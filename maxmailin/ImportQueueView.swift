//
//  ImportQueueView.swift
//  mailin
//
//  A4: what has been imported this session, what is running, what is waiting —
//  and each source's verdict.
//
//  The gap this closes: import progress lives in a toolbar string, so once a
//  run finishes the only trace is a receipt the user has to go and find in the
//  File menu. With several sources, "did that third mbox actually finish?" had
//  no answer on screen.
//
//  The queue holds the same verdict the receipt does (`ImportVerdict`:
//  Complete / Partial / Failed), computed from the same reconciliation, so the
//  two can never disagree — a queue that said "done" next to a receipt that
//  said "partial" would be worse than no queue.
//
//  Behind `Capability.importQueue` (Preview, OFF by default; requires
//  `guidedImport`). With it off, progress shows in the toolbar only and
//  receipts are still written and still readable.
//

import SwiftUI
import Observation

/// Session-scoped record of import activity.
///
/// Deliberately NOT persisted: it is a view of this session's work, and the
/// durable record is the receipt. A persisted queue would be a second,
/// diverging source of truth about what happened.
@MainActor
@Observable
final class ImportQueue {
    enum State: Equatable, Sendable {
        case waiting
        case running(fraction: Double)
        case finished(ImportVerdict)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .waiting, .running: return false
            case .finished, .failed, .cancelled: return true
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let path: String
        let sizeBytes: Int64
        var state: State = .waiting
        var messagesImported: Int = 0
        var startedAt: Date?
        var finishedAt: Date?

        var duration: TimeInterval? {
            guard let startedAt else { return nil }
            return (finishedAt ?? Date()).timeIntervalSince(startedAt)
        }
    }

    static let shared = ImportQueue()

    private(set) var entries: [Entry] = []

    var isActive: Bool { entries.contains { !$0.state.isTerminal } }
    var runningCount: Int { entries.filter { if case .running = $0.state { return true }; return false }.count }
    var waitingCount: Int { entries.filter { $0.state == .waiting }.count }

    func enqueue(urls: [URL]) {
        for url in urls {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(Entry(name: url.lastPathComponent, path: url.path, sizeBytes: size))
        }
    }

    func markRunning(path: String, fraction: Double) {
        guard let index = entries.lastIndex(where: { $0.path == path }) else { return }
        if entries[index].startedAt == nil { entries[index].startedAt = Date() }
        entries[index].state = .running(fraction: min(max(fraction, 0), 1))
    }

    func markFinished(path: String, verdict: ImportVerdict, messages: Int) {
        guard let index = entries.lastIndex(where: { $0.path == path }) else { return }
        entries[index].state = .finished(verdict)
        entries[index].messagesImported = messages
        entries[index].finishedAt = Date()
    }

    func markFailed(path: String, reason: String) {
        guard let index = entries.lastIndex(where: { $0.path == path }) else { return }
        entries[index].state = .failed(reason)
        entries[index].finishedAt = Date()
    }

    /// Anything still waiting or running when a run is cancelled. Marked
    /// rather than removed, so the user can see what did not happen.
    func markRemainingCancelled() {
        for index in entries.indices where !entries[index].state.isTerminal {
            entries[index].state = .cancelled
            entries[index].finishedAt = Date()
        }
    }

    /// Clears finished entries only — never one still running.
    func clearFinished() {
        entries.removeAll { $0.state.isTerminal }
    }
}

// MARK: - View

struct ImportQueueView: View {
    @Environment(ModuleRegistry.self) private var modules
    var queue = ImportQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if queue.entries.isEmpty {
                empty
            } else {
                List(queue.entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, minHeight: 300)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Imports")
                    .font(.title3.weight(.semibold))
                Text(queue.isActive
                     ? "\(queue.runningCount) running, \(queue.waitingCount) waiting"
                     : "Nothing running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear finished") { queue.clearFinished() }
                .controlSize(.small)
                .disabled(!queue.entries.contains { $0.state.isTerminal })
        }
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No imports this session.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Finished imports from earlier sessions are in File ▸ Import Receipts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func row(_ entry: ImportQueue.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(for: entry.state)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                switch entry.state {
                case .waiting:
                    Text("Waiting")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .running(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                case .finished(let verdict):
                    // Same verdict text as the receipt, from the same
                    // reconciliation — the two cannot disagree.
                    Text("\(verdict.label) — \(verdict.summary)")
                        .font(.caption2)
                        .foregroundStyle(colour(for: verdict))
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.messagesImported > 0 {
                        Text("\(entry.messagesImported) messages"
                             + (entry.duration.map { " in \(Int($0))s" } ?? ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .cancelled:
                    Text("Cancelled before it ran")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func icon(for state: ImportQueue.State) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .finished(let verdict):
            Image(systemName: verdict.isComplete
                  ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(colour(for: verdict))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.orange)
        }
    }

    private func colour(for verdict: ImportVerdict) -> Color {
        switch verdict {
        case .complete: return .green
        case .partial: return .orange
        case .failed: return .red
        }
    }
}
