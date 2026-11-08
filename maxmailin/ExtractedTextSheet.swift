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
//  R7: opened from a search's evidence it starts at the matched span with the
//  query in the find field; the text is read a few chunks at a time
//  (`ExtractedTextViewerModel`), and finding uses the search's phrase rule.
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
            // R7: one EXISTS on the document row — no text is read to decide this.
            hasText = await ArchiveDataService.shared.attachmentDocumentHasText(emailID: emailID, ordinal: ordinal)
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
    @StateObject private var viewer: ExtractedTextViewerModel
    @State private var openFailure: String?

    /// R7: `target` (from the search's evidence) opens the text at the match.
    init(emailID: UUID, ordinal: Int, filename: String, childPath: String? = nil, attachmentPosition: Int,
         target: ExtractedTextTarget? = nil, archive: ArchiveDataService = .shared) {
        self.emailID = emailID
        self.ordinal = ordinal
        self.filename = filename
        self.childPath = childPath
        self.attachmentPosition = attachmentPosition
        _viewer = StateObject(wrappedValue: ExtractedTextViewerModel(
            source: StoredExtractedTextSource(store: archive.sqliteStore, emailID: emailID, ordinal: ordinal), target: target))
    }

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
            HStack(spacing: Spacing.small) {
                TextField(String(localized: "Find in this text"), text: $viewer.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await viewer.next() } }
                    .accessibilityIdentifier("attachment.text.find")
                Button { Task { await viewer.previous() } } label: { Image(systemName: "chevron.up") }
                    .help(String(localized: "Previous match"))
                    .accessibilityLabel(String(localized: "Previous match"))
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled((viewer.total ?? 0) == 0)
                    .accessibilityIdentifier("attachment.text.previous")
                Button { Task { await viewer.next() } } label: { Image(systemName: "chevron.down") }
                    .help(String(localized: "Next match"))
                    .accessibilityLabel(String(localized: "Next match"))
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled((viewer.total ?? 0) == 0)
                    .accessibilityIdentifier("attachment.text.next")
            }
            if let outline = viewer.outline {
                Text(statusLine(outline))
                    .font(Typography.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("attachment.text.count")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if viewer.canShowEarlier {
                                Button(String(localized: "Earlier text")) { Task { await viewer.showEarlier() } }
                                    .font(Typography.caption1)
                                    .accessibilityIdentifier("attachment.text.earlier")
                            }
                            ForEach(viewer.segments) { segment in
                                Text(segment.text)
                                    .font(Typography.caption1)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(segment.id)
                            }
                            if viewer.canShowLater {
                                Button(String(localized: "Later text")) { Task { await viewer.showLater() } }
                                    .font(Typography.caption1)
                                    .accessibilityIdentifier("attachment.text.later")
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.4))
                    .onChange(of: viewer.scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            } else if viewer.opened {
                Text(String(localized: "No extracted text is stored for this file.")).font(Typography.caption1).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if let openFailure { Text(openFailure).font(Typography.caption2).foregroundStyle(.orange) }
            HStack { Spacer(); Button(String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(Spacing.large)
        .frame(minWidth: 560, minHeight: 420)
        .task { await viewer.open() }
        .onChange(of: viewer.query) { _, _ in viewer.queryDidChange() }
    }

    /// "Match 3 of 41 · 1,204,331 characters · part 4 to 6 of 25".
    private func statusLine(_ outline: AttachmentDocumentOutline) -> String {
        let characters = outline.characters.formatted()
        var line: String
        if viewer.counting {
            line = String(localized: "Counting matches…")
        } else if viewer.countFailed {
            line = String(localized: "The matches could not be counted.")
        } else if let total = viewer.total, total > 0 {
            line = String(localized: "Match \(((viewer.current ?? 0) + 1).formatted()) of \(total.formatted()) · \(characters) characters")
        } else if !viewer.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line = String(localized: "No occurrence of “\(viewer.query)”")
        } else {
            line = String(localized: "\(0) occurrences · \(characters) characters")
        }
        if outline.chunkCount > 1, let window = viewer.window {
            line += " · " + String(localized: "part \(window.lowerBound + 1) to \(window.upperBound + 1) of \(outline.chunkCount)")
        }
        return line
    }

    /// Every occurrence of `query` in `text` under the search's phrase rule
    /// (FIND-08: a whitespace run is one space, never across a section
    /// boundary; ASCII letters fold case, as `mailin_phrase` does).
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        SectionBoundary.phraseRanges(of: query, in: text).compactMap { Range($0, in: text) }
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
