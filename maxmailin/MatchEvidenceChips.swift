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
    /// R7: the row's message; with it, a chip whose match the index located
    /// offers Show text opened at that match.
    var emailID: UUID? = nil
    /// FIND-05: when set, a chip that names an attachment is a button that
    /// opens that attachment (by its ordinal in the message) or — §13.3 (9) —
    /// the file inside it named by the child path.
    var onOpenAttachment: ((Int, String?) -> Void)? = nil
    @Environment(\.backgroundProminence) private var prominence
    @State private var textTarget: EvidenceText?

    /// What Show text opens for one chip: the document and the matched span.
    struct EvidenceText: Identifiable, Equatable {
        let id = UUID()
        /// The document's ordinal in the chunk index (a child's is its child ordinal).
        let ordinal: Int
        /// The top-level attachment's position (Open original).
        let position: Int
        let filename: String
        let childPath: String?
        let target: ExtractedTextTarget
    }

    /// R7: the Show text target for a chip — nil unless the chip names an
    /// attachment (or a file inside one) and the index located the match.
    static func evidenceText(_ item: MatchEvidence) -> EvidenceText? {
        guard let anchor = item.anchor, let position = attachmentOrdinal(item.location) else { return nil }
        return EvidenceText(ordinal: anchor.ordinal, position: position, filename: attachmentFilename(item.location) ?? "",
                            childPath: childPath(item.location), target: ExtractedTextTarget(anchor))
    }

    var body: some View {
        if !evidence.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                        if let onOpenAttachment, let ordinal = Self.attachmentOrdinal(item.location) {
                            Button { onOpenAttachment(ordinal, Self.childPath(item.location)) } label: { chip(item) }
                                .buttonStyle(.plain)
                                .help(String(localized: "Open \(Self.attachmentFilename(item.location) ?? "")") + " · " + item.condition)
                                .accessibilityHint(String(localized: "Opens this attachment"))
                                .accessibilityIdentifier("search.matchEvidence.open.\(ordinal)")
                        } else {
                            chip(item).help(item.condition)
                        }
                        if emailID != nil, let text = Self.evidenceText(item) {
                            Button { textTarget = text } label: { Image(systemName: "text.magnifyingglass").font(.caption2) }
                                .buttonStyle(.plain)
                                .help(String(localized: "Show the text at this match"))
                                .accessibilityLabel(String(localized: "Show the text at this match"))
                                .accessibilityIdentifier("search.matchEvidence.showText.\(text.ordinal)")
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
            .sheet(item: $textTarget) { text in
                if let emailID {
                    ExtractedTextSheet(emailID: emailID, ordinal: text.ordinal, filename: text.filename, childPath: text.childPath,
                                       attachmentPosition: text.position, target: text.target)
                }
            }
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
        case .childText(let ordinal, _, _, _): return ordinal
        default: return nil
        }
    }

    /// §13.3 (9): the file inside the attachment, when the chip names one.
    static func childPath(_ location: MatchEvidence.Location) -> String? {
        if case .childText(_, _, let path, _) = location { return path }
        return nil
    }

    static func attachmentFilename(_ location: MatchEvidence.Location) -> String? {
        switch location {
        case .attachmentText(_, let filename, _, _): return filename
        case .speech(_, let filename, _): return filename
        case .childText(_, _, let path, _): return path.components(separatedBy: " › ").last ?? path
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
        case .childText(_, _, let path, let context):
            var text = String(localized: "Inside attachment: \(path)")
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
        case .childText: return "doc.on.doc"
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
