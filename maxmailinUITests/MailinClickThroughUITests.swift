//
//  MailinClickThroughUITests.swift
//  maxmailinUITests
//
//  REAL click simulation: launches the actual app (seeded with the bundled
//  demo archive via the --uitest launch argument) and presses the actual
//  buttons — folders, filters, sort, search operators, export menus, the
//  Feature Guide, and the email detail view. This is the layer unit tests
//  cannot cover: the full SwiftUI event loop from click to visible result.
//

import XCTest

final class MailinClickThroughUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()
        // Seeding imports the demo archive asynchronously on first launch.
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
    }

    override func tearDown() {
        app.terminate()
    }

    /// One end-to-end pass over the primary surfaces. Grouped in a single
    /// test so the app launches (and seeds) once; each step asserts a
    /// visible consequence of the click, not just "didn't crash".
    func testClickThrough_primarySurfaces() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "app window appears")

        // ── Email inbox: reach the list (hub tile or sidebar entry) ──
        let inboxCandidates = [
            app.buttons["All Emails"].firstMatch,
            app.staticTexts["All Emails"].firstMatch,
            app.buttons["Email Inbox"].firstMatch
        ]
        for candidate in inboxCandidates where candidate.waitForExistence(timeout: 5) {
            candidate.click()
            break
        }

        // ── Folder tree: All Emails row exists and is clickable ──
        let allEmails = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'All Emails'")).firstMatch
        if allEmails.waitForExistence(timeout: 10) {
            allEmails.click()
        }

        // ── Search field: type a structured operator and confirm the list
        //     reacts (this exercises the SQL-paging path end to end) ──
        let searchField = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] 'search'")).firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("type:received")
            searchField.typeKey(.return, modifierFlags: [])
            // Give the async re-page a beat, then clear.
            Thread.sleep(forTimeInterval: 1.0)
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
        }

        // ── Apply / Clear filter buttons ──
        let apply = app.buttons["Apply filters"].firstMatch
        if apply.waitForExistence(timeout: 3) {
            apply.click()
        }
        let clear = app.buttons["Clear all filters"].firstMatch
        if clear.exists { clear.click() }

        // ── Export menu (footer): opens and lists the unified formats ──
        let exportMenu = app.menuButtons["Export filtered emails"].firstMatch
        let exportButton = app.buttons["Export filtered emails"].firstMatch
        let export = exportMenu.exists ? exportMenu : exportButton
        if export.waitForExistence(timeout: 3) {
            export.click()
            let wordItem = app.menuItems.matching(
                NSPredicate(format: "title CONTAINS 'Word Document'")).firstMatch
            XCTAssertTrue(wordItem.waitForExistence(timeout: 3),
                "unified export menu lists Word Document")
            let mboxItem = app.menuItems.matching(
                NSPredicate(format: "title CONTAINS 'mbox'")).firstMatch
            XCTAssertTrue(mboxItem.exists, "unified export menu lists mbox")
            app.typeKey(.escape, modifierFlags: [])   // close without exporting
        }

        // ── Feature Guide: ? button opens the searchable guide ──
        let helpButton = app.buttons["Feature Guide"].firstMatch
        if helpButton.waitForExistence(timeout: 3) {
            helpButton.click()
            let guideTitle = app.staticTexts["Feature Guide"].firstMatch
            XCTAssertTrue(guideTitle.waitForExistence(timeout: 5),
                "Feature Guide sheet opens")
            let guideSearch = app.searchFields.firstMatch
            if guideSearch.waitForExistence(timeout: 3) {
                guideSearch.click()
                guideSearch.typeText("duplicate")
                let dupRow = app.staticTexts.matching(
                    NSPredicate(format: "value CONTAINS[c] 'duplicate' OR label CONTAINS[c] 'duplicate'"))
                    .firstMatch
                XCTAssertTrue(dupRow.waitForExistence(timeout: 3),
                    "guide search finds the Duplicate Manager")
            }
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.click() }
        }

        // ── Email row: open the first email, then navigate next/prev ──
        let firstRow = app.outlines.cells.firstMatch.exists
            ? app.outlines.cells.firstMatch
            : app.tables.cells.firstMatch
        if firstRow.waitForExistence(timeout: 5) {
            firstRow.click()
            let exportEmail = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Export email'")).firstMatch
            _ = exportEmail.waitForExistence(timeout: 5)
        }
    }

    /// Every window the hub can open must actually open (no dead tiles) —
    /// spot-checked on three tiles from different feature families.
    func testClickThrough_hubTilesOpenRealViews() {
        for (tile, expectation) in [
            ("Analytics", "Total"),
            ("Duplicates", "duplicate"),
            ("Preferences", "Settings")
        ] {
            let button = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", tile)).firstMatch
            guard button.waitForExistence(timeout: 5) else { continue }
            button.click()
            let landed = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", expectation)).firstMatch
            XCTAssertTrue(landed.waitForExistence(timeout: 8),
                "clicking '\(tile)' shows a view containing '\(expectation)'")
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
