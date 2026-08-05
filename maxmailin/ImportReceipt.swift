//
//  ImportReceipt.swift
//  maxmailin
//
//  Stage 5 W3 / Phase 12 (v2-core-cutover): a durable, tamper-evident record of
//  every import run — source identity (name/size/SHA-256/parser), outcome
//  (discovered/inserted/duplicates/skipped), timing, and integrity
//  (store-count delta + FTS row count). The receipt is SHA-256 self-hashed so
//  any later edit is detectable, and persisted as JSON for viewing/export.
//

import Foundation
import CryptoKit

struct ImportReceipt: Codable, Sendable, Equatable {
    struct SourceRecord: Codable, Sendable, Equatable {
        var filename: String
        var sizeBytes: Int
        var sha256: String
        var parser: String
        var parserVersion: Int
    }

    // Source
    var sources: [SourceRecord] = []
    // Outcome
    var discovered: Int = 0
    var inserted: Int = 0
    var duplicates: Int = 0
    var skipped: Int = 0
    var warnings: [String] = []
    // Timing
    var startedAt: Date
    var completedAt: Date
    var durationSeconds: Double = 0
    // Recovery
    var resumed: Bool = false
    // Integrity
    var storeCountBefore: Int = 0
    var storeCountAfter: Int = 0
    var ftsRowCount: Int = 0
    /// SHA-256 over the canonical JSON of every OTHER field. Empty until finalized.
    var contentHash: String = ""

    private func canonicalHash() -> String {
        var copy = self
        copy.contentHash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stamp the self-hash. Call once, last.
    mutating func finalize() { contentHash = canonicalHash() }

    /// True iff the receipt has not been altered since `finalize()`.
    func verify() -> Bool { !contentHash.isEmpty && contentHash == canonicalHash() }
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
        let stamp = Int(receipt.completedAt.timeIntervalSince1970)
        let url = directory.appendingPathComponent("receipt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(receipt).write(to: url)
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
