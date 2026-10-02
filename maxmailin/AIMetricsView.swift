@testable import ArchiveCore
//
//  AIMetricsView.swift
//  mailin
//
//  The reading surface for AIMetrics: what the AI Assistant's queries have
//  actually cost and produced, over a window the user picks. Every average
//  carries the number of queries it came from, and a metric no engine in the
//  window measured reads "not measured" — never 0.0 — because a fabricated
//  zero would be worse than no number at all.
//
//  Opens from the AI Assistant header (chart button): its own window on
//  macOS, a sheet on iOS. Reads the on-device file only; nothing here
//  transmits anything.
//

import SwiftUI

struct AIMetricsView: View {
    var onClose: (() -> Void)? = nil
    /// Preview-only: records to show instead of the shared store, so a
    /// populated layout can be rendered without writing the real file.
    var previewRecords: [AIMetrics.QueryRecord]? = nil

    @ObservedObject private var metrics = AIMetrics.shared
    @State private var windowSize: Int = 50
    @State private var copiedToast = false

    /// 0 means "every retained record".
    private let windowChoices: [(label: String, size: Int)] = [
        ("Last 20", 20), ("Last 50", 50), ("Last 200", 200), ("All", 0)
    ]

    private var allRecords: [AIMetrics.QueryRecord] { previewRecords ?? metrics.recent }
    private var hasLoaded: Bool { previewRecords != nil || metrics.hasLoadedPersisted }

    private var slice: [AIMetrics.QueryRecord] {
        windowSize == 0 ? allRecords : Array(allRecords.prefix(windowSize))
    }

    private var summary: AIMetrics.Summary { AIMetrics.summarize(slice) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                header
                if !hasLoaded {
                    loadingState
                } else if allRecords.isEmpty {
                    emptyState
                } else {
                    windowPicker
                    summarySection
                    ratesSection
                    engineSection
                    recentSection
                }
            }
            .padding()
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle("AI query metrics")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    PlatformClipboard.copyString(summaryText)
                    copiedToast = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedToast = false
                    }
                } label: {
                    Label(copiedToast ? "Copied" : "Copy summary", systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                }
                .disabled(slice.isEmpty)
                .help("Copy the figures below as plain text")
                #if os(macOS)
                Button {
                    if let url = metrics.storeURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Reveal file", systemImage: "folder")
                }
                .disabled(metrics.storeURL == nil)
                .help("Show the on-device metrics file in Finder")
                #endif
            }
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
        .task { if previewRecords == nil { metrics.loadPersisted() } }
    }

    // MARK: - Header and states

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundColor(.purple)
                Text("What the AI Assistant's queries actually cost and produced")
                    .font(Typography.headline)
                Spacer()
            }
            Text("Recorded on this device and never transmitted. Each figure states how many queries it comes from; a metric no engine in the window measured reads \"not measured\", not zero.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.medium)
    }

    private var loadingState: some View {
        HStack(spacing: Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text("Reading recorded queries…")
                .foregroundColor(AppColors.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No AI queries recorded yet.")
                .font(Typography.headline)
            Text("Ask the AI Assistant a question. Its timing, output and outcome are recorded here, engine by engine.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var windowPicker: some View {
        HStack {
            Text("Window")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
            Picker("Window", selection: $windowSize) {
                ForEach(windowChoices, id: \.size) { choice in
                    Text(choice.label).tag(choice.size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Spacer()
            Text("\(slice.count) of \(allRecords.count) retained")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        section(title: "Averages over \(summary.sampleSize) queries") {
            measuredRow("Time to answer", summary.elapsedMs, format: "%.0f ms")
            measuredRow("Emails cited per answer", summary.citedEmails)
            measuredRow("Findings per answer", summary.findings,
                        unmeasuredNote: "Only the Hybrid engine reports findings.")
            measuredRow("High-relevance findings", summary.highRelevance,
                        unmeasuredNote: "Only the Hybrid engine reports findings.")
            measuredRow("Knowledge-graph nodes cited", summary.kgNodes,
                        unmeasuredNote: "No engine reports knowledge-graph citations yet.")
        }
    }

    private var ratesSection: some View {
        section(title: String(localized: "Outcomes over the whole window")) {
            row("Fell back to the NLP baseline", percent(summary.fallbackRate),
                icon: summary.fallbackRate > 0 ? "arrow.uturn.backward" : nil, tint: .orange)
            row("Failed", percent(summary.failureRate),
                icon: summary.failureRate > 0 ? "exclamationmark.triangle" : nil, tint: AppColors.error)
            Text("Every path records whether it fell back or failed, so these two rates cover all \(summary.sampleSize) queries.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .padding(.top, Spacing.xxSmall)
        }
    }

    private var engineSection: some View {
        section(title: String(localized: "By engine")) {
            engineHeaderRow
            ForEach(engineStats) { stat in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                    Text(Self.displayName(for: stat.engine))
                        .font(Typography.callout)
                        .frame(width: 150, alignment: .leading)
                    Text("\(stat.queries)")
                        .font(Typography.callout)
                        .frame(width: 70, alignment: .trailing)
                    Text(stat.elapsed.isMeasured ? String(format: "%.0f ms", stat.elapsed.value) : "—")
                        .font(Typography.callout)
                        .frame(width: 90, alignment: .trailing)
                    Text("\(stat.fallbacks)")
                        .font(Typography.callout)
                        .foregroundColor(stat.fallbacks > 0 ? .orange : .primary)
                        .frame(width: 80, alignment: .trailing)
                    Text("\(stat.failures)")
                        .font(Typography.callout)
                        .foregroundColor(stat.failures > 0 ? AppColors.error : .primary)
                        .frame(width: 60, alignment: .trailing)
                    Spacer()
                }
            }
        }
    }

    private var engineHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text("Engine").frame(width: 150, alignment: .leading)
            Text("Queries").frame(width: 70, alignment: .trailing)
            Text("Avg time").frame(width: 90, alignment: .trailing)
            Text("Fallbacks").frame(width: 80, alignment: .trailing)
            Text("Failed").frame(width: 60, alignment: .trailing)
            Spacer()
        }
        .font(Typography.caption2)
        .foregroundColor(AppColors.secondary)
    }

    private var recentSection: some View {
        section(title: String(localized: "Recent queries")) {
            ForEach(slice.prefix(100)) { record in
                recentRow(record)
                if record.id != slice.prefix(100).last?.id {
                    Divider()
                }
            }
            if slice.count > 100 {
                Text("Showing the newest 100 of \(slice.count). Averages above use the whole window.")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .padding(.top, Spacing.xxSmall)
            }
        }
    }

    private func recentRow(_ record: AIMetrics.QueryRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xSmall) {
                Text(record.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                badge(Self.displayName(for: record.intent), tint: .purple)
                if record.reported.contains(AIMetrics.QueryRecord.Group.timing) {
                    Text("\(record.totalElapsedMs) ms")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                if record.reported.contains(AIMetrics.QueryRecord.Group.output), record.citedEmailCount > 0 {
                    Text("\(record.citedEmailCount) cited")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                if record.fallbackUsed { badge("fallback", tint: .orange) }
                if record.didFail { badge("failed", tint: AppColors.error) }
                Spacer()
            }
            Text(record.query)
                .font(Typography.callout)
                .lineLimit(2)
        }
        .padding(.vertical, Spacing.xxSmall)
    }

    // MARK: - Per-engine figures

    /// Per-engine rows. Time is averaged only over that engine's records that
    /// reported timing; fallback and failure are counts, recorded by every path.
    struct EngineStat: Identifiable {
        let engine: String
        let queries: Int
        let elapsed: AIMetrics.Measured
        let fallbacks: Int
        let failures: Int
        var id: String { engine }
    }

    private var engineStats: [EngineStat] {
        Self.engineStats(slice)
    }

    static func engineStats(_ slice: [AIMetrics.QueryRecord]) -> [EngineStat] {
        Dictionary(grouping: slice, by: \.intent).map { engine, records in
            let timed = records.filter { $0.reported.contains(AIMetrics.QueryRecord.Group.timing) }
            let elapsed = timed.isEmpty
                ? AIMetrics.Measured()
                : AIMetrics.Measured(
                    value: Double(timed.map(\.totalElapsedMs).reduce(0, +)) / Double(timed.count),
                    samples: timed.count)
            return EngineStat(engine: engine,
                              queries: records.count,
                              elapsed: elapsed,
                              fallbacks: records.filter(\.fallbackUsed).count,
                              failures: records.filter(\.didFail).count)
        }
        .sorted { $0.queries != $1.queries ? $0.queries > $1.queries : $0.engine < $1.engine }
    }

    /// The `intent` strings written by `AIAssistantView.beginMetrics`.
    static func displayName(for intent: String) -> String {
        switch intent {
        case "appleAIMoE": return "Apple AI MoE"
        case "appleAI": return "Apple AI"
        case "hybrid": return "Hybrid"
        case "cloudAI": return "Cloud AI"
        case "nlp": return "NLP"
        case "greeting": return "Greeting shortcut"
        case "acknowledgment": return "Acknowledgment shortcut"
        case "smartQuery": return "Smart-query shortcut"
        default: return intent
        }
    }

    // MARK: - Copy

    private var summaryText: String {
        var lines: [String] = []
        lines.append("mailin AI query metrics — \(summary.sampleSize) queries")
        lines.append("Time to answer: \(summary.elapsedMs.description("%.0f ms"))")
        lines.append("Emails cited per answer: \(summary.citedEmails.description())")
        lines.append("Findings per answer: \(summary.findings.description())")
        lines.append("High-relevance findings: \(summary.highRelevance.description())")
        lines.append("Knowledge-graph nodes cited: \(summary.kgNodes.description())")
        lines.append("Fell back to NLP baseline: \(percent(summary.fallbackRate))")
        lines.append("Failed: \(percent(summary.failureRate))")
        lines.append("")
        lines.append("By engine (queries, avg time, fallbacks, failed):")
        for stat in engineStats {
            let time = stat.elapsed.isMeasured ? String(format: "%.0f ms", stat.elapsed.value) : "—"
            lines.append("  \(Self.displayName(for: stat.engine)): \(stat.queries), \(time), \(stat.fallbacks), \(stat.failures)")
        }
        lines.append("")
        lines.append("Averages are taken only over the queries whose engine measured that field; \"not measured\" means no engine in this window did.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func percent(_ rate: Double) -> String {
        String(format: "%.0f%%", rate * 100)
    }

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

    private func row(_ label: String, _ value: String, icon: String? = nil, tint: Color = .green) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(label)
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .frame(width: 220, alignment: .leading)
            if let icon { Image(systemName: icon).foregroundColor(tint) }
            Text(value)
                .font(Typography.callout)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    /// A measured value shows its average and sample count; an unmeasured one
    /// says so, with the reason when there is one.
    @ViewBuilder
    private func measuredRow(_ label: String, _ measured: AIMetrics.Measured,
                             format: String = "%.1f", unmeasuredNote: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(label)
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .frame(width: 220, alignment: .leading)
            if measured.isMeasured {
                Text(String(format: format, measured.value))
                    .font(Typography.callout)
                Text("from \(measured.samples) of \(summary.sampleSize)")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Text("not measured")
                    .font(Typography.callout)
                    .italic()
                    .foregroundColor(AppColors.secondary)
                if let unmeasuredNote {
                    Text(unmeasuredNote)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            Spacer()
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1))
            .cornerRadius(CornerRadius.small)
    }
}

#Preview("Empty") {
    NavigationStack {
        AIMetricsView(onClose: {}, previewRecords: [])
    }
}

#Preview("Populated") {
    func sample(_ engine: String, _ query: String, ms: Int, cited: Int,
                findings: Int? = nil, fallback: Bool = false, failed: Bool = false) -> AIMetrics.QueryRecord {
        var r = AIMetrics.QueryRecord(query: query, intent: engine, persona: "legal", archiveEmailCount: 526)
        r.totalElapsedMs = ms
        r.citedEmailCount = cited
        r.answerCharCount = 900
        r.fallbackUsed = fallback
        r.didFail = failed
        r.reported = [AIMetrics.QueryRecord.Group.identity,
                      AIMetrics.QueryRecord.Group.timing,
                      AIMetrics.QueryRecord.Group.output]
        if let findings {
            r.totalFindings = findings
            r.highRelevanceCount = max(1, findings / 3)
            r.reported.insert(AIMetrics.QueryRecord.Group.findings)
        }
        return r
    }
    return NavigationStack {
        AIMetricsView(onClose: {}, previewRecords: [
            sample("hybrid", "Find privileged communications between Alex and counsel", ms: 2_310, cited: 5, findings: 12),
            sample("hybrid", "Who approved the March invoice?", ms: 1_870, cited: 3, findings: 6, fallback: true),
            sample("appleAI", "Summarise the Q2 board thread", ms: 1_420, cited: 4),
            sample("appleAIMoE", "Which suppliers changed bank details?", ms: 3_050, cited: 5),
            sample("nlp", "emails from finance last week", ms: 95, cited: 0),
            sample("cloudAI", "Draft a timeline of the merger talks", ms: 4_800, cited: 5, failed: true),
            sample("greeting", "hello", ms: 2, cited: 0),
        ])
    }
}
