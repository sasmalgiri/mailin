@testable import ArchiveCore
//
//  TriageQueueView.swift
//  maxmailin
//
//  The IT admin's daily surface: suspicious emails forwarded by users land
//  in a watched folder, auto-import into the pending queue pre-scored, and
//  leave with one verdict click (⌘1/⌘2/⌘3). Confirmed phishing feeds the
//  IOC blocklist export. Every intake and verdict is audit-logged.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TriageQueueView: View {
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var watchManager = WatchFolderManager.shared
    @ObservedObject private var triage = TriageQueueService.shared
    @State private var queue: [MBOXParser.RawEmail] = []
    @State private var scores: [UUID: (risk: String?, iocCount: Int)] = [:]
    @State private var confirmedCount = 0
    /// Every email awaiting a verdict; the queue holds the first `queueCap`.
    @State private var pendingTotal = 0
    @State private var isLoading = true
    @State private var exportError: String?

    static let queueCap = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            watchFolderBar
            Divider()
            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView("Loading queue…"); Spacer() }
                Spacer()
            } else if queue.isEmpty {
                emptyState
            } else {
                queueList
            }
            Divider()
            footer
        }
        .toolWindowFrame()
        .task {
            TriageQueueService.shared.activate()
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parsingFinished)) { _ in
            Task { await reload() }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("Phishing Triage", systemImage: "shield.lefthalf.filled")
                    .font(Typography.title2)
                Text(isLoading
                     ? "Loading…"
                     : pendingTotal > queue.count
                        ? "Showing \(queue.count) of \(pendingTotal) awaiting verdict — the next ones load when these are done; every intake and verdict is recorded in the audit trail"
                        : "\(queue.count) awaiting verdict — every intake and verdict is recorded in the audit trail")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                if let note = triage.lastIntakeNote {
                    Text(note)
                        .font(Typography.caption2)
                        .foregroundColor(.green)
                }
            }
            Spacer()
            HelpDot(text: "Users forward suspicious emails as .eml/.mbox into the watched folder below. They auto-import here pre-scored. Issue a verdict with the buttons or ⌘1 (Phishing), ⌘2 (Safe), ⌘3 (Needs Info). Confirmed emails feed the IOC blocklist export.")
            Button { if let onClose { onClose() } else { dismiss() } } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close triage queue")
        }
        .padding(Spacing.medium)
    }

    private var watchFolderBar: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: watchManager.isWatching ? "eye.fill" : "eye.slash")
                .foregroundColor(watchManager.isWatching ? .green : AppColors.secondary)
            if watchManager.isWatching, let path = watchManager.watchPath?.path {
                Text("Watching \(path)")
                    .font(Typography.caption1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { watchManager.stopWatching() }
                    .controlSize(.small)
            } else {
                Text("No folder is being watched — choose the folder users forward suspicious emails into.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                #if os(macOS)
                Button("Choose Folder…") { chooseWatchFolder() }
                    .controlSize(.small)
                #endif
            }
            Spacer()
            if let last = watchManager.lastImportDate {
                Text("Last intake \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.small) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.largeTitle).foregroundColor(.green)
            Text("Queue clear — nothing awaiting a verdict.")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var queueList: some View {
        List {
            ForEach(queue, id: \.id) { email in
                triageRow(email)
            }
        }
    }

    private func triageRow(_ email: MBOXParser.RawEmail) -> some View {
        let score = scores[email.id] ?? (nil, 0)
        let suggestion = TriageVerdictPolicy.suggestion(
            phishingRisk: score.risk, iocCount: score.iocCount,
            hasAttachments: !email.attachments.isEmpty)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(email.headers["Subject"] ?? "(No Subject)")
                        .font(Typography.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("From \(email.headers["From"] ?? "?") · \(email.headers["Date"] ?? "")")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let risk = score.risk {
                    Text("\(risk) risk")
                        .font(Typography.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((risk == "High" ? Color.red : risk == "Medium" ? .orange : .green).opacity(0.15))
                        .foregroundColor(risk == "High" ? .red : risk == "Medium" ? .orange : .green)
                        .clipShape(Capsule())
                }
                if score.iocCount > 0 {
                    Text("\(score.iocCount) IOC\(score.iocCount == 1 ? "" : "s")")
                        .font(Typography.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundColor(.purple)
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: Spacing.xSmall) {
                Label(suggestion.reason, systemImage: "lightbulb")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                Spacer()
                verdictButton(.confirmedPhishing, for: email, color: .red)
                verdictButton(.safe, for: email, color: .green)
                verdictButton(.needsInfo, for: email, color: .orange)
            }
        }
        .padding(.vertical, 3)
    }

    private func verdictButton(_ verdict: TriageVerdict, for email: MBOXParser.RawEmail, color: Color) -> some View {
        Button {
            issueVerdict(verdict, for: email)
        } label: {
            Label(verdict.displayName, systemImage: verdict.icon)
                .font(Typography.caption1)
        }
        .tint(color)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Mark as \(verdict.displayName) — removes it from the queue and records the verdict in the audit trail")
    }

    private var footer: some View {
        HStack {
            Text("\(confirmedCount) confirmed phishing email\(confirmedCount == 1 ? "" : "s") on record")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Spacer()
            // Keyboard verdicts act on the TOP of the queue (minimum-touch).
            if let first = queue.first {
                Group {
                    Button("") { issueVerdict(.confirmedPhishing, for: first) }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("") { issueVerdict(.safe, for: first) }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("") { issueVerdict(.needsInfo, for: first) }
                        .keyboardShortcut("3", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .hidden()
            }
            Button {
                exportBlocklist()
            } label: {
                Label("Export IOC Blocklist", systemImage: "square.and.arrow.up")
            }
            .disabled(confirmedCount == 0)
            .help("CSV of every indicator (URLs, IPs, domains, hashes, senders) from confirmed-phishing emails — feed it to your mail filter or firewall")
        }
        .padding(Spacing.medium)
    }

    private func issueVerdict(_ verdict: TriageVerdict, for email: MBOXParser.RawEmail) {
        TriageQueueService.shared.issueVerdict(verdict, for: email)
        queue.removeAll { $0.id == email.id }
        pendingTotal = max(0, pendingTotal - 1)
        if verdict == .confirmedPhishing { confirmedCount += 1 }
        // The shown part is done but more are waiting: load the next ones.
        if queue.isEmpty && pendingTotal > 0 {
            Task { await ReviewStateService.shared.waitForWrites(); await reload() }
        }
    }

    @MainActor
    private func reload() async {
        queue = await ArchiveDataService.shared.workingSet(
            query: TriageQueueService.pendingQuery, cap: Self.queueCap)
        pendingTotal = (try? await ArchiveDataService.shared.count(query: TriageQueueService.pendingQuery)) ?? queue.count
        var confirmedQuery = EmailQuery.all
        confirmedQuery.userTag = TriageVerdict.confirmedPhishing.rawValue
        confirmedCount = (try? await ArchiveDataService.shared.count(query: confirmedQuery)) ?? 0

        // Score off the main actor: phishing heuristics + IOC counts.
        let snapshot = queue
        let computed = await Task.detached(priority: .userInitiated) { () -> [UUID: (String?, Int)] in
            var out: [UUID: (String?, Int)] = [:]
            let flags = EmailNLPEngine.detectPhishing(in: snapshot)
            let riskByID = Dictionary(uniqueKeysWithValues: flags.map { ($0.email.id, $0.riskLevel.rawValue) })
            for email in snapshot {
                let iocs = IOCExtractor.extract(from: [email]).count
                out[email.id] = (riskByID[email.id], iocs)
            }
            return out
        }.value
        scores = computed
        isLoading = false
    }

    private func exportBlocklist() {
        Task { @MainActor in
            var q = EmailQuery.all
            q.userTag = TriageVerdict.confirmedPhishing.rawValue
            // Every confirmed email, streamed in batches — the blocklist used
            // to stop silently at the newest 2,000.
            var iocs: [IOCEntry] = []
            var seen = Set<String>()
            var confirmedCount = 0
            do {
                for try await batch in ArchiveDataService.shared.streamFullEmails(query: q, batchSize: 200) {
                    confirmedCount += batch.count
                    for ioc in IOCExtractor.extract(from: batch)
                    where seen.insert("\(ioc.type.rawValue):\(ioc.value.lowercased())").inserted {
                        iocs.append(ioc)
                    }
                }
            } catch {
                exportError = String(localized: "The confirmed emails could not all be read: \(error.localizedDescription). No blocklist was saved.")
                return
            }
            var csv = csvRow(["Type", "Value", "Source Email"])
            for ioc in iocs { csv += csvRow([ioc.type.rawValue, ioc.value, ioc.emailSubject]) }
            let outcome = PlatformExport.save(text: csv, suggestedName: "mailin_ioc_blocklist.csv")
            switch outcome {
            case .saved(let url), .shared(let url):
                _ = await DocumentRegistry.post(
                    .export,
                    summary: "IOC blocklist: \(iocs.count) indicators from \(confirmedCount) confirmed emails",
                    refs: url.lastPathComponent)
            case .failed:
                exportError = outcome.message(String(localized: "IOC blocklist"))
            case .cancelled:
                break
            }
        }
    }

    #if os(macOS)
    private func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            watchManager.startWatching(directory: url)
        }
    }
    #endif
}
