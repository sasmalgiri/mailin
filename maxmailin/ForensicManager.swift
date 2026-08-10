import Foundation
import CryptoKit
import SwiftUI
import os.log

private let forensicLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Forensic")

@MainActor
class ForensicManager: ObservableObject {
    static let shared = ForensicManager()

    @AppStorage("forensicModeEnabled") var isEnabled = false
    @AppStorage("forensicCaseNumber") var caseNumber = ""
    @AppStorage("forensicExaminerName") var examinerName = ""
    @AppStorage("forensicOrganization") var organization = ""

    // §21: SQLite (shared canonical DB) is the durable authority for all
    // forensic state. The @Published values below are BOUNDED caches:
    //   • sourceFileHashes — one row per imported file (naturally bounded).
    //   • auditLog — the most recent `auditDisplayLimit` entries only;
    //     verification/export stream the full log from the DB in order.
    //   • evidenceTags/tagTimestamps/annotations — hydrated up to
    //     `tagHydrationCap` rows; exact counts/ID sets come from SQL.
    //   • perEmailHashes — visible-window/import-batch cache only (never the
    //     archive); rows are fetched per window/export batch from the DB.
    @Published var sourceFileHashes: [SourceFileHash] = []
    @Published private(set) var auditLog: [AuditEntry] = []
    @Published private(set) var auditTotalCount: Int = 0
    @Published var evidenceTags: [UUID: EvidenceTag] = [:]
    @Published var tagTimestamps: [UUID: Date] = [:]
    @Published var annotations: [UUID: Annotation] = [:]
    @Published var perEmailHashes: [UUID: EmailHash] = [:]
    @Published var integrityStatus: IntegrityStatus = .unknown

    static let auditDisplayLimit = 500
    static let tagHydrationCap = 50_000
    static let hashWindowCap = 5_000

    /// Durable backing store (the shared canonical SQLite DB). Test seam.
    static var testStoreOverride: SQLiteEmailStore?
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }

    /// Chain cursor for O(1) appends without holding the whole log.
    private var auditSequence = 0
    private var lastAuditHash = "GENESIS"
    /// H2: appends are queued until the durable chain cursor is loaded —
    /// otherwise an early logAction would collide with existing seq numbers
    /// (PRIMARY KEY violation → false 'tampered') or fork the chain.
    private var chainReady = false
    private var pendingActions: [(action: String, detail: String)] = []

    private static let hmacKeychainKey = "forensicHMACKey"

    private lazy var hmacKey: SymmetricKey = {
        let existing = KeychainHelper.load(key: Self.hmacKeychainKey)
        if !existing.isEmpty, let data = Data(base64Encoded: existing) {
            return SymmetricKey(data: data)
        }
        var keyBytes = [UInt8](repeating: 0, count: 32)
        var status = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        if status != errSecSuccess {
            status = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
            if status != errSecSuccess {
                keyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
            }
        }
        let keyData = Data(keyBytes)
        KeychainHelper.save(key: Self.hmacKeychainKey, value: keyData.base64EncodedString())
        return SymmetricKey(data: keyData)
    }()

    private var installID: String {
        if let existing = UserDefaults.standard.string(forKey: "forensicInstallID") {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "forensicInstallID")
        return newID
    }

    // MARK: - Data Types

    private static let currentDataVersion = 1

    struct SourceFileHash: Identifiable, Codable, Sendable {
        let id: UUID
        let filename: String
        let fileSize: Int64
        let md5: String
        let sha1: String
        let sha256: String
        let importDate: Date
        let version: Int

        init(id: UUID, filename: String, fileSize: Int64, md5: String, sha1: String, sha256: String, importDate: Date) {
            self.id = id; self.filename = filename; self.fileSize = fileSize
            self.md5 = md5; self.sha1 = sha1; self.sha256 = sha256; self.importDate = importDate; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            filename = try c.decode(String.self, forKey: .filename)
            fileSize = try c.decode(Int64.self, forKey: .fileSize)
            md5 = try c.decode(String.self, forKey: .md5)
            sha1 = try c.decode(String.self, forKey: .sha1)
            sha256 = try c.decode(String.self, forKey: .sha256)
            importDate = try c.decode(Date.self, forKey: .importDate)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    struct AuditEntry: Identifiable, Codable, Sendable {
        let id: UUID
        let sequence: Int
        let timestamp: Date
        let action: String
        let detail: String
        let examiner: String
        let previousHash: String
        let entryHash: String
        let version: Int

        init(id: UUID, sequence: Int, timestamp: Date, action: String, detail: String, examiner: String, previousHash: String, entryHash: String) {
            self.id = id; self.sequence = sequence; self.timestamp = timestamp
            self.action = action; self.detail = detail; self.examiner = examiner
            self.previousHash = previousHash; self.entryHash = entryHash; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            sequence = try c.decode(Int.self, forKey: .sequence)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            action = try c.decode(String.self, forKey: .action)
            detail = try c.decode(String.self, forKey: .detail)
            examiner = try c.decode(String.self, forKey: .examiner)
            previousHash = try c.decode(String.self, forKey: .previousHash)
            entryHash = try c.decode(String.self, forKey: .entryHash)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    struct EmailHash: Codable, Sendable {
        let md5: String
        let sha1: String
        let sha256: String
        let byteCount: Int
        let version: Int

        init(md5: String, sha1: String, sha256: String, byteCount: Int) {
            self.md5 = md5; self.sha1 = sha1; self.sha256 = sha256; self.byteCount = byteCount; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            md5 = try c.decode(String.self, forKey: .md5)
            sha1 = try c.decode(String.self, forKey: .sha1)
            sha256 = try c.decode(String.self, forKey: .sha256)
            byteCount = try c.decode(Int.self, forKey: .byteCount)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    struct Annotation: Codable, Sendable {
        let text: String
        let examiner: String
        let timestamp: Date
        let version: Int

        init(text: String, examiner: String, timestamp: Date) {
            self.text = text; self.examiner = examiner; self.timestamp = timestamp; self.version = 1
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            examiner = try c.decode(String.self, forKey: .examiner)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }
    }

    enum IntegrityStatus: Equatable {
        case unknown
        case verified
        case tampered(details: String)
        case noData
    }

    enum EvidenceTag: String, CaseIterable, Codable {
        case none = "None"
        case relevant = "Relevant"
        case privileged = "Privileged"
        case irrelevant = "Irrelevant"
        case flagged = "Flagged"
        case suspicious = "Suspicious"

        var color: Color {
            switch self {
            case .none: return .secondary
            case .relevant: return .green
            case .privileged: return .orange
            case .irrelevant: return .gray
            case .flagged: return .red
            case .suspicious: return .purple
            }
        }

        var icon: String {
            switch self {
            case .none: return "tag"
            case .relevant: return "checkmark.seal.fill"
            case .privileged: return "lock.shield.fill"
            case .irrelevant: return "xmark.circle"
            case .flagged: return "flag.fill"
            case .suspicious: return "exclamationmark.triangle.fill"
            }
        }
    }

    // MARK: - File URLs

    private static let appSupportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let auditLogURL = appSupportDir.appendingPathComponent("forensic_audit_log.json")
    private let hashesURL = appSupportDir.appendingPathComponent("forensic_hashes.json")
    private let tagsURL = appSupportDir.appendingPathComponent("forensic_tags.json")
    private let annotationsURL = appSupportDir.appendingPathComponent("forensic_annotations.json")
    private let emailHashesURL = appSupportDir.appendingPathComponent("forensic_email_hashes.json")
    private let chainRootURL = appSupportDir.appendingPathComponent("forensic_chain_root.txt")

    private init() {
        Task { @MainActor in await bootstrapFromStore() }
    }

    /// Test-visible bootstrap: migrate legacy JSON once, then hydrate the
    /// bounded caches from the durable tables.
    func bootstrapFromStore() async {
        await migrateLegacyJSONIfNeeded()
        do {
            let sources = try await store.forensicSourceHashes()
            sourceFileHashes = sources.map {
                SourceFileHash(id: UUID(), filename: $0.filename, fileSize: $0.fileSize,
                               md5: $0.md5, sha1: $0.sha1, sha256: $0.sha256, importDate: $0.importedAt)
            }
            auditTotalCount = try await store.forensicAuditCount()
            let recent = try await store.forensicAuditRecent(limit: Self.auditDisplayLimit)
            auditLog = recent.reversed().map {
                AuditEntry(id: $0.entryID, sequence: $0.seq, timestamp: $0.timestamp,
                           action: $0.action, detail: $0.detail, examiner: $0.examiner,
                           previousHash: $0.previousHash, entryHash: $0.entryHash)
            }
            if let last = try await store.forensicAuditLast() {
                auditSequence = last.seq + 1
                lastAuditHash = last.entryHash
            } else {
                auditSequence = 0
                lastAuditHash = "GENESIS"
            }
            chainReady = true
            drainPendingActions()
            // Bounded tag/annotation hydration (display cache; SQL is exact).
            var tagOffset = 0
            evidenceTags = [:]; tagTimestamps = [:]
            while tagOffset < Self.tagHydrationCap {
                let page = try await store.forensicTagsPage(limit: 2_000, offset: tagOffset)
                if page.isEmpty { break }
                for row in page {
                    if let tag = EvidenceTag(rawValue: row.tag) {
                        evidenceTags[row.id] = tag
                        tagTimestamps[row.id] = row.taggedAt
                    }
                }
                tagOffset += page.count
                if page.count < 2_000 { break }
            }
            var noteOffset = 0
            annotations = [:]
            while noteOffset < Self.tagHydrationCap {
                let page = try await store.forensicAnnotationsPage(limit: 2_000, offset: noteOffset)
                if page.isEmpty { break }
                for row in page {
                    annotations[row.id] = Annotation(text: row.note, examiner: row.examiner, timestamp: row.createdAt)
                }
                noteOffset += page.count
                if page.count < 2_000 { break }
            }
        } catch {
            forensicLog.error("forensic bootstrap failed: \(error.localizedDescription, privacy: .public)")
            // Chain cursor unknown — surface, and unblock queued appends
            // against the (possibly empty) durable log rather than dropping
            // them; a residual seq collision throws loudly per-append.
            integrityStatus = .tampered(details: "Audit chain could not be loaded: \(error.localizedDescription)")
            chainReady = true
            drainPendingActions()
        }
    }

    private func drainPendingActions() {
        let queued = pendingActions
        pendingActions = []
        for entry in queued { logAction(entry.action, detail: entry.detail) }
    }

    /// §21: hydrate the visible window's forensic state (hashes, tags,
    /// annotations) in one bounded pass — call when the page changes or a
    /// streamed export processes a batch.
    func prefetchForensicWindow(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let hashes = try await store.forensicHashes(ids: ids)
            for (id, h) in hashes {
                perEmailHashes[id] = EmailHash(md5: h.md5, sha1: h.sha1, sha256: h.sha256, byteCount: h.byteCount)
            }
            trimHashWindow(keeping: ids)
            let tags = try await store.forensicTags(ids: ids)
            for (id, t) in tags {
                if let tag = EvidenceTag(rawValue: t.tag) {
                    evidenceTags[id] = tag
                    tagTimestamps[id] = t.taggedAt
                }
            }
            let notes = try await store.forensicAnnotations(ids: ids)
            for (id, n) in notes {
                annotations[id] = Annotation(text: n.note, examiner: n.examiner, timestamp: n.createdAt)
            }
        } catch {
            forensicLog.error("forensic window prefetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimHashWindow(keeping recent: [UUID]) {
        guard perEmailHashes.count > Self.hashWindowCap else { return }
        let keep = Set(recent)
        for key in perEmailHashes.keys where !keep.contains(key) {
            perEmailHashes.removeValue(forKey: key)
            if perEmailHashes.count <= Self.hashWindowCap { break }
        }
    }

    // MARK: - §21 one-time legacy JSON → SQLite migration

    private static let jsonMigrationKey = "mailin.forensic.jsonMigrated.v1"

    private func migrateLegacyJSONIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.jsonMigrationKey) else { return }
        do {
            let fm = FileManager.default
            // Audit log (chain order must be preserved exactly).
            if fm.fileExists(atPath: auditLogURL.path) {
                let data = try Data(contentsOf: auditLogURL)
                let entries = try JSONDecoder().decode([AuditEntry].self, from: data)
                let existing = try await store.forensicAuditCount()
                if existing == 0 {
                    for e in entries.sorted(by: { $0.sequence < $1.sequence }) {
                        try await store.forensicAuditAppend(SQLiteEmailStore.ForensicAuditRow(
                            seq: e.sequence, entryID: e.id, timestamp: e.timestamp,
                            action: e.action, detail: e.detail, examiner: e.examiner,
                            previousHash: e.previousHash, entryHash: e.entryHash))
                    }
                    let migrated = try await store.forensicAuditCount()
                    guard migrated == entries.count else {
                        forensicLog.error("audit JSON migration verification failed (\(migrated)/\(entries.count)) — will retry")
                        return
                    }
                }
            }
            // Source hashes.
            if fm.fileExists(atPath: hashesURL.path) {
                let data = try Data(contentsOf: hashesURL)
                for h in try JSONDecoder().decode([SourceFileHash].self, from: data) {
                    try await store.forensicSourceHashUpsert(SQLiteEmailStore.ForensicSourceHashRow(
                        filename: h.filename, fileSize: h.fileSize,
                        md5: h.md5, sha1: h.sha1, sha256: h.sha256, importedAt: h.importDate))
                }
            }
            // Evidence tags + timestamps.
            if fm.fileExists(atPath: tagsURL.path) {
                let data = try Data(contentsOf: tagsURL)
                let dict = try JSONDecoder().decode([String: String].self, from: data)
                var byTag: [String: [UUID]] = [:]
                for (key, value) in dict {
                    if let id = UUID(uuidString: key) { byTag[value, default: []].append(id) }
                }
                for (tag, ids) in byTag { try await store.forensicTagSet(tag, ids: ids) }
            }
            // Annotations.
            if fm.fileExists(atPath: annotationsURL.path) {
                let data = try Data(contentsOf: annotationsURL)
                let dict = try JSONDecoder().decode([String: Annotation].self, from: data)
                for (key, a) in dict {
                    if let id = UUID(uuidString: key) {
                        try await store.forensicAnnotationSet(a.text, examiner: a.examiner, id: id)
                    }
                }
            }
            // Per-email hashes (archive-sized in the worst case — chunked).
            if fm.fileExists(atPath: emailHashesURL.path) {
                let data = try Data(contentsOf: emailHashesURL)
                let dict = try JSONDecoder().decode([String: EmailHash].self, from: data)
                var batch: [UUID: SQLiteEmailStore.ForensicEmailHashRow] = [:]
                for (key, h) in dict {
                    guard let id = UUID(uuidString: key) else { continue }
                    batch[id] = SQLiteEmailStore.ForensicEmailHashRow(
                        md5: h.md5, sha1: h.sha1, sha256: h.sha256, byteCount: h.byteCount)
                    if batch.count >= 2_000 {
                        try await store.forensicHashUpsert(batch)
                        batch = [:]
                    }
                }
                try await store.forensicHashUpsert(batch)
            }
            // The JSON files are KEPT on disk as rollback evidence (§20/§21).
            defaults.set(true, forKey: Self.jsonMigrationKey)
            forensicLog.info("forensic JSON state migrated to SQLite")
        } catch {
            forensicLog.error("forensic JSON migration failed: \(error.localizedDescription, privacy: .public) — will retry next launch")
        }
    }

    // MARK: - HMAC-Chained Audit Log (Tamper-Evident)

    private func computeEntryHash(sequence: Int, timestamp: Date, action: String, detail: String, examiner: String, previousHash: String) -> String {
        let payload = "\(sequence)|\(timestamp.timeIntervalSince1970)|\(action)|\(detail)|\(examiner)|\(previousHash)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: hmacKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    func logAction(_ action: String, detail: String) {
        guard isEnabled else { return }
        guard chainReady else {
            // Queued, not dropped: drained by bootstrapFromStore once the
            // durable (sequence, lastHash) cursor is known.
            pendingActions.append((action, detail))
            return
        }
        let sequence = auditSequence
        let previousHash = lastAuditHash
        let examiner = examinerName.isEmpty ? "Unknown" : examinerName
        let timestamp = Date()

        let entryHash = computeEntryHash(
            sequence: sequence,
            timestamp: timestamp,
            action: action,
            detail: detail,
            examiner: examiner,
            previousHash: previousHash
        )

        let entry = AuditEntry(
            id: UUID(),
            sequence: sequence,
            timestamp: timestamp,
            action: action,
            detail: detail,
            examiner: examiner,
            previousHash: previousHash,
            entryHash: entryHash
        )
        // O(1) chain advance — the whole log is never resident.
        auditSequence += 1
        lastAuditHash = entryHash
        auditLog.append(entry)
        if auditLog.count > Self.auditDisplayLimit { auditLog.removeFirst(auditLog.count - Self.auditDisplayLimit) }
        auditTotalCount += 1
        saveChainRoot(entryHash)
        let row = SQLiteEmailStore.ForensicAuditRow(
            seq: entry.sequence, entryID: entry.id, timestamp: entry.timestamp,
            action: entry.action, detail: entry.detail, examiner: entry.examiner,
            previousHash: entry.previousHash, entryHash: entry.entryHash)
        Task { @MainActor [store] in
            do { try await store.forensicAuditAppend(row) }
            catch {
                forensicLog.fault("audit append failed (seq \(row.seq)): \(error.localizedDescription, privacy: .public)")
                self.integrityStatus = .tampered(details: "Audit entry #\(row.seq) could not be persisted: \(error.localizedDescription)")
            }
        }
    }

    /// Streamed verification (§21.1): walks the full durable log in bounded
    /// pages, recomputing the HMAC chain in order — the archive-sized log is
    /// never resident.
    func verifyAuditLogIntegrityStreamed() async -> IntegrityStatus {
        do {
            let total = try await store.forensicAuditCount()
            guard total > 0 else {
                integrityStatus = .noData
                return .noData
            }
            var expectedPrevious = "GENESIS"
            var expectedSeq = 0
            var lastHash = ""
            while true {
                let page = try await store.forensicAuditPage(fromSeq: expectedSeq, limit: 1_000)
                if page.isEmpty { break }
                for entry in page {
                    if entry.seq != expectedSeq {
                        integrityStatus = .tampered(details: "Sequence gap at entry \(expectedSeq): found \(entry.seq)")
                        return integrityStatus
                    }
                    if entry.previousHash != expectedPrevious {
                        integrityStatus = .tampered(details: "Chain break at entry \(entry.seq): expected previous hash \(expectedPrevious.prefix(16))..., found \(entry.previousHash.prefix(16))...")
                        return integrityStatus
                    }
                    let recomputed = computeEntryHash(
                        sequence: entry.seq, timestamp: entry.timestamp, action: entry.action,
                        detail: entry.detail, examiner: entry.examiner, previousHash: entry.previousHash)
                    if recomputed != entry.entryHash {
                        integrityStatus = .tampered(details: "Hash mismatch at entry \(entry.seq) (\(entry.action)): entry has been modified")
                        return integrityStatus
                    }
                    expectedPrevious = entry.entryHash
                    lastHash = entry.entryHash
                    expectedSeq += 1
                }
                if page.count < 1_000 { break }
            }
            if expectedSeq != total {
                integrityStatus = .tampered(details: "Log truncated: verified \(expectedSeq) of \(total) entries")
                return integrityStatus
            }
            if let storedRoot = try? String(contentsOf: chainRootURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               storedRoot != lastHash {
                integrityStatus = .tampered(details: "Chain root mismatch: log was modified outside the application")
                return integrityStatus
            }
            integrityStatus = .verified
            return .verified
        } catch {
            integrityStatus = .tampered(details: "Verification could not read the audit log: \(error.localizedDescription)")
            return integrityStatus
        }
    }

    /// Synchronous verification over the RECENT display window only (UI badge
    /// convenience). Full-log truth comes from `verifyAuditLogIntegrityStreamed`.
    func verifyAuditLogIntegrity() -> IntegrityStatus {
        guard !auditLog.isEmpty else {
            integrityStatus = auditTotalCount == 0 ? .noData : integrityStatus
            return integrityStatus
        }
        var expectedPrevious = auditLog.first!.previousHash
        for entry in auditLog {
            if entry.previousHash != expectedPrevious {
                integrityStatus = .tampered(details: "Chain break at entry \(entry.sequence)")
                return integrityStatus
            }
            let recomputed = computeEntryHash(
                sequence: entry.sequence, timestamp: entry.timestamp, action: entry.action,
                detail: entry.detail, examiner: entry.examiner, previousHash: entry.previousHash)
            if recomputed != entry.entryHash {
                integrityStatus = .tampered(details: "Hash mismatch at entry \(entry.sequence) (\(entry.action))")
                return integrityStatus
            }
            expectedPrevious = entry.entryHash
        }
        if let storedRoot = try? String(contentsOf: chainRootURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let lastHash = auditLog.last?.entryHash,
           storedRoot != lastHash {
            integrityStatus = .tampered(details: "Chain root mismatch: log was modified outside the application")
            return integrityStatus
        }
        integrityStatus = .verified
        return .verified
    }

    private func saveChainRoot(_ lastHash: String) {
        do { try lastHash.write(to: chainRootURL, atomically: true, encoding: .utf8) }
        catch { forensicLog.fault("chain root write failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Hash Computation (MD5 + SHA-1 + SHA-256)

    /// §9: streams the file through all three digests in ONE pass with a
    /// bounded 1 MB buffer — a 200 GB source never touches RAM as a whole.
    /// MD5/SHA-1 are compatibility/forensic identifiers only, never security
    /// primitives; SHA-256 is the integrity anchor.
    nonisolated static func computeHashes(for url: URL) -> SourceFileHash? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1_048_576) }
            catch { return nil }   // a READ ERROR is a failure, never fake EOF
            guard let chunk, !chunk.isEmpty else { break }
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            total += Int64(chunk.count)
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        return SourceFileHash(
            id: UUID(),
            filename: url.lastPathComponent,
            fileSize: total,
            md5: hex(md5.finalize()),
            sha1: hex(sha1.finalize()),
            sha256: hex(sha256.finalize()),
            importDate: Date()
        )
    }

    nonisolated static func computeEmailHash(rawSource: String) -> EmailHash {
        guard !rawSource.isEmpty else {
            return EmailHash(md5: "", sha1: "", sha256: "", byteCount: 0)
        }
        let data = rawSource.data(using: .utf8) ?? rawSource.data(using: .isoLatin1) ?? Data(rawSource.utf8)
        return EmailHash(
            md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sha1: Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count
        )
    }

    func registerFileHash(_ hash: SourceFileHash) {
        sourceFileHashes.append(hash)
        persistToStore("source hash") { [store] in
            try await store.forensicSourceHashUpsert(SQLiteEmailStore.ForensicSourceHashRow(
                filename: hash.filename, fileSize: hash.fileSize,
                md5: hash.md5, sha1: hash.sha1, sha256: hash.sha256, importedAt: hash.importDate))
        }
        logAction("File Imported", detail: "\(hash.filename) (\(hash.fileSize) bytes) — SHA-256: \(hash.sha256)")
    }

    /// Durable write-through helper — failures are logged AND surfaced.
    private func persistToStore(_ what: String, _ body: @escaping @Sendable () async throws -> Void) {
        Task { @MainActor in
            do { try await body() }
            catch {
                forensicLog.fault("forensic \(what, privacy: .public) write failed: \(error.localizedDescription, privacy: .public)")
                self.integrityStatus = .tampered(details: "Forensic \(what) could not be persisted: \(error.localizedDescription)")
            }
        }
    }

    func verifySourceFile(at url: URL) -> (passed: Bool, detail: String) {
        guard let stored = sourceFileHashes.first(where: { $0.filename == url.lastPathComponent }) else {
            return (false, "No stored hash for \(url.lastPathComponent)")
        }
        guard let current = Self.computeHashes(for: url) else {
            return (false, "Could not read file \(url.lastPathComponent)")
        }
        if current.sha256 != stored.sha256 {
            return (false, "SHA-256 MISMATCH for \(url.lastPathComponent). Original: \(stored.sha256.prefix(16))... Current: \(current.sha256.prefix(16))...")
        }
        if current.md5 != stored.md5 {
            return (false, "MD5 MISMATCH for \(url.lastPathComponent)")
        }
        return (true, "Integrity verified: \(url.lastPathComponent)")
    }

    func storeEmailHashes(_ emails: [MBOXParser.RawEmail]) {
        var batch: [UUID: SQLiteEmailStore.ForensicEmailHashRow] = [:]
        for email in emails {
            let hash = perEmailHashes[email.id] ?? Self.computeEmailHash(rawSource: email.rawSource)
            perEmailHashes[email.id] = hash
            batch[email.id] = SQLiteEmailStore.ForensicEmailHashRow(
                md5: hash.md5, sha1: hash.sha1, sha256: hash.sha256, byteCount: hash.byteCount)
        }
        trimHashWindow(keeping: emails.map(\.id))
        persistToStore("email hashes") { [store] in try await store.forensicHashUpsert(batch) }
    }

    func verifyEmailIntegrity(_ email: MBOXParser.RawEmail) -> (passed: Bool, detail: String) {
        guard let stored = perEmailHashes[email.id] else {
            return (false, "No stored hash for this email")
        }
        let current = Self.computeEmailHash(rawSource: email.rawSource)
        if current.sha256 != stored.sha256 {
            return (false, "Email content has been modified since import")
        }
        return (true, "Email integrity verified (SHA-256 match)")
    }

    func batchVerifyAllEmails(_ emails: [MBOXParser.RawEmail]) -> (passed: Int, failed: Int, unverified: Int, details: [String]) {
        var passed = 0, failed = 0, unverified = 0
        var details: [String] = []
        for email in emails {
            let result = verifyEmailIntegrity(email)
            if perEmailHashes[email.id] == nil {
                unverified += 1
            } else if result.passed {
                passed += 1
            } else {
                failed += 1
                details.append("FAILED: \(email.headers["Subject"] ?? "Unknown") — \(result.detail)")
            }
        }
        logAction("Batch Verification", detail: "\(passed) passed, \(failed) failed, \(unverified) unverified")
        return (passed, failed, unverified, details)
    }

    static let hashManifestHeader = "EmailID,Subject,From,Date,MD5,SHA1,SHA256,Integrity\n"

    /// One streamed manifest row (Part O: exports build the manifest
    /// incrementally from a bounded stream, never a whole array).
    func hashManifestRow(_ email: MBOXParser.RawEmail) -> String {
        let hash = perEmailHashes[email.id]
        let verification = verifyEmailIntegrity(email)
        let subject = (email.headers["Subject"] ?? "").replacingOccurrences(of: ",", with: ";")
        let from = (email.headers["From"] ?? "").replacingOccurrences(of: ",", with: ";")
        return "\(email.id),\"\(subject)\",\"\(from)\",\(email.timestamp),\(hash?.md5 ?? "N/A"),\(hash?.sha1 ?? "N/A"),\(hash?.sha256 ?? "N/A"),\(verification.passed ? "PASS" : "FAIL")\n"
    }

    func exportHashManifest(_ emails: [MBOXParser.RawEmail]) -> String {
        var csv = Self.hashManifestHeader
        for email in emails {
            csv += hashManifestRow(email)
        }
        return csv
    }

    // MARK: - Evidence Tagging

    func tag(_ emailID: UUID, as tag: EvidenceTag) {
        if tag == .none {
            evidenceTags.removeValue(forKey: emailID)
            tagTimestamps.removeValue(forKey: emailID)
        } else {
            evidenceTags[emailID] = tag
            tagTimestamps[emailID] = Date()
        }
        persistToStore("evidence tag") { [store] in
            try await store.forensicTagSet(tag == .none ? nil : tag.rawValue, ids: [emailID])
        }
        logAction("Evidence Tagged", detail: "Email \(emailID.uuidString.prefix(8)) tagged as \(tag.rawValue)")
        CollaborationManager.shared.autoExportIfEnabled()
    }

    func bulkTag(_ emailIDs: Set<UUID>, as tag: EvidenceTag) {
        let now = Date()
        for id in emailIDs {
            if tag == .none {
                evidenceTags.removeValue(forKey: id)
                tagTimestamps.removeValue(forKey: id)
            } else {
                evidenceTags[id] = tag
                tagTimestamps[id] = now
            }
        }
        let ids = Array(emailIDs)
        persistToStore("bulk evidence tag") { [store] in
            try await store.forensicTagSet(tag == .none ? nil : tag.rawValue, ids: ids)
        }
        logAction("Bulk Evidence Tag", detail: "\(emailIDs.count) emails tagged as \(tag.rawValue)")
        CollaborationManager.shared.autoExportIfEnabled()
    }

    /// iCloud/collaboration merge write: durable, but no audit-log spam and
    /// no re-export trigger (the sync layer owns those).
    func applyMergedTag(_ emailID: UUID, tag: EvidenceTag, timestamp: Date) {
        evidenceTags[emailID] = tag
        tagTimestamps[emailID] = timestamp
        persistToStore("merged tag") { [store] in
            try await store.forensicTagSet(tag.rawValue, ids: [emailID])
        }
    }

    func applyMergedAnnotation(_ emailID: UUID, annotation: Annotation) {
        annotations[emailID] = annotation
        persistToStore("merged annotation") { [store] in
            try await store.forensicAnnotationSet(annotation.text, examiner: annotation.examiner, id: emailID)
        }
    }

    func tagForEmail(_ emailID: UUID) -> EvidenceTag {
        evidenceTags[emailID] ?? .none
    }

    func taggedCount(for tag: EvidenceTag) -> Int {
        evidenceTags.values.filter { $0 == tag }.count
    }

    func emailIDs(withTag tag: EvidenceTag) -> Set<UUID> {
        Set(evidenceTags.filter { $0.value == tag }.keys)
    }

    // MARK: - Annotations

    func annotate(_ emailID: UUID, text: String) {
        let examiner = examinerName.isEmpty ? "Unknown" : examinerName
        annotations[emailID] = Annotation(text: text, examiner: examiner, timestamp: Date())
        persistToStore("annotation") { [store] in
            try await store.forensicAnnotationSet(text, examiner: examiner, id: emailID)
        }
        logAction("Annotation", detail: "Email \(emailID.uuidString.prefix(8)): \(text.prefix(80))")
        CollaborationManager.shared.autoExportIfEnabled()
    }

    func annotationFor(_ emailID: UUID) -> Annotation? {
        annotations[emailID]
    }

    // MARK: - Email Header Forensics

    struct ReceivedHop: Identifiable {
        let id = UUID()
        let from: String
        let by: String
        let with: String
        let date: String
        let ip: String?
        let ipv6: String?
        let authInfo: String?
        let raw: String
    }

    nonisolated static func parseReceivedChain(_ email: MBOXParser.RawEmail) -> [ReceivedHop] {
        let receivedHeaders = email.rawSource.components(separatedBy: "\n")
            .reduce(into: [String]()) { result, line in
                if line.lowercased().hasPrefix("received:") {
                    result.append(line)
                } else if !result.isEmpty, (line.hasPrefix(" ") || line.hasPrefix("\t")) {
                    result[result.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                }
            }

        return receivedHeaders.map { raw in
            let cleaned = raw.replacingOccurrences(of: "Received:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)

            let fromMatch = cleaned.range(of: #"from\s+(\S+)"#, options: .regularExpression).flatMap { String(cleaned[$0]) } ?? ""
            let byMatch = cleaned.range(of: #"by\s+(\S+)"#, options: .regularExpression).flatMap { String(cleaned[$0]) } ?? ""
            let withMatch = cleaned.range(of: #"with\s+(\S+)"#, options: .regularExpression).flatMap { String(cleaned[$0]) } ?? ""

            let ipv4Pattern = #"\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]"#
            let ip: String?
            if let ipRange = cleaned.range(of: ipv4Pattern, options: .regularExpression) {
                ip = String(cleaned[ipRange]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            } else {
                ip = nil
            }

            let ipv6Pattern = #"\[IPv6:([a-fA-F0-9:]+)\]"#
            let ipv6: String?
            if let range = cleaned.range(of: ipv6Pattern, options: .regularExpression) {
                ipv6 = String(cleaned[range]).replacingOccurrences(of: "[IPv6:", with: "").replacingOccurrences(of: "]", with: "")
            } else {
                ipv6 = nil
            }

            let authPattern = #"auth=(\S+)"#
            let authInfo: String?
            if let range = cleaned.range(of: authPattern, options: .regularExpression) {
                authInfo = String(cleaned[range])
            } else {
                authInfo = nil
            }

            let datePattern = #";(.+)$"#
            let date: String
            if let dateRange = cleaned.range(of: datePattern, options: .regularExpression) {
                date = String(cleaned[dateRange]).replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces)
            } else {
                date = ""
            }

            return ReceivedHop(from: fromMatch, by: byMatch, with: withMatch, date: date, ip: ip, ipv6: ipv6, authInfo: authInfo, raw: raw)
        }
    }

    nonisolated static func extractAuthResults(_ email: MBOXParser.RawEmail) -> (spf: String, dkim: String, dmarc: String) {
        let authHeader = email.headers["Authentication-Results"] ?? email.headers["authentication-results"] ?? ""
        let spf = authHeader.range(of: #"spf=(\w+)"#, options: .regularExpression).map { String(authHeader[$0]).replacingOccurrences(of: "spf=", with: "") } ?? "N/A"
        let dkim = authHeader.range(of: #"dkim=(\w+)"#, options: .regularExpression).map { String(authHeader[$0]).replacingOccurrences(of: "dkim=", with: "") } ?? "N/A"
        let dmarc = authHeader.range(of: #"dmarc=(\w+)"#, options: .regularExpression).map { String(authHeader[$0]).replacingOccurrences(of: "dmarc=", with: "") } ?? "N/A"
        return (spf, dkim, dmarc)
    }

    nonisolated static func extractDetailedAuthResults(_ email: MBOXParser.RawEmail) -> EmailNLPEngine.EmailAuthenticationResult {
        EmailNLPEngine.parseAuthenticationResults(email.headers)
    }

    // MARK: - Spoofing Detection

    struct SpoofIndicator: Identifiable {
        let id = UUID()
        let severity: SpoofSeverity
        let type: String
        let detail: String
    }

    enum SpoofSeverity: String {
        case high = "High"
        case medium = "Medium"
        case low = "Low"

        var color: Color {
            switch self {
            case .high: return .red
            case .medium: return .orange
            case .low: return .yellow
            }
        }
    }

    nonisolated static func detectSpoofingIndicators(_ email: MBOXParser.RawEmail) -> [SpoofIndicator] {
        var indicators: [SpoofIndicator] = []

        let from = email.headers["From"] ?? ""
        let returnPath = email.headers["Return-Path"] ?? email.headers["return-path"] ?? ""
        let replyTo = email.headers["Reply-To"] ?? ""

        let extractDomain: (String) -> String? = { addr in
            guard let atIndex = addr.lastIndex(of: "@") else { return nil }
            let afterAt = addr[addr.index(after: atIndex)...]
            return afterAt.trimmingCharacters(in: CharacterSet(charactersIn: "> \t\r\n")).lowercased()
        }

        let fromDomain = extractDomain(from)
        let returnPathDomain = extractDomain(returnPath)
        let replyToDomain = extractDomain(replyTo)

        if let fd = fromDomain, let rpd = returnPathDomain, !returnPath.isEmpty, fd != rpd {
            indicators.append(SpoofIndicator(severity: .high, type: "Return-Path Mismatch", detail: "From domain: \(fd), Return-Path domain: \(rpd)"))
        }

        if let fd = fromDomain, let rtd = replyToDomain, !replyTo.isEmpty, fd != rtd {
            indicators.append(SpoofIndicator(severity: .medium, type: "Reply-To Mismatch", detail: "From domain: \(fd), Reply-To domain: \(rtd)"))
        }

        let auth = extractAuthResults(email)
        if auth.spf == "fail" {
            indicators.append(SpoofIndicator(severity: .high, type: "SPF Fail", detail: "Sender not authorized by domain's SPF record"))
        }
        if auth.dkim == "fail" {
            indicators.append(SpoofIndicator(severity: .high, type: "DKIM Fail", detail: "DKIM reported as failing by the receiving server (Authentication-Results header; not independently verified)"))
        }
        if auth.dmarc == "fail" {
            indicators.append(SpoofIndicator(severity: .high, type: "DMARC Fail", detail: "Domain-based message authentication failed"))
        }

        if let fd = fromDomain {
            let homoglyphs: [(String, String)] = [
                ("rn", "m"), ("cl", "d"), ("vv", "w"),
                ("0", "O"), ("1", "l"), ("nn", "m")
            ]
            let knownSafeDomains: Set<String> = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com", "aol.com", "protonmail.com"]
            if !knownSafeDomains.contains(fd) {
                let domainName = fd.components(separatedBy: ".").first ?? fd
                for (fake, real) in homoglyphs {
                    if domainName.contains(fake) {
                        let replaced = domainName.replacingOccurrences(of: fake, with: real)
                        if replaced != domainName && replaced.count >= 3 {
                            indicators.append(SpoofIndicator(severity: .high, type: "Homoglyph Domain", detail: "Domain '\(fd)' may be impersonating '\(replaced)' (look-alike characters)"))
                        }
                    }
                }
            }

            let knownDomains = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com", "aol.com", "protonmail.com"]
            for known in knownDomains {
                if fd != known && fd.contains(known.replacingOccurrences(of: ".com", with: "")) && !fd.hasSuffix(".\(known)") {
                    indicators.append(SpoofIndicator(severity: .medium, type: "Subdomain Spoof", detail: "Domain '\(fd)' contains '\(known)' as substring — possible impersonation"))
                }
            }
        }

        let xOrigIP = email.headers["X-Originating-IP"] ?? ""
        if !xOrigIP.isEmpty {
            let cleaned = xOrigIP.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            if cleaned.hasPrefix("10.") || cleaned.hasPrefix("192.168.") || cleaned.hasPrefix("172.") {
                indicators.append(SpoofIndicator(severity: .low, type: "Private IP Origin", detail: "X-Originating-IP is a private address: \(cleaned)"))
            }
        }

        let receivedCount = parseReceivedChain(email).count
        if receivedCount == 0 {
            indicators.append(SpoofIndicator(severity: .medium, type: "No Received Headers", detail: "Missing Received chain — email may have been injected directly"))
        }

        return indicators
    }

    // MARK: - Email Risk Score (0–100)

    struct RiskAssessment {
        let score: Int
        let level: RiskLevel
        let factors: [String]

        enum RiskLevel: String {
            case safe = "Safe"
            case low = "Low Risk"
            case medium = "Medium Risk"
            case high = "High Risk"
            case critical = "Critical"

            var color: Color {
                switch self {
                case .safe: return .green
                case .low: return .blue
                case .medium: return .yellow
                case .high: return .orange
                case .critical: return .red
                }
            }

            var icon: String {
                switch self {
                case .safe: return "checkmark.shield.fill"
                case .low: return "shield.fill"
                case .medium: return "exclamationmark.shield.fill"
                case .high: return "exclamationmark.triangle.fill"
                case .critical: return "xmark.shield.fill"
                }
            }
        }
    }

    nonisolated static func assessRisk(for email: MBOXParser.RawEmail) -> RiskAssessment {
        var score = 0
        var factors: [String] = []

        let indicators = detectSpoofingIndicators(email)
        let highCount = indicators.filter { $0.severity == .high }.count
        let medCount = indicators.filter { $0.severity == .medium }.count
        let lowCount = indicators.filter { $0.severity == .low }.count

        score += highCount * 25
        score += medCount * 10
        score += lowCount * 3

        if highCount > 0 {
            factors.append("\(highCount) high-severity spoofing indicator(s)")
        }
        if medCount > 0 {
            factors.append("\(medCount) medium-severity indicator(s)")
        }

        let auth = extractAuthResults(email)
        if auth.spf == "fail" { score += 15; factors.append("SPF authentication failed") }
        if auth.dkim == "fail" { score += 15; factors.append("DKIM reported fail (per receiving server)") }
        if auth.dmarc == "fail" { score += 15; factors.append("DMARC policy failed") }

        let piiFindings = EmailNLPEngine.detectPII(in: [email])
        let ssnCount = piiFindings.filter { $0.type == .ssnPattern }.count
        let ccCount = piiFindings.filter { $0.type == .creditCard }.count
        if ssnCount > 0 { score += 10; factors.append("\(ssnCount) SSN pattern(s) found") }
        if ccCount > 0 { score += 10; factors.append("\(ccCount) credit card pattern(s) found") }

        if !email.anomalies.isEmpty {
            score += email.anomalies.count * 5
            factors.append("\(email.anomalies.count) anomaly/anomalies detected")
        }

        let hops = parseReceivedChain(email)
        if hops.count > 8 {
            score += 5
            factors.append("Unusually long routing chain (\(hops.count) hops)")
        }

        let body = email.plainBody.lowercased()
        let urgencyPhrases = ["urgent action required", "verify your account", "suspended",
                              "click here immediately", "act now or", "your account will be"]
        let matchedPhrases = urgencyPhrases.filter { body.contains($0) }
        if !matchedPhrases.isEmpty {
            score += matchedPhrases.count * 8
            factors.append("Suspicious urgency language detected")
        }

        score = min(score, 100)

        let level: RiskAssessment.RiskLevel
        switch score {
        case 0..<10: level = .safe
        case 10..<30: level = .low
        case 30..<55: level = .medium
        case 55..<80: level = .high
        default: level = .critical
        }

        if factors.isEmpty { factors.append("No risk indicators detected") }
        return RiskAssessment(score: score, level: level, factors: factors)
    }

    // MARK: - MIME Tree

    static func buildMIMETree(_ email: MBOXParser.RawEmail) -> [MIMETreeNode] {
        guard let root = email.mimeRoot else {
            return [MIMETreeNode(contentType: email.headers["Content-Type"] ?? "text/plain", filename: nil, size: email.plainBody.utf8.count, children: [])]
        }
        return [buildNode(from: root)]
    }

    struct MIMETreeNode: Identifiable {
        let id = UUID()
        let contentType: String
        let filename: String?
        let size: Int
        let children: [MIMETreeNode]
    }

    private static func buildNode(from part: MIMEPart) -> MIMETreeNode {
        let children = part.subparts.map { buildNode(from: $0) }
        return MIMETreeNode(
            contentType: part.mimeType,
            filename: part.filename,
            size: part.rawData?.count ?? part.body.utf8.count,
            children: children
        )
    }

    // MARK: - Forensic Export Helpers

    static func batesNumber(prefix: String, index: Int, padding: Int = 6) -> String {
        "\(prefix)\(String(format: "%0\(padding)d", index))"
    }

    /// §21.1: streams the FULL durable audit log to `url` in bounded pages —
    /// the log is never resident as a whole. Verification runs streamed first
    /// so the header states the true chain status.
    func exportAuditLogStreamed(to url: URL) async throws -> Int {
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        let total = try await store.forensicAuditCount()
        let integrity = await verifyAuditLogIntegrityStreamed()

        var header = "FORENSIC AUDIT LOG (TAMPER-EVIDENT)\n"
        header += String(repeating: "=", count: 76) + "\n"
        header += "Case Number: \(caseNumber.isEmpty ? "N/A" : caseNumber)\n"
        header += "Examiner: \(examinerName.isEmpty ? "N/A" : examinerName)\n"
        header += "Organization: \(organization.isEmpty ? "N/A" : organization)\n"
        header += "Export Date: \(displayFormatter.string(from: Date()))\n"
        header += "Total Entries: \(total)\n"
        switch integrity {
        case .verified:
            header += "Chain Integrity: VERIFIED (all \(total) entries pass HMAC-SHA256 verification)\n"
        case .tampered(let details):
            header += "Chain Integrity: FAILED — \(details)\n"
        case .noData:
            header += "Chain Integrity: N/A (empty log)\n"
        case .unknown:
            header += "Chain Integrity: NOT CHECKED\n"
        }
        header += String(repeating: "=", count: 76) + "\n\n"

        if !sourceFileHashes.isEmpty {
            header += "SOURCE FILE INTEGRITY\n"
            header += String(repeating: "-", count: 76) + "\n"
            for hash in sourceFileHashes {
                header += "File: \(hash.filename)\n"
                header += "  Size: \(hash.fileSize) bytes\n"
                header += "  MD5:    \(hash.md5)\n"
                header += "  SHA-1:  \(hash.sha1)\n"
                header += "  SHA-256: \(hash.sha256)\n"
                header += "  Import Date: \(displayFormatter.string(from: hash.importDate))\n\n"
            }
        }
        header += "HMAC-CHAINED ACTION LOG\n"
        header += String(repeating: "-", count: 76) + "\n"

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(header.utf8))

        var seq = 0
        var lastHash = "N/A"
        while true {
            let page = try await store.forensicAuditPage(fromSeq: seq, limit: 1_000)
            if page.isEmpty { break }
            var chunk = ""
            for entry in page {
                chunk += "#\(entry.seq) [\(displayFormatter.string(from: entry.timestamp))] \(entry.action)\n"
                chunk += "  Detail: \(entry.detail)\n"
                chunk += "  Examiner: \(entry.examiner)\n"
                chunk += "  HMAC: \(entry.entryHash)\n"
                chunk += "  Prev: \(entry.previousHash.prefix(32))...\n\n"
                lastHash = entry.entryHash
                seq = entry.seq + 1
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            if page.count < 1_000 { break }
        }

        var footer = String(repeating: "=", count: 76) + "\n"
        footer += "END OF AUDIT LOG\n"
        footer += "Final chain hash: \(lastHash)\n\n"
        footer += String(repeating: "-", count: 76) + "\n"
        footer += "DISCLAIMER: " + LegalComplianceManager.forensicDisclaimer + "\n"
        try handle.write(contentsOf: Data(footer.utf8))
        return total
    }

    static let forensicCSVHeader = "Bates Number,Message-ID,Date,From,To,CC,Subject,MD5,SHA-1,SHA-256,Byte Count,Has Attachments,Attachment Count,Evidence Tag,Annotation,Thread-ID,Spoof Risk,Risk Score,Risk Level\n"

    private static func forensicCSVEscape(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// One streamed forensic-CSV row for a running Bates number (Part O:
    /// exports stream rows from the store — never a whole-array pass).
    func forensicCSVRow(_ email: MBOXParser.RawEmail, bates: String) -> String {
        func csvEscape(_ s: String) -> String { Self.forensicCSVEscape(s) }
        let hash = perEmailHashes[email.id] ?? Self.computeEmailHash(rawSource: email.rawSource)
        let tag = tagForEmail(email.id).rawValue
        let note = annotations[email.id]?.text ?? ""
        let spoofCount = Self.detectSpoofingIndicators(email).count
        let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""

        var csv = ""
        csv += "\(bates),"
        csv += "\(csvEscape(email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? "")),"
        csv += "\(csvEscape(email.headers["Date"] ?? "")),"
        csv += "\(csvEscape(email.headers["From"] ?? "")),"
        csv += "\(csvEscape(email.headers["To"] ?? "")),"
        csv += "\(csvEscape(cc)),"
        csv += "\(csvEscape(email.headers["Subject"] ?? "")),"
        csv += "\(hash.md5),"
        csv += "\(hash.sha1),"
        csv += "\(hash.sha256),"
        csv += "\(hash.byteCount),"
        csv += "\(!email.attachments.isEmpty),"
        csv += "\(email.attachments.count),"
        csv += "\(csvEscape(tag)),"
        csv += "\(csvEscape(note)),"
        csv += "\(csvEscape(email.threadID ?? "")),"
        csv += "\(spoofCount),"
        let risk = Self.assessRisk(for: email)
        csv += "\(risk.score),"
        csv += "\(csvEscape(risk.level.rawValue))\n"
        return csv
    }

    func exportBulkForensicCSV(emails: [MBOXParser.RawEmail], batesPrefix: String = "MAIL") -> String {
        var csv = Self.forensicCSVHeader
        for (i, email) in emails.enumerated() {
            csv += forensicCSVRow(email, bates: Self.batesNumber(prefix: batesPrefix, index: i + 1))
        }
        return csv
    }

    static let concordanceDATHeader: String = {
        let sep = "\u{14}"
        let quote = "\u{FE}"
        return "\(quote)DOCID\(quote)\(sep)\(quote)BEGBATES\(quote)\(sep)\(quote)ENDBATES\(quote)\(sep)\(quote)FROM\(quote)\(sep)\(quote)TO\(quote)\(sep)\(quote)CC\(quote)\(sep)\(quote)BCC\(quote)\(sep)\(quote)SUBJECT\(quote)\(sep)\(quote)DATESENT\(quote)\(sep)\(quote)MSGID\(quote)\(sep)\(quote)HASHSHA256\(quote)\(sep)\(quote)CUSTODIAN\(quote)\(sep)\(quote)TAG\(quote)\n"
    }()

    /// One streamed Concordance .dat row (Part O).
    func concordanceDATRow(_ email: MBOXParser.RawEmail, bates: String) -> String {
        let sep = "\u{14}"
        let quote = "\u{FE}"
        let hash = perEmailHashes[email.id] ?? Self.computeEmailHash(rawSource: email.rawSource)
        let tag = tagForEmail(email.id).rawValue
        let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
        let bcc = email.headers["Bcc"] ?? email.headers["BCC"] ?? ""

        func datEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
        }

        var dat = ""
        dat += "\(quote)\(bates)\(quote)\(sep)"
        dat += "\(quote)\(bates)\(quote)\(sep)"
        dat += "\(quote)\(bates)\(quote)\(sep)"
        dat += "\(quote)\(datEscape(email.headers["From"] ?? ""))\(quote)\(sep)"
        dat += "\(quote)\(datEscape(email.headers["To"] ?? ""))\(quote)\(sep)"
        dat += "\(quote)\(datEscape(cc))\(quote)\(sep)"
        dat += "\(quote)\(datEscape(bcc))\(quote)\(sep)"
        dat += "\(quote)\(datEscape(email.headers["Subject"] ?? ""))\(quote)\(sep)"
        dat += "\(quote)\(datEscape(email.headers["Date"] ?? ""))\(quote)\(sep)"
        dat += "\(quote)\(datEscape(email.headers["Message-ID"] ?? ""))\(quote)\(sep)"
        dat += "\(quote)\(hash.sha256)\(quote)\(sep)"
        dat += "\(quote)\(datEscape(examinerName))\(quote)\(sep)"
        dat += "\(quote)\(tag)\(quote)\n"
        return dat
    }

    func exportConcordanceDAT(emails: [MBOXParser.RawEmail], batesPrefix: String = "MAIL") -> String {
        var dat = Self.concordanceDATHeader
        for (i, email) in emails.enumerated() {
            dat += concordanceDATRow(email, bates: Self.batesNumber(prefix: batesPrefix, index: i + 1))
        }
        return dat
    }

    func exportPrivilegeLog(emails: [MBOXParser.RawEmail]) -> String {
        let privileged = emails.filter { evidenceTags[$0.id] == .privileged }
        guard !privileged.isEmpty else { return "" }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var log = "PRIVILEGE LOG\n"
        log += String(repeating: "=", count: 76) + "\n"
        log += "Case Number: \(caseNumber.isEmpty ? "N/A" : caseNumber)\n"
        log += "Prepared by: \(examinerName.isEmpty ? "N/A" : examinerName)\n"
        log += "Date: \(displayFormatter.string(from: Date()))\n"
        log += "Total Privileged Documents: \(privileged.count)\n\n"

        log += String(format: "%-8s %-12s %-30s %-30s %s\n", "No.", "Date", "From", "To", "Subject")
        log += String(repeating: "-", count: 120) + "\n"

        for (i, email) in privileged.enumerated() {
            let date = email.headers["Date"] ?? "N/A"
            let from = String((email.headers["From"] ?? "N/A").prefix(28))
            let to = String((email.headers["To"] ?? "N/A").prefix(28))
            let subject = String((email.headers["Subject"] ?? "N/A").prefix(50))

            log += String(format: "%-8d %-12s %-30s %-30s %s\n",
                          i + 1,
                          String(date),
                          from,
                          to,
                          subject)

            if let annotation = annotations[email.id] {
                log += "         Basis: \(annotation.text)\n"
            }
        }

        log += "\n" + String(repeating: "=", count: 76) + "\n"
        log += "END OF PRIVILEGE LOG\n\n"
        log += "DISCLAIMER: " + LegalComplianceManager.forensicDisclaimer + "\n"
        return log
    }

    // MARK: - Persistence (§21: SQLite is the durable authority; the legacy
    // JSON files are read once by the migration and kept as rollback evidence)

    func clearForensicData() {
        let tsURL = tagsURL.deletingLastPathComponent().appendingPathComponent("forensic_tag_timestamps.json")
        for url in [auditLogURL, hashesURL, tagsURL, annotationsURL, emailHashesURL, chainRootURL, tsURL] {
            try? FileManager.default.removeItem(at: url)
        }
        auditLog = []
        auditTotalCount = 0
        auditSequence = 0
        lastAuditHash = "GENESIS"
        chainReady = true          // a cleared chain restarts at GENESIS
        pendingActions = []
        sourceFileHashes = []
        evidenceTags = [:]
        tagTimestamps = [:]
        annotations = [:]
        perEmailHashes = [:]
        integrityStatus = .unknown
        persistToStore("clear") { [store] in try await store.forensicClearAll() }
    }

    func clearAllForensicData() {
        clearForensicData()
        isEnabled = false
        caseNumber = ""
        examinerName = ""
        organization = ""
    }

    // MARK: - Privilege Auto-Detection

    private static let privilegeKeywords = [
        "attorney-client", "attorney client", "work product", "privileged",
        "confidential communication", "legal advice", "legally privileged",
        "protected by", "do not forward", "without prejudice",
        "litigation hold", "legal hold", "settlement", "deposition",
        "subpoena", "discovery request", "court order", "mediation",
        "arbitration", "indemnification", "non-disclosure", "nda"
    ]

    private static let legalSubjectTerms = [
        "patent", "trademark", "copyright", "intellectual property",
        "infringement", "litigation", "lawsuit", "legal review", "legal matter",
        "legal opinion", "legal hold", "legal counsel", "compliance review",
        "regulatory filing", "contract review", "contract dispute",
        "agreement draft", "amendment to", "terms and conditions",
        "privacy policy", "liability claim", "indemnif", "settlement offer",
        "settlement agreement", "court order", "court filing", "hearing notice",
        "motion to", "petition for", "appeal of", "deposition notice",
        "subpoena", "privilege log", "discovery request"
    ]

    private static let legalDomainPatterns = [
        "law.com", "lawfirm", "legalcounsel", "legalservices",
        "solicitor", "barrister", ".esq",
        "& associates", "&associates", ".llp", "law office",
        "law firm", "attorneys", "advocates"
    ]

    private static let legalSenderPatterns = [
        "advocate", "attorney", "lawyer", "counsel", "solicitor",
        "barrister", "notary", "paralegal", "law clerk"
    ]

    static func detectPrivilege(for email: MBOXParser.RawEmail) -> (isLikelyPrivileged: Bool, indicators: [String]) {
        var indicators: [String] = []
        let body = email.plainBody.lowercased()
        let subject = (email.headers["Subject"] ?? "").lowercased()
        let from = (email.headers["From"] ?? "").lowercased()
        let to = (email.headers["To"] ?? "").lowercased()
        let allParties = from + " " + to

        for keyword in privilegeKeywords {
            if body.contains(keyword) || subject.contains(keyword) {
                indicators.append("Contains: \"\(keyword)\"")
            }
        }

        for term in legalSubjectTerms {
            if subject.contains(term) {
                indicators.append("Legal subject: \"\(term)\"")
            }
        }

        for pattern in legalDomainPatterns {
            if allParties.contains(pattern) {
                indicators.append("Legal domain: \"\(pattern)\"")
            }
        }

        for pattern in legalSenderPatterns {
            if from.contains(pattern) {
                indicators.append("Legal sender: \"\(pattern)\"")
                break
            }
        }

        if subject.contains("re:") && legalSubjectTerms.contains(where: { subject.contains($0) }) {
            indicators.append("Legal thread subject")
        }

        if body.contains("this email is confidential") || body.contains("intended recipient") ||
           body.contains("delete this email") || body.contains("privileged and confidential") ||
           body.contains("attorney-client privilege") || body.contains("legally privileged") {
            indicators.append("Confidentiality disclaimer")
        }

        let patentPattern = try? NSRegularExpression(pattern: #"\b(patent|case|docket|matter)\s*(no\.?|number|#)\s*[:\s]?\s*\w+"#, options: .caseInsensitive)
        if let regex = patentPattern {
            let range = NSRange(body.startIndex..., in: body)
            if regex.firstMatch(in: body, range: range) != nil {
                indicators.append("Legal reference number detected")
            }
        }

        return (isLikelyPrivileged: !indicators.isEmpty, indicators: indicators)
    }

    @Published var privilegeFlags: [UUID: [String]] = [:]

    func runPrivilegeScan(on emails: [MBOXParser.RawEmail]) {
        var flags: [UUID: [String]] = [:]
        for email in emails {
            let result = Self.detectPrivilege(for: email)
            if result.isLikelyPrivileged {
                flags[email.id] = result.indicators
            }
        }
        privilegeFlags = flags
        logAction("Privilege Scan", detail: "Scanned \(emails.count) emails, flagged \(flags.count) as potentially privileged")
    }

    // MARK: - QC Sampling

    func qcSample(from emails: [MBOXParser.RawEmail], percentage: Double = 0.1) -> [UUID] {
        let tagged = emails.filter { evidenceTags[$0.id] != nil && evidenceTags[$0.id] != EvidenceTag.none }
        let sampleSize = max(1, Int(ceil(Double(tagged.count) * percentage)))
        let shuffled = tagged.shuffled()
        let sample = Array(shuffled.prefix(sampleSize))
        logAction("QC Sample", detail: "Sampled \(sample.count) of \(tagged.count) tagged emails (\(Int(percentage * 100))%)")
        return sample.map(\.id)
    }

    // MARK: - Reviewer Statistics

    struct ReviewerStats {
        let totalTagged: Int
        let tagDistribution: [EvidenceTag: Int]
        let avgSecondsPerTag: Double
        let codingSessionStart: Date?
        let privilegeFlagged: Int
    }

    func computeReviewerStats() -> ReviewerStats {
        var distribution: [EvidenceTag: Int] = [:]
        for tag in evidenceTags.values where tag != .none {
            distribution[tag, default: 0] += 1
        }

        let timestamps = tagTimestamps.values.sorted()
        var avgSeconds: Double = 0
        if timestamps.count > 1 {
            let intervals = zip(timestamps, timestamps.dropFirst()).map { $1.timeIntervalSince($0) }
            let reasonable = intervals.filter { $0 > 0 && $0 < 600 }
            if !reasonable.isEmpty {
                avgSeconds = reasonable.reduce(0, +) / Double(reasonable.count)
            }
        }

        return ReviewerStats(
            totalTagged: evidenceTags.values.filter { $0 != .none }.count,
            tagDistribution: distribution,
            avgSecondsPerTag: avgSeconds,
            codingSessionStart: timestamps.first,
            privilegeFlagged: privilegeFlags.count
        )
    }
}
