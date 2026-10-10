@testable import ArchiveCore
//
//  ArchiveScope.swift
//  maxmailin
//
//  The scope a tool was opened on, available to its 3.0 engines.
//
//  Tools receive a bounded working set (`ArchiveWorkingSetView`, newest
//  2,000) for display. Their 3.0 actions must instead cover the WHOLE scope
//  (rule 1). The host publishes the scope query and its exact total here, so
//  an action can run over every email the tool was opened on — through the
//  scope engine — without loading them. A tool opened without a host defaults
//  to the whole archive.
//
//  Also: the confirmation-with-count every whole-scope action shows first
//  (§3-X2, rule 4), and the line that tells the user the action covers the
//  whole scope rather than the loaded list.
//

import SwiftUI

struct ArchiveScope: Equatable, Sendable {
    var query: EmailQuery
    /// Exact number of emails in scope, when known.
    var total: Int?
    /// How many of them the tool's list shows.
    var loaded: Int?

    static let wholeArchive = ArchiveScope(query: .all, total: nil, loaded: nil)

    /// Exact count, asking the store if the host did not supply it.
    func resolvedTotal() async -> Int {
        if let total { return total }
        return (try? await ArchiveDataService.shared.count(query: query)) ?? 0
    }

    var description: String { ScopeJob.describe(query) }
}

private struct ArchiveScopeKey: EnvironmentKey {
    static let defaultValue = ArchiveScope.wholeArchive
}

extension EnvironmentValues {
    var archiveScope: ArchiveScope {
        get { self[ArchiveScopeKey.self] }
        set { self[ArchiveScopeKey.self] = newValue }
    }
}

// MARK: - Whole-scope note

/// One line above a tool's actions when its 3.0 engine is on.
struct WholeScopeNote: View {
    @Environment(\.archiveScope) private var scope
    @State private var total: Int?

    var body: some View {
        Label {
            if let total {
                Text("Actions here cover all \(total.formatted()) emails in scope (\(scope.description)), not only the emails listed.")
            } else {
                Text("Actions here cover every email in scope, not only the emails listed.")
            }
        } icon: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: scope) { total = await scope.resolvedTotal() }
    }
}

// MARK: - Confirmation with count (§3-X2)

/// A pending whole-scope action awaiting confirmation.
struct ScopeConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let verb: String
    let count: Int
    let detail: String?
    let destructive: Bool
    let action: @MainActor () async -> Void
}

extension View {
    /// Presents "This will <verb> N emails" before running a whole-scope
    /// action. Set the binding to a request to ask.
    func scopeConfirmation(_ request: Binding<ScopeConfirmationRequest?>) -> some View {
        alert(request.wrappedValue?.title ?? "",
              isPresented: Binding(get: { request.wrappedValue != nil },
                                   set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { req in
            Button(req.verb, role: req.destructive ? .destructive : nil) {
                Task { @MainActor in await req.action() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { req in
            Text(String(localized: "This applies to \(req.count) emails.") + (req.detail.map { "\n\n" + $0 } ?? ""))
        }
    }
}

/// Builds a request after counting the scope.
@MainActor
enum ScopeConfirm {
    static func request(_ scope: ArchiveScope, title: String, verb: String, detail: String? = nil,
                        destructive: Bool = false,
                        action: @escaping @MainActor () async -> Void) async -> ScopeConfirmationRequest {
        ScopeConfirmationRequest(title: title, verb: verb, count: await scope.resolvedTotal(),
                                 detail: detail, destructive: destructive, action: action)
    }
}

/// §3-H (switch: `v3PagedLists`): read by views that page lists.
enum V3Paging {
    nonisolated(unsafe) static var isOn = false
}
