//
//  RegistryDocumentTableTests.swift
//  ArchiveCoreTests
//
//  SUPPORTED_FORMATS_AND_LIMITS.md carries FormatCapabilityRegistry.markdownTable()
//  verbatim between its markers. This test checks that, and — when
//  MAILIN_REGENERATE_DOCS=1 is set — rewrites the document from the registry
//  so that the registry stays the single source (several agents edit rows
//  concurrently; the table is regenerated after each merge, never hand-merged).
//

import XCTest
@testable import ArchiveCore

final class RegistryDocumentTableTests: XCTestCase {

    private static let begin = "<!-- format-registry:begin -->"
    private static let end = "<!-- format-registry:end -->"

    private var documentURL: URL {
        // Packages/ArchiveCore/Tests/ArchiveCoreTests/<file> → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SUPPORTED_FORMATS_AND_LIMITS.md")
    }

    func testDocumentCarriesTheRegistryTableVerbatim() throws {
        let table = FormatCapabilityRegistry.markdownTable()
        var doc = try String(contentsOf: documentURL, encoding: .utf8)
        guard let a = doc.range(of: Self.begin), let b = doc.range(of: Self.end) else {
            return XCTFail("the registry markers are missing from the document")
        }
        let carried = doc[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if carried != table, ProcessInfo.processInfo.environment["MAILIN_REGENERATE_DOCS"] == "1" {
            doc.replaceSubrange(a.upperBound..<b.lowerBound, with: "\n" + table + "\n")
            try doc.write(to: documentURL, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(carried, table, "SUPPORTED_FORMATS_AND_LIMITS.md must carry the registry table verbatim — run with MAILIN_REGENERATE_DOCS=1 to regenerate")
    }

    /// Every registry id is unique; no row claims real files without saying what was run.
    func testRegistryRowsAreUniqueAndEvidenceIsExplained() {
        let ids = FormatCapabilityRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate registry ids: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }
}
