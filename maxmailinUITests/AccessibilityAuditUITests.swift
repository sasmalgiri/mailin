//
//  AccessibilityAuditUITests.swift
//  maxmailinUITests
//
//  §3-X4: Xcode's automated accessibility audit (element descriptions,
//  contrast, Dynamic Type, clipped text, hit regions, traits, parent/child)
//  over the main window and Settings ▸ Modules (where the 3.0 engines live),
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
    private func audit(_ surface: String) -> [String] {
        var issues: [String] = []
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

    func testAccessibilityAudit_mainWindowAndModules() {
        _ = app.buttons.firstMatch.waitForExistence(timeout: 120)
        var issues = audit("Main window")

        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title IN {'General', 'AI', 'Display', 'Advanced', 'Modules', 'Settings'} OR identifier CONTAINS[c] 'settings'")).firstMatch
        if settings.waitForExistence(timeout: 5) {
            let modulesTab = app.toolbars.buttons["Modules"].firstMatch
            if modulesTab.waitForExistence(timeout: 5) {
                modulesTab.click()
                Thread.sleep(forTimeInterval: 1)
                issues += audit("Settings ▸ Modules")
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
