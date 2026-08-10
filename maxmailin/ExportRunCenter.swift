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

import SwiftUI

@MainActor
@Observable
final class ExportRunCenter {
    static let shared = ExportRunCenter()

    private(set) var isActive = false
    private(set) var title = ""
    private(set) var done = 0
    private(set) var total = 0

    private var task: Task<Void, Never>?

    private init() {}

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

    func cancel() {
        task?.cancel()
    }

    private func finish() {
        isActive = false
        task = nil
        done = 0
        total = 0
    }
}

/// Minimal progress + cancel overlay for streaming exports. Attached once at
/// the ContentView level; hidden unless an export is running.
struct ExportProgressOverlayView: View {
    @State private var center = ExportRunCenter.shared

    var body: some View {
        Group {
            if center.isActive {
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
        }
        .animation(.easeInOut(duration: 0.2), value: center.isActive)
    }
}
