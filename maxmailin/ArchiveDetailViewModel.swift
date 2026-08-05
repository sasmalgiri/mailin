//
//  ArchiveDetailViewModel.swift
//  maxmailin
//
//  Stage 5 Wave 1C (v2-core-cutover): ID-based detail hydration. Selection
//  carries only an `EmailID`; the full email (bodies + headers) is fetched on
//  demand via `ArchiveDataService.fullEmail(id:)`. A small LRU cache holds a
//  few recently-opened emails (NOT a corpus cache), and a monotonic selection
//  token discards a stale hydration so a slow older load can't replace a newer
//  selection.
//

import Foundation

@MainActor
final class ArchiveDetailViewModel: ObservableObject {
    enum State {
        case idle
        case loading(EmailID)
        case loaded(MBOXParser.RawEmail)
        case failed(EmailID, String)
    }

    @Published private(set) var state: State = .idle

    private let archive: ArchiveDataService
    let cacheLimit: Int
    private var cache: [EmailID: MBOXParser.RawEmail] = [:]
    private var lru: [EmailID] = []          // most-recent last
    private var selectionToken: UInt64 = 0

    init(archive: ArchiveDataService = .shared, cacheLimit: Int = 16) {
        self.archive = archive
        self.cacheLimit = max(1, cacheLimit)
    }

    /// Convenience for tests/UI: the id of the currently loaded email, if any.
    var loadedID: EmailID? {
        if case .loaded(let email) = state { return email.id }
        return nil
    }

    /// Select (or clear) the detail email by id. Cache hit is synchronous;
    /// otherwise hydrate on demand, discarding the result if the selection
    /// changed while in flight.
    func select(_ id: EmailID?) async {
        selectionToken &+= 1
        let token = selectionToken
        guard let id else { state = .idle; return }

        if let cached = cache[id] {
            touch(id)
            state = .loaded(cached)
            return
        }

        state = .loading(id)
        do {
            let email = try await archive.fullEmail(id: id)
            guard token == selectionToken else { return }   // superseded selection
            if let email {
                insert(id, email)
                state = .loaded(email)
            } else {
                state = .failed(id, "Email not found")
            }
        } catch {
            guard token == selectionToken else { return }
            state = .failed(id, error.localizedDescription)
        }
    }

    /// Drop an id from the cache (e.g. after it is deleted) and clear detail if
    /// it is the one showing.
    func invalidate(_ id: EmailID) {
        cache[id] = nil
        lru.removeAll { $0 == id }
        if loadedID == id { state = .idle }
    }

    func clear() {
        selectionToken &+= 1
        state = .idle
    }

    // MARK: - Bounded LRU

    private func insert(_ id: EmailID, _ email: MBOXParser.RawEmail) {
        cache[id] = email
        touch(id)
        while lru.count > cacheLimit {
            let evicted = lru.removeFirst()
            cache[evicted] = nil
        }
    }

    private func touch(_ id: EmailID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }
}
