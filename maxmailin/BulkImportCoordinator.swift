//
//  BulkImportCoordinator.swift
//  maxmailin
//
//  THE production import engine. Coordinates the full pipeline:
//
//      file → SHA-256 → checkpoint check → ParserFactory.parseStreamingCallback →
//             SQLiteEmailStore.insertBatch → FTSSearchIndex.indexBatch →
//             checkpoint → signed ImportReceipt
//
//  Designed for the 1 TB-scale story:
//   • Per-file pipelining — never holds more than one batch of parsed emails
//     in memory at once. Only a bounded preview (Options.previewCap) is
//     handed to the UI via callback; the coordinator never retains the corpus.
//   • Resumable — files whose SHA-256 is fully checkpointed are skipped.
//     Mid-file checkpoints are ordinal-bound (message index) and identity-bound
//     (SHA-256 + size + parser + parser version + checkpoint schema), so a
//     resume can never skip evidence — including when the batch size changed
//     between sessions (Part B5).
//   • Batched persistence and indexing — one transaction per batch.
//   • No swallowed correctness errors (Part B3):
//       - a SQLite insert failure is counted and fails that file (checkpoint
//         stays at the last committed ordinal → exact retry);
//       - a checkpoint write failure fail-stops the whole import (a batch is
//         not committed until its checkpoint persists);
//       - an FTS batch failure degrades (logged + counted + receipted); the
//         launch FTSReconciler backfills the index (Part 1f);
//       - store/FTS counts that cannot be read are reported as unavailable,
//         never fabricated as 0;
//       - a receipt that fails to sign or persist is surfaced in the run
//         summary, warnings, and log.
//   • Per-file error accumulation — one bad file never aborts the rest (1g).
//   • Cooperative cancellation on Task.isCancelled.
//   • Forensic SHA-256 of each source file recorded for chain of custody;
//     committed batches are surfaced via callback so forensic email-hash
//     coverage matches the persisted corpus, not just the preview (C1).
//
//  Pure-Swift, on-device, no network.
//

import Foundation
import CryptoKit
import SwiftUI
import os

@MainActor
@Observable
final class BulkImportCoordinator {

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                       category: "BulkImport")

    enum Status: Equatable {
        case idle
        case hashing(file: String)
        case parsing(file: String)
        case persisting(processed: Int, total: Int)
        case indexing(processed: Int, total: Int)
        case completed(count: Int, skipped: Int)
        case failed(String)
        case cancelled
    }

    /// Everything the legacy ContentViewModel pipeline supported that the
    /// coordinator now owns (Part 1a–1e).
    struct Options {
        /// Persist/index batch size. Clamped to 1...10_000.
        var batchSize: Int = 500
        /// Used for sent/received classification during parsing (1a).
        var senderEmail: String = ""
        /// Free-tier cap: stop persisting once this many emails have been
        /// committed this run (1c). Capped files are NOT marked complete, so
        /// upgrading re-imports the remainder.
        var maxEmails: Int? = nil
        /// Upper bound on emails delivered through `onPreviewBatch` (1e).
        var previewCap: Int = 5_000
        /// §4: the user's duplicate policy, resolved at the entry point (the
        /// legacy `removeDuplicates` toggle maps to .messageID / .preserveAll).
        var dedupPolicy: DedupPolicy = .messageID
        /// Optional account attribution for imported rows.
        var accountID: String? = nil
    }

    /// UI/side-effect hooks. All are invoked on the main actor.
    struct Callbacks {
        /// (filename, fileIndex, fileCount, fraction 0...1 within this file).
        var onFileProgress: (@MainActor (String, Int, Int, Double) -> Void)? = nil
        /// Bounded preview of committed emails (never more than previewCap
        /// total across the run) so the legacy in-RAM UI keeps working (1e).
        var onPreviewBatch: (@MainActor ([MBOXParser.RawEmail]) -> Void)? = nil
        /// Every batch that was committed to the store this run — for
        /// forensic hash registration over the persisted corpus (C1).
        var onCommittedBatch: (@MainActor ([MBOXParser.RawEmail]) -> Void)? = nil
    }

    struct FileError: Equatable, Sendable {
        var filename: String
        var message: String
    }

    /// Per-run accounting (Part B4). All counts are THIS RUN, computed from
    /// parser results and store deltas — never cumulative store-wide totals.
    struct RunSummary {
        /// Messages the parsers saw (parsed + damaged).
        var discovered = 0
        /// Messages successfully parsed.
        var parsed = 0
        /// Rows committed to the store this run (store delta); nil when the
        /// store count was unavailable — never fabricated.
        var inserted: Int? = nil
        /// Exact-duplicate findings recorded this run (findings delta); nil
        /// when unavailable.
        var duplicates: Int? = nil
        /// Unparseable messages skipped by parser recovery (1h).
        var damaged = 0
        /// Whole files skipped because their hash is fully checkpointed.
        var skippedFiles = 0
        /// Parsed messages whose store insert failed — hard error, counted.
        var persistFailed = 0
        /// Messages successfully FTS-indexed this run.
        var indexed = 0
        /// Emails handed to the store this run (upper bound on inserted).
        var persistAttempted = 0
        var attachmentsSeen = 0
        /// FTS degraded mode (1f): failed index batches were logged and the
        /// launch FTSReconciler will backfill.
        var ftsDegraded = false
        var ftsFailedBatchCount = 0
        var resumed = false
        var resumedDetail: String? = nil
        var cappedAtLimit = false
        var fileErrors: [FileError] = []
        var warnings: [String] = []
        var receipt: ImportReceipt? = nil
        /// False when the receipt could not be written to disk (surfaced,
        /// never `try?`-swallowed).
        var receiptPersisted = false
    }

    var status: Status = .idle
    var lastFinishedAt: Date?
    /// The signed receipt from the most recent import run (Phase 12).
    var lastReceipt: ImportReceipt?
    /// Full accounting for the most recent run.
    var lastRunSummary: RunSummary?
    private var task: Task<Void, Never>?

    /// Thrown internally when the free-tier cap is reached mid-parse.
    private struct CapReachedSignal: Error {}
    /// Wraps a store-insert failure so the per-file handler can distinguish
    /// it from a parse failure (the batch was already counted).
    private struct PersistFailureSignal: Error {
        let underlying: Error
    }

    /// Fire-and-forget entry point (kept for SwiftDataDiagnosticsView).
    /// Production callers should prefer `runImport` to receive the summary.
    func startImport(urls: [URL], batchSize: Int = 500) {
        cancel()
        let options = Options(batchSize: batchSize)
        task = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.runImport(urls: urls, options: options)
            // runImport sets status (completed/failed/cancelled) on every path.
        }
    }

    /// Cooperative cancellation. Safe to call at any point.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Run the full import pipeline and return per-run accounting. Status is
    /// updated on every path (completed / failed / cancelled). Throws on
    /// cancellation, storage-authority block, or checkpoint write failure.
    func runImport(
        urls: [URL],
        options: Options = Options(),
        callbacks: Callbacks = Callbacks()
    ) async throws -> RunSummary {
        do {
            let summary = try await run(urls: urls, options: options, callbacks: callbacks)
            return summary
        } catch is CancellationError {
            status = .cancelled
            throw CancellationError()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Pipeline

    private func run(urls: [URL], options: Options, callbacks: Callbacks) async throws -> RunSummary {
        // Clamp batchSize to a sane range. Values <= 0 would divide-by-zero
        // in chunked Array operations downstream; absurdly large values
        // defeat the streaming-pipeline memory bound.
        let batchSize = max(1, min(options.batchSize, 10_000))
        var summary = RunSummary()
        let startedAt = Date()

        // 0. (1d) Storage-authority gate: never write SQLite against
        //    unresolved storage. Fail explicitly — silently skipping persist
        //    is how archives used to look imported without reaching the store.
        guard await StorageActivationCoordinator.shared.isActive else {
            Self.logger.fault("Import blocked: storage authority is not active.")
            throw MaxmailinError.persistence(.containerUnavailable,
                detail: "Storage is not ready yet. The import was blocked (not skipped) — retry once activation completes.")
        }

        // Surface (don't inherit) a corrupt checkpoint file: previously
        // ingested files may be re-imported this run.
        if await ImportCheckpointStore.shared.corruptionDetected() {
            summary.warnings.append("The resume-checkpoint file was corrupt and has been quarantined; previously imported files may be re-imported (duplicates are deduplicated by the store).")
        }

        // Per-run baselines for inserted/duplicates accounting (B4). A read
        // failure is recorded as unavailable — never fabricated as 0.
        var storeBefore: Int? = nil
        do { storeBefore = try await SQLiteEmailStore.shared.totalCount() } catch {
            Self.logger.fault("Store count unavailable before import: \(error.localizedDescription, privacy: .public)")
            summary.warnings.append("Store count unavailable before import — inserted/duplicate counts will be reported as unavailable.")
        }
        var dupBefore: Int? = nil
        do { dupBefore = try await SQLiteEmailStore.shared.duplicatesCount() } catch {
            Self.logger.error("Duplicate-findings count unavailable before import: \(error.localizedDescription, privacy: .public)")
        }

        var sources: [ImportReceipt.SourceRecord] = []
        var previewRemaining = max(0, options.previewCap)

        fileLoop: for (fileIndex, url) in urls.enumerated() {
            try Task.checkCancellation()
            let sourceName = url.lastPathComponent

            // Per-file parse/persist state, visible to the batch closure.
            var parsedInFile = 0            // parsed-message ordinal within this file
            var committedOrdinal = 0        // leading messages persisted+indexed
            var fileError: Error? = nil

            do {
                // 1. Hash this file for chain of custody + checkpoint lookup.
                self.status = .hashing(file: sourceName)
                callbacks.onFileProgress?(sourceName, fileIndex, urls.count, 0)
                let hash = try await Self.sha256(of: url)
                let sizeBytes: Int = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let parserID = ParserFactory.parserIdentity(forExtension: url.pathExtension)
                sources.append(ImportReceipt.SourceRecord(
                    filename: sourceName, sizeBytes: sizeBytes,
                    sha256: hash, parser: parserID.name, parserVersion: parserID.version
                ))

                // §3.1/§3.2: first-class source identity. Every row this file
                // produces is stamped (source_id, source_ordinal), so resume /
                // re-parse can never duplicate an occurrence — regardless of
                // dedup policy — and forensic evidence stays locatable.
                let sourceID = try await SQLiteEmailStore.shared.registerSource(
                    SQLiteEmailStore.SourceDescriptor(
                        sha256: hash, filename: sourceName, byteSize: sizeBytes,
                        parser: parserID.name, parserVersion: parserID.version,
                        accountID: options.accountID,
                        sourceKind: url.pathExtension.lowercased()
                    ))

                // 2. Skip if we have already fully ingested this file.
                if await ImportCheckpointStore.shared.isImported(sha256: hash) {
                    summary.skippedFiles += 1
                    continue
                }
                try Task.checkCancellation()

                // 3. (B5) Safe resume identity: ordinal-bound and bound to
                //    SHA-256 + size + parser + parser version + schema. Any
                //    mismatch restarts the file from scratch.
                let identity = ImportCheckpointStore.ResumeIdentity(
                    sha256: hash, sizeBytes: sizeBytes,
                    parser: parserID.name, parserVersion: parserID.version
                )
                let resumeFrom = await ImportCheckpointStore.shared.resumePoint(for: identity)
                if resumeFrom > 0 {
                    summary.resumed = true
                    summary.resumedDetail = "Resumed \(sourceName) at message \(resumeFrom) (identity-verified checkpoint)."
                }
                committedOrdinal = resumeFrom

                // 4. Streaming parse → persist → index → checkpoint, one
                //    bounded batch at a time. §7.7: the recovery report is
                //    RETURNED per source — no global static, no race.
                self.status = .parsing(file: sourceName)
                var fileReport: MBOXParser.ParseRecoveryReport? = nil

                do {
                    fileReport = try await ParserFactory.parseStreamingCallback(
                        fileURL: url,
                        senderEmail: options.senderEmail,
                        batchSize: batchSize,
                        onProgress: { prog in
                            Task { @MainActor in
                                callbacks.onFileProgress?(sourceName, fileIndex, urls.count, prog)
                            }
                        }
                    ) { [weak self] batch in
                        guard let self else { return }
                        try Task.checkCancellation()

                        let batchStart = parsedInFile
                        parsedInFile += batch.count

                        // (B5) Skip only ordinals the checkpoint proves are
                        // committed — exact for any batch size.
                        let range = Self.pendingRange(
                            batchStart: batchStart,
                            batchCount: batch.count,
                            resumeFrom: resumeFrom
                        )
                        guard !range.isEmpty else { return }

                        // (1b) Per-email source-file annotation.
                        var pending = Array(batch[range])
                        for i in pending.indices {
                            pending[i].headers["sourceFile"] = sourceName
                        }

                        // (1c) Free-tier cap on committed emails this run.
                        var capped = false
                        if let cap = options.maxEmails {
                            let remaining = cap - summary.persistAttempted
                            if remaining <= 0 { throw CapReachedSignal() }
                            if pending.count > remaining {
                                pending = Array(pending.prefix(remaining))
                                capped = true
                            }
                        }

                        summary.attachmentsSeen += pending.reduce(0) { $0 + $1.attachments.count }

                        let processedBefore = summary.persistAttempted
                        await MainActor.run {
                            self.status = .persisting(
                                processed: processedBefore,
                                total: processedBefore + pending.count
                            )
                        }

                        // Persist. A store failure is a hard error for this
                        // batch: counted, logged, and it fails THIS FILE. The
                        // checkpoint stays at the last committed ordinal, so
                        // a retry resumes exactly at the failure point.
                        let insertResult: BatchInsertResult
                        do {
                            insertResult = try await SQLiteEmailStore.shared.insertBatch(
                                pending,
                                sourceFileHash: hash,
                                accountID: options.accountID,
                                sourceID: sourceID,
                                firstOrdinal: batchStart + range.lowerBound,
                                dedupPolicy: options.dedupPolicy,
                                batchSize: batchSize,
                                progress: nil
                            )
                        } catch {
                            summary.persistFailed += pending.count
                            Self.logger.fault("Persist failed for \(sourceName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            throw PersistFailureSignal(underlying: error)
                        }
                        summary.persistAttempted += pending.count

                        try Task.checkCancellation()

                        // (1f) FTS degraded mode: rows ARE in the store; the
                        // launch FTSReconciler backfills. Log + count +
                        // receipt, keep importing.
                        await MainActor.run {
                            self.status = .indexing(
                                processed: processedBefore,
                                total: processedBefore + pending.count
                            )
                        }
                        // §5.3: index ONLY rows the store actually committed —
                        // a policy-deduped or resume-skipped row must never
                        // become a ghost FTS hit.
                        let insertedSet = Set(insertResult.insertedIDs)
                        let toIndex = pending.filter { insertedSet.contains($0.id) }
                        do {
                            if !toIndex.isEmpty {
                                try await FTSSearchIndex.shared.indexBatch(toIndex)
                            }
                            summary.indexed += toIndex.count
                        } catch {
                            summary.ftsDegraded = true
                            summary.ftsFailedBatchCount += 1
                            Self.logger.warning("FTS index failed for a batch in \(sourceName, privacy: .public); store↔FTS drift will be repaired on next launch: \(error.localizedDescription, privacy: .public)")
                        }

                        // (B3) A batch is NOT committed until its checkpoint
                        // persists. `recordProgress` throws on write failure,
                        // which fail-stops the whole import.
                        committedOrdinal = batchStart + range.lowerBound + pending.count
                        try await ImportCheckpointStore.shared.recordProgress(
                            identity: identity,
                            sourceName: sourceName,
                            messagesIngested: committedOrdinal
                        )

                        // (1e) Bounded preview + (C1) forensic coverage over
                        // committed batches.
                        if previewRemaining > 0 {
                            let slice = Array(pending.prefix(previewRemaining))
                            previewRemaining -= slice.count
                            await MainActor.run { callbacks.onPreviewBatch?(slice) }
                        }
                        await MainActor.run { callbacks.onCommittedBatch?(pending) }

                        if capped { throw CapReachedSignal() }
                        // pending falls out of scope here — its storage is
                        // released before the next batch begins.
                    }
                } catch {
                    fileError = error
                }

                // §7.7: aggregate this file's returned (source-scoped) report.
                if let report = fileReport {
                    summary.damaged += report.failed
                    summary.discovered += report.totalMessages
                } else {
                    summary.discovered += parsedInFile
                }
                summary.parsed += parsedInFile

                if let fileError { throw fileError }

                // 5. File fully ingested: record the completion checkpoint
                //    (clears the in-progress one). Its write failure also
                //    fail-stops (B3).
                try await ImportCheckpointStore.shared.record(
                    sha256: hash,
                    sourceName: sourceName,
                    emailCount: committedOrdinal
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImportCheckpointStore.CheckpointError {
                // Checkpoint write failure: fail-stop the entire import — we
                // must not advance past an unrecorded batch.
                throw error
            } catch is CapReachedSignal {
                // Free-tier cap reached: stop the whole run. The current file
                // keeps its in-progress checkpoint (NOT completed) so a
                // premium upgrade resumes exactly where the cap cut off.
                summary.cappedAtLimit = true
                summary.warnings.append("Import stopped at the free-tier limit\(options.maxEmails.map { " (\($0) emails)" } ?? ""); upgrade to import the remainder.")
                break fileLoop
            } catch let error as PersistFailureSignal {
                // (1g) One bad file must not abort the rest.
                summary.fileErrors.append(FileError(
                    filename: sourceName,
                    message: "Could not save emails to the archive: \(error.underlying.localizedDescription)"
                ))
            } catch {
                summary.fileErrors.append(FileError(
                    filename: sourceName,
                    message: error.localizedDescription
                ))
            }
        }

        // Per-run inserted/duplicates from store deltas (B4). Unreadable
        // counts stay nil — reported as unavailable, never inflated.
        let completedAt = Date()
        var storeAfter: Int? = nil
        do { storeAfter = try await SQLiteEmailStore.shared.totalCount() } catch {
            Self.logger.fault("Store count unavailable after import: \(error.localizedDescription, privacy: .public)")
            summary.warnings.append("Store count unavailable after import — inserted count is unavailable.")
        }
        var dupAfter: Int? = nil
        do { dupAfter = try await SQLiteEmailStore.shared.duplicatesCount() } catch {
            Self.logger.error("Duplicate-findings count unavailable after import: \(error.localizedDescription, privacy: .public)")
        }
        var ftsCount: Int? = nil
        do { ftsCount = try await FTSSearchIndex.shared.rowCount() } catch {
            Self.logger.error("FTS row count unavailable after import: \(error.localizedDescription, privacy: .public)")
            summary.warnings.append("Search-index row count unavailable after import.")
        }
        if let before = storeBefore, let after = storeAfter {
            summary.inserted = max(0, after - before)
        }
        if let before = dupBefore, let after = dupAfter {
            summary.duplicates = max(0, after - before)
        }

        // Phase 12: build, sign (self-hash) and persist the import receipt.
        var receipt = ImportReceipt(startedAt: startedAt, completedAt: completedAt)
        receipt.sources = sources
        receipt.discovered = summary.discovered
        receipt.parsed = summary.parsed
        receipt.inserted = summary.inserted
        receipt.duplicates = summary.duplicates
        receipt.damaged = summary.damaged
        receipt.skipped = summary.skippedFiles
        receipt.persistFailed = summary.persistFailed
        receipt.indexed = summary.indexed
        receipt.attachmentsSeen = summary.attachmentsSeen
        receipt.fileFailures = summary.fileErrors.map {
            ImportReceipt.FileFailure(filename: $0.filename, message: $0.message)
        }
        receipt.resumed = summary.resumed
        receipt.resumedDetail = summary.resumedDetail
        receipt.ftsDegraded = summary.ftsDegraded
        receipt.ftsFailedBatchCount = summary.ftsFailedBatchCount
        receipt.reconciliationPending = summary.ftsDegraded
        receipt.durationSeconds = completedAt.timeIntervalSince(startedAt)
        receipt.storeCountBefore = storeBefore
        receipt.storeCountAfter = storeAfter
        receipt.ftsRowCount = ftsCount
        receipt.warnings = summary.warnings
        do {
            try receipt.finalize()
        } catch {
            Self.logger.fault("Import receipt could not be signed: \(error.localizedDescription, privacy: .public)")
            summary.warnings.append("Import receipt could not be signed — it will not verify.")
        }
        summary.receipt = receipt
        do {
            _ = try ImportReceiptStore.production.save(receipt)
            summary.receiptPersisted = true
        } catch {
            // Surface, never swallow: the durable audit trail is missing.
            summary.receiptPersisted = false
            Self.logger.fault("Import receipt failed to persist: \(error.localizedDescription, privacy: .public)")
            summary.warnings.append("Import receipt failed to persist: \(error.localizedDescription)")
        }

        self.lastReceipt = receipt
        self.lastRunSummary = summary
        self.status = .completed(
            count: summary.inserted ?? summary.persistAttempted,
            skipped: summary.skippedFiles
        )
        self.lastFinishedAt = Date()
        return summary
    }

    // MARK: - Resume arithmetic (pure, unit-tested)

    /// Given a batch spanning parsed-message ordinals
    /// `[batchStart, batchStart + batchCount)` and a checkpoint proving that
    /// messages `[0, resumeFrom)` are already persisted + indexed, returns
    /// the index range WITHIN the batch that still needs persisting.
    ///
    /// Exact for any batch size: changing the batch size between the crashed
    /// session and the resume shifts batch boundaries but the union of
    /// pending ranges is always exactly `[resumeFrom, total)` — no message is
    /// ever skipped or double-committed by the resume arithmetic.
    nonisolated static func pendingRange(batchStart: Int, batchCount: Int, resumeFrom: Int) -> Range<Int> {
        let lower = min(max(resumeFrom - batchStart, 0), batchCount)
        return lower..<batchCount
    }

    // MARK: - File hashing

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
