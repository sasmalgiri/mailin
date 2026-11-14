//
//  ArchiveExportService.swift
//  maxmailin
//
//  Stage 5 Wave 2A (v2-core-cutover): the streaming export authority. Every bulk
//  export accepts an `ArchiveSelectionScope` (or query) and is written
//  INCREMENTALLY from a bounded stream — a "Select All → export" over a million
//  messages never first materializes a giant `[RawEmail]`. Progress, counts and
//  cancellation are reported; a receipt-style summary is returned.
//
//  Part O: every production export format routes through the two shared cores
//  below — `exportTextDocument` (single artifact, incremental FileHandle writes,
//  incremental SHA-256, optional Ed25519 signing of the streamed digest) and
//  `exportMessageFiles` (one file per message into a dedicated folder). Both
//  resolve the scope symbolically (query + exclusions), stream in bounded
//  batches, report progress against `count(scope:)`, honor cooperative
//  cancellation, and clean up partial artifacts on cancel/failure.
//

import Foundation
import CryptoKit

enum ArchiveExportFormat: Sendable {
    case csvSummaries      // id,date,from,to,subject
    case jsonSummaries     // array of summary objects
    case eml               // full RFC822 per message, concatenated with separators
}

struct ArchiveExportResult: Sendable, Equatable {
    var recordsWritten: Int
    var bytesWritten: Int
    var completed: Bool
    var cancelled: Bool
    /// Hex SHA-256 of the artifact, computed incrementally WHILE writing —
    /// the finished file is never re-read into memory. `nil` for per-message
    /// folder exports.
    var sha256Hex: String? = nil
    /// Companion `.sig` written by `ExportSigner` (signed exports only).
    var signatureURL: URL? = nil
    /// Recheck R5: messages in scope that this format could not produce
    /// honestly — content not decoded at import and no raw-bytes path for
    /// the format (PDF, TIFF, MSG) — and were withheld rather than rendered as
    /// header-only stubs. A run with any is `partial`, never `complete`.
    var withheld: Int = 0
    /// Recheck R4: source files streamed from whose locators carry no digest,
    /// so their identity could not be verified. Reported on the receipt.
    var unverifiedSources: Int = 0
    /// Third review T3: INPUT positions of the scope consumed by this run up
    /// to its last durable boundary — what a resume must skip. Differs from
    /// `recordsWritten` whenever a message was skipped or withheld.
    var positionsConsumed: Int = 0
    /// Five jobs OUT-07: messages the renderer produced nothing for (reported apart from withheld).
    var skipped: Int = 0
    /// Five jobs OUT-07: the durable per-file inventory a finished folder export left beside its files.
    var inventoryURL: URL? = nil
    /// Five jobs OUT-02: files beyond one per message, written because the
    /// user chose one copy per folder occurrence. Disclosed on the receipt.
    var extraCopies: Int = 0
    /// Audit 2026-11-06 A07: the files were all written but the inventory
    /// could not be finalised — the reason, so the receipt is `unverified`
    /// rather than `complete`. The working manifest is kept in that case.
    var inventoryFailure: String? = nil
}

enum ArchiveExportError: LocalizedError {
    case emptySelection
    case nothingToExport(String)
    /// Recheck R2: a resume asked to append to a partial artifact that is gone.
    case partialArtifactMissing(String)
    /// Recheck R2: the partial artifact is not the length the receipt recorded.
    case partialArtifactChanged(path: String, expected: UInt64, actual: UInt64)
    /// Third review T2: same length, different bytes.
    case partialArtifactContentChanged(path: String)
    /// Third review T2: a resume without the recorded boundary (length + hash).
    case resumeBoundaryMissing(String)
    /// Third review T2/T3: the folder's manifest is absent, inconsistent, or a
    /// listed file is missing or changed.
    case partialManifestInvalid(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "Nothing selected to export."
        case .nothingToExport(let what): return "No \(what) found to export."
        case .partialArtifactMissing(let path):
            return "The partial export at \(path) is no longer there, so it cannot be continued. Start the export again."
        case .partialArtifactChanged(let path, let expected, let actual):
            return "The partial export at \(path) is \(actual) bytes but the receipt recorded \(expected); it was changed after the run stopped and cannot be continued. Start the export again."
        case .partialArtifactContentChanged(let path):
            return "The partial export at \(path) does not match the receipt's hash; it was changed after the run stopped and cannot be continued. Start the export again."
        case .resumeBoundaryMissing(let what):
            return "This export cannot be continued: \(what). Start the export again."
        case .partialManifestInvalid(let why):
            return "The partial export folder cannot be continued: \(why). Start the export again."
        }
    }
}

@MainActor
final class ArchiveExportService {
    static let shared = ArchiveExportService(archive: .shared)

    let archive: ArchiveDataService
    init(archive: ArchiveDataService) { self.archive = archive }

    /// Audit F04: the per-run proof that every source file streamed from is
    /// the file that was imported. A new ledger begins with each export
    /// entry point, so each source is hashed once per run, not per message.
    private(set) var sourceLedger = SourceVerificationLedger()

    private func beginSourceLedger() { sourceLedger = SourceVerificationLedger() }

    /// Phase C-1 boundary: ArchiveCore does not know the forensic risk model.
    /// The app installs a scorer when Professional Workflows is on; nil means
    /// the detailed CSV writes "—" in that column.
    nonisolated(unsafe) static var riskScoreProvider: (@Sendable (MBOXParser.RawEmail) -> Int)?

    /// Stream-export `scope` in `format` to `url`, writing incrementally.
    /// `onProgress` is called after each bounded batch. Returns a receipt.
    @discardableResult
    func export(scope: ArchiveSelectionScope,
                format: ArchiveExportFormat,
                to url: URL,
                batchSize: Int = 200,
                onProgress: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var records = 0, bytes = 0, firstJSON = true, cancelled = false
        func write(_ s: String) throws {
            let d = Data(s.utf8); try handle.write(contentsOf: d); bytes += d.count
        }

        if format == .csvSummaries { try write("id,date,from,to,subject\n") }
        if format == .jsonSummaries { try write("[") }

        for try await batch in archive.streamSelected(scope: scope, batchSize: batchSize) {
            if Task.isCancelled { cancelled = true; break }
            for email in batch {
                switch format {
                case .csvSummaries:
                    let date = MBOXParser.parseDate(email.headers["Date"]).map { ISO8601DateFormatter().string(from: $0) } ?? ""
                    let row = [email.id.uuidString, date,
                               email.headers["From"] ?? "", email.headers["To"] ?? "",
                               email.headers["Subject"] ?? ""].map(Self.csvField).joined(separator: ",")
                    try write(row + "\n")
                case .jsonSummaries:
                    let obj: [String: String] = [
                        "id": email.id.uuidString,
                        "from": email.headers["From"] ?? "",
                        "subject": email.headers["Subject"] ?? "",
                        "date": email.headers["Date"] ?? ""
                    ]
                    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
                    if !firstJSON { try write(",") }
                    firstJSON = false
                    try handle.write(contentsOf: data); bytes += data.count
                case .eml:
                    let eml = email.rawSource.isEmpty
                        ? "Subject: \(email.headers["Subject"] ?? "")\n\n\(email.plainBody)"
                        : email.rawSource
                    try write("\n--- MESSAGE \(email.id.uuidString) ---\n")
                    try write(eml)
                }
                records += 1
            }
            onProgress?(records)
        }

        if format == .jsonSummaries { try write("]") }
        return ArchiveExportResult(recordsWritten: records, bytesWritten: bytes, completed: !cancelled, cancelled: cancelled)
    }

    private static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: - Part O shared core 1: single streamed text artifact

    /// The shared streaming pipeline every single-file text format uses:
    /// resolve `scope` → stream bounded batches → append rows through one
    /// `FileHandle` (hashing incrementally) → progress after each batch →
    /// cooperative cancellation (partial file deleted) → error (partial file
    /// deleted, error rethrown) → optional Ed25519 signature over the
    /// incrementally computed SHA-256 digest.
    @discardableResult
    func exportTextDocument(
        scope: ArchiveSelectionScope,
        to url: URL,
        batchSize: Int = 200,
        limit: Int? = nil,
        signed: Bool = false,
        write options: ExportWriteOptions = ExportWriteOptions(),
        startAt: Int = 0,
        maxBytes: Int? = nil,
        manifestFormat: String? = nil,
        header: @MainActor (Int) -> String = { _ in "" },
        footer: @MainActor (Int) -> String = { _ in "" },
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
        rawStream: (@MainActor (MBOXParser.RawEmail) async throws -> RawStreamPlan?)? = nil,
        row: @MainActor (MBOXParser.RawEmail, Int) throws -> String
    ) async throws -> ArchiveExportResult {
        // A partition continues the run's ledger (startAt > 0); a fresh
        // export starts a new one.
        if startAt == 0 { beginSourceLedger() }
        let total = try await boundedTotal(scope: scope, limit: limit)

        // A8 resume: appending continues the interrupted artifact; the first
        // `skipFirst` positions of the scope are stepped over, not rewritten.
        // Partitioned exports use `startAt` the same way for a fresh file, and
        // `maxBytes` closes the file once the cap is reached (the record that
        // crosses the cap is written whole; a partition is never cut mid-record).
        let fm = FileManager.default
        let resuming = options.append && options.skipFirst > 0
        // Recheck R2: a resume must find the partial artifact it was told
        // about, at exactly the length the receipt recorded. Anything else is
        // refused rather than appended to.
        if resuming, !fm.fileExists(atPath: url.path) {
            throw ArchiveExportError.partialArtifactMissing(url.path)
        }
        let appending = resuming
        if !appending { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        // R3/R8: the running hash covers the WHOLE file, so a checkpoint can
        // record the prefix hash at its offset; a resume seeds it from the
        // bytes already there (read once, which is also the T2 check).
        var digest = SHA256()
        if appending {
            // T2: the boundary is length AND content. Without both the resume
            // is refused; with both, the existing bytes are re-hashed first.
            guard let expectedOffset = options.expectedAppendOffset,
                  let expectedHash = options.expectedAppendSHA256 else {
                try? handle.close()
                throw ArchiveExportError.resumeBoundaryMissing("the receipt carries no length and hash for the partial file")
            }
            let end = try handle.seekToEnd()
            if end != expectedOffset {
                try? handle.close()
                throw ArchiveExportError.partialArtifactChanged(path: url.path, expected: expectedOffset, actual: end)
            }
            digest = try Self.sha256State(ofFile: url)
            let actualHash = ContainerManifest.hex(digest.finalize())
            if actualHash != expectedHash {
                try? handle.close()
                throw ArchiveExportError.partialArtifactContentChanged(path: url.path)
            }
        }
        // R3/R8: a container format keeps its expected-record manifest beside
        // the file — a fresh one for a fresh file, the existing one (checked
        // against the resume point) for a resume.
        var manifest: ContainerManifest.Writer? = nil
        if let manifestFormat {
            do {
                if appending, let offset = options.expectedAppendOffset, let hash = options.expectedAppendSHA256 {
                    manifest = try ContainerManifest.Writer(resumingFor: url, positions: options.skipFirst, offset: offset, sha256: hash)
                } else if !appending {
                    manifest = try ContainerManifest.Writer(creatingFor: url, format: manifestFormat, startPosition: startAt)
                }
            } catch {
                try? handle.close()
                if !appending { try? fm.removeItem(at: url) }
                throw ArchiveExportError.partialManifestInvalid(error.localizedDescription)
            }
        }
        defer { manifest?.close() }
        let baseOffset: UInt64 = appending ? (options.expectedAppendOffset ?? 0) : 0
        // `position` is the index within the scope (what the receipt reports as
        // written, cumulatively across resumes); `bytes` is this run's output.
        var position = 0, bytes = 0, cancelled = false
        let skip = appending ? options.skipFirst : startAt
        // Audit F08: the durable record boundary. `onProgress` reports once per
        // batch, and a resume skips exactly that many positions — so a kept
        // partial file must END at that batch boundary. These track the file
        // offset and position at the last reported batch; a failure inside the
        // next batch truncates back to them.
        var committedOffset: UInt64 = appending ? try handle.offset() : 0
        var committedPosition = skip
        // Fourth review Q2: a resume starts AT its checkpoint. Progress is
        // seeded from it so a failure before the first new batch keeps it,
        // and the loop below never reports or commits a position below it.
        if appending { onProgress?(skip, total) }

        func writeData(_ d: Data) throws {
            guard !d.isEmpty else { return }
            try handle.write(contentsOf: d)
            digest.update(data: d)
            bytes += d.count
        }
        func write(_ s: String) throws {
            guard !s.isEmpty else { return }
            try writeData(Data(s.utf8))
        }
        func abort() {
            try? handle.close()
            try? fm.removeItem(at: url)
            manifest?.remove()
        }
        /// Cancel or error with `keepPartialOnCancel`: the artifact stays on
        /// disk, cut back to the last reported batch boundary, so a later run
        /// appends after exactly the records the receipt says were written —
        /// never after ten unreported rows and half a record. If the cut
        /// itself fails, the file is removed: a partial that cannot be
        /// trusted must not be offered for resume (R2).
        func keepPartial() {
            // The manifest already ends at the checkpoint for `committedOffset`;
            // record lines after it were never written.
            manifest?.discardPending()
            do {
                try handle.truncate(atOffset: committedOffset)
                try? handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: url)
            }
        }

        do {
            if !appending { try write(header(total)) }
            committedOffset = try handle.offset()
            stream: for try await batch in archive.streamSelected(scope: scope, batchSize: batchSize) {
                if Task.isCancelled { cancelled = true; break }
                for email in batch {
                    if let limit, position >= limit { break stream }
                    if position >= skip {
                        // S5: a located-not-stored message streams from its
                        // source; everything else renders through `row`.
                        let recordStart = baseOffset + UInt64(bytes)
                        if let rawStream, let plan = try await rawStream(email) {
                            try write(plan.prefix)
                            // Q1: the source is checked against its verified
                            // snapshot before and after the streamed read.
                            try Self.streamRecord(plan, ledger: sourceLedger, write: writeData)
                        } else {
                            try write(try row(email, position))
                        }
                        try manifest?.record(position: position, email: email, folder: Self.primaryFolderFirst(SQLiteEmailStore.folderPaths(for: email)).first,
                                             offset: recordStart, length: baseOffset + UInt64(bytes) - recordStart)
                    }
                    position += 1
                    if let maxBytes, bytes >= maxBytes { break stream }
                }
                // Q2: a replay-only batch (still stepping over what the
                // interrupted run wrote) moves nothing — the checkpoint
                // never goes backward.
                if position > committedPosition {
                    // R8: the batch's bytes reach the medium BEFORE the
                    // manifest's checkpoint names them, and the checkpoint is
                    // durable before the receipt counts them — so whatever
                    // happens to the drive, the last checkpoint on it is a
                    // boundary that verifies.
                    if let manifest {
                        try ContainerManifest.fullSync(handle)
                        let prefix = ContainerManifest.hex(digest.finalize())
                        try manifest.checkpoint(positions: position, bytes: baseOffset + UInt64(bytes), sha256: prefix)
                    }
                    onProgress?(position, total)
                    committedOffset = try handle.offset()
                    committedPosition = position
                }
                if let limit, position >= limit { break }
            }
            if cancelled || Task.isCancelled {
                if options.keepPartialOnCancel {
                    keepPartial()
                    return ArchiveExportResult(recordsWritten: committedPosition, bytesWritten: bytes, completed: false, cancelled: true,
                                               positionsConsumed: committedPosition)
                }
                abort()
                return ArchiveExportResult(recordsWritten: position, bytesWritten: 0, completed: false, cancelled: true,
                                           positionsConsumed: position)
            }
            try write(footer(position))
            try handle.close()
        } catch {
            if options.keepPartialOnCancel { keepPartial() } else { abort() }
            throw error
        }

        // The hash always covers the WHOLE artifact: a resumed run's digest
        // was seeded from the bytes already there.
        let finished: SHA256Digest = digest.finalize()
        let hex = finished.map { String(format: "%02x", $0) }.joined()
        // R3: the manifest's end mark. The file itself is complete; a manifest
        // that cannot be finished is carried to the receipt, never ignored.
        var manifestFailure: String? = nil
        if let manifest {
            do { try manifest.finish(positions: position, bytes: baseOffset + UInt64(bytes), sha256: hex) }
            catch { manifestFailure = "the container manifest could not be finished: \(error.localizedDescription)" }
        }
        var sigURL: URL? = nil
        if signed {
            // Forensic-integrity formats: signature covers the streamed digest
            // (the artifact is never re-read into memory).
            do {
                sigURL = try ExportSigner.shared.signStreamedDigest(Data(finished), hex: hex, for: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        return ArchiveExportResult(recordsWritten: position, bytesWritten: bytes,
                                   completed: true, cancelled: false,
                                   sha256Hex: hex, signatureURL: sigURL,
                                   unverifiedSources: sourceLedger.unverifiedPaths.count,
                                   positionsConsumed: position,
                                   inventoryFailure: manifestFailure)
    }

    /// SHA-256 of a file in 1 MiB chunks — never the whole file in memory.
    nonisolated static func sha256(ofFile url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize()
    }

    /// The running SHA-256 state over a whole file, to continue hashing after it.
    nonisolated static func sha256State(ofFile url: URL) throws -> SHA256 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest
    }

    // MARK: - Part O shared core 2: one file per message into a folder

    /// Streams `scope` and writes one file per message into `folder` (created
    /// if needed). On cancellation or failure every file written so far is
    /// removed (and the folder, if this call created it), so no partial
    /// artifact survives. `content` returns nil to skip a message.
    ///
    /// `locatedRawExtension` (audit F05): when set, a message whose bytes are
    /// located rather than stored is streamed from its source into
    /// `<n>_<subject>.<ext>` instead of being handed to `content`, which could
    /// only render a header-only stub for it. A located message whose source
    /// is gone fails the export — never a stub.
    @discardableResult
    func exportMessageFiles(
        scope: ArchiveSelectionScope,
        to folder: URL,
        batchSize: Int = 200,
        limit: Int? = nil,
        write options: ExportWriteOptions = ExportWriteOptions(),
        locatedRawExtension: String? = nil,
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
        onProduced: (@MainActor @Sendable (Int) -> Void)? = nil,
        storedRaw: (@MainActor (MBOXParser.RawEmail, Int) async throws -> (filename: String, data: Data)?)? = nil,
        content: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)?
    ) async throws -> ArchiveExportResult {
        beginSourceLedger()
        let total = try await boundedTotal(scope: scope, limit: limit)

        let fm = FileManager.default
        let resuming = options.append && options.skipFirst > 0
        // T2/T3: a resume must find the folder and its manifest, and the
        // manifest must end at the position the receipt recorded with every
        // listed file present and unchanged. Verified before anything is written.
        var producedBefore = 0, withheldBefore = 0, skippedBefore = 0
        if resuming {
            guard fm.fileExists(atPath: folder.path) else {
                throw ArchiveExportError.partialManifestInvalid("the partial export folder \(folder.path) is gone")
            }
            let state = try ExportFolderManifest.verify(folder: folder, expectedPositions: options.skipFirst)
            producedBefore = state.produced
            // Q3: what the earlier run(s) withheld or skipped is restored, so
            // the final receipt covers the whole export, not this run alone.
            withheldBefore = state.withheld
            skippedBefore = state.skipped
            // Q2: progress and produced start AT the checkpoint.
            onProgress?(options.skipFirst, total)
            onProduced?(producedBefore)
        }
        let createdFolder = !fm.fileExists(atPath: folder.path)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = ExportFolderManifest(folder: folder)
        try manifest.open(append: resuming)
        defer { manifest.close() }

        // Only relative paths are retained for cleanup — bounded metadata, never bodies.
        var written: [String] = []
        var createdSubfolders: [URL] = []
        // A8 resume: `records` continues the interrupted run's numbering so the
        // per-message filenames stay one unbroken sequence. T3: the produced
        // count comes from the manifest, the INPUT position from `skipFirst`.
        var records = producedBefore, skipped = skippedBefore, bytes = 0, cancelled = false
        var seen = 0
        var extraCopies = 0
        // Audit F08: files written after the last reported batch boundary are
        // removed on a kept-partial stop, so the folder holds exactly the
        // records the receipt counts and a resume rewrites nothing twice.
        var writtenAtBoundary = 0
        var recordsAtBoundary = records
        var positionsAtBoundary = options.skipFirst
        var withheld = withheldBefore

        func cleanup() {
            guard !options.keepPartialOnCancel else {
                // Fifth review S2: the manifest is cut back ONLY when every
                // file past the boundary is really gone. A file that will not
                // go keeps its entry, so the next resume's verification sees
                // it, tries again, and refuses while it is still there.
                var allRemoved = true
                for name in written[writtenAtBoundary...] {
                    let target = folder.appendingPathComponent(name)
                    do {
                        try fm.removeItem(at: target)
                    } catch {
                        // Sixth review U1: only a definite "gone" (ENOENT)
                        // counts as removed. A file that is still there, or
                        // whose state cannot be established (EACCES, EIO…),
                        // keeps its entry.
                        var st = stat()
                        if lstat(target.path, &st) != 0, errno == ENOENT { continue }
                        allRemoved = false
                    }
                }
                written.removeSubrange(writtenAtBoundary...)
                if allRemoved { manifest.truncateToBoundary() } else { manifest.synchronize() }
                return
            }
            for name in written { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
            manifest.close()
            manifest.remove()
            for sub in createdSubfolders.reversed() { try? fm.removeItem(at: sub) }
            if createdFolder { try? fm.removeItem(at: folder) }
        }

        do {
            stream: for try await batch in archive.streamSelected(scope: scope, batchSize: batchSize) {
                if Task.isCancelled { cancelled = true; break }
                for email in batch {
                    if let limit, records + skipped >= limit { break stream }
                    // Step over what the interrupted run already wrote.
                    if seen < options.skipFirst { seen += 1; continue }
                    seen += 1
                    // A located message streams from its source (data nil);
                    // everything else renders through `content`.
                    // Recheck R5: the content check runs for EVERY per-file
                    // format, not only the one that can stream raw bytes. A
                    // message with no decoded content is either streamed
                    // (EML), withheld and counted (PDF/TIFF/MSG cannot render
                    // undecoded bytes), or — with no source either — a failure.
                    var located = false
                    if email.rawSource.isEmpty, email.plainBody.isEmpty, email.htmlBody.isEmpty {
                        switch await archive.rawMessageSource(for: email) {
                        case .located(let locator):
                            if locatedRawExtension != nil {
                                // F04: the source is proven to be the imported
                                // file before a byte of it is exported.
                                try await sourceLedger.verify(locator)
                                located = true
                            } else {
                                withheld += 1
                                continue
                            }
                        case .unavailable(let why):
                            // Nothing to render and nothing to stream: the
                            // export fails here rather than writing a stub.
                            throw RawMessageError.contentUnavailable(subject: email.headers["Subject"] ?? "(no subject)", reason: why)
                        case .stored:
                            break
                        }
                    }
                    let file: (filename: String, data: Data?)
                    if located, let ext = locatedRawExtension {
                        file = (Self.messageFilename(index: records, subject: email.headers["Subject"], ext: ext), nil)
                    } else if let storedRaw, let raw = try await storedRaw(email, records) {
                        // The message's own stored bytes (a capture), written as they are.
                        file = (raw.filename, raw.data)
                    } else if let rendered = try content(email, records) {
                        file = (rendered.filename, rendered.data)
                    } else {
                        skipped += 1
                        continue
                    }

                    // Folder layout: flat, one subfolder per message year, or
                    // the archive's own folders (OUT-03) with safe names —
                    // once in the first folder, or (OUT-02, by choice) once
                    // per folder the message belongs to.
                    var targets: [(subdirectory: String?, originalFolder: String?)] = []
                    switch options.layout {
                    case .flat:
                        targets = [(nil, nil)]
                    case .byYear:
                        targets = [(Self.yearFolderName(for: email), nil)]
                    case .sourceFolders:
                        let paths = Self.primaryFolderFirst(SQLiteEmailStore.folderPaths(for: email))
                        let chosen = options.folderOccurrences ? paths : Array(paths.prefix(1))
                        targets = chosen.map { path in
                            let safe = ExportInventory.safeRelativeDirectory(forFolderPath: path)
                            return (safe.isEmpty ? nil : safe, path)
                        }
                        if targets.isEmpty { targets = [(nil, nil)] }
                    }
                    extraCopies += targets.count - 1
                    for (subdirectory, originalFolder) in targets {
                        var directory = folder
                        var relative = file.filename
                        if let subdirectory {
                            directory = folder.appendingPathComponent(subdirectory, isDirectory: true)
                            relative = subdirectory + "/" + file.filename
                            if !fm.fileExists(atPath: directory.path) {
                                // Every missing ancestor is recorded so a cleanup removes what this run made.
                                var ancestor = folder
                                for component in subdirectory.split(separator: "/") {
                                    ancestor = ancestor.appendingPathComponent(String(component), isDirectory: true)
                                    if !fm.fileExists(atPath: ancestor.path) { createdSubfolders.append(ancestor) }
                                }
                                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                            }
                        }
                        var target = directory.appendingPathComponent(file.filename)

                        // Collision rule for a destination that already has files.
                        if fm.fileExists(atPath: target.path) {
                            switch options.collision {
                            case .skipExisting:
                                // Q5: an existing file accepted as output is
                                // fingerprinted in the manifest like a produced
                                // one (so produced == listed files and a resume
                                // re-verifies it), but never created or removed
                                // by this export.
                                let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
                                let digest = try Self.sha256(ofFile: target).map { String(format: "%02x", $0) }.joined()
                                try manifest.appendFile(name: relative, bytes: size, sha256: digest, existing: true,
                                                        emailID: email.id.uuidString, messageID: email.headers["Message-ID"],
                                                        originalFolder: originalFolder)
                                records += 1
                                continue
                            case .overwrite:
                                break
                            case .keepBoth:
                                target = Self.uniqueURL(for: target)
                                relative = (subdirectory.map { $0 + "/" } ?? "") + target.lastPathComponent
                            }
                        }
                        let fileBytes: Int
                        let fileHash: String
                        if let data = file.data {
                            try data.write(to: target, options: .atomic)
                            fileBytes = data.count
                            fileHash = ExportFolderManifest.hex(data)
                        } else {
                            let streamed = try await archive.writeRawMessage(for: email, to: target, ledger: sourceLedger)
                            fileBytes = streamed.bytes
                            fileHash = streamed.sha256Hex
                        }
                        bytes += fileBytes
                        written.append(relative)
                        try manifest.appendFile(name: relative, bytes: fileBytes, sha256: fileHash,
                                                emailID: email.id.uuidString, messageID: email.headers["Message-ID"],
                                                originalFolder: originalFolder)
                        records += 1
                    }
                }
                // T3: progress is the INPUT position (what a resume skips);
                // the produced count travels separately. Q2: a replay-only
                // batch writes no boundary and reports nothing — the
                // checkpoint never moves backward. Q3: the boundary carries
                // the cumulative withheld and skipped counts.
                if seen > positionsAtBoundary {
                    try manifest.appendBoundary(positions: seen, produced: records, withheld: withheld, skipped: skipped)
                    onProgress?(seen, total)
                    onProduced?(records)
                    writtenAtBoundary = written.count
                    recordsAtBoundary = records
                    positionsAtBoundary = seen
                }
                if let limit, records + skipped >= limit { break }
            }
        } catch {
            cleanup()
            throw error
        }
        if cancelled || Task.isCancelled {
            cleanup()
            return ArchiveExportResult(recordsWritten: options.keepPartialOnCancel ? recordsAtBoundary : records,
                                       bytesWritten: options.keepPartialOnCancel ? bytes : 0,
                                       completed: false, cancelled: true, withheld: withheld,
                                       unverifiedSources: sourceLedger.unverifiedPaths.count,
                                       positionsConsumed: options.keepPartialOnCancel ? positionsAtBoundary : seen,
                                       skipped: skipped, extraCopies: extraCopies)
        }
        // OUT-07: a finished run keeps its per-file record — the manifest is
        // finalised into the portable inventory beside the files. Only when
        // that succeeded is the working manifest removed; otherwise it stays
        // as the record rather than nothing.
        manifest.close()
        var inventoryURL: URL? = nil
        var inventoryFailure: String? = nil
        do {
            inventoryURL = try ExportInventory.finalize(folder: folder, manifestURL: manifest.url, layout: options.layout.rawValue,
                                                        written: records, withheld: withheld, skipped: skipped, positionsConsumed: seen)
            manifest.remove()
        } catch {
            // Audit A07: the files are complete, the record is not — carried
            // to the receipt as its own outcome, never swallowed into "complete".
            inventoryFailure = error.localizedDescription
        }
        return ArchiveExportResult(recordsWritten: records, bytesWritten: bytes, completed: true, cancelled: false,
                                   withheld: withheld, unverifiedSources: sourceLedger.unverifiedPaths.count,
                                   positionsConsumed: seen, skipped: skipped, inventoryURL: inventoryURL, extraCopies: extraCopies,
                                   inventoryFailure: inventoryFailure)
    }

    /// The folder a message is filed under when it is written once: its
    /// Inbox when it has one, else its first folder that is not an
    /// everything-view ("All Mail" — a captured Gmail message carries that
    /// label next to its real ones, and it sorts first). The other folders
    /// keep their order after it.
    nonisolated static func primaryFolderFirst(_ paths: [String]) -> [String] {
        guard paths.count > 1 else { return paths }
        func isInbox(_ p: String) -> Bool { p.caseInsensitiveCompare("Inbox") == .orderedSame }
        func isAllMail(_ p: String) -> Bool {
            let last = p.split(separator: "/").last.map(String.init) ?? p
            return last.caseInsensitiveCompare("All Mail") == .orderedSame
        }
        let primary = paths.first(where: isInbox) ?? paths.first(where: { !isAllMail($0) }) ?? paths[0]
        return [primary] + paths.filter { $0 != primary }
    }

    /// `2019`, or `undated` when the Date header is missing or unparseable.
    nonisolated static func yearFolderName(for email: MBOXParser.RawEmail) -> String {
        guard let date = MBOXParser.parseDate(email.headers["Date"]) else { return "undated" }
        return String(Calendar(identifier: .gregorian).component(.year, from: date))
    }

    /// `name (2).ext`, `name (3).ext`, … — the first that does not exist yet.
    nonisolated static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var n = 2
        while n < 10_000 {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }

    func boundedTotal(scope: ArchiveSelectionScope, limit: Int?) async throws -> Int {
        let count = try await archive.count(scope: scope)
        if let limit { return min(count, limit) }
        return count
    }

    /// Filesystem-safe per-message filename; the running index keeps names
    /// unique without an unbounded used-name set.
    nonisolated static func messageFilename(index: Int, subject: String?, ext: String) -> String {
        let safe = (subject ?? "(no-subject)")
            .replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .prefix(60)
        return "\(index + 1)_\(safe).\(ext)"
    }

    // MARK: - Per-format writers (Part O)

    /// EML: one .eml per message. `render` defaults to raw source (or a minimal
    /// reconstruction); callers may pass `ContentViewModel.exportEmailAsEML`.
    /// A located message (header-only import above the ceiling) is streamed
    /// from its source, byte for byte, whatever `render` would have made of it.
    @discardableResult
    func exportEMLFiles(scope: ArchiveSelectionScope, to folder: URL,
                        limit: Int? = nil,
                        render: (@MainActor @Sendable (MBOXParser.RawEmail) -> String)? = nil,
                        write options: ExportWriteOptions = ExportWriteOptions(),
                        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
                        onProduced: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let result = try await exportEMLFilesBody(scope: scope, to: folder, limit: limit, render: render, write: options,
                                                  onProgress: onProgress, onProduced: onProduced)
        return await withProvenanceSidecar(result, folder: folder)
    }

    /// V4-08 (§5.5 exports): a finished folder export holding connected mail
    /// gets its provenance sidecar — account, provider identity, folders and
    /// the captured SHA-256 per file, never a credential. The export verifier
    /// ignores the sidecar (ExportInventory), so verification is unchanged.
    /// EML, MSG, PDF and TIFF folders all carry it.
    func withProvenanceSidecar(_ result: ArchiveExportResult, folder: URL) async -> ArchiveExportResult {
        var result = result
        if !result.cancelled, result.inventoryURL != nil, let store = archive.sqliteStore,
           (try? await store.hasConnectedMessages()) == true {
            do {
                try await ConnectedArchiveSink(store: store).writeProvenanceSidecar(exportFolder: folder)
            } catch {
                let note = "connected-mail provenance was not written: \(error.localizedDescription)"
                result.inventoryFailure = result.inventoryFailure.map { $0 + "; " + note } ?? note
            }
        }
        return result
    }

    /// The same sidecar for a container (mbox, PST): one entry per record of
    /// the container's manifest that is connected mail, written beside it as
    /// `<container>.mailin-connected-provenance.json`. Nil when none is.
    @discardableResult
    func writeContainerProvenanceSidecar(container: URL) async throws -> URL? {
        guard let store = archive.sqliteStore, try await store.hasConnectedMessages() else { return nil }
        return try await ConnectedArchiveSink(store: store).writeProvenanceSidecar(container: container)
    }

    /// The container sidecar for a finished text-document export; a failure
    /// is carried on the receipt, never swallowed.
    func withContainerProvenanceSidecar(_ result: ArchiveExportResult, container: URL) async -> ArchiveExportResult {
        guard result.completed, !result.cancelled else { return result }
        var result = result
        do { try await writeContainerProvenanceSidecar(container: container) } catch {
            let note = "connected-mail provenance was not written: \(error.localizedDescription)"
            result.inventoryFailure = result.inventoryFailure.map { $0 + "; " + note } ?? note
        }
        return result
    }

    /// When the archive holds connected mail: a captured record's own bytes
    /// as one file (nil for every other record, which renders as before).
    func capturedRawFile(ext: String) async -> (@MainActor (MBOXParser.RawEmail, Int) async throws -> (filename: String, data: Data)?)? {
        guard let store = await connectedStore() else { return nil }
        return { email, index in
            guard let blob = try await store.capturedRawBlob(emailID: email.id) else { return nil }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: ext), try store.blobStore.read(blob))
        }
    }

    /// The mbox stream plan: a located message from its source, a captured
    /// message from its own stored bytes (as acquired — never re-encoded
    /// through the decoded text), anything else nil (rendered from the text).
    func mboxStreamPlan(for email: MBOXParser.RawEmail, connected: SQLiteEmailStore?) async throws -> RawStreamPlan? {
        if let located = try await locatorStreamPlan(for: email) { return located }
        guard let connected, let blob = try await connected.capturedRawBlob(emailID: email.id) else { return nil }
        return RawStreamPlan(prefix: MBOXRecordBuilder.envelopeLine(for: email),
                             sourcePath: connected.blobStore.url(for: blob.digest).path,
                             range: ByteRange(offset: 0, length: blob.length), quoteFromLines: true, locator: nil)
    }

    /// The store, when it holds connected mail (checked once per export).
    func connectedStore() async -> SQLiteEmailStore? {
        guard let store = archive.sqliteStore, (try? await store.hasConnectedMessages()) == true else { return nil }
        return store
    }

    private func exportEMLFilesBody(scope: ArchiveSelectionScope, to folder: URL, limit: Int?,
                                    render: (@MainActor @Sendable (MBOXParser.RawEmail) -> String)?,
                                    write options: ExportWriteOptions,
                                    onProgress: (@MainActor @Sendable (Int, Int) -> Void)?,
                                    onProduced: (@MainActor @Sendable (Int) -> Void)?) async throws -> ArchiveExportResult {
        try await exportMessageFiles(scope: scope, to: folder, limit: limit, write: options,
                                     locatedRawExtension: "eml", onProgress: onProgress, onProduced: onProduced,
                                     storedRaw: await capturedRawFile(ext: "eml")) { email, index in
            // A message without raw source (PST, MSG, OLM, NSF imports) is
            // rendered whole — headers, both bodies, every attachment — not
            // reduced to a subject line and the plain text.
            let eml: Data
            if let render { eml = Data(render(email).utf8) }
            else if email.rawSource.isEmpty { eml = RFC822Renderer.render(email) }
            else { eml = Data(email.rawSource.utf8) }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: "eml"), eml)
        }
    }

    /// MSG: one OLE2 .msg per message — the writer is per-message, so the set
    /// streams unbounded (unlike PST below).
    @discardableResult
    func exportMSGFiles(scope: ArchiveSelectionScope, to folder: URL,
                        limit: Int? = nil,
                        write options: ExportWriteOptions = ExportWriteOptions(),
                        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
                        onProduced: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let result = try await exportMessageFiles(scope: scope, to: folder, limit: limit, write: options, onProgress: onProgress, onProduced: onProduced) { email, index in
            guard let data = MSGWriter.write(email: email) else { return nil }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: "msg"), data)
        }
        return await withProvenanceSidecar(result, folder: folder)
    }

    /// Detailed CSV (the list "Export as CSV" columns).
    @discardableResult
    func exportDetailedCSV(scope: ArchiveSelectionScope, to url: URL,
                           limit: Int? = nil,
                           write options: ExportWriteOptions = ExportWriteOptions(),
                           onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try await exportTextDocument(
            scope: scope, to: url, limit: limit, write: options,
            header: { _ in "Date,From,To,CC,Subject,Type,Labels,Has Attachments,Attachment Count,Risk Score,Body Preview\n" },
            onProgress: onProgress
        ) { email, _ in
            Self.detailedCSVRow(email)
        }
    }

    nonisolated private static func detailedCSVRow(_ email: MBOXParser.RawEmail) -> String {
        func esc(_ s: String) -> String {
            var v = s
            if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
            let sanitized = v
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return "\"" + sanitized + "\""
        }
        let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
        // The Risk Score column is Professional's number. The app layer
        // installs the scorer (`ArchiveExportService+Professional`); with Page
        // 3 off the column reads "—" rather than a fabricated zero.
        let risk = Self.riskScoreProvider.map { "\($0(email))" } ?? "—"
        let row = [email.headers["Date"] ?? "", email.headers["From"] ?? "",
                   email.headers["To"] ?? "", cc, email.headers["Subject"] ?? "",
                   email.messageType, email.tags.joined(separator: "; "),
                   email.attachments.isEmpty ? "No" : "Yes", String(email.attachments.count),
                   risk, String(email.plainBody.prefix(200))]
            .map(esc).joined(separator: ",")
        return row + "\n"
    }

    // CAP-04: the portable HTML viewer is chunked (`data/part-NNNN.js`) and
    // carries no message cap any more; see ArchiveExportService+Renderers.

    /// Full-archive JSON (`ExportableParsedMBOXFile` shape) — the emails array
    /// is streamed; the summary is accumulated incrementally (date bounds +
    /// subject-hash cardinality), never from a materialized array.
    @discardableResult
    func exportJSONArchive(scope: ArchiveSelectionScope, to url: URL,
                           limit: Int? = nil,
                           onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let encoder = JSONEncoder()
        let iso = ISO8601DateFormatter()
        var first = true
        var minDate: Date? = nil, maxDate: Date? = nil
        var subjectHashes = Set<Int>()   // bounded: 8 bytes per DISTINCT subject
        return try await exportTextDocument(
            scope: scope, to: url, limit: limit,
            header: { _ in "{\"emails\":[" },
            footer: { _ in
                let start = minDate.map { iso.string(from: $0) } ?? "N/A"
                let end = maxDate.map { iso.string(from: $0) } ?? "N/A"
                return "],\"summary\":{\"start\":\"\(start)\",\"end\":\"\(end)\",\"subjectCount\":\(subjectHashes.count)}}"
            },
            onProgress: onProgress
        ) { email, _ in
            if let d = MBOXParser.parseDate(email.headers["Date"]) {
                minDate = min(minDate ?? d, d)
                maxDate = max(maxDate ?? d, d)
            }
            if let s = email.headers["Subject"]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                subjectHashes.insert(s.hashValue)
            }
            let data = try encoder.encode(email.asExportable())
            defer { first = false }
            return (first ? "" : ",") + (String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    /// Word (.doc): ONE Office-namespace HTML document containing every email
    /// in the scope — streamed section by section (page break between emails),
    /// never a materialized array. Opens in Microsoft Word / Pages.
    @discardableResult
    func exportWordArchive(scope: ArchiveSelectionScope, to url: URL,
                           limit: Int? = nil,
                           onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return try await exportTextDocument(
            scope: scope, to: url, limit: limit,
            header: { _ in """
                <html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word">
                <head><meta charset="utf-8"><title>mailin email export</title>
                <!--[if gte mso 9]><xml><w:WordDocument><w:View>Print</w:View></w:WordDocument></xml><![endif]-->
                <style>body{font-family:Calibri,Helvetica,sans-serif;font-size:11pt} table.hdr{border-bottom:1px solid #999;margin-bottom:10px;font-size:10pt} div.email{margin-bottom:24px} br.sep{page-break-before:always}</style>
                </head><body>

                """ },
            footer: { _ in "</body></html>" },
            onProgress: onProgress
        ) { email, index in
            var rows = ""
            for (label, key) in [("Subject", "Subject"), ("From", "From"), ("To", "To"),
                                 ("Cc", "Cc"), ("Date", "Date")] {
                if let value = email.headers[key], !value.isEmpty {
                    rows += "<tr><td style=\"font-weight:bold;padding:2px 12px 2px 0;white-space:nowrap;vertical-align:top\">\(label)</td><td style=\"padding:2px 0\">\(esc(value))</td></tr>"
                }
            }
            let body = email.htmlBody.isEmpty
                ? "<p>" + esc(email.plainBody).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
                : email.htmlBody
            let pageBreak = index == 0 ? "" : "<br class=\"sep\">"
            return "\(pageBreak)<div class=\"email\"><table class=\"hdr\">\(rows)</table>\(body)</div>\n"
        }
    }

    /// mbox: a standard mbox archive of the scope — importable by Apple Mail
    /// (File ▸ Import Mailboxes ▸ Files in mbox format) and by Thunderbird via
    /// ImportExportTools NG.
    ///
    /// H1 fixed three defects that made the handoff claim untrue:
    ///  1. the `From_` envelope was hardcoded `MAILER-DAEMON Thu Jan  1 1970`,
    ///     so every message claimed the epoch and an invented sender
    ///  2. when `rawSource` was empty it synthesized headers + plain body only,
    ///     silently **dropping attachments**
    ///  3. there was no partitioning, so a whole-archive export produced one
    ///     file that exceeds the 4 GiB single-file limit of FAT32 — the normal
    ///     format for the external drive such an export lands on
    @discardableResult
    func exportMBOXArchive(scope: ArchiveSelectionScope, to url: URL,
                           limit: Int? = nil,
                           write options: ExportWriteOptions = ExportWriteOptions(),
                           onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let connected = await connectedStore()
        let result = try await exportTextDocument(
            scope: scope, to: url, limit: limit, write: options,
            manifestFormat: "mbox",
            onProgress: onProgress,
            rawStream: { [self] email in try await self.mboxStreamPlan(for: email, connected: connected) }
        ) { email, _ in
            Self.mboxRecord(for: email)
        }
        return await withContainerProvenanceSidecar(result, container: url)
    }

    /// One mbox record: a correct `From_` envelope followed by the message.
    ///
    /// Byte fidelity is the priority: when the store has the raw MIME we emit
    /// it unchanged (only mbox `>From ` quoting is applied, which is the
    /// container's own escaping and is reversed on import). The synthesized
    /// fallback is used only when no raw MIME exists, and it now carries
    /// attachments as real MIME parts instead of discarding them.
    static func mboxRecord(for email: MBOXParser.RawEmail) -> String {
        let raw = email.rawSource.isEmpty
            ? MBOXRecordBuilder.synthesizeMIME(for: email)
            : email.rawSource
        // The stored raw carries the mbox framing it was parsed with: an
        // envelope line (the source's own, or the parser's synthetic
        // `From MAILER-DAEMON …`). That line is container metadata, not the
        // message — it must not be quoted into the body as `>From …`. Strip
        // it, write one correct envelope, and close the record with exactly
        // one blank line (RFC 4155), whatever the stored text ended with.
        let message = MBOXRecordBuilder.strippingEnvelopeLine(raw)
        let body = MBOXRecordBuilder.quoteFromLines(message)
        let separator: String
        if body.hasSuffix("\n\n") || body.hasSuffix("\r\n\r\n") { separator = "" }
        else if body.hasSuffix("\n") { separator = "\n" }
        else { separator = "\n\n" }
        // A real envelope the source carried (offset engine) is written back
        // verbatim; the streaming parser's MAILER-DAEMON/1970 placeholder is
        // replaced by one built from the message's own sender and date.
        let envelope: String
        if let stored = MBOXRecordBuilder.envelopeLine(in: raw), !stored.contains("MAILER-DAEMON") {
            envelope = stored.hasSuffix("\n") ? stored : stored + "\n"
        } else {
            envelope = MBOXRecordBuilder.envelopeLine(for: email)
        }
        return envelope + body + separator
    }

    /// Streams the scope into mbox **partitions** of at most `partitionBytes`,
    /// so the output survives a 4 GB-per-file filesystem and stays importable
    /// (Apple Mail imports a folder of mbox files).
    ///
    /// Returns one receipt per partition plus the combined counts.
    @discardableResult
    func exportMBOXPartitions(scope: ArchiveSelectionScope,
                              toDirectory directory: URL,
                              baseName: String = "archive",
                              partitionBytes: Int = 2 * 1_073_741_824,
                              limit: Int? = nil,
                              onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil)
    async throws -> [ArchiveExportResult] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var results: [ArchiveExportResult] = []
        let connected = await connectedStore()
        var partition = 1
        var written = 0
        var exhausted = false

        // Each partition is a normal streamed mbox export with its own receipt
        // and its own hash, so a partition can be verified independently. It
        // starts where the previous one stopped and closes when it reaches
        // `partitionBytes` (the record crossing the cap is written whole).
        while !exhausted {
            let name = String(format: "%@-%04d.mbox", baseName, partition)
            let target = directory.appendingPathComponent(name)
            let counter = PartitionRecordCounter()

            var result = try await exportTextDocument(
                scope: scope, to: target,
                limit: limit,
                startAt: written,
                maxBytes: partitionBytes,
                manifestFormat: "mbox",
                onProgress: onProgress,
                rawStream: { [self] email in
                    // A streamed record (located or captured) is a record of this partition too.
                    let plan = try await self.mboxStreamPlan(for: email, connected: connected)
                    if plan != nil { counter.count += 1 }
                    return plan
                }
            ) { email, _ in
                counter.count += 1
                return Self.mboxRecord(for: email)
            }
            let recordsThisPartition = counter.count
            if recordsThisPartition > 0 { result = await withContainerProvenanceSidecar(result, container: target) }

            if recordsThisPartition == 0 {
                // The scope ended exactly on the previous cap: nothing to
                // write, so no empty file is left for a mail client to trip on.
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.removeItem(at: ContainerManifest.url(for: target))
                break
            }
            results.append(result)
            written += recordsThisPartition
            // Under the cap means the scope ran out before the file filled.
            exhausted = result.bytesWritten < partitionBytes
            partition += 1
            if partition > 10_000 { break }   // pathological guard
        }
        return results
    }

    /// Markdown: ONE .md document — headers as a definition block, body as
    /// text — pastes cleanly into Notes/Obsidian/GitHub. Streamed.
    @discardableResult
    func exportMarkdownArchive(scope: ArchiveSelectionScope, to url: URL,
                               limit: Int? = nil,
                               write options: ExportWriteOptions = ExportWriteOptions(),
                               onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try await exportTextDocument(
            scope: scope, to: url, limit: limit, write: options,
            header: { total in "# mailin email export — \(total) email(s)\n\n" },
            onProgress: onProgress
        ) { email, index in
            var block = "---\n\n## \(index + 1). \(email.headers["Subject"] ?? "(No Subject)")\n\n"
            for (label, key) in [("From", "From"), ("To", "To"), ("Cc", "Cc"), ("Date", "Date")] {
                if let value = email.headers[key], !value.isEmpty {
                    block += "**\(label):** \(value)  \n"
                }
            }
            block += "\n" + email.plainBody + "\n\n"
            return block
        }
    }

    /// Attachment bulk save: streams the scope and copies each attachment file.
    /// `maxAttachments` is the free-tier cap (nil = unlimited).
    func exportAttachments(scope: ArchiveSelectionScope, to folder: URL,
                           maxAttachments: Int? = nil,
                           onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> (saved: Int, capped: Bool) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = 0, emailsDone = 0
        let total = try await archive.count(scope: scope)
        for try await batch in archive.streamSelected(scope: scope) {
            try Task.checkCancellation()
            for email in batch {
                for (attIndex, att) in email.attachments.enumerated() {
                    if let maxAttachments, saved >= maxAttachments { return (saved, true) }
                    guard let source = att.fileURL else { continue }
                    let safeName = att.filename
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "\\", with: "_")
                        .replacingOccurrences(of: "..", with: "_")
                    var target = folder.appendingPathComponent(safeName)
                    if FileManager.default.fileExists(atPath: target.path) {
                        target = folder.appendingPathComponent("\(saved + 1)_\(attIndex)_\(safeName)")
                    }
                    do {
                        try FileUtils.copyFile(from: source, to: target)
                        saved += 1
                    } catch {
                        FileUtilsAudit.logError(error, context: "Attachment Export", path: target.path)
                    }
                }
                emailsDone += 1
            }
            onProgress?(emailsDone, total)
        }
        return (saved, false)
    }

    // MARK: - PST parts (§3-H9)

    /// The largest part this destination accepts: the volume's maximum file
    /// size when the filesystem reports one (FAT32: 4 GB − 1), else 45 GB —
    /// under the PST format's 50 GB ceiling with room for the final index.
    static func pstPartBytes(for directory: URL) -> UInt64 {
        let formatSafe: UInt64 = 45_000_000_000
        if let max = (try? directory.resourceValues(forKeys: [.volumeMaximumFileSizeKey]))?.volumeMaximumFileSize,
           max > 0 {
            // Leave 5 % for the B-trees written at finalize.
            return min(formatSafe, UInt64(Double(max) * 0.95))
        }
        return formatSafe
    }

    /// Streams the scope into numbered PST files, each a complete, valid PST
    /// below `partBytes`. Returns the files and messages per file.
    func exportPSTParts(scope: ArchiveSelectionScope,
                        toDirectory directory: URL,
                        baseName: String = "archive",
                        partBytes: UInt64? = nil,
                        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> [(url: URL, messages: Int)] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let limit = partBytes ?? Self.pstPartBytes(for: directory)
        let total = try await archive.count(scope: scope)
        var parts: [(url: URL, messages: Int)] = []
        var part = 1
        var done = 0
        // R3: each part carries its own expected-record manifest.
        func newWriter() throws -> (PSTStreamWriting, URL, ContainerManifest.Writer) {
            let url = directory.appendingPathComponent(String(format: "%@-%04d.pst", baseName, part))
            return (try PSTWriterFactory.make(url: url), url, try ContainerManifest.Writer(creatingFor: url, format: "pst", startPosition: done))
        }
        var (writer, url, manifest) = try newWriter()
        var inPart = 0
        do {
            for try await batch in archive.streamSelected(scope: scope) {
                try Task.checkCancellation()
                for email in batch {
                    if inPart > 0, writer.dataBytesWritten >= limit {
                        let n = try writer.finalize()
                        try manifest.finish(positions: done, bytes: nil, sha256: nil)
                        manifest.close()
                        parts.append((url, n))
                        part += 1
                        (writer, url, manifest) = try newWriter()
                        inPart = 0
                    }
                    try writer.appendMessage(email)
                    try manifest.record(position: done, email: email, folder: Self.primaryFolderFirst(SQLiteEmailStore.folderPaths(for: email)).first, offset: nil, length: nil)
                    inPart += 1
                    done += 1
                }
                try manifest.flush()
                onProgress?(done, total)
            }
            if inPart > 0 {
                parts.append((url, try writer.finalize()))
                try manifest.finish(positions: done, bytes: nil, sha256: nil)
                manifest.close()
            } else {
                writer.abort()
                manifest.remove()
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            writer.abort()
            manifest.remove()
            throw error
        }
        // Every part is complete here; a sidecar that cannot be written is
        // this export's error (the caller reports it), never a silence.
        for part in parts { try await writeContainerProvenanceSidecar(container: part.url) }
        return parts
    }

    // MARK: - PST (streaming, uncapped)

    /// Streams the whole scope into a PST file on disk. Memory stays bounded
    /// (one batch + B-tree bookkeeping); message count is unlimited. The only
    /// size ceiling is the PST format's own 50 GB, surfaced as an error.
    func exportPST(scope: ArchiveSelectionScope,
                   to url: URL,
                   onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let total = try await archive.count(scope: scope)
        let writer = try PSTWriterFactory.make(url: url)
        // R3: the expected-record manifest beside the PST.
        let manifest: ContainerManifest.Writer
        do { manifest = try ContainerManifest.Writer(creatingFor: url, format: "pst", startPosition: 0) } catch {
            writer.abort()
            throw error
        }
        let written: Int
        do {
            var done = 0
            for try await batch in archive.streamSelected(scope: scope) {
                try Task.checkCancellation()
                for email in batch {
                    try writer.appendMessage(email)
                    try manifest.record(position: done, email: email, folder: Self.primaryFolderFirst(SQLiteEmailStore.folderPaths(for: email)).first, offset: nil, length: nil)
                    done += 1
                }
                try manifest.flush()
                onProgress?(done, total)
            }
            written = try writer.finalize()
            try manifest.finish(positions: done, bytes: nil, sha256: nil)
            manifest.close()
        } catch {
            writer.abort()
            manifest.remove()
            throw error
        }
        // The PST is complete here; a sidecar that cannot be written is this
        // export's error (the caller reports it), never a silence.
        try await writeContainerProvenanceSidecar(container: url)
        return written
    }
}

/// Records written into one mbox partition, by either the streamed or the rendered path.
@MainActor
final class PartitionRecordCounter {
    var count = 0
}
