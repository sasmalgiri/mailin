//
//  IWorkPasswordFixtureTests.swift
//  ArchiveCoreTests
//
//  Password-protected iWork 2013+ documents (IWA), written by Pages, Numbers
//  and Keynote 14.4 through AppleScript `set password` (synthetic content,
//  Fixtures/derived/iwork-password/MANIFEST.md). Each protected file has an
//  unprotected twin with the same content: with the password the reader must
//  give the twin's text; with a wrong one it names the wrong password; with
//  none the document stays locked.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class IWorkPasswordFixtureTests: XCTestCase {

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/derived/iwork-password", isDirectory: true)
    static let password = "Lighthouse-4650"

    func read(_ name: String, password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> OfficeTextExtractor.Result {
        let kind = try XCTUnwrap(DocumentKind.detect(mimeType: "", filename: name), "kind for \(name)", file: file, line: line)
        return try DocumentTextExtractor.extract(fileURL: Self.fixtures.appendingPathComponent(name), kind: kind, logicalName: name, password: password)
    }

    /// Locked without a password, "wrong password" with a wrong one, and with
    /// the right one the same text, sections and table cells as the twin.
    func assertOpensLikeTwin(_ protected: String, twin: String, phrases: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try read(protected), file: file, line: line) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted, "no password: locked", file: file, line: line)
        }
        XCTAssertThrowsError(try read(protected, password: "lighthouse-4650"), file: file, line: line) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword, "wrong password named", file: file, line: line)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "the password did not open the file", file: file, line: line)
        }
        let opened = try read(protected, password: Self.password)
        let plain = try read(twin)
        XCTAssertEqual(opened.text, plain.text, "same text as the unprotected twin", file: file, line: line)
        XCTAssertEqual(opened.components, plain.components, file: file, line: line)
        XCTAssertTrue(opened.skipped.isEmpty, "nothing skipped: \(opened.skipped)", file: file, line: line)
        for phrase in phrases {
            XCTAssertTrue(opened.text.contains(phrase), "missing “\(phrase)” in:\n\(opened.text)", file: file, line: line)
        }
        XCTAssertFalse(opened.notText.contains { $0.hasSuffix(IWork13Encryption.verifierName) }, "the verifier is not listed as content", file: file, line: line)
    }

    func testREAL_Pages14_protectedSingleFile_opensWithPassword() throws {
        try assertOpensLikeTwin("pages-protected.pages", twin: "pages-plain.pages",
                                phrases: ["The quorum clause lighthouse stands at the harbour."])
    }

    func testREAL_Pages14_protectedZippedBundle_opensWithPassword() throws {
        // The package form (bundle with Index.zip), zipped as Mail attaches it.
        try assertOpensLikeTwin("pages-bundle-protected.pages", twin: "pages-bundle-plain.pages",
                                phrases: ["The quorum clause lighthouse stands at the harbour."])
    }

    func testREAL_Numbers14_protected_tableCellsWithPassword() throws {
        try assertOpensLikeTwin("numbers-protected.numbers", twin: "numbers-plain.numbers",
                                phrases: ["Harbour ledger\tAmount\tDate", "quorum clause lighthouse\t4650\t2026-03-14"])
    }

    func testREAL_Keynote14_protected_titleAndNotesWithPassword() throws {
        try assertOpensLikeTwin("keynote-protected.key", twin: "keynote-plain.key",
                                phrases: ["Quorum clause lighthouse", "Speaker note: the harbour count is 4650."])
    }

    /// The verifier rejects a wrong password before any member is decrypted,
    /// and the right one gives the key the members open with.
    func testVerifier_parsesVersion2AndChecksThePassword() throws {
        let archive = Self.fixtures.appendingPathComponent("pages-protected.pages")
        let members = try ZIPArchiveReader.members(of: archive)
        let member = try XCTUnwrap(members.first { IWork13Encryption.isVerifier($0.name) })
        let scratch = try DocumentTextExtractor.scratchDirectory("iwpv2-test")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let verifier = try IWork13Encryption.parse([UInt8](try DocumentTextExtractor.memberData(member, from: archive, scratch: scratch)))
        XCTAssertEqual(verifier.iterations, 100_000)
        XCTAssertThrowsError(try IWork13Encryption.key(password: "", verifier: verifier)) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword)
        }
        XCTAssertEqual(try IWork13Encryption.key(password: Self.password, verifier: verifier).count, 16)
        XCTAssertThrowsError(try IWork13Encryption.parse([UInt8](repeating: 0, count: 50)))
    }
}
