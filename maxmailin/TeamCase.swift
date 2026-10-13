//
//  TeamCase.swift
//  maxmailin
//
//  3.1/3.2 T1–T13 (switch: `v31TeamCase`, preview, off; needs `v31ReviewPack`)
//  — several reviewers on one case, with no server and no network.
//
//  A case is a folder on a shared drive (NAS, file server, external disk):
//
//    <title>.mailincase/
//      manifest.json            case id, title, codes, batch list, QC rate
//      evidence.mailinpack      read-only, signed copy of the emails (Review Pack format)
//      logs/<key-id>.jsonl      one append-only log per reviewer device
//      leases/<batch>.lease     who has a batch checked out, until when
//
//  Every log entry is signed with the author's device key (Ed25519, Keychain)
//  and chained to the previous entry's hash. Nobody writes another person's
//  log, so there is never a write conflict on the share. The case state is
//  the fold of every log in Lamport-clock order (ties broken by author key,
//  then sequence) — any machine that reads the same logs reaches the same
//  state. Different codes on one email become a conflict with both decisions
//  kept; a lead resolves it with a further entry; nothing is overwritten.
//
//  A torn last line (share unplugged mid-write) is ignored and reported; an
//  entry whose signature or chain does not verify stops that log there and is
//  reported as tampered.
//

import Foundation
import CryptoKit
@testable import ArchiveCore

// MARK: - Files

struct TeamCaseManifest: Codable, Equatable, Sendable {
    var kind = "mailin.case"
    var version = 1
    var caseID: UUID
    var title: String
    var createdAt: Date
    var createdBy: String
    var leadKey: String
    var codes: [String]
    /// Email ids per batch, in pack order.
    var batches: [[UUID]]
    /// Share of each reviewer's coded emails sent to QC (0–100).
    var qcPercent: Int
    /// T6: extra coding fields with rules (nil on cases made before 3.1 T6).
    var layout: CodingLayout? = nil
}

/// T6: the coding form of a case — fields with fixed choices, which are
/// required, which take several choices, and choices that exclude each other.
struct CodingLayout: Codable, Equatable, Sendable {
    struct Field: Codable, Equatable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var choices: [String]
        var required = false
        var multiple = false
    }
    var fields: [Field]
    /// Sets of choices (from any field, or the main codes) that may not be chosen together.
    var exclusive: [[String]] = []

    static let standard = CodingLayout(fields: [
        Field(name: "Issues", choices: ["Contract", "Employment", "Financial", "Regulatory", "Other"], multiple: true),
        Field(name: "Confidentiality", choices: ["Public", "Confidential", "Highly confidential"], required: true),
    ], exclusive: [["Privileged", "Public"]])

    /// Problems with one email's coding; empty = it may be saved.
    func problems(code: String?, values: [String: [String]]) -> [String] {
        var out: [String] = []
        if code == nil { out.append(String(localized: "Choose a code.")) }
        for f in fields {
            let v = values[f.name] ?? []
            if f.required && v.isEmpty { out.append(String(localized: "“\(f.name)” is required.")) }
            if !f.multiple && v.count > 1 { out.append(String(localized: "“\(f.name)” takes one choice.")) }
            for c in v where !f.choices.contains(c) { out.append(String(localized: "“\(c)” is not a choice for “\(f.name)”.")) }
        }
        let chosen = Set(values.values.flatMap { $0 } + (code.map { [$0] } ?? []))
        for set in exclusive where Set(set).intersection(chosen).count > 1 {
            out.append(String(localized: "These cannot be chosen together: \(set.joined(separator: ", "))."))
        }
        return out
    }

    /// Log value for one field: "Name=a|b".
    static func encode(_ name: String, _ choices: [String]) -> String { name + "=" + choices.joined(separator: "|") }
    static func decode(_ value: String) -> (String, [String])? {
        guard let eq = value.firstIndex(of: "=") else { return nil }
        let rest = value[value.index(after: eq)...]
        return (String(value[..<eq]), rest.isEmpty ? [] : rest.split(separator: "|").map(String.init))
    }
}

struct TeamLogEntry: Codable, Equatable, Sendable {
    enum Op: String, Codable, Sendable {
        case join, code, tagAdd, tagRemove, note, checkout, release, batchDone, reviewLater, qcCode, resolve
        /// T6: one coding field, value "Name=a|b".
        case field
    }
    var seq: Int
    var lamport: Int
    var author: String          // public key, base64
    var authorName: String
    var role: String
    var at: Date
    var op: Op
    var emailID: UUID?
    var batch: Int?
    var value: String
    var prevHash: String
    var signature: String = ""

    /// Bytes that are signed (everything but the signature).
    func signedBytes() throws -> Data {
        var copy = self
        copy.signature = ""
        return try TeamCaseIO.encoder.encode(copy)
    }

    var hash: String { ((try? signedBytes()).map { Data(SHA256.hash(data: $0)).hexString } ?? "") + signature.prefix(16) }
}

struct TeamLease: Codable, Equatable, Sendable {
    var batch: Int
    var holder: String
    var holderName: String
    var expires: Date
}

enum TeamCaseIO {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func keyID(_ publicKeyB64: String) -> String {
        String(Data(SHA256.hash(data: Data(publicKeyB64.utf8))).hexString.prefix(16))
    }

    /// Write-then-rename, so a reader never sees half a file.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

// MARK: - State (the fold of all logs)

struct TeamConflict: Equatable, Sendable, Identifiable {
    var id: UUID { emailID }
    var emailID: UUID
    /// reviewer name → code
    var decisions: [String: String]
}

struct TeamCaseState: Equatable, Sendable {
    struct EmailState: Equatable, Sendable {
        /// author key → (code, lamport)
        var codes: [String: String] = [:]
        var resolved: String?
        /// tag → holders (a tag stays while any reviewer holds it)
        var tags: [String: Set<String>] = [:]
        var notes: [String] = []
        var qcCode: String?
        var qcBy: String?
        var reviewLater: Set<String> = []
        var firstCoder: String?
        /// T6: author key → field → choices.
        var fields: [String: [String: [String]]] = [:]
    }
    var emails: [UUID: EmailState] = [:]
    var members: [String: (name: String, role: String)] = [:]
    var batchDone: Set<Int> = []
    var problems: [String] = []
    var maxLamport = 0
    var entryCount = 0
    /// T10: codes per reviewer per day ("2026-10-13").
    var codedPerDay: [String: [String: Int]] = [:]

    static func == (a: TeamCaseState, b: TeamCaseState) -> Bool {
        a.emails == b.emails && a.batchDone == b.batchDone && a.entryCount == b.entryCount
            && a.members.mapValues { "\($0.name)|\($0.role)" } == b.members.mapValues { "\($0.name)|\($0.role)" }
    }

    func name(_ key: String) -> String { members[key]?.name ?? String(key.prefix(8)) }

    /// The code that stands: a resolution, or the codes if all agree.
    func code(_ id: UUID) -> String? {
        guard let e = emails[id] else { return nil }
        if let r = e.resolved { return r }
        let distinct = Set(e.codes.values)
        return distinct.count == 1 ? distinct.first : nil
    }

    var conflicts: [TeamConflict] {
        emails.compactMap { id, e in
            guard e.resolved == nil, Set(e.codes.values).count > 1 else { return nil }
            return TeamConflict(emailID: id, decisions: Dictionary(uniqueKeysWithValues: e.codes.map { (name($0.key), $0.value) }))
        }.sorted { $0.emailID.uuidString < $1.emailID.uuidString }
    }

    /// T7: QC results per reviewer: checked, overturned, error rate with a
    /// 95 % Wilson interval.
    func qcStats() -> [(reviewer: String, checked: Int, overturned: Int, rate: Double, low: Double, high: Double)] {
        var checked: [String: Int] = [:], over: [String: Int] = [:]
        for e in emails.values {
            guard let qc = e.qcCode, let coder = e.firstCoder, let original = e.codes[coder] else { continue }
            checked[coder, default: 0] += 1
            if qc != original { over[coder, default: 0] += 1 }
        }
        return checked.map { k, n in
            let x = Double(over[k] ?? 0), nn = Double(n), z = 1.96
            let p = x / nn
            let denom = 1 + z * z / nn
            let centre = (p + z * z / (2 * nn)) / denom
            let half = z * ((p * (1 - p) / nn + z * z / (4 * nn * nn)).squareRoot()) / denom
            return (name(k), n, over[k] ?? 0, p, max(0, centre - half), min(1, centre + half))
        }.sorted { $0.reviewer < $1.reviewer }
    }
}

// MARK: - Case

final class TeamCase: @unchecked Sendable {
    let folder: URL
    let manifest: TeamCaseManifest
    let evidence: OpenedReviewPack
    private let key: Curve25519.Signing.PrivateKey
    let myKey: String
    let myName: String
    let myRole: String

    static let leaseDuration: TimeInterval = 4 * 3600

    var logsDir: URL { folder.appendingPathComponent("logs", isDirectory: true) }
    var leasesDir: URL { folder.appendingPathComponent("leases", isDirectory: true) }
    var myLog: URL { logsDir.appendingPathComponent(TeamCaseIO.keyID(myKey) + ".jsonl") }

    /// `signingKey` is for tests (two reviewers on one machine); the app uses the device key.
    init(folder: URL, name: String, role: String, signingKey: Curve25519.Signing.PrivateKey? = nil) throws {
        self.folder = folder
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        manifest = try TeamCaseIO.decoder.decode(TeamCaseManifest.self, from: data)
        guard manifest.kind == "mailin.case" else { throw ReviewPackError.wrongKind }
        evidence = try OpenedReviewPack.open(folder.appendingPathComponent("evidence.\(ReviewPackFormat.packExtension)"))
        key = try signingKey ?? ReviewSigningKey.privateKey()
        myKey = key.publicKey.rawRepresentation.base64EncodedString()
        myName = name
        myRole = role
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leasesDir, withIntermediateDirectories: true)
    }

    /// T1: creates a case folder from a scope (lead only).
    @MainActor
    static func create(in parent: URL, title: String, scope: ArchiveScope, batchSize: Int, qcPercent: Int,
                       layout: CodingLayout? = .standard,
                       progress: @escaping (Int, Int) -> Void) async throws -> URL {
        if let why = OrgPolicy.denial(.export) { throw ReviewPackError.unreadable(why) }
        let folder = parent.appendingPathComponent("\(title).mailincase", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let packURL = folder.appendingPathComponent("evidence.\(ReviewPackFormat.packExtension)")
        _ = try await ReviewPackBuilder.build(scope: scope, title: title, codes: ReviewPackBuilder.defaultCodes,
                                              instructions: "", to: packURL, progress: progress)
        let pack = try OpenedReviewPack.open(packURL)
        let ids = pack.index.map(\.id)
        let size = max(1, batchSize)
        let batches = stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
        let examiner = ForensicManager.shared.examinerName.isEmpty ? String(localized: "Lead") : ForensicManager.shared.examinerName
        let manifest = TeamCaseManifest(caseID: pack.header.packID, title: title, createdAt: Date(), createdBy: examiner,
                                        leadKey: try ReviewSigningKey.publicKeyBase64(), codes: ReviewPackBuilder.defaultCodes,
                                        batches: batches, qcPercent: max(0, min(100, qcPercent)), layout: layout)
        try TeamCaseIO.atomicWrite(try TeamCaseIO.encoder.encode(manifest), to: folder.appendingPathComponent("manifest.json"))
        // The evidence copy is read-only for everyone (rule 1).
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: packURL.path)
        ScopeJobEnvironment.logAction("Team case created", detail: "\(title): \(ids.count) emails in \(batches.count) batches at \(folder.path)")
        return folder
    }

    // MARK: Reading (T3/T12)

    /// What has been read and verified of one log so far (T12: logs only
    /// grow, so each load reads just the bytes appended since the last one).
    struct LogCache {
        var parsedBytes = 0
        var lineNo = 0
        var entries: [TeamLogEntry] = []
        var prev = ""
        var author: String?
        var problems: [String] = []
        var stopped = false
    }
    private var caches: [String: LogCache] = [:]
    private let cacheLock = NSLock()

    /// Reads and verifies every log; returns the folded state.
    func load() -> TeamCaseState {
        var all: [TeamLogEntry] = []
        var problems: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let c = cached(file)
            all += c.entries
            problems += c.problems
            if let tail = Self.tornTail(file, after: c.parsedBytes) { problems.append(tail) }
        }
        var state = Self.fold(all, manifest: manifest)
        state.problems = problems
        return state
    }

    private func cached(_ url: URL) -> LogCache {
        cacheLock.lock(); defer { cacheLock.unlock() }
        var c = caches[url.lastPathComponent] ?? LogCache()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size < c.parsedBytes { c = LogCache() }       // replaced or truncated: read again from the start
        Self.readMore(url, into: &c)
        caches[url.lastPathComponent] = c
        return c
    }

    /// Whole-log read (tests and one-off checks).
    static func readLog(_ url: URL) -> ([TeamLogEntry], [String]) {
        var c = LogCache()
        readMore(url, into: &c)
        var problems = c.problems
        if let tail = tornTail(url, after: c.parsedBytes) { problems.append(tail) }
        return (c.entries, problems)
    }

    static func tornTail(_ url: URL, after offset: Int) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > offset ? "\(url.lastPathComponent): last line incomplete (interrupted write) — ignored" : nil
    }

    /// Parses complete lines after `c.parsedBytes`. A line that cannot be read
    /// (an interrupted write that a later entry follows) is skipped and
    /// reported — the chain still proves nothing was removed. A line whose
    /// signature or chain fails stops the log there (tampered).
    static func readMore(_ url: URL, into c: inout LogCache) {
        guard !c.stopped, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(c.parsedBytes))
        guard let data = try? h.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNL]
        var start = complete.startIndex
        while start < complete.endIndex, !c.stopped {
            let nl = complete[start...].firstIndex(of: 0x0A) ?? complete.endIndex
            let line = complete[start..<nl]
            start = complete.index(after: nl)
            c.lineNo += 1
            if line.isEmpty { continue }
            guard let e = try? TeamCaseIO.decoder.decode(TeamLogEntry.self, from: Data(line)) else {
                c.problems.append("\(url.lastPathComponent): line \(c.lineNo) unreadable (interrupted write) — skipped")
                continue
            }
            if c.author == nil { c.author = e.author }
            guard e.author == c.author, e.prevHash == c.prev, e.seq == c.entries.count,
                  let keyData = Data(base64Encoded: e.author),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  let sig = Data(base64Encoded: e.signature),
                  let bytes = try? e.signedBytes(), key.isValidSignature(sig, for: bytes) else {
                c.problems.append("\(url.lastPathComponent): entry \(c.lineNo) fails its signature or chain (tampered) — the rest of this log was not used")
                c.stopped = true
                break
            }
            c.entries.append(e)
            c.prev = e.hash
        }
        c.parsedBytes += complete.count
    }

    /// Deterministic fold: Lamport, then author, then seq.
    static func fold(_ entries: [TeamLogEntry], manifest: TeamCaseManifest) -> TeamCaseState {
        var s = TeamCaseState()
        let sorted = entries.sorted { ($0.lamport, $0.author, $0.seq) < ($1.lamport, $1.author, $1.seq) }
        for e in sorted {
            s.maxLamport = max(s.maxLamport, e.lamport)
            s.entryCount += 1
            if s.members[e.author] == nil || e.op == .join { s.members[e.author] = (e.authorName, e.role) }
            guard let id = e.emailID else {
                if e.op == .batchDone, let b = e.batch { s.batchDone.insert(b) }
                continue
            }
            var em = s.emails[id] ?? .init()
            switch e.op {
            case .code:
                if em.firstCoder == nil { em.firstCoder = e.author }
                if em.codes[e.author] == nil {
                    s.codedPerDay[e.author, default: [:]][TeamCaseIO.day(e.at), default: 0] += 1
                }
                em.codes[e.author] = e.value
            case .field:
                if let (name, choices) = CodingLayout.decode(e.value) { em.fields[e.author, default: [:]][name] = choices }
            case .tagAdd: em.tags[e.value, default: []].insert(e.author)
            case .tagRemove:
                em.tags[e.value]?.remove(e.author)
                if em.tags[e.value]?.isEmpty == true { em.tags[e.value] = nil }
            case .note: em.notes.append("[\(e.authorName)] \(e.value)")
            case .reviewLater:
                if e.value == "off" { em.reviewLater.remove(e.author) } else { em.reviewLater.insert(e.author) }
            case .qcCode:
                // QC counts only from Examiner or higher (T5), never from the first coder.
                if TeamCase.mayQC(OrgRole(rawValue: e.role) ?? .viewer), e.author != em.firstCoder {
                    em.qcCode = e.value; em.qcBy = e.author
                }
            case .resolve:
                // Only the lead's resolution counts.
                if e.author == manifest.leadKey { em.resolved = e.value }
            case .join, .checkout, .release, .batchDone: break
            }
            s.emails[id] = em
        }
        return s
    }

    // MARK: Writing

    /// Appends one signed entry to this device's own log.
    func append(_ op: TeamLogEntry.Op, emailID: UUID? = nil, batch: Int? = nil, value: String = "", state: TeamCaseState) throws {
        let mine = cached(myLog)
        guard !mine.stopped else {
            throw ReviewPackError.unreadable(String(localized: "Your own log in this case fails its check; nothing more is written to it."))
        }
        var e = TeamLogEntry(seq: mine.entries.count, lamport: max(state.maxLamport, mine.entries.last?.lamport ?? 0) + 1,
                             author: myKey, authorName: myName, role: myRole, at: Date(), op: op,
                             emailID: emailID, batch: batch, value: value, prevHash: mine.entries.last?.hash ?? "")
        e.signature = try key.signature(for: try e.signedBytes()).base64EncodedString()
        var line = try TeamCaseIO.encoder.encode(e)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: myLog.path) {
            FileManager.default.createFile(atPath: myLog.path, contents: nil)
        } else if Self.tornTail(myLog, after: mine.parsedBytes) != nil {
            // A torn previous write: start the next entry on a fresh line.
            line.insert(0x0A, at: 0)
        }
        let h = try FileHandle(forWritingTo: myLog)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
        try h.synchronize()
    }

    // MARK: Batches (T5)

    func lease(_ batch: Int) -> TeamLease? {
        let url = leasesDir.appendingPathComponent("\(batch).lease")
        guard let d = try? Data(contentsOf: url), let l = try? TeamCaseIO.decoder.decode(TeamLease.self, from: d) else { return nil }
        return l.expires > Date() ? l : nil
    }

    /// Checks a batch out. Exclusive create, so two reviewers can never both
    /// win; an expired lease is reclaimed.
    func checkout(_ batch: Int, state: TeamCaseState) throws -> Bool {
        if state.batchDone.contains(batch) { return false }
        guard Self.mayReview(OrgRole(rawValue: myRole) ?? .viewer) else {
            throw ReviewPackError.unreadable(String(localized: "Your role may not review batches."))
        }
        let url = leasesDir.appendingPathComponent("\(batch).lease")
        if let l = lease(batch) { return l.holder == myKey }
        try? FileManager.default.removeItem(at: url)   // expired
        let data = try TeamCaseIO.encoder.encode(TeamLease(batch: batch, holder: myKey, holderName: myName,
                                                           expires: Date().addingTimeInterval(Self.leaseDuration)))
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        fsync(fd)
        try append(.checkout, batch: batch, state: state)
        return true
    }

    func release(_ batch: Int, done: Bool, state: TeamCaseState) throws {
        guard lease(batch)?.holder == myKey else { return }
        try FileManager.default.removeItem(at: leasesDir.appendingPathComponent("\(batch).lease"))
        try append(done ? .batchDone : .release, batch: batch, state: state)
    }

    /// "Done" means every email in the batch has a code from this reviewer.
    func batchComplete(_ batch: Int, state: TeamCaseState) -> Bool {
        manifest.batches[batch].allSatisfy { id in
            guard let em = state.emails[id], let code = em.codes[myKey] else { return false }
            return manifest.layout?.problems(code: code, values: em.fields[myKey] ?? [:]).isEmpty ?? true
        }
    }

    /// T6: saves one email's coding only when it passes the layout's rules.
    func saveCoding(_ id: UUID, code: String, values: [String: [String]], state: TeamCaseState) throws -> [String] {
        if let layout = manifest.layout {
            let problems = layout.problems(code: code, values: values)
            guard problems.isEmpty else { return problems }
        }
        try append(.code, emailID: id, value: code, state: state)
        var current = state
        current.maxLamport += 1
        for (name, choices) in values.sorted(by: { $0.key < $1.key }) {
            try append(.field, emailID: id, value: CodingLayout.encode(name, choices), state: current)
            current.maxLamport += 1
        }
        return []
    }

    // MARK: Roles (T5)

    /// Checking out a batch needs Reviewer or higher; QC and resolving need Examiner.
    static func mayReview(_ role: OrgRole) -> Bool { role >= .reviewer }
    static func mayQC(_ role: OrgRole) -> Bool { role >= .examiner }

    // MARK: AI vs human (T8)

    /// Emails whose stored predictive score strongly disagrees with the code
    /// that stands (≥ 0.8 but coded Not relevant, ≤ 0.2 but coded Relevant).
    /// Only emails this archive has scored are considered.
    func aiDisagreements(state: TeamCaseState, analysis: [UUID: StoredAnalysis]) -> [(id: UUID, code: String, score: Double)] {
        evidence.index.compactMap { entry in
            guard let code = state.code(entry.id), let score = analysis[entry.id]?.predictive else { return nil }
            if score >= 0.8 && code == "Not relevant" { return (entry.id, code, score) }
            if score <= 0.2 && code == "Relevant" { return (entry.id, code, score) }
            return nil
        }
    }

    func firstUncoded(_ batch: Int, state: TeamCaseState) -> UUID? {
        manifest.batches[batch].first { state.emails[$0]?.codes[myKey] == nil }
    }

    // MARK: QC (T7)

    /// Emails coded by others, sampled deterministically at `qcPercent`.
    func qcQueue(state: TeamCaseState) -> [UUID] {
        state.emails.compactMap { id, e -> UUID? in
            guard let coder = e.firstCoder, coder != myKey, e.qcCode == nil else { return nil }
            let h = SHA256.hash(data: Data((id.uuidString + manifest.caseID.uuidString).utf8))
            return Int(Array(h)[0]) * 100 / 256 < manifest.qcPercent ? id : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: Privilege log (T9)

    /// One row per email whose standing (agreed or resolved) code is Privileged.
    func privilegeLogCSV(state: TeamCaseState) throws -> (csv: String, rows: Int) {
        var text = csvRow(["Email ID", "Date", "From", "To", "Subject", "Decided by", "Basis (notes)"])
        var rows = 0
        for (i, entry) in evidence.index.enumerated() where state.code(entry.id) == "Privileged" {
            let e = try evidence.email(at: i)
            let em = state.emails[entry.id]
            let by = em.map { s in s.resolved != nil ? String(localized: "lead (resolved)") : s.codes.keys.map(state.name).sorted().joined(separator: ", ") } ?? ""
            text += csvRow([e.id.uuidString, e.date, e.from, e.to, e.subject, by, em?.notes.joined(separator: " | ") ?? ""])
            rows += 1
        }
        return (text, rows)
    }

    // MARK: Migration (T14)

    /// Brings a 3.0 `.mailinreview` exchange file into the case as entries in
    /// this device's log (each marked as imported). Only emails in the case
    /// are taken; the file itself is not changed.
    func importLegacyReview(_ data: Data, state: TeamCaseState) throws -> Int {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let pkg = try dec.decode(ExportManager.ReviewStatePackage.self, from: data)
        let inCase = Set(evidence.index.map(\.id))
        var current = state
        var n = 0
        for (idStr, tag) in pkg.evidenceTags.sorted(by: { $0.key < $1.key }) {
            guard let id = UUID(uuidString: idStr), inCase.contains(id) else { continue }
            let code: String?
            switch ForensicManager.EvidenceTag(rawValue: tag) {
            case .relevant: code = "Relevant"
            case .irrelevant: code = "Not relevant"
            case .privileged: code = "Privileged"
            case .flagged, .suspicious: code = "Needs second look"
            default: code = nil
            }
            guard let code else { continue }
            try append(.code, emailID: id, value: code, state: current)
            try append(.note, emailID: id, value: String(localized: "imported from a review file by \(pkg.exportedBy) (\(pkg.exportDate.formatted()))"), state: current)
            current.maxLamport += 2
            n += 1
        }
        for (idStr, a) in pkg.annotations.sorted(by: { $0.key < $1.key }) {
            guard let id = UUID(uuidString: idStr), inCase.contains(id) else { continue }
            try append(.note, emailID: id, value: "[\(a.examiner)] \(a.text)", state: current)
            current.maxLamport += 1
            n += 1
        }
        return n
    }

    // MARK: Audit (T11) and production (T13)

    /// Every verified entry of every log, in fold order, as JSON Lines.
    func mergedAudit() -> Data {
        var all: [TeamLogEntry] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "jsonl" { all += Self.readLog(f).0 }
        var out = Data()
        for e in all.sorted(by: { ($0.lamport, $0.author, $0.seq) < ($1.lamport, $1.author, $1.seq) }) {
            if let d = try? TeamCaseIO.encoder.encode(e) { out.append(d); out.append(0x0A) }
        }
        return out
    }

    /// T13: the lead brings the resolved codes and tags into the archive.
    /// Existing codes in the archive are never replaced.
    @MainActor
    func applyToArchive(state: TeamCaseState) async throws -> (codes: Int, tags: Int, skipped: Int) {
        guard myKey == manifest.leadKey else { throw ReviewPackError.unreadable(String(localized: "only the case lead can apply the case to the archive")) }
        if let why = OrgPolicy.denial(.produce) { throw ReviewPackError.unreadable(why) }
        var codes = 0, tags = 0, skipped = 0
        let forensic = ForensicManager.shared
        for (id, e) in state.emails {
            if let c = state.code(id), let t = ReviewCodeMapping.evidenceTag(c) {
                if forensic.tagForEmail(id) == .none { forensic.applyMergedTag(id, tag: t, timestamp: Date()); codes += 1 }
                else if forensic.tagForEmail(id) != t { skipped += 1 }
            }
            for tag in e.tags.keys {
                try await ScopeJobEnvironment.store.userTagAdd(tag, ids: [id]); tags += 1
            }
        }
        ScopeJobEnvironment.logAction("Team case applied", detail: "\(manifest.title): \(codes) codes, \(tags) tags applied; \(skipped) kept the archive's existing code")
        return (codes, tags, skipped)
    }
}
