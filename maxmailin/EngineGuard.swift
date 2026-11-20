@testable import ArchiveCore
//
//  EngineGuard.swift
//  maxmailin
//
//  Crash isolation for the 3.0 engines (SCALE_TODO_3_0.md §3-M2/M3).
//
//  An app cannot catch its own crash. What it CAN do is make sure the same
//  crash never happens twice:
//
//   • Before a 3.0 engine runs, `EngineGuard` writes a small breadcrumb file
//     ("engine X is running"). It is removed when the run ends — normally or by
//     throwing.
//   • At launch, any breadcrumb older than this launch means the previous
//     process stopped INSIDE that engine. The engine is "tripped": its switch is
//     turned off, the old engine takes over, and the shell shows a banner with
//     "Copy diagnostics". Nothing is lost — both engines share the same data.
//   • An engine that THROWS (rather than crashing) falls back to the old code
//     for that call (`withFallback`), and the fallback is counted.
//
//  Breadcrumbs are plain files so they survive a crash of this process; they
//  are cheap (one tiny write per run, not per email).
//

import Foundation
import os

private let engineGuardLog = Logger(subsystem: "com.ecosanskriti.maxmailin", category: "EngineGuard")

/// One recorded trip: an engine the app stopped inside.
struct EngineTrip: Codable, Equatable, Sendable, Identifiable {
    var id: String { capability + "@" + String(date.timeIntervalSince1970) }
    let capability: String
    let date: Date
    let appVersion: String
    /// §3-M2: the app version that switched the engine back on (a new
    /// version may carry the fix). Optional so older trip logs decode.
    var restoredInVersion: String? = nil
    /// The user changed this engine's switch after the trip: their choice
    /// wins, a new version does not override it.
    var userChoseSince: Bool? = nil
}

enum EngineGuard {
    // MARK: Locations

    /// Captured on first use. The app touches it in `init` so breadcrumbs from
    /// this launch are never mistaken for leftovers of the previous one.
    static let launchDate = Date()

    static var directory: URL {
        // A bound scope-job environment (tests) keeps its breadcrumbs with it,
        // so they can never trip an engine in the real app.
        if let root = ScopeJobEnvironment.current?.root {
            return root.appendingPathComponent("EngineGuard", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EngineGuard", isDirectory: true)
    }
    private static var breadcrumbDirectory: URL { directory.appendingPathComponent("running", isDirectory: true) }
    private static var tripLogURL: URL { directory.appendingPathComponent("trips.json") }
    private static var fallbackLogURL: URL { directory.appendingPathComponent("fallbacks.json") }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: Breadcrumbs

    /// A running engine's breadcrumb. Remove it with `end`.
    struct Token: Sendable {
        let capability: Capability
        let url: URL
    }

    @discardableResult
    static func begin(_ capability: Capability) -> Token {
        _ = launchDate
        let url = breadcrumbDirectory.appendingPathComponent("\(capability.rawValue)__\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: breadcrumbDirectory, withIntermediateDirectories: true)
            try Data(capability.rawValue.utf8).write(to: url, options: .atomic)
        } catch {
            // A breadcrumb that cannot be written must not stop the work; the
            // run is simply not crash-protected.
            engineGuardLog.error("breadcrumb not written for \(capability.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return Token(capability: capability, url: url)
    }

    static func end(_ token: Token) {
        try? FileManager.default.removeItem(at: token.url)
    }

    /// Runs `body` inside a breadcrumb; nil runs it unguarded (the engine's switch is off).
    static func run<T>(_ capability: Capability?, _ body: () throws -> T) rethrows -> T {
        guard let capability else { return try body() }
        let token = begin(capability)
        defer { end(token) }
        return try body()
    }

    /// Runs on the caller's actor (`isolation`), so the body is never sent across actors.
    static func run<T>(_ capability: Capability?, isolation: isolated (any Actor)? = #isolation,
                       _ body: () async throws -> T) async rethrows -> T {
        guard let capability else { return try await body() }
        let token = begin(capability)
        defer { end(token) }
        return try await body()
    }

    // MARK: Package engines and coverage (review C23, rule 15)

    /// The package's engines (PST spec reader, Notes ODS reader, streaming
    /// parsers, store-level switches …) leave their breadcrumbs through here.
    static func installPackageBreadcrumbs() {
        EngineBreadcrumbs.begin = { name in
            guard let capability = Capability(rawValue: name) else {
                engineGuardLog.error("breadcrumb for an unknown engine \(name, privacy: .public)")
                return {}
            }
            let token = EngineGuard.begin(capability)
            return { EngineGuard.end(token) }
        }
    }

    /// Where every 3.0 engine's run seam carries its crash breadcrumb (an
    /// `EngineGuard.begin/run/withFallback`, a scope job's `capability:` or a
    /// package `EngineBreadcrumbs.run/start`). V3CompatibilityTests compares
    /// this to `Capability.v3Engines` and reads each file for the breadcrumb:
    /// a new engine cannot ship without one.
    static let runSeams: [Capability: String] = [
        .v3SafeHTML: "maxmailin/EmailHTMLView.swift",
        .v3SQLiteHygiene: "\(P)ArchiveSafety.swift",
        .v3Snapshots: "\(P)SQLiteEmailStore.swift",
        .v3ScopeEngine: "maxmailin/ScopeJob.swift",
        .v3FeatureIndex: "maxmailin/FeatureIndex.swift",
        .v3Fingerprints: "maxmailin/FeatureIndex.swift",
        .v3PagedLists: "\(P)SQLiteEmailStore.swift",
        .v3SemanticSearch: "maxmailin/ArchiveRetrievalService.swift",
        .v3Duplicates: "maxmailin/DuplicatesEngine.swift",
        .v3SearchOperators: "\(P)ArchiveQueryCompiler.swift",
        .v3AnalysisQueries: "maxmailin/DigestEngine.swift",
        .v3AlertsAnomalies: "maxmailin/BackgroundAnalysisManager.swift",
        .v3PredictiveCoding: "maxmailin/PredictiveCodingEngine.swift",
        .v3NearDuplicates: "maxmailin/NearDuplicatesEngine.swift",
        .v3TopicClusters: "maxmailin/TopicClustersEngine.swift",
        .v3Threads: "maxmailin/ThreadStoryView.swift",
        .v3AIAnswers: "maxmailin/AIContextSelector.swift",
        .v3Graphs: "maxmailin/RelationshipGraphView.swift",
        .v3KeywordMonitor: "maxmailin/KeywordMonitorEngine.swift",
        .v3LegalState: "maxmailin/LegalStateEngine.swift",
        .v3EDiscovery: "maxmailin/EDiscoveryEngine.swift",
        .v3Bates: "maxmailin/BatesEngine.swift",
        .v3ChainOfCustody: "maxmailin/ChainOfCustodyManager.swift",
        .v3Custodians: "maxmailin/CustodianEngine.swift",
        .v3ReviewBatches: "maxmailin/ReviewBatchPanelView.swift",
        .v3BatchOperations: "maxmailin/BatchOperationsEngine.swift",
        .v3AutomationRules: "maxmailin/AutomationRulesRunEngine.swift",
        .v3PrivilegeScan: "maxmailin/PrivilegeScanEngine.swift",
        .v3PIIReport: "maxmailin/PIIEngine.swift",
        .v3IOC: "maxmailin/IOCEngine.swift",
        .v3InvestigationReport: "maxmailin/InvestigationReportData.swift",
        .v3LegalReview: "maxmailin/LegalReviewWorkspaceView.swift",
        .v3EvidenceDesks: "maxmailin/EvidenceDesksStudio.swift",
        .v3EvidenceReceipts: "\(P)BulkImportCoordinator.swift",
        .v3PreservationExport: "maxmailin/PreservationExporter.swift",
        .v3PSTSpecReader: "\(P)EmailParserProtocol.swift",
        .v3PSTSpecWriter: "\(P)ArchiveExportService.swift",
        .v4FastImport: "\(P)BulkImportCoordinator.swift",
        .v31Recovery: "\(P)PSTParser.swift",
        .v31DeepRecovery: "\(P)PSTParser.swift",
        .v31ShortcutsActions: "maxmailin/MailinAppEntities.swift",
        .v31Scripts: "maxmailin/ScriptEngine.swift",
        .v31ReviewPack: "maxmailin/ReviewPack.swift",
        .v31TeamCase: "maxmailin/TeamCase.swift",
        .v31ForensicTimestamps: "maxmailin/ForensicSignalsView.swift",
        .devonthinkHandOff: "maxmailin/DEVONthinkHandOff.swift",
        .attachmentOCR: "maxmailin/AttachmentTextIndexJob.swift",
        .attachmentSpeech: "maxmailin/AttachmentTextIndexJob.swift",
        .protectedMessageDecrypt: "maxmailin/AttachmentTextIndexJob.swift",
        .streamingBinaryParsers: "\(P)EmailParserProtocol.swift",
        .selfContainedArchive: "\(P)BulkImportCoordinator.swift",
        .searchQueryModel: "\(P)SQLiteEmailStore.swift",
        .notesODSReader: "\(P)EmailParserProtocol.swift",
    ]
    private static let P = "Packages/ArchiveCore/Sources/ArchiveCore/"

    // MARK: Fallback (M3)

    /// A 3.0 engine threw at a tool's seam: records the fallback (log +
    /// audit) and returns the line the tool shows. The caller then runs the
    /// previous engine for this call. Cancellation is not a fallback.
    @MainActor
    static func fellBack(_ capability: Capability, error: Error) -> String {
        recordFallback(capability, error: error)
        engineGuardLog.error("\(capability.rawValue, privacy: .public) threw, falling back: \(error.localizedDescription, privacy: .public)")
        ScopeJobEnvironment.logAction("Fell back to the previous engine",
                                      detail: "\(capability.rawValue): \(error.localizedDescription)")
        return String(localized: "The new engine stopped (\(error.localizedDescription)); the previous engine ran instead.")
    }


    /// Uses the new engine when its switch is on, inside a breadcrumb; if the
    /// new engine throws, logs it, counts the fallback and runs the old path
    /// for this call. With the switch off, runs the old path directly.
    static func withFallback<T>(_ capability: Capability, isOn: Bool,
                                new: () async throws -> T,
                                old: () async throws -> T) async rethrows -> T {
        guard isOn else { return try await old() }
        do {
            return try await run(capability) { try await new() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            engineGuardLog.error("\(capability.rawValue, privacy: .public) threw, falling back: \(error.localizedDescription, privacy: .public)")
            recordFallback(capability, error: error)
            return try await old()
        }
    }

    static func withFallback<T>(_ capability: Capability, isOn: Bool,
                                new: () throws -> T,
                                old: () throws -> T) rethrows -> T {
        guard isOn else { return try old() }
        do {
            return try run(capability) { try new() }
        } catch is CancellationError {
            // C25: a cancelled run is not an engine failure — no fallback, nothing recorded.
            throw CancellationError()
        } catch {
            engineGuardLog.error("\(capability.rawValue, privacy: .public) threw, falling back: \(error.localizedDescription, privacy: .public)")
            recordFallback(capability, error: error)
            return try old()
        }
    }

    // MARK: Trips (M2)

    /// Breadcrumbs left by an earlier launch: each is an engine the app stopped
    /// inside. Removes them and returns their capabilities.
    static func collectLeftoverBreadcrumbs() -> [Capability] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: breadcrumbDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var tripped: Set<Capability> = []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified < launchDate else { continue }   // a run of THIS launch
            let raw = file.lastPathComponent.components(separatedBy: "__").first ?? ""
            if let capability = Capability(rawValue: raw) { tripped.insert(capability) }
            try? fm.removeItem(at: file)
        }
        return tripped.sorted { $0.rawValue < $1.rawValue }
    }

    static func loadTrips() -> [EngineTrip] {
        guard let data = try? Data(contentsOf: tripLogURL) else { return [] }
        return (try? JSONDecoder().decode([EngineTrip].self, from: data)) ?? []
    }

    static func saveTrips(_ trips: [EngineTrip]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(trips).write(to: tripLogURL, options: .atomic)
        } catch {
            engineGuardLog.error("trip log not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user changed `capability`'s switch: an open trip no longer decides it.
    static func noteUserChoice(_ capability: Capability) {
        var trips = loadTrips()
        guard let i = trips.lastIndex(where: { $0.capability == capability.rawValue }),
              trips[i].restoredInVersion == nil, trips[i].userChoseSince != true else { return }
        trips[i].userChoseSince = true
        saveTrips(trips)
    }

    /// Engines tripped in an EARLIER app version, still off, never restored
    /// and not touched by the user since: a new version switches them back
    /// on once (the trip may have been fixed). Marks them restored.
    static func takeRestorableTrips(currentVersion: String) -> [Capability] {
        var trips = loadTrips()
        var latest: [String: Int] = [:]
        for (i, t) in trips.enumerated() { latest[t.capability] = i }
        var restore: [Capability] = []
        for (_, i) in latest {
            let t = trips[i]
            guard t.appVersion != currentVersion, t.restoredInVersion == nil, t.userChoseSince != true,
                  let capability = Capability(rawValue: t.capability) else { continue }
            trips[i].restoredInVersion = currentVersion
            restore.append(capability)
        }
        if !restore.isEmpty { saveTrips(trips) }
        return restore.sorted { $0.rawValue < $1.rawValue }
    }

    /// The most recent trip for a capability, for the matrix row.
    static func lastTrip(_ capability: Capability) -> EngineTrip? {
        loadTrips().last { $0.capability == capability.rawValue }
    }

    // MARK: Fallback log

    struct FallbackRecord: Codable, Sendable {
        let capability: String
        let date: Date
        let error: String
    }

    /// Fallbacks recorded for `capability` since `date` (for job receipts).
    static func fallbackCount(_ capability: Capability, since date: Date) -> Int {
        loadFallbacks().filter { $0.capability == capability.rawValue && $0.date >= date }.count
    }

    static func recordFallback(_ capability: Capability, error: Error) {
        var records = loadFallbacks()
        records.append(FallbackRecord(capability: capability.rawValue, date: Date(), error: error.localizedDescription))
        if records.count > 500 { records.removeFirst(records.count - 500) }   // a log, not data: keep the recent part
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: fallbackLogURL, options: .atomic)
        } catch {
            engineGuardLog.error("fallback log not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadFallbacks() -> [FallbackRecord] {
        guard let data = try? Data(contentsOf: fallbackLogURL) else { return [] }
        return (try? JSONDecoder().decode([FallbackRecord].self, from: data)) ?? []
    }
}

/// Launch-time trip handling and the banner state (main actor).
@MainActor
@Observable
final class EngineTripCenter {
    static let shared = EngineTripCenter()

    /// Engines switched off at this launch because the app stopped inside them.
    private(set) var newlyTripped: [Capability] = []
    /// Engines a new version switched back on at this launch.
    private(set) var newlyRestored: [Capability] = []

    /// What this launch decided: engines a new version switched back on, and
    /// engines the previous process stopped inside (their trips are recorded).
    struct LaunchDecision: Sendable, Equatable {
        var restored: [Capability] = []
        var tripped: [Capability] = []
    }

    /// Set by `decideAtLaunch()` in the app's init; taken by `checkAtLaunch`.
    nonisolated(unsafe) static var pendingDecision: LaunchDecision?

    /// Review C23 (rule 15): the trips decided straight from the breadcrumb
    /// files and written to the switch file, from the app's `init` — before
    /// the registry loads and before `applyStoreLevelEarly` arms the
    /// store-level engines. The banner and audit lines follow in `checkAtLaunch`.
    nonisolated static func decideAtLaunch(stateStore: ModuleStateStore = ModuleStateStore(url: ModuleStateStore.productionURL)) {
        let decision = collectDecision()
        if !decision.restored.isEmpty || !decision.tripped.isEmpty {
            var state = stateStore.load()
            for capability in decision.restored { state.set(capability, enabled: true) }
            for capability in decision.tripped { state.set(capability, enabled: false) }
            stateStore.save(state)
        }
        pendingDecision = decision
    }

    /// Restorable trips and leftover breadcrumbs, the trips recorded.
    nonisolated static func collectDecision() -> LaunchDecision {
        // A new app version gets one fresh chance for engines an earlier
        // version tripped (unless the user decided since), §3-M2.
        let restored = EngineGuard.takeRestorableTrips(currentVersion: EngineGuard.appVersion)
        let leftovers = EngineGuard.collectLeftoverBreadcrumbs()
        if !leftovers.isEmpty {
            var trips = EngineGuard.loadTrips()
            for capability in leftovers {
                trips.append(EngineTrip(capability: capability.rawValue, date: Date(), appVersion: EngineGuard.appVersion))
            }
            EngineGuard.saveTrips(trips)
        }
        return LaunchDecision(restored: restored, tripped: leftovers)
    }

    /// Call once at launch, before any 3.0 engine can run: applies this
    /// launch's decision (taken in the app's init, or now) to the registry,
    /// records it in the audit trail and shows the banner.
    func checkAtLaunch(registry: ModuleRegistry) {
        let decision = Self.pendingDecision ?? Self.collectDecision()
        Self.pendingDecision = nil
        let restored = decision.restored
        for capability in restored {
            registry.set(capability, enabled: true)
            ScopeJobEnvironment.logAction("Engine switched back on in a new version",
                detail: "\(capability.rawValue) — it had stopped unexpectedly in an earlier version; switched off again automatically if it stops")
        }
        newlyRestored = restored
        let leftovers = decision.tripped
        guard !leftovers.isEmpty else { return }
        for capability in leftovers {
            registry.set(capability, enabled: false)
            ScopeJobEnvironment.logAction(
                "Engine switched off after an unexpected stop",
                detail: "\(capability.rawValue) — the previous engine is used; no data was changed")
        }
        newlyTripped = leftovers
    }

    func dismiss() { newlyTripped = [] }
    func dismissRestored() { newlyRestored = [] }

    /// Plain-text summary for "Copy diagnostics".
    func diagnosticsText() -> String {
        var lines = ["mailin \(EngineGuard.appVersion) — engine diagnostics", ""]
        let trips = EngineGuard.loadTrips()
        lines.append("Engines switched off after an unexpected stop: \(trips.count)")
        for t in trips.suffix(50) {
            lines.append("  \(ISO8601DateFormatter().string(from: t.date))  \(t.capability)  (\(t.appVersion))")
        }
        let fallbacks = EngineGuard.loadFallbacks()
        lines.append("")
        lines.append("Calls that fell back to the previous engine: \(fallbacks.count)")
        for f in fallbacks.suffix(50) {
            lines.append("  \(ISO8601DateFormatter().string(from: f.date))  \(f.capability)  \(f.error)")
        }
        lines.append("")
        lines.append(DiagnosticsCenter.shared.summaryText())
        return lines.joined(separator: "\n")
    }
}
