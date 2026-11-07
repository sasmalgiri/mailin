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
    @State private var children: [AttachmentChildRow] = []
    @State private var failure: String?

    var body: some View {
        Group {
            if !children.isEmpty {
                DisclosureGroup {
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
                                                                                 archive: .shared)?.message
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
        .task(id: "\(emailID.uuidString)#\(position)") {
            children = await ArchiveDataService.shared.attachmentChildren(emailID: emailID).filter { $0.position == position }
        }
    }

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
