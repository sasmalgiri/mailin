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
        let store = SQLiteEmailStore.shared
        do {
            while try await store.fingerprintBuildMissing(limit: 1_000) > 0 {}
            try await store.fingerprintRefreshBuckets()
        } catch {
            return (.failed(error.localizedDescription), 0)
        }
        guard let tree = try? await store.fingerprintTree() else {
            return (.failed(String(localized: "the archive fingerprint could not be read")), 0)
        }
        // Emails in scope (ids only).
        var inScope = Set<UUID>()
        do {
            for try await page in ArchiveDataService.shared.streamSummaries(query: scope.query, batchSize: 5_000) {
                inScope.formUnion(page.map(\.id))
            }
        } catch {
            return (.failed(error.localizedDescription), 0)
        }
        let bucketRoots = tree.buckets.map(\.root)
        let revision = (try? await store.corpusRevision()) ?? 0
        var written = 0
        let (outcome, _) = await PlatformExport.saveStreamed(suggestedName: "evidence_record.jsonl") { url in
            try await StreamedTextFile.write(to: url) { emit in
                let enc = JSONEncoder()
                enc.outputFormatting = [.sortedKeys]
                struct Header: Codable {
                    let format: String, style: String, archiveRoot: String, generatedAt: String
                    let archiveRevision: Int, emailsInRecord: Int, buckets: [[String: String]]
                    let hashRule: String, leafRule: String, verify: String
                }
                let header = Header(
                    format: "mailin-evidence-record/1", style: "RFC 4998 (Evidence Record Syntax) hash-tree proofs",
                    archiveRoot: tree.root, generatedAt: ISO8601DateFormatter().string(from: Date()),
                    archiveRevision: revision, emailsInRecord: inScope.count,
                    buckets: tree.buckets.map { ["month": String($0.bucket), "root": $0.root, "leaves": String($0.leaves)] },
                    hashRule: "parent = SHA-256 hex of \"<left>|<right>\"; an odd node is carried up unchanged",
                    leafRule: "leaf = SHA-256 hex of the email's raw MIME bytes; a leaf starting \"p:\" belongs to an email stored without raw MIME and is SHA-256 over its length-prefixed plain, HTML and header bytes",
                    verify: "Hash the email's raw MIME; fold with each step of `bucketPath` (L = sibling on the left), compare with the month root; fold with each step of `rootPath`, compare with archiveRoot.")
                try emit(String(data: try enc.encode(header), encoding: .utf8)! + "\n")
                struct Line: Codable { let id: String; let leaf: String; let month: Int; let bucketPath: [Step]; let rootPath: [Step] }
                for (bucketIndex, bucket) in tree.buckets.enumerated() {
                    let leaves = try await store.fingerprintLeaves(bucket: bucket.bucket)
                    let hexes = leaves.map(\.leaf)
                    let rootPath = path(for: bucketIndex, in: bucketRoots)
                    var chunk = ""
                    for (i, leaf) in leaves.enumerated() where inScope.contains(leaf.id) {
                        let line = Line(id: leaf.id.uuidString, leaf: leaf.leaf, month: bucket.bucket,
                                        bucketPath: path(for: i, in: hexes), rootPath: rootPath)
                        chunk += String(data: try enc.encode(line), encoding: .utf8)! + "\n"
                        written += 1
                    }
                    if !chunk.isEmpty { try emit(chunk) }
                }
            }
        }
        if outcome.succeeded {
            ForensicManager.shared.logAction("Evidence record exported",
                detail: "\(written) emails with hash-tree proofs to archive root \(tree.root.prefix(16))…")
        }
        return (outcome, written)
    }
}
