//
//  ImportReceiptView.swift
//  mailin
//
//  Plan task A5 (b–d): the import receipt window. Shows the reconciled verdict
//  (Complete / Partial / Failed — never "no error was thrown"), the exact
//  source identity, the full accounting, index and attachment coverage, every
//  failure, and the tamper-evidence tier. Recheck re-reads the live store and
//  index so drift since the import is visible rather than assumed away.
//
//  Honesty rules this view follows:
//   • a count that was unavailable shows "unavailable", never 0
//   • "Retry" appears only when the host supplied a retry action
//   • verification states its tier: verified / checksum only / tampered
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportReceiptView: View {
    let receipt: ImportReceipt
    /// Supplied by the host when re-running the failed sources is actually
    /// possible. Nil means no Retry button — not a button that does nothing.
    var onRetry: (([String]) -> Void)? = nil

    @State private var recheck: RecheckOutcome?
    @State private var isRechecking = false
    @State private var exportError: String?

    /// What the live store and index say *now*, versus what the receipt claimed.
    struct RecheckOutcome: Equatable {
        var storeCount: Int?
        var ftsRows: Int?
        var checkedAt: Date

        func drift(from receipt: ImportReceipt) -> String? {
            var notes: [String] = []
            if let now = storeCount, let then = receipt.storeCountAfter, now != then {
                notes.append("store holds \(now) rows now, \(then) at import")
            }
            if let now = ftsRows, let then = receipt.ftsRowCount, now != then {
                notes.append("index holds \(now) rows now, \(then) at import")
            }
            return notes.isEmpty ? nil : notes.joined(separator: "; ")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                verdictBanner
                sourcesSection
                accountingSection
                coverageSection
                if !receipt.fileFailures.isEmpty || !receipt.warnings.isEmpty {
                    problemsSection
                }
                integritySection
                actions
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
        }
        .navigationTitle("Import Receipt")
        .alert("Could not save the receipt", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Verdict

    private var verdictBanner: some View {
        let verdict = receipt.verdict
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: verdictIcon(verdict))
                    .foregroundColor(verdictColor(verdict))
                    .font(.title2)
                Text(verdict.label)
                    .font(Typography.title3)
                Spacer()
                Text(receipt.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            // The shortfall list below already says what went wrong, so the
            // one-line summary is shown only when there is nothing to list.
            if verdict.shortfalls.isEmpty {
                Text(verdict.summary)
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
            } else {
                ForEach(verdict.shortfalls, id: \.rawValue) { shortfall in
                    Label(shortfall.explanation, systemImage: "exclamationmark.triangle")
                        .font(Typography.caption1)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .background(verdictColor(verdict).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// S0: messages whose body exceeded the index budget are searchable only
    /// in part. A receipt that stayed silent about that would overstate search
    /// coverage for exactly the biggest messages in the import.
    private var indexBudgetNote: String? {
        guard let partial = try? FTSSearchIndex.partiallyIndexedCountSnapshot(),
              partial > 0 else { return nil }
        let budget = ByteCountFormatter.string(
            fromByteCount: Int64(FTSSearchIndex.indexedTextBudgetBytes), countStyle: .file)
        return "\(partial) message(s) in the archive are longer than the \(budget) search-index budget, so search covers only the first part of those messages."
    }

    private func verdictIcon(_ verdict: ImportVerdict) -> String {
        switch verdict {
        case .complete: return "checkmark.seal.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func verdictColor(_ verdict: ImportVerdict) -> Color {
        switch verdict {
        case .complete: return .green
        case .partial: return .orange
        case .failed: return .red
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        section("Source files") {
            if receipt.sources.isEmpty {
                Text("No source recorded.").foregroundColor(AppColors.secondary)
            }
            ForEach(Array(receipt.sources.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.filename).font(Typography.callout)
                    Text("\(byteText(source.sizeBytes)) · \(source.parser) v\(source.parserVersion)")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                    Text("SHA-256 \(source.sha256)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(AppColors.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            if receipt.resumed {
                Label(receipt.resumedDetail ?? "This run resumed a previous import.",
                      systemImage: "arrow.clockwise")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
    }

    // MARK: Accounting

    private var accountingSection: some View {
        section("What happened to every message") {
            row("Discovered", receipt.discovered)
            row("Read successfully", receipt.parsed)
            row("Saved to the archive", receipt.inserted)
            row("Recognised duplicates", receipt.duplicates)
            row("Damaged and skipped", receipt.damaged)
            row("Could not be saved", receipt.persistFailed)
            row("Source files skipped (already imported)", receipt.skipped)
            Divider()
            row("Duration", text: String(format: "%.1f s", receipt.durationSeconds))
        }
    }

    private var coverageSection: some View {
        section("Coverage") {
            row("Searchable (indexed this run)", receipt.indexed)
            row("Attachments seen", receipt.attachmentsSeen)
            row("Store rows before / after",
                 text: "\(countText(receipt.storeCountBefore)) → \(countText(receipt.storeCountAfter))")
            row("Index rows at finish", receipt.ftsRowCount)
            if let partial = indexBudgetNote {
                Label(partial, systemImage: "text.magnifyingglass")
                    .font(Typography.caption1)
                    .foregroundColor(.orange)
            }
            if receipt.ftsDegraded {
                Label("The index fell behind during this run (\(receipt.ftsFailedBatchCount) batch(es)). It needs rebuilding before search is complete.",
                      systemImage: "magnifyingglass.circle")
                    .font(Typography.caption1)
                    .foregroundColor(.orange)
            }
            if let outcome = recheck {
                Divider()
                if let drift = outcome.drift(from: receipt) {
                    Label("Changed since import — \(drift).", systemImage: "arrow.triangle.branch")
                        .font(Typography.caption1)
                        .foregroundColor(.orange)
                } else {
                    Label("Rechecked \(outcome.checkedAt.formatted(date: .omitted, time: .standard)): store and index still match this receipt.",
                          systemImage: "checkmark.circle")
                        .font(Typography.caption1)
                        .foregroundColor(.green)
                }
            }
        }
    }

    private var problemsSection: some View {
        section("Problems") {
            ForEach(Array(receipt.fileFailures.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: 1) {
                    Text(failure.filename).font(Typography.callout)
                    Text(failure.message)
                        .font(Typography.caption2)
                        .foregroundColor(.red)
                }
            }
            ForEach(Array(receipt.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "info.circle")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
    }

    private var integritySection: some View {
        section("Integrity") {
            switch receipt.verifyDetailed() {
            case .verified:
                Label("Verified — this receipt has not been modified since it was written.",
                      systemImage: "lock.shield.fill")
                    .font(Typography.caption1)
                    .foregroundColor(.green)
            case .checksumOnly:
                Label("Checksum only — this receipt predates signing, so storage integrity is confirmed but tampering cannot be ruled out.",
                      systemImage: "shield.lefthalf.filled")
                    .font(Typography.caption1)
                    .foregroundColor(.orange)
            case .tampered(let reason):
                Label("Does not verify — \(reason).", systemImage: "exclamationmark.shield.fill")
                    .font(Typography.caption1)
                    .foregroundColor(.red)
            }
            Text("Content hash \(receipt.contentHash.isEmpty ? "not recorded" : receipt.contentHash)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(AppColors.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack {
            Button {
                Task { await performRecheck() }
            } label: {
                if isRechecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Recheck")
                }
            }
            .disabled(isRechecking)
            .help("Re-read the archive and index and compare them with this receipt")

            if let onRetry, !receipt.fileFailures.isEmpty {
                Button("Retry failed sources") {
                    onRetry(receipt.fileFailures.map(\.filename))
                }
            }

            Spacer()

            Button("Save…") { save() }
            #if os(macOS)
            Button("Print…") { printReceipt() }
            #endif
        }
    }

    /// Re-reads the live store and index. Uses the production singletons because
    /// this window describes a production import.
    private func performRecheck() async {
        isRechecking = true
        defer { isRechecking = false }
        let storeCount = try? await SQLiteEmailStore.shared.totalCount()
        let ftsRows = try? await FTSSearchIndex.shared.rowCount()
        recheck = RecheckOutcome(storeCount: storeCount, ftsRows: ftsRows, checkedAt: Date())
    }

    private func save() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin-import-receipt.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try plainText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
        #endif
    }

    #if os(macOS)
    private func printReceipt() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        textView.string = plainText()
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let operation = NSPrintOperation(view: textView)
        operation.printInfo.topMargin = 36
        operation.printInfo.bottomMargin = 36
        operation.run()
    }
    #endif

    /// The printable/saveable form — deliberately plain text so it can be filed
    /// alongside a case without depending on this app to read it.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("mailin import receipt")
        lines.append("Verdict: \(receipt.verdict.label) — \(receipt.verdict.summary)")
        lines.append("Started: \(receipt.startedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append("Finished: \(receipt.completedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append(String(format: "Duration: %.1f s", receipt.durationSeconds))
        lines.append("")
        lines.append("Sources")
        for source in receipt.sources {
            lines.append("  \(source.filename) — \(byteText(source.sizeBytes)), \(source.parser) v\(source.parserVersion)")
            lines.append("    SHA-256 \(source.sha256)")
        }
        lines.append("")
        lines.append("Accounting")
        lines.append("  discovered: \(receipt.discovered)")
        lines.append("  read: \(receipt.parsed)")
        lines.append("  saved: \(countText(receipt.inserted))")
        lines.append("  duplicates: \(countText(receipt.duplicates))")
        lines.append("  damaged: \(receipt.damaged)")
        lines.append("  could not save: \(receipt.persistFailed)")
        lines.append("  files skipped: \(receipt.skipped)")
        lines.append("  indexed: \(receipt.indexed)")
        lines.append("  attachments seen: \(receipt.attachmentsSeen)")
        lines.append("  store rows: \(countText(receipt.storeCountBefore)) -> \(countText(receipt.storeCountAfter))")
        lines.append("  index rows: \(countText(receipt.ftsRowCount))")
        if !receipt.fileFailures.isEmpty {
            lines.append("")
            lines.append("Failures")
            for failure in receipt.fileFailures {
                lines.append("  \(failure.filename): \(failure.message)")
            }
        }
        if !receipt.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            for warning in receipt.warnings { lines.append("  \(warning)") }
        }
        lines.append("")
        switch receipt.verifyDetailed() {
        case .verified: lines.append("Integrity: verified (keyed signature)")
        case .checksumOnly: lines.append("Integrity: checksum only (pre-signing receipt)")
        case .tampered(let reason): lines.append("Integrity: DOES NOT VERIFY — \(reason)")
        }
        lines.append("Content hash: \(receipt.contentHash.isEmpty ? "not recorded" : receipt.contentHash)")
        return lines.joined(separator: "\n")
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text(title)
                .font(Typography.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: Int) -> some View {
        row(label, text: "\(value)")
    }

    /// An optional count renders as "unavailable" — never as 0, which would
    /// claim something the import could not measure.
    private func row(_ label: String, _ value: Int?) -> some View {
        row(label, text: countText(value))
    }

    private func row(_ label: String, text: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.callout)
            Spacer()
            Text(text)
                .font(Typography.callout)
                .monospacedDigit()
                .foregroundColor(AppColors.secondary)
        }
    }

    private func countText(_ value: Int?) -> String {
        value.map(String.init) ?? "unavailable"
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Window host

/// Opens the most recent persisted receipt. Receipts are durable artifacts, so
/// this reads them from disk rather than depending on an import that is still
/// in memory — reopening the app and asking "what did that import actually do"
/// has to work.
struct LatestImportReceiptView: View {
    @State private var receipt: ImportReceipt?
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if let receipt {
                ImportReceiptView(receipt: receipt)
            } else if !loaded {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: Spacing.xSmall) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(AppColors.secondary)
                    Text(loadError ?? "No import receipts yet.")
                        .font(Typography.callout)
                    Text("Import mail and a receipt is written automatically.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(40)
            }
        }
        .task {
            guard !loaded else { return }
            let store = ImportReceiptStore.production
            let newest = store.list()
                .map { url -> (URL, Date) in
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return (url, modified)
                }
                .sorted { $0.1 > $1.1 }
                .first?.0
            if let newest {
                do { receipt = try store.load(newest) }
                catch { loadError = "The most recent receipt could not be read: \(error.localizedDescription)" }
            }
            loaded = true
        }
    }
}

#if DEBUG
#Preview("Receipt — Partial") {
    var receipt = ImportReceipt(startedAt: Date().addingTimeInterval(-44),
                                completedAt: Date())
    receipt.sources = [.init(filename: "Sent.mbox", sizeBytes: 94_915_160,
                             sha256: "9f2c1a77e5b3d0c4a18f6e2b7d9c0a1b2c3d4e5f60718293a4b5c6d7e8f90123",
                             parser: "MBOXParser", parserVersion: 1)]
    receipt.discovered = 526
    receipt.parsed = 524
    receipt.inserted = 520
    receipt.duplicates = 4
    receipt.damaged = 2
    receipt.indexed = 500
    receipt.attachmentsSeen = 152
    receipt.storeCountBefore = 0
    receipt.storeCountAfter = 520
    receipt.ftsRowCount = 500
    receipt.durationSeconds = 44.0
    receipt.warnings = ["2 messages could not be read and were skipped."]
    try? receipt.finalize()
    return ImportReceiptView(receipt: receipt)
        .frame(width: 700, height: 760)
}
#endif
