//
//  ImportQueueView.swift
//  mailin
//
//  A4: what has been imported this session, what is running, what is waiting —
//  and each source's verdict. Plus the controls the plan asks for: pause and
//  resume the run, stop the file that is importing, cancel everything, and
//  reorder the files that have not started. Each running row shows its
//  stage, throughput, current batch envelope, indexed fraction, an ETA that
//  is labelled as an estimate, and the reason when nothing is moving.
//
//  The gap this closes: import progress lived in a toolbar string, so once a
//  run finished the only trace was a receipt the user had to find in the
//  File menu. With several sources, "did that third mbox actually finish?"
//  had no answer on screen.
//
//  The queue holds the same verdict the receipt does (`ImportVerdict`:
//  Complete / Partial / Failed), computed from the same reconciliation, so the
//  two can never disagree — a queue that said "done" next to a receipt that
//  said "partial" would be worse than no queue.
//
//  Live figures come from `BulkImportCoordinator.live`; the queue itself is
//  a session record. Neither is persisted: the durable record is the receipt.
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
        /// Stopped by the user after a committed batch; checkpoint kept.
        case stopped(messages: Int)

        var isTerminal: Bool {
            switch self {
            case .waiting, .running: return false
            case .finished, .failed, .cancelled, .stopped: return true
            }
        }
        var isWaiting: Bool { self == .waiting }
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

    func markStopped(path: String, messages: Int) {
        guard let index = entries.lastIndex(where: { $0.path == path }) else { return }
        entries[index].state = .stopped(messages: messages)
        entries[index].messagesImported = messages
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

    // MARK: Ordering (A4)

    /// The coordinator asks this before each file: the first WAITING entry, in
    /// the queue's current order, that is among the run's remaining sources.
    func preferredNext(among remaining: [URL]) -> URL? {
        for entry in entries where entry.state.isWaiting {
            if let url = remaining.first(where: { $0.path == entry.path }) { return url }
        }
        return nil
    }

    /// Move a waiting entry one step up (-1) or down (+1) past the nearest
    /// other waiting entry. Running and finished rows never move.
    func move(id: UUID, by delta: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].state.isWaiting, delta != 0 else { return }
        var target = index + delta
        while target >= 0 && target < entries.count && !entries[target].state.isWaiting {
            target += delta
        }
        guard target >= 0 && target < entries.count else { return }
        entries.swapAt(index, target)
    }

    func canMove(id: UUID, by delta: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state.isWaiting else { return false }
        var target = index + delta
        while target >= 0 && target < entries.count {
            if entries[target].state.isWaiting { return true }
            target += delta
        }
        return false
    }
}

// MARK: - View

struct ImportQueueView: View {
    @Environment(ModuleRegistry.self) private var modules
    var queue = ImportQueue.shared
    /// The run in progress, for live figures and control. nil renders the
    /// session record only.
    var coordinator: BulkImportCoordinator? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let reason = coordinator?.pauseReason, queue.isActive {
                pausedBanner(reason)
                Divider()
            }
            if queue.entries.isEmpty {
                empty
            } else {
                List(queue.entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 340)
        .accessibilityIdentifier("import.queue")
    }

    // MARK: Header and controls

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
            if let coordinator, queue.isActive {
                if coordinator.isPausedByUser {
                    Button {
                        coordinator.resume()
                    } label: { Label("Resume", systemImage: "play.fill") }
                        .help("Continue the import from the next batch")
                        .accessibilityIdentifier("import.queue.resume")
                } else {
                    Button {
                        coordinator.pause()
                    } label: { Label("Pause", systemImage: "pause.fill") }
                        .help("Pause at the next batch boundary — rows already saved stay saved")
                        .accessibilityIdentifier("import.queue.pause")
                }
                Button(role: .destructive) {
                    coordinator.cancel()
                } label: { Label("Cancel All", systemImage: "xmark.circle") }
                    .help("Stop the run. Every file keeps its checkpoint, so importing it again resumes where it stopped")
                    .accessibilityIdentifier("import.queue.cancelAll")
            }
            Button("Clear finished") { queue.clearFinished() }
                .disabled(!queue.entries.contains { $0.state.isTerminal })
                .help("Remove finished, failed and stopped rows from this list; their receipts stay on disk")
        }
        .controlSize(.small)
        .padding(16)
    }

    private func pausedBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
        .accessibilityIdentifier("import.queue.pauseReason")
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

    // MARK: Rows

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
                    rowControls(entry)
                }

                switch entry.state {
                case .waiting:
                    Text("Waiting")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .running(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    runningDetail(entry, fraction: fraction)
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
                case .stopped(let messages):
                    Text("Stopped by you after \(messages) messages — import this file again to resume from there")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("import.queue.row")
    }

    /// Stage · throughput · ETA (estimate) · batch envelope · indexed fraction.
    @ViewBuilder
    private func runningDetail(_ entry: ImportQueue.Entry, fraction: Double) -> some View {
        let isCurrent = coordinator?.live.currentPath == entry.path
        let live = isCurrent ? coordinator?.live : nil
        HStack(spacing: 6) {
            Text("\(Int(fraction * 100))%")
                .font(.caption2.monospacedDigit())
            if let stage = isCurrent ? stageText(coordinator?.status) : nil {
                Text("·").foregroundStyle(.secondary)
                Text(stage)
            }
            if let rate = live?.throughputBytesPerSecond {
                Text("·").foregroundStyle(.secondary)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s")
                    .monospacedDigit()
            }
            if let eta = live?.estimatedSecondsRemaining {
                Text("·").foregroundStyle(.secondary)
                Text("about \(etaText(eta)) left (estimate)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        if let live {
            HStack(spacing: 6) {
                if let envelope = live.envelope {
                    Text("Batch ≤ \(envelope.maxMessages) messages" + (envelope.maxBytes == Int.max ? "" : " / \(ByteCountFormatter.string(fromByteCount: Int64(envelope.maxBytes), countStyle: .memory))"))
                }
                if let indexed = live.indexedFraction {
                    Text("·").foregroundStyle(.secondary)
                    Text("indexed \(Int(indexed * 100))%" + (live.indexBacklog ? " (behind)" : ""))
                }
                if live.messagesThisFile > 0 {
                    Text("·").foregroundStyle(.secondary)
                    Text("\(live.messagesThisFile) saved")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("import.queue.live")
        }
    }

    @ViewBuilder
    private func rowControls(_ entry: ImportQueue.Entry) -> some View {
        switch entry.state {
        case .waiting:
            Button {
                queue.move(id: entry.id, by: -1)
            } label: { Image(systemName: "chevron.up") }
                .disabled(!queue.canMove(id: entry.id, by: -1))
                .help("Import this file earlier")
                .accessibilityLabel("Move \(entry.name) up")
            Button {
                queue.move(id: entry.id, by: 1)
            } label: { Image(systemName: "chevron.down") }
                .disabled(!queue.canMove(id: entry.id, by: 1))
                .help("Import this file later")
                .accessibilityLabel("Move \(entry.name) down")
        case .running:
            if let coordinator, coordinator.live.currentPath == entry.path {
                Button {
                    coordinator.skipCurrentSource()
                } label: { Image(systemName: "stop.circle") }
                    .help("Stop this file after the current batch and continue with the next; its checkpoint is kept")
                    .accessibilityLabel("Stop importing \(entry.name)")
                    .accessibilityIdentifier("import.queue.stopSource")
            }
        default:
            EmptyView()
        }
    }

    private func stageText(_ status: BulkImportCoordinator.Status?) -> String? {
        switch status {
        case .hashing: return "hashing"
        case .parsing: return "parsing"
        case .persisting(let done, let total): return "saving \(done)/\(total)"
        case .indexing(let done, let total): return "indexing \(done)/\(total)"
        default: return nil
        }
    }

    private func etaText(_ seconds: Double) -> String {
        if seconds < 90 { return "\(max(1, Int(seconds.rounded()))) s" }
        if seconds < 5_400 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3600)
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
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
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
