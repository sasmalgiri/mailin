//
//  ExtractedTextPagingTests.swift
//  ArchiveCoreTests
//
//  R7 (audit bf1a5b9): the store side of "Show text" — the existence query,
//  the outline, chunk pages, per-chunk match counts under the search's
//  phrase rule, the matched span carried by the evidence, and child counts
//  scoped to a query.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ExtractedTextPagingTests: XCTestCase {

    private static let filler = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor "
    private static func filler(_ characters: Int) -> String { String(repeating: filler, count: max(1, characters / filler.count)) }

    private func email(_ tag: String, year: Int, attachments: [AttachmentMetadata]) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<\(tag)-\(UUID().uuidString)@test>", "Subject": tag, "From": "a@test", "To": "me@test",
                      "Date": "Wed, 04 Jun \(year) 12:00:00 +0000"],
            rawSource: "", messageType: "email", attachments: attachments, timestamp: "\(year)-06-04T12:00:00Z", domains: [],
            plainBody: "body", htmlBody: "")
    }

    private func makeStore() throws -> SQLiteEmailStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
    }

    func testR7_phraseRuleMatchesMailinPhrase() throws {
        let cases: [(String, String)] = [
            ("The quarterly\n   results", "quarterly results"), ("quarterly\u{1E}results", "quarterly results"),
            ("quarterly \u{1E} results", "quarterly results"), ("QUARTERLY results", "quarterly RESULTS"),
            ("Éclair", "éclair"), ("x\u{00A0}y", "x y"), ("cost: $5 (net)", "$5 (net)"), ("foo.bar", "foo bar"), ("a  b", "a b"),
        ]
        for (text, literal) in cases {
            XCTAssertEqual(!SectionBoundary.phraseRanges(of: literal, in: text).isEmpty, SectionBoundary.contains(text, literal: literal),
                           "“\(literal)” in “\(text)”")
        }
        XCTAssertEqual(SectionBoundary.phraseRanges(of: "a b", in: "a b, a\tb, a\u{1E}b").count, 2)
        XCTAssertNil(SectionBoundary.phraseRegex("   "))

        let regex = try XCTUnwrap(SectionBoundary.phraseRegex("quarterly results"))
        let first = PhraseChunks.matches(in: "the quarterly ", previous: nil, next: "results here", regex: regex)
        let second = PhraseChunks.matches(in: "results here", previous: "the quarterly ", next: nil, regex: regex)
        XCTAssertEqual(first.starting, [NSRange(location: 4, length: 17)])
        XCTAssertEqual(second.starting, [])
        XCTAssertEqual(second.marks, [NSRange(location: 0, length: 7)])
    }

    func testR7_pagesCountsAndAnchorFromTheStore() async throws {
        let store = try makeStore()
        let mail = email("r7", year: 2025, attachments: [AttachmentMetadata(filename: "report.txt", mimeType: "text/plain", size: 10)])
        try await store.insertBatch([mail], batchSize: 10)
        let chunk = SearchChunker.chunkCharacters
        let text = Self.filler(chunk * 2 + chunk / 2) + "the quarterly\n   results were good " + Self.filler(chunk)
            + "and the Quarterly Results again " + Self.filler(chunk + chunk / 3) + "final quarterly results here " + Self.filler(2_000)
        try await store.indexAttachmentSearchDocuments(emailID: mail.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "report.txt", text: text, state: .complete, extractorVersion: 10, ocr: false)
        ])

        let has = try await store.attachmentDocumentHasText(emailID: mail.id, ordinal: 0)
        let hasNot = try await store.attachmentDocumentHasText(emailID: mail.id, ordinal: 3)
        XCTAssertTrue(has); XCTAssertFalse(hasNot)
        let outlineRead = try await store.attachmentDocumentOutline(emailID: mail.id, ordinal: 0)
        let outline = try XCTUnwrap(outlineRead)
        XCTAssertEqual(outline.kind, .attachmentText)
        XCTAssertEqual(outline.characters, text.count)
        XCTAssertGreaterThanOrEqual(outline.chunkCount, 5)

        let all = try await store.searchChunks(emailID: mail.id, kind: .attachmentText, ordinal: 0)
        XCTAssertEqual(all.joined(), text)
        var reference: [(chunk: Int, offset: Int)] = []
        for (i, c) in all.enumerated() { for r in SectionBoundary.phraseRanges(of: "quarterly results", in: c) { reference.append((i, r.location)) } }
        XCTAssertEqual(reference.count, 3)

        let page = try await store.attachmentDocumentChunks(emailID: mail.id, ordinal: 0, kind: .attachmentText, range: 1...2)
        XCTAssertEqual(Set(page.keys), [1, 2])
        XCTAssertEqual(page[2], all[2])

        let countsRead = try await store.attachmentDocumentMatchCounts(emailID: mail.id, ordinal: 0, kind: .attachmentText, literal: "quarterly results")
        let counts = try XCTUnwrap(countsRead)
        XCTAssertEqual(counts.count, all.count)
        for (i, n) in counts.enumerated() { XCTAssertEqual(n, reference.filter { $0.chunk == i }.count, "chunk \(i)") }

        var group = AttachmentConditionGroup()
        group.content = "quarterly results"
        let evidence = try await store.matchEvidence(emailID: mail.id, spec: SearchSpec(groups: [SearchGroup(.all, attachments: [group])]), freeText: nil)
        let anchor = try XCTUnwrap(evidence.compactMap(\.anchor).first, "\(evidence)")
        XCTAssertEqual(anchor.kind, .attachmentText)
        XCTAssertEqual(anchor.ordinal, 0)
        XCTAssertEqual(anchor.chunk, reference[0].chunk)
        XCTAssertEqual(anchor.offset, reference[0].offset)
        XCTAssertEqual(anchor.query, "quarterly results")
    }

    func testR7_childCountsScopedToAQuery() async throws {
        let store = try makeStore()
        let old = email("old", year: 2023, attachments: [AttachmentMetadata(filename: "a.zip", mimeType: "application/zip", size: 1)])
        let new = email("new", year: 2025, attachments: [AttachmentMetadata(filename: "b.zip", mimeType: "application/zip", size: 1)])
        try await store.insertBatch([old, new], batchSize: 10)
        func child(_ m: MBOXParser.RawEmail, _ i: Int, _ state: String) -> AttachmentChildRow {
            AttachmentChildRow(emailID: m.id, position: 0, childIndex: i, path: "f\(i)", filename: "f\(i).bin", kind: "bin",
                               sha256: "", bytes: 1, state: state, note: nil)
        }
        try await store.recordAttachmentChildren(emailID: old.id, position: 0, children: [child(old, 0, "locked")],
                                                 texts: [:], states: [0: .locked], extractorVersion: 10)
        try await store.recordAttachmentChildren(emailID: new.id, position: 0, children: [child(new, 0, "locked"), child(new, 1, "unsupported")],
                                                 texts: [:], states: [0: .locked, 1: .unsupported], extractorVersion: 10)
        var scope = EmailQuery()
        scope.afterDate = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01
        scope.text = "ignored free text"
        let scoped = try await store.attachmentChildStateCounts(scope: scope)
        XCTAssertEqual(scoped, ["locked": 1, "unsupported": 1])
        let wide = try await store.attachmentChildStateCounts()
        XCTAssertEqual(wide, ["locked": 2, "unsupported": 1])
    }
}
