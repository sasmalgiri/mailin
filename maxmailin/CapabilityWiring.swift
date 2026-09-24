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
            } else {
                AttachmentHydrator.locatorProvider = nil
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
             .reasoningStudios:
            // Gated at the point of use — the surface asks the registry. No
            // pushed flag to keep in step, which is the preferable shape;
            // these cases are listed explicitly rather than behind `default`
            // so a new capability has to make a deliberate choice here.
            break
        }
    }

    /// Applies every capability. Called once at launch, after the registry has
    /// loaded state and mapped legacy defaults.
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
