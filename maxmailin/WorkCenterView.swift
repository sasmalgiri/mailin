//
//  WorkCenterView.swift
//  maxmailin
//
//  The daily front door, SAP-style: three tabs. MY WORK — everything
//  waiting on you, prioritized (privilege gaps first). INTAKE REGISTER —
//  every movement into the archive, MB51-style, with counts and
//  fingerprints. JOBS — the background workers made visible, with a
//  Run Now. All read-only assembly of records the app already keeps.
//

import SwiftUI

struct WorkCenterView: View {
    var onOpenDestination: ((HubDestination) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runner = DerivedAIAnalysisJob.shared.runner
    @ObservedObject private var watchManager = WatchFolderManager.shared
    @State private var items: [WorkCenterModel.WorkItem] = []
    @State private var intakeRows: [SQLiteEmailStore.IntakeRow] = []
    @State private var migratedCount = 0
    @State private var coverage: (analyzed: Int, total: Int) = (0, 0)
    @State private var documents: [SQLiteEmailStore.IssuedDocument] = []
    @State private var docSearch = ""
    @State private var isLoading = true
    @AppStorage(DigestScheduler.enabledKey) private var digestEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Label("Work Center", systemImage: "tray.full.fill")
                        .font(Typography.title2)
                    Text("Your work, the archive's movements, and the background jobs — one place, updated live")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                Spacer()
                HelpDot(text: "My Work lists everything waiting on you, most urgent first — click an item to jump to its tool. Intake Register is the archive's movement log: every file that ever entered, with counts and fingerprints. Jobs shows the background workers and lets you kick the AI analysis manually.")
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close work center")
            }
            .padding(Spacing.medium)
            Divider()

            TabView {
                myWorkTab
                    .tabItem { Label("My Work", systemImage: "checklist") }
                intakeTab
                    .tabItem { Label("Intake Register", systemImage: "square.and.arrow.down.on.square") }
                jobsTab
                    .tabItem { Label("Jobs", systemImage: "gearshape.arrow.triangle.2.circlepath") }
                documentsTab
                    .tabItem { Label("Documents", systemImage: "number.square") }
            }
            .padding(.top, Spacing.xxSmall)
        }
        .toolWindowFrame()
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .parsingFinished)) { _ in
            Task { await reload() }
        }
    }

    // MARK: My Work

    private var myWorkTab: some View {
        Group {
            if isLoading {
                ProgressView("Collecting your work…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: Spacing.small) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle).foregroundColor(.green)
                    Text("All clear — nothing is waiting on you.")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    Button {
                        if let destination = item.destination {
                            onOpenDestination?(destination)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.small) {
                            Image(systemName: item.icon)
                                .foregroundColor(item.severity == .critical ? .red :
                                                 item.severity == .action ? AppColors.primary : AppColors.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(Typography.callout)
                                    .fontWeight(.semibold)
                                Text(item.detail)
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                            }
                            Spacer()
                            if item.destination != nil {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(AppColors.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.destination != nil ? "Open the tool for this item" : "Background progress — no action needed")
                }
            }
        }
    }

    // MARK: Intake Register

    private var intakeTab: some View {
        List {
            if migratedCount > 0 {
                Section {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Migration from v1")
                                .font(Typography.callout).fontWeight(.semibold)
                            Text("\(migratedCount) email(s) carried over without source identity — their provenance predates this register.")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                    }
                }
            }
            Section {
                if intakeRows.isEmpty {
                    Text("No source files recorded yet — every future import appears here with its counts and fingerprint.")
                        .foregroundColor(AppColors.secondary)
                }
                ForEach(intakeRows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(AppColors.primary)
                            Text(row.filename)
                                .font(Typography.callout).fontWeight(.semibold)
                            Text(DocumentNumberFormat.sourceAlias(row.sourceID))
                                .font(Typography.monoSmall)
                                .foregroundColor(AppColors.secondary)
                            Text(row.kind.uppercased())
                                .font(Typography.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(AppColors.primary.opacity(0.1))
                                .clipShape(Capsule())
                            Spacer()
                            Text(row.importedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                        HStack(spacing: Spacing.small) {
                            Text("\(row.storedCount) stored")
                            if row.duplicateCount > 0 {
                                Text("\(row.duplicateCount) duplicate\(row.duplicateCount == 1 ? "" : "s") skipped")
                                    .foregroundColor(.orange)
                            }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(row.byteSize), countStyle: .file))
                            Text("SHA \(row.sha256.prefix(12))…")
                                .font(Typography.monoSmall)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .padding(.leading, 26)
                    }
                    .help("This file's movement record: what it delivered, what was skipped as duplicate, and its content fingerprint for provenance")
                }
            } header: {
                Text("\(intakeRows.count) source file(s) — newest first")
            } footer: {
                Text("The register answers the auditor's first question: what entered this archive, when, and from where. Fingerprints let anyone verify a source file hasn't changed.")
                    .font(Typography.caption2)
            }
        }
    }

    // MARK: Jobs

    private var jobsTab: some View {
        List {
            Section("Background jobs") {
                jobRow(
                    icon: "sparkles", title: "AI analysis",
                    status: analysisStatus,
                    detail: coverage.total > 0
                        ? "\(coverage.analyzed) of \(coverage.total) emails analyzed — powers the AI chips, priority and phishing signals."
                        : "Runs after imports; nothing to analyze yet.",
                    action: ("Run Now", { DerivedAIAnalysisJob.shared.kickIfNeeded() }))
                jobRow(
                    icon: watchManager.isWatching ? "eye.fill" : "eye.slash",
                    title: "Watch folder",
                    status: watchManager.isWatching ? "Watching" : "Off",
                    detail: watchManager.isWatching
                        ? "Auto-importing new .eml/.mbox files into the triage queue."
                        : "Configure it in Phishing Triage to auto-import reported emails.",
                    action: nil)
                jobRow(
                    icon: "newspaper", title: "Weekly digest",
                    status: digestEnabled ? "Scheduled" : "Off",
                    detail: digestEnabled
                        ? "Summarizes saved-search activity once a week."
                        : "Enable in Settings ▸ Notifications for a weekly saved-search summary.",
                    action: nil)
            }
        }
    }

    private var analysisStatus: String {
        switch runner.state {
        case .running: return runner.total > 0 ? "Running \(runner.processed)/\(runner.total)" : "Running"
        case .completed: return coverage.total > 0 && coverage.analyzed >= coverage.total ? "Complete" : "Idle"
        case .failed: return "Failed — Run Now retries"
        case .cancelled: return "Cancelled"
        case .idle: return coverage.total > 0 && coverage.analyzed >= coverage.total ? "Complete" : "Idle"
        }
    }

    private func jobRow(icon: String, title: String, status: String, detail: String,
                        action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: icon)
                .foregroundColor(AppColors.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(Typography.callout).fontWeight(.semibold)
                    Text(status)
                        .font(Typography.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((status.hasPrefix("Complete") || status == "Watching" || status == "Scheduled" ? Color.green : status.hasPrefix("Running") ? Color.blue : Color.gray).opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(detail)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .controlSize(.small)
                    .help("Start this job immediately instead of waiting for the next automatic run")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Documents

    private var documentsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xxSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.secondary)
                TextField("Look up a document number or summary — e.g. IMP-2026 or 'blocklist'", text: $docSearch)
                    .textFieldStyle(.plain)
                    .onChange(of: docSearch) { _, _ in
                        Task { await reloadDocuments() }
                    }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 6)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: CornerRadius.small))
            .padding(Spacing.small)

            List {
                if documents.isEmpty {
                    Text(docSearch.isEmpty
                         ? "No documents posted yet — every completed import, verdict, export, report, story version and cleanup posts one automatically."
                         : "No document matches “\(docSearch)”.")
                        .foregroundColor(AppColors.secondary)
                }
                ForEach(documents) { doc in
                    HStack(alignment: .top, spacing: Spacing.small) {
                        Image(systemName: DocumentType(rawValue: doc.type)?.icon ?? "doc")
                            .foregroundColor(AppColors.primary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(doc.number)
                                    .font(Typography.monoBody)
                                    .fontWeight(.semibold)
                                    .textSelection(.enabled)
                                Text(DocumentType(rawValue: doc.type)?.displayName ?? doc.type)
                                    .font(Typography.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(AppColors.primary.opacity(0.1))
                                    .clipShape(Capsule())
                                Spacer()
                                Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                            }
                            Text(doc.summary)
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                                .textSelection(.enabled)
                            if !doc.refs.isEmpty {
                                Text(doc.refs)
                                    .font(Typography.monoSmall)
                                    .foregroundColor(AppColors.secondary.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .help("Quote this number anywhere — the record behind it is always one lookup away")
                }
            }
        }
    }

    @MainActor
    private func reloadDocuments() async {
        let needle = docSearch.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty {
            documents = (try? await SQLiteEmailStore.shared.recentDocuments()) ?? []
        } else {
            documents = (try? await SQLiteEmailStore.shared.lookupDocuments(matching: needle)) ?? []
        }
    }

    // MARK: data

    @MainActor
    private func reload() async {
        let store = SQLiteEmailStore.shared
        coverage = (try? await store.derivedAnalysisCoverage()) ?? (0, 0)
        intakeRows = (try? await store.intakeRegister()) ?? []
        migratedCount = (try? await store.migratedRowCount()) ?? 0
        await reloadDocuments()

        var inputs = WorkCenterModel.Inputs()
        inputs.triagePending = (try? await ArchiveDataService.shared.count(
            query: TriageQueueService.pendingQuery)) ?? 0
        let batches = ReviewBatchManager.shared.batches
        inputs.reviewPending = batches.reduce(0) { $0 + $1.pendingCount }
        inputs.batchCount = batches.count
        let privileged = ForensicManager.shared.evidenceTags.filter { $0.value == .privileged }.map(\.key)
        let annotated = Set(ForensicManager.shared.annotations.keys)
        inputs.privilegeGaps = privileged.filter { !annotated.contains($0) }.count
        inputs.watchFolderActive = watchManager.importLog.isEmpty && !watchManager.isWatching
            ? nil : watchManager.isWatching
        inputs.analysisAnalyzed = coverage.analyzed
        inputs.analysisTotal = coverage.total
        inputs.digestEnabled = digestEnabled
        items = WorkCenterModel.items(inputs)
        isLoading = false
    }
}
