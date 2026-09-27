@testable import ArchiveCore
//
//  SearchMatchFieldsTests.swift
//  maxmailinTests
//
//  A7: the per-result "matching field" indicator reads the search through
//  the one compiler and attributes each row's hit to the field(s) that
//  explain it. These pin the attribution rules, not the search itself.
//

import XCTest
@testable import maxmailin

private func email(from: String = "Alice Example <alice@example.com>",
                   to: String = "bob@example.com",
                   subject: String = "Quarterly report",
                   body: String = "Please find the invoice attached.",
                   attachments: [AttachmentMetadata] = [],
                   compacted: Bool = false) -> MBOXParser.RawEmail {
    var raw = MBOXParser.RawEmail(
        headers: ["From": from, "To": to, "Subject": subject,
                  "Date": "Tue, 14 Mar 2017 09:41:00 +0000",
                  "Message-ID": "<match-\(UUID().uuidString)@example.com>"],
        rawSource: "",
        messageType: "email",
        attachments: attachments,
        timestamp: "Tue, 14 Mar 2017 09:41:00 +0000",
        domains: ["example.com"],
        plainBody: body,
        htmlBody: ""
    )
    if compacted {
        raw.isBodyCompacted = true
        raw.bodyPreview = String(body.prefix(20))
        raw.plainBody = ""
    }
    return raw
}

final class SearchMatchFieldsTests: XCTestCase {

    // MARK: Term extraction

    func testPositiveTerms_dropOperatorsAndExcludedWords() {
        XCTAssertEqual(SearchMatchTerms.positiveTerms(in: "\"exact phrase\" AND (alpha OR beta) NOT gamma"),
                       ["exact phrase", "alpha", "beta"])
        XCTAssertEqual(SearchMatchTerms.positiveTerms(in: "invoic*"), ["invoic"])
        XCTAssertEqual(SearchMatchTerms.positiveTerms(in: ""), [])
    }

    func testPositiveTerms_regexAndProximityHaveNoPerFieldReading() {
        XCTAssertEqual(SearchMatchTerms.positiveTerms(in: "/inv[0-9]+/"), [])
        XCTAssertEqual(SearchMatchTerms.positiveTerms(in: "invoice NEAR/3 overdue"), [])
    }

    func testTerms_readTheSameOperatorsAsTheCompiler() {
        let terms = SearchMatchTerms(searchText: "from:Alice subject:\"quarterly report\" filename:pdf tag:Important budget")
        XCTAssertEqual(terms.sender, "alice")
        XCTAssertEqual(terms.subject, "quarterly report")
        XCTAssertEqual(terms.attachmentName, "pdf")
        XCTAssertEqual(terms.tag, "important")
        XCTAssertEqual(terms.freeTerms, ["budget"])
        XCTAssertFalse(terms.isEmpty)
        XCTAssertTrue(SearchMatchTerms(searchText: "   ").isEmpty)
    }

    // MARK: Attribution

    func testFreeText_isAttributedToEveryVisibleFieldItAppearsIn() {
        let terms = SearchMatchTerms(searchText: "report")
        let fields = terms.matchedFields(in: email(subject: "Quarterly report", body: "The report is attached."))
        XCTAssertEqual(fields, [.subject, .body])
    }

    func testFreeText_hitInSenderOnly_isNotAttributedToBody() {
        let terms = SearchMatchTerms(searchText: "alice")
        XCTAssertEqual(terms.matchedFields(in: email(body: "Nothing relevant here.")), [.sender])
    }

    func testFreeText_hitInAttachmentName() {
        let terms = SearchMatchTerms(searchText: "contract")
        let row = email(subject: "Signed", body: "See attached.",
                        attachments: [AttachmentMetadata(filename: "Contract-Final.PDF", mimeType: "application/pdf", size: 10)])
        XCTAssertEqual(terms.matchedFields(in: row), [.attachment])
    }

    func testFreeText_unexplainedByVisibleFields_fallsBackToBody() {
        // The store matched this row (FTS, stemmed or beyond the preview);
        // nothing the row shows explains it, so Body is the honest answer.
        let terms = SearchMatchTerms(searchText: "reconciliation")
        let row = email(subject: "Numbers", body: "Full text lives past the preview… reconciliation", compacted: true)
        XCTAssertEqual(terms.matchedFields(in: row), [.body])
    }

    func testStemTolerance_pluralFindsSingular() {
        let terms = SearchMatchTerms(searchText: "invoices")
        XCTAssertEqual(terms.matchedFields(in: email(subject: "Your invoice", body: "unrelated")), [.subject])
    }

    func testOperatorFields_areMarkedBecauseTheStoreGuaranteedThem() {
        let terms = SearchMatchTerms(searchText: "from:alice filename:pdf source:takeout tag:Important")
        let row = email(body: "anything")
        XCTAssertEqual(terms.matchedFields(in: row), [.sender, .attachment, .source, .tag])
    }

    func testOperatorAndFreeText_combine_inDisplayOrder() {
        let terms = SearchMatchTerms(searchText: "from:alice invoice")
        XCTAssertEqual(terms.matchedFields(in: email(body: "Please find the invoice attached.")), [.sender, .body])
    }

    func testNoSearch_marksNothing() {
        XCTAssertEqual(SearchMatchTerms(searchText: "").matchedFields(in: email()), [])
    }

    func testSummaryRow_usesSubjectFromAndPreview() {
        let summary = EmailSummary(id: UUID(), messageID: nil, subject: "Budget review", from: "Alice",
                                   date: Date(), bodyPreview: "Attached is the budget.", hasAttachments: true, sizeBytes: 10)
        XCTAssertEqual(SearchMatchTerms(searchText: "budget").matchedFields(in: summary), [.subject, .body])
        XCTAssertEqual(SearchMatchTerms(searchText: "alice").matchedFields(in: summary), [.sender])
    }

    // MARK: Highlighting

    func testHighlightTerms_includeTheFieldOperatorValueAndFreeText() {
        let terms = SearchMatchTerms(searchText: "from:alice subject:report budget")
        XCTAssertEqual(terms.highlightTerms(for: .sender), ["alice", "budget"])
        XCTAssertEqual(terms.highlightTerms(for: .subject), ["report", "budget"])
        XCTAssertEqual(terms.highlightTerms(for: .body), ["budget"])
    }
}
