@testable import ArchiveCore
//
//  AIInsightsPageView.swift
//  maxmailin
//
//  I1: Page 2's shell. A scope bar (source + date) narrows what every tab
//  works on; the tabs host the existing surfaces — Ask (`AIAssistantView`),
//  Summaries (`AIDigestView`), Reports (`ReportBuilderView`). Page 2 never
//  inherits Page 1's current filter: its scope is its own, and it is shown.
//
//  I4: the opt-in semantic index lives here too (build / pause / progress),
//  because it is a Page-2 job that must not run while Page 2 is off.
//

import SwiftUI

struct AIInsightsPageView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case ask = "Ask"
        case summaries = "Summaries"
        case reports = "Reports"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .ask: return "sparkles"
            case .summaries: return "doc.text.magnifyingglass"
            case .reports: return "doc.richtext"
            }
        }
    }

    @Environment(ModuleRegistry.self) private var modules
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.purchasePresentationTarget) private var purchaseTarget
    /// Same counter `AIAssistantView` consumes, so the number here is the
    /// number Ask will enforce.
    @AppStorage("freeAIQueryCount") private var freeQueryCount: Int = 0
    @State private var tab: Tab = .ask
    @State private var sources: [SQLiteEmailStore.StoredSource] = []
    @State private var selectedSource: String? = nil       // filename
    @State private var dateScope: ArchiveDateScope = .all
    @State private var semanticIndex = SemanticIndexController.shared

    /// The operator string the Ask tab receives as its search context, so
    /// retrieval is narrowed the same way the lists are.
    private var scopeContext: String {
        var parts: [String] = []
        if let selectedSource { parts.append("source:\(selectedSource.contains(" ") ? "\"\(selectedSource)\"" : selectedSource)") }
        if let after = dateScope.after {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            parts.append("after:\(f.string(from: after))")
        }
        return parts.joined(separator: " ")
    }

    /// Audit F14: the same scope as a typed query, so Summaries and Reports
    /// read the corpus their label names — not the whole archive.
    private var scopeQuery: EmailQuery { ArchiveQueryCompiler.compile(scopeContext) }

    private var scopeLabel: String {
        var label = selectedSource ?? "Whole archive"
        if dateScope != .all { label += " · \(dateScope.rawValue)" }
        return label
    }

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            content
        }
        .task { sources = (try? await ArchiveDataService.shared.sources()) ?? [] }
        // Back / Forward remembers the tab (Ask, Summaries, Reports).
        .navigationSection(.aiInsights, current: tab.rawValue) { section in
            if let section, let target = Tab(rawValue: section) { tab = target }
        }
        .accessibilityIdentifier("aiInsights.page")
    }

    private var scopeBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("aiInsights.tabs")

            #if !ENTERPRISE_EDITION
            if !storeManager.isPremium {
                // The Free allowance Ask enforces, visible before the sixth
                // query is refused; one tap opens Personal selected.
                let remaining = max(0, AIAssistantView.freeQueryLimit - freeQueryCount)
                Button {
                    storeManager.requestPurchase(.personal,
                                                 feature: String(localized: "AI Insights"),
                                                 reason: String(localized: "Personal and Professional remove the daily Ask limit and include Summaries and Reports."),
                                                 target: purchaseTarget)
                } label: {
                    Text("\(remaining) of \(AIAssistantView.freeQueryLimit) free Ask queries left today")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(remaining == 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help("The Free plan allows \(AIAssistantView.freeQueryLimit) Ask queries a day. Click to see plans.")
                .accessibilityIdentifier("aiInsights.freeQuota")
            }
            #endif

            Spacer()

            Menu {
                Button("Whole archive") { selectedSource = nil }
                if !sources.isEmpty {
                    Divider()
                    ForEach(sources, id: \.sourceID) { source in
                        Button(source.filename) { selectedSource = source.filename }
                    }
                }
            } label: {
                Label(selectedSource ?? "Whole archive", systemImage: "archivebox")
                    .lineLimit(1)
            }
            .help("Which imported source the page works on")
            .accessibilityIdentifier("aiInsights.scope.source")

            Menu {
                Picker("Date", selection: $dateScope) {
                    ForEach(ArchiveDateScope.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label(dateScope.rawValue, systemImage: "calendar")
            }
            .help("Limit the page to a date range")
            .accessibilityIdentifier("aiInsights.scope.date")

            if modules.isOn(.aiAssistant) {
                semanticIndexControl
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// I4: opt-in, resumable, visible progress, off by default.
    private var semanticIndexControl: some View {
        Menu {
            Toggle("Build semantic index", isOn: Binding(
                get: { semanticIndex.isEnabled },
                set: { semanticIndex.setEnabled($0, modules: modules) }))
            if semanticIndex.isEnabled {
                Text(semanticIndex.statusLine)
                if semanticIndex.isRunning {
                    Button("Pause") { semanticIndex.pause() }
                } else if semanticIndex.pending > 0 {
                    Button("Resume") { semanticIndex.resume(modules: modules) }
                }
                Divider()
                Button("Delete the index", role: .destructive) { semanticIndex.deleteIndex() }
            }
            Text("Sentence vectors for subject and preview, computed on this Mac; never sent anywhere. Lets Ask find messages that say the same thing in different words.")
        } label: {
            Label(semanticIndex.isEnabled ? (semanticIndex.isRunning ? "Indexing \(Int(semanticIndex.fraction * 100))%" : "Semantic index") : "Semantic index off",
                  systemImage: semanticIndex.isEnabled ? "point.3.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
        }
        .help("On-device semantic index for Ask (opt-in, resumable)")
        .accessibilityIdentifier("aiInsights.semanticIndex")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .ask:
            AIAssistantView(archiveScope: .all, searchContext: scopeContext, showsDoneButton: false)
                .id(scopeContext)   // a new scope is a new conversation context
        // Summaries and Reports are paid (Personal or Professional) on the
        // Archive page's hub; the same rule applies here. Ask keeps its own
        // free allowance inside `AIAssistantView`, identical from both routes.
        // Turning the AI Insights page on is module consent, not a purchase.
        case .summaries:
            if storeManager.isPremium {
                AIDigestView(scope: scopeQuery)
                    .id(scopeContext)
            } else {
                PaidFeatureLockedView(title: String(localized: "Summaries"), requiredTier: .personal,
                                      detail: String(localized: "AI summaries of a source or a date range are part of the Personal and Professional purchases."))
            }
        case .reports:
            if storeManager.isPremium {
                ReportBuilderView(scope: scopeQuery)
                    .id(scopeContext)
            } else {
                PaidFeatureLockedView(title: String(localized: "Reports"), requiredTier: .personal,
                                      detail: String(localized: "Report building is part of the Personal and Professional purchases."))
            }
        }
    }
}

/// What a page shows in place of a paid surface the current tier does not
/// cover: the feature stays discoverable, nothing about it runs, and one
/// button opens the paywall. Reads the store manager from the environment.
struct PaidFeatureLockedView: View {
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.purchasePresentationTarget) private var purchaseTarget
    let title: String
    let requiredTier: PurchaseTier
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label("\(title) is a \(requiredTier.displayName) feature", systemImage: "lock.fill")
        } description: {
            Text(detail)
        } actions: {
            // Opens the purchase screen with THIS tier selected and this
            // feature named as the reason, in the window the view lives in.
            Button("Unlock with \(requiredTier.displayName)…") {
                storeManager.requestPurchase(requiredTier, feature: title, reason: detail, target: purchaseTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(requiredTier == .professional ? .purple : .blue)
            .accessibilityIdentifier("paid.unlock.\(title)")
        }
        .accessibilityIdentifier("paid.locked.\(title)")
    }
}
