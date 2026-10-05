@testable import ArchiveCore
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
import NaturalLanguage
import StoreKit
import StoreKitTest
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

    @Test("A page compiled out of the edition has no tab; an org lock keeps its tab")
    func buildExcludedPagesHaveNoTab() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moduletests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("modules.v1.json")
        let noNetwork = ModuleRegistry(store: ModuleStateStore(url: url),
                                       excludedByBuild: [.liveMail], trapsOnMisuse: false)
        #expect(noNetwork.isExcludedByBuild(.liveMail))
        #expect(noNetwork.shippedModules == [.archive, .aiInsights, .professional])
        #expect(noNetwork.activation(.liveMail) == .unavailable(reason: "not included in this edition"))

        // (Whether THIS build excludes Live Mail is EnterpriseDeploymentTests'
        // job — the flag is defined on the app target, not the test bundle.)

        // A page that merely is not enabled still has a tab (it asks first).
        let (full, _) = makeRegistry()
        #expect(full.shippedModules == AppModule.allCases)
        #expect(!full.isExcludedByBuild(.liveMail))
    }

    @Test("Persona home hub belongs to Professional Workflows")
    func personaHubOwnedByProfessional() {
        #expect(HubDestination.personaHub.owner == .professional)
    }

    // MARK: Audit F12 — a managed hard-off stops running work

    @Test("A managed hard-off cancels the page's jobs, drops its host and rewires — without a relaunch")
    func policyHardOffTearsDownRunningWork() throws {
        let defaults = UserDefaults.standard
        let original = defaults.dictionary(forKey: ManagedConfig.managedDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: ManagedConfig.managedDefaultsKey) }
            else { defaults.removeObject(forKey: ManagedConfig.managedDefaultsKey) }
        }
        defaults.removeObject(forKey: ManagedConfig.managedDefaultsKey)

        let (registry, _) = makeRegistry()
        try registry.enable(.aiInsights)
        final class Host {}
        registry.register(.aiInsights) { Host() }
        _ = try registry.host(for: .aiInsights)
        var cancelled = false
        registry.jobs.register(id: "test.job", module: .aiInsights, label: "test") { cancelled = true }
        #expect(registry.hasLiveHost(.aiInsights))
        #expect(registry.jobs.jobs(for: .aiInsights).count == 1)

        // Policy arrives while the page is running.
        defaults.set(["disabledModules": ["aiInsights"]], forKey: ManagedConfig.managedDefaultsKey)
        registry.reloadPolicy()

        #expect(!registry.isEnabled(.aiInsights))
        #expect(cancelled, "the running job was cancelled by the policy change")
        #expect(registry.jobs.jobs(for: .aiInsights).isEmpty)
        #expect(!registry.hasLiveHost(.aiInsights), "the feature host was released")

        // Policy lifts: the page is enabled again (the user's on survived) and
        // a host can be built afresh.
        defaults.removeObject(forKey: ManagedConfig.managedDefaultsKey)
        registry.reloadPolicy()
        #expect(registry.isEnabled(.aiInsights))
        _ = try registry.host(for: .aiInsights)
        #expect(registry.hasLiveHost(.aiInsights))
    }

    // MARK: Audit F13 — the semantic index catches up after a completed walk

    private func semanticEmail(_ i: Int, date: String) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<sem-\(i)-\(UUID().uuidString)@test>", "Subject": "Semantic subject \(i)",
                      "From": "a@example.com", "To": "b@example.com", "Date": date],
            rawSource: "Subject: Semantic subject \(i)\n\nA sentence about topic number \(i) for the embedder.\n",
            messageType: "email", attachments: [], timestamp: "", domains: ["example.com"],
            plainBody: "A sentence about topic number \(i) for the embedder.", htmlBody: "")
    }

    private func waitUntilIdle(_ controller: SemanticIndexController) async {
        for _ in 0..<300 {
            if !controller.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A completed walk clears its cursor; the next run embeds later imports and drops deleted messages")
    func semanticIndexCatchesUpAfterCompletion() async throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }   // no on-device model here
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SemanticIndexController.enabledKey)
        defer {
            if let previous { defaults.set(previous, forKey: SemanticIndexController.enabledKey) }
            else { defaults.removeObject(forKey: SemanticIndexController.enabledKey) }
        }
        defaults.set(true, forKey: SemanticIndexController.enabledKey)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let first = [semanticEmail(1, date: "Wed, 01 Jan 2020 10:00:00 +0000"),
                     semanticEmail(2, date: "Thu, 02 Jan 2020 10:00:00 +0000"),
                     semanticEmail(3, date: "Fri, 03 Jan 2020 10:00:00 +0000")]
        try await store.insertBatch(first, batchSize: 10)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let vectors = EmbeddingStore(directory: root.appendingPathComponent("embeddings", isDirectory: true))
        let controller = SemanticIndexController(archive: archive, store: vectors)
        let (registry, _) = makeRegistry()
        try registry.enable(.aiInsights)

        controller.resume(modules: registry)
        await waitUntilIdle(controller)
        #expect(controller.lastError == nil, Comment(rawValue: controller.lastError ?? ""))
        let afterFirst = try await vectors.count()
        #expect(afterFirst == 3)
        let cursor = try await vectors.meta(SemanticIndexController.cursorDateKey)
        #expect(cursor == nil, "a completed walk forgets its cursor")

        // Later imports: one NEWER and one OLDER than anything indexed —
        // the case the old cursor could never reach.
        let later = [semanticEmail(4, date: "Sat, 04 Jan 2021 10:00:00 +0000"),
                     semanticEmail(5, date: "Tue, 01 Jan 2019 10:00:00 +0000")]
        try await store.insertBatch(later, batchSize: 10)
        // And one message deleted from the archive.
        try await archive.delete(ids: [first[0].id])

        controller.resume(modules: registry)
        await waitUntilIdle(controller)
        #expect(controller.lastError == nil, Comment(rawValue: controller.lastError ?? ""))
        let afterSecond = try await vectors.count()
        #expect(afterSecond == 4, "2 + 2 later imports, minus the deleted one")
        let present = try await vectors.existingIDs(among: later.map(\.id) + [first[0].id])
        #expect(present.contains(later[0].id) && present.contains(later[1].id))
        #expect(!present.contains(first[0].id), "the deleted message's vector is swept")
        #expect(controller.pending == 0)
    }

    // MARK: Audit F14 — reports read the scoped corpus

    @Test("The report query carries the Page 2 scope and applies the date range before any cap")
    func reportQueryCarriesScopeAndDates() {
        let scope = ArchiveQueryCompiler.compile("source:Sent.mbox")
        let from = Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 1))!
        let to = Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 31))!
        let query = ReportBuilderView.reportQuery(scope: scope, useDateRange: true, from: from, to: to)
        #expect(query.afterDate == Calendar.current.startOfDay(for: from))
        #expect(query.beforeDate == Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)))
        // The scope's own filter survives the date narrowing.
        var expected = scope
        expected.afterDate = query.afterDate
        expected.beforeDate = query.beforeDate
        #expect(query == expected)

        let whole = ReportBuilderView.reportQuery(scope: nil, useDateRange: false, from: from, to: to)
        #expect(whole == .all)

        // Recheck R9: the report's dates NARROW a page scope, never widen it.
        var lastWeek = EmailQuery.all
        lastWeek.afterDate = Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 20))
        lastWeek.beforeDate = Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 27))
        let wider = ReportBuilderView.reportQuery(scope: lastWeek, useDateRange: true,
                                                  from: Calendar.current.date(from: DateComponents(year: 2018, month: 1, day: 1))!,
                                                  to: Calendar.current.date(from: DateComponents(year: 2020, month: 12, day: 31))!)
        #expect(wider.afterDate == lastWeek.afterDate, "a wider report range cannot reach before the page scope")
        #expect(wider.beforeDate == lastWeek.beforeDate, "nor after it")
        let narrower = ReportBuilderView.reportQuery(scope: lastWeek, useDateRange: true,
                                                     from: Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 22))!,
                                                     to: Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 23))!)
        #expect(narrower.afterDate == Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 22)))
        #expect(narrower.beforeDate == Calendar.current.date(from: DateComponents(year: 2019, month: 3, day: 24)))

        #expect(ReportBuilderView.coverageNote(matching: 120, processed: 120).hasPrefix("All 120"))
        #expect(ReportBuilderView.coverageNote(matching: 12_000, processed: 5_000).contains("newest 5,000 of 12,000"))
    }

    @Test("Email Analytics (sentiment + NLP passes) belongs to AI Insights")
    func emailAnalyticsOwnedByAIInsights() {
        #expect(HubDestination.emailAnalytics.owner == .aiInsights)
        // Owner, 2026-09-30: topic discovery is NLP clustering, so the docked
        // Topics panel and the hub tool both belong to AI Insights.
        #expect(HubDestination.topicClusters.owner == .aiInsights)
        // The pure-count tools stay with the archive.
        for dest in [HubDestination.timeline, .communicationPatterns, .relationshipGraph, .duplicateManager] {
            #expect(dest.owner == .archive, "\(dest.rawValue)")
        }
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

    // MARK: R3 — resource snapshot

    @Test("Page-1-only snapshot holds no optional hosts and no optional jobs")
    func archiveOnlySnapshotIsClean() throws {
        let (registry, _) = makeRegistry()
        final class Host {}
        for module in AppModule.allCases where module.isOptional {
            registry.register(module) { Host() }
        }
        registry.jobs.register(id: "archive.import", module: .archive, label: "Import") {}

        let snapshot = registry.resourceSnapshot()
        #expect(snapshot.enabled == [.archive])
        #expect(snapshot.liveHosts.isEmpty)
        #expect(snapshot.jobsByModule[.archive] == 1)
        #expect(snapshot.jobsByModule[.aiInsights] == 0)
        #expect(snapshot.jobsByModule[.professional] == 0)
        #expect(snapshot.jobsByModule[.liveMail] == 0)
        #expect(snapshot.footprintBytes > 0, "footprint must be readable for the R3 table")
        #expect(snapshot.isArchiveOnlyClean)
    }

    @Test("Enabling a page shows up in the snapshot; disabling returns it to clean")
    func snapshotTracksActivation() throws {
        let (registry, _) = makeRegistry()
        final class Host {}
        registry.register(.aiInsights) { Host() }

        try registry.enable(.aiInsights)
        _ = try registry.host(for: .aiInsights)
        registry.jobs.register(id: "ai.digest", module: .aiInsights, label: "Digest") {}

        var snapshot = registry.resourceSnapshot()
        #expect(snapshot.enabled.contains(.aiInsights))
        #expect(snapshot.liveHosts == [.aiInsights])
        #expect(snapshot.jobsByModule[.aiInsights] == 1)
        #expect(!snapshot.isArchiveOnlyClean)

        registry.disable(.aiInsights)
        snapshot = registry.resourceSnapshot()
        #expect(snapshot.isArchiveOnlyClean, "disabling must return to the all-off baseline")
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


@Suite("Page isolation of feature flags (§3.3 R1)")
@MainActor
struct PageIsolationTests {

    private func gatedState(enabled: [AppModule]) throws -> AppStateManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("modules.v1.json")
        let registry = ModuleRegistry(store: ModuleStateStore(url: url),
                                      excludedByBuild: [], trapsOnMisuse: false)
        for module in enabled { try registry.enable(module) }
        let state = AppStateManager()
        state.isModuleEnabled = { registry.isEnabled($0) }
        return state
    }

    @Test("Archive-only: no AI or Professional feature can be opened")
    func archiveOnlyRefusesForeignFeatures() throws {
        let state = try gatedState(enabled: [])

        // Every owned feature refuses. The assertion trap is off in tests via
        // the registry, and the state gate itself simply declines.
        state.showAIAssistant = true
        state.showAIDigest = true
        state.showAnomalyDetection = true
        state.showPredictiveCoding = true
        state.showCustodianPanel = true
        state.showAuditTrail = true
        state.showEDiscovery = true
        state.showBatesNumbering = true
        state.showChainOfCustody = true
        state.showReviewBatches = true

        #expect(!state.showAIAssistant)
        #expect(!state.showAIDigest)
        #expect(!state.showAnomalyDetection)
        #expect(!state.showPredictiveCoding)
        #expect(!state.showCustodianPanel)
        #expect(!state.showAuditTrail)
        #expect(!state.showEDiscovery)
        #expect(!state.showBatesNumbering)
        #expect(!state.showChainOfCustody)
        #expect(!state.showReviewBatches)
    }

    @Test("Archive's own features are never gated")
    func archiveFeaturesAlwaysWork() throws {
        let state = try gatedState(enabled: [])

        state.showDuplicateManager = true
        state.showAttachmentGrid = true
        state.showTimeline = true
        state.showAllAttachmentsGallery = true
        state.triggerExport = true
        state.triggerSearch = true

        #expect(state.showDuplicateManager)
        #expect(state.showAttachmentGrid, "reading attachments is Page 1 work")
        #expect(state.showTimeline)
        #expect(state.showAllAttachmentsGallery)
        #expect(state.triggerExport, "export is Page 1 work")
        #expect(state.triggerSearch, "search is Page 1 work")
    }

    @Test("Enabling AI Insights opens exactly its own features, not Professional's")
    func enablingOnePageDoesNotOpenAnother() throws {
        let state = try gatedState(enabled: [.aiInsights])

        state.showAIAssistant = true
        state.showAIDigest = true
        state.showCustodianPanel = true
        state.showAuditTrail = true

        #expect(state.showAIAssistant)
        #expect(state.showAIDigest)
        #expect(!state.showCustodianPanel, "Professional stays closed")
        #expect(!state.showAuditTrail, "Professional stays closed")
    }

    @Test("Enabling Professional opens its features, not AI's")
    func professionalDoesNotOpenAI() throws {
        let state = try gatedState(enabled: [.professional])

        state.showCustodianPanel = true
        state.showAuditTrail = true
        state.showAIAssistant = true

        #expect(state.showCustodianPanel)
        #expect(state.showAuditTrail)
        #expect(!state.showAIAssistant, "AI Insights stays closed")
    }

    @Test("A feature already open closes when its page is switched off")
    func closingIsAlwaysAllowed() throws {
        let state = try gatedState(enabled: [.aiInsights])
        state.showAIAssistant = true
        #expect(state.showAIAssistant)

        // Closing must never be refused, whatever the page state.
        state.showAIAssistant = false
        #expect(!state.showAIAssistant)
    }

    @Test("Every owned feature declares an owning page")
    func ownershipIsComplete() {
        for feature in AppStateManager.OwnedFeature.allCases {
            #expect(feature.module.isOptional,
                    "\(feature.rawValue) must belong to an optional page, not Archive")
        }
    }
}


@Suite("Page activation matrix honesty")
@MainActor
struct PageFeatureCatalogTests {

    @Test("Every page publishes a feature matrix")
    func everyPageHasFeatures() {
        for module in AppModule.allCases {
            #expect(!PageFeatureCatalog.features(for: module).isEmpty,
                    "\(module.rawValue) must tell the user what it contains")
        }
    }

    @Test("Live Mail's rows all say they are not in this build")
    func liveMailIsHonestlyUnbuilt() {
        let rows = PageFeatureCatalog.features(for: .liveMail)
        #expect(rows.allSatisfy { $0.availability == .notInThisBuild },
                "no Live Mail capability may be advertised as included")
        let consequences = PageFeatureCatalog.consequences(for: .liveMail)
        #expect(consequences.contains { $0.contains("Nothing in this build") })
    }

    @Test("Archive costs nothing to have on")
    func archiveHasNoConsequences() {
        #expect(PageFeatureCatalog.consequences(for: .archive).isEmpty)
        #expect(PageFeatureCatalog.features(for: .archive)
            .allSatisfy { $0.availability == .available },
            "Page 1 must not gate its own basics behind a purchase")
    }

    @Test("Optional pages disclose what they start doing")
    func optionalPagesDiscloseConsequences() {
        for module in AppModule.allCases where module.isOptional {
            #expect(!PageFeatureCatalog.consequences(for: module).isEmpty,
                    "\(module.rawValue) must say what turning it on starts")
        }
    }

    @Test("Professional discloses that holds and cases survive being switched off")
    func professionalDisclosesRetention() {
        let lines = PageFeatureCatalog.consequences(for: .professional).joined(separator: " ")
        #expect(lines.contains("hold"))
        #expect(lines.lowercased().contains("kept") || lines.lowercased().contains("keeps"))
    }

    @Test("Every availability state has a user-facing label")
    func availabilityLabels() {
        #expect(PageFeature.Availability.available.label == "Included")
        #expect(PageFeature.Availability.requiresProfessional.label == "Professional")
        #expect(PageFeature.Availability.notInThisBuild.label == "Not in this build")
    }
}

// MARK: - Owner's screenshot review 2026-09-29 — "Running now" rows exist only while a job works

/// These tests drive the two shared launch-job singletons. Swift Testing runs
/// tests in parallel by default and each singleton is one object, so the
/// suite is serialized: two of these interleaving at an `await` would hand
/// the job a different test's registry mid-flight (seen once in a full run).
@Suite("Running-now job lifecycle", .serialized)
@MainActor
struct RunningJobLifecycleTests {


    private func disposableStore(_ tag: String) -> (SQLiteEmailStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(tag)-\(UUID().uuidString)", isDirectory: true)
        return (SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true)), root)
    }

    @Test("Attachment indexing registers while it runs and clears its row when there is nothing to do")
    func attachmentIndexRowClearsOnNothingToDo() async throws {
        let (registry, _) = makeRegistry()
        let (store, root) = disposableStore("attach"); defer { try? FileManager.default.removeItem(at: root) }
        AttachmentTextIndexJob.testStoreOverride = store; defer { AttachmentTextIndexJob.testStoreOverride = nil }
        let job = AttachmentTextIndexJob.shared
        job.cancel()   // a clean start regardless of what the host app kicked

        job.kickIfNeeded(registry: registry.jobs)
        #expect(registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID), "the row appears when the run starts")
        let run = try #require(job.currentRun)
        await run.value
        // In the full suite, imports run by OTHER tests post `.parsingFinished`,
        // whose observer re-kicks this shared job at any moment; each re-kick
        // over the empty test store ends at once. Drain any such run before
        // asserting, so the assertion is about lifecycle, not about timing.
        while let later = job.currentRun { await later.value }
        #expect(!registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID), "an empty archive: the run ends at once and its row is gone")
        #expect(job.currentRun == nil)

        // A later re-kick (what an import does) registers again without being handed the registry.
        job.kickIfNeeded()
        #expect(registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID))
        while let later = job.currentRun { await later.value }
        #expect(!registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID))
    }

    @Test("Cancelling a job clears its row immediately, and the cancelled run cannot clear a newer one")
    func attachmentIndexRowClearsOnCancel() async throws {
        let (registry, _) = makeRegistry()
        let (store, root) = disposableStore("attach-cancel"); defer { try? FileManager.default.removeItem(at: root) }
        AttachmentTextIndexJob.testStoreOverride = store; defer { AttachmentTextIndexJob.testStoreOverride = nil }
        let job = AttachmentTextIndexJob.shared
        job.cancel()

        job.kickIfNeeded(registry: registry.jobs)
        let first = try #require(job.currentRun)
        registry.jobs.entries.first { $0.id == AttachmentTextIndexJob.jobID }?.cancel()   // the Stop button
        #expect(!registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID), "Stop clears the row at once")

        job.kickIfNeeded(registry: registry.jobs)
        #expect(registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID), "a new run has its own row")
        await first.value   // the cancelled run's completion must not touch the new row
        while let later = job.currentRun { await later.value }
        #expect(!registry.jobs.isRunning(id: AttachmentTextIndexJob.jobID))
    }

    @Test("Repair job clears its row when the archive is already clean, without any notification")
    func fidelityRepairRowClearsOnNothingToDo() async throws {
        let (registry, _) = makeRegistry()
        let (store, root) = disposableStore("fidelity"); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "test.fidelity.\(UUID().uuidString)"))
        defaults.set(FidelityBackfillJob.headerPassVersion, forKey: FidelityBackfillJob.headerPassKey)   // header sweep already done
        FidelityBackfillJob.testStoreOverride = store; defer { FidelityBackfillJob.testStoreOverride = nil }
        FidelityBackfillJob.testDefaultsOverride = defaults; defer { FidelityBackfillJob.testDefaultsOverride = nil }
        let job = FidelityBackfillJob.shared
        job.cancel()

        var completions = 0
        let token = NotificationCenter.default.addObserver(forName: .fidelityBackfillCompleted, object: nil, queue: .main) { _ in completions += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        job.kickIfNeeded(senderEmail: "", registry: registry.jobs)
        #expect(registry.jobs.isRunning(id: FidelityBackfillJob.jobID))
        let run = try #require(job.currentRun)
        await run.value
        while let later = job.currentRun { await later.value }
        #expect(!registry.jobs.isRunning(id: FidelityBackfillJob.jobID), "nothing to repair: the row is cleared even though no completion notification was posted")
        #expect(completions == 0, "the UI-refresh notification is not what clears the row")
    }

    @Test("A job's progress detail is shown on its row and dropped with it")
    func jobDetailUpdates() {
        let (registry, _) = makeRegistry()
        registry.jobs.register(id: "x", module: .archive, label: "X") {}
        registry.jobs.update(id: "x", detail: "12 done")
        #expect(registry.jobs.entries.first?.detail == "12 done")
        registry.jobs.update(id: "y", detail: "ignored")   // unknown id: no-op
        #expect(registry.jobs.entries.count == 1)
        registry.jobs.finish(id: "x")
        #expect(registry.jobs.isIdle)
    }
}

// MARK: - Purchase gates on the 3.0 pages (audit 2026-09-30)

/// A user who has not purchased must be restricted the same way whichever
/// page, strip, workflow step or list launches the work. These tests use the
/// deterministic `StoreManager(testTier:)` fixture, which never touches
/// StoreKit and does not take the Debug all-unlocked shortcut, so a denial is
/// actually exercised here rather than assumed from a lock label.
@Suite("Purchase gates (Free / Personal / Professional)")
@MainActor
struct PurchaseGateTests {

    @Test("Free: nothing paid passes, and a denied gate shows the paywall")
    func freeTierIsDenied() {
        let store = StoreManager(testTier: .free)
        #expect(store.effectiveTier == .free)
        #expect(!store.isPremium)
        #expect(!store.isProfessional)
        #expect(store.require(.free))
        #expect(!store.showPaywall, "a Free-tier gate never shows the paywall")
        #expect(!store.require(.personal))
        #expect(store.showPaywall, "a denied gate must surface the paywall, not fail silently")
        store.showPaywall = false
        #expect(!store.requirePremium())
        #expect(!store.requireProfessional())
        #expect(store.showPaywall)
    }

    @Test("Personal: Premium passes, Professional is denied")
    func personalTierStopsAtProfessional() {
        let store = StoreManager(testTier: .personal)
        #expect(store.isPremium)
        #expect(!store.isProfessional)
        #expect(store.require(.personal))
        #expect(!store.require(.professional))
        #expect(store.showPaywall)
    }

    @Test("Professional: every gate passes and no paywall appears")
    func professionalTierPassesEverything() {
        let store = StoreManager(testTier: .professional)
        #expect(store.isPremium && store.isProfessional)
        #expect(store.require(.professional) && store.requirePremium() && store.requireProfessional())
        #expect(!store.showPaywall)
    }

    @Test("The test fixture never becomes the app's live store manager")
    func testFixtureDoesNotClaimLive() {
        let store = StoreManager(testTier: .free)
        #expect(StoreManager.live !== store)
    }

    @Test("Every tool the Professional page can launch is paid, at the tier the Archive hub charges")
    func professionalPageToolsArePaidLikeTheHub() {
        let tools = ProfessionalPageView.toolDestinations
        #expect(tools.count == 12, "strip lists 5 studios + 7 tools")
        // The Archive page's hub (ContentView) charges these three at
        // Personal and the rest at Professional; Page 3 must answer the same.
        let personalOnHub: Set<HubDestination> = [.actionRegister, .reasoningStudio, .redaction]
        for destination in tools {
            let tier = StoreManager.requiredTier(for: destination)
            #expect(tier > .free, "\(destination.rawValue) must never run for a Free user from Page 3")
            #expect(tier == (personalOnHub.contains(destination) ? .personal : .professional),
                    "\(destination.rawValue) opened from Page 3 must be gated like the Archive hub gates it")
        }
    }

    @Test("Hub tier mapping mirrors the Archive page: Work Center free, AI surfaces Personal")
    func hubTierMappingMirrorsArchiveHub() {
        #expect(StoreManager.requiredTier(for: .workCenter) == .free)
        #expect(StoreManager.requiredTier(for: .settings) == .free)
        #expect(StoreManager.requiredTier(for: .aiDigest) == .personal)
        #expect(StoreManager.requiredTier(for: .reportBuilder) == .personal)
        #expect(StoreManager.requiredTier(for: .aiAssistant) == .personal)
        #expect(StoreManager.requiredTier(for: .custodianPanel) == .professional)
        #expect(StoreManager.requiredTier(for: .batesNumbering) == .professional)
        #expect(StoreManager.requiredTier(for: .chainOfCustody) == .professional)
        #expect(StoreManager.requiredTier(for: .eDiscovery) == .professional)
    }

    @Test("The Free browse depth is the same number the Advanced list and exports use")
    func freeDepthIsOneNumber() {
        #expect(StoreManager.freeEmailLimit == 500)
    }

    @Test("An export run honours the tier in force when it starts, not the cap saved in its request")
    func exportCapFollowsCurrentTier() throws {
        // A request built (or a receipt written) while Personal was active
        // carries no cap; if the entitlement has lapsed by the time it is
        // started or resumed, the Free cap applies anyway.
        #expect(try ExportJobRunner.enforcedCap(savedCap: nil, isPremium: false) == StoreManager.freeEmailLimit)
        // A request built while Free carries the cap; once Personal is bought
        // the resume runs to the end of the selection.
        #expect(try ExportJobRunner.enforcedCap(savedCap: StoreManager.freeEmailLimit, isPremium: true) == nil)
        // No change in tier, no change in behaviour.
        #expect(try ExportJobRunner.enforcedCap(savedCap: StoreManager.freeEmailLimit, isPremium: false) == StoreManager.freeEmailLimit)
        #expect(try ExportJobRunner.enforcedCap(savedCap: nil, isPremium: true) == nil)
    }

    @Test("A fresh run or a resume with no tier to check is refused, never run on its saved cap")
    func exportWithoutATierIsRefused() throws {
        let scope = ArchiveSelectionScope.query(.all, exclusions: [])
        // A fresh request that was built uncapped (as a Personal host builds it).
        let fresh = ExportRequest(format: .csv, title: "CSV", scope: scope,
                                  destination: NSTemporaryDirectory() + "refused.csv", isFolder: false, cap: nil)
        #expect(throws: ExportJobRunner.AuthorizationError.self) {
            _ = try ExportJobRunner.authorized(fresh, isPremium: nil)
        }
        // A resume from a receipt that recorded no cap: the saved cap says
        // "unlimited", and the receipt alone must not be enough to run.
        var resume = fresh
        resume.skipFirst = 500
        resume.selectionFingerprint = "fp"
        #expect(throws: ExportJobRunner.AuthorizationError.self) {
            _ = try ExportJobRunner.authorized(resume, isPremium: nil)
        }
        // With a tier to check, the same requests run under that tier's cap.
        #expect(try ExportJobRunner.authorized(resume, isPremium: false).cap == StoreManager.freeEmailLimit)
        #expect(try ExportJobRunner.authorized(resume, isPremium: true).cap == nil)
        #expect(try ExportJobRunner.authorized(resume, isPremium: false).skipFirst == 500)
    }
}

// MARK: - Purchase presentation coordinator (directive 2026-09-30, part 2)

/// One request, one presenter per window, no duplicates, nothing dropped.
@Suite("Purchase presentation coordinator")
@MainActor
struct PurchasePresentationTests {

    @Test("A denied gate raises a request carrying tier, feature, reason and window")
    func deniedGateRaisesContextualRequest() {
        let store = StoreManager(testTier: .free)
        let allowed = store.require(.professional, feature: "Chain of Custody", reason: "Needs Professional", target: .window("Chain of Custody"))
        #expect(!allowed)
        #expect(store.paywallRequest == PurchaseRequest(requiredTier: .professional, feature: "Chain of Custody",
                                                        reason: "Needs Professional", target: .window("Chain of Custody")))
    }

    @Test("A second request while the sheet is up updates it in place and keeps its window")
    func secondRequestUpdatesInPlace() {
        let store = StoreManager(testTier: .free)
        store.requestPurchase(.personal, feature: "Summaries", reason: "r1", target: .main)
        store.requestPurchase(.professional, feature: "Bates Numbering", reason: "r2", target: .window("Bates"))
        let request = store.paywallRequest
        #expect(request?.requiredTier == .professional, "the higher tier wins")
        #expect(request?.feature == "Bates Numbering")
        #expect(request?.reason == "r2")
        #expect(request?.target == .main, "the sheet already showing in the main window stays there — no duplicate")
    }

    @Test("A plain request never lowers the tier of a specific one")
    func plainRequestKeepsSpecificTier() {
        let store = StoreManager(testTier: .free)
        store.requestPurchase(.professional, feature: "eDiscovery", reason: "needs pro", target: .main)
        store.showPaywall = true   // legacy gate: "show plans"
        #expect(store.paywallRequest?.requiredTier == .professional)
        #expect(store.paywallRequest?.feature == "eDiscovery")
    }

    @Test("Dismiss clears the request; the legacy flag reads it")
    func dismissClears() {
        let store = StoreManager(testTier: .free)
        #expect(!store.showPaywall)
        store.showPaywall = true
        #expect(store.showPaywall)
        #expect(store.paywallRequest == PurchaseRequest(requiredTier: .free, feature: nil, reason: nil, target: .main))
        store.dismissPaywall()
        #expect(!store.showPaywall)
        #expect(store.paywallRequest == nil)
    }

    @Test("Only the presenter whose window matches shows the request")
    func presenterTargetMatching() {
        let store = StoreManager(testTier: .free)
        store.requestPurchase(.personal, target: .settings)
        #expect(store.paywallRequest?.target == .settings)
        #expect(store.paywallRequest?.target != .main)
        #expect(store.paywallRequest?.target != .window("Production"))
    }

    @Test("Plan badge: Free upgrades, Personal sees Professional, Professional sees its plan")
    func planBadge() {
        #expect(StoreManager.planBadgeLabel(tier: .free, lifetime: false) == "Free · Upgrade")
        #expect(StoreManager.planBadgeLabel(tier: .personal, lifetime: false) == "Personal")
        #expect(StoreManager.planBadgeLabel(tier: .personal, lifetime: true) == "Personal · Lifetime")
        #expect(StoreManager.planBadgeLabel(tier: .professional, lifetime: true) == "Professional · Lifetime")
        #expect(StoreManager.planBadgeRequestTier(current: .free) == .personal)
        #expect(StoreManager.planBadgeRequestTier(current: .personal) == .professional)
        #expect(StoreManager.planBadgeRequestTier(current: .professional) == .free, "plan details, not an upgrade demand")
    }

    @Test("Purchase screen opens on the minimum tier the feature needs, never below the next unowned tier")
    func initialSelectedTier() {
        let pro = PurchaseRequest(requiredTier: .professional, feature: "Bates", reason: nil, target: .main)
        let personal = PurchaseRequest(requiredTier: .personal, feature: "Summaries", reason: nil, target: .main)
        #expect(PaywallView.initialSelectedTier(request: pro, currentTier: .free) == .professional)
        #expect(PaywallView.initialSelectedTier(request: personal, currentTier: .free) == .personal)
        #expect(PaywallView.initialSelectedTier(request: nil, currentTier: .free) == .personal)
        #expect(PaywallView.initialSelectedTier(request: personal, currentTier: .personal) == .professional,
                "a Personal owner is never offered Personal again")
        #expect(PaywallView.initialSelectedTier(request: nil, currentTier: .personal) == .professional)
        #expect(PaywallView.initialSelectedTier(request: pro, currentTier: .professional) == nil,
                "a Professional owner has nothing to buy")
    }

    @Test("Restore outcomes are three distinct messages")
    func restoreOutcomes() {
        #expect(RestoreOutcome.restored(.personal).isSuccess)
        #expect(!RestoreOutcome.nothingFound.isSuccess)
        #expect(!RestoreOutcome.failed("x").isSuccess)
        #expect(RestoreOutcome.restored(.professional).message.contains("Professional"))
        #expect(RestoreOutcome.nothingFound.message.contains("No eligible purchases"))
        #expect(RestoreOutcome.failed("offline").message.contains("offline"))
    }

    @Test("Lifetime fixture is reported as lifetime, not a subscription")
    func lifetimeFixture() {
        let store = StoreManager(testTier: .personal, lifetime: true)
        #expect(store.isLifetimePurchase)
        #expect(store.isPremium && !store.isProfessional)
    }

    @Test("Debug launch override simulates a tier on the live manager; Release has no such code")
    func debugLaunchOverride() {
        let store = StoreManager(testTier: .professional)
        store.applyDebugLaunchOverride(arguments: ["app", "-mailinSimulateTier", "free"])
        #expect(store.effectiveTier == .free)
        #expect(!store.isPremium)
        store.applyDebugLaunchOverride(arguments: ["app", "-mailinSimulateTier", "personal", "-mailinSimulateLifetime"])
        #expect(store.effectiveTier == .personal)
        #expect(store.isLifetimePurchase)
        store.applyDebugLaunchOverride(arguments: ["app", "-mailinSimulateTier", "bogus"])
        #expect(store.effectiveTier == .personal, "an unknown value changes nothing")
    }
}

// MARK: - Free input allowance (owner decision 2026-10-01: 100 MB of input)

@Suite("Free input allowance (100 MB)")
struct ImportAllowanceTests {

    @Test("The limit is 100 MB, decimal, and only the Free tier has one")
    @MainActor
    func limitPerTier() {
        #expect(StoreManager.freeInputByteLimit == 100_000_000)
        #expect(StoreManager(testTier: .free).inputByteLimit == 100_000_000)
        #expect(StoreManager(testTier: .personal).inputByteLimit == nil)
        #expect(StoreManager(testTier: .professional).inputByteLimit == nil)
    }

    @Test("Cumulative: what the archive holds plus this import must fit; no limit means always allowed")
    func evaluateIsCumulative() {
        let limit = StoreManager.freeInputByteLimit
        #expect(ImportAllowance.evaluate(requestedBytes: limit, ingestedBytes: 0, limitBytes: limit) == .allowed, "exactly the limit fits")
        #expect(ImportAllowance.evaluate(requestedBytes: limit + 1, ingestedBytes: 0, limitBytes: limit).denial != nil)
        #expect(ImportAllowance.evaluate(requestedBytes: 1, ingestedBytes: limit, limitBytes: limit).denial != nil, "a full archive admits nothing more")
        #expect(ImportAllowance.evaluate(requestedBytes: 40_000_000, ingestedBytes: 70_000_000, limitBytes: limit).denial != nil, "70 + 40 > 100")
        #expect(ImportAllowance.evaluate(requestedBytes: 30_000_000, ingestedBytes: 70_000_000, limitBytes: limit) == .allowed, "70 + 30 = 100")
        #expect(ImportAllowance.evaluate(requestedBytes: 5_000_000_000, ingestedBytes: 5_000_000_000, limitBytes: nil) == .allowed, "paid tiers: no limit")
    }

    @Test("A denial names the figures and the way out")
    func denialMessage() {
        let d = ImportAllowance.evaluate(requestedBytes: 40_000_000, ingestedBytes: 70_000_000, limitBytes: 100_000_000).denial
        #expect(d?.remainingBytes == 30_000_000)
        let message = d?.message ?? ""
        #expect(message.contains("100 MB"))
        #expect(message.contains("70 MB"))
        #expect(message.contains("40 MB"))
        #expect(message.contains("30 MB"))
        #expect(message.contains("Personal and Professional"))
        let fresh = ImportAllowance.evaluate(requestedBytes: 250_000_000, ingestedBytes: 0, limitBytes: 100_000_000).denial
        #expect(fresh?.message.contains("250 MB") == true)
    }

    @Test("Input bytes: files by size, folders by their regular contents, symlinks never followed")
    func totalBytesMeasuresInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("allowance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("eml", isDirectory: true)
        let nested = folder.appendingPathComponent("more", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let single = root.appendingPathComponent("a.mbox")
        try Data(count: 1_000).write(to: single)
        try Data(count: 300).write(to: folder.appendingPathComponent("1.eml"))
        try Data(count: 200).write(to: nested.appendingPathComponent("2.eml"))
        // A symlink inside the folder to a large file outside it must not count.
        let outside = root.appendingPathComponent("huge.bin")
        try Data(count: 50_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.eml"), withDestinationURL: outside)

        #expect(ImportAllowance.totalBytes(of: [single]) == 1_000)
        #expect(ImportAllowance.totalBytes(of: [folder]) == 500)
        #expect(ImportAllowance.totalBytes(of: [single, folder]) == 1_500)
        // A top-level symlink is not input either.
        let topLink = root.appendingPathComponent("top.mbox")
        try FileManager.default.createSymbolicLink(at: topLink, withDestinationURL: outside)
        #expect(ImportAllowance.totalBytes(of: [topLink]) == 0)
        #expect(ImportAllowance.totalBytes(of: [root.appendingPathComponent("missing.mbox")]) == 0)
    }
}

// MARK: - Interface localization

/// The App Store listing says the interface ships in 11 languages. This suite
/// pins that claim to the string catalog: every key that is meant to be
/// translated has a value in each of the ten non-English languages, and every
/// translation keeps the same format placeholders as its English key, so a
/// localized `String(format:)` can never crash or print the wrong argument.
@Suite("Interface localization — 11 languages")
struct InterfaceLocalizationTests {
    static let languages = ["de", "es", "fr", "hi", "it", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant"]

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable { let state: String; let value: String }
                let stringUnit: Unit?
            }
            let shouldTranslate: Bool?
            let extractionState: String?
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private static func loadCatalog() throws -> Catalog {
        // The catalog is a source file; the test reads it from the repo so the
        // check runs against what will be compiled, not against a built product.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // maxmailinTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("maxmailin/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    /// Format placeholders with their positional index removed, so "%1$lld"
    /// and "%lld" compare equal — translations may reorder arguments.
    private static func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(@|lld|ld|d|f|\.\d+f|s|u|llu|lu|%)"#)
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .sorted()
    }

    private static func translatableKeys(_ catalog: Catalog) -> [String] {
        catalog.strings.compactMap { key, entry in
            if entry.shouldTranslate == false { return nil }
            if entry.extractionState == "stale" { return nil }
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return key
        }.sorted()
    }

    @Test("The catalog's source language is English and it is not a token effort")
    func catalogShape() throws {
        let catalog = try Self.loadCatalog()
        #expect(catalog.sourceLanguage == "en")
        // Fewer than this means the interface strings were not extracted.
        #expect(Self.translatableKeys(catalog).count > 2_500)
    }

    @Test("Every translatable key has a value in all ten languages")
    func everyKeyTranslated() throws {
        let catalog = try Self.loadCatalog()
        var missing: [String: [String]] = [:]
        for key in Self.translatableKeys(catalog) {
            let locs = catalog.strings[key]?.localizations ?? [:]
            for lang in Self.languages {
                let value = locs[lang]?.stringUnit?.value ?? ""
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    missing[lang, default: []].append(key)
                }
            }
        }
        for lang in Self.languages {
            let keys = missing[lang] ?? []
            #expect(keys.isEmpty, "\(lang): \(keys.count) untranslated, e.g. \(keys.prefix(5))")
        }
    }

    @Test("Every translation keeps its English placeholders")
    func placeholdersPreserved() throws {
        let catalog = try Self.loadCatalog()
        var broken: [String] = []
        for key in Self.translatableKeys(catalog) {
            let expected = Self.placeholders(key)
            let locs = catalog.strings[key]?.localizations ?? [:]
            for lang in Self.languages {
                guard let value = locs[lang]?.stringUnit?.value, !value.isEmpty else { continue }
                if Self.placeholders(value) != expected {
                    broken.append("\(lang): \(key)")
                }
            }
        }
        #expect(broken.isEmpty, "\(broken.count) placeholder mismatches, e.g. \(broken.prefix(5))")
    }

    @Test("The built app declares all eleven interface languages")
    func bundleDeclaresLanguages() {
        let declared = Set(Bundle.main.localizations)
        for lang in ["en"] + Self.languages {
            #expect(declared.contains(lang), "Bundle.main.localizations lacks \(lang)")
        }
    }
}


// MARK: - Real StoreKit 2 purchase flows (local StoreKit test environment)

/// Purchases, upgrades, refunds, expiry, Ask to Buy and Restore Purchases run
/// through StoreKit 2 against `maxmailin/Products.storekit` with
/// `SKTestSession`, and the app's own `StoreManager` decides the tier from
/// `Transaction.currentEntitlements` with the Debug all-unlocked shortcut
/// switched off — the same code path the App Store build takes. What this
/// does NOT cover: the App Store sandbox and Apple Account sign-in, which
/// need TestFlight.
#if os(iOS)
// iOS only: on macOS `Product.purchase()` needs a window to anchor its
// confirmation sheet, and the hosted test runner has none, so it waits
// minutes and fails. The entitlement code under test is shared.
@Suite("StoreKit purchase flows (local StoreKit test environment)", .serialized)
@MainActor
struct StoreKitPurchaseFlowTests {

    private static var configURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("maxmailin/Products.storekit")
    }

    private func freshSession() throws -> SKTestSession {
        let session = try SKTestSession(contentsOf: Self.configURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        return session
    }

    /// The live manager as the App Store build runs it: StoreKit products,
    /// StoreKit entitlements, no Debug unlock.
    private func liveStore() async -> StoreManager {
        let store = StoreManager()
        store.debugUnlocksAllTiers = false
        await store.loadProducts()
        await store.checkEntitlements()
        return store
    }

    private func product(_ id: String, in store: StoreManager) throws -> Product {
        try #require(store.products.first { $0.id == id }, "product \(id) loads from the StoreKit file")
    }

    /// Polls until `condition` holds (the transaction listener is async).
    private func eventually(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }

    @Test("A fresh install is Free: all six products load, nothing is unlocked, exports are capped")
    func freshInstallIsFree() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        let store = await liveStore()
        #expect(Set(store.products.map(\.id)) == StoreManager.allProductIDs)
        #expect(store.effectiveTier == .free)
        #expect(!store.isPremium)
        #expect(try ExportJobRunner.enforcedCap(savedCap: nil, isPremium: store.isPremium) == StoreManager.freeEmailLimit)
    }

    @Test("Buying Personal yearly unlocks Personal (not Professional) with a renewal date")
    func buyPersonalYearly() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        let store = await liveStore()
        let outcome = await store.purchase(try product(StoreManager.personalYearlyID, in: store))
        #expect(outcome == .success(.personal), "outcome: \(outcome)")
        #expect(store.isPremium)
        #expect(!store.isProfessional)
        #expect(!store.isLifetimePurchase)
        #expect(store.subscriptionExpirationDate != nil)
        #expect(try ExportJobRunner.enforcedCap(savedCap: StoreManager.freeEmailLimit, isPremium: store.isPremium) == nil)
    }

    @Test("Upgrading Personal to Professional lifetime unlocks Professional for life")
    func upgradeToProfessionalLifetime() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        let store = await liveStore()
        _ = await store.purchase(try product(StoreManager.personalMonthlyID, in: store))
        let outcome = await store.purchase(try product(StoreManager.professionalLifetimeID, in: store))
        #expect(outcome == .success(.professional), "outcome: \(outcome)")
        #expect(store.isProfessional)
        #expect(store.isLifetimePurchase)
        #expect(store.subscriptionExpirationDate == nil)
    }

    @Test("A refunded (revoked) purchase takes access away")
    func refundRevokesAccess() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        let store = await liveStore()
        _ = await store.purchase(try product(StoreManager.personalLifetimeID, in: store))
        #expect(store.isPremium)
        let transaction = try #require(session.allTransactions().first { $0.productIdentifier == StoreManager.personalLifetimeID })
        try session.refundTransaction(identifier: transaction.identifier)
        await store.checkEntitlements()
        #expect(await eventually { store.effectiveTier == .free }, "tier after refund: \(store.effectiveTier)")
    }

    @Test("A cancelled subscription lapses on its own at the end of the period, with the app left running")
    func cancelledSubscriptionLapsesWhileRunning() async throws {
        let session = try freshSession()
        defer { session.clearTransactions(); session.timeRate = .realTime }
        // One monthly period = 30 real seconds.
        session.timeRate = .monthlyRenewalEveryThirtySeconds
        let store = await liveStore()
        _ = await store.purchase(try product(StoreManager.professionalMonthlyID, in: store))
        #expect(store.isProfessional)
        let sub = try #require(session.allTransactions().first { $0.productIdentifier == StoreManager.professionalMonthlyID })
        try session.disableAutoRenewForTransaction(identifier: sub.identifier)
        // No checkEntitlements call from here on: the app must notice by itself.
        #expect(await eventually(60) { store.effectiveTier == .free },
                "tier after the period ended: \(store.effectiveTier); expiry \(String(describing: store.subscriptionExpirationDate)); now \(Date())")
    }

    @Test("An expired subscription grants nothing once the app is next active")
    func expiredSubscriptionOnActivation() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        let store = await liveStore()
        _ = await store.purchase(try product(StoreManager.personalMonthlyID, in: store))
        #expect(store.isPremium)
        let sub = try #require(session.allTransactions().first { $0.productIdentifier == StoreManager.personalMonthlyID })
        try session.disableAutoRenewForTransaction(identifier: sub.identifier)
        try session.expireSubscription(productIdentifier: StoreManager.personalMonthlyID)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await store.checkEntitlements()   // what the app does on becoming active
        #expect(store.effectiveTier == .free, "tier: \(store.effectiveTier)")
    }

    @Test("Ask to Buy: pending unlocks nothing; approval unlocks through the transaction listener")
    func askToBuyPendingThenApproved() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let store = await liveStore()
        let outcome = await store.purchase(try product(StoreManager.personalYearlyID, in: store))
        #expect(outcome == .pending, "outcome: \(outcome)")
        #expect(store.purchasePending)
        #expect(store.effectiveTier == .free, "nothing unlocks while pending")
        let pending = try #require(session.allTransactions().first { $0.productIdentifier == StoreManager.personalYearlyID })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        #expect(await eventually { store.effectiveTier == .personal }, "tier after approval: \(store.effectiveTier)")
    }

    @Test("Restore Purchases on a new install finds the purchase; with none it says so")
    func restorePurchases() async throws {
        let session = try freshSession()
        defer { session.clearTransactions() }
        let buyer = await liveStore()
        _ = await buyer.purchase(try product(StoreManager.professionalYearlyID, in: buyer))

        // A second manager stands in for the same Apple Account on a fresh install.
        let reinstall = StoreManager()
        reinstall.debugUnlocksAllTiers = false
        let restored = await reinstall.restorePurchases()
        #expect(restored == .restored(.professional), "restore outcome: \(restored)")
        #expect(reinstall.lastRestoreOutcome == restored)

        session.clearTransactions()
        let nobody = StoreManager()
        nobody.debugUnlocksAllTiers = false
        let none = await nobody.restorePurchases()
        #expect(none == .nothingFound, "restore with no purchases: \(none)")
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// Every Mac tool window is a new SwiftUI root built by ToolWindowPresenter.
/// Found 2026-10-04 (owner clicking Compare): the store was attached INSIDE
/// the purchase presenter that reads it, so every tool window crashed with
/// "No ObservableObject of type StoreManager found" the moment it rendered.
@Suite("Tool windows render with the store attached")
@MainActor
struct ToolWindowEnvironmentTests {
    @Test("A tool window renders its root (purchase presenter included) without crashing")
    func toolWindowRendersWithStore() throws {
        let store = StoreManager(testTier: .free)
        let previous = StoreManager.live
        StoreManager.live = store
        defer { StoreManager.live = previous }

        let title = "ToolWindowEnvironmentTests-\(UUID().uuidString)"
        ToolWindowPresenter.shared.open(title: title, size: CGSize(width: 700, height: 540)) {
            Text("probe")
        }
        let window = try #require(NSApp.windows.first { $0.title == title }, "the tool window opened")
        // Rendering evaluates PurchasePresenterModifier.body, which reads the store.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(window.contentView != nil)
        ToolWindowPresenter.shared.close(title: title)
    }

    /// A view that reads both shared objects the way EmailDetailView and the
    /// studios do; any missing one traps when it renders.
    private struct EnvironmentProbe: View {
        @EnvironmentObject var store: StoreManager
        @Environment(ModuleRegistry.self) private var modules
        var body: some View { Text("\(store.effectiveTier.rawValue) \(modules.enabledModules.count)") }
    }

    @Test("Every secondary window root provides the store AND the page registry")
    func windowRootProvidesStoreAndRegistry() throws {
        let store = StoreManager(testTier: .professional)
        let previousStore = StoreManager.live
        StoreManager.live = store
        defer { StoreManager.live = previousStore }
        let (registry, _) = makeRegistry()
        let previousModules = ModuleRegistry.live
        ModuleRegistry.live = registry
        defer { ModuleRegistry.live = previousModules }

        let host = NSHostingView(rootView: ToolWindowPresenter.windowRoot(EnvironmentProbe(), title: "probe"))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}
#endif

@Suite("Professional page profession filter")
@MainActor
struct ProfessionFilterTests {
    @Test("Every tool appears for at least one profession, and All tools shows everything")
    func everyToolHasAProfession() {
        for destination in ProfessionalPageView.toolDestinations {
            #expect(ProfessionalPageView.isRelevant(destination, to: nil))
            let owners = ProfessionalPageView.professions.filter { ProfessionalPageView.isRelevant(destination, to: $0) }
            #expect(!owners.isEmpty, "\(destination.rawValue) is shown to no profession")
        }
        #expect(ProfessionalPageView.showsProduction(for: nil))
        #expect(ProfessionalPageView.showsProduction(for: .legal))
    }

    @Test("Choosing a profession narrows the strip")
    func professionNarrows() {
        for p in ProfessionalPageView.professions {
            let shown = ProfessionalPageView.toolDestinations.filter { ProfessionalPageView.isRelevant($0, to: p) }
            #expect(shown.count < ProfessionalPageView.toolDestinations.count, "\(p.rawValue) shows every tool")
        }
    }
}

@Suite("AI suggestion sender names")
struct AISuggestionSenderTests {
    @Test("Display name without quotes, else the address, else empty")
    func senderNames() {
        #expect(AIAssistantView.senderDisplayName("\"Ann Lee\" <ann@example.org>") == "Ann Lee")
        #expect(AIAssistantView.senderDisplayName("Ann Lee <ann@example.org>") == "Ann Lee")
        #expect(AIAssistantView.senderDisplayName("<ann@example.org>") == "ann@example.org")
        #expect(AIAssistantView.senderDisplayName("ann@example.org") == "ann@example.org")
        #expect(AIAssistantView.senderDisplayName("") == "")
    }
}

