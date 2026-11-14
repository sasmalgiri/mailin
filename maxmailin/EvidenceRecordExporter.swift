@testable import ArchiveCore
//
//  EvidenceRecordExporter.swift
//  maxmailin
//
//  §3-E2 (switch: `v3Fingerprints`). Long-term evidence records in the
//  style of RFC 4998 (Evidence Record Syntax): every email gets a hash-tree
//  proof from its own leaf up to the archive root, so each email can be
//  verified on its own, years later, with nothing but SHA-256.
//
//  Format (JSON lines, one object per line):
//   1. a header — format, archive root, every month root, the hashing rule,
//      the archive revision and how to verify;
//   2. one line per email in scope — its leaf, its month bucket, the
//      sibling hashes from the leaf to the month root, and from the month
//      root to the archive root.
//
//  Hashing rule (as `SQLiteEmailStore.merkleRoot`): parent = SHA-256 hex of
//  "<left hex>|<right hex>"; an odd node is carried up unchanged. A leaf is
//  SHA-256 of the email's raw MIME (or the stored-body digest; see F5).
//
//  Time: the header's `generatedAt` is the device clock. An independent
//  time-stamp (RFC 3161) is §3-E3, an online option; offline, print or send
//  the archive root to a third party (linked time-stamping).
//

import Foundation

@MainActor
enum EvidenceRecordExporter {
    struct Step: Codable { let side: String; let hash: String }   // "L" or "R" = side of the SIBLING

    /// Proof path for `index` in `leaves` (merkleRoot's pairing rule).
    nonisolated static func path(for index: Int, in leaves: [String]) -> [Step] {
        var steps: [Step] = []
        var level = leaves
        var i = index
        while level.count > 1 {
            let sibling = i ^ 1
            if sibling < level.count {
                steps.append(Step(side: sibling < i ? "L" : "R", hash: level[sibling]))
            }
            var next: [String] = []
            var j = 0
            while j < level.count {
                if j + 1 < level.count {
                    next.append(SQLiteEmailStore.merkleRoot([level[j], level[j + 1]]))
                } else {
                    next.append(level[j])
                }
                j += 2
            }
            level = next
            i /= 2
        }
        return steps
    }

    static func export(scope: ArchiveScope) async -> (ExportOutcome, Int) {
        var written = 0
        var root = ""
        let (outcome, _) = await PlatformExport.saveStreamed(suggestedName: "evidence_record.jsonl") { url in
            let out = try await write(scope: scope, to: url)
            written = out.written
            root = out.root
            return out.file
        }
        if outcome.succeeded {
            ScopeJobEnvironment.logAction("Evidence record exported",
                detail: "\(written) emails with hash-tree proofs to archive root \(root.prefix(16))…")
        }
        return (outcome, written)
    }

    struct WriteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes the record for every email in `scope` to `url` (streamed, one
    /// month at a time). Returns how many emails it covers and the archive root.
    static func write(scope: ArchiveScope, to url: URL) async throws
        -> (written: Int, root: String, file: ArchiveExportResult) {
        var inScope = Set<UUID>()
        for try await page in ScopeJobEnvironment.archive.streamSummaries(query: scope.query, batchSize: 5_000) {
            inScope.formUnion(page.map(\.id))
        }
        var written = 0
        var root = ""
        let file = try await StreamedTextFile.write(to: url) { emit in
            (written, root) = try await emitRecord(for: inScope, emit: emit)
        }
        return (written, root, file)
    }

    /// The record for exactly `ids` as one JSON-lines text — what a case
    /// bundle carries (§3-E2), sealed with the bundle.
    static func record(for ids: Set<UUID>) async throws -> (text: String, written: Int, root: String) {
        var text = ""
        let (written, root) = try await emitRecord(for: ids) { text += $0 }
        return (text, written, root)
    }

    /// Builds missing leaves, then emits the header and one proof line per
    /// email in `inScope`, month by month.
    private static func emitRecord(for inScope: Set<UUID>, emit: (String) throws -> Void) async throws -> (Int, String) {
        let store = ScopeJobEnvironment.store
        while try await store.fingerprintBuildMissing(limit: 1_000) > 0 {}
        try await store.fingerprintRefreshBuckets()
        guard let tree = try? await store.fingerprintTree() else {
            throw WriteError(message: String(localized: "the archive fingerprint could not be read"))
        }
        let bucketRoots = tree.buckets.map(\.root)
        let revision = (try? await store.corpusRevision()) ?? 0
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let header = Header(
            format: "mailin-evidence-record/1", style: "RFC 4998 (Evidence Record Syntax) hash-tree proofs",
            archiveRoot: tree.root, generatedAt: ISO8601DateFormatter().string(from: Date()),
            archiveRevision: revision, emailsInRecord: inScope.count,
            buckets: tree.buckets.map { ["month": String($0.bucket), "root": $0.root, "leaves": String($0.leaves)] },
            hashRule: "parent = SHA-256 hex of \"<left>|<right>\"; an odd node is carried up unchanged",
            leafRule: "leaf = SHA-256 hex of the email's raw MIME bytes; a leaf starting \"p:\" belongs to an email stored without raw MIME and is SHA-256 over its length-prefixed plain, HTML and header bytes",
            verify: "Hash the email's raw MIME; fold with each step of `bucketPath` (L = sibling on the left), compare with the month root; fold with each step of `rootPath`, compare with archiveRoot.")
        try emit(String(decoding: try enc.encode(header), as: UTF8.self) + "\n")
        var written = 0
        for (bucketIndex, bucket) in tree.buckets.enumerated() {
            let leaves = try await store.fingerprintLeaves(bucket: bucket.bucket)
            let hexes = leaves.map(\.leaf)
            let rootPath = path(for: bucketIndex, in: bucketRoots)
            var chunk = ""
            for (i, leaf) in leaves.enumerated() where inScope.contains(leaf.id) {
                let line = Line(id: leaf.id.uuidString, leaf: leaf.leaf, month: bucket.bucket,
                                bucketPath: path(for: i, in: hexes), rootPath: rootPath)
                chunk += String(decoding: try enc.encode(line), as: UTF8.self) + "\n"
                written += 1
            }
            if !chunk.isEmpty { try emit(chunk) }
        }
        return (written, tree.root)
    }

    struct Header: Codable {
        let format: String, style: String, archiveRoot: String, generatedAt: String
        let archiveRevision: Int, emailsInRecord: Int, buckets: [[String: String]]
        let hashRule: String, leafRule: String, verify: String
    }
    struct Line: Codable { let id: String; let leaf: String; let month: Int; let bucketPath: [Step]; let rootPath: [Step] }

    /// Folds `start` up a proof path (the header's verification rule).
    nonisolated static func fold(_ start: String, _ steps: [Step]) -> String {
        steps.reduce(start) { h, step in
            step.side == "L" ? SQLiteEmailStore.merkleRoot([step.hash, h]) : SQLiteEmailStore.merkleRoot([h, step.hash])
        }
    }
}
