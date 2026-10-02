@testable import ArchiveCore
//
//  ProfessionalPageView.swift
//  maxmailin
//
//  F-1: Page 3's shell. The Work Center is the job catalog / active work /
//  outputs surface (Workflows · My Work · Intake · Jobs · Documents ·
//  Reports); this view hosts it full-size and adds the strip of studios and
//  tools the page owns, each opening in its own window. Before this, the
//  page hosted `WorkCenterView()` with no destination handler, so a workflow
//  step that launches a tool went nowhere on Page 3.
//

import SwiftUI

struct ProfessionalPageView: View {
    @Environment(ModuleRegistry.self) private var modules
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.purchasePresentationTarget) private var purchaseTarget
    @State private var presented: HubDestination?

    struct Tool: Identifiable {
        let destination: HubDestination
        let title: String
        let symbol: String
        var id: String { destination.rawValue }
    }

    /// Every destination this page can launch (strip + Work Center steps).
    /// Each one is Professional-tier work: `StoreManager.requiredTier(for:)`
    /// answers `.professional` for all of them (pinned by a test).
    static var toolDestinations: [HubDestination] {
        (studios + tools).map(\.destination)
    }

    /// The destination behind a strip title ("Chain of Custody" → `.chainOfCustody`).
    static func destination(forTitle title: String) -> HubDestination? {
        (studios + tools).first { $0.title == title }?.destination
    }

    private static let studios: [Tool] = [
        Tool(destination: .achMatrix, title: String(localized: "Hypothesis Matrix"), symbol: "tablecells"),
        Tool(destination: .factMatrix, title: String(localized: "Fact–Evidence"), symbol: "checklist"),
        Tool(destination: .actionRegister, title: String(localized: "Action Register"), symbol: "list.bullet.clipboard"),
        Tool(destination: .evidenceDesks, title: String(localized: "Evidence Desks"), symbol: "square.grid.3x3"),
        Tool(destination: .reasoningStudio, title: String(localized: "Reasoning Studio"), symbol: "brain.head.profile"),
    ]
    private static let tools: [Tool] = [
        Tool(destination: .custodianPanel, title: String(localized: "Custodians & Holds"), symbol: "person.badge.shield.checkmark"),
        Tool(destination: .chainOfCustody, title: String(localized: "Chain of Custody"), symbol: "link"),
        Tool(destination: .eDiscovery, title: "eDiscovery", symbol: "doc.text.magnifyingglass"),
        Tool(destination: .batesNumbering, title: String(localized: "Bates Numbering"), symbol: "number"),
        Tool(destination: .redaction, title: String(localized: "Redaction"), symbol: "eye.slash"),
        Tool(destination: .reviewBatches, title: String(localized: "Review Batches"), symbol: "square.stack.3d.up"),
        Tool(destination: .investigationReport, title: String(localized: "Investigation Report"), symbol: "doc.richtext"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolStrip
            Divider()
            WorkCenterView(onOpenDestination: { open($0) }, onClose: {})
        }
        .sheet(item: $presented) { destination in
            NavigationStack {
                ProfessionalDestinationView(destination: destination)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { presented = nil }
                        }
                    }
            }
            .frame(minWidth: 900, minHeight: 640)
        }
        .accessibilityIdentifier("professional.page")
    }

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                #if !ENTERPRISE_EDITION
                if !storeManager.isProfessional {
                    // The page is on (module consent) but the work is not
                    // bought: say so once, up front, with the way to buy it.
                    Button {
                        storeManager.requestPurchase(.professional,
                                                     feature: String(localized: "Professional Workflows"),
                                                     reason: String(localized: "Custodians and holds, chain of custody, eDiscovery, Bates numbering, production and the studios are part of the Professional purchase."),
                                                     target: purchaseTarget)
                    } label: {
                        Label("Unlock Professional", systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .help("The tools on this page need the Professional purchase")
                    .accessibilityIdentifier("professional.unlock")
                    Divider().frame(height: 18)
                }
                #endif
                Text("Studios").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.studios) { tool in toolButton(tool) }
                Divider().frame(height: 18)
                Text("Tools").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.tools) { tool in toolButton(tool) }
                Divider().frame(height: 18)
                Button {
                    openProductionWindow()
                } label: {
                    Label("Production…", systemImage: storeManager.isProfessional ? "shippingbox" : "lock.fill")
                }
                .help(storeManager.isProfessional
                      ? "Produce a Bates-stamped set with a hash manifest, an exclusion log and a numbered production record"
                      : "Production needs the Professional purchase")
                .accessibilityIdentifier("professional.production")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .controlSize(.small)
    }

    private func toolButton(_ tool: Tool) -> some View {
        let required = StoreManager.requiredTier(for: tool.destination)
        let locked = storeManager.effectiveTier < required
        return Button { open(tool.destination) } label: {
            // Discoverable when locked (the name stays), execution gated in
            // `open`. The lock says why a click shows the paywall.
            Label(tool.title, systemImage: locked ? "lock.fill" : tool.symbol)
        }
        .help(locked ? "\(tool.title) needs the \(required.displayName) purchase" : "Open \(tool.title)")
        .accessibilityIdentifier("professional.tool.\(tool.destination.rawValue)")
    }

    /// The single launch point for this page's tools — the strip, a Work
    /// Center workflow step and the compact sheet all pass through here — so
    /// the purchase gate cannot be bypassed by the route taken. Turning the
    /// page on is module consent; the Professional purchase is what unlocks
    /// execution (same rule as the Archive page's hub).
    private func open(_ destination: HubDestination) {
        let required = StoreManager.requiredTier(for: destination)
        let title = (Self.studios + Self.tools).first { $0.destination == destination }?.title ?? destination.rawValue
        guard storeManager.require(required,
                                   feature: title,
                                   reason: "\(title) is part of the \(required.displayName) purchase\(required == .personal ? " and of Professional" : "").",
                                   target: purchaseTarget) else { return }
        #if os(macOS)
        ToolWindowPresenter.shared.open(title: destination.rawValue, size: CGSize(width: 1000, height: 700)) {
            AnyView(ProfessionalDestinationView(destination: destination).toolWindowFrame())
        }
        #else
        presented = destination
        #endif
    }

    private func openProductionWindow() {
        guard storeManager.require(.professional,
                                   feature: String(localized: "Production"),
                                   reason: String(localized: "Producing a Bates-stamped set with a hash manifest is part of the Professional purchase."),
                                   target: purchaseTarget) else { return }
        #if os(macOS)
        ToolWindowPresenter.shared.open(title: String(localized: "Production"), size: CGSize(width: 760, height: 720)) {
            AnyView(ProductionWindowView().toolWindowFrame())
        }
        #else
        presented = .batesNumbering
        #endif
    }
}

/// Page 3's destinations, mirrored from the Archive hub's mapping so the
/// same tool opens the same view from either page. Working-set tools are
/// hydrated through `ArchiveWorkingSetView` (bounded, never the corpus).
struct ProfessionalDestinationView: View {
    let destination: HubDestination

    var body: some View {
        switch destination {
        case .achMatrix:
            ACHMatrixStudioView().navigationTitle("Hypothesis Matrix (ACH)")
        case .factMatrix:
            FactEvidenceStudioView().navigationTitle("Fact–Evidence Matrix")
        case .actionRegister:
            ActionRegisterStudioView().navigationTitle("Action Register")
        case .evidenceDesks:
            ArchiveWorkingSetView(query: .all) { EvidenceDesksStudioView(workingSet: $0) }.navigationTitle("Evidence Desks")
        case .reasoningStudio:
            ReasoningStudioView().navigationTitle("Reasoning Studio")
        case .eDiscovery:
            ArchiveWorkingSetView(query: .all) { EDiscoveryWorkflowView(emails: $0) }.navigationTitle("eDiscovery Workflow")
        case .custodianPanel:
            CustodianPanelView(manager: CustodianManager.shared).navigationTitle("Custodian Panel")
        case .chainOfCustody:
            ArchiveWorkingSetView(query: .all) { ChainOfCustodyView(emails: $0) }.navigationTitle("Chain of Custody")
        case .batesNumbering:
            ArchiveWorkingSetView(query: .all) { BatesConfigView(emails: $0) }.navigationTitle("Bates Numbering")
        case .redaction:
            ArchiveWorkingSetView(query: .all) { RedactionConfigView(emails: $0) }.navigationTitle("Redaction")
        case .reviewBatches:
            ArchiveWorkingSetView(query: .all) { ReviewBatchPanelView(emails: $0, manager: ReviewBatchManager.shared) }.navigationTitle("Review Batches")
        case .investigationReport:
            ArchiveWorkingSetView(query: .all) { InvestigationReportConfigSheet(emails: $0, senderEmail: "") }.navigationTitle("Investigation Report")
        case .phishingTriage:
            TriageQueueView().navigationTitle("Phishing Triage")
        case .storyFile:
            StoryFileView().navigationTitle("Story File")
        case .reviewDashboard:
            ReviewDashboardView().navigationTitle("Review Dashboard")
        default:
            ContentUnavailableView("Open from the Archive page",
                                   systemImage: "square.grid.2x2",
                                   description: Text("\(destination.rawValue) lives in the Archive page's Tools hub."))
        }
    }
}
