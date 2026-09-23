//
//  ImportVerdictTests.swift
//  maxmailinTests
//
//  Plan task A5. The directive: Complete only when counts and index state
//  reconcile; anything else is labelled Partial or Failed precisely. These
//  tests pin the reconciliation arithmetic, including the cases where a count
//  is *unavailable* (nil) rather than zero — fabricating a zero there is how an
//  import looks clean while messages are missing.
//

import Testing
import Foundation
@testable import maxmailin

private func receipt(
    discovered: Int, parsed: Int, inserted: Int? = nil, duplicates: Int? = nil,
    damaged: Int = 0, persistFailed: Int = 0, indexed: Int = 0,
    ftsDegraded: Bool = false, reconciliationPending: Bool = false,
    sources: Int = 1, fileFailures: Int = 0
) -> ImportReceipt {
    var r = ImportReceipt(startedAt: Date(), completedAt: Date())
    r.discovered = discovered
    r.parsed = parsed
    r.inserted = inserted
    r.duplicates = duplicates
    r.damaged = damaged
    r.persistFailed = persistFailed
    r.indexed = indexed
    r.ftsDegraded = ftsDegraded
    r.reconciliationPending = reconciliationPending
    r.sources = (0..<sources).map { i in
        ImportReceipt.SourceRecord(
            filename: "source-\(i).mbox", sizeBytes: 1024, sha256: "deadbeef\(i)",
            parser: "MBOXParser", parserVersion: 1
        )
    }
    r.fileFailures = (0..<fileFailures).map { i in
        ImportReceipt.FileFailure(filename: "source-\(i).mbox", message: "unreadable")
    }
    return r
}

@Suite("Import verdict reconciliation (A5)")
struct ImportVerdictTests {

    @Test("A clean run reconciles to Complete")
    func cleanRunIsComplete() {
        let r = receipt(discovered: 526, parsed: 526, inserted: 526, duplicates: 0, indexed: 526)
        #expect(r.verdict == .complete)
        #expect(r.verdict.label == "Complete")
    }

    @Test("Deduplicated messages still reconcile to Complete")
    func duplicatesAreAccountedFor() {
        // 100 parsed, 90 stored, 10 recognised duplicates: nothing is missing.
        let r = receipt(discovered: 100, parsed: 100, inserted: 90, duplicates: 10, indexed: 90)
        #expect(r.verdict == .complete)
    }

    @Test("Damaged messages make it Partial, not Complete")
    func damagedIsPartial() {
        let r = receipt(discovered: 100, parsed: 98, inserted: 98, duplicates: 0,
                        damaged: 2, indexed: 98)
        #expect(r.verdict == .partial([.damagedMessages]))
    }

    @Test("Fewer searchable rows than stored rows is Partial")
    func indexShortfallIsPartial() {
        let r = receipt(discovered: 100, parsed: 100, inserted: 100, duplicates: 0, indexed: 40)
        #expect(r.verdict == .partial([.indexIncomplete]))
    }

    @Test("A knowingly-degraded index reports reconciliation, not a bare index gap")
    func degradedIndexReportsReconciliation() {
        let r = receipt(discovered: 100, parsed: 100, inserted: 100, duplicates: 0,
                        indexed: 0, ftsDegraded: true)
        #expect(r.verdict == .partial([.reconciliationPending]))
        #expect(!r.verdict.shortfalls.contains(.indexIncomplete),
                "one cause should not be reported twice under two names")
    }

    @Test("Messages that are neither stored, duplicate nor failed are unaccounted for")
    func accountingHoleIsCaught() {
        // 100 parsed but only 80 stored, no duplicates, no failures: 20 vanished.
        let r = receipt(discovered: 100, parsed: 100, inserted: 80, duplicates: 0, indexed: 80)
        #expect(r.verdict.shortfalls.contains(.unaccountedMessages))
    }

    @Test("An unavailable store count is never treated as zero")
    func nilCountsDoNotFabricateFailure() {
        // inserted == nil means "could not read the store count", so the
        // accounting check must be skipped rather than reporting 100 missing.
        let r = receipt(discovered: 100, parsed: 100, inserted: nil, duplicates: nil, indexed: 100)
        #expect(!r.verdict.shortfalls.contains(.unaccountedMessages))
        #expect(r.verdict == .complete)
    }

    @Test("Nothing parsed from a source that had messages is Failed")
    func parsedNothingIsFailed() {
        let r = receipt(discovered: 500, parsed: 0, inserted: 0, duplicates: 0,
                        damaged: 500, indexed: 0)
        #expect(r.verdict.label == "Failed")
        #expect(r.verdict.shortfalls.contains(.damagedMessages))
    }

    @Test("Nothing stored despite parsing is Failed")
    func storedNothingIsFailed() {
        let r = receipt(discovered: 50, parsed: 50, inserted: 0, duplicates: 0,
                        persistFailed: 50, indexed: 0)
        #expect(r.verdict.label == "Failed")
        #expect(r.verdict.shortfalls.contains(.persistFailures))
    }

    @Test("Every source failing is Failed; one of several failing is Partial")
    func sourceFailureSeverityScales() {
        let all = receipt(discovered: 0, parsed: 0, inserted: 0, duplicates: 0,
                          indexed: 0, sources: 2, fileFailures: 2)
        #expect(all.verdict.label == "Failed")

        let some = receipt(discovered: 60, parsed: 60, inserted: 60, duplicates: 0,
                           indexed: 60, sources: 3, fileFailures: 1)
        #expect(some.verdict.label == "Partial")
        #expect(some.verdict.shortfalls == [.sourceFileFailures])
    }

    @Test("Every verdict carries a plain-language explanation")
    func shortfallsExplainThemselves() {
        for shortfall in ImportShortfall.allCases {
            #expect(!shortfall.explanation.isEmpty)
        }
        let r = receipt(discovered: 10, parsed: 9, inserted: 9, duplicates: 0,
                        damaged: 1, indexed: 9)
        #expect(!r.verdict.summary.isEmpty)
    }
}


@Suite("Printable receipt (A5c)")
@MainActor
struct ImportReceiptRenderingTests {

    @Test("The printable receipt carries verdict, source identity and accounting")
    func plainTextIsSelfContained() {
        var r = receipt(discovered: 526, parsed: 524, inserted: 520, duplicates: 4,
                        damaged: 2, indexed: 500)
        try? r.finalize()
        let text = ImportReceiptView(receipt: r).plainText()

        #expect(text.contains("Verdict: Partial"))
        #expect(text.contains("source-0.mbox"))
        #expect(text.contains("SHA-256 deadbeef0"))
        #expect(text.contains("discovered: 526"))
        #expect(text.contains("read: 524"))
        #expect(text.contains("saved: 520"))
        #expect(text.contains("duplicates: 4"))
        #expect(text.contains("damaged: 2"))
        #expect(text.contains("indexed: 500"))
        #expect(text.contains("Integrity:"))
        #expect(text.contains("Content hash:"))
    }

    @Test("An unavailable count prints as unavailable, never as zero")
    func unavailableCountsAreNotZero() {
        var r = receipt(discovered: 100, parsed: 100, inserted: nil, duplicates: nil, indexed: 100)
        try? r.finalize()
        let text = ImportReceiptView(receipt: r).plainText()

        #expect(text.contains("saved: unavailable"))
        #expect(text.contains("duplicates: unavailable"))
        #expect(!text.contains("saved: 0"), "a count we could not read must not be reported as 0")
    }

    @Test("A tampered receipt says so in the printable copy")
    func tamperIsVisibleInPrintout() {
        var r = receipt(discovered: 10, parsed: 10, inserted: 10, duplicates: 0, indexed: 10)
        try? r.finalize()
        r.discovered = 999   // edit after signing
        let text = ImportReceiptView(receipt: r).plainText()
        #expect(text.contains("DOES NOT VERIFY"))
    }
}
