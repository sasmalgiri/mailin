@testable import ArchiveCore
//
//  MatchEvidenceChips.swift
//  maxmailin
//
//  Five jobs FIND-05: the "matched in" strip built from evidence the index
//  returned for THIS row — the place (subject, sender, body, an attachment
//  by name with its sheet/slide/header), an excerpt with the matched words
//  in bold, and a plain "evidence unavailable" when the text is not indexed
//  yet. Excerpts are stored plain text; nothing here renders HTML.
//

import SwiftUI

struct MatchEvidenceChips: View {
    let evidence: [MatchEvidence]
    /// FIND-05: when set, a chip that names an attachment is a button that
    /// opens that attachment (by its ordinal in the message).
    var onOpenAttachment: ((Int) -> Void)? = nil
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if !evidence.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                        if let onOpenAttachment, let ordinal = Self.attachmentOrdinal(item.location) {
                            Button { onOpenAttachment(ordinal) } label: { chip(item) }
                                .buttonStyle(.plain)
                                .help(String(localized: "Open \(Self.attachmentFilename(item.location) ?? "")") + " · " + item.condition)
                                .accessibilityHint(String(localized: "Opens this attachment"))
                                .accessibilityIdentifier("search.matchEvidence.open.\(ordinal)")
                        } else {
                            chip(item).help(item.condition)
                        }
                    }
                }
                if let excerpt = evidence.compactMap(\.excerpt).first {
                    Text(Self.attributed(excerpt))
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(prominence == .increased ? Color.white : Color.primary.opacity(0.8))
                        .accessibilityLabel(String(localized: "Matched text: \(excerpt.text)"))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("search.matchEvidence")
        }
    }

    private func chip(_ item: MatchEvidence) -> some View {
        Label(Self.label(item.location), systemImage: Self.symbol(item.location))
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(chipForeground(item))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(prominence == .increased ? Color.white.opacity(0.22) : Color.secondary.opacity(0.12), in: Capsule())
    }

    /// The attachment a chip points at, when it points at one.
    static func attachmentOrdinal(_ location: MatchEvidence.Location) -> Int? {
        switch location {
        case .attachmentText(let ordinal, _, _, _): return ordinal
        case .speech(let ordinal, _, _): return ordinal
        default: return nil
        }
    }

    static func attachmentFilename(_ location: MatchEvidence.Location) -> String? {
        switch location {
        case .attachmentText(_, let filename, _, _): return filename
        case .speech(_, let filename, _): return filename
        default: return nil
        }
    }

    private func chipForeground(_ item: MatchEvidence) -> Color {
        if case .unavailable = item.location { return .orange }
        return prominence == .increased ? Color.white : Color.primary.opacity(0.75)
    }

    static func label(_ location: MatchEvidence.Location) -> String {
        switch location {
        case .subject: return String(localized: "Subject")
        case .sender: return String(localized: "Sender")
        case .recipients: return String(localized: "Recipients")
        case .body: return String(localized: "Message body")
        case .attachmentName: return String(localized: "Attachment name")
        case .attachmentText(_, let filename, let ocr, let context):
            var text = ocr ? String(localized: "Recognised text: \(filename)") : String(localized: "Attachment text: \(filename)")
            if let context, !context.isEmpty { text += " · " + context }
            return text
        case .speech(_, let filename, let context):
            var text = String(localized: "Recognised speech: \(filename)")
            if let context, !context.isEmpty { text += " · " + context }
            return text
        case .metadata: return String(localized: "Matches filters")
        case .unavailable: return String(localized: "Evidence unavailable — text not indexed yet")
        }
    }

    static func symbol(_ location: MatchEvidence.Location) -> String {
        switch location {
        case .subject: return "textformat"
        case .sender: return "person"
        case .recipients: return "person.2"
        case .body: return "text.alignleft"
        case .attachmentName: return "paperclip"
        case .attachmentText(_, _, let ocr, _): return ocr ? "text.viewfinder" : "doc.text.magnifyingglass"
        case .speech: return "waveform"
        case .metadata: return "line.3.horizontal.decrease"
        case .unavailable: return "questionmark.circle"
        }
    }

    /// The excerpt with its marks in bold — offsets from the index, no markup parsing.
    static func attributed(_ excerpt: MatchEvidence.Excerpt) -> AttributedString {
        var result = AttributedString(excerpt.text)
        let ns = excerpt.text as NSString
        for mark in excerpt.marks where mark.lowerBound >= 0 && mark.upperBound <= ns.length {
            let swiftRange = Range(NSRange(location: mark.lowerBound, length: mark.count), in: excerpt.text)
            guard let swiftRange, let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            result[lower..<upper].font = .caption.bold()
        }
        return result
    }
}
