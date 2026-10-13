//
//  RecoveryBadgeView.swift
//  maxmailin
//
//  3.1 R12: in the email detail, a recovered email says how it was found and
//  shows the evidence (the header, flag, folder or byte offset). Live emails
//  show nothing. Hidden while Capability.v31Recovery is off.
//

import SwiftUI
@testable import ArchiveCore

struct RecoveryBadgeView: View {
    let emailID: UUID
    @State private var info: RecoveryInfo?

    var body: some View {
        Group {
            if let info {
                HStack(alignment: .top, spacing: Spacing.xSmall) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                        Text(Self.title(info.state))
                            .font(.subheadline.weight(.semibold))
                        Text(Self.evidenceLine(info))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if info.partial {
                            Text("Partly recovered: some parts of this email could not be read back.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Spacing.small)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: emailID) {
            guard RecoveryPolicy.isEnabled, TierAccess.allows(.recovery) else { info = nil; return }
            info = (try? await SQLiteEmailStore.shared.recovery(for: [emailID]))?[emailID]
        }
    }

    static func title(_ state: RecoveryState) -> String {
        switch state {
        case .live: return ""
        case .deletedFolder: return String(localized: "Recovered: found in a deleted-items folder")
        case .flaggedDeleted: return String(localized: "Recovered: marked deleted by the mail client")
        case .unpurged: return String(localized: "Recovered: deleted but not yet purged from the mailbox")
        case .orphan: return String(localized: "Recovered: no longer in any folder")
        case .carved: return String(localized: "Recovered: carved from raw bytes")
        case .deletionStub: return String(localized: "Deletion record only: the message itself is gone")
        }
    }

    /// "How: x-mozilla-status · Evidence: X-Mozilla-Status 0009 · Byte offset 1234".
    static func evidenceLine(_ info: RecoveryInfo) -> String {
        var parts = [String(localized: "How: \(info.method)")]
        if !info.evidence.isEmpty { parts.append(String(localized: "Evidence: \(info.evidence)")) }
        if let folder = info.folder, !info.evidence.contains(folder) {
            parts.append(String(localized: "Folder: \(folder)"))
        }
        if let offset = info.offset { parts.append(String(localized: "Byte offset \(offset)")) }
        return parts.joined(separator: " · ")
    }
}
