//
//  TikaODFIWorkFixtureTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "OpenDocument/iWork": real producer fixtures.
//  Every file under Fixtures/opensource/tika-odf-iwork/ was written by
//  OpenOffice.org / NeoOffice / LibreOffice, or by Pages, Numbers and Keynote
//  ('09, 2013 and 2018), and comes from Apache Tika's test corpus (Apache-2.0;
//  MANIFEST.md has the source URLs and SHA-256). The phrases asserted here
//  are the ones Tika's own ODFParserTest / IWorkParserTest assert, so a pass
//  means mailin reads the same body text an independent parser reads.
//  Previews and metadata do not count: every assertion is on body text.
//  One test method per fixture.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class TikaODFIWorkFixtureTests: XCTestCase {

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/opensource/tika-odf-iwork", isDirectory: true)

    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    /// The facade, as the attachment job calls it.
    func read(_ name: String, password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> OfficeTextExtractor.Result {
        let kind = try XCTUnwrap(DocumentKind.detect(mimeType: "", filename: name), "kind for \(name)", file: file, line: line)
        return try DocumentTextExtractor.extract(fileURL: Self.fixture(name), kind: kind, logicalName: name, password: password)
    }

    /// Tika's `assertContains` after whitespace folding, so line structure does not decide.
    func assertContains(_ phrases: [String], _ result: OfficeTextExtractor.Result, file: StaticString = #filePath, line: UInt = #line) {
        let folded = result.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for phrase in phrases {
            let p = phrase.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            XCTAssertTrue(folded.contains(p), "missing “\(phrase)” in:\n\(result.text.prefix(3000))", file: file, line: line)
        }
    }

    // MARK: - OpenDocument (OpenOffice.org 2/3, NeoOffice, LibreOffice)

    func testREAL_ODT_openOffice3_bodyAnnotationFootnoteShapesAndEmbeddedSheet() throws {
        let r = try read("testODFwithOOo3.odt")
        assertContains(["Tika is part of the Lucene project.", "Solr", "one embedded", "Rectangle Title", "a blue background and dark border",
                        "Apache Tika", "Test Document", "This is of course a simple footnote"], r)
        XCTAssertTrue(r.text.contains("[Comment by Bart Hanssens] Tika is part of the Lucene project."), "comments labelled with their author")
        XCTAssertTrue(r.text.contains("[1: This is of course a simple footnote]"), "footnote kept with its citation, not glued to the word")
        XCTAssertTrue(r.components.contains("Embedded: Object 1"), "the embedded spreadsheet is read as its own section: \(r.components)")
        XCTAssertTrue(r.notText.contains("ObjectReplacements/Object 1"), "previews of embedded objects are listed as not text")
    }

    func testREAL_ODT_openOffice2_neoOffice() throws {
        let r = try read("testOpenOffice2.odt")
        assertContains(["This is a sample Open Office document, written in NeoOffice 2.2.1 for the Mac."], r)
    }

    func testREAL_ODF_openOffice2_formulaHasNoBodyText() throws {
        // Tika: "contents of maths files not currently supported", content "". mailin: no reader claims it.
        XCTAssertNil(DocumentKind.detect(mimeType: "", filename: "testOpenOffice2.odf"), "a formula document is not a text document kind")
        XCTAssertNil(DocumentKind.detect(mimeType: "application/vnd.oasis.opendocument.formula", filename: "x"))
    }

    func testREAL_ODT_footerOnEveryPage() throws {
        let r = try read("testFooter.odt")
        assertContains(["Here is some text...", "Here is some text on page 2", "Here is footer text"], r)
        XCTAssertTrue(r.components.contains("Footer"), r.components.description)
    }

    func testREAL_ODS_footerFromStyles() throws {
        let r = try read("testFooter.ods")
        assertContains(["Here is a footer in the center area", "Data 1", "Data 4"], r)
        XCTAssertTrue(r.components.contains("Sheet: Sheet1"), r.components.description)
        XCTAssertFalse(r.text.contains("???"), "field placeholders of sheet headers are not text")
    }

    func testREAL_ODP_masterFooter() throws {
        let r = try read("testMasterFooter.odp")
        assertContains(["Master footer is here"], r)
        XCTAssertFalse(r.text.contains("<number>"), "page-number placeholders are not text")
    }

    func testREAL_ODT_spanishGnuPGPractice() throws {
        let r = try read("testNPEOpenDocument.odt")
        assertContains(["primero hay que generar un par de claves"], r)
    }

    func testREAL_ODT_styles_listsAndSpans() throws {
        let r = try read("testStyles.odt")
        assertContains(["This is just a test", "And another test is here.", "One", "First"], r)
    }

    func testREAL_ODT_largeFrenchManual_TIKA6000() throws {
        let r = try read("testODT-TIKA-6000.odt")
        assertContains(["Utilisation de ce document", "Copyright and License", "Changer la langue",
                        "La page d’accueil permet de faire une recherche simple"], r)
    }

    func testREAL_ODT_noMetaPart() throws {
        assertContains(["Test text"], try read("testODTNoMeta.odt"))
    }

    func testREAL_ODT_paragraphLevelFontStyles() throws {
        assertContains(["name, advocaat", "Publicatie Onbekwaamverklaring"], try read("testODTStyles2.odt"))
    }

    func testREAL_ODT_annotationInsideParagraph() throws {
        let r = try read("testODTStyles3.odt")
        assertContains(["WOUTERS Rolf", "Beschermde persoon is overleden"], r)
        XCTAssertFalse(r.text.contains("Rolf2017-01-31"), "the comment's date is not glued to the body text")
    }

    func testREAL_ODT_svgTitleInStyledSpan_chinese() throws {
        assertContains(["國立雲林科技大學國際", "學生簽章"], try read("testODT_svgTitleInStyledSpan.odt"))
    }

    func testREAL_ODT_embeddedDocuments() throws {
        assertContains(["This document has bold and italic text."], try read("testODTEmbedded.odt"))
    }

    func testREAL_ODT_embeddedImageAndLink() throws {
        let r = try read("testODTEmbeddedImageLink.odt")
        assertContains(["Visit Tika"], r)
        XCTAssertTrue(r.notText.contains { $0.hasPrefix("Pictures/") }, "the picture is listed as not text: \(r.notText)")
    }

    func testREAL_ODT_macros_textReadMacrosListedNeverRun() throws {
        let r = try read("testODTMacro.odt")
        assertContains(["Hello dear user", "Click the smiley"], r)
        XCTAssertTrue(r.notText.contains { $0.hasPrefix("Basic/") && $0.contains("not run") }, r.notText.description)
    }

    func testREAL_ODS_macros_emptySheetOnlyTheDefaultFooterIsText() throws {
        // One empty cell and a macro; the only text is LibreOffice's default page footer "Page 1".
        let r = try read("testODSMacro.ods")
        XCTAssertFalse(r.components.contains { $0.hasPrefix("Sheet:") }, r.components.description)
        XCTAssertTrue(r.components.allSatisfy { $0 == "Footer" || $0 == "Header" }, r.components.description)
        assertContains(["Page 1"], r)
        XCTAssertTrue(r.notText.contains { $0.hasPrefix("Basic/") && $0.contains("not run") }, r.notText.description)
    }

    func testREAL_ODP_macros_emptySlideIsNoText() throws {
        XCTAssertThrowsError(try read("testODPMacro.odp")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .noTextParts)
        }
    }

    func testREAL_ODP_37slides_sociologyLecture() throws {
        let r = try read("testODP_NPE.odp")
        assertContains(["Medicine and Health Care", "What is social epidemiology", "Culture-bound syndrome"], r)
        XCTAssertEqual(r.components.filter { $0.hasPrefix("Slide ") }.count, 37)
    }

    func testREAL_ODT_notAZipFile_isRefusedByName() throws {
        XCTAssertThrowsError(try read("testODTnotaZipFile.odt")) { error in
            guard case .notAPackage(let why)? = error as? OfficeTextExtractor.ExtractError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("Not a ZIP"), why)
        }
    }

    func testREAL_ODT_encrypted_lockedWithoutPassword_opensWithTika() throws {
        // LibreOffice: AES-256-CBC, PBKDF2 100,000 rounds, SHA-256 start key, SHA256/1K checksum. Password "tika".
        XCTAssertThrowsError(try read("testODTEncrypted.odt")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted)
        }
        XCTAssertThrowsError(try read("testODTEncrypted.odt", password: "not-tika")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword)
        }
        let r = try read("testODTEncrypted.odt", password: "tika")
        XCTAssertTrue(r.components.contains("Document"), r.components.description)
        XCTAssertFalse(r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(r.text.contains("<") == false, "decrypted and inflated XML is read as text, not shown raw")
    }

    // MARK: - iWork '09 (Pages, Numbers, Keynote 2009 XML)

    func testREAL_Keynote09_slidesNotesCommentsAndTable() throws {
        let r = try read("testKeynote.key")
        assertContains(["A sample presentation", "For the Apache Tika project", "Slide 1", "Some random text for the sake of testability.",
                        "A nice comment", "A nice note", "Cell one", "Cell two", "Cell three", "Cell four", "Cell 5", "Cell six", "7", "Cell eight", "5/5/1985"], r)
        XCTAssertEqual(r.components.filter { $0.hasPrefix("Slide ") && !$0.contains("continued") }.count, 3, r.components.description)
        XCTAssertTrue(r.components.contains("Notes 1") || r.components.contains { $0.hasPrefix("Notes ") }, r.components.description)
        // Tika's table markup: three rows of three cells, in order.
        XCTAssertTrue(r.text.contains("Cell one\tCell two\tCell three\nCell four\tCell 5\tCell six\n7\tCell eight\t5/5/1985"), r.text)
    }

    func testREAL_Keynote09_textBoxes() throws {
        assertContains(["text1 text2 text3"], try read("testTextBoxes.key"))
    }

    func testREAL_Keynote09_bulletPoints() throws {
        assertContains(["bullet point 1 bullet point 2 bullet point 3"], try read("testBulletPoints.key"))
    }

    func testREAL_Keynote09_tables() throws {
        assertContains(["row 1 row 2 row 3"], try read("testTables.key"))
    }

    func testREAL_Keynote09_masterSlideTable() throws {
        let r = try read("testMasterSlideTable.key")
        assertContains(["master row 1", "master row 2", "master row 3"], r)
        XCTAssertTrue(r.components.contains("Master slides"), r.components.description)
    }

    func testREAL_Pages09_twoPagesWithTable() throws {
        let r = try read("testPages.pages")
        assertContains(["Sample pages document", "Some plain text to parse.", "Cell one", "Cell two", "Cell three", "Cell four", "Cell five",
                        "Cell six", "Cell seven", "Cell eight", "Cell nine", "Both Pages 1.x and Keynote 2.x", "A second page....", "Extensible Markup Language"], r)
        XCTAssertFalse(r.text.contains("Lorem ipsum"), "template placeholder (ghost) text is not the document's text")
    }

    func testREAL_Pages09_layoutModeTextBoxes() throws {
        assertContains(["text box 1 - here is some text", "created in a text box in layout mode", "text box 2 - more text!@!$@#",
                        "this is text inside of a green box", "text inside of a green circle"], try read("testPagesLayout.pages"))
    }

    func testREAL_Pages09_headersFootersFootnotes() throws {
        let r = try read("testPagesHeadersFootersFootnotes.pages")
        assertContains(["Both Pages 1.x", "understanding the Pages document", "should be page 2", "THIS IS SOME HEADER TEXT",
                        "Footnote: Do a lot of people really use iWork?!?!"], r)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\t1"), r.text)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\t2"), r.text)
        for label in ["Header", "Footer", "Footnotes"] { XCTAssertTrue(r.components.contains(label), "\(label) in \(r.components)") }
    }

    func testREAL_Pages09_footerRomanUpper() throws {
        let r = try read("testPagesHeadersFootersRomanUpper.pages")
        assertContains(["THIS IS SOME HEADER TEXT"], r)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\tI"), r.text)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\tII"), r.text)
    }

    func testREAL_Pages09_footerRomanLower() throws {
        let r = try read("testPagesHeadersFootersRomanLower.pages")
        assertContains(["THIS IS SOME HEADER TEXT"], r)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\ti"), r.text)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\tii"), r.text)
    }

    func testREAL_Pages09_headerAndFooterAlphaUpper() throws {
        let r = try read("testPagesHeadersFootersAlphaUpper.pages")
        XCTAssertTrue(r.text.contains("THIS IS SOME HEADER TEXT\tA"), r.text)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\tA"), r.text)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\tB"), r.text)
    }

    func testREAL_Pages09_footerAlphaLower() throws {
        let r = try read("testPagesHeadersFootersAlphaLower.pages")
        assertContains(["THIS IS SOME HEADER TEXT"], r)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\ta"), r.text)
        XCTAssertTrue(r.text.contains("THIS IS SOME FOOTER TEXT\tb"), r.text)
    }

    func testREAL_Pages09_comments() throws {
        let r = try read("testPagesComments.pages")
        assertContains(["Both Pages 1.x", "understanding the Pages document", "should be page 2", "comment about the APXL file", "comment about UIMA"], r)
        XCTAssertTrue(r.components.contains("Comments"), r.components.description)
    }

    func testREAL_Pages09_passwordProtected_lockedWithoutPassword_opensWithTika() throws {
        // Password "tika" (Tika does not open it: TIKA-903). Apple's own ZIP methods 25451/25452.
        XCTAssertThrowsError(try read("testPagesPwdProtected.pages")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted)
        }
        let members = try ZIPArchiveReader.members(of: Self.fixture("testPagesPwdProtected.pages"))
        XCTAssertTrue(members.allSatisfy { IWorkDocumentReader.protectedMethods.contains($0.method) }, members.map(\.method).description)
        // Audit R6: the verifier (central-directory "iwpv" field) and the key.
        let verifier = try XCTUnwrap(try IWork09Encryption.verifier(in: Self.fixture("testPagesPwdProtected.pages")))
        XCTAssertEqual(verifier.iterations, 4000)
        XCTAssertThrowsError(try read("testPagesPwdProtected.pages", password: "Tika")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword)
        }
        let r = try read("testPagesPwdProtected.pages", password: "tika")
        // The template's placeholder (ghost) lorem ipsum stays excluded, as in every '09 document.
        assertContains(["Sample pages document", "A text box with text.", "Cell seven Cell eight Cell nine",
                        "here is some embedded text in a text box", "Chart: A CRAZY COOL 3D LINE CHART WOW", "Nunc volutpat dapibus nisi."], r)
        XCTAssertTrue(r.components.contains("Document"), r.components.description)
    }

    func testREAL_Numbers09_accountChecking_valuesAndSheets() throws {
        let r = try read("testNumbers.numbers")
        assertContains(["Category", "Home", "-226", "-137.5", "Checking Account: 300545668", "4650", "Credit Card", "Groceries", "-210", "Food",
                        "Try adding your own account transactions to this table."], r)
        XCTAssertTrue(r.components.contains("Sheet: Checking"), r.components.description)
        XCTAssertTrue(r.text.contains("Table: "), "table names are read")
        XCTAssertTrue(r.text.contains("2009-"), "date cells are read as dates: \(r.text.prefix(1200))")
    }

    func testREAL_Numbers09_tableNames() throws {
        let r = try read("tableNames.numbers")
        assertContains(["This is the main table"], r)
    }

    func testREAL_Numbers09_tableHeaders() throws {
        let r = try read("tableHeaders.numbers")
        assertContains((1...5).map { "header\($0)" } + (1...3).map { "row\($0)" }, r)
    }

    func testREAL_Numbers09_chartNames() throws {
        let r = try read("testNumbersCharts.numbers")
        assertContains(["Expenditure by Category", "Currency Chart name", "Chart 2", "Region 1", "average pay"], r)
    }

    // MARK: - iWork 2013 (IWA) and 2018 (zipped bundle with Index.zip)

    func testREAL_Keynote2013_IWA_slidesAndTableText() throws {
        let r = try read("testKeynote2013.key")
        assertContains(["A sample presentation", "For the Apache Tika project", "Slide 1", "Some random text for the sake of testability.",
                        "A nice comment", "A nice note", "Cell one", "Cell two", "Cell three", "Cell four", "Cell 5", "Cell six", "Cell eight", "5/5/1985"], r)
        XCTAssertEqual(r.components.filter { $0.hasPrefix("Slide ") }.count, 3, r.components.description)
    }

    func testREAL_Keynote2018_zippedBundle_innerIndexZip() throws {
        let r = try read("testKeynote2018.key")
        XCTAssertFalse(r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(r.components.contains { $0.hasPrefix("Slide ") }, r.components.description)
        XCTAssertTrue(r.notText.contains { $0.contains("Metadata/") }, "bundle metadata is listed as not text: \(r.notText)")
    }

    func testREAL_Pages2013_IWA_body() throws {
        let r = try read("testPages2013.pages")
        assertContains(["Sample pages document", "Some plain text to parse.", "Cell one", "Cell nine", "Both Pages 1.x and Keynote 2.x",
                        "A second page....", "Extensible Markup Language"], r)
    }

    func testREAL_Numbers2013_IWA_cellStringsAndSheets() throws {
        let r = try read("testNumbers2013.numbers")
        assertContains(["Category", "Home", "Checking Account: 300545668", "Credit Card", "Groceries", "Food",
                        "Try adding your own account transactions to this table."], r)
        XCTAssertTrue(r.components.contains { $0.contains("Checking") }, r.components.description)
    }

    /// Audit R6: IWA table tiles decoded cell by cell (pre-BNC v4 storage).
    /// The values are the ones the '09 version of the same workbook shows
    /// (`testREAL_Numbers09_accountChecking_valuesAndSheets`: -226, -137.5,
    /// 4650, -210), now read from the 2013 file's tiles as numbers and dates.
    func testREAL_Numbers2013_IWA_numericCellsDatesAndFormulaResults() throws {
        let r = try read("testNumbers2013.numbers")
        XCTAssertTrue(r.components.contains("Table cells: Transactions (sheet: Checking)"), r.components.description)
        XCTAssertTrue(r.components.contains("Table cells: Account Categories (sheet: Checking)"), r.components.description)
        XCTAssertTrue(r.components.contains("Table cells: Table 1 (sheet: Second sheet)"), r.components.description)
        // Row by row, tab-separated, numbers as stored, dates ISO, formula results (Balance, Total) as values.
        XCTAssertTrue(r.text.contains("Type\tDate\tDescription\tCategory\tAmount\tBalance"), r.text)
        XCTAssertTrue(r.text.contains("101\t2009-10-01\tRent\t2\t-775\t3875"), r.text)
        XCTAssertTrue(r.text.contains("Debit Card\t2009-11-02\tNight on the town\t6\t-210\t4279.1"), r.text)
        XCTAssertTrue(r.text.contains("Beginning Balance\t4650"), r.text)
        XCTAssertTrue(r.text.contains("Food\t-226"), r.text)
        XCTAssertTrue(r.text.contains("Gas\t-137.5"), r.text)
        XCTAssertTrue(r.text.contains("Total\t-2575.9"), r.text)
        XCTAssertTrue(r.text.contains("0.5\t0.1"), "the second sheet's numbers: \(r.text)")
        XCTAssertFalse(r.components.contains { $0 == "Table cells" || $0.hasPrefix("Table cells (sheets:") },
                       "every list string was placed in a cell, none left in the unplaced section: \(r.components)")
    }

    func testREAL_Keynote2013_Pages2013_IWA_tablesRowByRow() throws {
        let k = try read("testKeynote2013.key")
        XCTAssertTrue(k.text.contains("Cell one\tCell two\tCell three\nCell four\tCell 5\tCell six\n7\tCell eight\t5/5/1985"), k.text)
        let p = try read("testPages2013.pages")
        XCTAssertTrue(p.text.contains("Column one\tColumn two\tColumn three\nCell one\tCell two\tCell three"), p.text)
        XCTAssertTrue(p.text.contains("Cell seven\tCell eight\tCell nine"), p.text)
    }
}
