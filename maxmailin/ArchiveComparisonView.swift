@testable import ArchiveCore
import SwiftUI

/// Compares the WHOLE current archive with a second mailbox file.
///
/// v2.1 backlog #3: this used to take two `[RawEmail]` arrays capped at 2,000
/// per side and say so in a notice. It now drives `ArchiveComparisonEngine`,
/// which reduces each side to key rows in a scratch database and reads the
/// differences back in pages — so the counts are whole-archive counts and the
/// memory cost is one page of rows plus a bounded sample for the AI summary.
struct ArchiveComparisonView: View {
    let secondArchiveURL: URL
    let nameA: String
    let nameB: String
    let senderEmail: String
    var isPresented: Binding<Bool>?

    init(secondArchiveURL: URL, nameA: String, nameB: String,
         senderEmail: String = "", isPresented: Binding<Bool>? = nil) {
        self.secondArchiveURL = secondArchiveURL
        self.nameA = nameA
        self.nameB = nameB
        self.senderEmail = senderEmail
        self.isPresented = isPresented
    }

    enum Phase: Equatable {
        case idle
        case indexingCurrent(Int)
        case readingSecond(Int)
        case matching
        case ready
        case failed(String)
    }

    static let pageSize = 200

    @State private var engine: ArchiveComparisonEngine?
    @State private var phase: Phase = .idle
    @State private var totals: ArchiveComparisonEngine.Totals?
    @State private var statsA = ArchiveComparisonEngine.SideStats()
    @State private var statsB = ArchiveComparisonEngine.SideStats()
    @State private var filter: ArchiveComparisonEngine.Source? = nil
    @State private var rows: [ArchiveComparisonEngine.Row] = []
    @State private var lastPageWasFull = false
    @State private var isLoadingPage = false
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @State private var showTutorial = false
    @Environment(\.dismiss) private var envDismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch phase {
            case .idle, .indexingCurrent, .readingSecond, .matching:
                progressBody
            case .failed(let message):
                EmptyStateView(icon: "exclamationmark.triangle",
                               title: String(localized: "Comparison could not run"),
                               message: message)
            case .ready:
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        if let totals { summarySection(totals) }
                        statsComparison
                        aiInsightsSection
                        filterBar
                        rowList
                    }
                    .padding(Spacing.medium)
                }
            }
        }
        .featureTutorial(.archiveComparison, key: "archive_comparison_tutorial_seen", isPresented: $showTutorial)
        #if os(macOS)
        .toolWindowFrame()
        #endif
        .task { await runComparison() }
        .onDisappear { engine?.close() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(AppColors.primary)
            Text("Archive Comparison")
                .font(Typography.headline)
            Spacer()
            TutorialHelpButton(showTutorial: $showTutorial)
            SaveToDocumentsButton(title: String(localized: "Archive Compare")) {
                let t = totals ?? .init()
                return [
                    .init(key: "\(nameA) messages", value: "\(t.countA)"),
                    .init(key: "\(nameB) messages", value: "\(t.countB)"),
                    .init(key: "Only in \(nameA)", value: "\(t.onlyInA)"),
                    .init(key: "Only in \(nameB)", value: "\(t.onlyInB)"),
                    .init(key: "Common", value: "\(t.common) (\(t.byMessageID) by Message-ID, \(t.byFuzzy) by subject/sender/minute)"),
                    .init(key: "Second archive", value: secondArchiveURL.lastPathComponent),
                ]
            }
            .disabled(totals == nil)
            if isPresented != nil {
                Button { closeSheet() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close archive comparison")
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        engine?.close()
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Progress

    private var progressBody: some View {
        VStack(spacing: Spacing.medium) {
            ProgressView()
                .scaleEffect(1.2)
            Text(progressText)
                .font(Typography.subheadline)
                .foregroundColor(AppColors.secondary)
            Text("Whole archives are compared by Message-ID and by subject, sender and minute. Nothing is held in memory beyond one page.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("comparison.progress")
    }

    private var progressText: String {
        switch phase {
        case .idle: return String(localized: "Preparing…")
        case .indexingCurrent(let n): return "Indexing \(nameA)… \(n) messages"
        case .readingSecond(let n): return "Reading \(nameB)… \(n) messages"
        case .matching: return String(localized: "Matching…")
        case .ready, .failed: return ""
        }
    }

    // MARK: - Summary

    private func summarySection(_ t: ArchiveComparisonEngine.Totals) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Summary")
                .font(Typography.title3)
                .fontWeight(.bold)

            #if os(iOS)
            VStack(spacing: Spacing.small) { summaryCards(t) }
            #else
            HStack(spacing: Spacing.large) { summaryCards(t) }
            #endif

            Text("\(nameA): \(t.countA) messages. \(nameB): \(t.countB) messages. \(t.common) match — \(t.byMessageID) by Message-ID, \(t.byFuzzy) by subject, sender and minute.")
                .font(Typography.footnote)
                .foregroundColor(AppColors.secondary)
                .padding(.top, Spacing.xxSmall)
                .accessibilityIdentifier("comparison.summaryLine")
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    @ViewBuilder
    private func summaryCards(_ t: ArchiveComparisonEngine.Totals) -> some View {
        statCard(title: "Only in \(nameA)", count: t.onlyInA, color: .blue, icon: "a.circle.fill")
        statCard(title: String(localized: "Common"), count: t.common, color: .green, icon: "equal.circle.fill")
        statCard(title: "Only in \(nameB)", count: t.onlyInB, color: .orange, icon: "b.circle.fill")
    }

    private func statCard(title: String, count: Int, color: Color, icon: String) -> some View {
        VStack(spacing: Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text("\(count)")
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.small)
        .background(color.opacity(0.08))
        .cornerRadius(CornerRadius.medium)
    }

    // MARK: - Stats

    private var statsComparison: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Archive Statistics")
                .font(Typography.headline)
                .fontWeight(.semibold)

            #if os(iOS)
            VStack(spacing: Spacing.small) {
                archiveStatsColumn(name: nameA, stats: statsA, color: .blue)
                Divider()
                archiveStatsColumn(name: nameB, stats: statsB, color: .orange)
            }
            #else
            HStack(alignment: .top, spacing: Spacing.medium) {
                archiveStatsColumn(name: nameA, stats: statsA, color: .blue)
                Divider()
                archiveStatsColumn(name: nameB, stats: statsB, color: .orange)
            }
            #endif
            Text("Counted from message headers only; bodies are not read, so no sentiment figure is shown.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func archiveStatsColumn(name: String, stats: ArchiveComparisonEngine.SideStats, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack(spacing: Spacing.xxSmall) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                    .font(Typography.callout)
                    .fontWeight(.semibold)
            }
            statsRow(label: String(localized: "Total Emails"), value: "\(stats.total)")
            statsRow(label: String(localized: "Date Range"), value: Self.dateRange(stats))
            statsRow(label: String(localized: "Unique Senders"), value: "\(stats.uniqueSenders)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func dateRange(_ stats: ArchiveComparisonEngine.SideStats) -> String {
        guard let first = stats.earliest, let last = stats.latest else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(formatter.string(from: first)) - \(formatter.string(from: last))"
    }

    private func statsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Spacer()
            Text(value)
                .font(Typography.caption1)
                .fontWeight(.medium)
        }
    }

    // MARK: - Filter

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Filter")
                .font(Typography.callout)
                .fontWeight(.semibold)
            Picker("Filter", selection: $filter) {
                Text("All").tag(ArchiveComparisonEngine.Source?.none)
                Text("Only in A").tag(ArchiveComparisonEngine.Source?.some(.onlyInA))
                Text("Only in B").tag(ArchiveComparisonEngine.Source?.some(.onlyInB))
                Text("Common").tag(ArchiveComparisonEngine.Source?.some(.common))
            }
            #if os(iOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.segmented)
            #endif
            .onChange(of: filter) { _, _ in reloadFirstPage() }
        }
    }

    // MARK: - Paged list

    private var filteredTotal: Int {
        guard let totals else { return 0 }
        switch filter {
        case nil: return totals.onlyInA + totals.onlyInB + totals.common
        case .onlyInA?: return totals.onlyInA
        case .onlyInB?: return totals.onlyInB
        case .common?: return totals.common
        }
    }

    private var rowList: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("\(filteredTotal) email\(filteredTotal == 1 ? "" : "s")")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            if rows.isEmpty && !isLoadingPage {
                Text("No emails match this filter.")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(Spacing.large)
            } else {
                LazyVStack(spacing: Spacing.xxSmall) {
                    ForEach(rows) { row in comparisonRow(row) }
                    if lastPageWasFull {
                        Button {
                            loadNextPage()
                        } label: {
                            if isLoadingPage {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load \(Self.pageSize) more (showing \(rows.count) of \(filteredTotal))")
                            }
                        }
                        .buttonStyle(.bordered)
                        .padding(Spacing.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("comparison.loadMore")
                    }
                }
            }
        }
    }

    private func comparisonRow(_ row: ArchiveComparisonEngine.Row) -> some View {
        HStack(spacing: Spacing.xSmall) {
            Text(LocalizedStringKey(row.source.rawValue))
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 34, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small)
                        .fill(row.source == .onlyInA ? Color.blue :
                              row.source == .onlyInB ? Color.orange : Color.green)
                )
                .help(row.matchKind.map { "Matched by \($0)" } ?? "Present on one side only")

            VStack(alignment: .leading, spacing: 1) {
                Text(row.subject.isEmpty ? "(No Subject)" : row.subject)
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: Spacing.xSmall) {
                    Text(row.sender.isEmpty ? "Unknown" : row.sender)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                    Text(row.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary.opacity(0.7))
                        .lineLimit(1)
                }
                if let matched = row.matchedSubject, matched != row.subject {
                    Text("In \(nameB) as: \(matched)")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(Spacing.xSmall)
        .background(AppColors.backgroundSecondary.opacity(0.5))
        .cornerRadius(CornerRadius.small)
    }

    // MARK: - AI insights (bounded sample)

    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("AI-Enhanced Analysis")
                    .font(Typography.headline)
                    .fontWeight(.semibold)
                Spacer()
                if isLoadingAI {
                    ProgressView().controlSize(.small)
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
                    .help("Summarise the differences from a sample of up to \(ArchiveComparisonEngine.sampleCap) messages per side")
                }
            }

            if let insights = aiInsights {
                Text(insights)
                    .font(Typography.body)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            } else if !isLoadingAI {
                Text("Reads a sample of up to \(ArchiveComparisonEngine.sampleCap) differing messages per side — the counts above are whole-archive; the narrative is from the sample.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func loadAIInsights() {
        guard let engine else { return }
        isLoadingAI = true
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                do {
                    let idsA = try engine.onlyInAIDs(limit: ArchiveComparisonEngine.sampleCap)
                    let sampleA = try await ArchiveDataService.shared.fullEmails(ids: idsA)
                    let sampleB = try engine.onlyInBSample()
                    let compResult = await FoundationModelEngine.compareArchives(
                        archiveA: sampleA, archiveB: sampleB,
                        nameA: nameA, nameB: nameB,
                        onUpdate: { text in aiInsights = text }
                    )
                    aiInsights = compResult.synthesis
                } catch {
                    aiInsights = "Could not gather the sample: \(error.localizedDescription)"
                }
            } else {
                aiInsights = "Requires macOS 26 or later."
            }
            #else
            aiInsights = "AI features not available on this platform."
            #endif
            isLoadingAI = false
        }
    }

    // MARK: - Running the comparison

    private func runComparison() async {
        guard engine == nil else { return }
        do {
            let engine = try ArchiveComparisonEngine()
            self.engine = engine
            phase = .indexingCurrent(0)
            try await engine.indexCurrentArchive { n in
                Task { @MainActor in phase = .indexingCurrent(n) }
            }
            phase = .readingSecond(0)
            try await engine.indexSecondArchive(url: secondArchiveURL, senderEmail: senderEmail) { n in
                Task { @MainActor in phase = .readingSecond(n) }
            }
            phase = .matching
            let result = try await Task.detached(priority: .userInitiated) { try engine.match() }.value
            totals = result
            statsA = try engine.stats(.a)
            statsB = try engine.stats(.b)
            phase = .ready
            reloadFirstPage()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func reloadFirstPage() {
        rows = []
        lastPageWasFull = false
        loadNextPage()
    }

    private func loadNextPage() {
        guard let engine, !isLoadingPage else { return }
        isLoadingPage = true
        let cursor = rows.last.map { ArchiveComparisonEngine.Cursor(date: $0.date, id: $0.id) }
        let filter = filter
        Task {
            do {
                let page = try engine.page(filter: filter, after: cursor, limit: Self.pageSize)
                rows += page
                lastPageWasFull = page.count == Self.pageSize
            } catch {
                phase = .failed(error.localizedDescription)
            }
            isLoadingPage = false
        }
    }
}
