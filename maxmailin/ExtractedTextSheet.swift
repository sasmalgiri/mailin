@testable import ArchiveCore
//
//  ExtractedTextSheet.swift
//  maxmailin
//
//  Plan v4 §13.3 (9): what the search actually read. "Show text" on an
//  attachment or on a file inside it opens the extracted text exactly as it
//  is indexed — section labels ("[Sheet: Q3]", "[Slide 2]", "{deleted: …}")
//  included — with a find field that marks every occurrence, and an "Open
//  original" button that hands the real file to the system. Nothing here is
//  generated or summarised; it is the stored document text.
//

import SwiftUI

/// The "Show text" button for one attachment document or child document.
struct AttachmentTextButton: View {
    let emailID: UUID
    let ordinal: Int
    let filename: String
    var childPath: String? = nil
    var attachmentPosition: Int? = nil
    @State private var hasText = false
    @State private var showing = false

    var body: some View {
        Group {
            if hasText {
                Button { showing = true } label: { Label(String(localized: "Show text"), systemImage: "text.alignleft") }
                    .buttonStyle(.plain)
                    .font(Typography.caption1)
                    .foregroundStyle(Color.accentColor)
                    .help(String(localized: "The text search reads for this file, as it was extracted"))
                    .accessibilityIdentifier("attachment.showText.\(ordinal)")
                    .sheet(isPresented: $showing) {
                        ExtractedTextSheet(emailID: emailID, ordinal: ordinal, filename: filename, childPath: childPath,
                                           attachmentPosition: attachmentPosition ?? ordinal)
                    }
            }
        }
        .task(id: "\(emailID.uuidString)#\(ordinal)") {
            hasText = await ArchiveDataService.shared.attachmentDocumentText(emailID: emailID, ordinal: ordinal) != nil
        }
    }
}

struct ExtractedTextSheet: View {
    let emailID: UUID
    let ordinal: Int
    let filename: String
    var childPath: String? = nil
    let attachmentPosition: Int

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var query = ""
    @State private var openFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(childPath.map { String(localized: "Text inside \(filename): \($0)") } ?? String(localized: "Extracted text of \(filename)")).font(Typography.headline)
                    Text(String(localized: "Exactly what search reads for this file. Section labels in brackets name where each part came from."))
                        .font(Typography.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Open original")) {
                    Task { @MainActor in
                        openFailure = await EvidenceAttachmentOpener.open(emailID: emailID, ordinal: attachmentPosition, childPath: childPath, archive: .shared)?.message
                    }
                }
                .help(String(localized: "Open the file itself with the system"))
            }
            TextField(String(localized: "Find in this text"), text: $query)
                .textFieldStyle(.roundedBorder)
            if let text {
                let matches = Self.ranges(of: query, in: text)
                Text(matches.isEmpty && !query.isEmpty ? String(localized: "No occurrence of “\(query)”") : String(localized: "\(matches.count) occurrences · \(text.count.formatted()) characters"))
                    .font(Typography.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("attachment.text.count")
                ScrollView {
                    Text(Self.highlighted(text, ranges: matches))
                        .font(Typography.caption1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.quaternary.opacity(0.4))
            } else {
                Text(String(localized: "No extracted text is stored for this file.")).font(Typography.caption1).foregroundStyle(.secondary)
            }
            if let openFailure { Text(openFailure).font(Typography.caption2).foregroundStyle(.orange) }
            HStack { Spacer(); Button(String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(Spacing.large)
        .frame(minWidth: 560, minHeight: 420)
        .task { text = await ArchiveDataService.shared.attachmentDocumentText(emailID: emailID, ordinal: ordinal) }
    }

    /// Every case-insensitive, diacritic-insensitive occurrence of `query` in `text`.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            out.append(range)
            start = range.upperBound
        }
        return out
    }

    /// The text with every match marked (bold on a yellow background).
    static func highlighted(_ text: String, ranges: [Range<String.Index>]) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = .yellow.opacity(0.6)
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
