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
        return outcome
    }
}
