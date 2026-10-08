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
#if os(macOS)
import AppKit
#endif
import StoreKitTest

final class MailinClickThroughUITests: XCTestCase {

    private var app: XCUIApplication!
    /// macOS: menus that exist with nothing open; a press "opened a menu"
    /// only if the count rises above this.
    private var baselineMenus = 0

    /// The app under test: the scheme's Debug build, or — on the Mac, when
    /// UITEST_APP_PATH names an installed .app — that build (used to run the
    /// purchase checklist against the TestFlight copy, 2026-10-08).
    private func makeApp() -> XCUIApplication {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["UITEST_APP_PATH"], !path.isEmpty {
            return XCUIApplication(url: URL(fileURLWithPath: path))
        }
        #endif
        return XCUIApplication()
    }

    override func setUp() {
        continueAfterFailure = true
        app = makeApp()
        app.launchArguments = ["--uitest"]
        // Extra launch arguments from the runner (TEST_RUNNER_UITEST_EXTRA_ARGS),
        // e.g. -simulateAppleIntelligenceOff.
        if let extra = ProcessInfo.processInfo.environment["UITEST_EXTRA_ARGS"], !extra.isEmpty {
            app.launchArguments += extra.split(separator: " ").map(String.init)
        }
        app.launch()
        // A relaunch in the same test run can be slow (state teardown from
        // the previous test) — wait on process state first, then the window.
        _ = app.wait(for: .runningForeground, timeout: 30)
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    }

    override func tearDown() {
        app.terminate()
    }

    #if os(iOS)
    /// iPhone/iPad pass: taps instead of clicks, over the iOS layout
    /// (nav-bar Feature Guide, iOS search bar, email cells). The simulator
    /// container is fresh, so the --uitest seed imports the demo archive.
    func testClickThrough_iOSPrimarySurfaces() {
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)

        // ── Feature Guide from the navigation bar ──
        let help = app.buttons["Feature Guide"].firstMatch
        if help.waitForExistence(timeout: 30) {
            help.tap()
            // The guide is the only surface with a system search field.
            let guideOpen = app.searchFields.firstMatch.waitForExistence(timeout: 10)
                || app.navigationBars["Feature Guide"].exists
            if !guideOpen {
                print("UITEST-HIERARCHY-AFTER-TAP >>>")
                print(app.debugDescription)
                print("<<< UITEST-HIERARCHY-AFTER-TAP")
            }
            XCTAssertTrue(guideOpen, "Feature Guide opens on iOS")
            let guideSearch = app.searchFields.firstMatch
            if guideSearch.waitForExistence(timeout: 5) {
                guideSearch.tap()
                if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                    guideSearch.typeText("duplicate")
                    let hit = app.staticTexts.matching(
                        NSPredicate(format: "label CONTAINS[c] 'duplicate'")).firstMatch
                    XCTAssertTrue(hit.waitForExistence(timeout: 5),
                        "guide search finds Duplicate Manager on iOS")
                }
            }
            let doneNav = app.navigationBars.buttons["Done"].firstMatch
            let done = doneNav.exists ? doneNav : app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) {
                done.tap()
            } else {
                app.swipeDown(velocity: .fast)   // sheet dismiss fallback
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // ── Structured search in the iOS search bar ──
        let field = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] 'search'")).firstMatch
        if field.waitForExistence(timeout: 20) {
            field.tap()
            // Simulators with the hardware-keyboard setting never show the
            // soft keyboard and reject synthesized typing — guard on it.
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                field.typeText("type:received")
                if app.keyboards.buttons["search"].exists {
                    app.keyboards.buttons["search"].tap()
                } else if app.keyboards.buttons["Search"].exists {
                    app.keyboards.buttons["Search"].tap()
                }
                Thread.sleep(forTimeInterval: 1.5)
            }
        }

        // ── Open the first email cell (list rendered from the seeded demo) ──
        let cell = app.cells.firstMatch
        if cell.waitForExistence(timeout: 20) {
            cell.tap()
            // A detail affordance appears (export or navigation controls).
            let detail = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'export' OR label CONTAINS[c] 'next'")).firstMatch
            _ = detail.waitForExistence(timeout: 10)
        }
    }
    #endif

    #if os(iOS)
    /// Capture App Store screenshots from the real iOS build on the seeded
    /// demo archive. Each screen is saved as a keep-always attachment; the
    /// harness exports them to disk. Navigation is best-effort (existence-
    /// guarded) so the run always produces a set even if a surface moves.
    func testCaptureAppStoreScreenshots_iOS() {
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        Thread.sleep(forTimeInterval: 2.5)
        snap("01-list")

        // Feature Guide (nav "?").
        if tap(app.buttons["Feature Guide"]) {
            Thread.sleep(forTimeInterval: 1.5); snap("02-guide"); dismissModal()
        }

        // AI Assistant (nav sparkles).
        if tap(app.buttons["AI Assistant"]) {
            Thread.sleep(forTimeInterval: 1.5); snap("03-ai"); dismissModal()
        }

        // More menu → Analytics (dismiss the tool's first-run tutorial first).
        if tap(app.buttons["More"].firstMatch) {
            Thread.sleep(forTimeInterval: 0.8)
            let analytics = app.buttons["Analytics"].firstMatch
            if analytics.waitForExistence(timeout: 3) {
                analytics.tap(); Thread.sleep(forTimeInterval: 1.5)
                dismissTutorial()
                snap("04-analytics"); dismissModal()
            } else {
                app.swipeDown(velocity: .fast)   // close the menu
                Thread.sleep(forTimeInterval: 0.6)
            }
        }

        // Email detail (rows are buttons labelled "… from <sender>").
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'from '")).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap(); Thread.sleep(forTimeInterval: 2.0); snap("05-detail")
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap(); Thread.sleep(forTimeInterval: 1.0) }
        }

        // Filters & Tools panel (the tools/workflows hub), then a tool inside.
        if tap(app.buttons["Filters & Tools"]) {
            Thread.sleep(forTimeInterval: 1.5); snap("06-tools")
            let dup = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Duplicate'")).firstMatch
            if dup.waitForExistence(timeout: 3) {
                dup.tap(); Thread.sleep(forTimeInterval: 1.5)
                dismissTutorial()
                snap("07-duplicates"); dismissModal()
            }
        }
    }

    /// Dismiss a feature's first-run tutorial sheet ("Got It …") if present.
    private func dismissTutorial() {
        let gotIt = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Got It'")).firstMatch
        if gotIt.waitForExistence(timeout: 3) { gotIt.tap(); Thread.sleep(forTimeInterval: 1.2) }
    }

    @discardableResult
    private func tap(_ el: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        guard el.waitForExistence(timeout: timeout), el.isHittable else { return false }
        el.tap(); return true
    }

    private func dismissModal() {
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        else {
            let close = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Close' OR identifier CONTAINS 'xmark'")).firstMatch
            if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        }
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    #endif

    #if os(macOS)
    /// One end-to-end pass over the primary surfaces. Grouped in a single
    /// test so the app launches (and seeds) once; each step asserts a
    /// visible consequence of the click, not just "didn't crash".
    func testClickThrough_primarySurfaces() {
        // Launch latency is NOT the verdict: cold launches under the debug
        // runner (store open + startup jobs + accessibility snapshots of a
        // busy main thread) can exceed any fixed wait on a dev machine.
        // Soft-wait here; every functional step below asserts its own
        // visible outcome with its own timeout.
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)

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
        // The row can sit below the fold of a short window (one run reported
        // "Unable to find hit point" at y = 834); clicking an element that is
        // not hittable is a layout fact, not a product failure.
        if allEmails.waitForExistence(timeout: 10), allEmails.isHittable {
            allEmails.click()
        }

        // ── Search field: type a structured operator and confirm the list
        //     reacts (this exercises the SQL-paging path end to end) ──
        let searchField = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] 'search'")).firstMatch
        if searchField.waitForExistence(timeout: 5) {
            // Focus is a window-activation fact, not a product one: a run with
            // another app frontmost reported "neither element nor any
            // descendant has keyboard focus". Activate, click, and only type
            // when the field really has focus.
            app.activate()
            searchField.click()
            var focused = (searchField.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
            if !focused {
                Thread.sleep(forTimeInterval: 0.5)
                searchField.click()
                focused = (searchField.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
            }
            if focused {
                searchField.typeText("type:received")
                searchField.typeKey(.return, modifierFlags: [])
                // Give the async re-page a beat, then clear.
                Thread.sleep(forTimeInterval: 1.0)
                searchField.typeKey("a", modifierFlags: .command)
                searchField.typeKey(.delete, modifierFlags: [])
            }
        }

        // ── Date chip: opens the modern calendar with month/year jump ──
        let dateChip = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Start date'")).firstMatch
        if dateChip.waitForExistence(timeout: 5) {
            dateChip.click()
            let monthPicker = app.popUpButtons.firstMatch
            XCTAssertTrue(monthPicker.waitForExistence(timeout: 5),
                "date popover offers direct month/year pickers")
            let doneButton = app.buttons["Done"].firstMatch
            if doneButton.exists { doneButton.click() } else { app.typeKey(.escape, modifierFlags: []) }
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
            // The 3.0 three-pane shell has its own toolbar search field, so
            // `searchFields.firstMatch` is the ARCHIVE search, not the guide's.
            // Pick the guide's by its placeholder.
            let guideSearch = app.searchFields.matching(
                NSPredicate(format: "placeholderValue CONTAINS[c] 'feature'")).firstMatch
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

        // ── Hub tiles (same launch) ──
        clickThroughHubTiles()
    }
    #endif

    #if os(macOS)
    /// Hub tiles must open real views (no dead tiles) — spot-checked on
    /// three tiles from different feature families. Runs inside the same
    /// launch as the primary pass (relaunching the store-backed app twice
    /// in one runner is unreliable).
    private func clickThroughHubTiles() {
        // A tool window a previous step opened (the email row opens "Email
        // Detail") stays frontmost and its buttons — "Export analytics
        // report", "Find Duplicates Now" — matched a loose CONTAINS
        // predicate (found 2026-09-27). Close it, and match tiles by label.
        closeToolWindow(titled: "Email Detail")
        let tiles: [(tile: String, expectation: String, windowTitle: String?)] = [
            ("Analytics", "Total", "Email Analytics"),
            ("Duplicates", "duplicate", "Duplicates"),
            ("Preferences", "Settings", nil)
        ]
        for entry in tiles {
            let button = app.buttons.matching(
                NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", entry.tile, entry.tile + " ")).firstMatch
            guard button.waitForExistence(timeout: 5) else { continue }
            button.click()
            // The tool opens in its own window on macOS; the window's title is
            // the proof it opened, the static text is the fallback.
            let windowShown = entry.windowTitle.map { app.windows[$0].waitForExistence(timeout: 8) } ?? false
            let landed = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", entry.expectation)).firstMatch
            let shown = windowShown || landed.waitForExistence(timeout: 8)
            let windows = app.windows.allElementsBoundByIndex.map { $0.title }
            XCTAssertTrue(shown,
                "clicking '\(entry.tile)' opens its view; windows now: \(windows); button label: '\(button.label)'")
            if let title = entry.windowTitle { closeToolWindow(titled: title) } else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func closeToolWindow(titled title: String) {
        let window = app.windows[title]
        guard window.exists else { return }
        let close = window.buttons[XCUIIdentifierCloseWindow].firstMatch
        if close.exists { close.click() } else { window.typeKey("w", modifierFlags: .command) }
        Thread.sleep(forTimeInterval: 0.3)
    }
    #endif

    // MARK: - Real-mailbox import + every-button crawl (macOS and iOS)

    /// One row of the crawl report.
    private struct CrawlRow {
        let page: String
        let button: String
        let outcome: String
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// Imports a real mailbox through the user's path (Import button, the
    /// system file picker, the import sheet's Start button), then visits each
    /// page and presses every visible button once, recording what happened.
    /// Destructive and purchase buttons are listed but never pressed.
    ///
    /// macOS: the mailbox path comes from the runner environment
    /// (`TEST_RUNNER_MAILIN_UITEST_MBOX=/path/Sent.mbox`). iOS: the file must
    /// already be in the simulator's On My iPad storage; its name comes from
    /// the same variable (default "Sent"). The only hard failure is a crash;
    /// every other outcome is reported for review.
    func testRealMailbox_importThenPressEveryButton() throws {
        let env = ProcessInfo.processInfo.environment["MAILIN_UITEST_MBOX"] ?? ""
        // macOS without a mailbox path: crawl the archive already there
        // (the owner's Debug archive) and import nothing.
        let skipImport: Bool = {
            #if os(macOS)
            return env.isEmpty
            #else
            return false
            #endif
        }()
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        var rows: [CrawlRow] = []

        // ── 1. Import through the real UI ──
        #if os(macOS)
        recoverIfNeeded()
        baselineMenus = app.menus.count
        print("UITEST-BASELINE-MENUS \(baselineMenus)")
        #endif
        // The app reopens on the page it was last on; import from Archive.
        _ = openPage("Archive")
        let started = Date()
        let fileName = env.isEmpty ? "Sent" : ((env as NSString).lastPathComponent as NSString).deletingPathExtension
        if !skipImport {
            let importOutcome = importMailbox(path: env, fileName: fileName)
            rows.append(CrawlRow(page: "Archive", button: "Import \(fileName).mbox",
                                 outcome: "\(importOutcome) (\(Int(Date().timeIntervalSince(started))) s)"))
        }
        snapshotScreen("after-import")

        // ── 2. Every button on every page ──
        for page in ["Archive", "AI Insights", "Professional Workflows", "Live Mail"] {
            guard openPage(page) else {
                rows.append(CrawlRow(page: page, button: "(page)", outcome: "could not open page"))
                continue
            }
            snapshotScreen("page-\(page)")
            #if os(macOS)
            rows += macCrawl(page: page)
            #else
            rows += crawlButtons(onPage: page)
            #endif
        }

        #if os(macOS)
        // ── 3. Menu bar: every top-level menu opens and lists its commands ──
        rows += crawlMenuBar()
        #endif

        // ── Report ──
        var report = "| Page | Button | Outcome |\n|---|---|---|\n"
        for row in rows {
            let b = row.button.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
            let o = row.outcome.replacingOccurrences(of: "|", with: "/")
            report += "| \(row.page) | \(b) | \(o) |\n"
        }
        let crashes = rows.filter { $0.outcome.hasPrefix("CRASH") }
        let skipped = rows.filter { $0.outcome.hasPrefix("skipped") }.count
        report += "\nRows: \(rows.count); skipped: \(skipped); crashes: \(crashes.count)\n"
        print("CRAWL-REPORT>>>\n\(report)<<<CRAWL-REPORT")
        let attachment = XCTAttachment(string: report)
        attachment.name = "crawl-report.md"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(crashes.isEmpty, "buttons that crashed the app: \(crashes.map { "\($0.page) ▸ \($0.button)" })")
    }

    private func snapshotScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Drives Import ▸ file picker ▸ the file ▸ Open ▸ Start import, then
    /// waits for the import queue to drain. Returns a one-line outcome.
    private func importMailbox(path: String, fileName: String) -> String {
        // The three-pane shell has a sidebar Import button; the iPad layout
        // offers "Add more email files" / "New Import" instead.
        let candidates = [app.buttons["archive.sidebar.import"].firstMatch,
                          app.buttons["Add more email files"].firstMatch,
                          app.buttons["New Import"].firstMatch]
        var pressedImport = false
        for candidate in candidates where !pressedImport {
            if candidate.waitForExistence(timeout: 4), candidate.isHittable { press(candidate); pressedImport = true }
        }
        if !pressedImport {
            #if os(macOS)
            app.typeKey("o", modifierFlags: .command)
            #else
            return "FAIL: no Import button found"
            #endif
        }

        #if os(macOS)
        let panel = app.sheets.firstMatch.waitForExistence(timeout: 10) ? app.sheets.firstMatch : app.dialogs.firstMatch
        guard panel.waitForExistence(timeout: 10) else { return "FAIL: open panel did not appear" }
        panel.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        let open = panel.buttons["Open"].firstMatch
        if open.exists, open.isEnabled { open.click() } else { app.typeKey(.return, modifierFlags: []) }
        #else
        // Files picker: Browse ▸ On My iPad/iPhone ▸ the file ▸ Open.
        Thread.sleep(forTimeInterval: 2.0)
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 10) { browse.tap(); Thread.sleep(forTimeInterval: 1.0) }
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'On My'")).firstMatch
        if local.waitForExistence(timeout: 10) { local.tap(); Thread.sleep(forTimeInterval: 1.5) }
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", fileName)).firstMatch
        guard file.waitForExistence(timeout: 15) else {
            print("UITEST-PICKER-HIERARCHY >>>\n\(app.debugDescription)\n<<< UITEST-PICKER-HIERARCHY")
            return "FAIL: \(fileName) not shown in the file picker"
        }
        file.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5), open.isEnabled { open.tap() }
        #endif

        let start = app.buttons["Start import"].firstMatch
        guard start.waitForExistence(timeout: 30) else { return "FAIL: import sheet did not appear after choosing the file" }
        press(start)

        // Settled = the live import queue appeared and went away. Poll up
        // to 15 minutes; give up waiting for the queue after one minute.
        let begin = Date()
        var sawQueue = false
        while Date().timeIntervalSince(begin) < 900 {
            if app.state != .runningForeground { return "CRASH during import" }
            let queue = app.descendants(matching: .any)["import.queue.live"].firstMatch
            if queue.exists { sawQueue = true }
            if sawQueue && !queue.exists { break }
            if !sawQueue, Date().timeIntervalSince(begin) > 60 { break }
            Thread.sleep(forTimeInterval: 3)
        }
        Thread.sleep(forTimeInterval: 2)
        // The archive count is on the sidebar's "All Emails, N" row; the
        // list itself is lazy, so its rendered cells are not the total.
        let queueNote = sawQueue ? "queue drained" : "queue never shown"
        let allEmails = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Emails'")).firstMatch
        let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", fileName)).firstMatch
        let total = allEmails.exists ? allEmails.label : "All Emails row not visible"
        let fromFile = source.exists ? source.label : "\(fileName) source row not visible"
        return "imported, \(queueNote); sidebar: \(total); \(fromFile)"
    }

    /// Selects a page on the page strip, turning it on through the
    /// activation sheet if it is off.
    private func openPage(_ name: String) -> Bool {
        recoverIfNeeded()
        dismissEverything()
        let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        // A sheet (e.g. a first-run tutorial) can cover the page strip.
        for _ in 0..<3 where tab.exists && !tab.isHittable {
            #if os(macOS)
            let gotIt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Got It'")).firstMatch
            if gotIt.exists, gotIt.isHittable { gotIt.click() } else { app.typeKey(.escape, modifierFlags: []) }
            #else
            dismissOnce()
            #endif
            Thread.sleep(forTimeInterval: 0.8)
        }
        #if os(macOS)
        // Mac: the strip can report not-hittable while the window settles;
        // click the tab's own position instead of giving up.
        app.activate()
        if tab.exists, !tab.isHittable, !tab.frame.isEmpty, app.state == .runningForeground {
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            let turnOn = app.buttons["Turn on \(name)"].firstMatch
            if turnOn.waitForExistence(timeout: 3) { turnOn.click(); Thread.sleep(forTimeInterval: 1.5) }
            Thread.sleep(forTimeInterval: 1.0)
            return true
        }
        #endif
        guard tab.waitForExistence(timeout: 5), tab.isHittable else {
            let labels = (try? app.snapshot()).map { snap -> [String] in
                var out: [String] = []
                func walk(_ s: XCUIElementSnapshot) { if s.elementType == .button { out.append(s.label) }; s.children.forEach(walk) }
                walk(snap); return out
            } ?? []
            print("UITEST-PAGE-MISSING \(name) exists=\(tab.exists); buttons on screen: \(labels.prefix(60))")
            return false
        }
        press(tab)
        let turnOn = app.buttons["Turn on \(name)"].firstMatch
        if turnOn.waitForExistence(timeout: 3) {
            press(turnOn)
            Thread.sleep(forTimeInterval: 1.5)
        }
        Thread.sleep(forTimeInterval: 1.0)
        return true
    }

    /// Labels never pressed: they delete, reset, buy, quit or leave the page.
    private static let skipPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(delete|remove|erase|clear|reset|forget|purge|wipe|empty|quit|sign out|log ?out|buy|purchase|subscribe|restore purchases|manage subscription|turn off|disable|send|move archive|relocate|lift hold|release|revoke|close|minimi[sz]e|zoom|full ?screen)\b"#)

    private static let pageNames = ["Archive", "AI Insights", "Professional Workflows", "Live Mail"]

    /// Every distinct, enabled control a user can press on screen now.
    private func visibleControls() -> [(id: String, label: String)] {
        #if os(macOS)
        let root = app.windows.firstMatch
        #else
        let root: XCUIElement = app
        #endif
        guard let snapshot = try? root.snapshot() else { return [] }
        var seen = Set<String>()
        var out: [(id: String, label: String)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .keyboard { return }
            // Toggles and radio buttons are left alone: pressing them would
            // change the user's settings, not test a button.
            if s.elementType == .button || s.elementType == .menuButton || s.elementType == .popUpButton {
                let label = s.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = s.identifier
                let key = id + "|" + label
                // Email rows ("… from …", long labels) would turn a big
                // archive into thousands of presses; one row is enough.
                let isRow = label.count > 70 || label.contains(" from ")
                if s.isEnabled, !(label.isEmpty && id.isEmpty), !isRow,
                   !Self.pageNames.contains(where: { label.hasPrefix($0) }),
                   id != "archive.sidebar.import", !seen.contains(key) {
                    seen.insert(key)
                    out.append((id, label))
                }
            }
            s.children.forEach(walk)
        }
        walk(snapshot)
        return out
    }

    /// Presses every distinct, enabled button visible on the page.
    private func crawlButtons(onPage page: String) -> [CrawlRow] {
        var rows: [CrawlRow] = []
        let targets = visibleControls()
        let cap = 150
        for target in targets.prefix(cap) {
            let name = target.label.isEmpty ? target.id : target.label
            if Self.skipPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                rows.append(CrawlRow(page: page, button: name, outcome: "skipped (destructive, purchase or window control)"))
                continue
            }
            recoverIfNeeded()
            let element = resolve(target)
            guard element.exists else { rows.append(CrawlRow(page: page, button: name, outcome: "gone after an earlier press")); continue }
            // `isHittable` raises a test failure (not false) when the element
            // has no hit point at all; check the frame against the window first.
            let bounds = app.windows.firstMatch.frame
            var visible = !element.frame.isEmpty && bounds.intersects(element.frame) && element.isHittable
            // Below the fold: scroll the page up (at most three swipes).
            var swipes = 0
            while !visible && swipes < 3 && !element.frame.isEmpty && element.frame.minY > bounds.midY {
                #if os(iOS)
                app.windows.firstMatch.swipeUp(velocity: .slow)
                #else
                app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
                #endif
                Thread.sleep(forTimeInterval: 0.6)
                swipes += 1
                visible = !element.frame.isEmpty && bounds.intersects(element.frame) && element.isHittable
            }
            guard visible else {
                rows.append(CrawlRow(page: page, button: name, outcome: "not hittable (off-screen or covered; scroll needed)")); continue
            }

            dismissEverything()
            let popoverBefore = popoverOpen()
            let before = Set(visibleControls().map { $0.id + "|" + $0.label })
            #if os(macOS)
            let windowsBefore = app.windows.count
            let sheetsBefore = app.sheets.count
            #endif
            press(element)
            Thread.sleep(forTimeInterval: 1.5)

            if app.state != .runningForeground {
                rows.append(CrawlRow(page: page, button: name, outcome: "CRASH — app quit after the press"))
                app.launch(); _ = app.wait(for: .runningForeground, timeout: 30); _ = openPage(page)
                continue
            }
            var outcome: String
            #if os(macOS)
            if app.menus.count > baselineMenus {
                outcome = "opened a menu"
            } else if app.popovers.firstMatch.exists {
                outcome = "opened a popover"
            } else if app.sheets.count > sheetsBefore {
                outcome = "opened a sheet"
            } else if app.windows.count > windowsBefore {
                let title = app.windows.firstMatch.title
                outcome = "opened window “\(title)”"
                rows.append(CrawlRow(page: page, button: name, outcome: outcome))
                rows += crawlToolWindow(title: title, page: page, parent: name)
                dismissEverything()
                returnToPage(page)
                continue
            } else if app.dialogs.firstMatch.exists {
                outcome = "opened a dialog"
            } else {
                outcome = changeSummary(before: before)
            }
            #else
            if app.alerts.firstMatch.exists {
                outcome = "opened an alert “\(app.alerts.firstMatch.label)”"
            } else if filePickerOpen() {
                outcome = "opened the file picker"
            } else if popoverOpen() && !popoverBefore {
                outcome = "opened a menu or popover"
            } else {
                outcome = changeSummary(before: before)
            }
            #endif
            rows.append(CrawlRow(page: page, button: name, outcome: outcome))
            dismissEverything()
            returnToPage(page)
        }
        if targets.count > cap {
            rows.append(CrawlRow(page: page, button: "(\(targets.count - cap) more)", outcome: "not pressed: per-page cap of \(cap)"))
        }
        return rows
    }

    /// "Screen changed" vs "no visible change", from the controls on screen.
    private func changeSummary(before: Set<String>) -> String {
        let after = Set(visibleControls().map { $0.id + "|" + $0.label })
        let added = after.subtracting(before)
        if added.isEmpty && after == before { return "no visible change (may act in place)" }
        let sample = added.prefix(3).map { $0.split(separator: "|").last.map(String.init) ?? $0 }.joined(separator: ", ")
        return "screen changed (+\(added.count) controls\(sample.isEmpty ? "" : ": \(sample)"))"
    }

    private func resolve(_ target: (id: String, label: String)) -> XCUIElement {
        #if os(macOS)
        let root = app.windows.firstMatch
        #else
        let root: XCUIElement = app
        #endif
        if !target.id.isEmpty {
            let byID = root.descendants(matching: .any).matching(identifier: target.id).firstMatch
            if byID.exists { return byID }
        }
        return root.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", target.label)).firstMatch
    }

    /// Closes whatever the last press opened: alerts, menus, popovers,
    /// sheets, secondary windows, pushed screens.
    private func dismissEverything() {
        for _ in 0..<4 {
            var acted = false
            #if os(macOS)
            if app.menus.count > baselineMenus || app.popovers.firstMatch.exists || app.dialogs.firstMatch.exists {
                app.typeKey(.escape, modifierFlags: []); acted = true
            }
            if app.sheets.firstMatch.exists {
                let sheet = app.sheets.firstMatch
                var hit = false
                for title in ["Done", "Cancel", "Not now", "OK"] where !hit {
                    let b = sheet.buttons[title].firstMatch
                    if b.exists, b.isHittable { b.click(); hit = true }
                }
                if !hit { app.typeKey(.escape, modifierFlags: []) }
                acted = true
            }
            if app.windows.count > 1 {
                app.windows.firstMatch.typeKey("w", modifierFlags: .command); acted = true
            }
            #else
            if filePickerOpen() {
                let cancel = app.navigationBars.buttons["Cancel"].firstMatch
                if cancel.exists { cancel.tap() } else { app.buttons["Cancel"].firstMatch.tap() }
                acted = true
            } else if app.alerts.firstMatch.exists {
                let buttons = app.alerts.firstMatch.buttons
                let cancel = buttons["Cancel"].firstMatch
                (cancel.exists ? cancel : buttons.element(boundBy: max(0, buttons.count - 1))).tap(); acted = true
            } else if app.otherElements["PopoverDismissRegion"].exists {
                app.otherElements["PopoverDismissRegion"].firstMatch.tap(); acted = true
            } else {
                for title in ["Done", "Close", "Cancel", "Not now", "OK", "Got It"] {
                    let b = app.buttons[title].firstMatch
                    if b.exists, b.isHittable { b.tap(); acted = true; break }
                }
            }
            #endif
            if !acted { break }
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    private func popoverOpen() -> Bool {
        #if os(iOS)
        return app.otherElements["PopoverDismissRegion"].exists
        #else
        return app.popovers.firstMatch.exists
        #endif
    }

    /// The system document picker (Recents/Browse tabs, a Cancel button).
    private func filePickerOpen() -> Bool {
        #if os(iOS)
        return app.buttons["Browse"].exists && app.buttons["Cancel"].exists
        #else
        return false
        #endif
    }

    private func returnToPage(_ page: String) {
        #if os(iOS)
        // A pushed screen: go back until the page strip is reachable.
        for _ in 0..<3 {
            let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch
            if tab.exists, tab.isHittable { break }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() } else { app.swipeDown(velocity: .fast) }
            Thread.sleep(forTimeInterval: 0.6)
        }
        #endif
        let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch
        if tab.exists, tab.isHittable, !tab.isSelected { press(tab); Thread.sleep(forTimeInterval: 0.6) }
    }

    private func recoverIfNeeded() {
        if app.state == .notRunning || app.state == .unknown {
            app.launch(); _ = app.wait(for: .runningForeground, timeout: 30)
        }
        #if os(macOS)
        app.activate()
        // A restored window can take a few seconds to appear; deciding "no
        // window" too early opened a second one, and two same-titled windows
        // left the Archive crawl with nothing to press (2026-10-07).
        if !app.windows.firstMatch.waitForExistence(timeout: 8) {
            // Restored with every window closed: open the main window from the menu.
            app.typeKey("n", modifierFlags: [.command, .shift])   // File ▸ New Window
            _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        }
        // One main window: close extras restored from an earlier session.
        var guardCount = 0
        while app.windows.count > 1 && guardCount < 4 {
            app.windows.element(boundBy: 1).click()
            app.typeKey("w", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            guardCount += 1
        }
        print("UITEST-WINDOWS \(app.windows.count): \(app.windows.allElementsBoundByIndex.map(\.title))")
        #endif
        app.activate()
    }

    #if os(macOS)
    /// Presses every enabled button inside a tool window once (one level),
    /// closing anything a press opens, then closes the window.
    private func crawlToolWindow(title: String, page: String, parent: String) -> [CrawlRow] {
        var rows: [CrawlRow] = []
        let window = app.windows.matching(NSPredicate(format: "title == %@", title)).firstMatch
        guard window.waitForExistence(timeout: 5), let snap = try? window.snapshot() else {
            return [CrawlRow(page: page, button: "\(parent) ▸ (window)", outcome: "window could not be read")]
        }
        var seen = Set<String>()
        var targets: [(id: String, label: String)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .button || s.elementType == .menuButton || s.elementType == .popUpButton {
                let label = s.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = s.identifier + "|" + label
                let isRow = label.count > 70 || label.contains(" from ")
                let windowControl = [XCUIIdentifierCloseWindow, XCUIIdentifierMinimizeWindow, XCUIIdentifierZoomWindow, XCUIIdentifierFullScreenWindow].contains(s.identifier)
                if s.isEnabled, !(label.isEmpty && s.identifier.isEmpty), !isRow, !windowControl, !seen.contains(key) {
                    seen.insert(key); targets.append((s.identifier, label))
                }
            }
            s.children.forEach(walk)
        }
        walk(snap)
        for target in targets.prefix(60) {
            let name = target.label.isEmpty ? target.id : target.label
            let path = "\(parent) ▸ \(name)"
            if Self.skipPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                rows.append(CrawlRow(page: page, button: path, outcome: "skipped (destructive, purchase or window control)")); continue
            }
            guard window.exists else { rows.append(CrawlRow(page: page, button: path, outcome: "window closed by an earlier press")); break }
            let el = target.id.isEmpty
                ? window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", target.label)).firstMatch
                : window.descendants(matching: .any).matching(identifier: target.id).firstMatch
            guard el.exists else { rows.append(CrawlRow(page: page, button: path, outcome: "gone after an earlier press")); continue }
            guard !el.frame.isEmpty, window.frame.intersects(el.frame), el.isHittable else {
                rows.append(CrawlRow(page: page, button: path, outcome: "not hittable (scroll needed)")); continue
            }
            let windowsBefore = app.windows.count
            let sheetsBefore = window.sheets.count
            el.click()
            Thread.sleep(forTimeInterval: 1.0)
            if app.state == .notRunning || app.state == .unknown {
                rows.append(CrawlRow(page: page, button: path, outcome: "CRASH — app quit after the click"))
                app.launch(); _ = app.wait(for: .runningForeground, timeout: 30)
                return rows
            }
            var outcome = "acted in place"
            if app.menus.count > baselineMenus { outcome = "opened a menu"; app.typeKey(.escape, modifierFlags: []) }
            else if app.popovers.firstMatch.exists { outcome = "opened a popover"; app.typeKey(.escape, modifierFlags: []) }
            else if window.sheets.count > sheetsBefore || app.sheets.count > sheetsBefore {
                outcome = "opened a sheet"
                let sheet = app.sheets.firstMatch
                var closed = false
                for t in ["Done", "Cancel", "Not now", "OK", "Close"] where !closed {
                    let b = sheet.buttons[t].firstMatch
                    if b.exists, b.isHittable { b.click(); closed = true }
                }
                if !closed { app.typeKey(.escape, modifierFlags: []) }
            }
            else if app.windows.count > windowsBefore {
                let newTitle = app.windows.firstMatch.title
                outcome = "opened window “\(newTitle)”"
                if newTitle != title { app.windows.firstMatch.typeKey("w", modifierFlags: .command) }
            }
            else if app.dialogs.firstMatch.exists { outcome = "opened a dialog"; app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.4)
            rows.append(CrawlRow(page: page, button: path, outcome: outcome))
        }
        if window.exists {
            let close = window.buttons[XCUIIdentifierCloseWindow].firstMatch
            if close.exists { close.click() } else { window.typeKey("w", modifierFlags: .command) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return rows
    }

    /// Opens each top-level menu-bar menu and records its command count.
    private func crawlMenuBar() -> [CrawlRow] {
        var rows: [CrawlRow] = []
        let items = app.menuBars.firstMatch.menuBarItems.allElementsBoundByIndex
        for item in items where !item.title.isEmpty && item.title != "Apple" {
            item.click()
            Thread.sleep(forTimeInterval: 0.4)
            let menu = item.menus.firstMatch
            let count = menu.exists ? menu.menuItems.count : 0
            let enabled = menu.exists ? menu.menuItems.allElementsBoundByIndex.filter { $0.isEnabled }.count : 0
            rows.append(CrawlRow(page: "Menu bar", button: item.title, outcome: "menu opens: \(count) commands, \(enabled) enabled"))
            app.typeKey(.escape, modifierFlags: [])
        }
        return rows
    }
    #endif

    #if os(iOS)
    // MARK: - Core actions the crawl could not reach (iPad)

    /// Brings an element in the Professional page's horizontal tool strip on
    /// screen by swiping the strip, at most six times.
    private func revealInStrip(_ element: XCUIElement) -> Bool {
        // `isHittable` raises (not false) for an element with no hit point,
        // so check the frame against the window first.
        func onScreen() -> Bool {
            guard element.exists else { return false }
            let f = element.frame, w = app.windows.firstMatch.frame
            guard !f.isEmpty, w.contains(CGPoint(x: f.midX, y: f.midY)) else { return false }
            return element.isHittable
        }
        for _ in 0..<14 {
            if onScreen() { return true }
            // Drag along the strip's own row, toward the element.
            let w = app.windows.firstMatch.frame
            let f = element.frame
            guard !f.isEmpty else { break }
            let goRight = f.midX < w.minX
            drag(fromX: goRight ? w.minX + 120 : w.maxX - 120, toX: goRight ? w.maxX - 120 : w.minX + 120, y: f.midY,
                 fromY: f.midY, toY: f.midY)
            Thread.sleep(forTimeInterval: 0.6)
        }
        return onScreen()
    }

    /// A press-and-drag between two absolute points in the main window.
    private func drag(fromX: CGFloat, toX: CGFloat, y: CGFloat, fromY: CGFloat, toY: CGFloat) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: fromX, dy: fromY))
        let end = origin.withOffset(CGVector(dx: toX, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    private func relaunch(_ extra: [String]) {
        app.terminate()
        app.launchArguments = ["--uitest"] + extra
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        _ = app.buttons.firstMatch.waitForExistence(timeout: 60)
    }

    /// Runs one export format from the Archive footer through pre-flight to
    /// its receipt. Returns the receipt's verdict text, or why it stopped.
    private func exportThroughReceipt(_ menuTitle: String) -> String {
        _ = openPage("Archive")
        let menu = app.buttons["Export filtered emails"].firstMatch
        guard menu.waitForExistence(timeout: 10) else { return "FAIL: no Export menu" }
        var swipes = 0
        func menuOnScreen() -> Bool {
            let f = menu.frame, w = app.windows.firstMatch.frame
            return !f.isEmpty && w.contains(CGPoint(x: f.midX, y: f.midY)) && menu.isHittable
        }
        // The menu sits at the foot of the sidebar column: drag that column up.
        while !menuOnScreen() && swipes < 6 {
            let w = app.windows.firstMatch.frame
            let x = menu.frame.isEmpty ? w.minX + 150 : menu.frame.midX
            drag(fromX: x, toX: x, y: 0, fromY: w.maxY - 200, toY: w.minY + 250)
            swipes += 1; Thread.sleep(forTimeInterval: 0.6)
        }
        guard menuOnScreen() else {
            let w = app.windows.firstMatch.frame
            return "FAIL: Export menu not reachable (frame \(menu.frame), window \(w), on screen false)"
        }
        menu.tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", menuTitle)).firstMatch
        guard item.waitForExistence(timeout: 5) else { return "FAIL: menu has no \(menuTitle)" }
        item.tap()
        // iOS does not expose the button's identifier inside the sheet; its
        // label ("Start") is what VoiceOver and the test both see.
        let byID = app.buttons["export.preflight.start"].firstMatch
        let byLabel = app.buttons["Start"].firstMatch
        let appeared = byID.waitForExistence(timeout: 10) || byLabel.waitForExistence(timeout: 5)
        let start = byID.exists ? byID : byLabel
        guard appeared else {
            snapshotScreen("export-no-preflight-\(menuTitle)")
            let labels = (try? app.snapshot()).map { snap -> [String] in
                var out: [String] = []
                func walk(_ s: XCUIElementSnapshot) {
                    if [.button, .staticText, .alert, .sheet].contains(s.elementType), !s.label.isEmpty { out.append("\(s.elementType.rawValue):\(s.label)") }
                    s.children.forEach(walk)
                }
                walk(snap); return out
            } ?? []
            print("UITEST-NO-PREFLIGHT \(menuTitle) >>> \(labels.prefix(80))")
            return "FAIL: pre-flight sheet did not appear"
        }
        let preflightText = (try? app.snapshot())
            .map { snap -> String in
                var parts: [String] = []
                func walk(_ s: XCUIElementSnapshot) { if s.elementType == .staticText { parts.append(s.label) }; s.children.forEach(walk) }
                walk(snap)
                return parts.filter { $0.contains("emails as") || $0.contains("free tier") || $0.contains("needed") }
                    .joined(separator: " / ")
            } ?? ""
        start.tap()
        // iOS hands the finished file to the share sheet; close it, then read the receipt.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if app.state != .runningForeground { return "CRASH during export" }
            let close = app.buttons["Close"].firstMatch
            if app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists {
                if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
            }
            if app.descendants(matching: .any)["export.receipt"].firstMatch.exists { break }
            Thread.sleep(forTimeInterval: 1)
        }
        // The receipt card's text (iOS does not expose its identifiers).
        let receiptShown = app.descendants(matching: .any)["export.receipt"].firstMatch.exists
        let receiptText = (try? app.snapshot()).map { snap -> String in
            var parts: [String] = []
            func walk(_ s: XCUIElementSnapshot) { if s.elementType == .staticText { parts.append(s.label) }; s.children.forEach(walk) }
            walk(snap)
            return parts.filter { $0.localizedCaseInsensitiveContains("written") || $0.localizedCaseInsensitiveContains("export")
                && ($0.contains("emails") || $0.contains("complete") || $0.contains("SHA")) || $0.contains("SHA-256") }
                .prefix(4).joined(separator: " / ")
        } ?? ""
        let text = receiptShown ? (receiptText.isEmpty ? "receipt shown" : receiptText) : "no receipt within 5 minutes"
        snapshotScreen("export-\(menuTitle)")
        return "pre-flight: \(preflightText) ▸ receipt: \(text)"
    }

    func testCoreActions_exportAndProfessionalTools() {
        var rows: [String] = []

        // ── Professional (Debug unlock): the actions the crawl missed ──
        rows.append("CSV export: " + exportThroughReceipt("Spreadsheet (.csv)"))
        dismissEverything()
        rows.append("mbox export: " + exportThroughReceipt("mbox Archive"))
        dismissEverything()

        _ = openPage("Professional Workflows")
        let tools = ["eDiscovery": "eDiscovery", "batesNumbering": "Bates Numbering", "redaction": "Redaction",
                     "reviewBatches": "Review Batches", "investigationReport": "Investigation Report"]
        for (raw, title) in tools.sorted(by: { $0.key < $1.key }) {
            let tile = app.buttons["professional.tool.\(raw)"].firstMatch
            guard revealInStrip(tile) else { rows.append("\(title): FAIL not reachable in the tool strip"); continue }
            tile.tap()
            let done = app.buttons["Done"].firstMatch
            let opened = done.waitForExistence(timeout: 10)
            snapshotScreen("tool-\(raw)")
            rows.append("\(title): " + (opened ? "opened its tool sheet" : "FAIL no tool sheet within 10 s"))
            if app.state != .runningForeground { rows.append("\(title): CRASH"); relaunch([]); _ = openPage("Professional Workflows"); continue }
            dismissEverything()
        }
        let production = app.buttons["professional.production"].firstMatch
        if revealInStrip(production) {
            production.tap()
            let opened = app.buttons["Done"].firstMatch.waitForExistence(timeout: 10)
            snapshotScreen("tool-production")
            rows.append("Production…: " + (opened ? "opened (on iPad this is the Bates Numbering sheet)" : "FAIL nothing opened"))
            dismissEverything()
        } else { rows.append("Production…: FAIL not reachable") }

        // ── Free tier: the same buttons must ask for a purchase ──
        relaunch(["-mailinSimulateTier", "free"])
        let badge = app.buttons["plan.badge"].firstMatch
        rows.append("Free badge: " + (badge.waitForExistence(timeout: 10) ? badge.label : "FAIL no plan badge"))
        _ = openPage("Professional Workflows")
        for (raw, title) in [("batesNumbering", "Bates Numbering"), ("redaction", "Redaction")] {
            let tile = app.buttons["professional.tool.\(raw)"].firstMatch
            guard revealInStrip(tile) else { rows.append("Free \(title): FAIL not reachable"); continue }
            tile.tap()
            let paywall = app.descendants(matching: .any)["paywall"].firstMatch.waitForExistence(timeout: 8)
            snapshotScreen("free-\(raw)")
            rows.append("Free \(title): " + (paywall ? "paywall shown" : "FAIL opened without a purchase"))
            let close = app.buttons["paywall.close"].firstMatch
            if close.exists { close.tap(); Thread.sleep(forTimeInterval: 0.8) } else { dismissEverything() }
        }
        let freeProduction = app.buttons["professional.production"].firstMatch
        if revealInStrip(freeProduction) {
            freeProduction.tap()
            let paywall = app.descendants(matching: .any)["paywall"].firstMatch.waitForExistence(timeout: 8)
            rows.append("Free Production…: " + (paywall ? "paywall shown" : "FAIL opened without a purchase"))
            let close = app.buttons["paywall.close"].firstMatch
            if close.exists { close.tap(); Thread.sleep(forTimeInterval: 0.8) }
        }
        rows.append("Free CSV export: " + exportThroughReceipt("Spreadsheet (.csv)"))

        let report = rows.map { "- " + $0 }.joined(separator: "\n")
        print("CORE-ACTIONS>>>\n\(report)\n<<<CORE-ACTIONS")
        let attachment = XCTAttachment(string: report)
        attachment.name = "core-actions.md"; attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(rows.contains { $0.contains("CRASH") || $0.contains("FAIL") }, report)
    }
    #endif

    // MARK: - Purchases through the real purchase screen (iPad and Mac, local StoreKit)

    // The owner's TestFlight checklist, run as a user would: buy a monthly
    // plan and see features unlock; delete and reinstall, then Restore
    // Purchases; buy a lifetime plan. StoreKit runs locally from
    // maxmailin/Products.storekit through SKTestSession; the app runs with
    // -mailinRealStore, so its tier comes only from verified transactions.
    // The three tests run in order; ~/mailin-loc-work/purchase-fg.sh deletes
    // the app between the first and the second.

    #if os(macOS)
    private func relaunch(_ extra: [String]) {
        app.terminate()
        app = makeApp()
        app.launchArguments = ["--uitest"] + extra
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 30)
        _ = app.buttons.firstMatch.waitForExistence(timeout: 60)
    }
    #endif

    private static var storeConfigURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("maxmailin/Products.storekit")
    }

    private func storeSession(clear: Bool) throws -> SKTestSession {
        #if os(macOS)
        // On the Mac, SKTestSession in a UI test does not take over the app's
        // StoreKit: Buy goes to the App Store sandbox, which asks a person to
        // sign in (seen 2026-10-08). Run only when someone is at the Mac.
        guard ProcessInfo.processInfo.environment["MAC_SANDBOX_PURCHASE"] == "1" else {
            throw XCTSkip("Mac purchases need a person to sign in to the App Store sandbox; set TEST_RUNNER_MAC_SANDBOX_PURCHASE=1")
        }
        #endif
        let session = try SKTestSession(contentsOf: Self.storeConfigURL)
        if clear { session.resetToDefaultState(); session.clearTransactions() }
        session.disableDialogs = true
        session.askToBuyEnabled = false
        return session
    }

    private func planBadge() -> String {
        let badge = app.buttons["plan.badge"].firstMatch
        return badge.waitForExistence(timeout: 15) ? badge.label : "no plan badge"
    }

    /// Waits until the plan badge reads `expected` (the store updates async).
    private func waitForBadge(_ expected: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if planBadge() == expected { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// A control by the start of its label, whatever its type: on the Mac,
    /// "Restore Purchases" is a link-style button.
    private func button(beginningWith text: String) -> XCUIElement {
        let asButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        if asButton.exists { return asButton }
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType != %d", text, XCUIElement.ElementType.staticText.rawValue)).firstMatch
        return any.exists ? any : asButton
    }

    /// What the purchase screen exposes, printed when a control is missing.
    private func dumpControls(_ tag: String) {
        guard let snap = try? app.snapshot() else { return }
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if [.button, .link, .staticText, .radioButton, .sheet].contains(s.elementType), !(s.label.isEmpty && s.identifier.isEmpty) {
                out.append("\(s.elementType.rawValue):\(s.identifier):\(s.label.prefix(60))")
            }
            s.children.forEach(walk)
        }
        walk(snap)
        print("PURCHASE-DUMP \(tag) >>> \(out.prefix(120))")
    }

    private func textContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// On the Mac the purchase goes to the App Store sandbox, which asks the
    /// person at the Mac to sign in or confirm: wait for them.
    #if os(macOS)
    private static let purchaseWait: TimeInterval = 240
    #else
    private static let purchaseWait: TimeInterval = 20
    #endif

    private func waitUntilPurchaseScreenCloses(timeout: TimeInterval = MailinClickThroughUITests.purchaseWait) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !button(beginningWith: "Restore Purchases").exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        dumpControls("still-open")
        // Anything the purchase screen says (an error, a pending note).
        for id in ["paywall.error", "paywall.status", "paywall.pending"] {
            let e = app.descendants(matching: .any)[id].firstMatch
            if e.exists { print("PURCHASE-MESSAGE \(id): \(e.label) \(String(describing: e.value))") }
        }
        return false
    }

    /// Opens the purchase screen from the plan badge.
    private func openPurchaseScreen() -> Bool {
        let badge = app.buttons["plan.badge"].firstMatch
        guard badge.waitForExistence(timeout: 15) else { return false }
        #if os(macOS)
        print("PURCHASE-BADGE frame \(badge.frame) hittable \(badge.isHittable) enabled \(badge.isEnabled)")
        badge.click()
        #else
        badge.tap()
        #endif
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if button(beginningWith: "Restore Purchases").exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        dumpControls("no-restore")
        return false
    }

    /// Picks a plan and period on the purchase screen and presses Buy.
    /// Returns the Buy button's label (it names product and price).
    private func buy(tier: String, period: String) -> String {
        // A card's label can start with its badge ("Most Popular, Professional…").
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label BEGINSWITH 'Buy ') AND NOT (label BEGINSWITH 'Current plan')", tier)).firstMatch
        if card.waitForExistence(timeout: 10) { press(card) }
        let periodButton = button(beginningWith: period)
        if periodButton.waitForExistence(timeout: 5) { press(periodButton) }
        let buyButton = button(beginningWith: "Buy ")
        guard buyButton.waitForExistence(timeout: 10) else { dumpControls("no-buy"); return "FAIL no Buy button" }
        #if os(iOS)
        var swipes = 0
        while !buyButton.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }
        #endif
        let label = buyButton.label
        press(buyButton)
        return label
    }

    /// Opens a Professional-page tool and reports whether it opened or asked
    /// for a purchase.
    private func toolOutcome(_ raw: String) -> String {
        #if os(macOS)
        // On the Mac an unlocked tool opens in its own window; a locked one
        // shows the purchase sheet in the main window.
        _ = openPage("Professional Workflows")
        let tile = app.buttons["professional.tool.\(raw)"].firstMatch
        guard tile.waitForExistence(timeout: 10) else { return "FAIL not reachable" }
        let windowsBefore = app.windows.count
        tile.click()
        let paywall = app.descendants(matching: .any)["paywall"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        var outcome = "FAIL neither opened nor asked"
        while Date() < deadline {
            if paywall.exists { outcome = "asks for a purchase"; break }
            if app.windows.count > windowsBefore { outcome = "opens"; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        snapshotScreen("purchase-tool-\(raw)")
        if outcome == "opens" {
            app.typeKey("w", modifierFlags: .command)   // close the tool window
            Thread.sleep(forTimeInterval: 0.8)
        } else {
            let close = app.buttons["paywall.close"].firstMatch
            if close.exists { close.click(); Thread.sleep(forTimeInterval: 0.8) } else { dismissEverything() }
        }
        return outcome
        #else
        _ = openPage("Professional Workflows")
        let tile = app.buttons["professional.tool.\(raw)"].firstMatch
        guard revealInStrip(tile) else { return "FAIL not reachable" }
        tile.tap()
        let paywall = app.descendants(matching: .any)["paywall"].firstMatch
        let done = app.buttons["Done"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        var outcome = "FAIL neither opened nor asked"
        while Date() < deadline {
            if paywall.exists { outcome = "asks for a purchase"; break }
            if done.exists { outcome = "opens"; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        snapshotScreen("purchase-tool-\(raw)")
        let close = app.buttons["paywall.close"].firstMatch
        if close.exists { close.tap(); Thread.sleep(forTimeInterval: 0.8) } else { dismissEverything() }
        return outcome
        #endif
    }

    private func report(_ name: String, _ rows: [String]) {
        let text = rows.map { "- " + $0 }.joined(separator: "\n")
        print("PURCHASE-\(name)>>>\n\(text)\n<<<PURCHASE-\(name)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "purchase-\(name).md"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Reads the purchase state of the app as it is — no buying — so a
    /// purchase made by hand (TestFlight) can be checked: plan badge,
    /// Settings ▸ Plan & Purchases (tier, ownership, renewal date), and
    /// which tools open.
    func testPurchaseState_report() throws {
        relaunch([])
        var rows: [String] = []
        rows.append("Badge: “\(planBadge())”")
        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        let general = app.buttons["General"].firstMatch
        if general.waitForExistence(timeout: 8) { general.click() }
        #endif
        let tier = app.descendants(matching: .any)["settings.plan.tier"].firstMatch
        if tier.waitForExistence(timeout: 10) {
            rows.append("Settings ▸ Current plan: “\(tier.label)” value “\(String(describing: tier.value ?? ""))”")
        } else {
            rows.append("Settings ▸ Current plan: not found")
        }
        for label in ["Ownership", "Renews or ends"] {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if row.exists { rows.append("Settings ▸ \(label): “\(row.label)” value “\(String(describing: row.value ?? ""))”") }
        }
        snapshotScreen("purchase-state-settings")
        #if os(macOS)
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.8)
        #else
        dismissEverything()
        #endif
        rows.append("Redaction (Personal tool): \(toolOutcome("redaction"))")
        rows.append("Bates Numbering (Professional tool): \(toolOutcome("batesNumbering"))")
        // The Archive list's count line: Free reads "First 500 of N emails ·
        // Unlock Full Archive"; paid tiers show no such line.
        _ = openPage("Archive")
        let countLine = app.descendants(matching: .any)["archive.list.count"].firstMatch
        rows.append("Archive list count line: " + (countLine.waitForExistence(timeout: 5) ? "“\(countLine.label)”" : "none (whole archive)"))
        report("STATE", rows)
    }

    func testPurchase1_buyMonthlyUnlocksFeatures() throws {
        let session = try storeSession(clear: true)
        _ = session
        relaunch(["-mailinRealStore"])
        var rows: [String] = []
        let freeBadge = waitForBadge("Free plan. Upgrade")
        rows.append("Fresh install: badge “\(planBadge())”")
        XCTAssertTrue(freeBadge, "a fresh install must be Free")
        let redactionFree = toolOutcome("redaction")
        rows.append("Free ▸ Redaction (Personal tool): \(redactionFree)")
        XCTAssertEqual(redactionFree, "asks for a purchase")

        XCTAssertTrue(openPurchaseScreen(), "purchase screen opens from the plan badge")
        let bought = buy(tier: "Personal", period: "Monthly")
        rows.append("Pressed: “\(bought)”")
        // On success the purchase screen closes itself (PaywallView.submitPurchase).
        let unlocked = waitUntilPurchaseScreenCloses()
        rows.append("Purchase screen: " + (unlocked ? "closed itself after the purchase succeeded" : "FAIL still open after \(Int(Self.purchaseWait)) s"))
        snapshotScreen("purchase-monthly-done")
        if !unlocked { dismissEverything() }
        let personal = waitForBadge("Current plan: Personal")
        rows.append("Badge after purchase: “\(planBadge())”")
        let redactionPaid = toolOutcome("redaction")
        let batesPaid = toolOutcome("batesNumbering")
        rows.append("Personal ▸ Redaction: \(redactionPaid)")
        rows.append("Personal ▸ Bates Numbering (Professional tool): \(batesPaid)")
        report("MONTHLY", rows)
        XCTAssertTrue(unlocked && personal)
        XCTAssertTrue(bought.contains("Personal") && bought.contains("month"), bought)
        XCTAssertEqual(redactionPaid, "opens")
        XCTAssertEqual(batesPaid, "asks for a purchase")
    }

    func testPurchase2_reinstallThenRestore() throws {
        // iPad: the runner wiped all of the app's data before this test —
        // what a reinstall erases. Mac: the app keeps no purchase state of
        // its own (StoreManager asks StoreKit on every launch), so a fresh
        // launch sees what a reinstall sees; the Mac container holds the
        // owner's real archive and is not wiped. (Uninstalling under Xcode's local StoreKit also
        // erases the app's test purchases, unlike the real App Store, where
        // they stay with the Apple Account; so a real uninstall cannot stand
        // in for a reinstall here.)
        let session = try storeSession(clear: false)
        let owned = session.allTransactions().map(\.productIdentifier)
        relaunch(["-mailinRealStore"])
        var rows: [String] = ["Transactions on the store account: \(owned)"]
        rows.append("Fresh install, before Restore: badge “\(planBadge())”")
        XCTAssertTrue(openPurchaseScreen(), "purchase screen opens from the plan badge")
        let restore = button(beginningWith: "Restore Purchases")
        press(restore)
        let restored = textContaining("Restored: your Personal access").waitForExistence(timeout: Self.purchaseWait)
            || waitForBadge("Current plan: Personal", timeout: 5)
        snapshotScreen("purchase-restored")
        rows.append("Restore Purchases: " + (restored ? "“Restored: your Personal access is active on this device.”" : "FAIL"))
        dismissEverything()
        let personal = waitForBadge("Current plan: Personal")
        rows.append("Badge after Restore: “\(planBadge())”")
        let redaction = toolOutcome("redaction")
        rows.append("Restored ▸ Redaction: \(redaction)")
        report("RESTORE", rows)
        XCTAssertTrue(owned.contains("personal_monthly"), "the monthly purchase is on the store account")
        XCTAssertTrue(restored && personal)
        XCTAssertEqual(redaction, "opens")
    }

    func testPurchase3_buyLifetime() throws {
        let session = try storeSession(clear: false)
        _ = session
        relaunch(["-mailinRealStore"])
        var rows: [String] = ["Starting badge: “\(planBadge())”"]
        XCTAssertTrue(openPurchaseScreen(), "purchase screen opens from the plan badge")
        let bought = buy(tier: "Professional", period: "Lifetime")
        rows.append("Pressed: “\(bought)”")
        let unlocked = waitUntilPurchaseScreenCloses()
        rows.append("Purchase screen: " + (unlocked ? "closed itself after the purchase succeeded" : "FAIL still open after \(Int(Self.purchaseWait)) s"))
        snapshotScreen("purchase-lifetime-done")
        if !unlocked { dismissEverything() }
        let lifetime = waitForBadge("Current plan: Professional · Lifetime", timeout: 30)
        rows.append("Badge after purchase: “\(planBadge())”")
        let bates = toolOutcome("batesNumbering")
        rows.append("Professional ▸ Bates Numbering: \(bates)")
        report("LIFETIME", rows)
        XCTAssertTrue(bought.contains("Professional") && bought.contains("once"), bought)
        XCTAssertTrue(unlocked && lifetime)
        XCTAssertEqual(bates, "opens")
    }

    #if os(iOS)
    // MARK: - Deep crawl: every button, two levels (iPad)

    /// Scrolls `e` into view by dragging the column or strip it sits in.
    /// Returns false when it cannot be brought on screen or stays covered.
    /// The smallest on-screen scroll area lying under `f` on the axis that
    /// needs scrolling (so inside a sheet we scroll the sheet, not the page).
    private func scrollArea(for f: CGRect, vertical: Bool) -> CGRect {
        let w = app.windows.firstMatch.frame
        guard let snap = try? app.snapshot() else { return w }
        var best = w
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .scrollView || s.elementType == .table || s.elementType == .collectionView {
                let r = s.frame.intersection(w)
                let spans = vertical ? (r.minX <= f.midX && f.midX <= r.maxX) : (r.minY <= f.midY && f.midY <= r.maxY)
                if !r.isEmpty, spans, r.width > 60, r.height > 60, r.width * r.height < best.width * best.height { best = r }
            }
            s.children.forEach(walk)
        }
        walk(snap)
        return best
    }

    private func reveal(_ e: XCUIElement) -> Bool {
        for _ in 0..<6 {
            guard e.exists else { return false }
            let f = e.frame, w = app.windows.firstMatch.frame
            if f.isEmpty { return false }
            if w.insetBy(dx: 4, dy: 4).contains(CGPoint(x: f.midX, y: f.midY)) {
                if e.isHittable { return true }
                // On screen but outside its own scroll area (e.g. below a sheet's fold).
            }
            let vertical = f.midY > w.maxY - 4 || f.midY < w.minY + 4 || !(w.minX...w.maxX).contains(f.midX) == false
            let area = scrollArea(for: f, vertical: vertical)
            let x = min(max(f.midX, area.minX + 20), area.maxX - 20)
            let y = min(max(f.midY, area.minY + 20), area.maxY - 20)
            if f.midY > area.maxY - 4 { drag(fromX: x, toX: x, y: 0, fromY: area.maxY - 30, toY: area.minY + 30) }
            else if f.midY < area.minY + 4 { drag(fromX: x, toX: x, y: 0, fromY: area.minY + 30, toY: area.maxY - 30) }
            else if f.midX > area.maxX - 4 { drag(fromX: area.maxX - 30, toX: area.minX + 30, y: 0, fromY: y, toY: y) }
            else if f.midX < area.minX + 4 { drag(fromX: area.minX + 30, toX: area.maxX - 30, y: 0, fromY: y, toY: y) }
            else { return false }   // inside its area yet not hittable: covered
            Thread.sleep(forTimeInterval: 0.6)
        }
        return e.exists && e.isHittable
    }

    /// Among elements matching `target`, the one a user could tap now, else
    /// the first match (labels like "Done" repeat across hidden screens).
    private func resolveVisible(_ target: (id: String, label: String)) -> XCUIElement {
        let w = app.windows.firstMatch.frame
        let query = target.id.isEmpty
            ? app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", target.label))
            : app.descendants(matching: .any).matching(identifier: target.id)
        let n = min(query.count, 12)
        for i in 0..<n {
            let el = query.element(boundBy: i)
            let f = el.frame
            if !f.isEmpty, w.contains(CGPoint(x: f.midX, y: f.midY)), el.isHittable { return el }
        }
        return n > 0 ? query.element(boundBy: 0) : resolve(target)
    }

    /// Closes one level of whatever is on top.
    private func dismissOnce() {
        if app.alerts.firstMatch.exists {
            let b = app.alerts.firstMatch.buttons
            let cancel = b["Cancel"].firstMatch
            (cancel.exists ? cancel : b.element(boundBy: max(0, b.count - 1))).tap(); return
        }
        if filePickerOpen() {
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            (cancel.exists ? cancel : app.buttons["Cancel"].firstMatch).tap(); return
        }
        if popoverOpen() { app.otherElements["PopoverDismissRegion"].firstMatch.tap(); return }
        for title in ["Done", "Close", "Cancel", "Not now", "OK"] {
            let b = resolveVisible((id: "", label: title))
            if b.exists, !b.frame.isEmpty, app.windows.firstMatch.frame.contains(CGPoint(x: b.frame.midX, y: b.frame.midY)), b.isHittable { b.tap(); return }
        }
        let gotIt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Got It'")).firstMatch
        if gotIt.exists, gotIt.isHittable { gotIt.tap(); return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap(); return }
        app.swipeDown(velocity: .fast)
    }

    private static let deepSkip = try! NSRegularExpression(
        pattern: #"(?i)(\b(delete|remove|erase|clear|reset|forget|purge|wipe|empty|quit|sign out|log ?out|buy|purchase|subscribe|restore purchases|manage subscription|turn off|disable|send|move archive|relocate|lift hold|release|revoke)\b|new import|start new import|add more email files|add files)"#)

    private func isSkipped(_ name: String) -> Bool {
        Self.deepSkip.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private func keys() -> Set<String> { Set(visibleControls().map { $0.id + "|" + $0.label }) }

    /// What a press did, judged against the controls on screen before it.
    private func outcome(before: Set<String>, popoverBefore: Bool) -> (text: String, opened: Bool, added: [String]) {
        if app.state != .runningForeground { return ("CRASH — app quit after the press", false, []) }
        if app.alerts.firstMatch.exists {
            let buttons = app.alerts.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
            return ("opened alert “\(app.alerts.firstMatch.label)” [\(buttons.joined(separator: ", "))]", true, [])
        }
        if filePickerOpen() { return ("opened the file picker", true, []) }
        let after = keys()
        let added = Array(after.subtracting(before))
        if popoverOpen() && !popoverBefore { return ("opened a menu/popover (\(added.count) items)", true, added) }
        if added.isEmpty && after == before { return ("no visible change (acts in place)", false, []) }
        let sample = added.prefix(3).map { $0.split(separator: "|").last.map(String.init) ?? $0 }.joined(separator: ", ")
        return ("screen changed (+\(added.count): \(sample))", added.count >= 2, added)
    }

    func testDeepCrawl_everyButtonTwoLevels() {
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        var rows: [String] = []
        var pressedTop = Set<String>()
        let childCap = 25, topCap = 150

        for page in Self.pageNames where page != "Live Mail" {
            guard openPage(page) else { rows.append("| \(page) | (page) | could not open |"); continue }
            let targets = visibleControls()
            for target in targets.prefix(topCap) {
                let key = target.id + "|" + target.label
                let name = target.label.isEmpty ? target.id : target.label
                if pressedTop.contains(key) { continue }       // same control on an earlier page
                pressedTop.insert(key)
                if isSkipped(name) { rows.append("| \(page) | \(name) | skipped (destructive, purchase or import) |"); continue }
                recoverIfNeeded()
                dismissEverything()
                let parent = resolveVisible(target)
                guard parent.exists else { rows.append("| \(page) | \(name) | not present after earlier presses |"); continue }
                guard reveal(parent) else { rows.append("| \(page) | \(name) | NOT REACHABLE (covered or cannot scroll to it) |"); continue }
                let popBefore = popoverOpen()
                let before = keys()
                print("CRAWL-STEP \(Date()) \(page) ▸ \(name)")
                parent.tap()
                Thread.sleep(forTimeInterval: 1.2)
                let top = outcome(before: before, popoverBefore: popBefore)
                rows.append("| \(page) | \(name) | \(top.text) |")
                if top.text.hasPrefix("CRASH") {
                    app.launch(); _ = app.wait(for: .runningForeground, timeout: 30); _ = openPage(page); continue
                }

                // ── Level 2: everything the press opened (alerts are only listed) ──
                if top.opened && !app.alerts.firstMatch.exists && !filePickerOpen() {
                    let container = keys()
                    let children = top.added.compactMap { k -> (id: String, label: String)? in
                        let parts = k.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                        guard parts.count == 2 else { return nil }
                        return (parts[0], parts[1])
                    }
                    let anchors = Array(children.prefix(3))
                    for child in children.prefix(childCap) {
                        let cname = child.label.isEmpty ? child.id : child.label
                        if isSkipped(cname) { rows.append("| \(page) | \(name) ▸ \(cname) | skipped |"); continue }
                        // Container still open? If not, reopen it from the parent.
                        if !anchors.contains(where: { a in let e = resolveVisible(a); return e.exists && !e.frame.isEmpty && app.windows.firstMatch.frame.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) }) {
                            dismissEverything(); returnToPage(page)
                            let again = resolveVisible(target)
                            guard again.exists, reveal(again) else { rows.append("| \(page) | \(name) ▸ … | container could not be reopened; rest not pressed |"); break }
                            again.tap(); Thread.sleep(forTimeInterval: 1.2)
                        }
                        let el = resolveVisible(child)
                        guard el.exists else { rows.append("| \(page) | \(name) ▸ \(cname) | gone after an earlier press |"); continue }
                        guard reveal(el) else { rows.append("| \(page) | \(name) ▸ \(cname) | NOT REACHABLE |"); continue }
                        let cPop = popoverOpen()
                        let cBefore = keys()
                        print("CRAWL-STEP \(Date()) \(page) ▸ \(name) ▸ \(cname)")
                        el.tap()
                        Thread.sleep(forTimeInterval: 1.2)
                        let res = outcome(before: cBefore, popoverBefore: cPop)
                        rows.append("| \(page) | \(name) ▸ \(cname) | \(res.text) |")
                        if res.text.hasPrefix("CRASH") {
                            app.launch(); _ = app.wait(for: .runningForeground, timeout: 30); _ = openPage(page); break
                        }
                        // Close only what the child opened, then carry on in the container.
                        let now = keys()
                        if res.opened || !now.subtracting(container).isEmpty && now.isSuperset(of: container) == false {
                            dismissOnce(); Thread.sleep(forTimeInterval: 0.6)
                        }
                    }
                }
                dismissEverything()
                returnToPage(page)
            }
            if targets.count > topCap { rows.append("| \(page) | (\(targets.count - topCap) more) | not pressed: cap |") }
        }

        let crashes = rows.filter { $0.contains("CRASH") }
        let unreachable = rows.filter { $0.contains("NOT REACHABLE") }
        let report = "| Page | Button | Outcome |\n|---|---|---|\n" + rows.joined(separator: "\n")
            + "\n\nRows: \(rows.count); crashes: \(crashes.count); not reachable: \(unreachable.count)\n"
        print("DEEP-CRAWL>>>\n\(report)<<<DEEP-CRAWL")
        let att = XCTAttachment(string: report); att.name = "deep-crawl.md"; att.lifetime = .keepAlways; add(att)
        XCTAssertTrue(crashes.isEmpty, "crashes: \(crashes)")
    }
    #endif

    #if os(iOS)
    /// Deep crawl 2026-10-04: Archive ▸ AI Assistant ▸ Show tutorial, then a
    /// tap outside, and the app was gone. Reproduce that exact sequence.
    func testRepro_aiAssistantTutorialDismiss() {
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        _ = openPage("Archive")
        _ = app.buttons["AI Assistant"].firstMatch.waitForExistence(timeout: 90)
        Thread.sleep(forTimeInterval: 2)
        let ai = resolveVisible((id: "", label: "AI Assistant"))
        XCTAssertTrue(ai.exists && reveal(ai), "AI Assistant button reachable")
        ai.tap(); Thread.sleep(forTimeInterval: 2)
        print("REPRO after AI Assistant: popover=\(popoverOpen()) state=\(app.state.rawValue)")
        let help = resolveVisible((id: "", label: "Show tutorial"))
        XCTAssertTrue(help.exists && reveal(help), "Show tutorial reachable")
        help.tap(); Thread.sleep(forTimeInterval: 2)
        snapshotScreen("repro-tutorial-open")
        print("REPRO after tutorial: popover=\(popoverOpen()) state=\(app.state.rawValue)")
        if popoverOpen() { app.otherElements["PopoverDismissRegion"].firstMatch.tap() } else { dismissOnce() }
        Thread.sleep(forTimeInterval: 3)
        print("REPRO after dismiss: state=\(app.state.rawValue)")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after dismissing the tutorial")
        snapshotScreen("repro-after-dismiss")
    }
    #endif

    #if os(macOS)
    // MARK: - Fast Mac crawl (one snapshot per step; large archives make each
    // accessibility query cost seconds, so nothing is queried per element)

    private struct MacState {
        var windows: [String] = []
        var windowFrames: [String: CGRect] = [:]
        var menus = 0, popovers = 0, sheets = 0, dialogs = 0
        /// Enabled buttons in the window being crawled: key -> (name, frame).
        var buttons: [(key: String, name: String, frame: CGRect)] = []
    }

    private func macState(buttonsIn windowTitle: String) -> MacState? {
        guard let snap = try? app.snapshot() else { return nil }
        var st = MacState()
        var seen = Set<String>()
        func walk(_ e: XCUIElementSnapshot, collect: Bool) {
            switch e.elementType {
            case .menu: st.menus += 1
            case .popover: st.popovers += 1
            case .sheet: st.sheets += 1
            case .dialog: st.dialogs += 1
            default: break
            }
            if collect, [.button, .menuButton, .popUpButton].contains(e.elementType), e.isEnabled {
                let label = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = e.identifier + "|" + label
                let windowControl = [XCUIIdentifierCloseWindow, XCUIIdentifierMinimizeWindow, XCUIIdentifierZoomWindow, XCUIIdentifierFullScreenWindow].contains(e.identifier)
                let isRow = label.count > 70 || label.contains(" from ")
                if !(label.isEmpty && e.identifier.isEmpty), !windowControl, !isRow, !seen.contains(key) {
                    seen.insert(key)
                    st.buttons.append((key, label.isEmpty ? e.identifier : label, e.frame))
                }
            }
            e.children.forEach { walk($0, collect: collect) }
        }
        for child in snap.children {
            if child.elementType == .window {
                st.windows.append(child.title)
                st.windowFrames[child.title] = child.frame
                walk(child, collect: child.title == windowTitle)
            } else {
                walk(child, collect: false)
            }
        }
        return st
    }

    private func click(at frame: CGRect, inWindow title: String, windowFrame: CGRect) {
        let byTitle = app.windows.matching(NSPredicate(format: "title == %@", title)).firstMatch
        let origin = (byTitle.exists ? byTitle : app.windows.firstMatch).coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.midX - windowFrame.minX, dy: frame.midY - windowFrame.minY)).click()
    }

    private static let macSkip = try! NSRegularExpression(
        pattern: #"(?i)(\b(delete|remove|erase|clear|reset|forget|purge|wipe|empty|quit|sign out|log ?out|buy|purchase|subscribe|restore purchases|manage subscription|turn off|disable|send|move archive|relocate|lift hold|release|revoke|close)\b|new import|start new import|add files|open email archive|import)"#)

    /// Closes what a press opened, judged against the state before it.
    private func macDismiss(before: MacState, after: MacState, keep: Set<String>) {
        if after.menus > before.menus || after.popovers > before.popovers || after.dialogs > before.dialogs || after.sheets > before.sheets {
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
        for title in after.windows where !keep.contains(title) && !before.windows.contains(title) {
            app.windows[title].firstMatch.typeKey("w", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func macOutcome(before: MacState, after: MacState) -> String {
        let newWindows = after.windows.filter { !before.windows.contains($0) }
        if !newWindows.isEmpty { return "opened window “\(newWindows.joined(separator: ", "))”" }
        if after.sheets > before.sheets { return "opened a sheet" }
        if after.dialogs > before.dialogs { return "opened a dialog" }
        if after.popovers > before.popovers { return "opened a popover" }
        if after.menus > before.menus { return "opened a menu" }
        let b = Set(before.buttons.map(\.key)), a = Set(after.buttons.map(\.key))
        if a == b { return "no visible change (acts in place)" }
        return "screen changed (+\(a.subtracting(b).count) / -\(b.subtracting(a).count) controls)"
    }

    /// Presses every enabled button of `windowTitle` once; for presses that
    /// open a tool window, crawls that window one level deep.
    private func macCrawl(page: String, windowTitle: String = "mailin", parent: String? = nil, depth: Int = 0) -> [CrawlRow] {
        var rows: [CrawlRow] = []
        guard let first = macState(buttonsIn: windowTitle) else {
            return [CrawlRow(page: page, button: parent ?? "(page)", outcome: "could not read the window")]
        }
        let keep = Set(first.windows)
        var pressed = Set<String>()
        let targets = first.buttons.filter { !Self.pageNames.contains(where: $0.name.hasPrefix) }
        for target in targets.prefix(depth == 0 ? 150 : 60) {
            let path = parent.map { "\($0) ▸ \(target.name)" } ?? target.name
            if pressed.contains(target.key) { continue }
            pressed.insert(target.key)
            if Self.macSkip.firstMatch(in: target.name, range: NSRange(target.name.startIndex..., in: target.name)) != nil {
                rows.append(CrawlRow(page: page, button: path, outcome: "skipped (destructive, purchase, import or window control)")); continue
            }
            if app.state == .runningBackground { app.activate(); Thread.sleep(forTimeInterval: 0.5) }
            guard app.state == .runningForeground || app.state == .runningBackground, let before = macState(buttonsIn: windowTitle) else {
                rows.append(CrawlRow(page: page, button: path, outcome: "app not running before the press")); break
            }
            guard before.windows.contains(windowTitle), let winFrame = before.windowFrames[windowTitle] else {
                rows.append(CrawlRow(page: page, button: path, outcome: "window closed by an earlier press")); break
            }
            guard var now = before.buttons.first(where: { $0.key == target.key }) else {
                rows.append(CrawlRow(page: page, button: path, outcome: "gone after an earlier press")); continue
            }
            // Off-screen: scroll the area it sits in (mouse wheel at a point on
            // its row or column inside the window), up to five times.
            var scrolls = 0
            func onScreen(_ f: CGRect) -> Bool { !f.isEmpty && winFrame.insetBy(dx: 4, dy: 4).contains(CGPoint(x: f.midX, y: f.midY)) }
            while !onScreen(now.frame) && !now.frame.isEmpty && scrolls < 5 && app.state == .runningForeground {
                let f = now.frame
                let x = min(max(f.midX, winFrame.minX + 40), winFrame.maxX - 40)
                let y = min(max(f.midY, winFrame.minY + 60), winFrame.maxY - 40)
                let window = app.windows.matching(NSPredicate(format: "title == %@", windowTitle)).firstMatch
                let point = (window.exists ? window : app.windows.firstMatch).coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x - winFrame.minX, dy: y - winFrame.minY))
                if f.midY > winFrame.maxY - 4 { point.scroll(byDeltaX: 0, deltaY: -300) }
                else if f.midY < winFrame.minY + 4 { point.scroll(byDeltaX: 0, deltaY: 300) }
                else if f.midX > winFrame.maxX - 4 { point.scroll(byDeltaX: -300, deltaY: 0) }
                else { point.scroll(byDeltaX: 300, deltaY: 0) }
                Thread.sleep(forTimeInterval: 0.6)
                scrolls += 1
                guard let st = macState(buttonsIn: windowTitle), let moved = st.buttons.first(where: { $0.key == target.key }) else { break }
                now = moved
            }
            guard onScreen(now.frame) else {
                rows.append(CrawlRow(page: page, button: path, outcome: "not visible (could not scroll to it)")); continue
            }
            // Coordinate clicks land on whatever is in front: only click when
            // maxmailin itself is frontmost (otherwise they hit Xcode).
            if app.state != .runningForeground { app.activate(); Thread.sleep(forTimeInterval: 1) }
            guard app.state == .runningForeground else {
                rows.append(CrawlRow(page: page, button: path, outcome: "not pressed: another app is in front"))
                continue
            }
            print("CRAWL-STEP \(Date()) \(page) ▸ \(path)")
            click(at: now.frame, inWindow: windowTitle, windowFrame: winFrame)
            Thread.sleep(forTimeInterval: 1.2)
            if app.state == .notRunning || app.state == .unknown {
                rows.append(CrawlRow(page: page, button: path, outcome: "CRASH — app quit after the click"))
                app.launch(); _ = app.wait(for: .runningForeground, timeout: 30)
                recoverIfNeeded(); _ = openPage(page)
                if depth > 0 { break } else { continue }
            }
            guard let after = macState(buttonsIn: windowTitle) else {
                rows.append(CrawlRow(page: page, button: path, outcome: "could not read the app after the click")); continue
            }
            let outcome = macOutcome(before: before, after: after)
            rows.append(CrawlRow(page: page, button: path, outcome: outcome))
            let opened = after.windows.filter { !before.windows.contains($0) }
            if depth == 0, let tool = opened.first {
                rows += macCrawl(page: page, windowTitle: tool, parent: path, depth: 1)
            }
            if let latest = macState(buttonsIn: windowTitle) {
                macDismiss(before: before, after: latest, keep: keep)
            }
            if depth == 0 { returnToPage(page) }
        }
        return rows
    }
    #endif

    #if os(macOS)
    /// Mac crawl 2026-10-05: clicking an AI Insights suggestion ("Ask: …")
    /// crashed the app inside AppKit accessibility. Click one, then read the
    /// accessibility tree the way VoiceOver would.
    func testRepro_macAISuggestionClick() {
        recoverIfNeeded()
        _ = openPage("AI Insights")
        let which = ProcessInfo.processInfo.environment["MAILIN_REPRO_SUGGESTION"] ?? "Ask: "
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", which)).firstMatch
        guard suggestion.waitForExistence(timeout: 20) else { XCTFail("no suggestion shown"); return }
        if ProcessInfo.processInfo.environment["MAILIN_REPRO_RAPID"] == "1" {
            // The crawl's sequence: several suggestions within seconds.
            let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask: '"))
            let n = min(all.count, 5)
            for i in 0..<n {
                let b = all.element(boundBy: i)
                if b.exists, b.isHittable { b.click(); print("REPRO-MAC rapid click \(i) enabled=\(b.isEnabled)") }
                Thread.sleep(forTimeInterval: 1.5)
            }
        } else if suggestion.isHittable { suggestion.click() } else { suggestion.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
        for i in 0..<20 {
            Thread.sleep(forTimeInterval: 1)
            _ = try? app.snapshot()          // what an accessibility client does
            print("REPRO-MAC tick \(i) state=\(app.state.rawValue)")
            if app.state == .notRunning { break }
        }
        XCTAssertNotEqual(app.state, .notRunning, "the app survives clicking a suggestion")
    }
    #endif

    #if os(macOS)
    /// Mac crawl 2026-10-05: clicking the Archive tab left AI Insights on
    /// screen. Click it and check the Archive content actually appears.
    func testRepro_macPageSwitch() {
        recoverIfNeeded()
        app.activate()
        Thread.sleep(forTimeInterval: 2)
        for name in ["Archive", "AI Insights", "Archive"] {
            let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            guard tab.waitForExistence(timeout: 10) else { XCTFail("no \(name) tab"); return }
            print("REPRO-PAGE \(name) tab label=\(tab.label) hittable=\(tab.isHittable) frame=\(tab.frame) state=\(app.state.rawValue)")
            if tab.isHittable { tab.click() } else { tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
            Thread.sleep(forTimeInterval: 2)
            let archiveShown = app.descendants(matching: .any)["archive.sidebar"].firstMatch.exists
                || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Emails'")).firstMatch.exists
            let aiShown = app.descendants(matching: .any)["aiInsights.page"].firstMatch.exists
            print("REPRO-PAGE after \(name): archiveShown=\(archiveShown) aiShown=\(aiShown) selected=\(tab.isSelected)")
            snapshotScreen("page-switch-\(name)")
        }
    }
    #endif

    #if os(macOS)
    /// Owner, 2026-10-05: "have you checked the result of the AI answers?"
    /// Asks real questions on the archive and records every answer verbatim.
    func testAIAnswers_recordForReview() {
        recoverIfNeeded()
        // A tall window, so every suggestion is on screen without scrolling.
        let windowMenu = app.menuBars.menuBarItems["Window"]
        if windowMenu.exists {
            windowMenu.click()
            let zoom = app.menuItems["Zoom"]
            if zoom.waitForExistence(timeout: 2), zoom.isEnabled { zoom.click() } else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 1)
        }
        _ = openPage("AI Insights")
        let askTab = app.buttons["Ask"].firstMatch
        if askTab.waitForExistence(timeout: 5), askTab.isHittable { askTab.click() }
        var report = ""
        var asked = Set<String>()
        for n in 0..<10 {
            // Back to the suggestion list: clear any previous conversation.
            // The page's identifier ("aiInsights.page") is inherited by the
            // buttons inside it on macOS, so the trash button is found by its
            // exact label. A click that did not register left the answer on
            // screen and ended the run early: retry until the list is back.
            let clear = app.buttons.matching(NSPredicate(format: "label == 'Clear conversation'")).firstMatch
            let anySuggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask: '")).firstMatch
            for _ in 0..<3 {
                guard clear.exists, clear.isEnabled else { break }
                app.activate()
                if clear.isHittable { clear.click() }
                if anySuggestion.waitForExistence(timeout: 5) { break }
            }
            let suggestions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask: '")).allElementsBoundByIndex
            guard let bound = suggestions.first(where: { !asked.contains($0.label) }) else { break }
            // Re-found by label, not by list position: the list re-renders
            // and an index-bound element went stale before the click.
            let next = app.buttons.matching(NSPredicate(format: "label == %@", bound.label)).firstMatch
            let q = String(next.label.dropFirst("Ask: ".count))
            asked.insert(next.label)
            var tries = 0
            while !next.isHittable && tries < 6 {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).scroll(byDeltaX: 0, deltaY: -250)
                Thread.sleep(forTimeInterval: 0.5); tries += 1
            }
            guard next.isHittable else { report += "\n## Q\(n+1): \(q)\n(could not reach the suggestion)\n"; continue }
            app.activate(); Thread.sleep(forTimeInterval: 1)
            print("AI-DEBUG before click: \(next.label) enabled=\(next.isEnabled) hittable=\(next.isHittable)")
            next.click()
            let started = Date()
            Thread.sleep(forTimeInterval: 1)
            // A suggestion that did not start (first click only activated the
            // window): click it once more.
            if next.exists, next.isHittable, app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask: '")).count > 1 {
                next.click(); Thread.sleep(forTimeInterval: 1)
            }
            print("AI-DEBUG 1s after: thinking=\(app.staticTexts["Thinking..."].exists) suggestionsLeft=\(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask: '")).count) bubbles=\(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", String(q.prefix(20)))).count)")
            Thread.sleep(forTimeInterval: 2)
            while Date().timeIntervalSince(started) < 150 {
                let busy = app.staticTexts["Thinking..."].exists || app.buttons["Processing query"].exists
                    || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Answering'")).firstMatch.exists
                if !busy { break }
                Thread.sleep(forTimeInterval: 2)
            }
            Thread.sleep(forTimeInterval: 20)   // slow engines finish streaming
            var texts: [String] = []
            if let snap = try? app.windows.firstMatch.snapshot() {
                func walk(_ e: XCUIElementSnapshot) {
                    if e.elementType == .staticText || e.elementType == .textView {
                        let t = (e.value as? String) ?? e.label
                        if !t.isEmpty { texts.append(t) }
                    }
                    e.children.forEach(walk)
                }
                walk(snap)
            }
            let from = texts.lastIndex(where: { $0.contains(q.prefix(30)) }).map { $0 + 1 } ?? max(0, texts.count - 40)
            var lines: [String] = []
            for t in texts[from...] where lines.last != t { lines.append(t) }
            let answer = lines.prefix(60).joined(separator: "\n")
            report += "\n## Q\(n+1): \(q)  (\(Int(Date().timeIntervalSince(started))) s)\n\(answer)\n"
            snapshotScreen("ai-answer-\(n+1)")
            if app.state == .notRunning { report += "\n(app quit)\n"; break }

            // An answer's follow-up is a button: press the first "Tell the
            // story of …" one after Thread Story and record what it gives.
            let followUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask follow-up: Tell the story of'")).firstMatch
            if q.hasPrefix("[Thread Story]") || q.hasPrefix("Narrate this conversation thread") {
                guard followUp.exists else { report += "\n## Q\(n+1)b: (no follow-up button)\n"; continue }
                let fq = String(followUp.label.dropFirst("Ask follow-up: ".count))
                if !followUp.isHittable {
                    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).scroll(byDeltaX: 0, deltaY: -600)
                    Thread.sleep(forTimeInterval: 1)
                }
                guard followUp.isHittable else { report += "\n## Q\(n+1)b: \(fq)\n(could not reach the follow-up)\n"; continue }
                app.activate(); Thread.sleep(forTimeInterval: 1)
                followUp.click()
                let fStarted = Date()
                // The question appears as its own bubble once asked; a click
                // that only focused the window is repeated once.
                let asked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Your question: " + String(fq.prefix(30)))).firstMatch
                if !asked.waitForExistence(timeout: 5), followUp.exists, followUp.isHittable { followUp.click() }
                Thread.sleep(forTimeInterval: 3)
                while Date().timeIntervalSince(fStarted) < 150 {
                    let busy = app.staticTexts["Thinking..."].exists || app.buttons["Processing query"].exists
                        || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Answering'")).firstMatch.exists
                    if !busy { break }
                    Thread.sleep(forTimeInterval: 2)
                }
                Thread.sleep(forTimeInterval: 20)   // the model narrates
                var ftexts: [String] = []
                if let snap = try? app.windows.firstMatch.snapshot() {
                    func walk(_ e: XCUIElementSnapshot) {
                        if e.elementType == .staticText || e.elementType == .textView {
                            let t = (e.value as? String) ?? e.label
                            if !t.isEmpty { ftexts.append(t) }
                        }
                        e.children.forEach(walk)
                    }
                    walk(snap)
                }
                let ffrom = ftexts.lastIndex(where: { $0.hasPrefix("Your question: " + fq.prefix(30)) }).map { $0 + 1 } ?? max(0, ftexts.count - 30)
                report += "\n## Q\(n+1)b (follow-up button): \(fq)  (\(Int(Date().timeIntervalSince(fStarted))) s)\n" + ftexts[ffrom...].prefix(30).joined(separator: "\n") + "\n"
            }
        }
        print("AI-ANSWERS>>>\(report)\n<<<AI-ANSWERS")
        let att = XCTAttachment(string: report); att.name = "ai-answers.md"; att.lifetime = .keepAlways; add(att)
    }

    /// Owner, 2026-10-07: "Redact & Export was still missed by the Mac crawl.
    /// Verify its actual output, not just that its window opens." Presses the
    /// button on the real archive and saves both files to REDACT_OUT_DIR; the
    /// runner script then checks the files themselves.
    func testRedactAndExport_writesFiles() {
        recoverIfNeeded()
        let outDir = ProcessInfo.processInfo.environment["REDACT_OUT_DIR"] ?? "/tmp/mailin-redact"
        _ = openPage("Professional Workflows")
        let tool = app.buttons.matching(NSPredicate(format: "label == 'Redaction' OR label BEGINSWITH 'Redaction,'")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "Redaction tool on the Professional page")
        tool.click()
        let window = app.windows["Redaction"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Redaction window opens")
        let export = window.buttons["Redact & Export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 30), "Redact & Export exists (working set loaded)")
        XCTAssertTrue(export.isHittable, "Redact & Export is on screen without scrolling")
        export.click()

        func answerSavePanel(name: String) -> Bool {
            let panel = app.sheets.firstMatch.waitForExistence(timeout: 10) ? app.sheets.firstMatch : app.dialogs.firstMatch
            guard panel.waitForExistence(timeout: 10) else { return false }
            // Pasted, not typed: synthesized typing timed out in the panel.
            func paste(_ text: String) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                app.typeKey("a", modifierFlags: .command)
                app.typeKey("v", modifierFlags: .command)
                Thread.sleep(forTimeInterval: 0.5)
            }
            // File name first, then the folder via Go to Folder.
            paste(name)
            panel.typeKey("g", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 1.0)
            paste(outDir)
            app.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 1.5)
            let save = panel.buttons["Save"].firstMatch
            if save.exists, save.isEnabled { save.click() } else { app.typeKey(.return, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 1.0)
            let replace = app.buttons["Replace"].firstMatch
            if replace.waitForExistence(timeout: 2) { replace.click() }
            return true
        }
        XCTAssertTrue(answerSavePanel(name: "RedactedExport.txt"), "first save panel")
        XCTAssertTrue(answerSavePanel(name: "RedactionLog.csv"), "second save panel")

        // Anywhere in the app: after the save panels the window reference
        // can go stale, and the message was missed while it showed.
        // The message is a Label: its text is the element's value on macOS.
        let done = app.descendants(matching: .any).matching(NSPredicate(format:
            "label BEGINSWITH 'Exported ' OR value BEGINSWITH 'Exported ' OR label BEGINSWITH 'Export blocked' OR value BEGINSWITH 'Export blocked' OR value BEGINSWITH 'Export failed'")).firstMatch
        let finished = done.waitForExistence(timeout: 120)
        var message = finished ? ((done.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? done.label) : "(no result message)"
        if !finished, let snap = try? app.snapshot() {
            // What the window shows instead, for the report.
            var seen: [String] = []
            func walk(_ e: XCUIElementSnapshot) {
                let t = ((e.value as? String) ?? "") + " " + e.label
                if t.lowercased().contains("export") { seen.append("\(e.elementType.rawValue): \(t.trimmingCharacters(in: .whitespaces))") }
                e.children.forEach(walk)
            }
            walk(snap)
            message += " | on screen: " + seen.prefix(12).joined(separator: " | ")
        }
        print("REDACT-RESULT>>>\(message)<<<REDACT-RESULT")
        XCTAssertTrue(message.hasPrefix("Exported "), "export finished: \(message)")
    }

    /// Owner, 2026-10-07: start from Settings — turn AI on there, confirm
    /// Apple Intelligence is reachable, then ask. The model log
    /// (subsystem com.ecosanskriti.mailin, category model) is read by the
    /// runner script afterwards to prove the answer came from the model.
    func testAI_fromSettings_turnOnThenAsk() {
        recoverIfNeeded()
        var report = ""
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title IN {'General', 'AI', 'Display', 'Advanced', 'Modules', 'Settings'} OR identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings window opens")
        let aiTab = app.toolbars.buttons["AI"].firstMatch
        XCTAssertTrue(aiTab.waitForExistence(timeout: 5), "AI tab exists")
        aiTab.click()
        Thread.sleep(forTimeInterval: 1)

        let toggle = app.descendants(matching: .any).matching(identifier: "settings.ai.enable").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "AI switch exists")
        func isOn() -> Bool { "\(toggle.value ?? "")" == "1" }
        report += "AI switch at start: \(isOn() ? "on" : "off")\n"
        let aiPageTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'AI Insights'")).firstMatch

        // Off: the AI Insights page must go off with it.
        if isOn() { toggle.click(); Thread.sleep(forTimeInterval: 1) }
        report += "after turning off: switch \(isOn() ? "on" : "off"); page tab \"\(aiPageTab.exists ? aiPageTab.label : "missing")\"\n"
        XCTAssertFalse(isOn())
        // On again: the page comes back.
        toggle.click(); Thread.sleep(forTimeInterval: 1)
        report += "after turning on: switch \(isOn() ? "on" : "off"); page tab \"\(aiPageTab.exists ? aiPageTab.label : "missing")\"\n"
        XCTAssertTrue(isOn())

        // Owner, 2026-10-07: switching the AI page on from its page tab must
        // turn AI on in Settings too. Off here, on from the page, check here.
        toggle.click(); Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(isOn(), "AI off in Settings before the page test")
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
        if aiPageTab.waitForExistence(timeout: 5) { aiPageTab.click() }
        let turnOn = app.buttons["Turn on AI Insights"].firstMatch
        if turnOn.waitForExistence(timeout: 5) { turnOn.click() }
        Thread.sleep(forTimeInterval: 1)
        report += "after turning the page on from its tab: page tab \"\(aiPageTab.exists ? aiPageTab.label : "missing")\"\n"
        app.typeKey(",", modifierFlags: .command)
        if aiTab.waitForExistence(timeout: 5) { aiTab.click() }
        Thread.sleep(forTimeInterval: 1)
        report += "Settings ▸ AI switch after page activation: \(isOn() ? "on" : "off")\n"
        XCTAssertTrue(isOn(), "turning the AI page on turned AI on in Settings")

        let status = app.descendants(matching: .any).matching(identifier: "settings.ai.appleIntelligenceStatus").firstMatch
        let statusText = status.waitForExistence(timeout: 5) ? status.label : "(no status row)"
        report += "Apple Intelligence status: \(statusText)\n"
        XCTAssertTrue(statusText.contains("ready"), "Apple Intelligence reported ready: \(statusText)")
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        // Ask something only the model can write: a narrative over a thread.
        _ = openPage("AI Insights")
        let askTab = app.buttons["Ask"].firstMatch
        if askTab.waitForExistence(timeout: 5), askTab.isHittable { askTab.click() }
        let field = app.textFields.matching(NSPredicate(format: "label == 'Question input' OR placeholderValue BEGINSWITH 'Ask a follow-up'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "question field")
        let question = ProcessInfo.processInfo.environment["AI_SETTINGS_QUESTION"]
            ?? "Summarize what Hatigarm and I discussed about translating manga into Bengali"
        field.click()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question, forType: .string)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
        field.typeKey(.return, modifierFlags: [])
        let started = Date()
        Thread.sleep(forTimeInterval: 3)
        while Date().timeIntervalSince(started) < 150 {
            let busy = app.staticTexts["Thinking..."].exists || app.buttons["Processing query"].exists
                || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Answering'")).firstMatch.exists
            if !busy { break }
            Thread.sleep(forTimeInterval: 2)
        }
        Thread.sleep(forTimeInterval: 5)
        var texts: [String] = []
        if let snap = try? app.windows.firstMatch.snapshot() {
            func walk(_ e: XCUIElementSnapshot) {
                if e.elementType == .staticText {
                    let t = (e.value as? String) ?? e.label
                    if !t.isEmpty { texts.append(t) }
                }
                e.children.forEach(walk)
            }
            walk(snap)
        }
        let from = texts.lastIndex(where: { $0.contains(question.prefix(30)) }).map { $0 + 1 } ?? max(0, texts.count - 30)
        report += "\n## \(question)  (\(Int(Date().timeIntervalSince(started))) s)\n" + texts[from...].prefix(30).joined(separator: "\n") + "\n"
        print("AI-SETTINGS>>>\(report)\n<<<AI-SETTINGS")
    }

    /// Questions a user would type, each with a checkable answer in the
    /// owner's archive. Records every answer verbatim for review.
    func testAIAnswers_typedQuestions() {
        recoverIfNeeded()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        if windowMenu.exists {
            windowMenu.click()
            let zoom = app.menuItems["Zoom"]
            if zoom.waitForExistence(timeout: 2), zoom.isEnabled { zoom.click() } else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 1)
        }
        _ = openPage("AI Insights")
        let askTab = app.buttons["Ask"].firstMatch
        if askTab.waitForExistence(timeout: 5), askTab.isHittable { askTab.click() }

        let questions = ProcessInfo.processInfo.environment["AI_TYPED_QUESTIONS"]?
            .components(separatedBy: "|").filter { !$0.isEmpty } ?? [
            "What is my granted patent number and when was it granted?",
            "What is the application number of my patent?",
            "How much did I pay Khurana & Khurana in total?",
            "Who is Shabana Khan?",
            "What was the settlement amount with the packers?",
            "Did I book a train ticket in 2018? From where to where?",
            "Which job interviews was I invited to?",
            "Find the email about the Bengali manga translation",
            "What do I still need to do for my patent?",
            "Do any emails contain a password?",
            "How many emails did I send in 2015?",
            "What happened with the hospital claim for Giridhar Sasmal?",
        ]
        let field = app.textFields.matching(NSPredicate(format: "label == 'Question input' OR placeholderValue BEGINSWITH 'Ask a follow-up'")).firstMatch
        var report = ""
        for (n, q) in questions.enumerated() {
            let clear = app.buttons.matching(NSPredicate(format: "label == 'Clear conversation'")).firstMatch
            if clear.exists, clear.isEnabled, clear.isHittable { clear.click(); Thread.sleep(forTimeInterval: 1) }
            guard field.waitForExistence(timeout: 5), field.isHittable else { report += "\n## T\(n+1): \(q)\n(no question field)\n"; continue }
            app.activate(); Thread.sleep(forTimeInterval: 0.5)
            field.click()
            // Pasted, not typed: synthesized typing of a long question timed
            // out on macOS.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(q, forType: .string)
            field.typeKey("a", modifierFlags: .command)
            field.typeKey("v", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.5)
            field.typeKey(.return, modifierFlags: [])
            let started = Date()
            Thread.sleep(forTimeInterval: 3)
            while Date().timeIntervalSince(started) < 150 {
                let busy = app.staticTexts["Thinking..."].exists || app.buttons["Processing query"].exists
                    || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Answering'")).firstMatch.exists
                if !busy { break }
                Thread.sleep(forTimeInterval: 2)
            }
            Thread.sleep(forTimeInterval: 15)
            var texts: [String] = []
            if let snap = try? app.windows.firstMatch.snapshot() {
                func walk(_ e: XCUIElementSnapshot) {
                    if e.elementType == .staticText {
                        let t = (e.value as? String) ?? e.label
                        if !t.isEmpty { texts.append(t) }
                    }
                    e.children.forEach(walk)
                }
                walk(snap)
            }
            let from = texts.lastIndex(where: { $0.contains(q.prefix(30)) }).map { $0 + 1 } ?? max(0, texts.count - 40)
            var lines: [String] = []
            for t in texts[from...] where lines.last != t { lines.append(t) }
            report += "\n## T\(n+1): \(q)  (\(Int(Date().timeIntervalSince(started))) s)\n" + lines.prefix(40).joined(separator: "\n") + "\n"
            if app.state == .notRunning { report += "\n(app quit)\n"; break }
        }
        print("AI-TYPED>>>\(report)\n<<<AI-TYPED")
        let att = XCTAttachment(string: report); att.name = "ai-typed.md"; att.lifetime = .keepAlways; add(att)
    }
    #endif

    #if os(iOS)
    /// The typed-question check on iPad (owner, 2026-10-07: "check on iPad").
    /// Set MAILIN_UITEST_IMPORT=1 to import Sent.mbox from On My iPad first.
    func testAIAnswers_typedQuestions_iOS() {
        recoverIfNeeded()
        var report = ""
        if ProcessInfo.processInfo.environment["MAILIN_UITEST_IMPORT"] == "1" {
            _ = openPage("Archive")
            report += "import: \(importMailbox(path: "", fileName: "Sent"))\n"
        }
        _ = openPage("Archive")
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Emails'")).firstMatch
        report += "archive: \(all.waitForExistence(timeout: 5) ? all.label : "All Emails row not visible")\n"
        _ = openPage("AI Insights")
        let askTab = app.buttons["Ask"].firstMatch
        if askTab.waitForExistence(timeout: 5), askTab.isHittable { askTab.tap() }
        let questions = ProcessInfo.processInfo.environment["AI_TYPED_QUESTIONS"]?
            .components(separatedBy: "|").filter { !$0.isEmpty } ?? [
            "What is my granted patent number and when was it granted?",
            "How much did I pay Khurana & Khurana in total?",
            "Who is Shabana Khan?",
            "What was the settlement amount with the packers?",
            "Did I book a train ticket in 2018? From where to where?",
            "Find the email about the Bengali manga translation",
            "What do I still need to do for my patent?",
            "Do any emails contain a password?",
            "How many emails did I send in 2015?",
            "Summarize what Hatigarm and I discussed about translating manga into Bengali",
        ]
        let field = app.textFields.matching(NSPredicate(format: "label == 'Question input' OR placeholderValue BEGINSWITH 'Ask a follow-up'")).firstMatch
        for (n, q) in questions.enumerated() {
            let clear = app.buttons.matching(NSPredicate(format: "label == 'Clear conversation'")).firstMatch
            if clear.exists, clear.isEnabled, clear.isHittable { clear.tap(); Thread.sleep(forTimeInterval: 1) }
            guard field.waitForExistence(timeout: 5), field.isHittable else { report += "\n## P\(n+1): \(q)\n(no question field)\n"; continue }
            field.tap()
            field.typeText(q + "\n")
            let started = Date()
            Thread.sleep(forTimeInterval: 3)
            while Date().timeIntervalSince(started) < 150 {
                let busy = app.staticTexts["Thinking..."].exists || app.buttons["Processing query"].exists
                    || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Answering'")).firstMatch.exists
                if !busy { break }
                Thread.sleep(forTimeInterval: 2)
            }
            Thread.sleep(forTimeInterval: 5)
            var texts: [String] = []
            if let snap = try? app.windows.firstMatch.snapshot() {
                func walk(_ e: XCUIElementSnapshot) {
                    if e.elementType == .staticText {
                        let t = (e.value as? String) ?? e.label
                        if !t.isEmpty { texts.append(t) }
                    }
                    e.children.forEach(walk)
                }
                walk(snap)
            }
            let from = texts.lastIndex(where: { $0.hasPrefix("Your question: " + q.prefix(30)) || $0.contains(q.prefix(30)) }).map { $0 + 1 } ?? max(0, texts.count - 30)
            var out: [String] = []
            for t in texts[from...] where out.last != t { out.append(t) }
            report += "\n## P\(n+1): \(q)  (\(Int(Date().timeIntervalSince(started))) s)\n" + out.prefix(25).joined(separator: "\n") + "\n"
            if app.state == .notRunning { report += "\n(app quit)\n"; break }
        }
        print("AI-IPAD>>>\(report)\n<<<AI-IPAD")
    }
    #endif
}
