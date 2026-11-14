@testable import ArchiveCore
//
//  DuplicateVerification.swift
//  maxmailin
//
//  Five jobs, DUP-01. The duplicate engines group emails by clues — a shared
//  Message-ID, a fingerprint of the first 200 body characters, the EDRM
//  Message Identification Hash. A clue is not a comparison: RFC 5322 lets
//  two messages carry the same Message-ID with different transport headers,
//  and a prefix says nothing about the rest of the body or the attachments.
//
//  This step takes each group the engines produce and compares its members
//  in full. Only a group that passes is shown as identical and offered for
//  bulk removal; the rest are candidates the person decides about one by one.
//
//  Classes (DUP-03 refines these further):
//    byteIdentical      — every member's stored raw message hashes the same
//    contentEquivalent  — all addresses, the date, the subject, the whole
//                         body and every attachment match; raw bytes differ
//                         or are not stored for every member
//    candidate          — something differs, named in `differences`
//

import CryptoKit
import Foundation

enum DuplicateVerification {

    /// What differed between members of a group that did not verify.
    enum Difference: String, CaseIterable, Sendable {
        case from, to, cc, bcc, date, subject, body, structure, attachments
        /// Audit 2026-11-06 A01: at least one attachment's bytes could not be
        /// produced, so the copies could not be compared byte for byte.
        case attachmentBytes

        var label: String {
            switch self {
            case .from: return String(localized: "sender")
            case .to: return String(localized: "recipients")
            case .cc: return String(localized: "Cc")
            case .bcc: return String(localized: "Bcc")
            case .date: return String(localized: "date")
            case .subject: return String(localized: "subject")
            case .body: return String(localized: "body")
            case .structure: return String(localized: "MIME structure")
            case .attachments: return String(localized: "attachments")
            case .attachmentBytes: return String(localized: "attachment bytes (not available for every copy — open the files and compare before removing)")
            }
        }
    }

    /// DUP-03: the four classes, kept apart on screen and in what they allow.
    enum Verdict: Equatable, Sendable {
        /// Every member's stored raw message hashes the same, byte for byte.
        case byteIdentical
        /// Content-equivalent as defined by `contentEquivalentDefinition`.
        /// `attachmentBytesCompared` is always true for a verdict `verify`
        /// returns (audit A01: copies whose attachment bytes could not be
        /// compared are candidates); false is kept for stored/older values
        /// and is never verified.
        case contentEquivalent(attachmentBytesCompared: Bool)
        /// Similar text above a threshold (near-duplicate engines) — never identical.
        case similar(similarity: Double)
        /// Grouped by a clue, but something named in `differences` differs.
        case candidate(differences: [Difference])

        /// Only the two identical classes may be removed in bulk.
        var isVerified: Bool {
            switch self {
            case .byteIdentical, .contentEquivalent(attachmentBytesCompared: true): return true
            case .contentEquivalent, .similar, .candidate: return false
            }
        }
    }

    /// The explicit definition of the content-equivalent class (DUP-03).
    static var contentEquivalentDefinition: String {
        String(localized: "Content-equivalent: the same sender, recipients, Cc, Bcc, date, subject, whole body, MIME structure and attachment bytes — only the stored raw bytes differ (transport headers, line endings).")
    }

    struct Group: Identifiable, Sendable {
        /// The first member's id; the first member is the copy that is kept.
        var id: UUID { members[0].id }
        var members: [MBOXParser.RawEmail]
        let verdict: Verdict
    }

    // MARK: - Verification

    /// Compare every member of one engine group in full. A group of fewer
    /// than two emails is trivially identical.
    static func verify(_ members: [MBOXParser.RawEmail]) -> Verdict {
        guard members.count > 1 else { return .byteIdentical }

        // 1. Stored raw bytes, when every member has them: the same bytes are
        //    byte-identical; the same bytes up to line endings are content-
        //    equivalent (audit A01: a different byte stream is never called
        //    byte-identical).
        if members.allSatisfy({ !$0.rawSource.isEmpty }) {
            if Set(members.map { sha256($0.rawSource) }).count == 1 { return .byteIdentical }
            if Set(members.map { sha256(normalisedLineEndings($0.rawSource)) }).count == 1 {
                return .contentEquivalent(attachmentBytesCompared: true)
            }
        }

        // A member the reader could not parse (a preserved-but-unreadable
        // capture: raw bytes kept, no header, body or attachment read from
        // them) has no content to compare — empty fields equal empty fields
        // proves nothing. Only the identical bytes above could have proven
        // it, so it stays a candidate the person compares.
        if members.contains(where: { !hasParsedContent($0) }) {
            return .candidate(differences: [.body, .structure])
        }

        // 2. Full content, field by field.
        var differences: [Difference] = []
        func check(_ field: Difference, _ value: (MBOXParser.RawEmail) -> String) {
            if Set(members.map(value)).count > 1 { differences.append(field) }
        }
        check(.from) { addresses($0.headers["From"]) }
        check(.to) { addresses($0.headers["To"]) }
        check(.cc) { addresses($0.headers["Cc"] ?? $0.headers["CC"]) }
        check(.bcc) { addresses($0.headers["Bcc"] ?? $0.headers["BCC"]) }
        check(.date) { dateKey($0.headers["Date"]) }
        check(.subject) { collapse($0.headers["Subject"] ?? "") }
        check(.body) { bodyKey($0) }
        // MIME structure: which body parts exist and how many parts are
        // attachments or inline (an HTML-only copy is not the plain copy).
        check(.structure) { email in
            "plain:\(!email.plainBody.isEmpty) html:\(!email.htmlBody.isEmpty) parts:\(email.attachments.count) inline:\(email.attachments.filter(\.isInline).count)"
        }

        // Release audit bf1a5b9 R2: attachments are compared as OCCURRENCES —
        // payload SHA-256, byte count, file name, Content-ID, disposition and
        // MIME type kept together per attachment (the export checker's model,
        // `ExportReconciliation.Occurrence`) — as a multiset of whole tuples.
        // A set of sorted payload hashes let two inline images swap their
        // Content-IDs, or a file be renamed, and still pass as equivalent.
        let occurrences = members.map { ExportReconciliation.occurrences(of: $0, includeMIMEType: true) }
        let bytesCompared = occurrences.allSatisfy { $0.missingBytes == 0 }
        let keys = occurrences.map { set in
            ExportReconciliation.occurrenceMultiset(bytesCompared ? set.list : set.list.map(\.withoutBytes))
        }
        if keys.contains(where: { $0 != keys[0] }) { differences.append(.attachments) }
        // Audit A01: bytes that could not be produced for comparison leave the
        // copies unproven — a candidate the person compares, never a bulk removal.
        if bytesCompared == false, !differences.contains(.attachments) { differences.append(.attachmentBytes) }

        if differences.isEmpty { return .contentEquivalent(attachmentBytesCompared: true) }
        return .candidate(differences: differences)
    }

    /// Split engine groups into those proven identical and the candidates.
    /// Order within each list follows the input (largest groups first).
    static func classify(_ groups: [[MBOXParser.RawEmail]]) -> (verified: [Group], candidates: [Group]) {
        var verified: [Group] = []
        var candidates: [Group] = []
        for members in groups where members.count > 1 {
            let group = Group(members: members, verdict: verify(members))
            if group.verdict.isVerified { verified.append(group) } else { candidates.append(group) }
        }
        return (verified, candidates)
    }

    /// The copies a bulk action may remove: every member after the first of
    /// each verified group. Candidates never contribute.
    static func bulkRemovable(_ groups: [Group]) -> [UUID] {
        groups.filter(\.verdict.isVerified).flatMap { $0.members.dropFirst().map(\.id) }
    }

    /// DUP-04: which copy survives each group the selection touches. The
    /// survivor is the first member the user did not tick; when every member
    /// is ticked the first one stays (a group never loses all its copies).
    static func plans(for selected: Set<UUID>, among groups: [[MBOXParser.RawEmail]]) -> [SQLiteEmailStore.DuplicateRemovalPlan] {
        var plans: [SQLiteEmailStore.DuplicateRemovalPlan] = []
        var planned = Set<UUID>()
        for members in groups {
            let ids = members.map(\.id)
            let removed = ids.filter { selected.contains($0) && !planned.contains($0) }
            guard !removed.isEmpty else { continue }
            let survivor = ids.first { !selected.contains($0) } ?? ids[0]
            let finalRemoved = removed.filter { $0 != survivor }
            guard !finalRemoved.isEmpty else { continue }
            planned.formUnion(finalRemoved)
            plans.append(.init(survivor: survivor, removed: finalRemoved))
        }
        return plans
    }

    /// DUP-05: the survivor, described — who, when, where it lives.
    static func survivorLine(_ members: [MBOXParser.RawEmail]) -> String {
        guard let kept = members.first else { return "" }
        var parts = [kept.headers["From"] ?? "", kept.timestamp].filter { !$0.isEmpty }
        let folders = SQLiteEmailStore.folderPaths(for: kept)
        if !folders.isEmpty { parts.append(String(localized: "in \(folders.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }

    /// One line naming what differs, for a candidate group's row.
    static func differenceLine(_ verdict: Verdict) -> String? {
        guard case .candidate(let differences) = verdict, !differences.isEmpty else { return nil }
        let names = differences.map(\.label).formatted(.list(type: .and))
        return String(localized: "Differs in \(names)")
    }

    // MARK: - Archive-wide (Message-ID) groups

    /// Verify the archive's same-Message-ID groups a chunk at a time so memory
    /// follows the number of duplicates, not the archive. Returns the ids a
    /// bulk removal may delete and how many groups were left as candidates.
    static func verifyArchiveWide(
        groups: [[UUID]],
        load: @escaping ([UUID]) async throws -> [MBOXParser.RawEmail]
    ) async throws -> (removable: [UUID], verifiedGroups: Int, candidateGroups: Int, plans: [SQLiteEmailStore.DuplicateRemovalPlan]) {
        var removable: [UUID] = []
        var plans: [SQLiteEmailStore.DuplicateRemovalPlan] = []
        var verifiedGroups = 0
        var candidateGroups = 0
        var pending: [[UUID]] = []
        var pendingCount = 0

        func flush() async throws {
            guard !pending.isEmpty else { return }
            let loaded = try await load(pending.flatMap { $0 })
            let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for ids in pending {
                // Keep the store's order: the first id is the copy to keep.
                let members = ids.compactMap { byID[$0] }
                guard members.count > 1 else { continue }
                if verify(members).isVerified {
                    verifiedGroups += 1
                    let extra = members.dropFirst().map(\.id)
                    removable.append(contentsOf: extra)
                    plans.append(.init(survivor: members[0].id, removed: extra))
                } else {
                    candidateGroups += 1
                }
            }
            pending.removeAll(keepingCapacity: true)
            pendingCount = 0
        }

        for ids in groups {
            try Task.checkCancellation()
            pending.append(ids)
            pendingCount += ids.count
            if pendingCount >= 500 { try await flush() }
        }
        try await flush()
        return (removable, verifiedGroups, candidateGroups, plans)
    }

    /// Whether the record carries anything the reader produced: a body, an
    /// attachment, or one of the identifying headers. An unreadable capture
    /// (`ConnectedArchiveSink.unreadableRecord`) carries none of them.
    static func hasParsedContent(_ email: MBOXParser.RawEmail) -> Bool {
        if !email.plainBody.isEmpty || !email.htmlBody.isEmpty || !email.attachments.isEmpty { return true }
        if email.anomalies.contains(where: { $0.hasPrefix("connected-parse-failed") }) { return false }
        // "(No Subject)" is the reader's placeholder for a missing Subject, not content.
        return ["From", "To", "Cc", "Subject", "Date", "Message-ID"].contains { name in
            let value = (email.headers[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !(name == "Subject" && value == "(No Subject)")
        }
    }

    // MARK: - Normalisation

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// CRLF and LF sources of the same message are the same message.
    private static func normalisedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let addressPattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-']+@[A-Za-z0-9.\-]+"#)

    /// Lower-cased addresses, sorted — display names and ordering are not content.
    private static func addresses(_ header: String?) -> String {
        guard let header, !header.isEmpty else { return "" }
        guard let re = addressPattern else { return header.lowercased() }
        let ns = header as NSString
        let found = re.matches(in: header, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
        return found.isEmpty ? collapse(header.lowercased()) : found.sorted().joined(separator: ";")
    }

    /// The instant, when the header parses; otherwise the header text.
    private static func dateKey(_ header: String?) -> String {
        guard let header else { return "" }
        if let date = MBOXParser.parseDate(header) { return String(Int(date.timeIntervalSince1970)) }
        return collapse(header)
    }

    /// The whole body, every character. Plain text when present, otherwise
    /// the HTML's text; when every member also carries HTML, that is
    /// compared too so a changed HTML part is not missed.
    private static func bodyKey(_ email: MBOXParser.RawEmail) -> String {
        let text = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
        var key = normalisedLineEndings(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.plainBody.isEmpty, !email.htmlBody.isEmpty {
            key += "\u{1E}" + normalisedLineEndings(FTSSearchIndex.stripHTMLText(email.htmlBody))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sha256(key)
    }
}
