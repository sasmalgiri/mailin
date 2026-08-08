//
//  FeatureGuideView.swift
//  maxmailin
//
//  Searchable guide to EVERY feature in the app: type a few letters and
//  find the feature, what it does, and its step-by-step tutorial — the
//  low-learning-curve front door ("search for any feature"). Opened from
//  the Help (?) toolbar button.
//

import SwiftUI

extension FeatureTutorial {
    /// The complete catalog (every tutorial the app ships).
    static let allFeatures: [FeatureTutorial] = [
        .general, .emailAnalytics, .emailTimeline, .communicationPatterns,
        .relationshipGraph, .executiveDashboard, .aiAssistant, .aiDigest,
        .knowledgeGraph, .threadSummarizer, .anomalyDetection, .iocExtractor,
        .keywordMonitor, .duplicateManager, .nearDuplicates, .topicClusters,
        .batchOperations, .smartAlerts, .automationRules, .attachmentGallery,
        .archiveComparison, .backgroundFindings, .forensicReview, .legalReview,
        .predictiveCoding, .gdprCompliance, .custodianPanel, .chainOfCustody,
        .batesNumbering, .reviewBatches, .itAdmin, .journalist, .personal
    ]
}

struct FeatureGuideView: View {
    @Binding var isPresented: Bool
    @State private var search = ""
    @State private var selectedTutorial: FeatureTutorial?
    @State private var showGlossary = false

    private var matches: [FeatureTutorial] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return FeatureTutorial.allFeatures }
        return FeatureTutorial.allFeatures.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.overview.localizedCaseInsensitiveContains(query)
                || $0.quickStart.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty {
                    Text("No feature matches “\(search)”. Try a different word — or check the Glossary below.")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                }
                ForEach(matches, id: \.title) { tutorial in
                    Button {
                        selectedTutorial = tutorial
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.small) {
                            Image(systemName: tutorial.icon)
                                .foregroundColor(AppColors.primary)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tutorial.title)
                                    .font(Typography.callout)
                                    .fontWeight(.semibold)
                                Text(tutorial.overview)
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the \(tutorial.title) guide")
                }

                Section {
                    Button {
                        showGlossary = true
                    } label: {
                        Label("Glossary of Terms", systemImage: "character.book.closed")
                    }
                    .help("Definitions of email and forensic terms")
                }
            }
            .searchable(text: $search, prompt: "Search any feature…")
            .navigationTitle("Feature Guide")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .sheet(item: Binding(
                get: { selectedTutorial.map { IdentifiedTutorial(tutorial: $0) } },
                set: { selectedTutorial = $0?.tutorial }
            )) { wrapped in
                FeatureTutorialSheet(
                    tutorial: wrapped.tutorial,
                    isPresented: Binding(
                        get: { selectedTutorial != nil },
                        set: { if !$0 { selectedTutorial = nil } }
                    )
                )
            }
            .sheet(isPresented: $showGlossary) {
                NavigationStack {
                    GlossaryView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showGlossary = false }
                            }
                        }
                }
                .frame(minWidth: 440, minHeight: 480)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 620)
    }

    /// FeatureTutorial has no stable Identifiable conformance — wrap for .sheet(item:).
    private struct IdentifiedTutorial: Identifiable {
        let tutorial: FeatureTutorial
        var id: String { tutorial.title }
    }
}

#Preview("Feature Guide") {
    FeatureGuideView(isPresented: .constant(true))
}
