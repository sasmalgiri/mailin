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

enum ArchiveSelectionScope: Sendable, Equatable {
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
            // Exclusions are a bounded user set; subtract those that actually match.
            return max(0, total - exclusions.count)
        }
    }

    /// Stream the selected full emails in bounded pages — the safe basis for
    /// export/delete/review over a whole-query "Select All" at any scale.
    func streamSelected(scope: ArchiveSelectionScope, batchSize: Int = 200) -> AsyncThrowingStream<[MBOXParser.RawEmail], Error> {
        switch scope {
        case .none:
            return AsyncThrowingStream { $0.finish() }
        case .explicit(let ids):
            let idList = Array(ids)
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
