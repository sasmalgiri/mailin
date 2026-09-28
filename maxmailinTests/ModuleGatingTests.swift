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

        #expect(ReportBuilderView.coverageNote(matching: 120, processed: 120).hasPrefix("All 120"))
        #expect(ReportBuilderView.coverageNote(matching: 12_000, processed: 5_000).contains("newest 5,000 of 12,000"))
    }

    @Test("Email Analytics (sentiment + NLP passes) belongs to AI Insights")
    func emailAnalyticsOwnedByAIInsights() {
        #expect(HubDestination.emailAnalytics.owner == .aiInsights)
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
