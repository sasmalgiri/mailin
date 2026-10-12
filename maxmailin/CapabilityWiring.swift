@testable import ArchiveCore
//
//  CapabilityWiring.swift
//  mailin
//
//  Applies a capability switch to the non-UI machinery behind it.
//
//  Why a separate type: most capabilities are gated where they are *used* (a
//  view asks `modules.isOn(...)` and renders or does not). A few, though, are
//  read from synchronous, non-main-actor code — the attachment reader and the
//  export writer — which cannot capture the main-actor registry. Those need a
//  plain flag that the registry pushes to them whenever it changes.
//
//  The alternative was for the readers to consult the registry directly, which
//  would mean making them main-actor, which would mean making export
//  main-actor. That trade is not worth it for a boolean.
//
//  Called at launch for every capability, and again whenever one is switched,
//  so a toggle takes effect immediately rather than on next launch.
//

import Foundation

enum CapabilityWiring {

    /// Pushes one capability's state into whatever needs it as a plain flag.
    ///
    /// `isOn` here is the FULLY resolved answer from
    /// `ModuleRegistry.isOn(_:)` — page on, switch on, dependencies on — not
    /// the raw switch position. A capability whose page is off must leave its
    /// machinery disarmed.
    static func apply(_ capability: Capability, isOn: Bool) {
        switch capability {
        case .v3SQLiteHygiene:
            // §3-S2/S9: read when a connection opens.
            SQLiteHygiene.isEnabled = isOn
        case .v3Snapshots:
            // §3-S1: pre-upgrade snapshots are taken when the store opens.
            ArchiveSnapshotPolicy.isEnabled = isOn
        case .v3SafeHTML:
            SafeHTMLPolicy.isEnabled = isOn
        case .v31Recovery:
            RecoveryPolicy.isEnabled = isOn
        case .v31DeepRecovery:
            RecoveryPolicy.deepRecoveryEnabled = isOn
        case .v31Scripts:
            // S5–S7: on-demand runs read the flag; import-time scripts hook the importer.
            ScriptPolicy.isEnabled = isOn
            ScriptImportRunner.install(isOn)
        case .v31ShortcutsActions:
            // S1–S4: intents run without a view, so they read a pushed flag.
            ShortcutsPolicy.actionsEnabled = isOn
        case .v3AlertsAnomalies:
            // §3-A1: background findings over the whole archive.
            BackgroundAnalysisManager.wholeArchiveEnabled = isOn
        case .v3PredictiveCoding:
            PredictiveCodingEngine.wholeArchiveEnabled = isOn
        case .v3AIAnswers:
            // §3-I3/I4: AI enhancements read emails chosen from the whole archive.
            AIContextSelector.isEnabled = isOn
        case .v3SemanticSearch:
            ArchiveRetrievalService.semanticFusionEnabled = isOn
        case .v3SearchOperators:
            ArchiveQueryCompiler.exclusionsEnabled = isOn
        case .v3PagedLists:
            SQLiteEmailStore.unboundedIDLookups = isOn
            V3Paging.isOn = isOn
        case .v3EvidenceReceipts:
            // §3-E4: import receipts record who, which tool and the settings.
            if isOn {
                let provider: @Sendable () -> (custodian: String?, tool: String, settings: [String: String]) = {
                    let defaults = UserDefaults.standard
                    let state = ModuleStateStore(url: ModuleStateStore.productionURL).load()
                    var settings: [String: String] = [:]
                    for c in [Capability.blobTier, .offsetParser, .externalStorage, .locatorReads] {
                        settings[c.rawValue] = state.isCapabilitySet(c) ? "on" : "off"
                    }
                    if let caseNumber = defaults.string(forKey: "forensicCaseNumber"), !caseNumber.isEmpty {
                        settings["caseNumber"] = caseNumber
                    }
                    let examiner = defaults.string(forKey: "forensicExaminerName")
                    return (custodian: (examiner?.isEmpty ?? true) ? nil : examiner,
                            tool: "mailin \(EngineGuard.appVersion)", settings: settings)
                }
                ImportReceipt.collectionContextProvider = provider
            } else {
                ImportReceipt.collectionContextProvider = nil
            }
        case .v3LegalState:
            // §3-F4: the custodian/hold/seal manager dual-writes into SQLite
            // while on; turning on migrates the existing files once.
            LegalStateMirror.isEnabled = isOn
            CollectToPreserve.engineOn = isOn
            // Recovery of an interrupted direct database write runs whatever
            // the switch (rule 16); off means the files alone are the truth.
            Task { @MainActor in
                await LegalStateMirror.shared.recoverInterruptedDatabaseWrite()
                if isOn { await LegalStateMirror.shared.activate() } else { await LegalStateMirror.shared.deactivate() }
            }
        case .locatorReads:
            // S5. Off means the readers fall back to the stored raw MIME,
            // exactly as they did before the capability existed.
            //
            // Hoisted out of a ternary deliberately: the type-checker cannot
            // infer a @Sendable closure through `?:`, and the failure mode is
            // an unhelpful "failed to produce diagnostic" rather than a
            // sensible error.
            if isOn {
                let provider: @Sendable (UUID) -> MessageLocator? = { id in
                    SQLiteEmailStore.locatorSnapshot(emailID: id)
                }
                AttachmentHydrator.locatorProvider = provider
                // Per-part ranges ride the same switch: both are locator
                // reads, and a part range without its message locator is
                // unusable anyway — the message locator is what supplies the
                // source path.
                let parts: @Sendable (UUID) -> [PartLocator] = { id in
                    SQLiteEmailStore.partSnapshot(emailID: id)
                }
                AttachmentHydrator.partProvider = parts
            } else {
                AttachmentHydrator.locatorProvider = nil
                AttachmentHydrator.partProvider = nil
            }

        case .aiAssistant:
            // Language detection's low-confidence path consults the on-device
            // model. It is reached from ARCHIVE analytics, so without this
            // gate a Page-1-only install invokes an AI model — a page
            // independence violation (§3.3 R1–R6). Gated on `aiAssistant`
            // because that is the capability whose page owns model access;
            // with it off, detection still works, just from NLP alone.
            // Hoisted, not a ternary: the type-checker cannot infer a
            // @Sendable closure through `?:` and fails with an unhelpful
            // "failed to produce diagnostic" — the same trap as `.locatorReads`
            // above.
            if isOn {
                let gate: @Sendable () -> Bool = { true }
                EmailNLPEngine.modelLanguageFallbackGate = gate
            } else {
                EmailNLPEngine.modelLanguageFallbackGate = nil
            }

        case .blobTier, .offsetParser, .externalStorage, .guidedImport,
             .importQueue, .searchCoverageBadge,
             .aiDigest, .anomalyDetection, .smartAutoTagger,
             .topicClusters, .threadSummarizer, .smartAlerts, .keywordMonitor,
             .predictiveCoding, .custodianPanel, .reviewBatches, .auditTrail,
             .eDiscovery, .batesNumbering, .redaction, .gdprReport,
             .chainOfCustody, .investigationReport, .reportBuilder,
             .reasoningStudios,
             .v3ScopeEngine,
             .v3FeatureIndex,
             .v3Fingerprints,
             .v3Duplicates,
             .v3AnalysisQueries,
             .v3NearDuplicates,
             .v3TopicClusters,
             .v3Threads,
             .v3Graphs,
             .v3KeywordMonitor,
             .v3EDiscovery,
             .v3Bates,
             .v3ChainOfCustody,
             .v3Custodians,
             .v3ReviewBatches,
             .v3BatchOperations,
             .v3AutomationRules,
             .v3PrivilegeScan,
             .v3PIIReport,
             .v3IOC,
             .v3InvestigationReport,
             .v3LegalReview,
             .v3EvidenceDesks,
             .v3PreservationExport,
             .v31ReviewPack, .v31TeamCase, .v31ForensicTimestamps:
            // Gated at the point of use — the surface asks the registry. No
            // pushed flag to keep in step, which is the preferable shape;
            // these cases are listed explicitly rather than behind `default`
            // so a new capability has to make a deliberate choice here.
            break
        }
    }

    /// Applies every capability. Called once at launch, after the registry has
    /// loaded state and mapped legacy defaults.
    /// §3-S1/S2: the store-level 3.0 switches must be armed before the archive
    /// store opens its first connection (a pre-upgrade snapshot is taken at
    /// open). Called from the app's `init`, before any view exists, straight
    /// from the persisted switch positions. Both are Archive-page engines, and
    /// the Archive page is always on.
    static func applyStoreLevelEarly() {
        let state = ModuleStateStore(url: ModuleStateStore.productionURL).load()
        SQLiteHygiene.isEnabled = state.isCapabilitySet(.v3SQLiteHygiene)
        ArchiveSnapshotPolicy.isEnabled = state.isCapabilitySet(.v3Snapshots)
    }

    @MainActor
    static func applyAll(_ registry: ModuleRegistry) {
        for capability in Capability.allCases {
            apply(capability, isOn: registry.isOn(capability))
        }
    }

    /// Disarms everything this type has pushed.
    ///
    /// Exists because these flags are process-global by design, and that has
    /// teeth: a test that enabled AI Insights through a throwaway registry
    /// left `EmailNLPEngine.modelLanguageFallbackGate` installed for every
    /// test that ran afterwards, so archive analytics started calling the
    /// on-device model and `testFullAnalytics_streamingEqualsArrayOracle`
    /// began reporting message body text as a language name. The leak was
    /// invisible until an assertion happened to compare two runs.
    ///
    /// Any test that touches capability state should call this in teardown.
    static func resetAll() {
        for capability in Capability.allCases {
            apply(capability, isOn: false)
        }
    }
}
