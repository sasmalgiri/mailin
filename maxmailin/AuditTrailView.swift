//
//  AuditTrailView.swift
//  maxmailin
//
//  The tamper-evident case record, made workable: live chain-integrity
//  badge, search across actions/details/examiners, one-click kind chips
//  with counts, a date scope, and a day-grouped timeline with per-kind
//  icons and expandable hash details. Daily Report and Export stay one
//  click away. Replaces the old flat AuditTrailSheet.
//

import SwiftUI

// MARK: - Pure filtering (unit-tested)

enum AuditTrailFilter {

    enum DateScope: String, CaseIterable {
        case today = "Today"
        case week = "7 Days"
        case all = "All"
    }

    /// The kind is the first clause of the action ("Triage verdict: …" →
    /// "Triage verdict") — the same grouping the daily report uses.
    static func kind(of action: String) -> String {
        action.components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? action
    }

    static func matches(action: String, detail: String, examiner: String,
                        timestamp: Date, search: String, kind: String?,
                        scope: DateScope, now: Date = Date(),
                        calendar: Calendar = .current) -> Bool {
        switch scope {
        case .today:
            guard calendar.isDate(timestamp, inSameDayAs: now) else { return false }
        case .week:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now),
                  timestamp >= cutoff else { return false }
        case .all:
            break
        }
        if let kind, Self.kind(of: action) != kind { return false }
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return action.localizedCaseInsensitiveContains(needle)
            || detail.localizedCaseInsensitiveContains(needle)
            || examiner.localizedCaseInsensitiveContains(needle)
    }

    static func icon(forKind kind: String) -> String {
        let lower = kind.lowercased()
        if lower.contains("import") || lower.contains("intake") { return "square.and.arrow.down" }
        if lower.contains("export") || lower.contains("report") { return "square.and.arrow.up" }
        if lower.contains("verdict") || lower.contains("tag") { return "tag" }
        if lower.contains("verif") || lower.contains("hash") || lower.contains("integrity") { return "checkmark.seal" }
        if lower.contains("hold") || lower.contains("custod") { return "lock.shield" }
        if lower.contains("annotat") || lower.contains("note") { return "note.text" }
        if lower.contains("delete") || lower.contains("remove") || lower.contains("clear") { return "trash" }
        return "doc.text"
    }
}

// MARK: - View

struct AuditTrailView: View {
    @ObservedObject var forensicManager: ForensicManager
    @ObservedObject var storeManager: StoreManager
    var onExport: () -> Void
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedKind: String? = nil
    @State private var scope: AuditTrailFilter.DateScope = .all
    @State private var chainStatus: ForensicManager.IntegrityStatus = .unknown
    @State private var isGeneratingDailyReport = false
    @State private var dailyReportNote: String? = nil
    @State private var expandedEntryID: UUID? = nil

    private static let freeViewLimit = 10

    private var filtered: [ForensicManager.AuditEntry] {
        forensicManager.auditLog.reversed().filter {
            AuditTrailFilter.matches(
                action: $0.action, detail: $0.detail, examiner: $0.examiner,
                timestamp: $0.timestamp, search: search,
                kind: selectedKind, scope: scope)
        }
    }

    private var visible: [ForensicManager.AuditEntry] {
        storeManager.isProfessional ? filtered : Array(filtered.prefix(Self.freeViewLimit))
    }

    private var kindCounts: [(kind: String, count: Int)] {
        Dictionary(grouping: forensicManager.auditLog, by: { AuditTrailFilter.kind(of: $0.action) })
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// Day-grouped, newest day first (entries within a day newest first).
    private var dayGroups: [(day: String, entries: [ForensicManager.AuditEntry])] {
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        var order: [String] = []
        var groups: [String: [ForensicManager.AuditEntry]] = [:]
        for entry in visible {
            let key = fmt.string(from: entry.timestamp)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { (day: $0, entries: groups[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if forensicManager.auditLog.isEmpty {
                emptyState
            } else if visible.isEmpty {
                noMatchState
            } else {
                timeline
            }
        }
        .toolWindowFrame()
        .task { await verifyChain() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Label("Audit Trail", systemImage: "clock.badge.checkmark")
                        .font(Typography.title2)
                    Text("\(forensicManager.auditLog.count) recorded action(s) — every entry's hash links to the one before it, so tampering shows")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                Spacer()
                chainBadge
                HelpDot(text: "This is the case's tamper-evident history: imports, verdicts, tags, exports and verifications, hash-chained in order. Search or click a category chip to narrow it; click an entry to see its chain hashes. Daily Report copies today's log for the case file.")
                Button {
                    Task { await generateDailyReport() }
                } label: {
                    Label(isGeneratingDailyReport ? "Verifying…" : "Daily Report",
                          systemImage: "doc.badge.clock")
                }
                .disabled(isGeneratingDailyReport)
                .help("End-of-day case log: verifies the chain, then copies today's activity report to the clipboard")
                if storeManager.isProfessional {
                    Button {
                        onExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Save the complete audit log for the case record")
                } else {
                    Button("Export (Pro)") { storeManager.showPaywall = true }
                        .foregroundColor(.purple)
                }
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close audit trail")
            }
            if let note = dailyReportNote {
                Label(note, systemImage: note.contains("WARNING") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(Typography.caption1)
                    .foregroundColor(note.contains("WARNING") ? .red : .green)
            }
        }
        .padding(Spacing.medium)
    }

    private var chainBadge: some View {
        Group {
            switch chainStatus {
            case .verified:
                Label("Chain verified", systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
            case .tampered:
                Label("TAMPERED", systemImage: "exclamationmark.shield.fill")
                    .foregroundColor(.red)
            case .noData:
                Label("Empty", systemImage: "shield")
                    .foregroundColor(AppColors.secondary)
            case .unknown:
                Label("Checking…", systemImage: "shield")
                    .foregroundColor(AppColors.secondary)
            }
        }
        .font(Typography.caption1)
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 4)
        .background((chainStatus == .verified ? Color.green : chainStatus == .unknown || chainStatus == .noData ? Color.gray : Color.red).opacity(0.12))
        .clipShape(Capsule())
        .help("Live integrity check: every entry's hash is recomputed and compared against the chain. Green means the log is exactly as written.")
    }

    // MARK: filters

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack(spacing: Spacing.small) {
                HStack(spacing: Spacing.xxSmall) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppColors.secondary)
                    TextField("Search actions, details, examiners…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, Spacing.xSmall)
                .padding(.vertical, 5)
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: CornerRadius.small))
                .frame(maxWidth: 340)

                Picker("", selection: $scope) {
                    ForEach(AuditTrailFilter.DateScope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .help("Limit the timeline to today, the last 7 days, or everything")
                Spacer()
                if selectedKind != nil || !search.isEmpty || scope != .all {
                    Button("Clear") {
                        search = ""; selectedKind = nil; scope = .all
                    }
                    .controlSize(.small)
                    .help("Show the full trail again")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xxSmall) {
                    ForEach(kindCounts, id: \.kind) { entry in
                        Button {
                            selectedKind = selectedKind == entry.kind ? nil : entry.kind
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: AuditTrailFilter.icon(forKind: entry.kind))
                                    .font(.caption2)
                                Text(entry.kind)
                                Text("\(entry.count)").fontWeight(.semibold)
                            }
                            .font(Typography.caption2)
                            .padding(.horizontal, Spacing.xSmall)
                            .padding(.vertical, 3)
                            .background(selectedKind == entry.kind ? AppColors.primary : AppColors.primary.opacity(0.08))
                            .foregroundColor(selectedKind == entry.kind ? .white : AppColors.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Show only \(entry.kind) entries")
                        .accessibilityAddTraits(selectedKind == entry.kind ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
    }

    // MARK: timeline

    private var timeline: some View {
        List {
            ForEach(dayGroups, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.entries) { entry in
                        entryRow(entry)
                    }
                }
            }
            if !storeManager.isProfessional && filtered.count > Self.freeViewLimit {
                Section {
                    Button {
                        storeManager.showPaywall = true
                    } label: {
                        Label("\(filtered.count - Self.freeViewLimit) more entries — unlock the full trail with Pro",
                              systemImage: "crown.fill")
                            .foregroundColor(.purple)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: ForensicManager.AuditEntry) -> some View {
        let kind = AuditTrailFilter.kind(of: entry.action)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(alignment: .top, spacing: Spacing.small) {
                Image(systemName: AuditTrailFilter.icon(forKind: kind))
                    .foregroundColor(AppColors.primary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.action)
                        .font(Typography.callout)
                        .fontWeight(.semibold)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                            .lineLimit(expandedEntryID == entry.id ? nil : 2)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    Text("#\(entry.sequence) · \(entry.examiner)")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
            if expandedEntryID == entry.id {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entry hash  \(entry.entryHash)")
                    Text("Links to    \(entry.previousHash)")
                }
                .font(Typography.monoSmall)
                .foregroundColor(AppColors.secondary)
                .textSelection(.enabled)
                .padding(.leading, 32)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(AnimationTiming.normal) {
                expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
            }
        }
        .help("Click to show this entry's chain hashes — the fingerprint that makes tampering visible")
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.medium) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(AppColors.secondary.opacity(0.4))
            Text("No audit entries yet")
                .font(Typography.headline)
                .foregroundColor(AppColors.secondary)
            Text("Actions like importing files, tagging evidence, issuing triage verdicts and verifying hashes are recorded here automatically.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: Spacing.small) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundColor(AppColors.secondary)
            Text("No entries match — clear the search, chip, or date scope.")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: actions

    @MainActor
    private func verifyChain() async {
        chainStatus = await forensicManager.verifyAuditLogIntegrityStreamed()
    }

    @MainActor
    private func generateDailyReport() async {
        isGeneratingDailyReport = true
        defer { isGeneratingDailyReport = false }
        let status = await forensicManager.verifyAuditLogIntegrityStreamed()
        chainStatus = status
        let chainOK: Bool?
        switch status {
        case .verified: chainOK = true
        case .tampered: chainOK = false
        case .unknown, .noData: chainOK = nil
        }
        var inputs = CaseActivityReportBuilder.Inputs()
        inputs.documentNumber = await DocumentRegistry.post(
            .report, summary: "Daily activity report — case \(forensicManager.caseNumber.isEmpty ? "(none)" : forensicManager.caseNumber)")
        inputs.caseNumber = forensicManager.caseNumber
        inputs.examiner = forensicManager.examinerName
        inputs.day = Date()
        inputs.auditEntries = forensicManager.auditLog.map {
            ($0.timestamp, $0.sequence, $0.action, $0.detail, $0.examiner)
        }
        inputs.chainVerified = chainOK
        PlatformClipboard.copyString(CaseActivityReportBuilder.build(inputs))
        forensicManager.logAction(
            "Daily activity report generated",
            detail: "Chain \(chainOK == true ? "verified" : chainOK == false ? "FAILED verification" : "not verifiable"); report copied to clipboard")
        dailyReportNote = chainOK == false
            ? "Report copied — WARNING: the audit chain FAILED verification."
            : "Report copied — paste it into the case file."
    }
}
