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
        case from, to, cc, bcc, date, subject, body, attachments

        var label: String {
            switch self {
            case .from: return String(localized: "sender")
            case .to: return String(localized: "recipients")
            case .cc: return String(localized: "Cc")
            case .bcc: return String(localized: "Bcc")
            case .date: return String(localized: "date")
            case .subject: return String(localized: "subject")
            case .body: return String(localized: "body")
            case .attachments: return String(localized: "attachments")
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case byteIdentical
        /// `attachmentBytesCompared` is false when at least one attachment had
        /// no stored bytes, so only its name, type and size were compared.
        case contentEquivalent(attachmentBytesCompared: Bool)
        case candidate(differences: [Difference])

        var isVerified: Bool {
            if case .candidate = self { return false }
            return true
        }
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

        // 1. Stored raw bytes, when every member has them.
        if members.allSatisfy({ !$0.rawSource.isEmpty }) {
            let digests = Set(members.map { sha256(normalisedLineEndings($0.rawSource)) })
            if digests.count == 1 { return .byteIdentical }
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

        var bytesCompared = true
        let attachmentKeys = members.map { email -> String in
            let identities = email.attachments.map { attachment -> String in
                let identity = attachmentIdentity(attachment)
                if !identity.bytes { bytesCompared = false }
                return identity.key
            }
            return identities.sorted().joined(separator: "\n")
        }
        if Set(attachmentKeys).count > 1 { differences.append(.attachments) }

        if differences.isEmpty { return .contentEquivalent(attachmentBytesCompared: bytesCompared) }
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
    ) async throws -> (removable: [UUID], verifiedGroups: Int, candidateGroups: Int) {
        var removable: [UUID] = []
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
                    removable.append(contentsOf: members.dropFirst().map(\.id))
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
        return (removable, verifiedGroups, candidateGroups)
    }

    // MARK: - Normalisation

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Bytes when stored (base64 or a readable file); otherwise name, type and size.
    private static func attachmentIdentity(_ attachment: AttachmentMetadata) -> (key: String, bytes: Bool) {
        if let base64 = attachment.base64, !base64.isEmpty {
            let stripped = base64.filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: stripped) { return ("bytes:" + sha256(data), true) }
            return ("b64:" + sha256(stripped), true)
        }
        if let url = attachment.fileURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return ("bytes:" + sha256(data), true)
        }
        return ("meta:\(attachment.filename)|\(attachment.mimeType)|\(attachment.size)", false)
    }
}
