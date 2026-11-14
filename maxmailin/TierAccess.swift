//
//  TierAccess.swift
//  maxmailin
//
//  Which purchase each new 3.0 surface needs, in one place. Views lock
//  themselves with `TierGate`; code that runs without a view (Shortcuts
//  intents, import-time scripts, the risk score) reads `TierAccess.tier`,
//  which StoreManager publishes whenever the effective tier changes.
//
//  Recovery: Personal. Deep recovery and carving, Scripts, Shortcuts actions,
//  hidden timestamps and signature checks, sending a Review Pack, merging
//  responses, starting or applying a team case: Professional. Reviewing a
//  pack you received and joining a team case: Free — a reviewer needs no
//  licence to do the work they were sent.
//

import SwiftUI

enum TierAccess {
    /// The effective tier (StoreManager.publishAccessScope keeps it current).
    nonisolated(unsafe) static var tier: PurchaseTier = .free

    static func allows(_ needed: PurchaseTier) -> Bool { tier >= needed }

    enum Feature: CaseIterable {
        case recovery, deepRecovery, scripts, shortcutsActions, forensicSignals
        case sendReviewPack, reviewReceivedPack, startTeamCase, joinTeamCase

        var tier: PurchaseTier {
            switch self {
            case .recovery: return .personal
            case .deepRecovery, .scripts, .shortcutsActions, .forensicSignals, .sendReviewPack, .startTeamCase:
                return .professional
            case .reviewReceivedPack, .joinTeamCase:
                return .free
            }
        }

        var name: String {
            switch self {
            case .recovery: return String(localized: "Deleted-email recovery")
            case .deepRecovery: return String(localized: "Deep recovery and carving")
            case .scripts: return String(localized: "mailin Scripts")
            case .shortcutsActions: return String(localized: "Shortcuts actions")
            case .forensicSignals: return String(localized: "Hidden timestamps and signature checks")
            case .sendReviewPack: return String(localized: "Sending Review Packs")
            case .reviewReceivedPack: return String(localized: "Reviewing a pack")
            case .startTeamCase: return String(localized: "Leading a team case")
            case .joinTeamCase: return String(localized: "Joining a team case")
            }
        }
    }

    static func allows(_ f: Feature) -> Bool { allows(f.tier) }
}

/// Shows `content` when the purchase allows `feature`; otherwise says which
/// purchase it needs, with the way to buy it (the shared paywall).
struct TierGate<Content: View>: View {
    let feature: TierAccess.Feature
    var target: PurchasePresentationTarget = .settings
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var storeManager: StoreManager

    var body: some View {
        if storeManager.effectiveTier >= feature.tier {
            content()
        } else {
            VStack(spacing: Spacing.medium) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("\(feature.name) is part of \(feature.tier.displayName).")
                    .font(.headline).multilineTextAlignment(.center)
                Button {
                    storeManager.requestPurchase(feature.tier, feature: feature.name,
                                                 reason: String(localized: "\(feature.name) is part of \(feature.tier.displayName)."),
                                                 target: target)
                } label: {
                    Label(String(localized: "Unlock \(feature.tier.displayName)"), systemImage: "lock.open.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
