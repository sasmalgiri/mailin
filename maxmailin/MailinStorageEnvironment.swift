//
//  MailinStorageEnvironment.swift
//  maxmailin
//
//  Stage 3.1.7 (v2-core-cutover): an injectable storage environment so the
//  Stage 4 stress harness measures an ISOLATED, disposable database and can
//  NEVER read, alter, migrate, clear, or vacuum the real user's Mailin store.
//  This is a hard safety gate, not a debug convenience — it is Release-safe
//  (no `#if DEBUG`), because the stress harness runs in Release.
//
//  Production code continues to use `.production` (the shared singletons over
//  the real Application Support locations). Harnesses/tests use
//  `disposable(at:)`, which refuses any root that resolves onto the production
//  storage directory.
//

import Foundation

enum StorageEnvironmentError: Error, Sendable, Equatable {
    /// A disposable environment was asked to root itself on (or inside) the
    /// real user's production storage directory. Refused — the harness must
    /// never touch production data.
    case refusedProductionPath(String)
}

/// A self-contained storage triple (store + FTS index + repository) rooted at a
/// single location. The production environment uses the shared singletons; a
/// disposable environment uses freshly-constructed instances under an isolated
/// directory.
/// Which canonical-store engine a disposable environment uses. Production is
/// migrating to `.sqlite` (direct SQLite/blob) because the stress harness
/// proved SwiftData's import is O(N²) and its keyset paging O(N) on the
/// shipping deployment target; `.swiftData` is retained for A/B measurement.
enum StorageEngine: Sendable {
    case sqlite
    case swiftData
}

struct MailinStorageEnvironment: Sendable {
    let store: any EmailArchiveStore
    let fts: FTSSearchIndex
    let repository: EmailStoreRepository
    /// nil for the production environment (default OS locations); the isolated
    /// root for a disposable environment.
    let root: URL?
    /// True only for the single shared production environment. The harness
    /// asserts this is false before running.
    let isProduction: Bool

    /// The one environment over the real user data. Read/written by the app.
    static let production = MailinStorageEnvironment(
        store: EmailStore.shared,
        fts: .shared,
        repository: .shared,
        root: nil,
        isProduction: true
    )

    /// An isolated, disposable environment rooted at `root`. Every store /
    /// index file lives under `root`, so deleting `root` fully disposes of it.
    /// `engine` selects the canonical-store implementation under test.
    ///
    /// Throws `StorageEnvironmentError.refusedProductionPath` if `root`
    /// resolves onto (equals, contains, or is contained by) the production
    /// storage directory — the hard safety gate.
    static func disposable(at root: URL, engine: StorageEngine = .sqlite) throws -> MailinStorageEnvironment {
        try assertNotProduction(root)
        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        let store: any EmailArchiveStore
        switch engine {
        case .sqlite:    store = SQLiteEmailStore(directory: storeDir)
        case .swiftData: store = EmailStore(storeDirectory: storeDir)
        }
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let repo = EmailStoreRepository(store: store, fts: fts)
        return MailinStorageEnvironment(
            store: store, fts: fts, repository: repo, root: root, isProduction: false
        )
    }

    /// The real production storage directory: `<AppSupport>/com.ecosanskriti.mailin`.
    /// Both the SwiftData store and the FTS shards live under this tree.
    static var productionStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
    }

    /// Refuse any root that overlaps the production storage tree in either
    /// direction (equal, ancestor, or descendant). Path comparison is done on
    /// standardized, resolved file paths so `..`/symlink tricks can't slip a
    /// production path past the gate.
    static func assertNotProduction(_ root: URL) throws {
        let prod = productionStorageDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = root.standardizedFileURL.resolvingSymlinksInPath().path
        // Compare with a trailing separator so "/a/mailin2" isn't treated as a
        // child of "/a/mailin".
        let prodPrefix = prod.hasSuffix("/") ? prod : prod + "/"
        let candPrefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
        let overlaps = candidate == prod
            || candPrefix.hasPrefix(prodPrefix)   // candidate is inside production
            || prodPrefix.hasPrefix(candPrefix)   // production is inside candidate
        if overlaps {
            throw StorageEnvironmentError.refusedProductionPath(candidate)
        }
    }
}
