//
//  R5bCeilingTests.swift
//  ArchiveCoreTests
//
//  R5b (audit bf1a5b9; owner 2026-11-08: "there should be no limit at all"):
//  ceilings in the five-jobs paths that dropped work without a word are gone.
//  Each test fails on the previous code.
//

import XCTest
@testable import ArchiveCore

final class R5bCeilingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("r5b-ceilings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private static func item(_ name: String, _ value: Data, type: UInt16 = 0x0500) -> Data {
        var d = Data()
        let n = Data(name.utf8)
        withUnsafeBytes(of: type.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(n.count).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(value.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(n); d.append(value)
        return d
    }

    /// A Notes document with 250 fields before its subject and an 11 MB body:
    /// the reader used to stop at 200 fields (losing the subject and body) and
    /// refused any field above 10 MB (losing it and everything after it).
    func testR5b_notesDocumentWithManyFieldsAndALargeBody_isReadWhole() throws {
        var file = Data([0x1A, 0x00])
        file.append(Data(repeating: 0, count: 254))
        withUnsafeBytes(of: UInt32(256).littleEndian) { file.replaceSubrange(0x28..<0x2C, with: $0) }
        for i in 0..<250 { file.append(Self.item("XField\(i)", Data("value \(i)".utf8))) }
        file.append(Self.item("Subject", Data("After many fields".utf8)))
        file.append(Self.item("From", Data("CN=Sender/O=Acme".utf8)))
        file.append(Self.item("$MessageID", Data("<r5b-nsf@acme.example>".utf8)))
        let body = String(repeating: "large body words ", count: 11 * 1_048_576 / 17) + "finalnsfword"
        file.append(Self.item("Body", Data(body.utf8)))
        file.append(Self.item("Form", Data("Memo".utf8)))
        file.append(Data(repeating: 0, count: 128))
        let url = dir.appendingPathComponent("many.nsf")
        try file.write(to: url)

        let rows = try NSFParser.parse(fileURL: url, senderEmail: "")
        let row = try XCTUnwrap(rows.first { $0.headers["Subject"] == "After many fields" }, "the subject after field 200 is read")
        XCTAssertTrue(row.plainBody.hasSuffix("finalnsfword"), "the 11 MB body is read whole")
    }

    /// A pattern match beyond the first 50,000 characters of a body is a match:
    /// verification used to read only that prefix and reject it.
    func testR5b_patternSearchVerifiesTheWholeBody() throws {
        let filler = String(repeating: "ordinary filler text ", count: 4_000)   // 84,000 characters
        let email = try MBOXParser.processRawMessage("""
            From: a@example.com
            Subject: long
            Content-Type: text/plain

            \(filler) invoice-77231 at the very end

            """, senderEmail: "")
        let regex = try NSRegularExpression(pattern: "invoice-[0-9]{5}", options: [.caseInsensitive])
        XCTAssertTrue(BoundedRegexSearch.matches(regex, email))
    }
}
