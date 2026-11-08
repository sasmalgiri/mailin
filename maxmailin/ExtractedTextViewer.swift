@testable import ArchiveCore
//
//  ExtractedTextViewer.swift
//  maxmailin
//
//  R7 (audit bf1a5b9): the model behind "Show text". It opens at the span
//  the search matched (document, chunk, offset — from the evidence), marks
//  every occurrence of the query, and Next / Previous step through all of
//  them. It never holds the whole text: a window of three chunks around the
//  one in view is loaded on demand, and the occurrences are known as a count
//  per chunk from one streaming pass in the store. Finding uses the search's
//  own phrase rule (FIND-08), so what the viewer finds is what search found.
//

import Foundation
import SwiftUI

/// Where Show text opens: the query and the matched span in the stored chunk.
struct ExtractedTextTarget: Equatable, Sendable {
    var query: String
    var chunk: Int
    /// UTF-16 offset and length in the chunk's stored text (boundaries included).
    var offset: Int
    var length: Int

    init(query: String, chunk: Int, offset: Int, length: Int) {
        self.query = query; self.chunk = chunk; self.offset = offset; self.length = length
    }

    init(_ anchor: MatchEvidence.Anchor) {
        self.init(query: anchor.query, chunk: anchor.chunk, offset: anchor.offset, length: anchor.length)
    }
}

/// What the viewer reads — a few chunks at a time, never the whole text.
protocol ExtractedTextSource: Sendable {
    func outline() async -> AttachmentDocumentOutline?
    func chunks(_ range: ClosedRange<Int>, kind: SearchDocKind) async -> [Int: String]
    func matchCounts(_ literal: String, kind: SearchDocKind) async -> [Int]?
}

/// The archive's stored text of one attachment document (or file inside one).
struct StoredExtractedTextSource: ExtractedTextSource {
    let store: SQLiteEmailStore?
    let emailID: UUID
    let ordinal: Int

    func outline() async -> AttachmentDocumentOutline? {
        try? await store?.attachmentDocumentOutline(emailID: emailID, ordinal: ordinal)
    }
    func chunks(_ range: ClosedRange<Int>, kind: SearchDocKind) async -> [Int: String] {
        (try? await store?.attachmentDocumentChunks(emailID: emailID, ordinal: ordinal, kind: kind, range: range)) ?? [:]
    }
    func matchCounts(_ literal: String, kind: SearchDocKind) async -> [Int]? {
        guard let store else { return nil }
        do { return try await store.attachmentDocumentMatchCounts(emailID: emailID, ordinal: ordinal, kind: kind, literal: literal) } catch { return nil }
    }
}

@MainActor
final class ExtractedTextViewerModel: ObservableObject {
    /// Chunks loaded either side of the one in view.
    static let windowRadius = 1
    /// Display blocks of about this many UTF-16 units, cut at a line break when there is one.
    static let segmentUnits = 2_000

    struct Segment: Identifiable, Equatable {
        let id: String
        let chunk: Int
        let text: AttributedString
    }

    @Published var query: String
    @Published private(set) var outline: AttachmentDocumentOutline?
    @Published private(set) var opened = false
    /// Occurrences starting in each chunk; nil while counting, or when the count failed.
    @Published private(set) var counts: [Int]?
    @Published private(set) var counting = false
    @Published private(set) var countFailed = false
    /// The occurrence in view (0-based, over the whole document).
    @Published private(set) var current: Int?
    @Published private(set) var window: ClosedRange<Int>?
    @Published private(set) var segments: [Segment] = []
    /// The segment to scroll to.
    @Published private(set) var scrollTarget: String?

    let target: ExtractedTextTarget?
    private let source: any ExtractedTextSource
    /// The raw text of the chunks in the window, by chunk number.
    private(set) var loadedChunks: [Int: String] = [:]
    /// Every range of chunks read from the store, in order (what the viewer cost).
    private(set) var requestedRanges: [ClosedRange<Int>] = []
    /// The span in view, in raw chunk offsets.
    private var focus: (chunk: Int, range: NSRange)?
    private var countedQuery: String?
    private var recountTask: Task<Void, Never>?

    init(source: any ExtractedTextSource, target: ExtractedTextTarget?) {
        self.source = source
        self.target = target
        self.query = target?.query ?? ""
    }

    var total: Int? { counts?.reduce(0, +) }
    var chunkCount: Int { outline?.chunkCount ?? 0 }

    // MARK: Opening

    func open() async {
        outline = await source.outline()
        opened = true
        guard let outline, outline.chunkCount > 0 else { return }
        let start = min(max(target?.chunk ?? 0, 0), outline.chunkCount - 1)
        await ensureWindow(around: start)
        if let target, target.chunk == start {
            focus = (start, NSRange(location: target.offset, length: target.length))
        }
        rebuildSegments()
        await recount(fromTarget: true)
    }

    /// The query was edited: count again after a pause in typing.
    func queryDidChange() {
        recountTask?.cancel()
        recountTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.recount(fromTarget: false)
        }
    }

    /// Counts the occurrences of the query over the whole document, then goes
    /// to the match at the search's span (on opening) or to the first one.
    func recount(fromTarget: Bool) async {
        let literal = query
        guard literal != countedQuery else { return }
        countedQuery = literal
        current = nil
        guard let outline else { return }
        guard SectionBoundary.phraseRegex(literal) != nil else {
            counts = []   // nothing to find
            counting = false; countFailed = false
            rebuildSegments()
            return
        }
        counting = true
        countFailed = false
        rebuildSegments()
        let result = await source.matchCounts(literal, kind: outline.kind)
        guard literal == query else { return }   // superseded by a newer query
        counting = false
        counts = result
        countFailed = result == nil
        guard let total, total > 0 else { rebuildSegments(); return }
        if fromTarget, let target, let index = await matchIndex(atOrAfter: target) {
            await go(to: index)
        } else {
            await go(to: 0)
        }
    }

    /// The document-wide index of the first occurrence at or after the target span.
    private func matchIndex(atOrAfter target: ExtractedTextTarget) async -> Int? {
        guard let counts, counts.indices.contains(target.chunk) else { return nil }
        let before = counts[..<target.chunk].reduce(0, +)
        await ensureWindow(around: target.chunk)
        let starting = matches(inChunk: target.chunk)?.starting ?? []
        if let local = starting.firstIndex(where: { $0.location + $0.length > target.offset }) { return before + local }
        let after = before + counts[target.chunk]
        return after < (total ?? 0) ? after : nil
    }

    // MARK: Next / Previous

    func next() async { await go(to: (current ?? -1) + 1) }
    func previous() async { await go(to: (current ?? 0) - 1) }

    func go(to index: Int) async {
        guard let counts, let total, total > 0 else { return }
        let i = ((index % total) + total) % total
        var remaining = i
        var chunk = 0
        while chunk < counts.count, remaining >= counts[chunk] { remaining -= counts[chunk]; chunk += 1 }
        guard chunk < counts.count else { return }
        await ensureWindow(around: chunk)
        let starting = matches(inChunk: chunk)?.starting ?? []
        current = i
        if starting.indices.contains(remaining) { focus = (chunk, starting[remaining]) }
        rebuildSegments()
    }

    // MARK: Paging

    var canShowEarlier: Bool { (window?.lowerBound ?? 0) > 0 }
    var canShowLater: Bool { (window?.upperBound ?? 0) < chunkCount - 1 }

    func showEarlier() async {
        guard let window, window.lowerBound > 0 else { return }
        await ensureWindow(around: window.lowerBound - 1)
        scrollTarget = segments.first?.id
    }

    func showLater() async {
        guard let window, window.upperBound < chunkCount - 1 else { return }
        await ensureWindow(around: window.upperBound + 1)
        scrollTarget = segments.first(where: { $0.chunk == window.upperBound + 1 })?.id ?? segments.last?.id
    }

    /// Loads the chunks around `chunk` that are not loaded yet and drops the rest.
    func ensureWindow(around chunk: Int) async {
        guard let outline, outline.chunkCount > 0 else { return }
        let lo = max(0, chunk - Self.windowRadius), hi = min(outline.chunkCount - 1, chunk + Self.windowRadius)
        let missing = (lo...hi).filter { loadedChunks[$0] == nil }
        if let first = missing.first, let last = missing.last {
            requestedRanges.append(first...last)
            let read = await source.chunks(first...last, kind: outline.kind)
            for (index, text) in read where (lo...hi).contains(index) { loadedChunks[index] = text }
        }
        for index in loadedChunks.keys where !(lo...hi).contains(index) { loadedChunks[index] = nil }
        window = lo...hi
        rebuildSegments()
    }

    // MARK: Matching (the search's phrase rule)

    private func matches(inChunk chunk: Int) -> PhraseChunks.Matches? {
        guard let text = loadedChunks[chunk], let regex = SectionBoundary.phraseRegex(query) else { return nil }
        return PhraseChunks.matches(in: text, previous: loadedChunks[chunk - 1], next: loadedChunks[chunk + 1], regex: regex)
    }

    /// The marks in one loaded chunk (raw offsets): every occurrence, and the one in view.
    func marks(inChunk chunk: Int) -> (all: [NSRange], current: NSRange?) {
        let all = matches(inChunk: chunk)?.marks ?? []
        let current = focus.flatMap { $0.chunk == chunk ? $0.range : nil }
        return (all, current)
    }

    // MARK: Display

    private func rebuildSegments() {
        guard let window else { segments = []; return }
        var out: [Segment] = []
        var target: String?
        for chunk in window {
            guard let raw = loadedChunks[chunk] else { continue }
            let (all, currentMark) = marks(inChunk: chunk)
            let display = Self.displayText(raw)
            let ns = display.text as NSString
            let hiddenMarks = all.map { display.map($0) }
            let hiddenCurrent = currentMark.map { display.map($0) }
            var start = 0
            var index = 0
            while start < ns.length {
                var end = min(ns.length, start + Self.segmentUnits)
                if end < ns.length {
                    let search = NSRange(location: start + Self.segmentUnits / 2, length: end - start - Self.segmentUnits / 2)
                    let newline = ns.range(of: "\n", options: .backwards, range: search)
                    if newline.location != NSNotFound { end = newline.location + 1 }
                    end = ns.rangeOfComposedCharacterSequence(at: max(start, end - 1)).upperBound
                }
                let piece = NSRange(location: start, length: end - start)
                let id = "\(chunk):\(index)"
                out.append(Segment(id: id, chunk: chunk,
                                   text: Self.attributed(ns.substring(with: piece), offset: start, marks: hiddenMarks, current: hiddenCurrent)))
                if let hiddenCurrent, target == nil, hiddenCurrent.location >= start, hiddenCurrent.location < end { target = id }
                index += 1
                start = end
            }
        }
        segments = out
        if let target { scrollTarget = target }
    }

    /// The stored text without its U+001E boundaries, with a map from raw
    /// UTF-16 offsets to display offsets.
    struct DisplayText {
        let text: String
        /// Display offset of each raw offset (nil when the text has no boundary).
        let removedBefore: [Int]?

        func map(_ range: NSRange) -> NSRange {
            guard let removedBefore else { return range }
            let lo = min(range.location, removedBefore.count - 1), hi = min(range.location + range.length, removedBefore.count - 1)
            return NSRange(location: lo - removedBefore[lo], length: (hi - removedBefore[hi]) - (lo - removedBefore[lo]))
        }
    }

    static func displayText(_ raw: String) -> DisplayText {
        let units = Array(raw.utf16)
        guard units.contains(0x1E) else { return DisplayText(text: raw, removedBefore: nil) }
        var removed = [Int](repeating: 0, count: units.count + 1)
        for (i, u) in units.enumerated() { removed[i + 1] = removed[i] + (u == 0x1E ? 1 : 0) }
        return DisplayText(text: SectionBoundary.hidden(raw), removedBefore: removed)
    }

    /// One display block with the occurrences marked (the one in view stronger).
    static func attributed(_ piece: String, offset: Int, marks: [NSRange], current: NSRange?) -> AttributedString {
        var result = AttributedString(piece)
        let length = (piece as NSString).length
        func apply(_ range: NSRange, strong: Bool) {
            let lo = max(0, range.location - offset), hi = min(length, range.location + range.length - offset)
            guard hi > lo, let swiftRange = Range(NSRange(location: lo, length: hi - lo), in: piece),
                  let a = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let b = AttributedString.Index(swiftRange.upperBound, within: result) else { return }
            result[a..<b].backgroundColor = strong ? Color.orange.opacity(0.8) : Color.yellow.opacity(0.6)
            result[a..<b].inlinePresentationIntent = .stronglyEmphasized
        }
        for mark in marks { apply(mark, strong: false) }
        if let current { apply(current, strong: true) }
        return result
    }
}
