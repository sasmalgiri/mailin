@testable import ArchiveCore
//
//  ExportRunCenter.swift
//  maxmailin
//
//  Part O: one shared progress/cancellation surface for streaming exports.
//  Every bulk export runs as a cancellable Task and reports (done, total)
//  after each bounded batch; the small overlay below shows progress and a
//  Cancel button. Deliberately minimal — the streaming pipeline itself lives
//  in `ArchiveExportService`.
//
//  A8: when a run finishes, the overlay turns into the run's receipt
//  (`ExportReceipt`): requested / written / outcome / SHA-256 / destination,
//  with Reveal and Save. A run that ends in an error or a cancel produces a
//  receipt that says so, in the same place, instead of a bar that vanishes.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ExportRunCenter {
    static let shared = ExportRunCenter()

    private(set) var isActive = false
    private(set) var title = ""
    /// Input positions consumed at the last reported boundary (what a resume skips).
    private(set) var done = 0
    private(set) var total = 0
    /// Files produced so far, when the writer reports it separately (folder
    /// formats, third review T3). Nil when produced == done.
    private(set) var produced: Int?
    /// What the receipt calls "written".
    var writtenForReceipt: Int { produced ?? done }
    private(set) var startedAt = Date()

    /// The most recent finished run. Shown by the overlay until dismissed.
    private(set) var lastReceipt: ExportReceipt?
    var showReceipt = false
    /// Where the receipt was saved, if it could be.
    private(set) var lastReceiptURL: URL?

    private var task: Task<Void, Never>?
    /// Set by the export body when it knows its outcome; consulted by finish().
    private var pendingReceipt: ExportReceipt?

    /// A8: a request waiting for the user's pre-flight confirmation. The
    /// overlay presents it as a sheet; Start hands it to `ExportJobRunner`.
    var pendingPreflight: ExportRequest?

    private init() {}

    /// Every export enters here: show the pre-flight sheet for `request`.
    /// Refused while a run is active, like `run`.
    func requestPreflight(_ request: ExportRequest) {
        guard !isActive else { return }
        pendingPreflight = request
    }

    /// Resume an interrupted export from its receipt (Resume button).
    func resume(_ receipt: ExportReceipt) {
        guard let request = receipt.resumeRequest, !isActive else { return }
        showReceipt = false
        pendingPreflight = request
    }

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    /// Run `operation` as the single active export. A second export while one
    /// is running is refused (the overlay is already showing).
    func run(title: String, operation: @escaping @MainActor () async -> Void) {
        guard !isActive else { return }
        isActive = true
        self.title = title
        done = 0
        total = 0
        produced = nil
        startedAt = Date()
        pendingReceipt = nil
        showReceipt = false
        task = Task { @MainActor [weak self] in
            await operation()
            self?.finish()
        }
    }

    /// Batch progress callback — pass directly as `onProgress`.
    func update(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// Folder formats: files produced so far (differs from `done` when
    /// messages were skipped or withheld).
    func noteProduced(_ count: Int) {
        produced = count
    }

    func cancel() {
        task?.cancel()
    }

    /// The export body records what it did. Called at most once per run; a
    /// later call replaces the earlier (an error after a partial result).
    func record(_ receipt: ExportReceipt) {
        pendingReceipt = receipt
    }

    /// A failure the body did not turn into a receipt itself (thrown error).
    func recordFailure(destination: URL?, isFolder: Bool, requested: Int?, message: String,
                       resume: ExportRequest? = nil) {
        pendingReceipt = ExportReceipt(
            title: title,
            destination: destination?.path ?? "—",
            isFolder: isFolder,
            requested: requested,
            written: writtenForReceipt,
            outcome: .failed,
            errorMessage: message,
            startedAt: startedAt,
            completedAt: Date(),
            resumeRequest: resume)
    }

    /// The older exports (`runStreamingExport`) say how they ended in a status line rather than a
    /// receipt; without this every one of them finished as "Failed — N written before the error",
    /// even a complete export. Records the real outcome unless the body already recorded one.
    func recordOutcome(_ outcome: ExportReceipt.Outcome, destination: URL? = nil, message: String? = nil) {
        guard pendingReceipt == nil else { return }
        pendingReceipt = ExportReceipt(
            title: title,
            destination: destination?.path ?? "—",
            isFolder: false,
            requested: total > 0 ? total : nil,
            written: writtenForReceipt,
            outcome: outcome,
            errorMessage: outcome == .failed ? message : nil,
            startedAt: startedAt,
            completedAt: Date())
    }

    func dismissReceipt() {
        showReceipt = false
    }

    // MARK: - R06: finishing and verifying a folder export after the fact

    /// The inventory could not be written when the run ended: build it from the
    /// retained manifest, re-hash every listed file, and update the receipt.
    func finishInventory(_ receipt: ExportReceipt) async {
        var updated = receipt
        let folder = receipt.destinationURL
        let outcome: Result<(URL, ExportInventory.Verification), Error> = await Task.detached(priority: .utility) {
            do {
                let url = try ExportInventory.repair(folder: folder)
                return .success((url, try ExportInventory.verify(folder: folder)))
            } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let (url, verification)):
            updated.inventoryPath = url.path
            updated.checked = verification.listed
            updated.verificationLine = Self.verificationText(verification)
            if verification.isClean {
                updated.outcome = .complete
                updated.errorMessage = nil
            }
        case .failure(let error):
            updated.verificationLine = String(localized: "Inventory could not be finished: \(error.localizedDescription)")
        }
        replace(updated)
    }

    /// Re-read every file the inventory lists and compare its hash (full, never sampled).
    func verifyExport(_ receipt: ExportReceipt) async {
        var updated = receipt
        let folder = receipt.destinationURL
        let outcome: Result<ExportInventory.Verification, Error> = await Task.detached(priority: .utility) {
            do { return .success(try ExportInventory.verify(folder: folder)) } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let verification):
            updated.verificationLine = Self.verificationText(verification)
        case .failure(let error):
            updated.verificationLine = String(localized: "Verification could not run: \(error.localizedDescription)")
        }
        replace(updated)
    }

    /// "written", "hashes recorded while writing" and this re-read stay three different statements.
    static func verificationText(_ v: ExportInventory.Verification) -> String {
        var line = String(localized: "rehash checked: \(v.matching) of \(v.listed) files match")
        if !v.missing.isEmpty { line += " · " + String(localized: "missing \(v.missing.count)") }
        if !v.changed.isEmpty { line += " · " + String(localized: "changed \(v.changed.count)") }
        if !v.unlisted.isEmpty { line += " · " + String(localized: "unlisted \(v.unlisted.count)") }
        return line
    }

    private func replace(_ receipt: ExportReceipt) {
        lastReceipt = receipt
        lastReceiptURL = try? ExportReceiptStore.production.save(receipt)
        showReceipt = true
    }

    private func finish() {
        // A run that recorded nothing still gets a receipt: silence is not an
        // outcome. It is marked failed with an explicit reason.
        let receipt = pendingReceipt ?? ExportReceipt(
            title: title, destination: "—", isFolder: false, requested: total > 0 ? total : nil,
            written: done, outcome: .failed,
            errorMessage: "The export ended without reporting a result.",
            startedAt: startedAt, completedAt: Date())
        lastReceipt = receipt
        lastReceiptURL = try? ExportReceiptStore.production.save(receipt)
        showReceipt = true
        isActive = false
        task = nil
        done = 0
        total = 0
        pendingReceipt = nil
    }
}

/// Progress + cancel while running; the receipt when finished. Attached once
/// at the ContentView level; hidden unless an export is running or a receipt
/// is waiting to be read.
struct ExportProgressOverlayView: View {
    @State private var center = ExportRunCenter.shared
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    /// §3-F1: with the 3.0 scope engine on, progress shows in the shell's
    /// job bar with every other running job; the receipt card stays here.
    private var progressInJobBar: Bool { modules?.isOn(.v3ScopeEngine) ?? false }
    @State private var copied = false
    @State private var receiptSaveNote: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            // An always-present anchor so the pre-flight sheet can be
            // presented even when neither card is showing.
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            if center.isActive {
                if !progressInJobBar { progressCard }
            } else if center.showReceipt, let receipt = center.lastReceipt {
                receiptCard(receipt)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.isActive)
        .animation(.easeInOut(duration: 0.2), value: center.showReceipt)
        // A8: every export passes through the pre-flight sheet.
        .sheet(item: Binding(get: { center.pendingPreflight },
                             set: { center.pendingPreflight = $0 })) { request in
            ExportPreflightSheet(request: request,
                                 onStart: { confirmed in
                                     center.pendingPreflight = nil
                                     ExportJobRunner.shared.start(confirmed)
                                 },
                                 onCancel: { center.pendingPreflight = nil })
        }
    }

    private var progressCard: some View {
        VStack(spacing: 10) {
            Text(center.title)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if center.total > 0 {
                ProgressView(value: center.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("\(center.done) / \(center.total)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                center.cancel()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 32)
        .transition(.opacity)
    }

    private func receiptCard(_ receipt: ExportReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: receipt.outcome))
                    .foregroundColor(color(for: receipt.outcome))
                Text(receipt.title)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button {
                    center.dismissReceipt()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss — the receipt is kept on disk")
                .accessibilityLabel("Dismiss export receipt")
            }

            Text(receipt.verdictLine)
                .font(.system(size: 11))
                .foregroundColor(color(for: receipt.outcome))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("export.receipt.verdict")
            // OUT-04/07: what was selected, written, checked, excluded, failed — and where the inventory is.
            if let reconciliation = receipt.reconciliationLine {
                Text(reconciliation)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("export.receipt.reconciliation")
            }
            if let inventory = receipt.inventoryPath {
                Text(String(localized: "Inventory: \((inventory as NSString).lastPathComponent) — every file with its SHA-256, beside the files"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .help(inventory)
                    .accessibilityIdentifier("export.receipt.inventory")
            }

            if let error = receipt.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verification = receipt.verificationLine {
                Text(verification)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.receipt.verification")
            }

            Text(receipt.destinationURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(receipt.destination)

            if let hash = receipt.sha256Hex {
                HStack(spacing: 4) {
                    Text("SHA-256 \(hash.prefix(16))…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button {
                        PlatformClipboard.copyString(hash)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the full SHA-256")
                    .accessibilityLabel("Copy SHA-256")
                }
            }

            HStack(spacing: 8) {
                if receipt.isResumable {
                    Button {
                        center.resume(receipt)
                    } label: {
                        Label("Resume", systemImage: "arrow.clockwise")
                    }
                    .font(.system(size: 11))
                    .help("Continue this export from message \((receipt.resumeRequest?.skipFirst ?? 0) + 1); what was written stays")
                    .accessibilityIdentifier("export.receipt.resume")
                }
                // R06: the files are there, the record is not — finish it here, from the kept manifest.
                if receipt.outcome == .unverified {
                    Button {
                        Task { await center.finishInventory(receipt) }
                    } label: {
                        Label(String(localized: "Finish inventory"), systemImage: "list.bullet.clipboard")
                    }
                    .font(.system(size: 11))
                    .help(String(localized: "Build the inventory from the kept manifest and re-hash every file; nothing is rewritten"))
                    .accessibilityIdentifier("export.receipt.finishInventory")
                } else if receipt.isFolder, receipt.inventoryPath != nil {
                    Button {
                        Task { await center.verifyExport(receipt) }
                    } label: {
                        Label(String(localized: "Verify export"), systemImage: "checkmark.shield")
                    }
                    .font(.system(size: 11))
                    .help(String(localized: "Re-read every listed file and compare its hash with the inventory"))
                    .accessibilityIdentifier("export.receipt.verify")
                }
                #if os(macOS)
                if receipt.destination != "—" {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([receipt.destinationURL])
                    }
                    .font(.system(size: 11))
                    .help("Show the exported file or folder in Finder")
                }
                Button(receiptSaveNote ?? String(localized: "Save receipt…")) { saveReceipt(receipt) }
                    .font(.system(size: 11))
                    .help(receiptSaveNote ?? String(localized: "Save this receipt as plain text"))
                #endif
                Spacer()
                Text(receipt.completedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 300)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 32)
        .transition(.opacity)
        .accessibilityIdentifier("export.receipt")
    }

    private func icon(for outcome: ExportReceipt.Outcome) -> String {
        switch outcome {
        case .complete: return "checkmark.seal.fill"
        case .truncated, .partial: return "exclamationmark.circle.fill"
        case .unverified: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for outcome: ExportReceipt.Outcome) -> Color {
        switch outcome {
        case .complete: return .green
        case .truncated, .partial, .unverified: return .orange
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }

    #if os(macOS)
    private func saveReceipt(_ receipt: ExportReceipt) {
        let panel = ManagedSavePanel()
        panel.nameFieldStringValue = "mailin-export-receipt.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try receipt.plainText().write(to: url, atomically: true, encoding: .utf8)
            receiptSaveNote = String(localized: "Receipt saved")
        } catch {
            receiptSaveNote = String(localized: "Receipt not saved: \(error.localizedDescription)")
        }
    }
    #endif
}
