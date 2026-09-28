//
//  ArchiveSelectionScope.swift
//  maxmailin
//
//  Stage 5 Wave 1E (v2-core-cutover): symbolic selection that scales. A user's
//  explicit taps stay an `Set<EmailID>`, but "Select All" over a million-message
//  result becomes `.query(...)` — never a million-element Set. Every downstream
//  bulk operation (export / delete / review) consumes an `ArchiveSelectionScope`
//  and streams it, so bulk actions stay as bounded as the list itself.
//

import Foundation
import CryptoKit

enum ArchiveSelectionScope: Sendable, Equatable, Codable {
    case none
    /// A small, explicitly user-selected set of ids.
    case explicit(Set<EmailID>)
    /// Every email matching `query`, minus `exclusions` the user deselected.
    case query(EmailQuery, exclusions: Set<EmailID>)

    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .explicit(let ids): return ids.isEmpty
        case .query: return false   // resolved lazily; assume non-empty
        }
    }
}

extension ArchiveDataService {
    /// Exact number of emails a selection scope resolves to.
    func count(scope: ArchiveSelectionScope) async throws -> Int {
        switch scope {
        case .none:
            return 0
        case .explicit(let ids):
            return ids.count
        case .query(let query, let exclusions):
            let total = try await count(query: query)
            // §15: subtract ONLY exclusions that actually belong to the query —
            // a deselected id that no longer matches (or was deleted) must not
            // shrink the count. Exclusions are a bounded user set, so this is
            // one bounded verification pass, never a result materialization.
            guard !exclusions.isEmpty else { return total }
            let matching = try await matchingIDs(among: Array(exclusions), query: query)
            return max(0, total - matching.count)
        }
    }

    /// Stream the selected full emails in bounded pages — the safe basis for
    /// export/delete/review over a whole-query "Select All" at any scale.
    /// Audit F08: what a resumed export must match. A positional resume
    /// ("skip the first N") is only correct while the selection has the same
    /// members in the same order; this fingerprints the ids in export order
    /// so a receipt can refuse to resume over a changed archive. Ids only —
    /// the summaries page is read, never the bodies.
    func selectionFingerprint(scope: ArchiveSelectionScope) async throws -> String {
        var digest = SHA256()
        var count = 0
        func add(_ id: EmailID) {
            withUnsafeBytes(of: id.uuid) { digest.update(bufferPointer: $0) }
            count += 1
        }
        switch scope {
        case .none:
            break
        case .explicit(let ids):
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) { add(id) }
        case .query(let query, let exclusions):
            var cursor: EmailPageCursor? = nil
            repeat {
                let page = try await self.page(query: query, cursor: cursor, limit: 1_000)
                for summary in page.summaries where !exclusions.contains(summary.id) { add(summary.id) }
                cursor = page.nextCursor
            } while cursor != nil
        }
        return "\(count):" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func streamSelected(scope: ArchiveSelectionScope, batchSize: Int = 200) -> AsyncThrowingStream<[MBOXParser.RawEmail], Error> {
        switch scope {
        case .none:
            return AsyncThrowingStream { $0.finish() }
        case .explicit(let ids):
            // A8: a stable order, so an export resumed from a receipt skips
            // exactly the messages the interrupted run already wrote.
            let idList = ids.sorted { $0.uuidString < $1.uuidString }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var i = 0
                        while i < idList.count {
                            if Task.isCancelled { break }
                            let slice = Array(idList[i..<min(i + batchSize, idList.count)])
                            let emails = try await self.fullEmails(ids: slice)
                            continuation.yield(emails)
                            i += batchSize
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        case .query(let query, let exclusions):
            let base = streamFullEmails(query: query, batchSize: batchSize)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await batch in base {
                            if Task.isCancelled { break }
                            let filtered = exclusions.isEmpty ? batch : batch.filter { !exclusions.contains($0.id) }
                            if !filtered.isEmpty { continuation.yield(filtered) }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
