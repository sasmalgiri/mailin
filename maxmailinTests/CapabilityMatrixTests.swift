//
//  CapabilityMatrixTests.swift
//  maxmailinTests
//
//  The three properties the on/off matrix has to have, plus one migration
//  hazard that would otherwise have cost users their page settings on upgrade.
//
//  NOT YET EXECUTED — written under an instruction to implement first and test
//  afterwards.
//

import XCTest
@testable import maxmailin

@MainActor
final class CapabilityMatrixTests: XCTestCase {

    private func freshRegistry() -> ModuleRegistry {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modules-\(UUID().uuidString).json")
        return ModuleRegistry(store: ModuleStateStore(url: url),
                              excludedByBuild: [],
                              trapsOnMisuse: false)
    }

    /// The registries above are throwaway, but the flags they PUSH are
    /// process-global — that is the whole point of `CapabilityWiring`. Without
    /// this teardown, `testCapabilityIsOffWhileItsPageIsOff` left the AI
    /// model gate installed (it ends with AI Insights enabled), so every later
    /// test in the suite ran with archive analytics calling the on-device
    /// language model. That surfaced as
    /// `testFullAnalytics_streamingEqualsArrayOracle` reporting message body
    /// text as a language name — a failure four files away from its cause.
    override func tearDown() async throws {
        CapabilityWiring.resetAll()
    }

    // MARK: - Rule 1: a capability can never outlive its page

    /// The invariant the whole layer rests on. A stored "on" flag for an AI
    /// capability must not be able to resurrect AI work on a Page-1-only
    /// install — otherwise the page-independence rules are only as strong as
    /// the capability table.
    func testCapabilityIsOffWhileItsPageIsOff() throws {
        let registry = freshRegistry()

        try registry.enable(.aiInsights)
        registry.set(.aiAssistant, enabled: true)
        XCTAssertTrue(registry.isOn(.aiAssistant))

        // The stored switch stays on — the user's choice is theirs — but the
        // capability must not run.
        registry.disable(.aiInsights)
        XCTAssertFalse(registry.isOn(.aiAssistant),
                       "a capability must not run while its page is off")
        XCTAssertTrue(registry.switchPosition(.aiAssistant),
                      "the switch position must be preserved, not silently flipped")
        XCTAssertEqual(registry.block(.aiAssistant), .pageOff(.aiInsights),
                       "the reason must be attributable, not an unexplained inert row")

        try registry.enable(.aiInsights)
        XCTAssertTrue(registry.isOn(.aiAssistant),
                      "re-enabling the page must restore the capability unchanged")
    }

    /// Archive capabilities are governed by the switch alone, because Page 1
    /// cannot be switched off.
    func testArchiveCapabilitiesNeedNoPageCheck() {
        let registry = freshRegistry()
        XCTAssertTrue(registry.isEnabled(.archive))
        registry.set(.searchCoverageBadge, enabled: true)
        XCTAssertTrue(registry.isOn(.searchCoverageBadge))
        registry.set(.searchCoverageBadge, enabled: false)
        XCTAssertFalse(registry.isOn(.searchCoverageBadge))
        XCTAssertEqual(registry.block(.searchCoverageBadge), .switchedOff)
    }

    // MARK: - Rule 2: new and unproven ships OFF

    /// The point of the whole exercise: installing this build must not change
    /// how an archive behaves until someone asks.
    func testUnprovenEnginesAreOffByDefault() {
        let registry = freshRegistry()
        for capability in [Capability.offsetParser, .locatorReads, .blobTier,
                           .externalStorage, .guidedImport, .importQueue] {
            XCTAssertFalse(capability.defaultsOn,
                           "\(capability.rawValue) is unproven and must default off")
            XCTAssertFalse(registry.isOn(capability),
                           "\(capability.rawValue) must be off on a fresh install")
        }
    }

    /// And everything that already shipped keeps working without the user
    /// having to go and switch it on.
    func testEstablishedFeaturesAreOnByDefault() throws {
        let registry = freshRegistry()
        try registry.enable(.professional)
        for capability in [Capability.batesNumbering, .redaction, .auditTrail,
                           .reasoningStudios, .custodianPanel] {
            XCTAssertTrue(capability.defaultsOn, "\(capability.rawValue) already shipped")
            XCTAssertTrue(registry.isOn(capability),
                          "\(capability.rawValue) must keep working without being re-enabled")
        }
    }

    /// Maturity must line up with the default, or the badge in the matrix lies
    /// about what will happen.
    func testMaturityAndDefaultAgree() {
        for capability in Capability.allCases {
            switch capability.maturity {
            case .stable:
                XCTAssertTrue(capability.defaultsOn, "\(capability.rawValue)")
            case .preview, .experimental:
                XCTAssertFalse(capability.defaultsOn, "\(capability.rawValue)")
            }
        }
    }

    // MARK: - Rule 3: dependencies are honoured and explained

    func testDependencyOffTurnsTheDependentOff() {
        let registry = freshRegistry()
        registry.set(.blobTier, enabled: true)
        registry.set(.offsetParser, enabled: true)
        registry.set(.locatorReads, enabled: true)
        XCTAssertTrue(registry.isOn(.locatorReads))

        registry.set(.offsetParser, enabled: false)
        XCTAssertFalse(registry.isOn(.locatorReads),
                       "byte-range reads are meaningless without the offset index")
        XCTAssertEqual(registry.block(.locatorReads), .dependencyOff(.offsetParser),
                       "the matrix must be able to name the responsible dependency")
        XCTAssertTrue(registry.switchPosition(.locatorReads),
                      "the dependent's own switch is untouched")
    }

    /// Transitively: the offset parser needs somewhere to put a message too
    /// large to be a row, so turning off the blob tier disables both.
    func testDependencyChainIsTransitive() {
        let registry = freshRegistry()
        registry.set(.blobTier, enabled: true)
        registry.set(.offsetParser, enabled: true)
        registry.set(.locatorReads, enabled: true)

        registry.set(.blobTier, enabled: false)
        XCTAssertFalse(registry.isOn(.offsetParser))
        XCTAssertFalse(registry.isOn(.locatorReads),
                       "a dependency two links away must still disable this")
    }

    /// No cycles — a cycle would make `isOn` recurse forever.
    func testDependencyGraphIsAcyclic() {
        for capability in Capability.allCases {
            var seen: Set<Capability> = [capability]
            var frontier = capability.requires
            var depth = 0
            while !frontier.isEmpty {
                depth += 1
                XCTAssertLessThan(depth, Capability.allCases.count + 1,
                                  "dependency cycle reachable from \(capability.rawValue)")
                var next: [Capability] = []
                for item in frontier {
                    XCTAssertFalse(seen.contains(item),
                                   "dependency cycle: \(capability.rawValue) → \(item.rawValue)")
                    seen.insert(item)
                    next += item.requires
                }
                frontier = next
            }
        }
    }

    /// A dependency must belong to the same page, or enabling a page could not
    /// make its own capabilities work.
    func testDependenciesStayWithinTheSamePage() {
        for capability in Capability.allCases {
            for dependency in capability.requires {
                XCTAssertEqual(dependency.owner, capability.owner,
                               "\(capability.rawValue) depends on \(dependency.rawValue) from another page")
            }
        }
    }

    // MARK: - Nothing is lost

    /// Every capability has to state what happens to existing work when it is
    /// switched off, and none of those statements may describe deletion. This
    /// is the actual requirement, enforced as a property of the type.
    func testEveryCapabilityExplainsWhatSurvivesBeingSwitchedOff() {
        for capability in Capability.allCases {
            let text = capability.whenOff
            XCTAssertFalse(text.isEmpty, "\(capability.rawValue) must say what happens when off")
            for word in ["delete", "deleted", "destroy", "erase", "discard"] {
                XCTAssertFalse(text.lowercased().contains(word),
                               "\(capability.rawValue): switching off must not describe loss — “\(text)”")
            }
        }
    }

    /// Experimental capabilities must carry a warning; a maturity badge alone
    /// is not a sentence the user can act on.
    func testExperimentalCapabilitiesWarn() {
        for capability in Capability.allCases where capability.maturity == .experimental {
            XCTAssertNotNil(capability.warning,
                            "\(capability.rawValue) is experimental and must explain the risk")
        }
    }

    // MARK: - Reset

    func testResetReturnsToTheShippedDefault() {
        let registry = freshRegistry()
        XCTAssertFalse(registry.hasExplicitChoice(.offsetParser))

        registry.set(.offsetParser, enabled: true)
        XCTAssertTrue(registry.hasExplicitChoice(.offsetParser))
        XCTAssertTrue(registry.switchPosition(.offsetParser))

        registry.resetToDefault(.offsetParser)
        XCTAssertFalse(registry.hasExplicitChoice(.offsetParser))
        XCTAssertEqual(registry.switchPosition(.offsetParser),
                       Capability.offsetParser.defaultsOn)
    }

    // MARK: - Persistence and the v1 → v2 migration hazard

    /// The hazard worth its own test: Swift's synthesized decoder does NOT
    /// fall back to a property's default for a missing key — it throws. A v1
    /// state file has no `capabilities` key, so a synthesized decoder would
    /// fail, the store would return a fresh state, and every optional page the
    /// user had enabled would silently switch off on upgrade.
    func testV1StateFileUpgradesWithoutLosingEnabledPages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modules-v1-\(UUID().uuidString).json")
        let v1 = """
        {
          "version": 1,
          "enabled": { "aiInsights": true, "professional": true },
          "didMapLegacyDefaults": true
        }
        """
        try Data(v1.utf8).write(to: url)

        let registry = ModuleRegistry(store: ModuleStateStore(url: url),
                                      excludedByBuild: [], trapsOnMisuse: false)
        XCTAssertTrue(registry.isEnabled(.aiInsights),
                      "an upgrade must not switch off a page the user had enabled")
        XCTAssertTrue(registry.isEnabled(.professional))
        XCTAssertFalse(registry.isEnabled(.liveMail))
        // With no stored capability choices every capability is at its
        // default — exactly the behaviour the v1 build had.
        XCTAssertTrue(registry.isOn(.batesNumbering))
        XCTAssertFalse(registry.isOn(.offsetParser))
    }

    /// A capability added by a LATER build must arrive at its own default, not
    /// be silently disabled by an older state file that has no key for it.
    func testUnknownCapabilityKeyDoesNotDisableOthers() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modules-partial-\(UUID().uuidString).json")
        let partial = """
        {
          "version": 2,
          "enabled": { "professional": true },
          "capabilities": { "redaction": false },
          "didMapLegacyDefaults": true
        }
        """
        try Data(partial.utf8).write(to: url)

        let registry = ModuleRegistry(store: ModuleStateStore(url: url),
                                      excludedByBuild: [], trapsOnMisuse: false)
        XCTAssertFalse(registry.isOn(.redaction), "the explicit choice must be honoured")
        XCTAssertTrue(registry.isOn(.batesNumbering),
                      "a capability with no stored key must use its default, not off")
    }

    func testChoicesSurviveARestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modules-persist-\(UUID().uuidString).json")
        let first = ModuleRegistry(store: ModuleStateStore(url: url),
                                   excludedByBuild: [], trapsOnMisuse: false)
        first.set(.offsetParser, enabled: true)
        first.set(.searchCoverageBadge, enabled: false)

        let reopened = ModuleRegistry(store: ModuleStateStore(url: url),
                                      excludedByBuild: [], trapsOnMisuse: false)
        XCTAssertTrue(reopened.switchPosition(.offsetParser))
        XCTAssertFalse(reopened.switchPosition(.searchCoverageBadge))
    }

    // MARK: - The two enums must not drift

    /// Every page-owned sheet gate has a matching matrix switch. Without this
    /// a new `OwnedFeature` would be ungated by the matrix and silently
    /// un-switchable.
    func testOwnedFeaturesAllMapToACapability() {
        for feature in AppStateManager.OwnedFeature.allCases {
            let capability = feature.capability
            XCTAssertNotNil(capability,
                            "OwnedFeature.\(feature.rawValue) has no matching Capability")
            XCTAssertEqual(capability?.owner, feature.module,
                           "OwnedFeature.\(feature.rawValue) and its capability disagree about the owning page")
        }
    }

    /// Live Mail ships nothing in this build — its features are
    /// `.notInThisBuild` — so offering switches for them would be offering
    /// switches that cannot work.
    func testEveryCapabilityHasAnOwnerAndLiveMailOwnsNone() {
        XCTAssertTrue(Capability.all(for: .liveMail).isEmpty,
                      "Live Mail ships nothing in this build, so it must own no switches")
        for module in [AppModule.archive, .aiInsights, .professional] {
            XCTAssertFalse(Capability.all(for: module).isEmpty,
                           "\(module.rawValue) should own at least one capability")
        }
    }

    /// Raw values are persistence keys: a rename silently reverts a user's
    /// choice to the default, which for an experimental capability means
    /// silently turning it ON. Pinned so a rename fails here first.
    func testPersistenceKeysArePinned() {
        XCTAssertEqual(Capability.offsetParser.rawValue, "offsetParser")
        XCTAssertEqual(Capability.locatorReads.rawValue, "locatorReads")
        XCTAssertEqual(Capability.blobTier.rawValue, "blobTier")
        XCTAssertEqual(Capability.guidedImport.rawValue, "guidedImport")
        XCTAssertEqual(Capability.importQueue.rawValue, "importQueue")
        XCTAssertEqual(Capability.externalStorage.rawValue, "externalStorage")
        XCTAssertEqual(Capability.searchCoverageBadge.rawValue, "searchCoverageBadge")
        XCTAssertEqual(Set(Capability.allCases.map(\.rawValue)).count,
                       Capability.allCases.count,
                       "two capabilities share a persistence key")
    }

    // MARK: - The "switched on but inert" summary

    /// `blockedCapabilities()` is what the matrix's banner reports. It must
    /// name a dependency-blocked capability and its cause — a switch left on
    /// while something it needs is off is the case a user cannot diagnose
    /// without being told.
    func testBlockedCapabilitiesNamesTheDependencyThatStoppedIt() {
        let registry = freshRegistry()
        registry.set(.blobTier, enabled: true)
        registry.set(.offsetParser, enabled: true)
        registry.set(.locatorReads, enabled: true)
        // Scoped to this chain: a fresh registry has the optional pages off,
        // so THEIR defaults-on capabilities are legitimately blocked already.
        let chain: Set<Capability> = [.blobTier, .offsetParser, .locatorReads]
        XCTAssertTrue(registry.blockedCapabilities().allSatisfy { !chain.contains($0.capability) },
                      "nothing in this chain is blocked while all of it is on")

        registry.set(.offsetParser, enabled: false)
        let blocked = registry.blockedCapabilities()
        XCTAssertEqual(blocked.first(where: { $0.capability == .locatorReads })?.block,
                       .dependencyOff(.offsetParser))
        XCTAssertFalse(blocked.contains { $0.capability == .offsetParser },
                       "a capability the user switched off is not 'blocked' — it is off on purpose")
    }

    /// A capability whose page is off is reported with the page as the cause,
    /// not silently omitted — the banner's whole job is that no switch is
    /// mysteriously inert.
    func testBlockedCapabilitiesReportsAPageOffCause() throws {
        let registry = freshRegistry()
        let capability = try XCTUnwrap(
            Capability.allCases.first { $0.owner != .archive && $0.defaultsOn },
            "need a defaults-on capability on an optional page")
        let page = capability.owner

        try registry.enable(page)
        XCTAssertFalse(registry.blockedCapabilities().contains { $0.capability == capability })

        registry.disable(page)
        let blocked = registry.blockedCapabilities()
        XCTAssertEqual(blocked.first(where: { $0.capability == capability })?.block,
                       .pageOff(page),
                       "the page must be named as the reason")
        XCTAssertTrue(registry.switchPosition(capability),
                      "and the capability's own switch is untouched, so it resumes on re-enable")
    }
}
