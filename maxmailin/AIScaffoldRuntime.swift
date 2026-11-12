//
//  AIScaffoldRuntime.swift
//  maxmailin
//
//  Plan v4 SCAF-01…05 (§0 items 3–5, §8.4, §14): the app-side glue for the
//  disabled BYOK AI scaffolding in ArchiveCore/AIScaffold.
//
//  What this release contains: contracts, the Keychain profile store, an
//  independent AI policy, consent / budget / ledger contracts and fakes.
//  What it does NOT contain: a live transport, a settings screen, a menu item,
//  a background job or any caller in the primary journey. A saved key is not
//  an AI feature. The legacy cloud code (`CloudAIProvider`, `CloudAIConsent`)
//  stays compiled only under `MAILIN_CLOUD_AI`, which no configuration sets.
//
//  Entitlement (SCAF-04): the existing Pro (Professional) entitlement, read
//  through the existing `AccessPolicy`; no new product, no price change. A key
//  never unlocks Pro and Pro never starts inference by itself.
//

@testable import ArchiveCore
import Foundation

enum AIScaffoldRuntime {
    /// No live AI route ships in this release.
    static var liveInferenceAvailable: Bool {
        AIProductionTransport.liveInferenceShipped && AIProductionTransport.current.isAvailable
    }

    /// The key-profile settings stay hidden (not reachable) until a runtime exists.
    static var showsKeyProfileSettings: Bool { liveInferenceAvailable }

    /// The coordinator the app would use: the production (unavailable)
    /// transport, the shared independent AI policy, the real Keychain store,
    /// and a consent queue no screen drives. Every `submit` is refused.
    @MainActor
    static func makeCoordinator(store: StoreManager?) -> AIRequestCoordinator {
        AIRequestCoordinator(policy: .shared,
                             entitlement: ProAIEntitlement(state: store?.entitlementState ?? .free),
                             keys: AIKeyProfileStore(),
                             consent: AIPendingConsentQueue(),
                             budget: AIRunBudget(perRunLimit: 0, periodLimit: 0),
                             transport: AIProductionTransport.current)
    }
}

/// SCAF-04: the existing Pro entitlement as the coordinator's gate. Only an
/// active or lifetime Professional plan allows AI work; Free, Personal and a
/// lapsed plan do not (LIFE-06 keeps their data, not new paid work).
struct ProAIEntitlement: AIEntitlementGate {
    let state: EntitlementState

    var allowsAIWork: Bool {
        guard AccessPolicy(state: state).allowsPaidWork else { return false }
        switch state {
        case .active(let tier), .lifetime(let tier): return tier >= .professional
        case .free, .lapsed: return false
        }
    }
}
