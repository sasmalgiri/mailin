//
//  ChildHashRepair.swift
//  ArchiveCore
//
//  Completion directive §2 "Repair persisted child hashes". Until 3fd934f
//  (2026-11-07) the files INSIDE an attached message (.eml, .msg/.oft,
//  winmail.dat) were recorded in `attachment_children` with a DOUBLE hash —
//  `hex(Data(SHA256.hash(data)))`, the SHA-256 of the SHA-256 — while every
//  other child carried `hex(data)`. The code was fixed but the extractor
//  version stayed 7, so a completed row of version 7 still holds the wrong
//  derived hash, and the index's own re-queue (rows BELOW 7) never reaches it.
//
//  This is the explicit, versioned migration:
//
//    SELECT   completed messages (an `attachment_text_state` row) whose
//             children sit under a MESSAGE-kind attachment recorded at
//             extractor version ≤ 7 — the affected code path, by version and
//             by kind, not by import date and not by "bump and hope".
//    RECOMPUTE from the preserved bytes: the parent attachment is hydrated
//             from the stored raw source, parsed again with the same readers,
//             and each child's bytes hashed once.
//    REPLACE  the derived hash — only when the stored value IS the double
//             hash of those bytes — in one transaction per message; the
//             child's text documents (evidence), the parent attachment's own
//             `content_hash` (original hash), the message's id and every
//             export receipt are untouched.
//    MARK     a child whose bytes cannot be read back "hash unverifiable" in
//             its note; a hash is never invented.
//    RECORD   rows checked / repaired / unverifiable / failed with a cursor,
//             so an interrupted repair resumes where it stopped and never
//             processes a message twice (`attachmentIndex.childHashRepair`,
//             beside `attachmentIndex.lastRebuild`).
//

import Foundation
import CryptoKit
import SQLite3

// MARK: - Store side

extension SQLiteEmailStore {

    /// SQL for "this attachment is a message": by name, by MIME type.
    nonisolated static let messageAttachmentSQL = """
        (lower(a.filename) LIKE '%.eml' OR lower(a.filename) LIKE '%.msg' OR lower(a.filename) LIKE '%.oft' OR lower(a.filename) = 'winmail.dat'
         OR lower(a.mime_type) LIKE '%rfc822%' OR lower(a.mime_type) LIKE '%vnd.ms-outlook%' OR lower(a.mime_type) LIKE '%ms-tnef%')
        """

    /// Messages, in id order after `cursor`, whose attachment index is
    /// complete and whose children under a message-kind attachment were
    /// recorded by an extractor of version ≤ `maxExtractorVersion` (a parent
    /// attachment without a search document counts as version 0).
    func childHashRepairPage(after cursor: UUID?, maxExtractorVersion: Int, limit: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT DISTINCT e.id FROM emails e
            JOIN attachment_text_state s ON s.email_id = e.id
            JOIN attachment_children c ON c.email_id = e.id
            JOIN attachments a ON a.email_id = e.id AND a.position = c.position
            LEFT JOIN search_docs d ON d.email_id = e.id AND d.kind IN (\(SearchDocKind.attachmentContentSQL)) AND d.ordinal = c.position
            WHERE e.id > ? AND COALESCE(d.extractor_version, 0) <= ? AND \(Self.messageAttachmentSQL)
            ORDER BY e.id LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, cursor?.uuidString ?? "")
        sqlite3_bind_int64(stmt, 2, Int64(maxExtractorVersion))
        sqlite3_bind_int64(stmt, 3, Int64(limit))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = UUID(uuidString: columnText(stmt, 0)) { out.append(id) } }
        return out
    }

    /// Positions of this message's attachments that are messages themselves.
    func messageAttachmentPositions(emailID: UUID) throws -> Set<Int> {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT a.position FROM attachments a WHERE a.email_id = ? AND \(Self.messageAttachmentSQL);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString)
        var out = Set<Int>()
        while try stepRow(stmt, db) { out.insert(Int(sqlite3_column_int64(stmt, 0))) }
        return out
    }

    struct ChildHashUpdate: Sendable, Equatable {
        let position: Int
        let childIndex: Int
        /// The corrected hash; nil leaves the stored value.
        let sha256: String?
        /// The new note; nil leaves the stored value.
        let note: String?
    }

    /// Applies every update of one message in ONE transaction: the row set is
    /// corrected whole or not at all. Only `sha256` and `note` can change.
    func repairAttachmentChildHashes(emailID: UUID, updates: [ChildHashUpdate]) throws {
        guard !updates.isEmpty else { return }
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let stmt = try prepare(db, """
                UPDATE attachment_children SET sha256 = COALESCE(?, sha256), note = COALESCE(?, note)
                WHERE email_id = ? AND position = ? AND child_index = ?;
            """)
            defer { sqlite3_finalize(stmt) }
            for update in updates {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindTextOrNull(stmt, 1, update.sha256)
                bindTextOrNull(stmt, 2, update.note)
                bindText(stmt, 3, emailID.uuidString)
                sqlite3_bind_int64(stmt, 4, Int64(update.position))
                sqlite3_bind_int64(stmt, 5, Int64(update.childIndex))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }
}

// MARK: - The migration

enum ChildHashRepair {

    /// Bump when another derived-hash fault needs a pass; `Record.version`
    /// below this runs again from the start.
    static let currentVersion = 1
    /// The last extractor version whose attached-message children were double-hashed.
    static let lastAffectedExtractorVersion = 7
    /// Messages nest this deep in the index (AttachmentTextIndexJob.maxMessageDepth).
    static var maxMessageDepth: Int { ExtractionLimits.base.messageDepth }
    static let recordKey = "attachmentIndex.childHashRepair"
    static let unverifiableMarker = "hash unverifiable"
    static let pageSize = 200

    /// The persisted state: a receipt that is also the resume point.
    struct Record: Codable, Sendable, Equatable {
        var version: Int
        /// The archive this record is about (a different store starts fresh).
        var storePath: String
        var completed = false
        /// Last message processed; the next run continues after it.
        var cursor: UUID?
        var messages = 0
        var rowsChecked = 0
        var rowsRepaired = 0
        /// Rows whose child bytes could not be read back: marked, never changed.
        var rowsUnverifiable = 0
        var rowsFailed = 0
        var startedAt: Date
        var updatedAt: Date
    }

    /// What ONE run did (the record accumulates across runs).
    struct Receipt: Sendable, Equatable {
        var messages = 0
        var rowsChecked = 0
        var rowsRepaired = 0
        var rowsUnverifiable = 0
        var rowsFailed = 0
        var completed = false
        /// True when the record already said completed for this version and store: nothing was read.
        var alreadyDone = false

        var line: String {
            "rows checked \(rowsChecked) · repaired \(rowsRepaired) · unverifiable \(rowsUnverifiable) · failed \(rowsFailed) · messages \(messages)" + (completed ? " · complete" : " · not finished")
        }
    }

    static func record(defaults: UserDefaults = .standard) -> Record? {
        guard let data = defaults.data(forKey: recordKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: recordKey) }
    }

    /// "Child file hashes (reader 7 fault): 1,204 rows checked, 310 repaired, 2 unverifiable, on 7 Nov 2026."
    static func reportText(_ record: Record?) -> String? {
        guard let record, record.rowsChecked > 0 || record.rowsUnverifiable > 0 else { return nil }
        let when = record.updatedAt.formatted(date: .abbreviated, time: .omitted)
        let suffix = record.completed ? "" : String(localized: " Not finished — continues at the next pass.")
        return String(localized: "Hashes of files inside attached messages: \(record.rowsChecked.formatted()) rows checked, \(record.rowsRepaired.formatted()) repaired, \(record.rowsUnverifiable.formatted()) unverifiable, last on \(when).\(suffix)")
    }

    /// Runs (or resumes) the repair. `stopAfterMessages` is a test seam that
    /// interrupts the run after that many messages, leaving the record
    /// incomplete with its cursor; cancellation does the same.
    static func run(store: SQLiteEmailStore, defaults: UserDefaults = .standard, stopAfterMessages: Int? = nil,
                    now: Date = Date()) async -> Receipt {
        var receipt = Receipt()
        let path = store.storeDirectory.path
        var state: Record
        if let existing = Self.record(defaults: defaults), existing.version == currentVersion, existing.storePath == path {
            if existing.completed { receipt.completed = true; receipt.alreadyDone = true; return receipt }
            state = existing
        } else {
            state = Record(version: currentVersion, storePath: path, startedAt: now, updatedAt: now)
        }
        var cursor = state.cursor
        outer: while !Task.isCancelled {
            let page: [UUID]
            do { page = try await store.childHashRepairPage(after: cursor, maxExtractorVersion: lastAffectedExtractorVersion, limit: pageSize) }
            catch { receipt.rowsFailed += 1; state.rowsFailed += 1; break }
            if page.isEmpty { state.completed = true; receipt.completed = true; break }
            for id in page {
                if Task.isCancelled { break outer }
                if let stop = stopAfterMessages, receipt.messages >= stop { break outer }
                let outcome = await repair(store: store, emailID: id)
                receipt.messages += 1; state.messages += 1
                receipt.rowsChecked += outcome.checked; state.rowsChecked += outcome.checked
                receipt.rowsRepaired += outcome.repaired; state.rowsRepaired += outcome.repaired
                receipt.rowsUnverifiable += outcome.unverifiable; state.rowsUnverifiable += outcome.unverifiable
                receipt.rowsFailed += outcome.failed; state.rowsFailed += outcome.failed
                cursor = id
                state.cursor = id
                state.updatedAt = Date()
                save(state, defaults: defaults)
            }
        }
        state.updatedAt = Date()
        save(state, defaults: defaults)
        return receipt
    }

    struct MessageOutcome: Equatable {
        var checked = 0, repaired = 0, unverifiable = 0, failed = 0
    }

    /// One message: recompute every child under its message attachments.
    static func repair(store: SQLiteEmailStore, emailID: UUID) async -> MessageOutcome {
        var outcome = MessageOutcome()
        do {
            let rows = try await store.attachmentChildren(forEmailID: emailID)
            let positions = try await store.messageAttachmentPositions(emailID: emailID)
            let candidates = rows.filter { positions.contains($0.position) }
            guard !candidates.isEmpty else { return outcome }
            let email = try await store.fullEmail(id: emailID)
            let cache = AttachmentHydrator.Cache()
            var bytesByPosition: [Int: [String: [Data]]] = [:]
            if let email {
                for position in positions where position < email.attachments.count {
                    let attachment = email.attachments[position]
                    guard let data = AttachmentHydrator.data(for: attachment, index: position, email: email, cache: cache) else { continue }
                    var map: [String: [Data]] = [:]
                    collectMessageChildren(data: data, filename: attachment.filename, mimeType: attachment.mimeType, prefix: "", depth: 0, into: &map)
                    bytesByPosition[position] = map
                }
            }
            var updates: [SQLiteEmailStore.ChildHashUpdate] = []
            var taken: [String: Int] = [:]   // "<position>|<path>" → how many same-path children already paired
            for row in candidates {
                let key = "\(row.position)|\(row.path)"
                let index = taken[key, default: 0]
                taken[key] = index + 1
                guard let map = bytesByPosition[row.position] else {
                    // The parent's bytes are not retrievable: nothing to recompute from.
                    outcome.unverifiable += 1
                    updates.append(mark(row, "\(unverifiableMarker): the attached message's bytes are not available"))
                    continue
                }
                guard let list = map[row.path], index < list.count else {
                    // Rows whose container is not a message (a zip inside the message) are not this fault's rows.
                    if isUnderMessageContainer(path: row.path, map: map) {
                        outcome.unverifiable += 1
                        updates.append(mark(row, "\(unverifiableMarker): the file was not found inside the attached message when read again"))
                    }
                    continue
                }
                let data = list[index]
                let correct = ExportFolderManifest.hex(data)
                let double = ExportFolderManifest.hex(Data(SHA256.hash(data: data)))
                if row.sha256 == correct {
                    outcome.checked += 1
                } else if row.sha256 == double {
                    outcome.checked += 1
                    outcome.repaired += 1
                    updates.append(SQLiteEmailStore.ChildHashUpdate(position: row.position, childIndex: row.childIndex, sha256: correct, note: nil))
                } else {
                    outcome.unverifiable += 1
                    updates.append(mark(row, "\(unverifiableMarker): the recorded hash matches neither the file's bytes nor the known fault"))
                }
            }
            try await store.repairAttachmentChildHashes(emailID: emailID, updates: updates)
        } catch {
            outcome.failed += 1
        }
        return outcome
    }

    private static func mark(_ row: AttachmentChildRow, _ marker: String) -> SQLiteEmailStore.ChildHashUpdate {
        let note: String
        if let existing = row.note, existing.contains(unverifiableMarker) { note = existing }
        else if let existing = row.note, !existing.isEmpty { note = existing + "; " + marker }
        else { note = marker }
        return SQLiteEmailStore.ChildHashUpdate(position: row.position, childIndex: row.childIndex, sha256: nil, note: note)
    }

    /// True when every container on the row's path is a message in `map` (so
    /// the row was written by the affected code path and SHOULD be there).
    private static func isUnderMessageContainer(path: String, map: [String: [Data]]) -> Bool {
        let parts = path.components(separatedBy: " › ")
        guard parts.count > 1 else { return true }   // a direct child of the attached message
        var prefix = ""
        for part in parts.dropLast() {
            let container = prefix + part
            guard let datas = map[container], let data = datas.first, parseMessage(data, filename: part, mimeType: "") != nil else { return false }
            prefix = container + " › "
        }
        return true
    }

    /// The bytes of every child of an attached message, keyed by the index's
    /// path ("inner.eml › terms.docx"); nested messages are followed to the
    /// same depth the index uses. Same-named children keep their order.
    static func collectMessageChildren(data: Data, filename: String, mimeType: String, prefix: String, depth: Int, into map: inout [String: [Data]]) {
        guard depth < maxMessageDepth, let email = parseMessage(data, filename: filename, mimeType: mimeType) else { return }
        defer { for a in email.attachments { if let url = a.fileURL { try? FileManager.default.removeItem(at: url) } } }
        for attachment in email.attachments {
            let bytes = attachment.fileURL.flatMap { try? Data(contentsOf: $0) }
                ?? attachment.base64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? Data()
            let path = prefix + attachment.filename
            map[path, default: []].append(bytes)
            collectMessageChildren(data: bytes, filename: attachment.filename, mimeType: attachment.mimeType, prefix: path + " › ", depth: depth + 1, into: &map)
        }
    }

    /// The same three readers the index uses for an attached message.
    static func parseMessage(_ data: Data, filename: String, mimeType: String) -> MBOXParser.RawEmail? {
        guard !data.isEmpty else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType.lowercased()
        if TNEFReader.isTNEF(data) || ((mime.contains("ms-tnef") || filename.lowercased() == "winmail.dat") && data.count >= 6) {
            guard let content = try? TNEFReader.read(data) else { return nil }
            let attachments = content.attachments.map { file in
                AttachmentMetadata(filename: file.filename, mimeType: file.isEmbeddedMessage ? "application/vnd.ms-outlook" : file.mimeType,
                                   size: file.data.count, base64: file.isEmbeddedMessage ? nil : file.data.base64EncodedString())
            }
            return MBOXParser.RawEmail(id: UUID(), headers: content.subject.map { ["Subject": $0] } ?? [:], rawSource: "", messageType: "received",
                                       attachments: attachments, timestamp: "", domains: [], plainBody: content.bodyText, htmlBody: "",
                                       mimeRoot: nil, mimeSummary: nil, mimeDiagnostics: [], threadID: nil, inReplyTo: nil, references: nil)
        }
        if (mime.contains("vnd.ms-outlook") || ext == "msg" || ext == "oft"),
           data.count >= 8, data[data.startIndex] == 0xD0, data[data.startIndex + 1] == 0xCF {
            return try? MSGParser.parse(data: data)
        }
        if mime.contains("message/rfc822") || ext == "eml" {
            guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
            return try? MBOXParser.processRawMessage(raw, senderEmail: "")
        }
        return nil
    }
}
