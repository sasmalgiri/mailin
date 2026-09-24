//
//  ImportMemoryBudgetTests.swift
//  maxmailinTests
//
//  Plan task P3.3. Measurement showed that import peak memory is owned by the
//  SQLite page caches and by one connection per year-shard, not by batch
//  residency (RELEASE_READINESS.md §P0.2 CORRECTION). These tests pin the two
//  levers that follow: a tighter storage budget during an import, and a cap on
//  concurrently-open shard connections — both restored afterwards, because an
//  interactive archive still wants the big cache for deep-page seeks.
//

import Testing
import Foundation
@testable import maxmailin

private func emails(years: [Int]) -> [MBOXParser.RawEmail] {
    years.enumerated().map { index, year in
        MBOXParser.RawEmail(
            headers: [
                "From": "sender@example.com",
                "To": "recipient@example.com",
                "Subject": "Budget probe \(year)",
                "Date": "Tue, 14 Mar \(year) 09:41:00 +0000",
                "Message-ID": "<budget-\(year)-\(index)@example.com>"
            ],
            rawSource: "",
            messageType: "email",
            attachments: [],
            timestamp: "Tue, 14 Mar \(year) 09:41:00 +0000",
            domains: ["example.com"],
            plainBody: "budgettoken\(year) body text",
            htmlBody: ""
        )
    }
}

@Suite("Import memory budget (P3.3)")
struct ImportMemoryBudgetTests {

    @Test("The import budget is materially smaller than the interactive one")
    func budgetsDiffer() {
        #expect(SQLiteEmailStore.importBudget.cacheKB < SQLiteEmailStore.interactiveBudget.cacheKB)
        #expect(SQLiteEmailStore.importBudget.mmapBytes < SQLiteEmailStore.interactiveBudget.mmapBytes)
        // Interactive keeps the 128 MB cache the deep-page seeks were tuned for.
        #expect(SQLiteEmailStore.interactiveBudget.cacheKB == 131_072)
    }

    @Test("Switching the store budget takes effect and is reversible")
    func storeBudgetSwitches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)

        // Force the connection open so the pragmas are live.
        _ = try await store.totalCount()
        #expect(await store.activeBudget == SQLiteEmailStore.interactiveBudget)

        await store.setMemoryBudget(SQLiteEmailStore.importBudget)
        #expect(await store.activeBudget == SQLiteEmailStore.importBudget)

        await store.setMemoryBudget(SQLiteEmailStore.interactiveBudget)
        #expect(await store.activeBudget == SQLiteEmailStore.interactiveBudget)

        // The store still works after the round trip — a budget change must not
        // disturb the data.
        #expect(try await store.totalCount() == 0)
    }

    @Test("Import mode caps open shard connections and evicts the excess now")
    func importModeCapsShards() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-fts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fts = FTSSearchIndex(shardsDirectory: root)

        // Ten years → ten shard connections under interactive limits.
        try await fts.indexBatch(emails(years: Array(2010...2019)))
        let before = await fts.shardBudget
        #expect(before.open == 10)
        #expect(before.cap == 20)

        await fts.beginImportMode()
        let during = await fts.shardBudget
        #expect(during.cap == 4, "import mode must cap concurrent shard handles")
        #expect(during.open <= during.cap, "handles above the new cap are evicted immediately")
        #expect(during.cacheKB < before.cacheKB, "and each remaining handle holds less cache")

        // Data survives the eviction: a swept shard reopens on demand.
        let rows = try await fts.rowCount()
        #expect(rows == 10)
        let hits = try await fts.searchRaw("budgettoken2015", limit: 5)
        #expect(hits.count == 1)

        await fts.endImportMode()
        let after = await fts.shardBudget
        #expect(after.cap == 20, "interactive limits are restored")
        #expect(after.cacheKB == before.cacheKB)
    }

    @Test("Indexing a wide date range in import mode stays within the cap")
    func wideDateRangeStaysCapped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-wide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fts = FTSSearchIndex(shardsDirectory: root)

        await fts.beginImportMode()
        // 19 years, the spread of the real fixture.
        try await fts.indexBatch(emails(years: Array(2007...2025)))

        let budget = await fts.shardBudget
        #expect(budget.open <= budget.cap,
                "a 19-year corpus must not hold 19 connections while importing")
        #expect(try await fts.rowCount() == 19, "every year is still indexed")
    }
}


@Suite("Attachment-byte compaction (P3.4)")
struct AttachmentCompactionTests {

    /// An mbox with one base64 attachment, so the payload is unambiguous.
    private func writeMBOXWithAttachment(payloadKB: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-\(UUID().uuidString).mbox")
        let payload = Data(repeating: 0x41, count: payloadKB * 1024).base64EncodedString()
        let text = """
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: sender@example.com
        To: recipient@example.com
        Subject: Compaction probe
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <compaction@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain

        body text here
        --BOUND
        Content-Type: application/octet-stream; name="payload.bin"
        Content-Disposition: attachment; filename="payload.bin"
        Content-Transfer-Encoding: base64

        \(payload)
        --BOUND--

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("The extractor never populates attachment base64 — so that was not the cost")
    func attachmentBytesAreNotRetainedEitherWay() async throws {
        let url = try writeMBOXWithAttachment(payloadKB: 256)
        defer { try? FileManager.default.removeItem(at: url) }

        var retained: MBOXParser.RawEmail?
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 10, retainAttachmentBytes: true
        ) { batch in retained = batch.first }

        let full = try #require(retained)
        #expect(full.attachments.count == 1)
        // Recorded as a finding, not a wish: EmailBodyExtractor deliberately
        // leaves base64 nil (EmailBodyExtractor.swift:325), so attachment
        // payload duplication was never part of the import peak.
        #expect(full.attachments[0].base64 == nil)
        #expect(full.attachments[0].size > 0, "metadata is still complete")
    }

    @Test("The retained MIME tree is negligible — also not the cost")
    func mimeTreeIsNegligible() async throws {
        let url = try writeMBOXWithAttachment(payloadKB: 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        var email: MBOXParser.RawEmail?
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 10, retainAttachmentBytes: true
        ) { batch in email = batch.first }

        let parsed = try #require(email)
        let treeBytes = parsed.mimeRoot.map { Self.treeBytes($0) } ?? 0

        // Recorded as measurement, not aspiration: for a 1.4 MB message the
        // retained tree was 28 bytes, so dropping it cannot explain — or fix —
        // the import peak. RSS itself varied 419–478 MiB across identical runs,
        // which is why this suite counts object bytes instead.
        #expect(parsed.rawSource.utf8.count > 1_000_000)
        #expect(treeBytes < 10_000,
                "the MIME tree does not retain the message payload")
    }

    /// Bytes a MIME part subtree retains: `body` and `rawBody` per part, plus
    /// any `rawData`, recursively.
    private static func treeBytes(_ part: MIMEPart) -> Int {
        var total = part.body.utf8.count + part.rawBody.utf8.count
        total += part.rawData?.count ?? 0
        for sub in part.subparts { total += treeBytes(sub) }
        return total
    }
}
