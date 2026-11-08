//
//  AttachmentChildrenList.swift
//  maxmailin
//
//  Plan v4 §13.3 (9): what is INSIDE an attachment — the files of an
//  archive, the attachments of an attached message — listed under it in the
//  detail view with each file's state, and opened one by one. The list comes
//  from the indexing job's record (`attachment_children`), so it says what
//  was read and what was not; nothing here invents a page or a cell.
//

import SwiftUI
@testable import ArchiveCore

struct AttachmentChildrenList: View {
    let emailID: EmailID
    let position: Int
    var archive: ArchiveDataService = .shared
    @State private var children: [AttachmentChildRow] = []
    @State private var failure: String?
    /// IPAD-04: open on arrival, so the files inside are on screen without a
    /// tap (a long list starts closed; its count is in the label).
    @State private var isExpanded = true

    var body: some View {
        Group {
            if !children.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children, id: \.childIndex) { child in
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(child.path).font(Typography.caption1).lineLimit(2)
                                Text(Self.stateLabel(child.state) + (child.note.map { " — " + $0 } ?? ""))
                                    .font(Typography.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            // §13.3 (9): the text search reads for this file, with a find field.
                            AttachmentTextButton(emailID: emailID, ordinal: child.ordinal, filename: child.filename, childPath: child.path, attachmentPosition: position)
                            Button {
                                Task { @MainActor in
                                    failure = await EvidenceAttachmentOpener.open(emailID: emailID, ordinal: position, childPath: child.path,
                                                                                 archive: archive)?.message
                                }
                            } label: { Label(String(localized: "Open"), systemImage: "arrow.up.forward.square") }
                            .buttonStyle(.plain)
                            .font(Typography.caption1)
                            .help(String(localized: "Extract this file from the attachment and open it"))
                            .accessibilityLabel(String(localized: "Open \(child.filename)"))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let failure {
                        Text(failure).font(Typography.caption2).foregroundStyle(.orange)
                    }
                } label: {
                    Label(String(localized: "Contents (\(children.count))"), systemImage: "list.bullet.indent")
                        .font(Typography.caption1)
                }
                .accessibilityIdentifier("attachment.children.\(position)")
            }
        }
        .task(id: "\(emailID.uuidString)#\(position)") { await load() }
        // IPAD-04: the indexing job records the files inside after import; a
        // message opened before it reached this one fills in when it does.
        .onReceive(NotificationCenter.default.publisher(for: .attachmentIndexUpdated)) { _ in
            Task { @MainActor in await load() }
        }
    }

    private func load() async {
        let rows = await Self.rows(emailID: emailID, position: position, archive: archive)
        if rows.map(\.childIndex) != children.map(\.childIndex) {
            isExpanded = Self.startsExpanded(count: rows.count)
        }
        children = rows
    }

    /// The files inside attachment `position` of one message, as recorded.
    static func rows(emailID: EmailID, position: Int, archive: ArchiveDataService) async -> [AttachmentChildRow] {
        await archive.attachmentChildren(emailID: emailID).filter { $0.position == position }
    }

    /// Open when the list is short enough to read at a glance.
    static func startsExpanded(count: Int) -> Bool { count <= 12 }

    /// The recorded state, in the person's words.
    static func stateLabel(_ state: String) -> String {
        switch ChildDocument.State(rawValue: state) {
        case .extracted: return String(localized: "read for search")
        case .noText: return String(localized: "no text found")
        case .partial: return String(localized: "partly read")
        case .unsupported: return String(localized: "not read")
        case .locked: return String(localized: "locked")
        case .failed: return String(localized: "could not be read")
        case .none: return state
        }
    }
}
