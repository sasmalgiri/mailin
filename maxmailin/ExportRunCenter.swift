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

    func dismissReceipt() {
        showReceipt = false
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
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // An always-present anchor so the pre-flight sheet can be
            // presented even when neither card is showing.
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            if center.isActive {
                progressCard
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

            if let error = receipt.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                #if os(macOS)
                if receipt.destination != "—" {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([receipt.destinationURL])
                    }
                    .font(.system(size: 11))
                    .help("Show the exported file or folder in Finder")
                }
                Button("Save receipt…") { saveReceipt(receipt) }
                    .font(.system(size: 11))
                    .help("Save this receipt as plain text")
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
        case .cancelled: return "stop.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for outcome: ExportReceipt.Outcome) -> Color {
        switch outcome {
        case .complete: return .green
        case .truncated, .partial: return .orange
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }

    #if os(macOS)
    private func saveReceipt(_ receipt: ExportReceipt) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin-export-receipt.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? receipt.plainText().write(to: url, atomically: true, encoding: .utf8)
    }
    #endif
}
