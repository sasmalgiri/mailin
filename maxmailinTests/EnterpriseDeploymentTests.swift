@testable import ArchiveCore
//
//  EnterpriseDeploymentTests.swift
//  maxmailinTests
//
//  V3_0_PRIVATE_PLAN §4 D1/D2: the no-network edition excludes Live Mail
//  structurally, a stale state file cannot resurrect it, and a managed
//  policy hard-off applies without a relaunch and cannot be overridden.
//

import XCTest
@testable import maxmailin

@MainActor
final class EnterpriseDeploymentTests: XCTestCase {

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("modules-\(UUID().uuidString).json")
    }

    // MARK: D1 — edition exclusion

    func testNoNetworkBuildExcludesLiveMail() {
        XCTAssertTrue(ModuleRegistry.buildExclusions.contains(.liveMail),
                      "this configuration defines NO_NETWORK_BUILD, so Live Mail is not in the edition")
    }

    func testExcludedPageIsUnavailableAndCannotBeEnabled() {
        let modules = ModuleRegistry(store: ModuleStateStore(url: storeURL()), excludedByBuild: [.liveMail], trapsOnMisuse: false)
        XCTAssertEqual(modules.activation(.liveMail), .unavailable(reason: "not included in this edition"))
        XCTAssertFalse(modules.isEnabled(.liveMail))
        XCTAssertThrowsError(try modules.enable(.liveMail))
    }

    func testStaleStateFileWithLiveMailOnRendersUnavailable() throws {
        // A state file from a public build that had Live Mail switched on.
        let url = storeURL()
        var state = ModuleState()
        state.set(.liveMail, enabled: true)
        state.didMapLegacyDefaults = true
        ModuleStateStore(url: url).save(state)

        let modules = ModuleRegistry(store: ModuleStateStore(url: url), excludedByBuild: [.liveMail], trapsOnMisuse: false)
        XCTAssertEqual(modules.activation(.liveMail), .unavailable(reason: "not included in this edition"))
        XCTAssertFalse(modules.enabledModules.contains(.liveMail), "a stored on must never render as on in an edition that excludes the page")
    }

    // MARK: D2 — managed configuration

    func testManagedDisabledModuleIsHardOffWithoutRelaunch() throws {
        let defaults = UserDefaults.standard
        let original = defaults.dictionary(forKey: ManagedConfig.managedDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: ManagedConfig.managedDefaultsKey) }
            else { defaults.removeObject(forKey: ManagedConfig.managedDefaultsKey) }
        }
        let modules = ModuleRegistry(store: ModuleStateStore(url: storeURL()), excludedByBuild: [], trapsOnMisuse: false)
        try modules.enable(.professional)
        XCTAssertTrue(modules.isEnabled(.professional))

        // Policy arrives after launch.
        defaults.set(["orgName": "Test Org", "disabledModules": ["professional"]], forKey: ManagedConfig.managedDefaultsKey)
        modules.reloadPolicy()
        XCTAssertEqual(modules.activation(.professional), .unavailable(reason: "disabled by your organization"))
        XCTAssertFalse(modules.isEnabled(.professional), "the org's off wins over the user's on")
        XCTAssertThrowsError(try modules.enable(.professional), "the user cannot re-enable an org-disabled page")

        // Unknown names and wrong types are ignored, never a crash.
        defaults.set(["disabledModules": ["noSuchPage", 42]], forKey: ManagedConfig.managedDefaultsKey)
        modules.reloadPolicy()
        XCTAssertNotEqual(modules.activation(.professional), .unavailable(reason: "disabled by your organization"))
    }

    func testManagedExaminerNameWinsWhenSealing() throws {
        let defaults = UserDefaults.standard
        let original = defaults.dictionary(forKey: ManagedConfig.managedDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: ManagedConfig.managedDefaultsKey) }
            else { defaults.removeObject(forKey: ManagedConfig.managedDefaultsKey) }
        }
        defaults.set(["examinerName": "Org Examiner"], forKey: ManagedConfig.managedDefaultsKey)
        let receipt = try ReceiptSealer.seal(text: "content", sealedBy: "Local Name")
        XCTAssertEqual(receipt.sealedBy, "Org Examiner", "org identity is policy")
        XCTAssertEqual(ReceiptSealer.verify(text: "content", receipt: receipt), .valid)
        XCTAssertNotEqual(ReceiptSealer.verify(text: "content!", receipt: receipt), .valid)
    }
}
