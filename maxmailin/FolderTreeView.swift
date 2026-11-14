@testable import ArchiveCore
import SwiftUI

struct FolderNode: Identifiable {
    var id: String { filterValue.isEmpty ? name : filterValue }
    let name: String
    let icon: String
    var children: [FolderNode]
    var emailCount: Int
    var filterValue: String
}

/// Part G7 + v1 parity: self-loading folder tree with ARCHIVE-WIDE counts.
/// v1.0 computed every folder bucket over the whole corpus (it held all
/// emails in memory); v2 reproduces the same tree — Inbox / Sent /
/// Has Attachments / Labels / Source Files with exact totals — via SQL
/// aggregates (GROUP BY over indexed tables), so counts stay exact and
/// memory stays bounded at any archive size. No injected corpus.
struct FolderTreeView: View {
    @Binding var selectedFolder: String?

    @State private var archiveTotal = 0
    @State private var typeCounts: [String: Int] = [:]
    @State private var attachmentTotal = 0
    @State private var labelBuckets: [AggregateBucket] = []
    /// CAP-03: every label is reachable — the total is shown and the list
    /// grows a page at a time; nothing is cut at a constant.
    @State private var labelTotal = 0
    @State private var sourceBuckets: [AggregateBucket] = []
    /// 3.1 R2: recovered mail by kind (empty when recovery is off or nothing was found).
    @State private var recovery = RecoveryCounts()
    @State private var isLoaded = false

    /// Labels load this many at a time, busiest first (a page size, not a cap).
    static let labelPage = 200

    /// Operator-safe value: multiword labels/filenames must be quoted or the
    /// search parser splits them ("tag:Boxbe Waiting List" → tag:Boxbe + text).
    private static func operatorValue(_ v: String) -> String {
        v.contains(" ") ? "\"\(v)\"" : v
    }

    private struct FlatRow: Identifiable {
        var id: String { "\(node.id)-\(depth)" }
        let node: FolderNode
        let depth: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Label("Folders", systemImage: "folder.fill")
                .font(Typography.headline)
                .padding(.horizontal, Spacing.small)

            let rows = flattenTree(buildTree())

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selectedFolder = nil
                    } label: {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "tray.fill")
                                .foregroundColor(AppColors.primary)
                                .accessibilityHidden(true)
                            Text("All Emails")
                                .font(Typography.callout)
                            Spacer()
                            Text("\(archiveTotal)")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                                .contentTransition(.numericText())
                                .adaptiveAnimation(archiveTotal)
                        }
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xxSmall)
                        .background(selectedFolder == nil ? AppColors.primary.opacity(0.1) : Color.clear)
                        .cornerRadius(CornerRadius.small)
                    }
                    .buttonStyle(.plain)
                    .help("Show every email in the archive")
                    .accessibilityLabel("All Emails, \(archiveTotal)")
                    .accessibilityAddTraits(selectedFolder == nil ? .isSelected : [])

                    ForEach(rows) { row in
                        Button {
                            if !row.node.filterValue.isEmpty {
                                selectedFolder = row.node.filterValue
                            }
                        } label: {
                            HStack(spacing: Spacing.xSmall) {
                                Image(systemName: row.node.icon)
                                    .foregroundColor(folderColor(for: row.node.name))
                                    .accessibilityHidden(true)
                                Text(row.node.name)
                                    .font(Typography.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(row.node.emailCount)")
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                                    .contentTransition(.numericText())
                                    .adaptiveAnimation(row.node.emailCount)
                            }
                            .padding(.leading, CGFloat(row.depth * 16) + Spacing.small)
                            .padding(.trailing, Spacing.small)
                            .padding(.vertical, Spacing.xxSmall)
                            .background(selectedFolder == row.node.filterValue ? AppColors.primary.opacity(0.1) : Color.clear)
                            .cornerRadius(CornerRadius.small)
                        }
                        .buttonStyle(.plain)
                        .help(row.node.filterValue.isEmpty
                              ? "\(row.node.name) — \(row.node.emailCount) emails"
                              : "Show only: \(row.node.name)")
                        .accessibilityLabel("\(row.node.name), \(row.node.emailCount) emails")
                        .accessibilityAddTraits(selectedFolder == row.node.filterValue ? .isSelected : [])
                    }
                    if labelBuckets.count < labelTotal {
                        Button {
                            Task { @MainActor in await loadMoreLabels() }
                        } label: {
                            Label("Show more (\(labelBuckets.count) of \(labelTotal) labels)", systemImage: "ellipsis.circle")
                                .font(Typography.caption1)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16 + Spacing.small)
                        .padding(.vertical, Spacing.xxSmall)
                        .help("Lists the next \(Self.labelPage) labels, busiest first. Every label in the archive can be reached this way.")
                        .accessibilityIdentifier("folderTree.moreLabels")
                    }
                }
            }
        }
        .task {
            guard !isLoaded else { return }
            await reload()
            isLoaded = true
        }
        // The fidelity backfill repairs legacy rows' message type / labels /
        // attachments after launch, and imports add rows — reload the exact
        // aggregates when either lands so the tree updates without a restart.
        .onReceive(NotificationCenter.default.publisher(for: .fidelityBackfillCompleted)) { _ in
            Task { @MainActor in await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parsingFinished)) { _ in
            Task { @MainActor in await reload() }
        }
        // IPAD-05: a Move to Trash / Restore (duplicate removal included)
        // changes every count here; without this they stayed at the old total.
        .onReceive(NotificationCenter.default.publisher(for: .archiveTrashChanged)) { _ in
            Task { @MainActor in await reload() }
        }
    }

    @MainActor
    private func reload() async {
        let archive = ArchiveDataService.shared
        archiveTotal = (try? await archive.count()) ?? 0
        let store = SQLiteEmailStore.shared
        // IPAD-05: the same trash-excluding counts as the list header — the
        // per-type GROUP BY and the attachment count read every stored row, so
        // a duplicate moved to the Trash left "Inbox 51" beside "50 Emails".
        var received = EmailQuery.all; received.messageType = "received"
        var sent = EmailQuery.all; sent.messageType = "sent"
        var withAttachments = EmailQuery.all; withAttachments.hasAttachments = true
        typeCounts = ["received": (try? await archive.count(query: received)) ?? 0,
                      "sent": (try? await archive.count(query: sent)) ?? 0]
        attachmentTotal = (try? await archive.count(query: withAttachments)) ?? 0
        // CAP-03: the total is always known; the list keeps what was expanded.
        labelTotal = (try? await store.parserTagTotal()) ?? 0
        labelBuckets = (try? await store.parserTagCounts(matching: nil, offset: 0, limit: max(Self.labelPage, labelBuckets.count))) ?? []
        // One bucket per imported file: bounded by the import history, never by a constant.
        sourceBuckets = (try? await store.sourceFileCounts(limit: Int(Int32.max))) ?? []
        recovery = RecoveryPolicy.isEnabled && TierAccess.allows(.recovery)
            ? ((try? await store.recoveryCounts()) ?? RecoveryCounts()) : RecoveryCounts()
    }

    @MainActor
    private func loadMoreLabels() async {
        let next = (try? await SQLiteEmailStore.shared.parserTagCounts(matching: nil, offset: labelBuckets.count, limit: Self.labelPage)) ?? []
        labelBuckets.append(contentsOf: next)
    }

    private func flattenTree(_ nodes: [FolderNode], depth: Int = 0) -> [FlatRow] {
        var result: [FlatRow] = []
        for node in nodes {
            result.append(FlatRow(node: node, depth: depth))
            result.append(contentsOf: flattenTree(node.children, depth: depth + 1))
        }
        return result
    }

    private func folderColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("inbox") || lower.contains("received") { return .blue }
        if lower.contains("sent") { return .green }
        if lower.contains("draft") { return .orange }
        if lower.contains("trash") || lower.contains("deleted") { return .red }
        if lower.contains("spam") || lower.contains("junk") { return .yellow }
        if lower.contains("archive") { return .purple }
        return AppColors.secondary
    }

    /// v1's folder buckets, from exact archive-wide aggregates. Empty
    /// buckets are hidden — identical to v1.0's behavior.
    private func buildTree() -> [FolderNode] {
        var nodes: [FolderNode] = []

        let received = typeCounts["received"] ?? 0
        let sent = typeCounts["sent"] ?? 0
        if received > 0 {
            nodes.append(FolderNode(name: String(localized: "Inbox"), icon: "tray.fill", children: [], emailCount: received, filterValue: "type:received"))
        }
        if sent > 0 {
            nodes.append(FolderNode(name: String(localized: "Sent"), icon: "paperplane.fill", children: [], emailCount: sent, filterValue: "type:sent"))
        }

        if attachmentTotal > 0 {
            nodes.append(FolderNode(name: String(localized: "Has Attachments"), icon: "paperclip", children: [], emailCount: attachmentTotal, filterValue: "has:attachment"))
        }

        if !labelBuckets.isEmpty {
            let labelChildren = labelBuckets.map {
                FolderNode(name: $0.value, icon: "tag.fill", children: [], emailCount: $0.count, filterValue: "tag:\(Self.operatorValue($0.value))")
            }
            // v1 showed the label-application total on the parent row
            // (labels overlap, so this can exceed the email count).
            nodes.append(FolderNode(name: String(localized: "Labels (\(labelTotal))"), icon: "tag.fill", children: labelChildren,
                                    emailCount: labelChildren.reduce(0) { $0 + $1.emailCount }, filterValue: ""))
        }

        // 3.1 R2: Recovered ▸ one row per kind, like Intella's <RECOVERED> /
        // <ORPHAN ITEMS>, but by how each email was found.
        if recovery.recovered > 0 {
            let kinds: [(RecoveryState, String, String)] = [
                (.deletedFolder, String(localized: "In deleted folders"), "trash"),
                (.flaggedDeleted, String(localized: "Flagged deleted"), "flag.slash"),
                (.unpurged, String(localized: "Unpurged"), "arrow.uturn.backward.circle"),
                (.orphan, String(localized: "Orphaned"), "questionmark.folder"),
                (.carved, String(localized: "Carved"), "scissors"),
                (.deletionStub, String(localized: "Deletion stubs"), "doc.badge.ellipsis"),
            ]
            let children = kinds.compactMap { kind -> FolderNode? in
                let n = recovery[kind.0]
                return n > 0 ? FolderNode(name: kind.1, icon: kind.2, children: [], emailCount: n,
                                          filterValue: "recovery:\(kind.0.rawValue)") : nil
            }
            nodes.append(FolderNode(name: String(localized: "Recovered"), icon: "arrow.counterclockwise.circle",
                                    children: children, emailCount: recovery.recovered, filterValue: "is:recovered"))
        }

        if sourceBuckets.count > 1 {
            let sourceChildren = sourceBuckets.map {
                FolderNode(name: $0.value, icon: "doc.fill", children: [], emailCount: $0.count, filterValue: "source:\(Self.operatorValue($0.value))")
            }
            nodes.append(FolderNode(name: String(localized: "Source Files"), icon: "folder.fill", children: sourceChildren,
                                    emailCount: archiveTotal, filterValue: ""))
        }

        return nodes
    }
}
