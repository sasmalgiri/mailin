//
//  IndexCoverageTests.swift
//  maxmailinTests
//
//  S0 of SIZE_LIMITS_DESIGN.md. Before this, `insertWithHandle` indexed
//  `String(body.prefix(50_000))` and said nothing: a 380 MB message was
//  indexed to 50,000 characters while search implied completeness. That is the
//  same silent-truncation defect `BoundedRegexSearch` already refuses to commit
//  (it returns `truncated: true`), so the rule now applies to indexing too.
//
//  What these tests pin: the budget is bytes (not characters), it truncates on
//  a valid UTF-8 boundary, the coverage is recorded per message, and a
//  fully-indexed message is not mislabelled as partial.
//

import Testing
import Foundation
@testable import maxmailin

private func email(year: Int, body: String, subject: String = "Coverage probe") -> MBOXParser.RawEmail {
    MBOXParser.RawEmail(
        headers: [
            "From": "sender@example.com",
            "To": "recipient@example.com",
            "Subject": subject,
            "Date": "Tue, 14 Mar \(year) 09:41:00 +0000",
            "Message-ID": "<coverage-\(UUID().uuidString)@example.com>"
        ],
        rawSource: "",
        messageType: "email",
        attachments: [],
        timestamp: "Tue, 14 Mar \(year) 09:41:00 +0000",
        domains: ["example.com"],
        plainBody: body,
        htmlBody: ""
    )
}

@Suite("Search-index coverage (S0)")
struct IndexCoverageTests {

    // MARK: The budget itself

    @Test("A short body is fully indexed and not reported as truncated")
    func shortBodyIsComplete() {
        let coverage = FTSSearchIndex.indexableText("a short body")
        #expect(!coverage.isTruncated)
        #expect(coverage.indexedBytes == coverage.totalBytes)
        #expect(coverage.indexed == "a short body")
        #expect(coverage.summary == "Fully indexed for search.")
    }

    @Test("A body over the budget is truncated to the budget and says so")
    func longBodyIsTruncatedAndReported() {
        let body = String(repeating: "x", count: FTSSearchIndex.indexedTextBudgetBytes + 10_000)
        let coverage = FTSSearchIndex.indexableText(body)

        #expect(coverage.isTruncated)
        #expect(coverage.indexedBytes <= FTSSearchIndex.indexedTextBudgetBytes)
        #expect(coverage.totalBytes == body.utf8.count)
        #expect(coverage.summary.contains("search covers the first part"))
    }

    @Test("The budget is bytes, not characters")
    func budgetIsBytesNotCharacters() {
        // Each emoji is 4 UTF-8 bytes, so a string with a quarter of the budget
        // in *characters* is exactly at the budget in bytes.
        let emoji = String(repeating: "🧿", count: FTSSearchIndex.indexedTextBudgetBytes / 4)
        let coverage = FTSSearchIndex.indexableText(emoji)

        #expect(coverage.totalBytes == FTSSearchIndex.indexedTextBudgetBytes)
        #expect(!coverage.isTruncated, "a body exactly at the byte budget is complete")

        let overBudget = emoji + "🧿🧿"
        let cut = FTSSearchIndex.indexableText(overBudget)
        #expect(cut.isTruncated)
        #expect(cut.indexedBytes <= FTSSearchIndex.indexedTextBudgetBytes)
    }

    @Test("Truncation lands on a valid UTF-8 boundary, never mid-scalar")
    func truncationIsUTF8Safe() {
        // Fill past the budget with multi-byte scalars so a naive byte cut
        // would slice one in half.
        let body = String(repeating: "é", count: FTSSearchIndex.indexedTextBudgetBytes)
        let coverage = FTSSearchIndex.indexableText(body)

        #expect(coverage.isTruncated)
        #expect(!coverage.indexed.unicodeScalars.contains("\u{FFFD}"),
                "the indexed text must not contain a replacement character")
        // Round-trips cleanly, which a broken scalar would not.
        #expect(String(decoding: Array(coverage.indexed.utf8), as: UTF8.self) == coverage.indexed)
    }

    // MARK: Recorded per message

    @Test("Coverage is persisted with the indexed row and read back")
    func coverageIsPersisted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fts = FTSSearchIndex(shardsDirectory: root)

        let small = email(year: 2018, body: "tiny body")
        let huge = email(year: 2018,
                         body: String(repeating: "y", count: FTSSearchIndex.indexedTextBudgetBytes + 5_000))
        try await fts.indexBatch([small, huge])

        let smallCoverage = try await fts.coverage(for: small.id)
        let hugeCoverage = try await fts.coverage(for: huge.id)

        let s = try #require(smallCoverage)
        #expect(s.indexedBytes == s.totalBytes, "a small message is fully indexed")

        let h = try #require(hugeCoverage)
        #expect(h.totalBytes > h.indexedBytes, "a huge message records the shortfall")
        #expect(h.indexedBytes <= FTSSearchIndex.indexedTextBudgetBytes)
    }

    @Test("The partially-indexed count is what a coverage badge needs")
    func partialCountIsQueryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-count-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fts = FTSSearchIndex(shardsDirectory: root)

        let over = String(repeating: "z", count: FTSSearchIndex.indexedTextBudgetBytes + 1_000)
        try await fts.indexBatch([
            email(year: 2016, body: "small one"),
            email(year: 2016, body: over),
            email(year: 2017, body: over)
        ])

        #expect(try await fts.partiallyIndexedCount() == 2,
                "only the two oversized messages count as partially indexed")
        #expect(try await fts.rowCount() == 3, "all three are still searchable")
    }

    @Test("A truncated message is still findable by text inside the budget")
    func truncatedMessageStillSearchable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fts = FTSSearchIndex(shardsDirectory: root)

        // A findable token at the start, then padding past the budget.
        let body = "needlemarker at the beginning "
            + String(repeating: "w", count: FTSSearchIndex.indexedTextBudgetBytes + 2_000)
        try await fts.indexBatch([email(year: 2019, body: body)])

        let hits = try await fts.searchRaw("needlemarker", limit: 10)
        #expect(hits.count == 1, "text within the budget is still searchable")

        #expect(try await fts.partiallyIndexedCount() == 1,
                "and the message is flagged as only partly covered")
    }
}
