@testable import ArchiveCore
//
//  AttachmentResumeView.swift
//  maxmailin
//
//  Audit b4b502f A10 / plan v4 §13.3 (10): an attachment whose reading
//  stopped at a per-run ceiling (a part over the size guard, the archive
//  budget, the nesting depth) says so and offers "Resume…". Each round
//  doubles the ceilings and opens one more level, for this attachment only,
//  and the record says which round read it. Nothing is hidden, nothing
//  unbounded: the person chooses each round.
//

import SwiftUI

struct AttachmentResumeView: View {
    let emailID: UUID
    let position: Int
    let filename: String
    @State private var row: AttachmentCoverageRow?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Group {
            if let current = row, Self.canResume(current) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "arrow.clockwise.circle").foregroundStyle(.secondary)
                        Text(String(localized: "Stopped at a per-run limit (round \(current.resumeRound))"))
                            .font(Typography.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button(working ? String(localized: "Resuming…") : String(localized: "Resume…")) { Task { await resume() } }
                            .buttonStyle(.plain)
                            .font(Typography.caption1)
                            .foregroundStyle(Color.accentColor)
                            .disabled(working)
                            .help(String(localized: "Read this file again with the limits doubled: \(ExtractionLimits.round(current.resumeRound + 1).summary)"))
                            .accessibilityIdentifier("attachment.resume.\(position)")
                    }
                    if let message {
                        Text(message).font(Typography.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("attachment.resume.outcome")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .task(id: "\(emailID.uuidString)#\(position)") { row = await AttachmentTextIndexJob.shared.coverageRow(emailID: emailID, position: position) }
    }

    /// Resumable: not fully read, and the recorded reason names one of the ceilings.
    static func canResume(_ row: AttachmentCoverageRow) -> Bool {
        (row.state == .partial || row.state == .unsupported) && ExtractionLimits.noteNamesALimit(row.note)
    }

    @MainActor
    private func resume() async {
        working = true
        defer { working = false }
        switch await AttachmentTextIndexJob.shared.resume(emailID: emailID, position: position) {
        case .unreadable(let why):
            message = String(localized: "\(filename) could not be read again: \(why)")
        case .resumed(let round, let state, let note, let limits):
            message = state.isSearchable && !ExtractionLimits.noteNamesALimit(note)
                ? String(localized: "Round \(round) (\(limits)) read \(filename) whole.")
                : String(localized: "Round \(round) (\(limits)) read more of \(filename); what is still not read is listed in its record.")
            row = await AttachmentTextIndexJob.shared.coverageRow(emailID: emailID, position: position)
        }
    }
}
