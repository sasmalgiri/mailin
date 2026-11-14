//
//  FolderModel.swift
//  ArchiveCore
//
//  Five jobs FOLD-02: folders are first-class. Until now a folder was a flat
//  tag string in `email_tags`, with no source, no parent, no way to list a
//  folder that holds no message, and "Inbox" from two archives was one row.
//
//  Schema v21 (additive, snapshot first as for every upgrade):
//    folders(folder_id, source_id, path, name, parent_id, declared)
//      one row per (source, "/"-separated path); `declared` = the source
//      itself lists this folder (a PST folder node, a mailbox directory),
//      so an empty folder is kept; 0 = known only from its messages.
//      source_id 0 = rows imported before sources had identity.
//    email_folders(email_id, folder_id)
//      memberships — a message in two Gmail labels is one email with two
//      rows here, never two emails.
//
//  Dual write (rule 16): every membership is also written to `email_tags`
//  as before, so the previous sidebar, the `tag:` operator and a rollback
//  see the same data. Existing archives are backfilled from `email_tags`
//  at the upgrade (Apple Mail flag tags from older imports excluded).
//

import Foundation
import SQLite3

struct ArchiveFolderNode: Sendable, Equatable, Hashable, Identifiable {
    let folderID: Int64
    /// 0 = imported before sources had identity.
    let sourceID: Int64
    /// "/"-separated path within the source; immutable origin (FOLD-04).
    let path: String
    let name: String
    let parentID: Int64?
    /// The source lists this folder itself, so it exists even when empty.
    let declared: Bool
    /// Messages directly in this folder (memberships), not in its children.
    let messageCount: Int

    var id: Int64 { folderID }
}

extension SQLiteEmailStore {

    /// Apple Mail flag tags that older imports stored next to labels. They
    /// are not folders and are left out of the backfill.
    static let emlxFlagTags: Set<String> = ["Read", "Deleted", "Answered", "Flagged", "Draft"]

    /// v21 tables (additive, IF NOT EXISTS) and the backfill from tags.
    func createSchemaV21(_ handle: OpaquePointer) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS folders(
                folder_id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id INTEGER NOT NULL DEFAULT 0,
                path      TEXT NOT NULL,
                name      TEXT NOT NULL,
                parent_id INTEGER,
                declared  INTEGER NOT NULL DEFAULT 0,
                UNIQUE(source_id, path)
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_folders(
                email_id  TEXT NOT NULL,
                folder_id INTEGER NOT NULL,
                PRIMARY KEY(email_id, folder_id)
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_email_folders_folder ON email_folders(folder_id);")
        try backfillFolders(handle)
    }

    /// Folder memberships for every email that has none yet, from its parser
    /// tags — a page of tag rows at a time, so the upgrade's memory does not
    /// grow with the archive.
    func backfillFolders(_ db: OpaquePointer) throws {
        let insert = try prepare(db, "INSERT OR IGNORE INTO email_folders(email_id, folder_id) VALUES (?,?);")
        defer { sqlite3_finalize(insert) }
        var cache: [String: Int64] = [:]
        // `email_tags` is WITHOUT ROWID: the cursor is its (email_id, tag) key.
        var lastEmail = ""
        var lastTag = ""
        while true {
            let page = try prepare(db, """
                SELECT t.email_id, COALESCE(e.source_id, 0), t.tag, COALESCE(s.parser, '')
                FROM email_tags t JOIN emails e ON e.id = t.email_id
                LEFT JOIN sources s ON s.source_id = e.source_id
                WHERE (t.email_id > ? OR (t.email_id = ? AND t.tag > ?)) AND t.tag <> ''
                  AND NOT EXISTS (SELECT 1 FROM email_folders ef WHERE ef.email_id = t.email_id)
                ORDER BY t.email_id, t.tag LIMIT 20000;
            """)
            defer { sqlite3_finalize(page) }
            bindText(page, 1, lastEmail)
            bindText(page, 2, lastEmail)
            bindText(page, 3, lastTag)
            var rows: [(emailID: String, sourceID: Int64, tag: String, parser: String)] = []
            while try stepRow(page, db) {
                rows.append((columnText(page, 0), sqlite3_column_int64(page, 1), columnText(page, 2), columnText(page, 3)))
            }
            guard let last = rows.last else { break }
            for row in rows {
                if row.parser == "emlx", Self.emlxFlagTags.contains(row.tag) { continue }
                let fid = try folderID(db, sourceID: row.sourceID, path: row.tag, declared: false, cache: &cache)
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, row.emailID)
                sqlite3_bind_int64(insert, 2, fid)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            lastEmail = last.emailID
            lastTag = last.tag
        }
    }

    /// The folder's id, creating it and every missing parent. `declared`
    /// marks the leaf as listed by the source. `cache` saves a query per
    /// repeated path within one batch.
    func folderID(_ db: OpaquePointer, sourceID: Int64, path: String, declared: Bool,
                  cache: inout [String: Int64]) throws -> Int64 {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !components.isEmpty else { throw SQLiteStoreError.step("empty folder path") }
        var parentID: Int64? = nil
        var current = ""
        for (index, component) in components.enumerated() {
            current = current.isEmpty ? component : current + "/" + component
            let isLeaf = index == components.count - 1
            let key = "\(sourceID)|\(current)"
            if let hit = cache[key], !(isLeaf && declared) {
                parentID = hit
                continue
            }
            let upsert = try prepare(db, """
                INSERT INTO folders(source_id, path, name, parent_id, declared) VALUES (?,?,?,?,?)
                ON CONFLICT(source_id, path) DO UPDATE SET declared = MAX(folders.declared, excluded.declared)
                RETURNING folder_id;
            """)
            defer { sqlite3_finalize(upsert) }
            sqlite3_bind_int64(upsert, 1, sourceID)
            bindText(upsert, 2, current)
            bindText(upsert, 3, component)
            if let parentID { sqlite3_bind_int64(upsert, 4, parentID) } else { sqlite3_bind_null(upsert, 4) }
            sqlite3_bind_int(upsert, 5, (isLeaf && declared) ? 1 : 0)
            guard try stepRow(upsert, db) else { throw SQLiteStoreError.step(lastError(db)) }
            let id = sqlite3_column_int64(upsert, 0)
            cache[key] = id
            parentID = id
        }
        return parentID ?? 0
    }

    /// The folder memberships one email carries: its folder path, then its
    /// labels — never its flags, and never the same path twice.
    static func folderPaths(for email: MBOXParser.RawEmail) -> [String] {
        var out: [String] = []
        if let path = email.folderPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !path.isEmpty {
            out.append(path)
        }
        for tag in email.tags where !tag.isEmpty && !email.flags.contains(tag) && !out.contains(tag) {
            out.append(tag)
        }
        return out
    }

    /// Folders a source lists itself (PST folder nodes, mailbox directories),
    /// so an empty one is in the tree too.
    func registerFolders(sourceID: Int64, paths: [String]) throws {
        let clean = paths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            var cache: [String: Int64] = [:]
            for path in clean { _ = try folderID(db, sourceID: sourceID, path: path, declared: true, cache: &cache) }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Every folder with its direct message count, ordered by source then path.
    func folderNodes() throws -> [ArchiveFolderNode] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT f.folder_id, f.source_id, f.path, f.name, f.parent_id, f.declared,
                   (SELECT COUNT(*) FROM email_folders ef JOIN emails e ON e.id = ef.email_id WHERE ef.folder_id = f.folder_id)
            FROM folders f ORDER BY f.source_id, f.path;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [ArchiveFolderNode] = []
        while try stepRow(stmt, db) {
            out.append(ArchiveFolderNode(
                folderID: sqlite3_column_int64(stmt, 0), sourceID: sqlite3_column_int64(stmt, 1),
                path: columnText(stmt, 2), name: columnText(stmt, 3),
                parentID: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4),
                declared: sqlite3_column_int(stmt, 5) != 0,
                messageCount: Int(sqlite3_column_int64(stmt, 6))))
        }
        return out
    }

    func folderTotal() throws -> Int {
        try scalarInt(try ensureDB(), "SELECT COUNT(*) FROM folders;")
    }

    /// Recovery action: rebuild memberships from the tags (the dual-written
    /// record). Declared folders and the parents they hang from are kept.
    func rebuildFoldersFromTags() throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try exec(db, "DELETE FROM email_folders;")
            try exec(db, """
                DELETE FROM folders WHERE declared = 0
                  AND folder_id NOT IN (SELECT parent_id FROM folders WHERE parent_id IS NOT NULL);
            """)
            try backfillFolders(db)
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }
}
