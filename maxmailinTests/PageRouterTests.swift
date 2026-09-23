//
//  PageRouterTests.swift
//  maxmailinTests
//
//  Plan tasks A1/A2. The routing rules that keep §3.3 true on screen: a
//  disabled page can never be shown, a page that gets switched off while
//  visible falls back to Archive, and restored state cannot reopen a page the
//  user has since disabled.
//

import Testing
import Foundation
@testable import maxmailin

@MainActor
private func fixtures(
    enabled: [AppModule] = [],
    suite: String = UUID().uuidString
) throws -> (ModuleRegistry, UserDefaults) {
    let stateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("router-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("modules.v1.json")
    let registry = ModuleRegistry(store: ModuleStateStore(url: stateURL),
                                  excludedByBuild: [], trapsOnMisuse: false)
    for module in enabled { try registry.enable(module) }
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (registry, defaults)
}

@Suite("Top-level page routing (A1/A2)")
@MainActor
struct PageRouterTests {

    @Test("A fresh install opens on Archive")
    func defaultsToArchive() throws {
        let (_, defaults) = try fixtures()
        let router = PageRouter(defaults: defaults)
        #expect(router.selection == .archive)
    }

    @Test("A disabled page cannot be selected")
    func disabledPageIsRefused() throws {
        let (registry, defaults) = try fixtures()
        let router = PageRouter(defaults: defaults)

        let switched = router.select(.liveMail, in: registry)
        #expect(switched == false)
        #expect(router.selection == .archive, "refusing must leave the current page alone")
    }

    @Test("An enabled page can be selected and is remembered")
    func enabledPageIsSelectableAndPersisted() throws {
        let (registry, defaults) = try fixtures(enabled: [.professional])
        let router = PageRouter(defaults: defaults)

        #expect(router.select(.professional, in: registry))
        #expect(router.selection == .professional)

        // A relaunch restores the page the user was on.
        let restored = PageRouter(defaults: defaults)
        #expect(restored.selection == .professional)
    }

    @Test("Switching a visible page off falls back to Archive")
    func disablingVisiblePageFallsBack() throws {
        let (registry, defaults) = try fixtures(enabled: [.aiInsights])
        let router = PageRouter(defaults: defaults)
        #expect(router.select(.aiInsights, in: registry))

        registry.disable(.aiInsights)
        router.reconcile(with: registry)

        #expect(router.selection == .archive)
    }

    @Test("Restored state cannot reopen a page that is now disabled")
    func staleRestoredSelectionIsReconciled() throws {
        let (registry, defaults) = try fixtures(enabled: [.professional])
        let router = PageRouter(defaults: defaults)
        #expect(router.select(.professional, in: registry))

        // The page is switched off between launches.
        registry.disable(.professional)

        let relaunched = PageRouter(defaults: defaults)
        #expect(relaunched.selection == .professional, "state is restored verbatim…")
        relaunched.reconcile(with: registry)
        #expect(relaunched.selection == .archive, "…and then reconciled against what is enabled")
    }

    @Test("An organization-disabled page is refused like any other disabled page")
    func orgDisabledPageIsRefused() throws {
        // Simulates the build-exclusion path, which shares the .unavailable
        // branch used by ManagedConfig.disabledModules.
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-org-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("modules.v1.json")
        let registry = ModuleRegistry(store: ModuleStateStore(url: stateURL),
                                      excludedByBuild: [.liveMail], trapsOnMisuse: false)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let router = PageRouter(defaults: defaults)

        #expect(router.select(.liveMail, in: registry) == false)
        #expect(router.selection == .archive)
    }

    @Test("Archive is always selectable")
    func archiveIsAlwaysAvailable() throws {
        let (registry, defaults) = try fixtures(enabled: [.aiInsights])
        let router = PageRouter(initial: .aiInsights, defaults: defaults)
        #expect(router.select(.archive, in: registry))
        #expect(router.selection == .archive)
    }
}
