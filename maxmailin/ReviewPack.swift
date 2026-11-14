//
//  ReviewPack.swift
//  maxmailin
//
//  3.1 T0 (switch: `v31ReviewPack`, preview, off) — the AXIOM "portable case"
//  idea in mailin's shape:
//
//  1. The examiner exports a scope as a sealed `.mailinpack`.
//  2. A reviewer opens it in any mailin (it is never imported into their
//     archive), codes / tags / notes each email and saves a signed
//     `.mailinresponse`.
//  3. The examiner merges the response: every decision is recorded with who
//     and when; a decision that disagrees with an existing code goes to the
//     conflict list instead of overwriting it (rule 1).
//
//  Both files are JSON Lines, written and read one line at a time (memory stays
//  flat at any scope size). The last line is an Ed25519 signature over the
//  SHA-256 of every byte before it, made with the author's per-device key
//  (kept in the Keychain). A pack or response whose bytes or signature do not
//  match is refused, never partly applied.
//

import Foundation
import CryptoKit
@testable import ArchiveCore

// MARK: - File model

enum ReviewPackFormat {
    static let packExtension = "mailinpack"
    static let responseExtension = "mailinresponse"
    static let version = 1
}

struct ReviewPackHeader: Codable, Equatable, Sendable {
    var kind = "mailin.reviewpack"
    var version = ReviewPackFormat.version
    var packID: UUID
    var title: String
    var createdAt: Date
    var createdBy: String
    /// Ed25519 public key of the examiner's device (raw, base64).
    var examinerKey: String
    var emailCount: Int
    /// The coding choices the reviewer may use.
    var codes: [String]
    var instructions: String
    var scope: String
}

struct ReviewPackEmail: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var date: String
    var from: String
    var to: String
    var cc: String
    var subject: String
    var body: String
    var attachments: [String]
    /// SHA-256 of the stored source, so the examiner can prove which bytes were reviewed.
    var sourceSHA256: String
}

struct ReviewPackSignature: Codable, Equatable, Sendable {
    var kind = "mailin.signature"
    /// SHA-256 (hex) of every byte before this line.
    var sha256: String
    /// Ed25519 signature over that digest (base64).
    var signature: String
}

struct ReviewResponseHeader: Codable, Equatable, Sendable {
    var kind = "mailin.reviewresponse"
    var version = ReviewPackFormat.version
    var packID: UUID
    /// SHA-256 of the whole pack file the reviewer opened.
    var packSHA256: String
    var reviewer: String
    var reviewerKey: String
    var createdAt: Date
}

struct ReviewDecision: Codable, Equatable, Sendable {
    var emailID: UUID
    var code: String?
    var tags: [String]
    var note: String?
    var decidedAt: Date
}

enum ReviewPackError: LocalizedError, Equatable {
    case unreadable(String)
    case badSignature
    case wrongKind
    case unknownPack
    case packChanged
    case keyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return String(localized: "The file could not be read: \(why)")
        case .badSignature: return String(localized: "The file's signature does not match its contents. It was changed after it was signed and was not used.")
        case .wrongKind: return String(localized: "This is not a mailin Review Pack or response.")
        case .unknownPack: return String(localized: "This response belongs to a Review Pack this Mac or device did not create.")
        case .packChanged: return String(localized: "The response was made from a different copy of the pack than the one sent.")
        case .keyUnavailable(let why): return String(localized: "The signing key is not available: \(why)")
        }
    }
}

// MARK: - Device signing key

enum ReviewSigningKey {
    static let account = "mailin.review.ed25519"

    static func privateKey() throws -> Curve25519.Signing.PrivateKey {
        do {
            if let data = try ChainAnchors.KeychainItem.load(account: account) {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            }
            let key = Curve25519.Signing.PrivateKey()
            try ChainAnchors.KeychainItem.save(account: account, data: key.rawRepresentation)
            return key
        } catch {
            throw ReviewPackError.keyUnavailable(error.localizedDescription)
        }
    }

    static func publicKeyBase64() throws -> String {
        try privateKey().publicKey.rawRepresentation.base64EncodedString()
    }
}

// MARK: - Signed JSON Lines writer / reader

/// Writes JSON lines while hashing them; `finish` appends the signature line.
final class SignedLineWriter {
    private let handle: FileHandle
    private var hasher = SHA256()
    private let encoder: JSONEncoder

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ReviewPackError.unreadable(url.lastPathComponent)
        }
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func write<T: Encodable>(_ value: T) throws {
        var line = try encoder.encode(value)
        line.append(0x0A)
        hasher.update(data: line)
        try handle.write(contentsOf: line)
    }

    func finish(signingWith key: Curve25519.Signing.PrivateKey) throws {
        let digest = Data(hasher.finalize())
        let sig = try key.signature(for: digest)
        var line = try encoder.encode(ReviewPackSignature(sha256: digest.hexString, signature: sig.base64EncodedString()))
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
        try handle.close()
    }
}

enum SignedLineReader {
    /// Reads `url` in 1 MB windows and calls `line` for each line (without
    /// its newline), then `tail` with any bytes after the last newline.
    /// Each window is cut once (no per-line copying of the rest), and drained
    /// in its own autorelease pool, so time is linear and memory flat.
    static func scan(_ url: URL, raw: ((Data) -> Void)? = nil, line: (Data) throws -> Void) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                raw?(chunk)
                pending.append(chunk)
                var start = pending.startIndex
                while let nl = pending[start...].firstIndex(of: 0x0A) {
                    try line(Data(pending[start..<nl]))
                    start = pending.index(after: nl)
                }
                pending = Data(pending[start...])
                return true
            }
            if !more { break }
        }
        return pending
    }

    /// Verifies the signature line against `publicKey` (raw base64) and every
    /// byte before it, streaming. Returns the SHA-256 of the whole file.
    static func verify(url: URL, publicKey: (Data) throws -> String) throws -> String {
        var body = SHA256()
        var whole = SHA256()
        var firstLine: Data?
        var lastLine = Data()
        // Hold back the last line (the signature) until the end.
        let tail = try scan(url, raw: { whole.update(data: $0) }) { l in
            var withNL = l
            withNL.append(0x0A)
            if firstLine == nil { firstLine = withNL }
            if !lastLine.isEmpty { body.update(data: lastLine) }
            lastLine = withNL
        }
        guard tail.isEmpty, let firstLine, !lastLine.isEmpty else { throw ReviewPackError.unreadable(url.lastPathComponent) }
        let dec = decoder()
        guard let sigLine = try? dec.decode(ReviewPackSignature.self, from: lastLine), sigLine.kind == "mailin.signature" else {
            throw ReviewPackError.badSignature
        }
        let digest = Data(body.finalize())
        guard digest.hexString == sigLine.sha256,
              let sig = Data(base64Encoded: sigLine.signature),
              let keyData = Data(base64Encoded: try publicKey(firstLine)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(sig, for: digest) else {
            throw ReviewPackError.badSignature
        }
        return Data(whole.finalize()).hexString
    }

    /// Calls `body` with every line except the signature line (already verified).
    static func forEachLine(url: URL, _ body: (Data) throws -> Void) throws {
        var held: Data?
        _ = try scan(url) { l in
            if let h = held { try body(h) }
            held = l
        }
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Examiner side

/// Packs this device created (to accept only their responses).
enum IssuedPacks {
    struct Entry: Codable, Equatable { var packID: UUID; var sha256: String; var title: String; var createdAt: Date; var emailCount: Int }

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReviewPacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("issued.json")
    }

    static func all() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? SignedLineReader.decoder().decode([Entry].self, from: data)) ?? []
    }

    static func add(_ e: Entry) throws {
        var list = all().filter { $0.packID != e.packID }
        list.append(e)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(list).write(to: url, options: .atomic)
    }
}

@MainActor
enum ReviewPackBuilder {
    nonisolated static let defaultCodes = ["Relevant", "Not relevant", "Privileged", "Needs second look"]

    /// Writes every email in `scope` to `url` (streamed), signs it and records it as issued.
    static func build(scope: ArchiveScope, title: String, codes: [String], instructions: String,
                      to url: URL, progress: (Int, Int) -> Void) async throws -> IssuedPacks.Entry {
        let key = try ReviewSigningKey.privateKey()
        let total = try await ScopeJobEnvironment.archive.count(query: scope.query)
        let packID = UUID()
        let writer = try SignedLineWriter(url: url)
        let examiner = ForensicManager.shared.examinerName.isEmpty ? String(localized: "Examiner") : ForensicManager.shared.examinerName
        try writer.write(ReviewPackHeader(packID: packID, title: title, createdAt: Date(), createdBy: examiner,
                                          examinerKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                          emailCount: total, codes: codes, instructions: instructions,
                                          scope: ScopeJob.describe(scope.query)))
        var written = 0
        for try await batch in ScopeJobEnvironment.archive.streamFullEmails(query: scope.query, batchSize: 200) {
            try autoreleasepool { for e in batch {
                try writer.write(ReviewPackEmail(
                    id: e.id, date: e.headers["Date"] ?? e.timestamp, from: e.headers["From"] ?? "",
                    to: e.headers["To"] ?? "", cc: e.headers["Cc"] ?? "", subject: e.headers["Subject"] ?? "",
                    body: e.plainBody.isEmpty ? RedactionEngine.plainText(fromHTML: e.htmlBody) : e.plainBody,
                    attachments: e.attachments.map(\.filename),
                    sourceSHA256: Data(SHA256.hash(data: Data(e.rawSource.utf8))).hexString))
                written += 1
            } }
            progress(written, total)
            try Task.checkCancellation()
        }
        guard written == total else {
            throw ReviewPackError.unreadable(String(localized: "the archive changed while the pack was written (\(written) of \(total)); build it again"))
        }
        try writer.finish(signingWith: key)
        let sha = try SignedLineReader.verify(url: url) { first in
            try SignedLineReader.decoder().decode(ReviewPackHeader.self, from: first).examinerKey
        }
        let entry = IssuedPacks.Entry(packID: packID, sha256: sha, title: title, createdAt: Date(), emailCount: written)
        try IssuedPacks.add(entry)
        ScopeJobEnvironment.logAction("Review Pack created", detail: "\(title): \(written) emails — scope: \(ScopeJob.describe(scope.query)); SHA-256 \(sha)")
        return entry
    }
}

struct ReviewMergeConflict: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { emailID }
    var emailID: UUID
    var existing: String
    var proposed: String
    var reviewer: String
    var decidedAt: Date
}

struct ReviewMergeResult: Equatable, Sendable {
    var reviewer = ""
    var decisions = 0
    var codesApplied = 0
    var tagsAdded = 0
    var notesAdded = 0
    var unchanged = 0
    var notInArchive = 0
    var conflicts: [ReviewMergeConflict] = []
}

@MainActor
enum ReviewResponseMerger {
    /// Verifies and merges a response. Nothing is written unless the whole
    /// file verifies. Existing codes are never overwritten.
    static func merge(url: URL) async throws -> ReviewMergeResult {
        var header: ReviewResponseHeader?
        _ = try SignedLineReader.verify(url: url) { first in
            guard let h = try? SignedLineReader.decoder().decode(ReviewResponseHeader.self, from: first),
                  h.kind == "mailin.reviewresponse" else { throw ReviewPackError.wrongKind }
            header = h
            return h.reviewerKey
        }
        guard let header else { throw ReviewPackError.wrongKind }
        guard let issued = IssuedPacks.all().first(where: { $0.packID == header.packID }) else { throw ReviewPackError.unknownPack }
        guard issued.sha256 == header.packSHA256 else { throw ReviewPackError.packChanged }

        var decisions: [ReviewDecision] = []
        var isFirst = true
        try SignedLineReader.forEachLine(url: url) { line in
            if isFirst { isFirst = false; return }
            decisions.append(try SignedLineReader.decoder().decode(ReviewDecision.self, from: line))
        }

        var result = ReviewMergeResult(reviewer: header.reviewer, decisions: decisions.count)
        let forensic = ForensicManager.shared
        let store = ScopeJobEnvironment.store
        for chunk in stride(from: 0, to: decisions.count, by: 500).map({ Array(decisions[$0..<min($0 + 500, decisions.count)]) }) {
            let ids = chunk.map(\.emailID)
            let present = Set(try await ScopeJobEnvironment.archive.summaries(ids: ids).map(\.id))
            let tags = (try? await store.userTags(ids: ids)) ?? [:]
            for d in chunk {
                guard present.contains(d.emailID) else { result.notInArchive += 1; continue }
                var changed = false
                if let code = d.code, let tag = ReviewCodeMapping.evidenceTag(code) {
                    let existing = forensic.tagForEmail(d.emailID)
                    if existing == .none {
                        forensic.applyMergedTag(d.emailID, tag: tag, timestamp: d.decidedAt)
                        result.codesApplied += 1; changed = true
                    } else if existing != tag {
                        result.conflicts.append(.init(emailID: d.emailID, existing: existing.rawValue, proposed: code,
                                                      reviewer: header.reviewer, decidedAt: d.decidedAt))
                    }
                } else if let code = d.code {
                    // A pack-specific code becomes a tag "code:<name>".
                    let tag = "code:\(code)"
                    if !(tags[d.emailID]?.contains(tag) ?? false) {
                        try await store.userTagAdd(tag, ids: [d.emailID]); result.tagsAdded += 1; changed = true
                    }
                }
                for t in d.tags where !(tags[d.emailID]?.contains(t) ?? false) {
                    try await store.userTagAdd(t, ids: [d.emailID]); result.tagsAdded += 1; changed = true
                }
                if let note = d.note, !note.isEmpty {
                    let existing = forensic.annotationFor(d.emailID)?.text ?? ""
                    if !existing.contains(note) {
                        let text = existing.isEmpty ? "[\(header.reviewer)] \(note)" : existing + "\n[\(header.reviewer)] \(note)"
                        forensic.applyMergedAnnotation(d.emailID, annotation: .init(text: text, examiner: header.reviewer, timestamp: d.decidedAt))
                        result.notesAdded += 1; changed = true
                    }
                }
                if !changed { result.unchanged += 1 }
            }
        }
        try ReviewMergeLog.append(header: header, result: result, file: url.lastPathComponent)
        ScopeJobEnvironment.logAction("Review response merged",
                           detail: "\(header.reviewer): \(result.decisions) decisions — \(result.codesApplied) codes, \(result.tagsAdded) tags, \(result.notesAdded) notes applied; \(result.conflicts.count) conflicts; \(result.notInArchive) not in this archive")
        return result
    }
}

enum ReviewCodeMapping {
    /// The four default codes map onto mailin's evidence tags; other codes become tags.
    static func evidenceTag(_ code: String) -> ForensicManager.EvidenceTag? {
        switch code {
        case "Relevant": return .relevant
        case "Not relevant": return .irrelevant
        case "Privileged": return .privileged
        case "Needs second look": return .flagged
        default: return nil
        }
    }
}

/// Every merge, with its conflicts, kept for the lead (append-only JSON Lines).
enum ReviewMergeLog {
    struct Record: Codable { var mergedAt: Date; var file: String; var packID: UUID; var reviewer: String
        var decisions: Int; var applied: Int; var conflicts: [ReviewMergeConflict] }

    static var url: URL { IssuedPacks.url.deletingLastPathComponent().appendingPathComponent("merges.jsonl") }

    static func append(header: ReviewResponseHeader, result: ReviewMergeResult, file: String) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var line = try enc.encode(Record(mergedAt: Date(), file: file, packID: header.packID, reviewer: header.reviewer,
                                         decisions: result.decisions,
                                         applied: result.codesApplied + result.tagsAdded + result.notesAdded,
                                         conflicts: result.conflicts))
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }

    static func openConflicts() -> [ReviewMergeConflict] {
        var out: [ReviewMergeConflict] = []
        guard FileManager.default.fileExists(atPath: url.path) else { return out }
        try? SignedLineReader.forEachLineIncludingLast(url: url) { line in
            if let r = try? SignedLineReader.decoder().decode(Record.self, from: line) { out.append(contentsOf: r.conflicts) }
        }
        return out
    }
}

extension SignedLineReader {
    static func forEachLineIncludingLast(url: URL, _ body: (Data) throws -> Void) throws {
        let tail = try scan(url, line: body)
        if !tail.isEmpty { try body(tail) }
    }
}

// MARK: - Reviewer side (works in any mailin; never touches the reviewer's archive)

struct OpenedReviewPack: Sendable {
    var url: URL
    var header: ReviewPackHeader
    var sha256: String
    /// Line offsets of each email, so bodies are read only when shown.
    var index: [(id: UUID, subject: String, from: String, date: String, offset: UInt64, length: Int)]

    static func open(_ url: URL) throws -> OpenedReviewPack {
        var header: ReviewPackHeader?
        let sha = try SignedLineReader.verify(url: url) { first in
            guard let h = try? SignedLineReader.decoder().decode(ReviewPackHeader.self, from: first),
                  h.kind == "mailin.reviewpack" else { throw ReviewPackError.wrongKind }
            header = h
            return h.examinerKey
        }
        guard let header else { throw ReviewPackError.wrongKind }
        var index: [(id: UUID, subject: String, from: String, date: String, offset: UInt64, length: Int)] = []
        var offset: UInt64 = 0
        var lineNo = 0
        let dec = SignedLineReader.decoder()
        try SignedLineReader.forEachLine(url: url) { line in
            defer { offset += UInt64(line.count + 1); lineNo += 1 }
            guard lineNo > 0 else { return }
            let e = try dec.decode(ReviewPackEmail.self, from: line)
            index.append((e.id, e.subject, e.from, e.date, offset, line.count))
        }
        guard index.count == header.emailCount else { throw ReviewPackError.badSignature }
        return OpenedReviewPack(url: url, header: header, sha256: sha, index: index)
    }

    func email(at i: Int) throws -> ReviewPackEmail {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: index[i].offset)
        guard let data = try h.read(upToCount: index[i].length) else { throw ReviewPackError.unreadable(url.lastPathComponent) }
        return try SignedLineReader.decoder().decode(ReviewPackEmail.self, from: data)
    }

    /// Writes the signed response with every decision made.
    func writeResponse(_ decisions: [UUID: ReviewDecision], reviewer: String, to out: URL) throws {
        let key = try ReviewSigningKey.privateKey()
        let w = try SignedLineWriter(url: out)
        try w.write(ReviewResponseHeader(packID: header.packID, packSHA256: sha256, reviewer: reviewer,
                                         reviewerKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                         createdAt: Date()))
        for entry in index { if let d = decisions[entry.id] { try w.write(d) } }
        try w.finish(signingWith: key)
    }
}
