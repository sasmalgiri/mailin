//
//  MenuBarSearchView.swift
//  maxmailin
//
//  Menu-bar quick search (macOS): search the whole archive from the menu bar
//  without switching to the app — the ultimate minimum-touch surface. Ranked
//  (bm25) results via the bounded repository; choosing one activates mailin
//  and opens that email through the same path Spotlight uses.
//
//  Toggle: Settings ▸ Display ▸ "Menu bar quick search".
//

#if os(macOS)
import SwiftUI
import AppKit

struct MenuBarSearchView: View {
    @State private var query = ""
    @State private var results: [EmailSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search your archive…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { openFirstResult() }
                    .accessibilityLabel("Search your email archive")
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)

            Divider()

            if results.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Type to search all your emails — press Return to open the top result."
                     : (isSearching ? "Searching…" : "No matches."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results) { summary in
                            Button {
                                open(summary.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(summary.subject.isEmpty ? "(No Subject)" : summary.subject)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(summary.date, style: .date)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Text(summary.from)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open in mailin")
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
            HStack {
                Text("Return opens the top result")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Open mailin") { activateApp() }
                    .font(.system(size: 11))
                    .help("Bring the main mailin window forward")
            }
            .padding(8)
        }
        .frame(width: 380)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)   // debounce
            guard !Task.isCancelled else { return }
            let query = ArchiveQueryCompiler.compile(trimmed)
            let page = try? await ArchiveDataService.shared.searchRanked(query: query, cursor: nil, limit: 12)
            guard !Task.isCancelled else { return }
            results = page?.summaries ?? []
            isSearching = false
        }
    }

    private func openFirstResult() {
        if let first = results.first { open(first.id) }
    }

    private func open(_ id: UUID) {
        activateApp()
        // Same navigation path Spotlight results use.
        NotificationCenter.default.post(name: .spotlightEmailSelected, object: id)
        dismiss()
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
#endif
