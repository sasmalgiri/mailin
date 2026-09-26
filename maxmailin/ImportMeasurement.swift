//
//  ImportMeasurement.swift
//  maxmailin
//
//  A11: Release-safe measurement of a real file through the PRODUCTION
//  import path. The test target cannot produce Release numbers (`@testable`
//  needs ENABLE_TESTABILITY, which Release correctly does not set), so this
//  runs inside the app: pick a file, import it into a disposable environment
//  under the temporary directory with `BulkImportCoordinator`, report
//  throughput, peak footprint, on-disk growth and the count reconciliation,
//  then delete the environment. Never touches the user's archive — the
//  environment root is gated by `MailinStorageEnvironment.assertNotProduction`.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct FileImportMeasurement: Codable, Sendable, Equatable {
    var fileName: String
    var fileBytes: Int64
    var configuration: String
    var engine: String
    var startedAt: Date
    var seconds: Double

    var discovered: Int
    var parsed: Int
    var damaged: Int
    var inserted: Int?
    var duplicates: Int?
    var persistFailed: Int
    var indexed: Int
    var storedRows: Int
    var ftsRows: Int
    var batches: Int

    var rssBaselineMB: Double
    var rssPeakMB: Double
    var rssAfterMB: Double

    var storeBytes: Int64
    var ftsBytes: Int64

    var notes: [String]

    var throughputMiBPerSecond: Double { seconds > 0 ? Double(fileBytes) / 1_048_576 / seconds : 0 }
    var messagesPerSecond: Double { seconds > 0 ? Double(parsed) / seconds : 0 }
    var storeRatio: Double { fileBytes > 0 ? Double(storeBytes) / Double(fileBytes) : 0 }
    var ftsRatio: Double { fileBytes > 0 ? Double(ftsBytes) / Double(fileBytes) : 0 }
    /// The same three identities the measurement tests assert.
    var reconciles: Bool {
        discovered == parsed + damaged
            && storedRows == parsed - persistFailed
            && ftsRows == storedRows
    }

    /// One line per figure, for SCALE_RESULTS.md.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("mailin import measurement — \(configuration)")
        lines.append("File: \(fileName) (\(ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file)))")
        lines.append("Engine: \(engine)")
        lines.append("Started: \(startedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append(String(format: "Wall: %.1f s · %.2f MiB/s · %.1f msg/s", seconds, throughputMiBPerSecond, messagesPerSecond))
        lines.append("Discovered / parsed / damaged: \(discovered) / \(parsed) / \(damaged)")
        lines.append("Inserted / duplicates: \(inserted.map(String.init) ?? "n/a") / \(duplicates.map(String.init) ?? "n/a")")
        lines.append("Persist failed: \(persistFailed) · Indexed: \(indexed) · Batches: \(batches)")
        lines.append("Stored rows: \(storedRows) · FTS rows: \(ftsRows) · Reconciles: \(reconciles ? "yes" : "NO")")
        lines.append(String(format: "RSS MiB baseline → peak → after: %.0f → %.0f → %.0f (peak Δ %.0f)", rssBaselineMB, rssPeakMB, rssAfterMB, rssPeakMB - rssBaselineMB))
        lines.append(String(format: "Store / FTS on disk: %lld / %lld B (%.3f× / %.3f× source)", storeBytes, ftsBytes, storeRatio, ftsRatio))
        for note in notes { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}

enum FileImportHarness {
    /// Import `file` into a disposable environment under `root` through the
    /// production coordinator and measure it. The caller owns `root`.
    @MainActor
    static func measure(file: URL, useOffsetEngine: Bool, root: URL,
                        coordinator existing: BulkImportCoordinator? = nil,
                        onCoordinator: (@MainActor (BulkImportCoordinator) -> Void)? = nil) async throws -> FileImportMeasurement {
        try MailinStorageEnvironment.assertNotProduction(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        let ftsDir = root.appendingPathComponent("fts", isDirectory: true)
        let store = SQLiteEmailStore(directory: storeDir)
        let fts = FTSSearchIndex(shardsDirectory: ftsDir)
        let checkpoints = ImportCheckpointStore(storeURL: root.appendingPathComponent("checkpoints.json"))
        let coordinator = BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints,
                                                requiresStorageActivation: false)
        onCoordinator?(coordinator)

        let fileBytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        var options = BulkImportCoordinator.Options()
        options.useOffsetEngine = useOffsetEngine
        options.recordLocators = useOffsetEngine
        options.enforceStoragePreflight = false

        let probe = FootprintProbe(baseline: currentFootprintBytes())
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { batch in probe.record(count: batch.count, footprint: currentFootprintBytes()) }

        let clock = ContinuousClock()
        let startedAt = Date()
        let start = clock.now
        let summary = try await coordinator.runImport(urls: [file], options: options, callbacks: callbacks)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let rssAfter = currentFootprintBytes()

        try? await store.checkpoint()
        let stored = try await store.totalCount()
        let ftsRows = try await fts.rowCount()

        var notes = summary.warnings
        if summary.ftsDegraded { notes.append("FTS degraded for \(summary.ftsFailedBatchCount) batch(es); the launch reconciler repairs the drift.") }
        if summary.resumed, let detail = summary.resumedDetail { notes.append(detail) }
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let mib = { (b: UInt64) in Double(b) / 1_048_576.0 }
        return FileImportMeasurement(
            fileName: file.lastPathComponent,
            fileBytes: fileBytes,
            configuration: configuration,
            engine: useOffsetEngine ? "offset" : "streaming",
            startedAt: startedAt,
            seconds: seconds,
            discovered: summary.discovered,
            parsed: summary.parsed,
            damaged: summary.damaged,
            inserted: summary.inserted,
            duplicates: summary.duplicates,
            persistFailed: summary.persistFailed,
            indexed: summary.indexed,
            storedRows: stored,
            ftsRows: ftsRows,
            batches: probe.batches,
            rssBaselineMB: mib(probe.baseline),
            rssPeakMB: mib(probe.peak),
            rssAfterMB: mib(rssAfter),
            storeBytes: directoryBytes(storeDir),
            ftsBytes: directoryBytes(ftsDir),
            notes: notes)
    }

    static func directoryBytes(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Peak footprint sampled once per committed batch — the same probe shape
    /// the measurement tests use, so the numbers are comparable.
    final class FootprintProbe: @unchecked Sendable {
        let baseline: UInt64
        private(set) var peak: UInt64
        private(set) var batches = 0
        private let lock = NSLock()
        init(baseline: UInt64) { self.baseline = baseline; self.peak = baseline }
        func record(count: Int, footprint: UInt64) {
            lock.lock(); defer { lock.unlock() }
            batches += 1
            peak = max(peak, footprint)
        }
    }
}

// MARK: - View

/// Pick a file, run it through the production import path into a throwaway
/// environment, read the numbers. Release-safe: nothing here is DEBUG-only.
struct ImportMeasurementView: View {
    @State private var file: URL?
    @State private var useOffsetEngine = false
    @State private var isRunning = false
    @State private var result: FileImportMeasurement?
    @State private var errorMessage: String?
    @State private var coordinator: BulkImportCoordinator?
    @State private var copied = false
    #if os(iOS)
    @State private var showPicker = false
    #endif

    var body: some View {
        Form {
            Section("Source") {
                HStack {
                    Text(file?.lastPathComponent ?? "No file chosen")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(file == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { chooseFile() }
                        .disabled(isRunning)
                        .help("Any mailbox file mailin can import; it is read, never modified")
                }
                Toggle("Use the offset engine", isOn: $useOffsetEngine)
                    .disabled(isRunning)
                    .help("Measure the byte-offset scanner instead of the streaming parser")
                Text("The file is imported into a temporary archive that is deleted afterwards. Your own archive is not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Run") {
                Button(isRunning ? "Measuring…" : "Measure import") { Task { await run() } }
                    .disabled(file == nil || isRunning)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("measurement.run")
                if isRunning, let coordinator {
                    ProgressView(value: coordinator.live.fileFraction)
                    HStack(spacing: 8) {
                        Text("\(Int(coordinator.live.fileFraction * 100))%")
                        if let rate = coordinator.live.throughputBytesPerSecond {
                            Text("· \(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s")
                        }
                        if let reason = coordinator.pauseReason { Text("· \(reason)") }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) { coordinator.cancel() }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            if let result {
                Section("Result — \(result.configuration), \(result.engine) engine") {
                    figure("Wall time", String(format: "%.1f s", result.seconds))
                    figure("Throughput", String(format: "%.2f MiB/s · %.1f msg/s", result.throughputMiBPerSecond, result.messagesPerSecond))
                    figure("Discovered / parsed / damaged", "\(result.discovered) / \(result.parsed) / \(result.damaged)")
                    figure("Stored rows / FTS rows", "\(result.storedRows) / \(result.ftsRows)")
                    figure("Reconciles", result.reconciles ? "Yes" : "No")
                    figure("Footprint MiB (baseline → peak → after)", String(format: "%.0f → %.0f → %.0f", result.rssBaselineMB, result.rssPeakMB, result.rssAfterMB))
                    figure("Store / FTS on disk", String(format: "%.3f× / %.3f× source", result.storeRatio, result.ftsRatio))
                    figure("Batches", "\(result.batches)")
                    ForEach(result.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(copied ? "Copied" : "Copy as text") {
                            PlatformClipboard.copyString(result.plainText())
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }
                        #if os(macOS)
                        Button("Save JSON…") { saveJSON(result) }
                        #endif
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Measure an Import")
        .frame(minWidth: 480, minHeight: 420)
        #if os(iOS)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.data, .folder]) { outcome in
            if case .success(let url) = outcome { file = url }
        }
        #endif
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func chooseFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a mailbox file to measure"
        if panel.runModal() == .OK { file = panel.url }
        #else
        showPicker = true
        #endif
    }

    private func run() async {
        guard let file else { return }
        isRunning = true
        errorMessage = nil
        result = nil
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-measure-\(UUID().uuidString)", isDirectory: true)
        defer {
            isRunning = false
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
        do {
            result = try await FileImportHarness.measure(file: file, useOffsetEngine: useOffsetEngine, root: root,
                                                         onCoordinator: { coordinator = $0 })
        } catch is CancellationError {
            errorMessage = "Cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    private func saveJSON(_ measurement: FileImportMeasurement) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin-import-measurement.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(measurement).write(to: url, options: .atomic)
    }
    #endif
}
