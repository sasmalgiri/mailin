//
//  AIProvenanceView.swift
//  mailin
//
//  Renders the AIProvenance record for a single AI answer. Used by the
//  AI Assistant and digest screens as a "Show Sources" disclosure so users
//  (and reviewers) can verify exactly which inputs produced an answer.
//

import SwiftUI

struct AIProvenanceView: View {
    let provenance: AIProvenance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                header
                routingSection
                evidenceSection
                kgSection
                findingsSection
                synthesisSection
                hashesSection
            }
            .padding()
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle("How this answer was made")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Image(systemName: "checkmark.shield")
                    .foregroundColor(.green)
                Text("Verifiable AI provenance")
                    .font(Typography.headline)
                Spacer()
                Text(provenance.createdAt, style: .date)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Text(provenance.query)
                .font(Typography.body)
                .foregroundColor(.primary)
                .padding(.vertical, Spacing.xxSmall)
            Text("This record is HMAC-chained into the forensic audit log when forensic mode is enabled, so it cannot be silently edited.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.medium)
    }

    private var routingSection: some View {
        section(title: "Routing") {
            row("Intent", provenance.intent)
            row("Persona", provenance.persona)
            row("Model", "\(provenance.modelGeneration)\(provenance.modelAvailable ? "" : " (fallback)")")
            if provenance.cloudCrossValidated {
                row("Cross-validation", "Cloud expert validated", icon: "checkmark.seal")
            }
            row("Experts", provenance.expertsRun.joined(separator: ", "))
            if !provenance.subQueries.isEmpty {
                row("Sub-queries", "\(provenance.subQueries.count)")
            }
            if !provenance.toolsUsed.isEmpty {
                row("Tools", provenance.toolsUsed.joined(separator: ", "))
            }
        }
    }

    private var evidenceSection: some View {
        section(title: "Evidence retrieved") {
            row("Archive size", "\(provenance.archiveEmailCount) emails")
            row("Retrieved", "\(provenance.retrievedEmailIDs.count) emails")
            if provenance.ragKeyChunkCount > 0 {
                row("Key passages", "\(provenance.ragKeyChunkCount)")
            }
        }
    }

    private var kgSection: some View {
        section(title: "Knowledge graph") {
            row("Edges in graph at synthesis", "\(provenance.kgEdgeCount)")
            row("Nodes cited in answer", "\(provenance.kgNodeIDs.count)")
            if !provenance.kgNodeIDs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(provenance.kgNodeIDs.prefix(20), id: \.self) { id in
                        Text(id)
                            .font(Typography.monoSmall)
                            .foregroundColor(.primary)
                    }
                    if provenance.kgNodeIDs.count > 20 {
                        Text("+\(provenance.kgNodeIDs.count - 20) more")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                .padding(Spacing.xSmall)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.small)
            }
        }
    }

    private var findingsSection: some View {
        section(title: "Findings") {
            row("Total findings", "\(provenance.totalFindings)")
            row("High relevance", "\(provenance.highRelevanceCount)")
            row("Linked to specific emails", "\(provenance.linkedFindings)")
        }
    }

    private var synthesisSection: some View {
        section(title: "Synthesis") {
            row("Compression layer", "Layer \(provenance.synthesisLayerCount)")
            row("Context characters", "\(provenance.contextCharCount)")
            row("Answer characters", "\(provenance.answerCharCount)")
        }
    }

    private var hashesSection: some View {
        section(title: "Reproducibility hashes (SHA-256)") {
            row("Archive snapshot", provenance.archiveHash.prefix(16) + "…", mono: true)
            row("Graph snapshot", provenance.kgSnapshotHash.prefix(16) + "…", mono: true)
            row("Provenance ID", provenance.id.uuidString.prefix(12) + "…", mono: true)
            Text("If the archive and graph hashes match a future run, the same query will produce the same routing and findings.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .padding(.top, Spacing.xxSmall)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text(title.uppercased())
                .font(Typography.caption1)
                .fontWeight(.semibold)
                .foregroundColor(AppColors.secondary)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                content()
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.medium)
        }
    }

    private func row(_ label: String, _ value: String, icon: String? = nil, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(label)
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .frame(width: 150, alignment: .leading)
            if let icon { Image(systemName: icon).foregroundColor(.green) }
            Text(value)
                .font(mono ? Typography.monoSmall : Typography.callout)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private func row(_ label: String, _ value: Substring, mono: Bool = false) -> some View {
        row(label, String(value), mono: mono)
    }
}

#Preview {
    NavigationStack {
        AIProvenanceView(provenance: AIProvenance(
            createdAt: Date(),
            query: "Find privileged communications between Alex and counsel",
            intent: "entity",
            persona: "legal",
            modelGeneration: "AppleFoundationModel",
            modelAvailable: true,
            cloudCrossValidated: false,
            expertsRun: ["kgExpert", "entityExpert", "securityExpert"],
            subQueries: ["who is counsel", "messages between Alex and counsel"],
            toolsUsed: ["analyzeEmails", "spotlightSearch"],
            archiveEmailCount: 526,
            retrievedEmailIDs: [UUID(), UUID(), UUID()],
            ragKeyChunkCount: 8,
            kgNodeIDs: ["person:alex@acme.example", "person:counsel@firm.example", "topic:litigation"],
            kgEdgeCount: 1241,
            totalFindings: 12,
            highRelevanceCount: 4,
            linkedFindings: 9,
            synthesisLayerCount: 3,
            contextCharCount: 8420,
            answerCharCount: 1240,
            archiveHash: "a31b9d…",
            kgSnapshotHash: "7f0e22…",
            metricsRecordID: nil
        ))
    }
}
