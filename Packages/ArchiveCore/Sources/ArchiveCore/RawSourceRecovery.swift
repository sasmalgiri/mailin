//
//  RawSourceRecovery.swift
//  ArchiveCore
//
//  Health ▸ Recovery ▸ "Recover missing imported attachments" (owner-approved
//  2026-11-07, item 6; hardened per the completion directive §2 "Recover
//  existing imports"). Archives that imported PST, OST, MSG, OFT or NSF files
//  before the rendered raw source (RenderedSource.swift) hold messages with
//  NO raw source — and therefore no attachment bytes: those attachments
//  cannot be opened, searched, exported or compared. This action puts the
//  bytes back from the original file:
//
//    1. DETECT from provenance AND availability: a message of a binary-source
//       import is affected when its stored raw source is empty OR an
//       attachment of it has no retrievable bytes (`AttachmentHydrator`);
//       intact messages of the same source are counted as already intact.
//    2. BACK UP: the archive is snapshotted (the same `VACUUM INTO` copy that
//       precedes a schema upgrade) before anything is written; the receipt
//       names the snapshot.
//    3. LOCATE AND VALIDATE: the archive's own copy, or a file the person
//       points at, is hashed and compared with the registered SHA-256. A
//       file whose hash differs is a "wrong source": nothing is written from
//       it unless a message corroborates on Message-ID AND content the row
//       itself keeps (its stored body; attachment sizes/hashes) — R4.
//    4. STAGE: the file is read again with the import's parser and every
//       proposed match is staged on disk; nothing is written until the whole
//       file has been read, so "matched by two messages" can be seen.
//    5. MATCH on more than Message-ID: Message-ID AND corroborating content
//       (subject, date to the second, from address, recipients, attachment
//       names, count and sizes, attachment hashes where stored, and the
//       normalised stored body); without a Message-ID, the source ordinal
//       plus the same corroboration. A single weak signal, or more than one
//       row, is AMBIGUOUS: listed for review with both sides, never written.
//       R4: two messages in the file that match one row but differ in body
//       or attachment payload are AMBIGUOUS too — unless the file is the
//       verified source and the row's stored source ordinal names exactly
//       one of them.
//    6. REPAIR only the raw columns: identity, folders, tags, notes, holds
//       and Trash state are untouched (`RecoveryInvariants` proves it).
//    7. LABEL: the rendered source carries `X-Mailin-Rendered` and now
//       `X-Mailin-Reconstructed: from <file> on <date>` — never presented as
//       captured wire bytes.
//    8. RECEIPT with six counts — affected, recovered, already intact,
//       ambiguous, missing source, failed — persisted as JSON.
//
//  The count is shown before anything runs (rule 4); cancellation leaves a
//  partial receipt ("X of Y sources") and no half-written rows (rule 5).
//

import Foundation
import CryptoKit
import SQLite3

// MARK: - Store side

extension SQLiteEmailStore {

    /// Kinds of import whose messages have no RFC 5322 bytes of their own
    /// (and were stored without a raw source before 2026-11-07).
    nonisolated static let binarySourceKinds: Set<String> = ["pst", "ost", "msg", "oft", "nsf"]

    struct BinarySource: Sendable, Equatable {
        let sourceID: Int64
        let sha256: String
        let filename: String
        let parser: String
        let sourceKind: String
        let byteSize: Int
    }

    /// Registered sources whose parser or kind is one of the binary mail formats.
    func binarySources() throws -> [BinarySource] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT source_id, sha256, filename, parser, source_kind, byte_size FROM sources ORDER BY imported_at DESC;")
        defer { sqlite3_finalize(stmt) }
        var out: [BinarySource] = []
        while try stepRow(stmt, db) {
            let source = BinarySource(sourceID: sqlite3_column_int64(stmt, 0), sha256: columnText(stmt, 1), filename: columnText(stmt, 2),
                                      parser: columnText(stmt, 3), sourceKind: columnText(stmt, 4), byteSize: Int(sqlite3_column_int64(stmt, 5)))
            let ext = (source.filename as NSString).pathExtension.lowercased()
            let tokens = [source.parser.lowercased(), source.sourceKind.lowercased(), ext]
            if tokens.contains(where: { Self.binarySourceKinds.contains($0) }) { out.append(source) }
        }
        return out
    }

    /// One message the recovery may have to repair: what the row stores that a
    /// re-read can be checked against.
    struct RecoveryCandidate: Sendable, Equatable {
        let id: UUID
        let messageID: String?
        let subject: String
        /// Seconds since 1970, as the row stores it.
        let date: Int64
        let from: String
        let sourceHash: String?
        let sourceOrdinal: Int64?
        let attachmentNames: [String]
        /// False when the stored raw source is empty.
        let hasRawSource: Bool
        /// R4: everything else the row keeps that a re-read is checked against.
        /// To and Cc as stored.
        var recipients: String = ""
        /// `RecoveryContent.bodyFingerprint` of the stored body (nil when the row keeps none).
        var bodyFingerprint: String? = nil
        /// Stored attachment sizes, in `attachmentNames` order (0 = not recorded).
        var attachmentSizes: [Int] = []
        /// Stored attachment SHA-256 values, in `attachmentNames` order ("" = not recorded).
        var attachmentHashes: [String] = []
    }

    /// A page of messages of the given sources (or of no registered source),
    /// in id order after `cursor`: every message whose raw source is empty,
    /// and every message with attachments (whose bytes the caller checks).
    func recoveryCandidatePage(sourceHashes: [String], includeUnregistered: Bool, after cursor: UUID?, limit: Int) throws -> [RecoveryCandidate] {
        let db = try ensureDB()
        let marks = sourceHashes.map { _ in "?" }.joined(separator: ",")
        var sourceClause = sourceHashes.isEmpty ? "0" : "e.source_hash IN (\(marks))"
        if includeUnregistered {
            sourceClause = "(\(sourceClause) OR e.source_hash IS NULL OR e.source_hash NOT IN (SELECT sha256 FROM sources))"
        }
        let stmt = try prepare(db, """
            SELECT e.id, e.message_id, e.subject, e.date, e.from_addr, e.source_hash, e.source_ordinal,
                   (b.raw IS NOT NULL AND length(b.raw) > 0) OR (b.raw_blob_digest IS NOT NULL AND b.raw_blob_digest != ''),
                   (SELECT group_concat(a.filename, char(31)) FROM (SELECT filename FROM attachments WHERE email_id = e.id ORDER BY position) a),
                   e.to_addr, e.cc_addr, b.plain, b.html,
                   (SELECT group_concat(a.size_bytes || char(30) || COALESCE(a.content_hash, ''), char(31))
                      FROM (SELECT size_bytes, content_hash FROM attachments WHERE email_id = e.id ORDER BY position) a)
            FROM emails e LEFT JOIN email_bodies b ON b.id = e.id
            WHERE e.id > ? AND (\(sourceClause))
              AND (e.has_attach = 1 OR ((b.raw IS NULL OR length(b.raw) = 0) AND (b.raw_blob_digest IS NULL OR b.raw_blob_digest = '')))
            ORDER BY e.id LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        bindText(stmt, index, cursor?.uuidString ?? ""); index += 1
        for hash in sourceHashes { bindText(stmt, index, hash); index += 1 }
        sqlite3_bind_int64(stmt, index, Int64(limit))
        var out: [RecoveryCandidate] = []
        while try stepRow(stmt, db) {
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { continue }
            let names = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? [] : columnText(stmt, 8).components(separatedBy: "\u{1F}")
            let recipients = [columnText(stmt, 9), sqlite3_column_type(stmt, 10) == SQLITE_NULL ? "" : columnText(stmt, 10)]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            let plain = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? "" : columnText(stmt, 11)
            let html = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? "" : columnText(stmt, 12)
            var sizes: [Int] = [], hashes: [String] = []
            if sqlite3_column_type(stmt, 13) != SQLITE_NULL {
                for item in columnText(stmt, 13).components(separatedBy: "\u{1F}") {
                    let parts = item.components(separatedBy: "\u{1E}")
                    sizes.append(Int(parts.first ?? "") ?? 0)
                    hashes.append(parts.count > 1 ? parts[1].lowercased() : "")
                }
            }
            var candidate = RecoveryCandidate(
                id: id,
                messageID: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1),
                subject: columnText(stmt, 2), date: sqlite3_column_int64(stmt, 3), from: columnText(stmt, 4),
                sourceHash: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : columnText(stmt, 5),
                sourceOrdinal: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6),
                attachmentNames: names, hasRawSource: sqlite3_column_int64(stmt, 7) != 0)
            candidate.recipients = recipients
            candidate.bodyFingerprint = RawSourceRecovery.RecoveryContent.bodyFingerprint(plain: plain, html: html)
            candidate.attachmentSizes = sizes
            candidate.attachmentHashes = hashes
            out.append(candidate)
        }
        return out
    }

    /// How many messages each of the given sources has in the archive.
    func messageCounts(sourceHashes: [String]) throws -> [String: Int] {
        guard !sourceHashes.isEmpty else { return [:] }
        let db = try ensureDB()
        let marks = sourceHashes.map { _ in "?" }.joined(separator: ",")
        let stmt = try prepare(db, "SELECT source_hash, COUNT(*) FROM emails WHERE source_hash IN (\(marks)) GROUP BY source_hash;")
        defer { sqlite3_finalize(stmt) }
        for (i, hash) in sourceHashes.enumerated() { bindText(stmt, Int32(i + 1), hash) }
        var out: [String: Int] = [:]
        while try stepRow(stmt, db) { out[columnText(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1)) }
        return out
    }

    /// Store a raw source for one message (inline, or in the blob tier when
    /// large). Only the raw columns change — one statement, so a row is
    /// either repaired or exactly as it was.
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

    /// Everything a repair must leave alone, read in one place so a test (and
    /// the run itself) can compare before and after.
    struct RecoveryInvariants: Sendable, Equatable {
        var messageID: String?
        var subject: String
        var date: Int64
        var sourceID: Int64?
        var sourceOrdinal: Int64?
        var headersJSON: Data?
        var folderIDs: [Int64]
        var tags: Set<String>
        var note: String?
        var held: Bool
        var trashed: Bool
    }

    func recoveryInvariants(id: UUID) throws -> RecoveryInvariants? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.message_id, e.subject, e.date, e.source_id, e.source_ordinal, b.headers_json,
                   EXISTS (SELECT 1 FROM legal_holds h WHERE h.email_id = e.id),
                   COALESCE((SELECT trashed FROM email_review_state r WHERE r.email_id = e.id), 0),
                   (SELECT note FROM email_annotations n WHERE n.email_id = e.id)
            FROM emails e LEFT JOIN email_bodies b ON b.id = e.id WHERE e.id = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard try stepRow(stmt, db) else { return nil }
        var headers: Data?
        if sqlite3_column_type(stmt, 5) != SQLITE_NULL, let bytes = sqlite3_column_blob(stmt, 5) {
            headers = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 5)))
        }
        var out = RecoveryInvariants(
            messageID: sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : columnText(stmt, 0),
            subject: columnText(stmt, 1), date: sqlite3_column_int64(stmt, 2),
            sourceID: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
            sourceOrdinal: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4),
            headersJSON: headers, folderIDs: [], tags: [], note: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : columnText(stmt, 8),
            held: sqlite3_column_int64(stmt, 6) != 0, trashed: sqlite3_column_int64(stmt, 7) != 0)
        let folders = try prepare(db, "SELECT folder_id FROM email_folders WHERE email_id = ? ORDER BY folder_id;")
        defer { sqlite3_finalize(folders) }
        bindText(folders, 1, id.uuidString)
        while try stepRow(folders, db) { out.folderIDs.append(sqlite3_column_int64(folders, 0)) }
        out.tags = try userTags(ids: [id])[id] ?? []
        return out
    }
}

// MARK: - Provenance label

/// The second header of a reconstructed raw source: where the bytes came from
/// and when — so the detail view and every export say "reconstructed", never
/// "captured".
enum RawSourceProvenance {
    static let reconstructedHeader = "X-Mailin-Reconstructed"

    struct Label: Sendable, Equatable {
        /// `X-Mailin-Rendered` value (the source format), when the text was rendered by mailin.
        var rendered: String?
        /// The file the message was re-read from.
        var sourceFilename: String?
        /// When the re-read happened.
        var date: Date?
        /// True when the file's hash differed from the registered source.
        var fromUnverifiedFile = false
        /// True when the header says the message was matched by its content (always so for an unverified file).
        var matchedByContent = false
        var isReconstructed: Bool { sourceFilename != nil }
    }

    /// Suffix of a reconstruction from a file whose hash differs (R4: such a write only happens when
    /// the message's content matched what the archive kept).
    static let unverifiedSuffix = "; file hash differs from the registered source; matched by Message-ID and content (stored body and attachments)"

    /// `X-Mailin-Reconstructed: from <file> on <ISO 8601>[; file hash differs from the registered source; matched by …]`
    static func headerValue(sourceFilename: String, date: Date, verified: Bool) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        let flat = sourceFilename.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        return "from \(flat) on \(stamp)" + (verified ? "" : unverifiedSuffix)
    }

    /// The rendered raw source with the reconstruction header inserted after
    /// the `X-Mailin-Rendered` line (or first, when that line is absent).
    static func stamp(rawSource: String, sourceFilename: String, date: Date, verified: Bool) -> String {
        let line = "\(reconstructedHeader): \(headerValue(sourceFilename: sourceFilename, date: date, verified: verified))\r\n"
        if rawSource.hasPrefix(RFC822Renderer.provenanceHeader + ":"),
           let end = rawSource.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let after = rawSource.index(after: end)
            return String(rawSource[..<after]) + line + String(rawSource[after...])
        }
        return line + rawSource
    }

    /// Reads both provenance headers from the head of a raw source.
    static func label(for rawSource: String) -> Label {
        var out = Label()
        guard !rawSource.isEmpty else { return out }
        for line in rawSource.prefix(4_096).split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).prefix(40) {
            if line.isEmpty { break }
            if line.hasPrefix(RFC822Renderer.provenanceHeader + ":") {
                out.rendered = line.dropFirst(RFC822Renderer.provenanceHeader.count + 1).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(reconstructedHeader + ":") {
                let value = line.dropFirst(reconstructedHeader.count + 1).trimmingCharacters(in: .whitespaces)
                var body = value
                if let semicolon = body.firstIndex(of: ";") {
                    let tail = body[body.index(after: semicolon)...]
                    out.fromUnverifiedFile = tail.contains("differs")
                    out.matchedByContent = tail.contains("matched by Message-ID and content")
                    body = String(body[..<semicolon])
                }
                if body.hasPrefix("from "), let range = body.range(of: " on ", options: .backwards) {
                    out.sourceFilename = String(body[body.index(body.startIndex, offsetBy: 5)..<range.lowerBound])
                    out.date = ISO8601DateFormatter().date(from: String(body[range.upperBound...]))
                } else {
                    out.sourceFilename = body
                }
            }
        }
        return out
    }
}

// MARK: - The action

enum RawSourceRecovery {

    /// One source and the affected messages it has to answer for.
    struct SourceGroup: Sendable, Identifiable, Equatable {
        var id: String { sourceHash ?? "unknown" }
        let sourceHash: String?
        let sourceID: Int64?
        let filename: String
        let messages: [SQLiteEmailStore.RecoveryCandidate]
        /// Messages of this source whose source and bytes are in place.
        let alreadyIntact: Int
        /// The archive's verified copy of the source, when it exists.
        var fileURL: URL?
        var count: Int { messages.count }
    }

    struct Plan: Sendable, Equatable {
        var groups: [SourceGroup]
        /// Messages affected (no raw source, or attachment bytes not retrievable).
        var total: Int { groups.reduce(0) { $0 + $1.count } }
        var recoverable: Int { groups.filter { $0.fileURL != nil }.reduce(0) { $0 + $1.count } }
        var missing: Int { total - recoverable }
        /// Sources with at least one affected message.
        var affectedGroups: [SourceGroup] { groups.filter { $0.count > 0 } }
        var alreadyIntact: Int { groups.reduce(0) { $0 + $1.alreadyIntact } }
    }

    /// A match the run would not write: both sides, for review.
    struct AmbiguousItem: Codable, Sendable, Equatable {
        var emailID: UUID
        var storedSubject: String
        var storedDate: Date
        var storedFrom: String
        var fileSubject: String
        var fileDate: Date?
        var fileFrom: String
        var reason: String
        /// R4: positions in the file of every message proposed for this row (when more than one).
        var fileOrdinals: [Int]? = nil
    }

    struct SourceResult: Codable, Sendable, Equatable {
        var filename: String
        var affected = 0
        var recovered = 0
        var ambiguous = 0
        /// Affected rows the file did not account for (no proposal at all).
        var unmatched = 0
        var alreadyIntact = 0
        /// The file was not available (no copy, none chosen).
        var missing = false
        /// The file's SHA-256 differed from the registered source.
        var wrongSource = false
        /// Reading stopped before the file ended (the person cancelled).
        var cancelled = false
        var failure: String?
        /// SHA-256 of the file actually read.
        var fileSHA256: String?
    }

    /// The six counts, per run, persisted as JSON (`RawSourceRecoveryReceiptStore`).
    struct Receipt: Codable, Sendable, Equatable {
        var startedAt: Date
        var completedAt: Date
        var snapshotPath: String?
        var sources: [SourceResult] = []
        var ambiguousItems: [AmbiguousItem] = []
        var cancelled = false
        var recoveredIDs: [UUID] = []

        var affected: Int { sources.reduce(0) { $0 + $1.affected } }
        var recovered: Int { sources.reduce(0) { $0 + $1.recovered } }
        var alreadyIntact: Int { sources.reduce(0) { $0 + $1.alreadyIntact } }
        var ambiguous: Int { sources.reduce(0) { $0 + $1.ambiguous } }
        /// Affected messages whose source file was not available.
        var missingSource: Int { sources.filter(\.missing).reduce(0) { $0 + $1.affected } }
        var missingSources: [String] { sources.filter(\.missing).map(\.filename) }
        var wrongSources: [String] { sources.filter(\.wrongSource).map(\.filename) }
        /// Sources that had something to read.
        var sourcesWithWork: Int { sources.filter { $0.affected > 0 }.count }
        /// Affected messages of a source that was read but whose row could not be repaired: a read
        /// error, a cancelled file, or no proposal in the file for the row.
        var failed: Int { sources.filter { !$0.missing }.reduce(0) { $0 + $1.unmatched } }
        var sourcesRead: Int { sources.filter { $0.affected > 0 && !$0.missing && !$0.cancelled && $0.failure == nil }.count }

        /// "affected 14 · recovered 11 · already intact 120 · ambiguous 1 · missing source 1 · failed 1"
        var line: String {
            var parts = ["affected \(affected)", "recovered \(recovered)", "already intact \(alreadyIntact)",
                         "ambiguous \(ambiguous)", "missing source \(missingSource)", "failed \(failed)"]
            if cancelled { parts.append("cancelled after \(sourcesRead) of \(sourcesWithWork) sources") }
            if let snapshotPath { parts.append("snapshot \(snapshotPath)") }
            if !wrongSources.isEmpty { parts.append("wrong source: \(wrongSources.joined(separator: ", "))") }
            let failures = sources.compactMap(\.failure)
            if !failures.isEmpty { parts.append("errors: \(failures.joined(separator: "; "))") }
            return parts.joined(separator: " · ")
        }
    }

    enum Failure: LocalizedError {
        case snapshotFailed(String)
        var errorDescription: String? {
            switch self {
            case .snapshotFailed(let why): return "The archive could not be backed up before the repair, so nothing was changed: \(why)"
            }
        }
    }

    /// Plan page size — a batch, never a cap (rule 6).
    static let pageSize = 500

    /// What would be re-read, per source, with the copy that would be used.
    /// Detection reads the stored provenance (which import) and the actual
    /// availability (raw source present AND every attachment's bytes
    /// retrievable); the per-source "already intact" count is kept.
    static func plan(store: SQLiteEmailStore) async throws -> Plan {
        let sources = try await store.binarySources()
        let byHash = Dictionary(sources.map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })
        let hashes = sources.map(\.sha256)
        let totals = try await store.messageCounts(sourceHashes: hashes)
        var affected: [String: [SQLiteEmailStore.RecoveryCandidate]] = [:]
        var cursor: UUID?
        while true {
            try Task.checkCancellation()
            let page = try await store.recoveryCandidatePage(sourceHashes: hashes, includeUnregistered: true, after: cursor, limit: pageSize)
            guard let last = page.last else { break }
            cursor = last.id
            for candidate in page {
                let key = candidate.sourceHash ?? ""
                if !candidate.hasRawSource {
                    affected[key, default: []].append(candidate)
                    continue
                }
                // Registered sources of another kind (mbox with a raw source) are not this action's business;
                // a binary-source message with a raw source is checked attachment by attachment.
                guard byHash[key] != nil else { continue }
                if try await bytesMissing(store: store, id: candidate.id) { affected[key, default: []].append(candidate) }
            }
        }
        // Every binary source is a group — one with nothing affected reports its messages as already
        // intact, so a repeated run says "already intact = all" instead of nothing.
        for hash in hashes where affected[hash] == nil { affected[hash] = [] }
        let directory = store.storeDirectory
        var groups: [SourceGroup] = []
        func name(_ hash: String) -> String { byHash[hash]?.filename ?? (hash.isEmpty ? "unknown source" : "source \(hash.prefix(12))…") }
        for (hash, messages) in affected.sorted(by: { (name($0.key), $0.key) < (name($1.key), $1.key) }) {
            let source = byHash[hash]
            let filename = name(hash)
            let intact = max(0, (totals[hash] ?? messages.count) - messages.count)
            var group = SourceGroup(sourceHash: hash.isEmpty ? nil : hash, sourceID: source?.sourceID, filename: filename,
                                    messages: messages, alreadyIntact: source == nil ? 0 : intact, fileURL: nil)
            if !hash.isEmpty, let source, !source.filename.isEmpty {
                group.fileURL = SourceCopies.existingCopy(sha256: hash, filename: source.filename, storeDirectory: directory)
            }
            groups.append(group)
        }
        return Plan(groups: groups)
    }

    /// True when any attachment of the message has no retrievable bytes.
    static func bytesMissing(store: SQLiteEmailStore, id: UUID) async throws -> Bool {
        guard let email = try await store.fullEmail(id: id), !email.attachments.isEmpty else { return false }
        let cache = AttachmentHydrator.Cache()
        for (index, attachment) in email.attachments.enumerated() {
            if AttachmentHydrator.data(for: attachment, index: index, email: email, cache: cache) == nil { return true }
        }
        return false
    }

    /// What one message in the file looked like, kept with its staged source.
    struct Proposal: Sendable, Equatable {
        let candidateID: UUID
        let subject: String
        let date: Date?
        let from: String
        let attachmentNames: [String]
        let stagedURL: URL
        let strong: Bool
        /// R4: position of the message in the file.
        var ordinal: Int = 0
        /// R4: what the message IS — metadata, normalised body, attachment payload fingerprints.
        var contentKey: String = ""
    }

    /// Re-read every group that has a file (its copy, or `files[group.id]` the
    /// person chose), stage the matches, write the corroborated ones, reset
    /// the attachment index for the recovered messages. Nothing else in the
    /// rows changes. Cancellation stops between messages; the file being read
    /// is not committed and the receipt says how far the run got.
    static func run(store: SQLiteEmailStore, plan: Plan, files: [String: URL] = [:],
                    receipts: RawSourceRecoveryReceiptStore? = nil, now: Date = Date(),
                    progress: (@Sendable (String) -> Void)? = nil) async -> Receipt {
        var receipt = Receipt(startedAt: now, completedAt: now)
        let runnable = plan.groups.filter { $0.count > 0 && (files[$0.id] ?? $0.fileURL) != nil }
        // 2. Back up before the first write (rule 2). No snapshot, no repair.
        if !runnable.isEmpty {
            do {
                let snapshot = try await store.snapshot(reason: "before-attachment-recovery")
                receipt.snapshotPath = snapshot.url.path
            } catch {
                for group in plan.groups {
                    var result = SourceResult(filename: group.filename, affected: group.count, alreadyIntact: group.alreadyIntact)
                    result.missing = (files[group.id] ?? group.fileURL) == nil
                    if !result.missing { result.unmatched = group.count; result.failure = Failure.snapshotFailed(error.localizedDescription).localizedDescription }
                    receipt.sources.append(result)
                }
                receipt.completedAt = Date()
                _ = try? receipts?.save(receipt)
                return receipt
            }
        }
        let staging = store.storeDirectory.appendingPathComponent("recovery-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var stopped = false
        for group in plan.groups {
            var result = SourceResult(filename: group.filename, affected: group.count, alreadyIntact: group.alreadyIntact)
            if group.count == 0 {   // nothing to read: every message of this source is intact
                receipt.sources.append(result)
                continue
            }
            guard let fileURL = files[group.id] ?? group.fileURL else {
                result.missing = true
                receipt.sources.append(result)
                continue
            }
            if stopped || Task.isCancelled {
                result.cancelled = true; result.unmatched = group.count
                receipt.sources.append(result)
                continue
            }
            progress?(group.filename)
            // 3. Validate the file against the registered hash.
            var verified = true
            do {
                let hash = try ExportInventory.sha256(of: fileURL)
                result.fileSHA256 = hash
                if let expected = group.sourceHash, hash != expected { verified = false; result.wrongSource = true }
            } catch {
                result.failure = "\(group.filename): \(error.localizedDescription)"; result.unmatched = group.count
                receipt.sources.append(result)
                continue
            }
            // 4. Stage every proposal; decide after the whole file is read.
            let matcher = Matcher(candidates: group.messages, verifiedFile: verified)
            var proposals: [UUID: [Proposal]] = [:]
            var ambiguous: [AmbiguousItem] = []
            var ordinal = 0
            let fileStaging = staging.appendingPathComponent(group.id, isDirectory: true)
            // A parser may hand batches over from its own context, where `Task.isCancelled` is not this
            // task's flag — so cancellation is carried by hand and checked before every message.
            let stop = CancelFlag()
            do {
                try FileManager.default.createDirectory(at: fileStaging, withIntermediateDirectories: true)
                try await withTaskCancellationHandler {
                    _ = try await ParserFactory.parseStreamingCallback(fileURL: fileURL, senderEmail: "", batchSize: 100) { batch in
                    for parsed in batch {
                        defer { ordinal += 1 }
                        if stop.isSet || Task.isCancelled { throw CancellationError() }
                        defer { for attachment in parsed.attachments { if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) } } }
                        guard !parsed.rawSource.isEmpty else { continue }
                        let content = RecoveryContent(parsed)
                        switch matcher.match(parsed, ordinal: ordinal, content: content) {
                        case .none: continue
                        case .ambiguous(let item): ambiguous.append(item)
                        case .match(let candidate, let strong):
                            let url = fileStaging.appendingPathComponent("\(candidate.id.uuidString)-\(ordinal).eml")
                            try Data(parsed.rawSource.utf8).write(to: url)
                            proposals[candidate.id, default: []].append(Proposal(
                                candidateID: candidate.id, subject: parsed.headers["Subject"] ?? "", date: Matcher.date(of: parsed),
                                from: Matcher.address(parsed.headers["From"] ?? ""), attachmentNames: parsed.attachments.map(\.filename),
                                stagedURL: url, strong: strong, ordinal: ordinal, contentKey: content.identityKey))
                        }
                    }
                    }
                } onCancel: { stop.set() }
            } catch is CancellationError {
                result.cancelled = true; result.unmatched = group.count; stopped = true
                receipt.sources.append(result)
                continue
            } catch {
                result.failure = "\(group.filename): \(error.localizedDescription)"; result.unmatched = group.count
                receipt.sources.append(result)
                continue
            }
            // 5./6. Commit: exactly one content-distinct proposal per row, otherwise ambiguous.
            let byID = Dictionary(group.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (candidateID, list) in proposals.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let candidate = byID[candidateID] else { continue }
                guard let proposal = choose(list, for: candidate, verifiedFile: verified) else {
                    let other = list.count > 1 ? list[1] : list[0]
                    ambiguous.append(AmbiguousItem(emailID: candidateID, storedSubject: candidate.subject,
                                                   storedDate: Date(timeIntervalSince1970: Double(candidate.date)), storedFrom: candidate.from,
                                                   fileSubject: "\(list.count) messages in the file: " + list.map(\.subject).joined(separator: " / "),
                                                   fileDate: other.date, fileFrom: other.from,
                                                   reason: "more than one message in the file matches this row and their body or attachment content differs",
                                                   fileOrdinals: list.map(\.ordinal).sorted()))
                    continue
                }
                do {
                    let raw = String(decoding: try Data(contentsOf: proposal.stagedURL), as: UTF8.self)
                    let stamped = RawSourceProvenance.stamp(rawSource: raw, sourceFilename: fileURL.lastPathComponent, date: now, verified: verified)
                    try await store.replaceRawSource(emailID: candidateID, rawSource: stamped)
                    result.recovered += 1
                    receipt.recoveredIDs.append(candidateID)
                } catch {
                    result.failure = (result.failure.map { $0 + "; " } ?? "") + "\(candidate.subject): \(error.localizedDescription)"
                }
            }
            // One row, one verdict: an ambiguous row that was also written (cannot happen by construction) is not double counted.
            let written = Set(receipt.recoveredIDs)
            let ambiguousRows = Set(ambiguous.map(\.emailID)).subtracting(written)
            result.ambiguous = ambiguousRows.count
            receipt.ambiguousItems += ambiguous.filter { ambiguousRows.contains($0.emailID) }
            result.unmatched = group.count - result.recovered - result.ambiguous
            receipt.sources.append(result)
        }
        receipt.cancelled = stopped
        // 7. The attachment index reads the recovered messages again.
        if !receipt.recoveredIDs.isEmpty {
            try? await store.attachmentTextStateReset(emailIDs: receipt.recoveredIDs)
            if let coverage = try? AttachmentCoverageStore(url: await store.attachmentCoverageURL) {
                try? coverage.remove(emailIDs: receipt.recoveredIDs)
            }
        }
        receipt.completedAt = Date()
        _ = try? receipts?.save(receipt)
        return receipt
    }

    /// R4: the one proposal a row may be written from. Proposals that are the same message (same
    /// metadata, normalised body and attachment payloads — a copy filed twice) count once and the
    /// first is used. Content-distinct proposals are ambiguous, except in the verified source file
    /// when the row's stored source ordinal names exactly one of them (the import's own position).
    static func choose(_ list: [Proposal], for candidate: SQLiteEmailStore.RecoveryCandidate, verifiedFile: Bool) -> Proposal? {
        let ordered = list.sorted { $0.ordinal < $1.ordinal }
        guard let first = ordered.first else { return nil }
        if Set(ordered.map(\.contentKey)).count == 1 { return first }
        guard verifiedFile, let stored = candidate.sourceOrdinal else { return nil }
        let atOrdinal = ordered.filter { Int64($0.ordinal) == stored }
        return atOrdinal.count == 1 ? atOrdinal[0] : nil
    }

    /// R4: what a message in the file holds beyond its headers — computed once per message.
    struct RecoveryContent: Sendable, Equatable {
        /// Normalised body fingerprint (`bodyFingerprint(plain:html:)`).
        var body: String?
        /// Lower-cased addr-specs of To and Cc.
        var recipients: Set<String>
        struct Attachment: Sendable, Equatable {
            var name: String
            var size: Int
            /// SHA-256 of the payload when the parser handed the bytes over.
            var sha256: String?
        }
        var attachments: [Attachment]
        /// Subject, date, sender, body and attachment payloads: two proposals with the same key are the same message.
        var identityKey: String

        init(_ parsed: MBOXParser.RawEmail) {
            body = Self.bodyFingerprint(plain: parsed.plainBody, html: parsed.htmlBody)
            recipients = Self.addresses([parsed.headers["To"] ?? "", parsed.headers["Cc"] ?? ""].joined(separator: ", "))
            attachments = parsed.attachments.map { attachment in
                Attachment(name: attachment.filename.lowercased(), size: attachment.size, sha256: Self.payloadHash(attachment))
            }
            let date = Matcher.date(of: parsed).map { String(Int64($0.timeIntervalSince1970)) } ?? "-"
            let parts = attachments.map { "\($0.name)#\($0.sha256 ?? "size:\($0.size)")" }.sorted()
            identityKey = [Matcher.collapse(parsed.headers["Subject"] ?? ""), date, Matcher.address(parsed.headers["From"] ?? ""),
                           recipients.sorted().joined(separator: ","), body ?? "-", parts.joined(separator: ",")].joined(separator: "|")
        }

        /// SHA-256 of the whitespace-collapsed plain body ("p:"), or of the HTML when there is no plain
        /// body ("h:"); nil when the message has no body at all.
        static func bodyFingerprint(plain: String, html: String) -> String? {
            let p = plain.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            if !p.isEmpty { return "p:" + hex(SHA256.hash(data: Data(p.utf8))) }
            let h = html.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            if !h.isEmpty { return "h:" + hex(SHA256.hash(data: Data(h.utf8))) }
            return nil
        }

        /// Lower-cased addr-specs found in an address header ("Ann <ann@x.org>, bob@y.org").
        static func addresses(_ header: String) -> Set<String> {
            var out: Set<String> = []
            for token in header.components(separatedBy: CharacterSet(charactersIn: " \t\r\n<>,;\"()[]")) where token.contains("@") {
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ":'"))
                if !trimmed.isEmpty { out.insert(trimmed.lowercased()) }
            }
            return out
        }

        static func payloadHash(_ attachment: AttachmentMetadata) -> String? {
            if let url = attachment.fileURL, let hash = try? ExportInventory.sha256(of: url) { return hash.lowercased() }
            if let base64 = attachment.base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                return hex(SHA256.hash(data: data))
            }
            return nil
        }

        private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: Matching

    enum MatchOutcome: Equatable {
        case none
        case match(SQLiteEmailStore.RecoveryCandidate, strong: Bool)
        case ambiguous(AmbiguousItem)
    }

    /// Message-ID plus corroboration; ordinal plus corroboration; never one weak signal.
    struct Matcher {
        let candidates: [SQLiteEmailStore.RecoveryCandidate]
        let verifiedFile: Bool
        private let byMessageID: [String: [SQLiteEmailStore.RecoveryCandidate]]
        private let byOrdinal: [Int64: SQLiteEmailStore.RecoveryCandidate]
        private let bySubject: [String: [SQLiteEmailStore.RecoveryCandidate]]

        init(candidates: [SQLiteEmailStore.RecoveryCandidate], verifiedFile: Bool) {
            self.candidates = candidates
            self.verifiedFile = verifiedFile
            var ids: [String: [SQLiteEmailStore.RecoveryCandidate]] = [:]
            var ordinals: [Int64: SQLiteEmailStore.RecoveryCandidate] = [:]
            var subjects: [String: [SQLiteEmailStore.RecoveryCandidate]] = [:]
            for candidate in candidates {
                if let id = candidate.messageID, !id.isEmpty { ids[Self.normalise(id), default: []].append(candidate) }
                if let ordinal = candidate.sourceOrdinal { ordinals[ordinal] = candidate }
                subjects[Self.collapse(candidate.subject), default: []].append(candidate)
            }
            byMessageID = ids; byOrdinal = ordinals; bySubject = subjects
        }

        func match(_ parsed: MBOXParser.RawEmail, ordinal: Int, content precomputed: RecoveryContent? = nil) -> MatchOutcome {
            let content = precomputed ?? RecoveryContent(parsed)
            let fileMessageID = parsed.headers["Message-ID"].map(Self.normalise).flatMap { $0.isEmpty ? nil : $0 }
            let fileDate = Self.date(of: parsed)
            let fileFrom = Self.address(parsed.headers["From"] ?? "")
            let fileSubject = parsed.headers["Subject"] ?? ""
            func item(_ candidate: SQLiteEmailStore.RecoveryCandidate, _ reason: String) -> AmbiguousItem {
                AmbiguousItem(emailID: candidate.id, storedSubject: candidate.subject, storedDate: Date(timeIntervalSince1970: Double(candidate.date)),
                              storedFrom: candidate.from, fileSubject: fileSubject, fileDate: fileDate, fileFrom: fileFrom, reason: reason)
            }
            func agrees(_ candidate: SQLiteEmailStore.RecoveryCandidate) -> Bool {
                Self.mismatch(candidate, parsed, date: fileDate, from: fileFrom, content: content) == nil
            }
            // Message-ID AND content.
            if let fileMessageID, let hits = byMessageID[fileMessageID], !hits.isEmpty {
                let corroborated = hits.filter(agrees)
                if corroborated.count == 1 {
                    let hit = corroborated[0]
                    // R4: a file whose hash differs is trusted only when the content the row itself keeps
                    // (its body, or attachment hashes) establishes the correspondence.
                    if !verifiedFile && !Self.contentEstablished(hit, content) {
                        return .ambiguous(item(hit, "the file differs from the registered source and this row keeps no body or attachment fingerprint that confirms the match"))
                    }
                    return .match(hit, strong: true)
                }
                if corroborated.count > 1 { return .ambiguous(item(corroborated[0], "the same Message-ID and content match \(corroborated.count) rows")) }
                let why = Self.mismatch(hits[0], parsed, date: fileDate, from: fileFrom, content: content) ?? "content"
                return .ambiguous(item(hits[0], "Message-ID matches but the row differs in: \(why)"))
            }
            // A file whose hash differs is only trusted on Message-ID AND content.
            guard verifiedFile else { return .none }
            // No Message-ID on one side: the source ordinal AND content.
            if let hit = byOrdinal[Int64(ordinal)] {
                if agrees(hit) { return .match(hit, strong: false) }
                let why = Self.mismatch(hit, parsed, date: fileDate, from: fileFrom, content: content) ?? "content"
                return .ambiguous(item(hit, "the message at this position in the file differs from the row in: \(why)"))
            }
            // Neither: every content signal, and exactly one row.
            guard fileDate != nil, !fileFrom.isEmpty else { return .none }   // subject alone is one weak signal
            let hits = (bySubject[Self.collapse(fileSubject)] ?? []).filter(agrees)
            if hits.count == 1 { return .match(hits[0], strong: false) }
            if hits.count > 1 { return .ambiguous(item(hits[0], "subject, date, sender, body and attachments match \(hits.count) rows and there is no Message-ID")) }
            return .none
        }

        /// True when the message agrees with everything the row keeps (`mismatch` is nil).
        static func corroborates(_ candidate: SQLiteEmailStore.RecoveryCandidate, _ parsed: MBOXParser.RawEmail, date: Date?, from: String) -> Bool {
            mismatch(candidate, parsed, date: date, from: from, content: RecoveryContent(parsed)) == nil
        }

        /// R4: nil when the message agrees with everything the row keeps — subject, date to the second,
        /// sender, recipients (when both sides have them), attachment names, count and sizes (when
        /// recorded), attachment SHA-256 (when recorded) and the normalised stored body; otherwise
        /// which of those differ ("body", "subject, attachments").
        static func mismatch(_ candidate: SQLiteEmailStore.RecoveryCandidate, _ parsed: MBOXParser.RawEmail, date: Date?, from: String,
                             content: RecoveryContent) -> String? {
            var differs: [String] = []
            if collapse(candidate.subject) != collapse(parsed.headers["Subject"] ?? "") { differs.append("subject") }
            if let date, candidate.date != 0, Int64(date.timeIntervalSince1970) != candidate.date { differs.append("date") }
            let storedFrom = address(candidate.from)
            if !storedFrom.isEmpty, !from.isEmpty, storedFrom != from { differs.append("sender") }
            let storedRecipients = RecoveryContent.addresses(candidate.recipients)
            if !storedRecipients.isEmpty, !content.recipients.isEmpty, storedRecipients != content.recipients { differs.append("recipients") }
            if !attachmentsAgree(candidate, content) { differs.append("attachments") }
            if candidate.bodyFingerprint != content.body { differs.append("body") }
            guard !differs.isEmpty else { return nil }
            return differs.joined(separator: ", ")
        }

        /// Names and count always; sizes where the row recorded one (and the file reports one);
        /// SHA-256 where the row recorded one — a payload that cannot be hashed does not agree.
        static func attachmentsAgree(_ candidate: SQLiteEmailStore.RecoveryCandidate, _ content: RecoveryContent) -> Bool {
            guard candidate.attachmentNames.count == content.attachments.count else { return false }
            struct Stored { var name: String; var size: Int; var hash: String }
            let stored = candidate.attachmentNames.enumerated().map { index, name in
                Stored(name: name.lowercased(),
                       size: index < candidate.attachmentSizes.count ? candidate.attachmentSizes[index] : 0,
                       hash: index < candidate.attachmentHashes.count ? candidate.attachmentHashes[index] : "")
            }.sorted { ($0.name, $0.size, $0.hash) < ($1.name, $1.size, $1.hash) }
            let file = content.attachments.sorted { ($0.name, $0.size, $0.sha256 ?? "") < ($1.name, $1.size, $1.sha256 ?? "") }
            for (s, f) in zip(stored, file) {
                if s.name != f.name { return false }
                if s.size > 0, f.size > 0, s.size != f.size { return false }
                if !s.hash.isEmpty, s.hash != f.sha256 { return false }
            }
            return true
        }

        /// R4: what makes a match from a changed file independent of the headers — the row keeps a
        /// body (and it is equal), or it keeps a hash for every attachment (and they agree).
        static func contentEstablished(_ candidate: SQLiteEmailStore.RecoveryCandidate, _ content: RecoveryContent) -> Bool {
            if let body = candidate.bodyFingerprint, body == content.body { return true }
            let hashes = candidate.attachmentHashes
            return !hashes.isEmpty && hashes.count == candidate.attachmentNames.count && hashes.allSatisfy { !$0.isEmpty }
                && attachmentsAgree(candidate, content)
        }

        static func normalise(_ messageID: String) -> String {
            messageID.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
        }

        static func collapse(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        }

        /// The addr-spec of a From header, lower-cased: "Ann <ann@x.org>" → "ann@x.org".
        static func address(_ header: String) -> String {
            if let open = header.lastIndex(of: "<"), let close = header[open...].firstIndex(of: ">") {
                return String(header[header.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
            }
            return header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        static func date(of email: MBOXParser.RawEmail) -> Date? {
            parseDate(email.timestamp) ?? parseDate(email.headers["Date"] ?? "")
        }

        static func parseDate(_ text: String) -> Date? {
            guard !text.isEmpty else { return nil }
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: text) { return d }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: text) { return d }
            let trimmed = text.replacingOccurrences(of: "\\s*\\(.*\\)$", with: "", options: .regularExpression)
            for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
                if let d = f.date(from: trimmed) { return d }
            }
            return nil
        }
    }
}

/// A cancellation flag that crosses parser contexts.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

// MARK: - Receipts

/// Recovery receipts as JSON files, beside the import and export receipts
/// (production: Application Support ▸ receipts ▸ recovery).
struct RawSourceRecoveryReceiptStore: Sendable {
    let directory: URL

    static var production: RawSourceRecoveryReceiptStore {
        RawSourceRecoveryReceiptStore(directory: ImportReceiptStore.production.directory.appendingPathComponent("recovery", isDirectory: true))
    }

    @discardableResult
    func save(_ receipt: RawSourceRecovery.Receipt) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ArtifactProtection.applyBackgroundReadable(to: directory)
        let stamp = Int(receipt.completedAt.timeIntervalSince1970)
        let url = directory.appendingPathComponent("recovery-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(receipt).write(to: url)
        ArtifactProtection.applyBackgroundReadable(to: url)
        return url
    }

    func load(_ url: URL) throws -> RawSourceRecovery.Receipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RawSourceRecovery.Receipt.self, from: Data(contentsOf: url))
    }

    /// Newest first.
    func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
