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
