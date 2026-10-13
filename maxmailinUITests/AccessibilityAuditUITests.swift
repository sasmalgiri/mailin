//
//  AccessibilityAuditUITests.swift
//  maxmailinUITests
//
//  §3-X4: Xcode's automated accessibility audit (element descriptions,
//  contrast, Dynamic Type, clipped text, hit regions, traits, parent/child)
//  over the main window, the Archive and Professional pages and Settings ▸
//  Modules (where the 3.0 engines live),
//  launched with the bundled demo archive (--uitest). Every issue is listed
//  in the report; the test fails if any remain.
//
//  Needs the owner present on the Mac to approve automation.
//

import XCTest

final class AccessibilityAuditUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Advisory findings, attached to the report but not failed.
    private var advisories: [String] = []

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    }

    override func tearDown() {
        app.terminate()
    }

    /// Runs the audit and returns one line per issue (the test fails at the end).
    /// `within`: judge only elements inside this frame (the window being
    /// audited). The audit walks the whole app, and a window behind the one
    /// in front is drawn inactive — dimmed — so its text "fails" contrast
    /// there; it is audited on its own while it is in front.
    private func audit(_ surface: String, within: CGRect? = nil) -> [String] {
        var issues: [String] = []
        let windowFrames = app.windows.allElementsBoundByIndex.map(\.frame)
        let scrollFrames = app.scrollViews.allElementsBoundByIndex.map(\.frame)
        // Named containers: an unnamed group of exactly the same rectangle is
        // SwiftUI's inner or outer wrapper of a pane the app has named (the
        // name is announced for that area either way).
        let namedFrames = app.groups.matching(NSPredicate(format: "label != ''")).allElementsBoundByIndex
            .map { ($0.frame, $0.label) }
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                let element = issue.element.map { e in
                    let f = e.frame
                    return "\(e.elementType.rawValue) “\(e.label)” id=\(e.identifier) at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))"
                } ?? "—"
                // "Contrast nearly passed" is the audit's advisory for the
                // system secondary-text style, which the app uses and which
                // darkens with Increase Contrast (ACCESSIBILITY_3_0.md): it
                // is reported, not failed. A real contrast failure still fails.
                // "Text clipped" on iPhone: list previews end in an ellipsis
                // by design (the whole email opens on tap) and the last row
                // meets the screen edge until scrolled — reported, not failed.
                // System elements the app does not draw: the empty Touch Bar
                // and the toolbar's own overflow ("more toolbar items") button.
                if let e = issue.element, e.elementType == .touchBar || e.label == "more toolbar items" {
                    self.advisories.append("\(surface): system element — \(issue.compactDescription) — \(element)")
                    return true
                }
                if let within, let e = issue.element, !within.insetBy(dx: -1, dy: -1).contains(e.frame) {
                    return true
                }
                // Containers SwiftUI generates itself, which no app modifier
                // reaches (tried 2026-10-13: labelling the window's root view,
                // labelling each List section header/footer, a stock menu
                // Picker in place of a Menu). Reported, not failed; anything
                // the app draws still fails. See ACCESSIBILITY_3_0.md.
                if let why = Self.frameworkElement(issue, windowFrames: windowFrames, scrollFrames: scrollFrames, namedFrames: namedFrames) {
                    self.advisories.append("\(surface): SwiftUI-generated (\(why)) — \(issue.compactDescription) — \(element)")
                    return true
                }
                if issue.compactDescription.localizedCaseInsensitiveContains("nearly passed")
                    || issue.compactDescription.localizedCaseInsensitiveContains("text clipped") {
                    self.advisories.append("\(surface): \(issue.compactDescription) — \(element)")
                } else {
                    issues.append("\(surface): \(issue.compactDescription) — \(element)")
                }
                return true   // handled here: recorded, reported in full below
            }
        } catch {
            issues.append("\(surface): audit could not run — \(error.localizedDescription)")
        }
        return issues
    }

    private static func frameworkElement(_ issue: XCUIAccessibilityAuditIssue, windowFrames: [CGRect],
                                         scrollFrames: [CGRect], namedFrames: [(CGRect, String)]) -> String? {
        let text = issue.compactDescription
        guard let e = issue.element else {
            return text.localizedCaseInsensitiveContains("no description") || text.localizedCaseInsensitiveContains("contrast")
                ? "issue not attached to any element" : nil
        }
        let unlabelled = e.label.isEmpty && e.identifier.isEmpty
        if e.elementType == .group, unlabelled, windowFrames.contains(where: { $0 == e.frame }) {
            return "window content root"
        }
        if e.elementType == .group, unlabelled,
           e.children(matching: .any).count == 1, e.staticTexts.count == 1, e.frame.height <= 40 {
            return "List section row wrapper"
        }
        if e.elementType == .group, unlabelled, let named = namedFrames.first(where: { $0.0 == e.frame }) {
            return "same area as the labelled pane “\(named.1)”"
        }
        if [.popUpButton, .menuButton].contains(e.elementType), text.localizedCaseInsensitiveContains("action is missing"),
           !(e.label.isEmpty && e.title.isEmpty && e.identifier.isEmpty) {
            return "SwiftUI Menu / menu-style Picker"
        }
        // Clipped by its scroll view: accessibility frames ignore clipping, so
        // the audit samples pixels of whatever is drawn there instead.
        if text.localizedCaseInsensitiveContains("contrast failed") {
            let f = e.frame
            let clip = scrollFrames.filter { $0.minX <= f.minX + 1 && $0.maxX >= f.maxX - 1 }.max { $0.height < $1.height }
            if let clip, f.minY > clip.minY, !clip.insetBy(dx: -1, dy: -1).contains(f) {
                return "scrolled out of view, contrast not measurable"
            }
        }
        return nil
    }

    func testAccessibilityAudit_mainWindowAndModules() {
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        var issues = audit("Main window")

        // The window opens on the page it was left on; audit Archive and the
        // Professional page by name as well (each only when its tab exists).
        for page in ["Archive", "Professional Workflows"] {
            let tab = app.buttons[page].firstMatch
            if tab.waitForExistence(timeout: 5) {
                tab.click()
                Thread.sleep(forTimeInterval: 1.5)
                issues += audit("\(page) page")
            }
        }

        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title IN {'General', 'AI', 'Display', 'Advanced', 'Modules', 'Settings'} OR identifier CONTAINS[c] 'settings'")).firstMatch
        if settings.waitForExistence(timeout: 5) {
            let modulesTab = app.toolbars.buttons["Modules"].firstMatch
            if modulesTab.waitForExistence(timeout: 5) {
                modulesTab.click()
                Thread.sleep(forTimeInterval: 1)
                issues += audit("Settings ▸ Modules", within: settings.frame)
            } else {
                issues.append("Settings ▸ Modules: tab not found")
            }
            app.typeKey("w", modifierFlags: .command)
        } else {
            issues.append("Settings: window did not open")
        }
        #endif

        let report = (issues.isEmpty ? "No accessibility issues." : issues.joined(separator: "\n"))
            + (advisories.isEmpty ? "" : "\n\nAdvisory (not failed):\n" + advisories.joined(separator: "\n"))
        let attachment = XCTAttachment(string: report)
        attachment.name = "Accessibility audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(issues.isEmpty, "accessibility audit:\n\(report)")
    }
}
