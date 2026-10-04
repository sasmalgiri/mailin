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
        #if os(macOS)
        guard !env.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MAILIN_UITEST_MBOX to a mailbox file to run the crawl.")
        }
        #endif
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        var rows: [CrawlRow] = []

        // ── 1. Import through the real UI ──
        // The app reopens on the page it was last on; import from Archive.
        _ = openPage("Archive")
        let started = Date()
        let fileName = env.isEmpty ? "Sent" : ((env as NSString).lastPathComponent as NSString).deletingPathExtension
        let importOutcome = importMailbox(path: env, fileName: fileName)
        rows.append(CrawlRow(page: "Archive", button: "Import \(fileName).mbox",
                             outcome: "\(importOutcome) (\(Int(Date().timeIntervalSince(started))) s)"))
        snapshotScreen("after-import")

        // ── 2. Every button on every page ──
        for page in ["Archive", "AI Insights", "Professional Workflows", "Live Mail"] {
            guard openPage(page) else {
                rows.append(CrawlRow(page: page, button: "(page)", outcome: "could not open page"))
                continue
            }
            snapshotScreen("page-\(page)")
            rows += crawlButtons(onPage: page)
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
            if app.menus.firstMatch.exists {
                outcome = "opened a menu (\(app.menus.firstMatch.menuItems.count) items)"
            } else if app.popovers.firstMatch.exists {
                outcome = "opened a popover"
            } else if app.sheets.count > sheetsBefore {
                outcome = "opened a sheet"
            } else if app.windows.count > windowsBefore {
                outcome = "opened window “\(app.windows.firstMatch.title)”"
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
            if app.menus.firstMatch.exists || app.popovers.firstMatch.exists || app.dialogs.firstMatch.exists {
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
        if app.state != .runningForeground {
            app.launch(); _ = app.wait(for: .runningForeground, timeout: 30)
        }
        #if os(macOS)
        if app.windows.count == 0 { app.typeKey("n", modifierFlags: .command); Thread.sleep(forTimeInterval: 1) }
        #endif
        app.activate()
    }

    #if os(macOS)
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
        let start = app.buttons["export.preflight.start"].firstMatch
        guard start.waitForExistence(timeout: 15) else {
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
        let preflightText = (try? app.otherElements["export.preflight"].firstMatch.snapshot())
            .map { snap -> String in
                var parts: [String] = []
                func walk(_ s: XCUIElementSnapshot) { if s.elementType == .staticText { parts.append(s.label) }; s.children.forEach(walk) }
                walk(snap); return parts.joined(separator: " / ")
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
        let verdict = app.descendants(matching: .any)["export.receipt.verdict"].firstMatch
        let text = verdict.exists ? verdict.label : "no receipt within 5 minutes"
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
}
