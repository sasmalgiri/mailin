import SwiftUI

struct FolderNode: Identifiable {
    var id: String { filterValue }
    let name: String
    let icon: String
    var children: [FolderNode]
    var emailCount: Int
    var filterValue: String
}

/// Part G7: self-loading folder tree. The "All Emails" total is the store
/// COUNT (archive truth); the folder buckets (sent/received, attachments,
/// labels, source files) are computed over a bounded most-recent working set
/// streamed from the store — tags/source-file metadata have no SQL column yet,
/// so their counts are working-set-scoped, exactly like the preview array this
/// view used to receive. No injected corpus.
struct FolderTreeView: View {
    @Binding var selectedFolder: String?

    @State private var archiveTotal = 0
    @State private var workingSet: [MBOXParser.RawEmail] = []
    @State private var isLoaded = false

    private struct FlatRow: Identifiable {
        var id: String { "\(node.filterValue)-\(depth)" }
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
                        }
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xxSmall)
                        .background(selectedFolder == nil ? AppColors.primary.opacity(0.1) : Color.clear)
                        .cornerRadius(CornerRadius.small)
                    }
                    .buttonStyle(.plain)
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
                            }
                            .padding(.leading, CGFloat(row.depth * 16) + Spacing.small)
                            .padding(.trailing, Spacing.small)
                            .padding(.vertical, Spacing.xxSmall)
                            .background(selectedFolder == row.node.filterValue ? AppColors.primary.opacity(0.1) : Color.clear)
                            .cornerRadius(CornerRadius.small)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.node.name), \(row.node.emailCount) emails")
                        .accessibilityAddTraits(selectedFolder == row.node.filterValue ? .isSelected : [])
                    }
                }
            }
        }
        .task {
            guard !isLoaded else { return }
            archiveTotal = (try? await ArchiveDataService.shared.count()) ?? 0
            workingSet = await ArchiveDataService.shared.workingSet(query: .all)
            isLoaded = true
        }
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

    /// Folder buckets over the bounded working set (see type comment).
    private func buildTree() -> [FolderNode] {
        var nodes: [FolderNode] = []
        let emails = workingSet

        let sent = emails.filter { $0.messageType == "sent" }
        let received = emails.filter { $0.messageType == "received" }
        if !received.isEmpty {
            nodes.append(FolderNode(name: "Inbox", icon: "tray.fill", children: [], emailCount: received.count, filterValue: "type:received"))
        }
        if !sent.isEmpty {
            nodes.append(FolderNode(name: "Sent", icon: "paperplane.fill", children: [], emailCount: sent.count, filterValue: "type:sent"))
        }

        let withAttachments = emails.filter { !$0.attachments.isEmpty }
        if !withAttachments.isEmpty {
            nodes.append(FolderNode(name: "Has Attachments", icon: "paperclip", children: [], emailCount: withAttachments.count, filterValue: "has:attachment"))
        }

        let tagGroups = Dictionary(grouping: emails.flatMap { email in
            email.tags.map { (tag: $0, email: email) }
        }, by: { $0.tag })

        var labelChildren: [FolderNode] = []
        for (tag, items) in tagGroups.sorted(by: { $0.value.count > $1.value.count }).prefix(20) {
            labelChildren.append(FolderNode(name: tag, icon: "tag.fill", children: [], emailCount: items.count, filterValue: "tag:\(tag)"))
        }
        if !labelChildren.isEmpty {
            nodes.append(FolderNode(name: "Labels", icon: "tag.fill", children: labelChildren, emailCount: labelChildren.reduce(0) { $0 + $1.emailCount }, filterValue: ""))
        }

        let sourceFiles = Dictionary(grouping: emails, by: { $0.headers["sourceFile"] ?? "Unknown" })
        if sourceFiles.count > 1 {
            var sourceChildren: [FolderNode] = []
            for (file, items) in sourceFiles.sorted(by: { $0.key < $1.key }) {
                sourceChildren.append(FolderNode(name: file, icon: "doc.fill", children: [], emailCount: items.count, filterValue: "source:\(file)"))
            }
            nodes.append(FolderNode(name: "Source Files", icon: "folder.fill", children: sourceChildren, emailCount: emails.count, filterValue: ""))
        }

        return nodes
    }
}
