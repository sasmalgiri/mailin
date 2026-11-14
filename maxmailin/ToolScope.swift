@testable import ArchiveCore
//
//  ToolScope.swift
//  maxmailin
//
//  §3-X1 (owner decision 2026-10-11): one tool, one scope rule — wherever it
//  is opened from. A tool used to see the current filter from the sidebar,
//  the whole archive from the Professional / AI page, and the menu's query
//  from a tool window, so the same tool could number or report two different
//  sets of emails without saying so. Now every host opens the tool on the
//  current filter, with a visible choice of the whole archive, and both
//  counts are on screen before anything runs (rule 4).
//

import SwiftUI

/// The Archive page's current filter, published for hosts that are not part
/// of the Archive page (Professional and AI pages, tool windows).
@MainActor
@Observable
final class CurrentArchiveFilter {
    static let shared = CurrentArchiveFilter()
    var query: EmailQuery = .all
}

enum ToolScope {
    /// The scope a tool runs on: the filter unless the user chose the whole
    /// archive (or there is no filter).
    static func query(filter: EmailQuery, wholeArchive: Bool) -> EmailQuery {
        filter.isEmpty || wholeArchive ? .all : filter
    }
}

/// Lets the user choose between the current filter and the whole archive,
/// shows both counts, and builds the tool for the chosen scope.
struct ToolScopeHost<Content: View>: View {
    /// The filter to offer; nil = the Archive page's current filter.
    var filter: EmailQuery? = nil
    @ViewBuilder var content: (EmailQuery) -> Content

    @State private var wholeArchive = false
    @State private var filterCount: Int?
    @State private var totalCount: Int?

    private var currentFilter: EmailQuery { filter ?? CurrentArchiveFilter.shared.query }
    private var hasFilter: Bool { !currentFilter.isEmpty }
    private var chosen: EmailQuery { ToolScope.query(filter: currentFilter, wholeArchive: wholeArchive) }

    var body: some View {
        VStack(spacing: 0) {
            if hasFilter {
                Picker(String(localized: "Scope"), selection: $wholeArchive) {
                    Text(filterCount.map { String(localized: "Current filter · \($0) emails") } ?? String(localized: "Current filter"))
                        .tag(false)
                    Text(totalCount.map { String(localized: "Whole archive · \($0) emails") } ?? String(localized: "Whole archive"))
                        .tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.xSmall)
                .accessibilityIdentifier("tool.scope")
                Divider()
            }
            content(chosen)
                .id(wholeArchive)
        }
        .task(id: currentFilter) {
            let archive = ArchiveDataService.shared
            totalCount = try? await archive.count()
            filterCount = hasFilter ? try? await archive.count(query: currentFilter) : totalCount
        }
    }
}

/// `ToolScopeHost` for tools that still take a working set of emails.
struct ScopedWorkingSet<Content: View>: View {
    var filter: EmailQuery? = nil
    @ViewBuilder var content: ([MBOXParser.RawEmail]) -> Content

    var body: some View {
        ToolScopeHost(filter: filter) { query in
            ArchiveWorkingSetView(query: query, content: content)
        }
    }
}

/// A deadline that counts only time the app is in the foreground: an answer
/// started just before the user switched away is not cut off as "timed out"
/// for the time the system kept the app suspended (V6 walkthrough,
/// 2026-10-11). On the Mac the app is never suspended, so it is wall time.
enum ActiveTimeDeadline {
    static func sleep(seconds: Double) async throws {
        #if os(iOS)
        var counted = 0.0
        while counted < seconds {
            try await Task.sleep(for: .milliseconds(500))
            if await MainActor.run(body: { UIApplication.shared.applicationState == .active }) { counted += 0.5 }
        }
        #else
        try await Task.sleep(for: .seconds(seconds))
        #endif
    }
}
