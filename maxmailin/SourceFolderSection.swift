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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(String(localized: "Trash")), \(sidebar.trashedCount) messages")
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
        let isSelected = model.selectedSourceFolder == selection
        return Button {
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
        }
        .buttonStyle(.plain)
        .help(row.node.path)
        .accessibilityLabel("\(row.node.name), \(row.node.messageCount) messages")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.sourceFolder")
    }
}
