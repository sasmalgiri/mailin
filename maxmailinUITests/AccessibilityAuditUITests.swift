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
                let element = issue.element.map { "\($0.elementType.rawValue) “\($0.label)” id=\($0.identifier)" } ?? "—"
                issues.append("\(surface): \(issue.compactDescription) — \(element)")
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

        let report = issues.isEmpty ? "No accessibility issues." : issues.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "Accessibility audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(issues.isEmpty, "accessibility audit:\n\(report)")
    }
}
