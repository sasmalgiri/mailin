//
//  ImportReceipt.swift
//  maxmailin
//
//  Stage 5 W3 / Phase 12 (v2-core-cutover): a durable, tamper-evident record of
//  every import run — source identity (name/size/SHA-256/parser+version),
//  outcome (discovered/parsed/inserted/duplicates/damaged/skipped/failed),
//  degradation state (FTS drift pending reconciliation), resume provenance,
//  timing, and integrity (store-count delta + FTS row count). The receipt is
//  SHA-256 self-hashed so any later edit is detectable, and persisted as JSON
//  for viewing/export.
//
//  Accounting semantics (Part B4):
//   • discovered  — messages the parsers saw this run (parsed + damaged).
//   • parsed      — messages successfully parsed this run.
//   • inserted    — rows actually committed to the store THIS RUN (store
//                   delta). nil when the store count was unavailable —
//                   never fabricated as 0.
//   • duplicates  — exact-duplicate findings recorded THIS RUN (findings
//                   delta), not the cumulative store-wide count.
//   • damaged     — unparseable messages skipped by parser recovery.
//   • skipped     — whole source files skipped via checkpoint (already
//                   fully ingested).
//   • persistFailed — parsed messages whose store insert failed (hard,
//                   counted, never swallowed).
//   • indexed     — messages successfully FTS-indexed this run.
//

import Foundation
import CryptoKit

/// W3: at-rest protection for locally-created evidence artifacts (SQLite DB,
/// FTS shards, receipts, checkpoints, audit log, encrypted archives).
///
///  • iOS — Data Protection classes:
///      `.completeUntilFirstUserAuthentication` for artifacts that background
///      work must keep reading/writing after the device locks (the SQLite
///      store, FTS shards, import checkpoints/receipts written mid-import,
///      and the audit log that background jobs append to). `.complete` for
///      strictly foreground, user-driven artifacts (encrypted archive
///      export files) — unreadable whenever the device is locked.
///  • macOS — no Data Protection classes; instead ensure code-created
///      containing directories are 700 and files 600 (owner-only), so other
///      local users can never read the archive artifacts.
///
/// Best-effort by design: a missing file is a no-op (callers apply this right
/// after creation), and a failed chmod must not abort an import.
enum ArtifactProtection {
    /// Stores that background jobs (import continuation, FTS reconciler,
    /// background analysis) read while the device may be locked.
    static func applyBackgroundReadable(to url: URL) {
        apply(to: url, foregroundOnly: false)
    }

    /// Strictly foreground, user-driven artifacts.
    static func applyForegroundOnly(to url: URL) {
        apply(to: url, foregroundOnly: true)
    }

    private static func apply(to url: URL, foregroundOnly: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        #if os(iOS)
        let cls: FileProtectionType = foregroundOnly
            ? .complete
            : .completeUntilFirstUserAuthentication
        // Directories: new children inherit the directory's class.
        try? fm.setAttributes([.protectionKey: cls], ofItemAtPath: url.path)
        #else
        let perms = isDir.boolValue ? 0o700 : 0o600
        try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        #endif
    }
}

struct ImportReceipt: Codable, Sendable, Equatable {
    struct SourceRecord: Codable, Sendable, Equatable {
        var filename: String
        var sizeBytes: Int
        var sha256: String
        var parser: String
        var parserVersion: Int
    }

    /// One source file that failed mid-import (Part B3/g): recorded so a bad
    /// file never silently disappears from the run's history.
    struct FileFailure: Codable, Sendable, Equatable {
        var filename: String
        var message: String
    }

    /// Bumped when receipt fields/semantics change.
    var schemaVersion: Int = 2
    // Source
    var sources: [SourceRecord] = []
    // Outcome (see header for exact semantics)
    var discovered: Int = 0
    var parsed: Int = 0
    /// Store-delta committed rows this run; nil = count unavailable (never 0-faked).
    var inserted: Int? = nil
    /// Duplicate-findings delta this run; nil = count unavailable.
    var duplicates: Int? = nil
    var damaged: Int = 0
    var skipped: Int = 0
    var persistFailed: Int = 0
    var indexed: Int = 0
    var attachmentsSeen: Int = 0
    var fileFailures: [FileFailure] = []
    var warnings: [String] = []
    // Timing
    var startedAt: Date
    var completedAt: Date
    var durationSeconds: Double = 0
    // Recovery / resume provenance (Part B5)
    var resumed: Bool = false
    var resumedDetail: String? = nil
    // Degradation (Part 1f): FTS batches that failed were logged + counted;
    // rows are in the store and the launch FTSReconciler backfills the index.
    var ftsDegraded: Bool = false
    var ftsFailedBatchCount: Int = 0
    /// True when store↔FTS drift is known and awaiting launch reconciliation.
    var reconciliationPending: Bool = false
    // Integrity — nil means the count could not be read (surfaced via
    // `warnings`), never fabricated.
    var storeCountBefore: Int? = nil
    var storeCountAfter: Int? = nil
    var ftsRowCount: Int? = nil
    /// SHA-256 over the canonical JSON of every OTHER field. Empty until finalized.
    var contentHash: String = ""

    init(startedAt: Date, completedAt: Date) {
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// nil when canonical encoding fails — callers must treat that as a
    /// signing failure, never hash empty data (Part B3).
    private func canonicalHash() -> String? {
        var copy = self
        copy.contentHash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(copy) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stamp the self-hash. Call once, last. Throws when the receipt cannot
    /// be canonically encoded — an unsigned receipt must be surfaced, not
    /// silently produced with a hash of empty data.
    mutating func finalize() throws {
        guard let hash = canonicalHash() else {
            throw MaxmailinError.forensic(.signatureInvalid,
                detail: "Import receipt could not be canonically encoded for self-hashing.")
        }
        contentHash = hash
    }

    /// True iff the receipt has not been altered since `finalize()`.
    /// A receipt that cannot be re-encoded never verifies.
    func verify() -> Bool {
        guard let hash = canonicalHash() else { return false }
        return !contentHash.isEmpty && contentHash == hash
    }

    // Custom decode with per-field defaults so receipts persisted by earlier
    // schema versions still load (durability requirement). Encoding stays
    // synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sources = try c.decodeIfPresent([SourceRecord].self, forKey: .sources) ?? []
        discovered = try c.decodeIfPresent(Int.self, forKey: .discovered) ?? 0
        parsed = try c.decodeIfPresent(Int.self, forKey: .parsed) ?? 0
        inserted = try c.decodeIfPresent(Int.self, forKey: .inserted)
        duplicates = try c.decodeIfPresent(Int.self, forKey: .duplicates)
        damaged = try c.decodeIfPresent(Int.self, forKey: .damaged) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        persistFailed = try c.decodeIfPresent(Int.self, forKey: .persistFailed) ?? 0
        indexed = try c.decodeIfPresent(Int.self, forKey: .indexed) ?? 0
        attachmentsSeen = try c.decodeIfPresent(Int.self, forKey: .attachmentsSeen) ?? 0
        fileFailures = try c.decodeIfPresent([FileFailure].self, forKey: .fileFailures) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        completedAt = try c.decode(Date.self, forKey: .completedAt)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        resumed = try c.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
        resumedDetail = try c.decodeIfPresent(String.self, forKey: .resumedDetail)
        ftsDegraded = try c.decodeIfPresent(Bool.self, forKey: .ftsDegraded) ?? false
        ftsFailedBatchCount = try c.decodeIfPresent(Int.self, forKey: .ftsFailedBatchCount) ?? 0
        reconciliationPending = try c.decodeIfPresent(Bool.self, forKey: .reconciliationPending) ?? false
        storeCountBefore = try c.decodeIfPresent(Int.self, forKey: .storeCountBefore)
        storeCountAfter = try c.decodeIfPresent(Int.self, forKey: .storeCountAfter)
        ftsRowCount = try c.decodeIfPresent(Int.self, forKey: .ftsRowCount)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
    }
}

/// Persists receipts as JSON files under a directory (production: Application
/// Support). Read back for a receipt viewer / export.
struct ImportReceiptStore {
    let directory: URL

    static var production: ImportReceiptStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ImportReceiptStore(directory: appSupport
            .appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true))
    }

    @discardableResult
    func save(_ receipt: ImportReceipt) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // W3: receipts are written mid-import, which may outlive a device
        // lock — background-readable class; owner-only on macOS.
        ArtifactProtection.applyBackgroundReadable(to: directory)
        let stamp = Int(receipt.completedAt.timeIntervalSince1970)
        let url = directory.appendingPathComponent("receipt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(receipt).write(to: url)
        ArtifactProtection.applyBackgroundReadable(to: url)
        return url
    }

    func load(_ url: URL) throws -> ImportReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ImportReceipt.self, from: Data(contentsOf: url))
    }

    func list() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }
}
