//
//  RawSourceRecovery.swift
//  ArchiveCore
//
//  Owner-approved 2026-11-07 (item 6). Archives that imported PST, MSG or
//  NSF files before the rendered raw source (RenderedSource.swift) hold
//  messages with NO raw source — and therefore no attachment bytes: those
//  attachments cannot be opened, searched, exported or compared. This action
//  puts the bytes back from the original file:
//
//    1. find every message without a raw source, grouped by the source it
//       came from (the sources table), with the affected count per source;
//    2. locate each source: the archive's own verified copy (self-contained
//       mode) or a file the person points at; a source that is nowhere is
//       listed by name with its count — never silently skipped;
//    3. read the source again with the import's parser, match each message
//       to its row by Message-ID (else by subject and minute), and store the
//       rendered raw source for that row — no header, body, tag, note, hold
//       or folder is touched; then put the attachment index back to work.
//
//  The count is shown before anything runs (rule 4); a receipt says
//  recovered / unmatched / missing per source (rule 5).
//

import Foundation
import SQLite3

extension SQLiteEmailStore {

    struct RawlessMessage: Sendable, Equatable {
        let id: UUID
        let messageID: String?
        let subject: String
        /// Seconds since 1970, as the row stores it.
        let date: Int64
        let sourceHash: String?
    }

    /// Every message whose stored raw source is empty (no inline raw, no blob).
    func messagesWithoutRawSource() throws -> [RawlessMessage] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, e.message_id, e.subject, e.date, e.source_hash
            FROM emails e LEFT JOIN email_bodies b ON b.id = e.id
            WHERE (b.raw IS NULL OR length(b.raw) = 0) AND (b.raw_blob_digest IS NULL OR b.raw_blob_digest = '')
            ORDER BY e.source_hash, e.date;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [RawlessMessage] = []
        while try stepRow(stmt, db) {
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { continue }
            out.append(RawlessMessage(id: id,
                                      messageID: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1),
                                      subject: columnText(stmt, 2), date: sqlite3_column_int64(stmt, 3),
                                      sourceHash: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : columnText(stmt, 4)))
        }
        return out
    }

    /// Store a raw source for one message (inline, or in the blob tier when
    /// large). Only the raw columns change.
    func replaceRawSource(emailID: UUID, rawSource: String) throws {
        let db = try ensureDB()
        let data = Data(rawSource.utf8)
        var inline: Data? = data
        var digest: String? = nil
        var length: Int64 = 0
        if data.count > BlobStore.inlineThresholdBytes {
            let reference = try blobStore.write(data)
            inline = nil; digest = reference.digest; length = reference.length
        }
        let stmt = try prepare(db, "UPDATE email_bodies SET raw = ?, raw_blob_digest = ?, raw_blob_length = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, 1, inline)
        bindTextOrNull(stmt, 2, digest)
        sqlite3_bind_int64(stmt, 3, length)
        bindText(stmt, 4, emailID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }
}

enum RawSourceRecovery {

    struct SourceGroup: Sendable, Identifiable, Equatable {
        var id: String { sourceHash ?? "unknown" }
        let sourceHash: String?
        let filename: String
        let messages: [SQLiteEmailStore.RawlessMessage]
        /// The archive's verified copy of the source, when it exists.
        var fileURL: URL?
        var count: Int { messages.count }
    }

    struct Plan: Sendable, Equatable {
        var groups: [SourceGroup]
        var total: Int { groups.reduce(0) { $0 + $1.count } }
        var recoverable: Int { groups.filter { $0.fileURL != nil }.reduce(0) { $0 + $1.count } }
        var missing: Int { total - recoverable }
    }

    struct SourceResult: Sendable, Equatable {
        let filename: String
        var recovered = 0
        var unmatched = 0
        /// The file was not available (no copy, none chosen).
        var missing = false
        var failure: String?
    }

    struct Report: Sendable, Equatable {
        var sources: [SourceResult] = []
        var recovered: Int { sources.reduce(0) { $0 + $1.recovered } }
        var unmatched: Int { sources.reduce(0) { $0 + $1.unmatched } }
        var missingSources: [String] { sources.filter(\.missing).map(\.filename) }
        var recoveredIDs: [UUID] = []

        /// "Recovered 12 of 14 · 2 unmatched · 1 source not found: old.pst"
        var line: String {
            var parts = ["recovered \(recovered)"]
            if unmatched > 0 { parts.append("unmatched \(unmatched)") }
            if !missingSources.isEmpty { parts.append("source not found: \(missingSources.joined(separator: ", "))") }
            let failures = sources.compactMap(\.failure)
            if !failures.isEmpty { parts.append("failed: \(failures.joined(separator: "; "))") }
            return parts.joined(separator: " · ")
        }
    }

    /// What would be re-read, per source, with the copy that would be used.
    static func plan(store: SQLiteEmailStore) async throws -> Plan {
        let rawless = try await store.messagesWithoutRawSource()
        guard !rawless.isEmpty else { return Plan(groups: []) }
        let sources = try await store.sources()
        let byHash = Dictionary(uniqueKeysWithValues: sources.map { ($0.sha256, $0) })
        let directory = store.storeDirectory
        var groups: [SourceGroup] = []
        for (hash, messages) in Dictionary(grouping: rawless, by: { $0.sourceHash ?? "" }).sorted(by: { $0.key < $1.key }) {
            let source = byHash[hash]
            let filename = source?.filename ?? (hash.isEmpty ? "unknown source" : "source \(hash.prefix(12))…")
            var group = SourceGroup(sourceHash: hash.isEmpty ? nil : hash, filename: filename, messages: messages, fileURL: nil)
            if !hash.isEmpty, let source, !source.filename.isEmpty {
                group.fileURL = SourceCopies.existingCopy(sha256: hash, filename: source.filename, storeDirectory: directory)
            }
            groups.append(group)
        }
        return Plan(groups: groups)
    }

    /// Re-read every group that has a file (its copy, or `files[group.id]` the
    /// person chose), store the rendered raw sources, reset the attachment
    /// index for the recovered messages. Nothing else in the rows changes.
    static func run(store: SQLiteEmailStore, plan: Plan, files: [String: URL] = [:],
                    progress: (@Sendable (String) -> Void)? = nil) async -> Report {
        var report = Report()
        for group in plan.groups {
            var result = SourceResult(filename: group.filename)
            guard let fileURL = files[group.id] ?? group.fileURL else {
                result.missing = true
                result.unmatched = group.count
                report.sources.append(result)
                continue
            }
            progress?(group.filename)
            var byMessageID: [String: SQLiteEmailStore.RawlessMessage] = [:]
            var bySubjectMinute: [String: [SQLiteEmailStore.RawlessMessage]] = [:]
            for message in group.messages {
                if let id = message.messageID, !id.isEmpty { byMessageID[normalise(id)] = message }
                bySubjectMinute[subjectMinuteKey(message.subject, minute: message.date / 60), default: []].append(message)
            }
            var pending = Set(group.messages.map(\.id))
            do {
                _ = try await ParserFactory.parseStreamingCallback(fileURL: fileURL, senderEmail: "", batchSize: 100) { batch in
                    for parsed in batch {
                        guard !parsed.rawSource.isEmpty else { continue }
                        var match: SQLiteEmailStore.RawlessMessage?
                        if let id = parsed.headers["Message-ID"], let hit = byMessageID[normalise(id)], pending.contains(hit.id) {
                            match = hit
                        } else if let minute = Self.minute(of: parsed) {
                            match = bySubjectMinute[subjectMinuteKey(parsed.headers["Subject"] ?? "", minute: minute)]?.first { pending.contains($0.id) }
                        }
                        guard let row = match else { continue }
                        try await store.replaceRawSource(emailID: row.id, rawSource: parsed.rawSource)
                        pending.remove(row.id)
                        result.recovered += 1
                        report.recoveredIDs.append(row.id)
                        for attachment in parsed.attachments { if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) } }
                    }
                }
            } catch {
                result.failure = "\(group.filename): \(error.localizedDescription)"
            }
            result.unmatched = pending.count
            report.sources.append(result)
        }
        if !report.recoveredIDs.isEmpty {
            try? await store.attachmentTextStateReset(emailIDs: report.recoveredIDs)
            if let coverage = try? AttachmentCoverageStore(url: await store.attachmentCoverageURL) {
                try? coverage.remove(emailIDs: report.recoveredIDs)
            }
        }
        return report
    }

    static func normalise(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
    }

    static func subjectMinuteKey(_ subject: String, minute: Int64) -> String {
        subject.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased() + "|\(minute)"
    }

    static func minute(of email: MBOXParser.RawEmail) -> Int64? {
        if let date = ExportReconciliation.parseDate(email.timestamp) ?? ExportReconciliation.parseDate(email.headers["Date"] ?? "") {
            return Int64(date.timeIntervalSince1970) / 60
        }
        return nil
    }
}
