@testable import ArchiveCore
//
//  SourceFolderSection.swift
//  maxmailin
//
//  IPAD-02 / IPAD-05: the FOLD-01/02 source-folder tree and the Trash, in the
//  list's own sidebar — the iPad's left pane and the iPhone's Filters sheet
//  (and the Mac's Advanced list). Until this, both lived only in the Mac
//  three-pane sidebar (`ArchiveSidebarView`), so an iPad showed no Work,
//  Work/Clients or empty "Archive 2019", and had no way into the Trash.
//
//  Same data as the Mac: `ArchiveSidebarModel` (store aggregates, never a
//  corpus walk) and the same `folderID` filter on the list's query.
//

import SwiftUI

extension Notification.Name {
    /// Rows moved to or restored from the Trash (duplicate removal included):
    /// every count surface re-reads the store.
    static let archiveTrashChanged = Notification.Name("mailin.archiveTrashChanged")
}

extension ArchiveSidebarModel {
    /// One folder row of the flat, indented list the compact sidebar draws.
    struct FlatFolderRow: Identifiable, Equatable {
        let node: ArchiveFolderNode
        let depth: Int
        var id: Int64 { node.folderID }
        /// FOLD-02: the source declares it but nothing is filed in it.
        var isEmptyFolder: Bool { node.declared && node.messageCount == 0 }
    }

    /// One source's folders, depth-first, children right under their parent.
    struct FlatFolderSource: Identifiable, Equatable {
        let sourceID: Int64
        let title: String
        let rows: [FlatFolderRow]
        var id: Int64 { sourceID }
    }

    /// IPAD-02: the trees the Mac sidebar nests, flattened in the same order
    /// with their depth — every folder, empty and nested ones included.
    static func flatFolders(_ trees: [FolderTree]) -> [FlatFolderSource] {
        func walk(_ items: [FolderItem], depth: Int) -> [FlatFolderRow] {
            items.flatMap { [FlatFolderRow(node: $0.node, depth: depth)] + walk($0.children ?? [], depth: depth + 1) }
        }
        return trees.map { FlatFolderSource(sourceID: $0.sourceID, title: $0.title, rows: walk($0.items, depth: 0)) }
    }

    /// How many folders the trees hold in all (the total the header shows).
    var folderRowTotal: Int { Self.flatFolders(folderTrees).reduce(0) { $0 + $1.rows.count } }
}

/// The source-folder tree + Trash for the list's sidebar.
struct SourceFolderSection: View {
    @ObservedObject var model: ParsedEmailListViewModel
    @StateObject private var sidebar = ArchiveSidebarModel()
    /// Folders are drawn a page at a time; the total is always shown.
    @State private var reach = ArchiveSidebarModel.labelPage

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            trashRow
            folders
        }
        .task { await sidebar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .archiveTrashChanged)) { _ in
            Task { @MainActor in await sidebar.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEmailsImported)) { _ in
            Task { @MainActor in await sidebar.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parsingFinished)) { _ in
            Task { @MainActor in await sidebar.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fidelityBackfillCompleted)) { _ in
            Task { @MainActor in await sidebar.refresh() }
        }
    }

    private var trashRow: some View {
        let inTrash = model.reviewStateFilter == .trashed
        return Button {
            model.reviewStateFilter = inTrash ? .active : .trashed
        } label: {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .accessibilityHidden(true)
                Text("Trash")
                    .font(Typography.callout)
                Spacer()
                Text(sidebar.trashedCount.formatted())
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
            .background(inTrash ? AppColors.primary.opacity(0.1) : Color.clear)
            .cornerRadius(CornerRadius.small)
            .contentShape(Rectangle())   // the whole row, as for the folder rows
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: CountPhrase.row(String(localized: "Trash"), messages: sidebar.trashedCount)))
        .accessibilityAddTraits(inTrash ? .isSelected : [])
        .accessibilityIdentifier("sidebar.trash")
    }

    @ViewBuilder
    private var folders: some View {
        if !sidebar.completeLabels {
            Text("Source folders are listed when “Complete lists (3.0)” is on in Settings ▸ Modules.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .padding(.horizontal, Spacing.small)
        } else if !sidebar.folderTrees.isEmpty {
            let sources = ArchiveSidebarModel.flatFolders(sidebar.folderTrees)
            let total = sources.reduce(0) { $0 + $1.rows.count }
            Label("Source Folders (\(total))", systemImage: "folder.fill")
                .font(Typography.headline)
                .padding(.horizontal, Spacing.small)
                .padding(.top, Spacing.xSmall)
                .help(ArchiveSidebarModel.occurrenceCountsNote)
                .accessibilityHint(ArchiveSidebarModel.occurrenceCountsNote)
            ForEach(Self.page(sources, reach: reach)) { source in
                Label(source.title, systemImage: "archivebox")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Spacing.small)
                ForEach(source.rows) { row in folderRow(row) }
            }
            if reach < total {
                Button {
                    reach += ArchiveSidebarModel.labelPage
                } label: {
                    Label("Show more (\(min(reach, total)) of \(total) folders)", systemImage: "ellipsis.circle")
                        .font(Typography.caption1)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16 + Spacing.small)
                .padding(.vertical, Spacing.xxSmall)
                .accessibilityIdentifier("sidebar.sourceFolders.more")
            }
        }
    }

    /// The first `reach` rows across the sources, sources kept whole in order.
    static func page(_ sources: [ArchiveSidebarModel.FlatFolderSource], reach: Int) -> [ArchiveSidebarModel.FlatFolderSource] {
        var left = reach
        var out: [ArchiveSidebarModel.FlatFolderSource] = []
        for source in sources where left > 0 {
            let rows = Array(source.rows.prefix(left))
            left -= rows.count
            out.append(.init(sourceID: source.sourceID, title: source.title, rows: rows))
        }
        return out
    }

    private func folderRow(_ row: ArchiveSidebarModel.FlatFolderRow) -> some View {
        let selection = ParsedEmailListViewModel.SourceFolderSelection(id: row.node.folderID, name: row.node.name)
        let isSelected = model.reviewStateFilter != .trashed && model.selectedSourceFolder == selection
        return Button {
            // Gate 1 follow-up 2026-11-18: a source folder is a place; choosing
            // it leaves the Trash (it was applied underneath the Trash view).
            model.leaveTrashForSidebarPlace()
            model.selectedSourceFolder = isSelected ? nil : selection
        } label: {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: row.isEmptyFolder ? "folder.badge.minus" : "folder")
                    .foregroundColor(AppColors.secondary)
                    .accessibilityHidden(true)
                Text(row.node.name)
                    .font(Typography.callout)
                    .lineLimit(1)
                Spacer()
                Text(row.node.messageCount.formatted())
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.leading, CGFloat(row.depth * 16) + Spacing.small + 8)
            .padding(.trailing, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
            .background(isSelected ? AppColors.primary.opacity(0.1) : Color.clear)
            .cornerRadius(CornerRadius.small)
            // The whole row is the target: a plain button answers only where
            // something is drawn, so a click in the gap between the name and
            // the count (the row's middle) chose nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.node.path)
        .accessibilityLabel(Text(verbatim: CountPhrase.row(row.node.name, messages: row.node.messageCount)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.sourceFolder")
    }
}

/// Gate 1 walk 2026-11-18: what an empty list says. On iPad a folder or Trash
/// with nothing in it left a blank pane (only a search said anything); on
/// iPhone a search with no hits said "Try widening the date range, selecting
/// more senders…" although no such filter was set. The empty state names the
/// place that is empty; a search's own notice (above the list) says what
/// was searched, so its empty state adds no advice.
enum ListEmptyState: Equatable {
    case trash
    case folder(String)
    case search
    case filters

    static func of(searchText: String, inTrash: Bool, folderName: String?) -> ListEmptyState {
        if inTrash { return .trash }
        if let folderName, !folderName.isEmpty { return .folder(folderName) }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .search }
        return .filters
    }

    var title: String {
        switch self {
        case .trash: return String(localized: "No messages in \(String(localized: "Trash"))")
        case .folder(let name): return String(localized: "No messages in \(name)")
        case .search, .filters: return String(localized: "No matching emails")
        }
    }

    /// The advice line; only the date / sender / reply-count filters have any.
    var message: String? {
        guard self == .filters else { return nil }
        return String(localized: "No emails match your current filters. Try widening the date range, selecting more senders, or reducing the minimum reply count.")
    }
}
