@testable import ArchiveCore
//
//  SearchDocBackfillJob.swift
//  maxmailin
//
//  Five jobs FIND-07: fills the chunked search index for mail that was
//  stored before the index existed. Pages through emails without a body
//  document in id order (keyset, resumable by construction: whatever is
//  done stays done), reading bodies from the store — never from the
//  original file. Kicked when the switch turns on and at launch; stops at
//  cancellation and picks up where it was on the next run.
//
//  R5 (audit bf1a5b9; owner 2026-11-08 "there should be no limit at all"):
//  then a message kept by its byte range — above the full-parse ceiling, so
//  its body is in the original file — has its text STREAMED from that file
//  into its body document (`StreamedBodyIndexer`), in bounded memory, with no
//  size limit. Kicked after every import too, so a large message becomes
//  searchable without a relaunch.
//

import Foundation
import os.log

@MainActor
final class SearchDocBackfillJob {
    static let shared = SearchDocBackfillJob()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "SearchBackfill")

    /// Test seam.
    static var testStoreOverride: SQLiteEmailStore?
    static var testSuppressKicks = false
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }

    static let jobID = "search.chunkBackfill"
    static let jobLabel = "Index message text in full"
    private weak var registry: JobRegistry?
    private var task: Task<Void, Never>?

    struct Outcome: Sendable, Equatable {
        var indexed = 0
        var remaining = 0
        /// R5: messages kept by byte range whose text was streamed from the original file.
        var streamedBodies = 0
        /// R5: such messages whose original file could not be read (their body is reported not searchable).
        var streamedFailed = 0
    }

    init() {
        // R5: a new import can bring messages whose text is streamed from their original file.
        NotificationCenter.default.addObserver(forName: .parsingFinished, object: nil, queue: .main) { _ in
            Task { @MainActor in SearchDocBackfillJob.shared.kickIfNeeded() }
        }
    }

    func kickIfNeeded(registry: JobRegistry? = nil) {
        guard task == nil, !Self.testSuppressKicks, SearchChunkPolicy.isEnabled else { return }
        guard SafeMode.shared.allowsBackgroundWork else { return }
        guard BackgroundExecution.isProtectedDataAvailable else { return }
        if let registry { self.registry = registry }
        self.registry?.register(id: Self.jobID, module: .archive, label: Self.jobLabel) { [weak self] in self?.cancel() }
        task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run()
            self.task = nil
            self.registry?.finish(id: Self.jobID)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        registry?.finish(id: Self.jobID)
    }

    /// One pass: index every email without a body document, `pageSize` at a time.
    @discardableResult
    func run(pageSize: Int = 200) async -> Outcome {
        var outcome = Outcome()
        var cursor: UUID? = nil
        do {
            while !Task.isCancelled {
                let ids = try await store.searchDocsBackfillPage(after: cursor, limit: pageSize)
                guard let last = ids.last else { break }
                try await store.backfillSearchDocuments(ids: ids)
                outcome.indexed += ids.count
                cursor = last
                let remaining = try await store.searchDocsBackfillRemaining()
                outcome.remaining = remaining
                registry?.update(id: Self.jobID, detail: String(localized: "\(outcome.indexed.formatted()) messages indexed in full, \(remaining.formatted()) to go"))
            }
            outcome.remaining = try await store.searchDocsBackfillRemaining()
        } catch {
            Self.logger.error("search backfill stopped: \(error.localizedDescription, privacy: .public)")
        }
        // R5: the text of every message kept by its byte range, streamed from its original file.
        if !Task.isCancelled {
            let pass = await StreamedBodyIndexer().indexPending(store: store) { [weak self] progress in
                await self?.reportStreamed(progress)
            }
            outcome.streamedBodies = pass.indexed
            outcome.streamedFailed = pass.failed
            if pass.failed > 0 { Self.logger.error("streamed bodies: \(pass.failed) original file(s) could not be read") }
        }
        return outcome
    }

    private func reportStreamed(_ progress: StreamedBodyIndexer.PassOutcome) {
        registry?.update(id: Self.jobID, detail: String(localized: "\(progress.indexed.formatted()) large messages read from their original files for search"))
    }
}
