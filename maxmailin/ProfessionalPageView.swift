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
    @State private var presented: HubDestination?

    private struct Tool: Identifiable {
        let destination: HubDestination
        let title: String
        let symbol: String
        var id: String { destination.rawValue }
    }

    private let studios: [Tool] = [
        Tool(destination: .achMatrix, title: "Hypothesis Matrix", symbol: "tablecells"),
        Tool(destination: .factMatrix, title: "Fact–Evidence", symbol: "checklist"),
        Tool(destination: .actionRegister, title: "Action Register", symbol: "list.bullet.clipboard"),
        Tool(destination: .evidenceDesks, title: "Evidence Desks", symbol: "square.grid.3x3"),
        Tool(destination: .reasoningStudio, title: "Reasoning Studio", symbol: "brain.head.profile"),
    ]
    private let tools: [Tool] = [
        Tool(destination: .custodianPanel, title: "Custodians & Holds", symbol: "person.badge.shield.checkmark"),
        Tool(destination: .chainOfCustody, title: "Chain of Custody", symbol: "link"),
        Tool(destination: .eDiscovery, title: "eDiscovery", symbol: "doc.text.magnifyingglass"),
        Tool(destination: .batesNumbering, title: "Bates Numbering", symbol: "number"),
        Tool(destination: .redaction, title: "Redaction", symbol: "eye.slash"),
        Tool(destination: .reviewBatches, title: "Review Batches", symbol: "square.stack.3d.up"),
        Tool(destination: .investigationReport, title: "Investigation Report", symbol: "doc.richtext"),
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
                Text("Studios").font(.caption).foregroundStyle(.secondary)
                ForEach(studios) { tool in toolButton(tool) }
                Divider().frame(height: 18)
                Text("Tools").font(.caption).foregroundStyle(.secondary)
                ForEach(tools) { tool in toolButton(tool) }
                Divider().frame(height: 18)
                Button {
                    openProductionWindow()
                } label: {
                    Label("Production…", systemImage: "shippingbox")
                }
                .help("Produce a Bates-stamped set with a hash manifest, an exclusion log and a numbered production record")
                .accessibilityIdentifier("professional.production")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .controlSize(.small)
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button { open(tool.destination) } label: {
            Label(tool.title, systemImage: tool.symbol)
        }
        .help("Open \(tool.title)")
        .accessibilityIdentifier("professional.tool.\(tool.destination.rawValue)")
    }

    private func open(_ destination: HubDestination) {
        #if os(macOS)
        ToolWindowPresenter.shared.open(title: destination.rawValue, size: CGSize(width: 1000, height: 700)) {
            AnyView(ProfessionalDestinationView(destination: destination).toolWindowFrame())
        }
        #else
        presented = destination
        #endif
    }

    private func openProductionWindow() {
        #if os(macOS)
        ToolWindowPresenter.shared.open(title: "Production", size: CGSize(width: 760, height: 720)) {
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
