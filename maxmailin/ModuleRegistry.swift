//
//  ModuleRegistry.swift
//  mailin
//
//  v3.0 §3.2/§3.3 — the single authority for which of the four pages is active.
//
//  The owner rule this file exists to enforce (V3_0_PLAN.md §3.3 R1–R6): a page
//  depends only on itself, and if the user has activated nothing but Page 1
//  then nothing else runs — no jobs, no timers, no indexes, no model loads, no
//  sockets, no migrations, and no audit-chain writes. There is no provenance
//  carve-out (R6).
//
//  Everything optional is reached through `host(for:)`, which builds a feature
//  from its registered factory only while that module is enabled. Touching a
//  disabled module's host is a programming error: `.hostWhileDisabled` traps in
//  Debug and is reported (and refused) in Release.
//

import Foundation
import Observation
import os.log

private let moduleLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin",
                               category: "ModuleRegistry")

// MARK: - The four pages

/// The four top-level pages. Archive is Page 1 and cannot be switched off; the
/// other three are off on a fresh install and appear only once enabled.
enum AppModule: String, CaseIterable, Codable, Sendable, Identifiable {
    case archive
    case aiInsights
    case professional
    case liveMail

    var id: String { rawValue }

    /// Page 1 is mandatory; every other page is opt-in.
    var isOptional: Bool { self != .archive }

    var displayName: String {
        switch self {
        case .archive: return "Archive"
        case .aiInsights: return "AI Insights"
        case .professional: return "Professional Workflows"
        case .liveMail: return "Live Mail"
        }
    }

    /// Managed-configuration key an organization uses to hard-off this page.
    var managedConfigName: String { rawValue }
}

/// What Settings ▸ Modules shows for a page, and what the rest of the app may
/// assume about it. `unavailable` means the build or an org policy excludes the
/// page — the user cannot switch it on.
enum ModuleActivation: Equatable, Sendable {
    case unavailable(reason: String)
    case disabled
    case enabledNoAccounts          // Live Mail: on, but no account authorized yet
    case active
    case paused(reason: String)
    case error(String)

    /// True only when the module may hold resources or run work.
    var mayRunWork: Bool {
        switch self {
        case .active, .enabledNoAccounts: return true
        case .unavailable, .disabled, .paused, .error: return false
        }
    }

    var isUserSwitchable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// What happens to a module's saved work when the user switches it off.
/// Artifacts are kept by default: disabling a page must never destroy evidence,
/// reports, cases or legal holds.
enum ModuleRetention: String, Codable, Sendable {
    case keepArtifacts
    case deleteLocalCache
}

// MARK: - Persisted state

/// Versioned on-disk module state. Deliberately one small file rather than
/// scattered `@AppStorage` flags, so "what is enabled" has exactly one
/// authority that can be migrated.
struct ModuleState: Codable, Sendable, Equatable {
    /// v2 adds `capabilities` — the per-feature on/off matrix under each page.
    /// Additive: a v1 file decodes with an empty capability table, which means
    /// "every capability at its default", which is exactly the behaviour a v1
    /// install already had.
    static let currentVersion = 2

    var version: Int = ModuleState.currentVersion
    /// Only optional modules appear here. Absent means disabled.
    var enabled: [String: Bool] = [:]
    /// Explicit per-capability choices. **Absent means "use the default"**, not
    /// "off" — so a capability added by a later build arrives at its own
    /// default instead of being silently disabled by an older state file.
    var capabilities: [String: Bool] = [:]
    /// Set once the 2.x defaults have been mapped forward, so the mapping
    /// cannot run twice and silently re-enable something the user turned off.
    var didMapLegacyDefaults: Bool = false

    func isEnabled(_ module: AppModule) -> Bool {
        guard module.isOptional else { return true }
        return enabled[module.rawValue] ?? false
    }

    mutating func set(_ module: AppModule, enabled isOn: Bool) {
        guard module.isOptional else { return }
        enabled[module.rawValue] = isOn
    }

    /// The stored choice for a capability, ignoring its owning page and its
    /// dependencies — `ModuleRegistry.isOn` applies those.
    func isCapabilitySet(_ capability: Capability) -> Bool {
        capabilities[capability.rawValue] ?? capability.defaultsOn
    }

    /// True when the user has made an explicit choice, so the UI can
    /// distinguish "default" from "deliberately set to the same value".
    func hasExplicitChoice(_ capability: Capability) -> Bool {
        capabilities[capability.rawValue] != nil
    }

    mutating func set(_ capability: Capability, enabled isOn: Bool) {
        capabilities[capability.rawValue] = isOn
    }

    mutating func clearChoice(_ capability: Capability) {
        capabilities.removeValue(forKey: capability.rawValue)
    }

    init() {}

    /// Written by hand, not synthesized, for one specific reason: Swift's
    /// generated decoder does NOT fall back to a property's default value when
    /// a key is missing — it throws. A v1 state file has no `capabilities`
    /// key, so the synthesized decoder would fail, `ModuleStateStore.load`
    /// would return a fresh `ModuleState`, and every optional page the user had
    /// enabled would silently switch off on upgrade. Decoding each field
    /// leniently is what makes the migration additive in practice as well as
    /// on paper.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try container.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? [:]
        capabilities = try container.decodeIfPresent([String: Bool].self, forKey: .capabilities) ?? [:]
        didMapLegacyDefaults = try container.decodeIfPresent(
            Bool.self, forKey: .didMapLegacyDefaults) ?? false
    }
}

/// Atomic, versioned reader/writer for `ModuleState`.
///
/// Lives beside the archive in Application Support. Reading a file written by a
/// newer build returns defaults rather than guessing at unknown semantics.
struct ModuleStateStore: Sendable {
    let url: URL

    static var productionURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("modules.v1.json", isDirectory: false)
    }

    func load() -> ModuleState {
        guard let data = try? Data(contentsOf: url) else { return ModuleState() }
        guard let state = try? JSONDecoder().decode(ModuleState.self, from: data) else {
            moduleLog.error("module state unreadable — falling back to all-optional-off")
            return ModuleState()
        }
        guard state.version <= ModuleState.currentVersion else {
            moduleLog.error("module state version \(state.version) is newer than this build — ignoring")
            return ModuleState()
        }
        return state
    }

    func save(_ state: ModuleState) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            // Atomic replace: a crash mid-write must not leave a truncated file
            // that would read back as "everything off" on the next launch.
            try data.write(to: url, options: .atomic)
        } catch {
            moduleLog.error("could not persist module state: \(error.localizedDescription)")
        }
    }
}

// MARK: - Jobs

/// Every piece of cancellable background work, tagged with the module that owns
/// it, so disabling a page can stop exactly that page's work and Settings can
/// show what is running (§3.2).
@MainActor
@Observable
final class JobRegistry {
    struct Entry: Identifiable {
        let id: String
        let module: AppModule
        let label: String
        let cancel: @MainActor () -> Void
    }

    private(set) var entries: [Entry] = []

    func register(id: String, module: AppModule, label: String,
                  cancel: @escaping @MainActor () -> Void) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, module: module, label: label, cancel: cancel))
    }

    func finish(id: String) {
        entries.removeAll { $0.id == id }
    }

    func jobs(for module: AppModule) -> [Entry] {
        entries.filter { $0.module == module }
    }

    /// Stops a module's work. Called by `ModuleRegistry.disable`.
    func cancelAll(for module: AppModule) {
        let doomed = jobs(for: module)
        for entry in doomed { entry.cancel() }
        entries.removeAll { $0.module == module }
        if !doomed.isEmpty {
            moduleLog.info("cancelled \(doomed.count) job(s) for \(module.rawValue, privacy: .public)")
        }
    }

    var isIdle: Bool { entries.isEmpty }
}

// MARK: - Registry

/// Reads and writes module activation, and hands out feature hosts.
///
/// Held by the app shell as the one instance; features must never construct
/// their own. All mutation is main-actor so Settings and the sidebar observe a
/// single consistent state.
@MainActor
@Observable
final class ModuleRegistry {
    enum Failure: LocalizedError, Equatable {
        case unavailable(AppModule, reason: String)
        case hostWhileDisabled(AppModule)
        case noFactory(AppModule)

        var errorDescription: String? {
            switch self {
            case .unavailable(let m, let reason):
                return "\(m.displayName) is not available: \(reason)"
            case .hostWhileDisabled(let m):
                return "\(m.displayName) was requested while disabled"
            case .noFactory(let m):
                return "\(m.displayName) has no registered feature factory"
            }
        }
    }

    private let store: ModuleStateStore
    private var state: ModuleState
    private var factories: [AppModule: () -> AnyObject] = [:]
    private var hosts: [AppModule: AnyObject] = [:]

    /// In Debug, asking for a disabled page's host is a programming error and
    /// traps so it cannot slip into a shipped build (§3.3 R5). The tests that
    /// assert the *refusal* behaviour turn the trap off — otherwise they would
    /// abort the test process instead of observing the thrown error.
    private let trapsOnMisuse: Bool

    let jobs = JobRegistry()

    /// Set by a build that physically excludes a page (the Enterprise Offline
    /// configuration excludes Live Mail), so the UI can say "not in this
    /// edition" instead of offering a switch that cannot work.
    private let excludedByBuild: Set<AppModule>

    init(store: ModuleStateStore = ModuleStateStore(url: ModuleStateStore.productionURL),
         excludedByBuild: Set<AppModule> = ModuleRegistry.buildExclusions,
         trapsOnMisuse: Bool = true) {
        self.store = store
        self.excludedByBuild = excludedByBuild
        self.trapsOnMisuse = trapsOnMisuse
        self.state = store.load()
    }

    /// Pages absent from this build. Live Mail and the cloud tiers are compiled
    /// out of the no-network edition, so they can never be switched on there.
    nonisolated static var buildExclusions: Set<AppModule> {
        #if NO_NETWORK_BUILD
        return [.liveMail]
        #else
        return []
        #endif
    }

    // MARK: Reading

    func activation(_ module: AppModule) -> ModuleActivation {
        if excludedByBuild.contains(module) {
            return .unavailable(reason: "not included in this edition")
        }
        if let org = orgDisabledReason(module) {
            return .unavailable(reason: org)
        }
        guard module.isOptional else { return .active }
        return state.isEnabled(module) ? .active : .disabled
    }

    /// The gate every optional code path must ask before doing anything at all.
    func isEnabled(_ module: AppModule) -> Bool {
        activation(module).mayRunWork
    }

    /// An organization may hard-off a page through managed configuration; the
    /// user cannot re-enable it from the UI (EnterpriseConfig's policy rule).
    private func orgDisabledReason(_ module: AppModule) -> String? {
        guard module.isOptional else { return nil }
        if ManagedConfig.disabledModules.contains(module.managedConfigName) {
            return "disabled by your organization"
        }
        // A managed "no cloud AI" policy does not disable on-device AI, so it
        // is deliberately NOT mapped to the whole AI Insights page here.
        return nil
    }

    var enabledModules: [AppModule] {
        AppModule.allCases.filter { isEnabled($0) }
    }

    // MARK: Capabilities (the on/off matrix under each page)

    /// Why a capability is not running. `nil` means it is.
    enum CapabilityBlock: Equatable, Sendable {
        case pageOff(AppModule)
        case switchedOff
        case dependencyOff(Capability)

        var explanation: String {
            switch self {
            case .pageOff(let module):
                return "\(module.displayName) is switched off."
            case .switchedOff:
                return "Switched off."
            case .dependencyOff(let dependency):
                return "Needs “\(dependency.displayName)”, which is switched off."
            }
        }
    }

    /// The single gate every capability-specific code path must ask.
    ///
    /// Requires the owning page AND the stored flag AND every declared
    /// dependency. The page check comes first and is not overridable: a stale
    /// "on" flag must never be able to resurrect a disabled page's work
    /// (§3.3 R1–R6).
    func isOn(_ capability: Capability) -> Bool {
        block(capability) == nil
    }

    func block(_ capability: Capability) -> CapabilityBlock? {
        guard isEnabled(capability.owner) else { return .pageOff(capability.owner) }
        guard state.isCapabilitySet(capability) else { return .switchedOff }
        for dependency in capability.requires where !isOn(dependency) {
            return .dependencyOff(dependency)
        }
        return nil
    }

    /// The stored switch position, independent of page and dependencies — what
    /// the matrix toggle shows, so a row does not appear to have flipped
    /// itself when its page was turned off.
    func switchPosition(_ capability: Capability) -> Bool {
        state.isCapabilitySet(capability)
    }

    func hasExplicitChoice(_ capability: Capability) -> Bool {
        state.hasExplicitChoice(capability)
    }

    func set(_ capability: Capability, enabled isOn: Bool) {
        guard state.isCapabilitySet(capability) != isOn
                || !state.hasExplicitChoice(capability) else { return }
        state.set(capability, enabled: isOn)
        store.save(state)
        applyWiring(from: capability)
        moduleLog.info("""
            capability \(capability.rawValue, privacy: .public) \
            \(isOn ? "on" : "off", privacy: .public)
            """)
    }

    /// Returns to the shipped default, so a user can undo an experiment
    /// without having to remember what the default was.
    func resetToDefault(_ capability: Capability) {
        state.clearChoice(capability)
        store.save(state)
        applyWiring(from: capability)
        moduleLog.info("capability \(capability.rawValue, privacy: .public) reset to default")
    }

    /// Pushes the new state to the machinery that reads a plain flag rather
    /// than the registry, for this capability AND anything that depends on it —
    /// turning off a dependency must disarm its dependents too, not leave them
    /// pointed at an engine that is no longer running.
    private func applyWiring(from capability: Capability) {
        CapabilityWiring.apply(capability, isOn: isOn(capability))
        for dependent in capability.dependents {
            CapabilityWiring.apply(dependent, isOn: isOn(dependent))
        }
    }

    /// Switching a PAGE changes every capability it owns, so the same push has
    /// to happen there. Called by `enable`/`disable`.
    private func applyWiring(forPage module: AppModule) {
        for capability in Capability.all(for: module) {
            CapabilityWiring.apply(capability, isOn: isOn(capability))
        }
    }

    /// Every capability of a page that is currently running — the honest
    /// answer to "what is this page actually doing?".
    func activeCapabilities(of module: AppModule) -> [Capability] {
        Capability.all(for: module).filter { isOn($0) }
    }

    /// Capabilities whose switch is on but which are not running anyway, with
    /// the reason. Surfaced in the matrix so a row is never mysteriously inert.
    func blockedCapabilities() -> [(capability: Capability, block: CapabilityBlock)] {
        Capability.allCases.compactMap { capability in
            guard state.isCapabilitySet(capability), let block = block(capability) else { return nil }
            return (capability, block)
        }
    }

    /// True when the user is running Page 1 only — the shape the resting-cost
    /// baseline in RELEASE_READINESS.md is measured against.
    var isArchiveOnly: Bool {
        enabledModules == [.archive]
    }

    // MARK: Writing

    func enable(_ module: AppModule) throws {
        guard module.isOptional else { return }
        if case .unavailable(let reason) = activation(module) {
            throw Failure.unavailable(module, reason: reason)
        }
        guard !state.isEnabled(module) else { return }
        state.set(module, enabled: true)
        store.save(state)
        applyWiring(forPage: module)
        moduleLog.info("enabled \(module.rawValue, privacy: .public)")
    }

    /// Switches a page off: stops its jobs, drops its host so its types are no
    /// longer resident, and keeps its saved artifacts unless the caller
    /// explicitly asked for cache deletion.
    func disable(_ module: AppModule, retention: ModuleRetention = .keepArtifacts) {
        guard module.isOptional else { return }
        jobs.cancelAll(for: module)
        hosts[module] = nil
        state.set(module, enabled: false)
        store.save(state)
        applyWiring(forPage: module)
        moduleLog.info("""
            disabled \(module.rawValue, privacy: .public) \
            (retention: \(retention.rawValue, privacy: .public))
            """)
    }

    // MARK: Feature hosts

    /// Registers how to build a page's feature object. The closure must not run
    /// at registration time — that is the whole point of the indirection.
    func register(_ module: AppModule, factory: @escaping () -> AnyObject) {
        factories[module] = factory
    }

    /// Returns the page's feature object, building it on first use. Refuses when
    /// the page is off, which is what keeps a disabled module's types from ever
    /// being instantiated (§3.3 R2, R5).
    func host(for module: AppModule) throws -> AnyObject {
        guard isEnabled(module) else {
            if trapsOnMisuse {
                assertionFailure("host(for: .\(module.rawValue)) while disabled — see V3_0_PLAN.md §3.3 R5")
            }
            moduleLog.fault("host requested for disabled module \(module.rawValue, privacy: .public)")
            throw Failure.hostWhileDisabled(module)
        }
        if let existing = hosts[module] { return existing }
        guard let factory = factories[module] else { throw Failure.noFactory(module) }
        let built = factory()
        hosts[module] = built
        return built
    }

    /// Test/measurement hook: true when a page's feature object exists in
    /// memory. The disabled-launch instrumentation asserts this is false for
    /// every optional page.
    func hasLiveHost(_ module: AppModule) -> Bool {
        hosts[module] != nil
    }

    /// One reading of what the app is actually holding, for
    /// `MODULE_ACTIVATION_MATRIX.md` and the §3.3 R3 measurements. Resident
    /// memory is included so a snapshot can be compared across module states,
    /// but note RSS is process-wide — it is evidence, not attribution.
    struct ResourceSnapshot: Sendable, Equatable {
        var enabled: [AppModule]
        var liveHosts: [AppModule]
        var jobsByModule: [AppModule: Int]
        var footprintBytes: UInt64

        /// The condition a Page-1-only install must satisfy: nothing optional
        /// is constructed and nothing optional is running.
        var isArchiveOnlyClean: Bool {
            enabled == [.archive] && liveHosts.isEmpty
                && jobsByModule.filter { $0.key.isOptional && $0.value > 0 }.isEmpty
        }
    }

    func resourceSnapshot() -> ResourceSnapshot {
        var counts: [AppModule: Int] = [:]
        for module in AppModule.allCases {
            counts[module] = jobs.jobs(for: module).count
        }
        return ResourceSnapshot(
            enabled: enabledModules,
            liveHosts: AppModule.allCases.filter { hosts[$0] != nil },
            jobsByModule: counts,
            footprintBytes: currentFootprintBytes()
        )
    }

    // MARK: Legacy mapping

    /// Maps 2.x state forward exactly once (directive §8.2: "safely map prior
    /// optional-state and purchases").
    ///
    /// A fresh install gets everything optional off. An existing install keeps
    /// what the user was already using: AI follows the old `enableAIFeatures`
    /// flag, and Professional follows the fact that they had completed persona
    /// selection — the 2.x signal that they were doing professional work. Live
    /// Mail is never auto-enabled, because it would mean network access the
    /// user has not yet consented to.
    func mapLegacyStateIfNeeded(isExistingInstall: Bool,
                                legacyAIEnabled: Bool,
                                legacyPersonaCompleted: Bool) {
        guard !state.didMapLegacyDefaults else { return }
        defer {
            state.didMapLegacyDefaults = true
            store.save(state)
        }
        guard isExistingInstall else {
            moduleLog.info("fresh install — all optional pages off")
            return
        }
        if legacyAIEnabled { state.set(.aiInsights, enabled: true) }
        if legacyPersonaCompleted { state.set(.professional, enabled: true) }
        moduleLog.info("""
            mapped 2.x state — ai: \(legacyAIEnabled, privacy: .public), \
            professional: \(legacyPersonaCompleted, privacy: .public), liveMail: false
            """)
    }
}
