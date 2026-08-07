import SwiftUI

struct NearDuplicateDetectionView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?

    /// Part M(b): bump when the near-duplicate algorithm changes — persisted
    /// findings at an older version are recomputed instead of reused.
    static let algoVersion = 1
    /// Groups hydrated per page from the persisted findings — bounded resident
    /// set; no `[RawEmail]` archive list is retained.
    static let persistedPageSize = 50

    @State private var threshold: Double = 0.85
    @State private var groups: [EmailNLPEngine.NearDuplicateGroup] = []
    @State private var isAnalyzing = false
    @State private var removedGroupIDs: Set<UUID> = []
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @State private var showTutorial = false
    @State private var persistedGroupCount = 0
    @State private var loadedGroupCount = 0
    @Environment(\.dismiss) private var envDismiss

    private var visibleGroups: [EmailNLPEngine.NearDuplicateGroup] {
        groups.filter { !removedGroupIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isAnalyzing {
                VStack {
                    Spacer()
                    ProgressView("Analyzing \(min(emails.count, 10_000)) emails for near-duplicates...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if groups.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "doc.on.doc",
                        title: "No Near-Duplicates Found",
                        message: "Adjust the similarity threshold and run the analysis to find emails with similar content."
                    )
                    thresholdControl
                        .padding(.top, Spacing.medium)
                    Button("Find Near-Duplicates") { analyze() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Spacing.medium)
                    Spacer()
                }
                .padding(Spacing.medium)
            } else if visibleGroups.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "All Duplicates Removed",
                        message: "All duplicate groups have been dismissed from view."
                    )
                    Button("Reset View") {
                        removedGroupIDs.removeAll()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, Spacing.medium)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    thresholdControl
                    HStack {
                        Text("\(visibleGroups.count) duplicate group\(visibleGroups.count == 1 ? "" : "s") found")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        Spacer()
                        let totalDuplicates = visibleGroups.reduce(0) { $0 + $1.duplicates.count }
                        Text("\(totalDuplicates) duplicate email\(totalDuplicates == 1 ? "" : "s") total")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }

                    Label {
                        Text("Similarity scores indicate how closely emails match based on content analysis. Scores above 90% are near-identical; 70-90% share significant content. Groups are ranked by similarity — review the lowest-scoring groups most carefully.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(CornerRadius.small)

                    Button("Re-analyze") { analyze() }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.top, Spacing.small)

                aiInsightsSection
                    .padding(.horizontal, Spacing.medium)

                List {
                    ForEach(visibleGroups) { group in
                        groupRow(group)
                    }
                    if loadedGroupCount < persistedGroupCount {
                        Button {
                            Task { await loadNextPersistedPage() }
                        } label: {
                            Label("Load More Groups (\(persistedGroupCount - loadedGroupCount) remaining)",
                                  systemImage: "arrow.down.circle")
                                .font(Typography.caption1)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(AppColors.primary)
                    }
                }
            }
        }
        .onAppear { loadPersistedOrAnalyze() }
        .featureTutorial(.nearDuplicates, key: "near_duplicates_tutorial_seen", isPresented: $showTutorial)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
        .resizableSheet()
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(AppColors.primary)
            Text("Near-Duplicate Detection")
                .font(Typography.headline)
            Spacer()
            TutorialHelpButton(showTutorial: $showTutorial)
            if isPresented != nil {
                Button("Done") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.medium)
    }

    private var thresholdControl: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Text("Similarity Threshold")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(threshold * 100))%")
                    .font(Typography.monoSmall)
                    .foregroundColor(AppColors.primary)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(AppColors.primary.opacity(0.08))
                    .cornerRadius(CornerRadius.small)
            }
            Slider(value: $threshold, in: 0.5...1.0, step: 0.01)
                .accessibilityLabel("Similarity threshold")
                .accessibilityValue("\(Int(threshold * 100)) percent")
            HStack {
                Text("Loose (50%)")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                Spacer()
                Text("Exact (100%)")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
        }
    }

    // MARK: - AI Insights

    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Text("AI Analysis")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                } else if aiInsights == nil {
                    Button {
                        loadAIInsights()
                    } label: {
                        Label("Enhance with AI", systemImage: "sparkles")
                            .font(Typography.caption1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
            }

            if let insights = aiInsights {
                Text(insights)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Spacing.small)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private func loadAIInsights() {
        isLoadingAI = true
        let totalDuplicates = visibleGroups.reduce(0) { $0 + $1.duplicates.count }
        let context = """
        Near-duplicate analysis found \(visibleGroups.count) groups with \(totalDuplicates) duplicates \
        at \(Int(threshold * 100))% similarity threshold across \(emails.count) emails.
        """
        let emailsCopy = emails
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .entity,
                    emails: emailsCopy,
                    context: context
                )
                aiInsights = result ?? "AI analysis unavailable."
            } else {
                aiInsights = "Requires macOS 26 or later."
            }
            #else
            aiInsights = "AI features not available on this platform."
            #endif
            isLoadingAI = false
        }
    }

    private func groupRow(_ group: EmailNLPEngine.NearDuplicateGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                // Representative email
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    HStack(spacing: Spacing.xxSmall) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("Representative")
                            .font(Typography.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }
                    emailSummaryRow(group.representative)
                }
                .padding(Spacing.xSmall)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.medium)

                // Duplicates
                ForEach(group.duplicates, id: \.id) { duplicate in
                    emailSummaryRow(duplicate)
                        .padding(Spacing.xSmall)
                        .background(AppColors.backgroundTertiary)
                        .cornerRadius(CornerRadius.small)
                }

                // Remove button
                Button {
                    let _ = withAnimation {
                        removedGroupIDs.insert(group.id)
                    }
                } label: {
                    Label("Remove All Duplicates", systemImage: "trash")
                        .font(Typography.caption1)
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .padding(.top, Spacing.xxSmall)
            }
        } label: {
            HStack(spacing: Spacing.xSmall) {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Text(group.representative.headers["Subject"] ?? "(No Subject)")
                        .font(Typography.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(group.representative.headers["From"] ?? "Unknown")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: Spacing.xxxSmall) {
                    Text("\(Int(group.similarityScore * 100))% similar")
                        .font(Typography.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(similarityColor(group.similarityScore))
                        .padding(.horizontal, Spacing.xSmall)
                        .padding(.vertical, 2)
                        .background(similarityColor(group.similarityScore).opacity(0.12))
                        .cornerRadius(CornerRadius.small)
                        .help(group.similarityScore >= 0.9 ? "Near-identical content — safe to remove duplicates" : "Significant overlap — review differences before removing")

                    Text("\(group.duplicates.count) duplicate\(group.duplicates.count == 1 ? "" : "s")")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
            .padding(.vertical, Spacing.xxSmall)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.duplicates.count) duplicates of \(group.representative.headers["Subject"] ?? "email"), \(Int(group.similarityScore * 100)) percent similar")
    }

    private func emailSummaryRow(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(Typography.caption1)
                .fontWeight(.medium)
                .lineLimit(2)
            HStack(spacing: Spacing.xSmall) {
                Text(email.headers["From"] ?? "Unknown")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
                Spacer()
                Text(email.headers["Date"] ?? "")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func similarityColor(_ score: Double) -> Color {
        if score >= 0.95 { return AppColors.error }
        if score >= 0.90 { return AppColors.warning }
        return AppColors.info
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Persisted findings (Part M b)

    /// Reopen path: page the PERSISTED findings (id pairs/groups + similarity,
    /// stamped with algorithm version + corpus revision) instead of re-running
    /// the O(n²) similarity scan. Falls back to a fresh analysis when nothing
    /// valid is persisted. Explicit "Find Near-Duplicates" / "Re-analyze"
    /// always recomputes (and re-persists).
    private func loadPersistedOrAnalyze() {
        Task { @MainActor in
            let store = SQLiteEmailStore.shared
            let revision = (try? await ArchiveCorpusRevision.shared.reconciled()) ?? 0
            let meta = (try? await store.nearDuplicateMeta()) ?? (algoVersion: 0, corpusRevision: 0)
            let count = (try? await store.nearDuplicateGroupCount()) ?? 0
            guard count > 0, meta.algoVersion == Self.algoVersion, meta.corpusRevision == revision else {
                analyze()
                return
            }
            persistedGroupCount = count
            loadedGroupCount = 0
            groups = []
            removedGroupIDs.removeAll()
            await loadNextPersistedPage()
        }
    }

    /// Hydrate ONE bounded page of persisted groups (~50 groups' member
    /// emails hydrated per page, appended for review).
    @MainActor
    private func loadNextPersistedPage() async {
        let store = SQLiteEmailStore.shared
        let keys = (try? await store.nearDuplicateGroupKeysPage(limit: Self.persistedPageSize, offset: loadedGroupCount)) ?? []
        guard !keys.isEmpty else { return }
        let members = (try? await store.nearDuplicateMembers(groupKeys: keys)) ?? []
        let byGroup = Dictionary(grouping: members, by: \.groupKey)
        let hydrated = (try? await ArchiveDataService.shared.fullEmails(ids: members.map(\.emailID))) ?? []
        let emailByID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
        var page: [EmailNLPEngine.NearDuplicateGroup] = []
        for key in keys {
            guard let rows = byGroup[key],
                  let repRow = rows.first(where: { $0.isRepresentative }),
                  let representative = emailByID[repRow.emailID] else { continue }
            let duplicates = rows.filter { !$0.isRepresentative }.compactMap { emailByID[$0.emailID] }
            guard !duplicates.isEmpty else { continue }
            page.append(EmailNLPEngine.NearDuplicateGroup(
                representative: representative,
                duplicates: duplicates,
                similarityScore: repRow.similarity
            ))
        }
        groups += page
        loadedGroupCount += keys.count
    }

    private func analyze() {
        isAnalyzing = true
        removedGroupIDs.removeAll()
        let emailsCopy = emails
        let currentThreshold = threshold
        Task.detached {
            let results = EmailNLPEngine.findNearDuplicates(in: emailsCopy, threshold: currentThreshold)
            await MainActor.run {
                groups = results
                isAnalyzing = false
                persistedGroupCount = results.count
                loadedGroupCount = results.count
            }
            // Part M(b): persist the findings — compact rows of {group,
            // member id, representative flag, similarity} + algorithm version
            // + corpus revision — so the next open pages them instead of
            // recomputing.
            let rows = results.flatMap { group -> [SQLiteEmailStore.NearDupMemberRow] in
                let key = group.representative.id.uuidString
                let representative = SQLiteEmailStore.NearDupMemberRow(
                    groupKey: key, emailID: group.representative.id,
                    isRepresentative: true, similarity: group.similarityScore
                )
                let members = group.duplicates.map {
                    SQLiteEmailStore.NearDupMemberRow(
                        groupKey: key, emailID: $0.id,
                        isRepresentative: false, similarity: group.similarityScore
                    )
                }
                return [representative] + members
            }
            let store = SQLiteEmailStore.shared
            let revision = (try? await store.corpusRevision()) ?? 0
            try? await store.nearDuplicatesReplace(rows, algoVersion: Self.algoVersion, corpusRevision: revision)
        }
    }
}
