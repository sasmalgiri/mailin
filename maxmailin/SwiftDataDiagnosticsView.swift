//
//  SwiftDataDiagnosticsView.swift
//  maxmailin
//
//  Developer / power-user diagnostics for the v2 storage layer. Lets you:
//    • See SwiftData + FTS5 row counts in real time
//    • Import the bundled sample mbox through BulkImportCoordinator
//    • Test full-text search against the FTS5 index
//    • Force-rerun migration
//    • Clear SwiftData store (for testing)
//
//  Strictly local. Hidden behind About → SwiftData v2 Diagnostics.
//

import SwiftUI

struct SwiftDataDiagnosticsView: View {
    @State private var coordinator = BulkImportCoordinator()
    @ObservedObject private var migration = MigrationService.shared

    @State private var swiftDataCount: Int = 0
    @State private var ftsCount: Int = 0
    @State private var searchQuery: String = ""
    @State private var searchResults: [MBOXParser.RawEmail] = []
    @State private var lastSearchDuration: TimeInterval?
    @State private var infoMessage: String?
    @State private var showClearConfirm = false

    // Phase 2 proof: paginated browser backed by EmailStore.
    @State private var paginated = PaginatedEmailViewModel(pageSize: 25)

    var body: some View {
        Form {
            Section("Storage counts") {
                LabeledContent("SwiftData rows") {
                    Text("\(swiftDataCount)").monospacedDigit()
                }
                LabeledContent("FTS5 indexed rows") {
                    Text("\(ftsCount)").monospacedDigit()
                }
                Button("Refresh counts") {
                    Task { await refreshCounts() }
                }
            }

            Section("Bulk import (uses BulkImportCoordinator)") {
                Text(coordinatorStatusText)
                    .font(.callout)
                    .foregroundStyle(coordinatorStatusColor)
                if let frac = coordinatorProgressFraction {
                    ProgressView(value: frac)
                }
                Button("Import bundled sample mbox") {
                    importBundledSample()
                }
                .disabled(isImporting)
                Button("Cancel current import", role: .destructive) {
                    coordinator.cancel()
                }
                .disabled(!isImporting)
            }

            Section("FTS5 search test") {
                TextField("Try a word, e.g. invoice", text: $searchQuery)
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                Button("Search") {
                    Task { await runSearch() }
                }
                .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                if let dur = lastSearchDuration {
                    Text("\(searchResults.count) hits in \(String(format: "%.3f", dur))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(searchResults.prefix(10), id: \.id) { email in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email.headers["Subject"] ?? "(No Subject)")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(email.headers["From"] ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("Migration") {
                Text(migrationStatusText)
                    .font(.callout)
                Button("Force re-migrate legacy archive") {
                    Task { await MigrationService.shared.forceMigrate() }
                }
            }

            Section("Phase 2 — Paginated browser (PaginatedEmailViewModel)") {
                HStack {
                    Text("Loaded in memory")
                    Spacer()
                    Text("\(paginated.emails.count) / \(paginated.totalCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Refresh page 1") {
                    Task { await paginated.refresh() }
                }
                Button("Load next page") {
                    Task { await paginated.loadMore() }
                }
                .disabled(paginated.isLoading)
                if paginated.isLoading {
                    HStack { ProgressView(); Text("Loading…") }
                }
                if let err = paginated.loadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                ForEach(paginated.emails.prefix(10), id: \.id) { email in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email.headers["Subject"] ?? "(No Subject)")
                            .font(.callout)
                            .lineLimit(1)
                        Text(email.headers["From"] ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if paginated.emails.count > 10 {
                    Text("+ \(paginated.emails.count - 10) more in memory window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Danger zone") {
                Button("Clear SwiftData + FTS5", role: .destructive) {
                    showClearConfirm = true
                }
            }

            if let infoMessage {
                Section { Text(infoMessage).font(.footnote) }
            }
        }
        .navigationTitle("SwiftData v2 Diagnostics")
        .task {
            await refreshCounts()
            await paginated.refresh()
        }
        .alert("Clear all v2 storage?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                Task { await clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every email in the SwiftData store and the FTS5 search index. Legacy mailin JSON archive (if any) is not touched.")
        }
    }

    // MARK: - State helpers

    private var coordinatorStatusText: String {
        switch coordinator.status {
        case .idle: return "Idle"
        case .hashing(let file): return "Hashing \(file)…"
        case .parsing(let file): return "Parsing \(file)…"
        case .persisting(let p, let t): return "Persisting \(p)/\(t)"
        case .indexing(let p, let t): return "Indexing \(p)/\(t)"
        case .completed(let n, let skipped):
            return skipped > 0
                ? "Completed — \(n) imported, \(skipped) already in store"
                : "Completed — \(n) emails imported"
        case .failed(let m): return "Failed: \(m)"
        case .cancelled: return "Cancelled"
        }
    }

    private var coordinatorStatusColor: Color {
        switch coordinator.status {
        case .failed: return .red
        case .completed: return .green
        case .cancelled: return .orange
        default: return .primary
        }
    }

    private var coordinatorProgressFraction: Double? {
        switch coordinator.status {
        case .persisting(let p, let t), .indexing(let p, let t):
            return t > 0 ? Double(p) / Double(t) : nil
        default: return nil
        }
    }

    private var isImporting: Bool {
        switch coordinator.status {
        case .idle, .completed, .failed, .cancelled: return false
        default: return true
        }
    }

    private var migrationStatusText: String {
        switch migration.status {
        case .idle: return "Idle"
        case .checking: return "Checking for legacy archive…"
        case .migrating:
            return "Migrating \(migration.migratedCount)/\(migration.totalCount) (\(Int(migration.progressFraction * 100))%)"
        case .completed: return "Completed"
        case .skipped: return "No legacy archive — nothing to migrate"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    // MARK: - Actions

    private func refreshCounts() async {
        async let sd = (try? await EmailStore.shared.totalCount()) ?? 0
        async let fts = (try? await FTSSearchIndex.shared.rowCount()) ?? 0
        let (s, f) = await (sd, fts)
        await MainActor.run {
            swiftDataCount = s
            ftsCount = f
        }
    }

    private func importBundledSample() {
        guard let url = Bundle.main.url(forResource: "demo_emails", withExtension: "mbox")
            ?? Bundle.main.url(forResource: "sample", withExtension: "mbox") else {
            infoMessage = "Bundled sample mbox not found in app bundle."
            return
        }
        infoMessage = nil
        coordinator.startImport(urls: [url])
        Task {
            while isImporting {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refreshCounts()
            }
            await refreshCounts()
        }
    }

    private func runSearch() async {
        let q = searchQuery
        let start = Date()
        let ids = (try? await FTSSearchIndex.shared.search(q, limit: 100)) ?? []
        let duration = Date().timeIntervalSince(start)

        var hits: [MBOXParser.RawEmail] = []
        for id in ids {
            if let e = try? await EmailStore.shared.fullEmail(id: id) {
                hits.append(e)
            }
        }
        await MainActor.run {
            searchResults = hits
            lastSearchDuration = duration
        }
    }

    private func clearAll() async {
        do {
            try await EmailStore.shared.clearAll()
            try await FTSSearchIndex.shared.clear()
            await refreshCounts()
            await MainActor.run {
                searchResults = []
                infoMessage = "Cleared SwiftData store and FTS5 index."
            }
        } catch {
            await MainActor.run {
                infoMessage = "Clear failed: \(error.localizedDescription)"
            }
        }
    }
}
