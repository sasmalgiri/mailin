//
//  ModuleGatingTests.swift
//  maxmailinTests
//
//  v3.0 §3.3 R1–R6: proves the page-independence rule mechanically rather than
//  by review. If the user has activated nothing but Page 1, every other page
//  must report disabled, refuse to build its feature host, and hold no jobs.
//

import Testing
import Foundation
@testable import maxmailin

@MainActor
private func makeRegistry(file: String = #function) -> (ModuleRegistry, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("moduletests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("modules.v1.json")
    let registry = ModuleRegistry(store: ModuleStateStore(url: url),
                                  excludedByBuild: [], trapsOnMisuse: false)
    return (registry, url)
}

@Suite("Module gating (v3.0 §3.3)")
@MainActor
struct ModuleGatingTests {

    // MARK: R2 — nothing exists until activated

    @Test("Fresh install: Archive on, every optional page off")
    func freshInstallDefaults() {
        let (registry, _) = makeRegistry()

        #expect(registry.isEnabled(.archive))
        #expect(!registry.isEnabled(.aiInsights))
        #expect(!registry.isEnabled(.professional))
        #expect(!registry.isEnabled(.liveMail))
        #expect(registry.isArchiveOnly)
        #expect(registry.enabledModules == [.archive])
    }

    @Test("A disabled page never yields a feature host")
    func hostRefusedWhileDisabled() {
        let (registry, _) = makeRegistry()
        final class Host {}
        var built = 0
        registry.register(.aiInsights) { built += 1; return Host() }

        // Registration alone must not construct anything (R2).
        #expect(built == 0)
        #expect(!registry.hasLiveHost(.aiInsights))

        // Asking for the host while disabled fails and still builds nothing.
        #expect(throws: ModuleRegistry.Failure.hostWhileDisabled(.aiInsights)) {
            _ = try registry.host(for: .aiInsights)
        }
        #expect(built == 0)
        #expect(!registry.hasLiveHost(.aiInsights))
    }

    @Test("Enabling builds the host lazily, exactly once")
    func hostBuiltOnceAfterEnable() throws {
        let (registry, _) = makeRegistry()
        final class Host {}
        var built = 0
        registry.register(.professional) { built += 1; return Host() }

        try registry.enable(.professional)
        #expect(built == 0, "enabling must not eagerly construct the feature")

        let first = try registry.host(for: .professional)
        let second = try registry.host(for: .professional)
        #expect(built == 1)
        #expect(first === second)
    }

    // MARK: R4 — disabling returns to the baseline

    @Test("Disabling cancels the page's jobs and drops its host")
    func disableStopsWorkAndReleasesHost() throws {
        let (registry, _) = makeRegistry()
        final class Host {}
        registry.register(.aiInsights) { Host() }
        try registry.enable(.aiInsights)
        _ = try registry.host(for: .aiInsights)

        var cancelled = 0
        registry.jobs.register(id: "ai.digest", module: .aiInsights, label: "Digest") {
            cancelled += 1
        }
        registry.jobs.register(id: "archive.import", module: .archive, label: "Import") {
            cancelled += 100   // must NOT be cancelled by an AI disable
        }

        registry.disable(.aiInsights)

        #expect(cancelled == 1, "only the disabled page's jobs may be cancelled")
        #expect(!registry.hasLiveHost(.aiInsights))
        #expect(!registry.isEnabled(.aiInsights))
        #expect(registry.jobs.jobs(for: .aiInsights).isEmpty)
        #expect(registry.jobs.jobs(for: .archive).count == 1, "Page 1 work is untouched")
    }

    @Test("Archive cannot be disabled")
    func archiveIsMandatory() {
        let (registry, _) = makeRegistry()
        registry.disable(.archive)
        #expect(registry.isEnabled(.archive))
    }

    // MARK: Persistence

    @Test("Activation survives a relaunch")
    func statePersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moduletests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("modules.v1.json")
        let store = ModuleStateStore(url: url)

        let first = ModuleRegistry(store: store, excludedByBuild: [], trapsOnMisuse: false)
        try first.enable(.professional)

        let second = ModuleRegistry(store: store, excludedByBuild: [], trapsOnMisuse: false)
        #expect(second.isEnabled(.professional))
        #expect(!second.isEnabled(.aiInsights))
        #expect(!second.isEnabled(.liveMail))
    }

    @Test("State written by a newer build is ignored, not guessed at")
    func futureVersionFallsBackToAllOff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moduletests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("modules.v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let future = """
        {"version": 99, "enabled": {"liveMail": true}, "didMapLegacyDefaults": true}
        """
        try Data(future.utf8).write(to: url)

        let registry = ModuleRegistry(store: ModuleStateStore(url: url),
                                      excludedByBuild: [], trapsOnMisuse: false)
        #expect(!registry.isEnabled(.liveMail))
        #expect(registry.isArchiveOnly)
    }

    // MARK: Build exclusion and org policy

    @Test("A page excluded by the build is unavailable, not merely off")
    func buildExclusionIsNotUserSwitchable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moduletests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("modules.v1.json")
        let registry = ModuleRegistry(store: ModuleStateStore(url: url),
                                      excludedByBuild: [.liveMail], trapsOnMisuse: false)

        #expect(registry.activation(.liveMail).isUserSwitchable == false)
        #expect(!registry.isEnabled(.liveMail))
        #expect(throws: (any Error).self) { try registry.enable(.liveMail) }
    }

    // MARK: Legacy mapping (directive §8.2)

    @Test("Fresh install ignores 2.x defaults entirely")
    func legacyMappingSkippedOnFreshInstall() {
        let (registry, _) = makeRegistry()
        registry.mapLegacyStateIfNeeded(isExistingInstall: false,
                                        legacyAIEnabled: true,
                                        legacyPersonaCompleted: true)
        #expect(registry.isArchiveOnly)
    }

    @Test("Existing install keeps what it was using; Live Mail never auto-enables")
    func legacyMappingPreservesPriorUse() {
        let (registry, _) = makeRegistry()
        registry.mapLegacyStateIfNeeded(isExistingInstall: true,
                                        legacyAIEnabled: true,
                                        legacyPersonaCompleted: true)
        #expect(registry.isEnabled(.aiInsights))
        #expect(registry.isEnabled(.professional))
        #expect(!registry.isEnabled(.liveMail), "network access is never inherited")
    }

    @Test("Legacy mapping runs once and cannot re-enable a user's choice")
    func legacyMappingIsIdempotent() {
        let (registry, _) = makeRegistry()
        registry.mapLegacyStateIfNeeded(isExistingInstall: true,
                                        legacyAIEnabled: true,
                                        legacyPersonaCompleted: false)
        #expect(registry.isEnabled(.aiInsights))

        registry.disable(.aiInsights)
        // A second launch must not resurrect it from the old default.
        registry.mapLegacyStateIfNeeded(isExistingInstall: true,
                                        legacyAIEnabled: true,
                                        legacyPersonaCompleted: false)
        #expect(!registry.isEnabled(.aiInsights))
    }
}
