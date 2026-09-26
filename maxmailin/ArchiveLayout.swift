//
//  ArchiveLayout.swift
//  maxmailin
//
//  B5: ONE answer to "where does the production archive live". The SQLite
//  store (with its blob tier beneath it) and the FTS5 shards are siblings
//  under one root, and both resolve that root here — before this, a chosen
//  location moved the database while the search index stayed in Application
//  Support, which would have split the archive across two volumes.
//
//  Resolution rules, in order:
//    1. A VERIFIED relocation record whose destination is reachable and
//       holds `sqlite/emails.db` → the destination. This is how a moved
//       archive is found after relaunch.
//    2. An archive at the default root → the default root. The copy left on
//       this Mac after a move is never renamed or deleted automatically, so
//       a detached external volume can never make the mail vanish; the UI
//       says which copy is open.
//    3. A chosen location with a usable volume and NO archive at the default
//       root → `<chosen>/mailin-archive` (new archives are created there).
//    4. Otherwise the default root.
//

import Foundation

/// Written by `ArchiveRelocator` once a copy has been verified. Read at
/// launch by `ArchiveLayout.productionRoot`.
struct RelocationRecord: Codable, Equatable, Sendable {
    var sourceRoot: String
    var destinationRoot: String
    var verifiedAt: Date
    var rows: Int
    var bytes: Int64
    var emailsDBSHA256: String

    var destinationURL: URL { URL(fileURLWithPath: destinationRoot, isDirectory: true) }
    var sourceURL: URL { URL(fileURLWithPath: sourceRoot, isDirectory: true) }
}

struct RelocationRecordStore: Sendable {
    let url: URL

    static var production: RelocationRecordStore {
        RelocationRecordStore(url: ArchiveLayout.defaultRoot.appendingPathComponent("archive-relocation.v1.json"))
    }

    func load() -> RelocationRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RelocationRecord.self, from: data)
    }

    func save(_ record: RelocationRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum ArchiveLayout {
    static let containerName = "com.ecosanskriti.mailin"
    static let relocatedFolderName = "mailin-archive"
    static let sqliteFolder = "sqlite"
    static let ftsFolder = "fts5"

    /// `<Application Support>/com.ecosanskriti.mailin`.
    static var defaultRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent(containerName, isDirectory: true)
    }

    static func sqliteDirectory(under root: URL) -> URL { root.appendingPathComponent(sqliteFolder, isDirectory: true) }
    static func ftsDirectory(under root: URL) -> URL { root.appendingPathComponent(ftsFolder, isDirectory: true) }
    static func hasArchive(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: sqliteDirectory(under: root).appendingPathComponent("emails.db").path)
    }

    /// The root the running app uses. Resolved from the recorded location,
    /// the relocation record and what is actually on disk right now.
    static var productionRoot: URL {
        resolveRoot(defaultRoot: defaultRoot,
                    chosen: ArchiveLocationStore(url: ArchiveLocationStore.productionURL).load(),
                    relocation: RelocationRecordStore.production.load())
    }

    /// Pure resolution over the four rules above; testable with temp roots.
    static func resolveRoot(defaultRoot: URL,
                            chosen: ArchiveLocation?,
                            relocation: RelocationRecord?,
                            isUsable: (URL) -> Bool = { ArchiveLocationPolicy.verdict(for: $0).isUsable }) -> URL {
        // 1. A verified, reachable relocation wins.
        if let relocation, hasArchive(at: relocation.destinationURL),
           isUsable(relocation.destinationURL.deletingLastPathComponent()) {
            return relocation.destinationURL
        }
        // 2. The archive on this Mac.
        if hasArchive(at: defaultRoot) { return defaultRoot }
        // 3. A chosen location for a NEW archive.
        if let chosen, isUsable(chosen.url) {
            return chosen.url.appendingPathComponent(relocatedFolderName, isDirectory: true)
        }
        // 4.
        return defaultRoot
    }

    /// True when a relocation record exists but its destination is not
    /// reachable right now — the app is showing the copy left on this Mac.
    static var isShowingFallbackCopy: Bool {
        guard let record = RelocationRecordStore.production.load() else { return false }
        return !hasArchive(at: record.destinationURL) && hasArchive(at: defaultRoot)
    }
}
