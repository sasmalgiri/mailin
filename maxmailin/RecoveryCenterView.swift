//
//  RecoveryCenterView.swift
//  maxmailin
//
//  3.1 R10/R11 + R9 entry: one screen for deleted-email recovery.
//  • What was recovered, by kind (counts from SQL, whole archive).
//  • Deletion analysis against legal-hold dates, with its limit in words.
//  • Carve a file: read any file for email messages and add the ones that
//    verify (streamed in batches; the receipt says found / added / rejected).
//  • Save the recovery report (CSV, every recovered email, streamed by page).
//  Shown only while Capability.v31Recovery is on.
//

import SwiftUI
import UniformTypeIdentifiers
@testable import ArchiveCore

struct RecoveryCenterView: View {
    @Environment(ModuleRegistry.self) private var modules
    @State private var counts = RecoveryCounts()
    @State private var analysis = DeletionAnalysis()
    @State private var showCarvePicker = false
    @State private var isCarving = false
    @State private var carveProgress: Double = 0
    @State private var carveTask: Task<Void, Never>?
    @State private var status: String?
    @State private var isSavingReport = false

    var body: some View {
        Form {
            Section {
                if counts.recovered == 0 {
                    Text("No recovered emails yet. Import a mailbox with recovery on, or carve a file below.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent(String(localized: "Recovered emails"), value: "\(counts.recovered)")
                    ForEach(RecoveryState.allCases.filter { $0.isRecovered && counts[$0] > 0 }, id: \.self) { s in
                        LabeledContent(RecoveryBadgeView.title(s), value: "\(counts[s])")
                    }
                    if counts.partial > 0 {
                        LabeledContent(String(localized: "Partly recovered"), value: "\(counts.partial)")
                    }
                }
            } header: {
                Text("Recovered")
            } footer: {
                Text("Recovery reads what the mail files still hold: deleted-items folders, deletion flags, mail not yet purged, items no longer in any folder and, with deep recovery on, unallocated space in PST files. Mail that was purged and overwritten cannot be recovered.")
            }

            Section {
                LabeledContent(String(localized: "Recovered emails on legal hold"), value: "\(analysis.recoveredOnHold)")
                ForEach(analysis.matters, id: \.matter) { m in
                    LabeledContent(m.matter.isEmpty ? String(localized: "Hold (no matter name)") : m.matter) {
                        Text("\(m.recoveredBeforeHold) dated before the hold of \(m.holdPlacedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                ForEach(analysis.custodians, id: \.custodian) { c in
                    LabeledContent(c.custodian) {
                        Text(c.isBurst
                             ? String(localized: "\(c.recovered) recovered; \(c.busiestWeekCount) in week \(c.busiestWeek) — a burst")
                             : String(localized: "\(c.recovered) recovered; most in week \(c.busiestWeek) (\(c.busiestWeekCount))"))
                    }
                }
            } header: {
                Text("Deletion analysis")
            } footer: {
                Text("Mail files do not record when a message was deleted, so this shows only what the data proves: recovered emails dated before each hold was placed were covered by the duty to preserve.")
            }

            Section {
                if isCarving {
                    ProgressView(value: carveProgress)
                    Button("Stop carving", role: .cancel) { carveTask?.cancel() }
                } else {
                    Button {
                        showCarvePicker = true
                    } label: {
                        Label("Carve a file for emails…", systemImage: "scissors")
                    }
                    .disabled(!modules.isOn(.v31DeepRecovery))
                    if !modules.isOn(.v31DeepRecovery) {
                        Text("Turn on Deep recovery in Settings ▸ Modules to carve files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await saveReport() }
                } label: {
                    Label("Save recovery report (CSV)…", systemImage: "square.and.arrow.down")
                }
                .disabled(counts.recovered == 0 || isSavingReport)
                if let status {
                    Text(status).font(.callout).textSelection(.enabled)
                }
            } header: {
                Text("Actions")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Recovery"))
        .task { await reload() }
        .fileImporter(isPresented: $showCarvePicker, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            carveTask = Task { await carve(url) }
        }
    }

    private func reload() async {
        let store = ScopeJobEnvironment.store
        counts = (try? await store.recoveryCounts()) ?? RecoveryCounts()
        analysis = (try? await store.deletionAnalysis()) ?? DeletionAnalysis()
    }

    /// Carves `url`, adding every verified message in batches. The status and
    /// the audit entry are written only after the insert really happened.
    private func carve(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        isCarving = true
        carveProgress = 0
        defer { isCarving = false }
        var added = 0
        var skipped = 0
        let started = Date()
        // R10: the source is only read; its SHA-256 before and after proves it.
        let shaBefore = await Task.detached { PlatformExport.fileSHA256(url) }.value ?? "unreadable"
        do {
            let result = try await MIMECarver.carve(url: url, emit: { batch in
                let r = try await ScopeJobEnvironment.store.insertBatch(
                    batch, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                    dedupPolicy: .messageID, batchSize: 200, progress: nil)
                try await FTSSearchIndex.shared.indexBatch(batch)
                added += r.insertedIDs.count
                skipped += batch.count - r.insertedIDs.count
            }, progress: { done, total in
                guard total > 0 else { return }
                let fraction = Double(done) / Double(total)
                Task { @MainActor in carveProgress = fraction }
            })
            if added > 0 { _ = try? await ArchiveCorpusRevision.shared.bump() }
            let shaAfter = await Task.detached { PlatformExport.fileSHA256(url) }.value ?? "unreadable"
            let seconds = Int(Date().timeIntervalSince(started))
            var line = String(localized: "Carved \(url.lastPathComponent): \(result.kept) messages found, \(added) added, \(skipped) already in the archive, \(result.rejected) candidates rejected.")
            line += " " + (shaBefore == shaAfter
                ? String(localized: "Source unchanged (SHA-256 \(String(shaBefore.prefix(16)))…); \(seconds) s.")
                : String(localized: "Warning: the source changed while it was read (SHA-256 before \(String(shaBefore.prefix(16))), after \(String(shaAfter.prefix(16)))); \(seconds) s."))
            status = line
            if added > 0 {
                ScopeJobEnvironment.logAction("Recovery carve", detail: line + " SHA-256 " + shaBefore)
                NotificationCenter.default.post(name: .parsingFinished, object: nil)
            }
        } catch is CancellationError {
            status = String(localized: "Carving stopped: \(added) messages were added before it stopped.")
            if added > 0 { ScopeJobEnvironment.logAction("Recovery carve (stopped)", detail: status ?? "") }
        } catch {
            status = String(localized: "Carving failed after adding \(added) messages: \(error.localizedDescription)")
        }
        await reload()
    }

    /// Every recovered email, streamed page by page into the CSV.
    private func saveReport() async {
        isSavingReport = true
        defer { isSavingReport = false }
        var text = csvRow(["Email ID", "Date", "From", "Subject", "State", "Method", "Evidence", "Folder", "Byte offset", "Partial"])
        var rows = 0
        do {
            let pages = try await Self.collectReport()
            for page in pages {
                for r in page {
                    text += csvRow([r.id.uuidString, r.date.ISO8601Format(), r.from, r.subject, r.info.state.rawValue,
                                    r.info.method, r.info.evidence, r.info.folder ?? "",
                                    r.info.offset.map(String.init) ?? "", r.info.partial ? "yes" : "no"])
                    rows += 1
                }
            }
        } catch {
            status = String(localized: "The recovery report couldn't be built: \(error.localizedDescription)")
            return
        }
        let outcome = PlatformExport.save(data: Data(text.utf8), suggestedName: "Recovery Report.csv")
        status = outcome.message(String(localized: "Recovery report (\(rows) emails)"))
        if outcome.succeeded {
            ScopeJobEnvironment.logAction("Recovery report", detail: "\(rows) recovered emails")
        }
    }

    private static func collectReport() async throws -> [[RecoveryReportRow]] {
        var pages: [[RecoveryReportRow]] = []
        var cursor: (date: Int64, id: String)?
        while true {
            let page = try await ScopeJobEnvironment.store.recoveryReportPage(state: nil, after: cursor)
            if page.isEmpty { break }
            pages.append(page)
            guard let last = page.last, page.count == 1_000 else { break }
            cursor = (Int64(last.date.timeIntervalSince1970), last.id.uuidString)
        }
        return pages
    }
}
