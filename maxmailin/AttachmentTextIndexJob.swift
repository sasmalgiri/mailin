@testable import ArchiveCore
//
//  AttachmentTextIndexJob.swift
//  maxmailin
//
//  Attachment-CONTENT search (v2.1 backlog #2, now shipped): extracts text
//  from attachments (PDF via PDFKit; plain-text families; RTF/HTML via
//  AttributedString) and indexes it into the `attachment_search` FTS table,
//  so `in:attachments` matches what's INSIDE files — not just filenames.
//
//  Bounded by construction: byte-capped work-list pages over emails with
//  attachments; one email's attachments resident at a time; per-attachment
//  extracted text capped; binary formats without a text extractor are
//  recorded as attempted (state row) so the work list converges and the UI
//  can report progress honestly. Kicked at launch and after every import.
//
//  Five jobs FIND-03: "attempted" is per email; what happened to EACH
//  attachment (searchable, cut short, no text, unsupported, locked, failed)
//  is recorded in `AttachmentCoverageStore` with the extractor version, so
//  the person sees what was not searchable and a newer extractor retries
//  what an older one could not read — without a reimport.
//

import Foundation
import CryptoKit
import PDFKit
import os.log

extension Notification.Name {
    /// Posted when newly indexed attachment text is available — active
    /// `in:attachments` searches should re-run.
    static let attachmentIndexUpdated = Notification.Name("mailin.attachmentIndexUpdated")
}

@MainActor
final class AttachmentTextIndexJob {

    static let shared = AttachmentTextIndexJob()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "AttachmentIndex")

    /// Test seam.
    static var testStoreOverride: SQLiteEmailStore?
    /// Test seam: the app's own launch/import kicks stay out while a test drives passes itself.
    static var testSuppressKicks = false
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }

    private var task: Task<Void, Never>?
    private var runGeneration = 0

    /// Settings ▸ Modules "Running now". The job owns its own row (owner's
    /// review 2026-09-29): registered when a run starts — including re-kicks
    /// after an import — and cleared on EVERY exit. Before this the launch
    /// hook registered the row and nothing ever cleared it.
    static let jobID = "attachment.textIndex"
    static let jobLabel = "Index attachment contents"
    private weak var registry: JobRegistry?

    /// Test seam: the current run, if any.
    var currentRun: Task<Void, Never>? { task }

    /// Extracted text cap per attachment — plenty for search, never unbounded.
    /// Text beyond it is recorded as `truncated` (FIND-07 removes the cap).
    nonisolated static let maxTextPerAttachment = 500_000

    /// FIND-03: bump when an extractor is added or improved. Coverage rows
    /// below this version in unsupported/failed/truncated are re-queued at
    /// the start of the next pass. 1 = before per-attachment coverage;
    /// 2 = per-attachment states; 3 = DOCX/XLSX/PPTX (FIND-01).
    /// 4 (2026-11-06): OpenDocument, iWork, Office 97–2003 and ZIP contents
    /// are read — rows those kinds left as unsupported are retried.
    /// 5: children of archives and messages are their own documents (§13.3).
    /// 6 (§13.8 step 3): winmail.dat (TNEF) opened, .msg/.oft attachments read
    /// as messages, embedded Outlook messages expanded — rows those kinds
    /// left as unsupported are retried.
    /// 7 (§13.8 step 4): Office depth — tracked changes, text boxes, Excel
    /// comments and hidden sheets, hidden slides, charts, embedded documents
    /// as children; XLSB, Visio (VSDX) and Project XML readers.
    nonisolated static let extractorVersion = 7

    struct Outcome: Sendable, Equatable {
        var indexedEmails = 0
        var extractedTexts = 0
        var failed = 0
        /// E1: emails read again for scanned text by the OCR second pass, and how many it covers.
        var ocrEmails = 0
        var ocrTotal = 0
    }

    /// FIND-03: what one attachment yielded.
    struct Extraction: Sendable {
        let ordinal: Int
        let filename: String
        let mimeType: String
        /// Text to index in the previous (capped) table, when there is any.
        let text: String?
        /// FIND-07: the whole text, for the chunk index — never cut.
        let fullText: String?
        let state: AttachmentCoverageState
        let extractor: String
        let note: String?
        /// §13.3 (5): the files inside this attachment, each its own document.
        var children: [ChildDocument] = []

        /// The chunk index's document for this attachment.
        var searchDocument: AttachmentSearchDocument {
            let docState: SearchDocState
            switch state {
            case .extracted, .truncated: docState = .complete   // the chunk index holds the whole text
            case .partial: docState = .partial                   // some text-bearing parts were not read
            case .noText: docState = .noText
            case .unsupported: docState = .unsupported
            case .locked: docState = .locked
            case .failed: docState = .failed
            }
            return AttachmentSearchDocument(ordinal: ordinal, filename: filename, text: (docState == .complete || docState == .partial) ? fullText : nil,
                                            state: docState, extractorVersion: AttachmentTextIndexJob.extractorVersion, ocr: extractor == "ocr",
                                            speech: extractor == "speech")
        }

        func coverageRow(emailID: UUID) -> AttachmentCoverageRow {
            AttachmentCoverageRow(
                emailID: emailID, ordinal: ordinal, filename: filename, mimeType: mimeType,
                state: state, extractor: extractor, extractorVersion: AttachmentTextIndexJob.extractorVersion,
                characters: text?.count ?? 0, note: note)
        }
    }

    init() {
        // New imports create new work; re-kick when one lands.
        NotificationCenter.default.addObserver(
            forName: .parsingFinished, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AttachmentTextIndexJob.shared.kickIfNeeded() }
        }
    }

    func kickIfNeeded(registry: JobRegistry? = nil) {
        guard task == nil, !Self.testSuppressKicks else { return }
        guard SafeMode.shared.allowsBackgroundWork else { return }   // §3-S6
        guard BackgroundExecution.isProtectedDataAvailable else { return }   // §3-S3
        if let registry { self.registry = registry }
        runGeneration += 1
        let generation = runGeneration
        self.registry?.register(id: Self.jobID, module: .archive, label: Self.jobLabel) { [weak self] in self?.cancel() }
        task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run()
            if self.runGeneration == generation {
                self.task = nil
                self.registry?.finish(id: Self.jobID)
            }
        }
    }

    func cancel() {
        runGeneration += 1
        task?.cancel()
        task = nil
        registry?.finish(id: Self.jobID)
    }

    /// OPEN-04: a pass is kicked or in progress right now.
    var isRunning: Bool { task != nil || activeRun != nil }

    private func report(_ outcome: Outcome) {
        var parts = ["\(outcome.indexedEmails.formatted()) emails indexed"]
        if outcome.extractedTexts > 0 { parts.append("\(outcome.extractedTexts.formatted()) texts") }
        if outcome.failed > 0 { parts.append("\(outcome.failed.formatted()) failed") }
        if outcome.ocrTotal > 0 { parts.append(String(localized: "scanned text: \(outcome.ocrEmails.formatted()) of \(outcome.ocrTotal.formatted()) emails")) }
        registry?.update(id: Self.jobID, detail: parts.joined(separator: ", "))
    }

    /// The pass in progress. Passes never overlap: two at once could index the same email twice
    /// and one could overwrite the other's freshly read (OCR) text.
    /// The pass clears this itself when it ends, so a waiter never finds a finished pass still
    /// marked active (it would wait on it again and again without ever yielding).
    private var activeRun: (id: UUID, task: Task<Outcome, Never>)?

    /// Runs one pass, after any pass already running has finished. Cancelling the caller cancels
    /// the pass (an interrupted pass resumes on the next run).
    @discardableResult
    func run(batchSize: Int = 50) async -> Outcome {
        while let active = activeRun { _ = await active.task.value }
        let id = UUID()
        // Main-actor isolated: the pass cannot start before `activeRun` is set below.
        let pass = Task { @MainActor in
            let outcome = await self.runPass(batchSize: batchSize)
            if self.activeRun?.id == id { self.activeRun = nil }
            return outcome
        }
        activeRun = (id, pass)
        return await withTaskCancellationHandler { await pass.value } onCancel: { pass.cancel() }
    }

    /// Returns once no pass is running (a kicked pass is cancelled first).
    func cancelAndWaitUntilIdle() async {
        cancel()
        while let active = activeRun { active.task.cancel(); _ = await active.task.value }
    }

    private func runPass(batchSize: Int) async -> Outcome {
        var outcome = Outcome()
        // E1: read once per run; a switch flipped mid-run applies from the next run.
        let ocr = AttachmentOCR.isEnabled
        var ocrState: AttachmentOCRState? = nil
        if ocr {
            let stateURL = await store.attachmentOCRStateURL
            ocrState = try? AttachmentOCRState(url: stateURL)
        }
        // FIND-03: per-attachment coverage beside the archive.
        let coverage = try? AttachmentCoverageStore(url: await store.attachmentCoverageURL)
        do {
            if let coverage {
                let requeued = try await Self.requeueStale(store: store, coverage: coverage)
                if requeued > 0 { Self.logger.info("attachment index: \(requeued) email(s) re-queued for extractor v\(Self.extractorVersion)") }
            }
            // FIND-07: attachments indexed before the chunk index existed go
            // back on the work list so their whole text is indexed too.
            if SearchChunkPolicy.isEnabled {
                let requeued = try await Self.requeueForChunkIndex(store: store)
                if requeued > 0 { Self.logger.info("attachment index: \(requeued) email(s) re-queued for the chunk index") }
            }
            while true {
                if Task.isCancelled { break }
                let page = try await store.attachmentTextCandidates(limit: batchSize)
                if !page.rawless.isEmpty {
                    // No raw source → nothing to extract; mark attempted, and
                    // say so for each attachment the side table knows.
                    for id in page.rawless {
                        try await store.attachmentTextIndex(emailID: id, texts: [])
                        await recordCoverage(coverage, emailID: id, extractions: nil,
                                             unreadable: String(localized: "message source not stored"))
                    }
                }
                if page.candidates.isEmpty {
                    if page.rawless.isEmpty { break }
                    continue
                }
                var pageProgress = page.rawless.count
                for candidate in page.candidates {
                    if Task.isCancelled { break }
                    // Whole extraction chain off the main actor — MIME decode,
                    // temp-file write, PDF/text parse.
                    let extractions: [Extraction]? = await Task.detached(priority: .utility) {
                        Self.extractCoverage(fromRaw: candidate.raw, ocr: ocr)
                    }.value
                    let texts = Self.texts(extractions ?? [])
                    do {
                        try await store.attachmentTextIndex(emailID: candidate.id, texts: texts)
                        await recordCoverage(coverage, emailID: candidate.id, extractions: extractions,
                                             unreadable: String(localized: "message could not be parsed"))
                        // Read with OCR already: the second pass need not come back to it.
                        try? ocrState?.markDone([candidate.id])
                        outcome.indexedEmails += 1
                        outcome.extractedTexts += texts.count
                        pageProgress += 1
                    } catch {
                        outcome.failed += 1
                        Self.logger.error("attachment index failed for \(candidate.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if pageProgress == 0 { break }
                report(outcome)
            }
            if let ocrState, !Task.isCancelled {
                try await ocrSecondPass(state: ocrState, coverage: coverage, batchSize: batchSize, outcome: &outcome)
            }
            if outcome.indexedEmails > 0 || outcome.ocrEmails > 0 {
                Self.logger.info("attachment text indexed: \(outcome.indexedEmails) email(s), \(outcome.extractedTexts) text(s)")
                NotificationCenter.default.post(name: .attachmentIndexUpdated, object: nil)
            }
        } catch {
            Self.logger.error("attachment index aborted: \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    /// E1: emails whose attachment text was extracted before OCR was on, and that hold an image
    /// or a PDF, are read again — each once (the state file remembers), resuming at its cursor.
    /// IDs are paged without loading messages; only emails not yet read are loaded, in
    /// byte-capped pages. A finished pass clears the cursor, so mail indexed while OCR was off
    /// is found on a later run.
    private func ocrSecondPass(state: AttachmentOCRState, coverage: AttachmentCoverageStore?,
                               batchSize: Int, outcome: inout Outcome) async throws {
        outcome.ocrTotal = try await store.attachmentOCRCandidateCount()
        outcome.ocrEmails = min(outcome.ocrTotal, (try? state.doneCount()) ?? 0)
        report(outcome)
        var cursor = state.cursor
        while !Task.isCancelled {
            let ids = try await store.attachmentOCRCandidateIDs(after: cursor, limit: batchSize * 10)
            guard let last = ids.last else { state.cursor = nil; break }
            let done = try state.done(among: ids)
            var pending = ids.filter { !done.contains($0) }
            while !pending.isEmpty, !Task.isCancelled {
                let page = try await store.rawCandidates(ids: Array(pending.prefix(batchSize)))
                if !page.rawless.isEmpty { try state.markDone(page.rawless) }
                for candidate in page.candidates {
                    if Task.isCancelled { break }
                    let extractions: [Extraction]? = await Task.detached(priority: .utility) {
                        Self.extractCoverage(fromRaw: candidate.raw, ocr: true)
                    }.value
                    do {
                        try await store.attachmentTextIndex(emailID: candidate.id, texts: Self.texts(extractions ?? []))
                        await recordCoverage(coverage, emailID: candidate.id, extractions: extractions,
                                             unreadable: String(localized: "message could not be parsed"))
                        try state.markDone([candidate.id])
                        outcome.ocrEmails += 1
                    } catch {
                        outcome.failed += 1
                        Self.logger.error("attachment OCR failed for \(candidate.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                let handled = Set(page.rawless).union(page.candidates.map(\.id))
                if handled.isEmpty { break }
                pending.removeAll { handled.contains($0) }
                report(outcome)
            }
            if Task.isCancelled { break }
            cursor = last.uuidString
            state.cursor = cursor
        }
    }

    // MARK: - FIND-03: coverage

    /// Write what happened to each attachment. `extractions == nil` means the
    /// message itself could not be read: every attachment the side table
    /// lists is then `failed` with `unreadable` as the reason.
    private func recordCoverage(_ coverage: AttachmentCoverageStore?, emailID: UUID,
                                extractions: [Extraction]?, unreadable: String) async {
        // FIND-07: the chunk index gets each attachment's whole text (or its state).
        if SearchChunkPolicy.isEnabled, let extractions {
            do {
                try await store.indexAttachmentSearchDocuments(emailID: emailID, documents: extractions.map(\.searchDocument))
                // §13.3 (5): every file inside an attachment is its own document and row.
                for extraction in extractions { try await recordChildren(emailID: emailID, extraction: extraction) }
            } catch {
                Self.logger.error("attachment search documents not written for \(emailID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let coverage else { return }
        let rows: [AttachmentCoverageRow]
        if let extractions {
            rows = extractions.map { $0.coverageRow(emailID: emailID) }
        } else {
            let metadata = (try? await store.attachmentMetadata(forEmailID: emailID)) ?? []
            rows = metadata.enumerated().map { item in
                AttachmentCoverageRow(
                    emailID: emailID, ordinal: item.offset, filename: item.element.filename,
                    mimeType: item.element.mimeType, state: .failed, extractor: "none",
                    extractorVersion: Self.extractorVersion, characters: 0, note: unreadable)
            }
        }
        do { try coverage.record(emailID: emailID, rows: rows) } catch {
            Self.logger.error("attachment coverage not recorded for \(emailID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The files inside one attachment as child rows and `childText` documents.
    private func recordChildren(emailID: UUID, extraction: Extraction) async throws {
        let rows = extraction.children.enumerated().map { index, child in
            AttachmentChildRow(emailID: emailID, position: extraction.ordinal, childIndex: index, path: child.path, filename: child.filename,
                               kind: child.kind, sha256: child.sha256, bytes: child.bytes, state: child.state.rawValue, note: child.note)
        }
        var texts: [Int: String?] = [:], states: [Int: SearchDocState] = [:]
        for (index, child) in extraction.children.enumerated() {
            texts[index] = child.state.isSearchable ? child.text : nil
            switch child.state {
            case .extracted: states[index] = .complete
            case .noText: states[index] = .noText
            case .partial: states[index] = .partial
            case .unsupported: states[index] = .unsupported
            case .locked: states[index] = .locked
            case .failed: states[index] = .failed
            }
        }
        try await store.recordAttachmentChildren(emailID: emailID, position: extraction.ordinal, children: rows,
                                                 texts: texts, states: states, extractorVersion: Self.extractorVersion)
    }

    /// Emails an older extractor left unsupported, failed or cut short go back
    /// on the work list, a page at a time. Returns how many were re-queued.
    static func requeueStale(store: SQLiteEmailStore, coverage: AttachmentCoverageStore) async throws -> Int {
        var total = 0
        while !Task.isCancelled {
            let ids = try coverage.emailIDs(staleBelow: extractorVersion, limit: 500)
            if ids.isEmpty { break }
            try await store.attachmentTextStateReset(emailIDs: ids)
            try coverage.remove(emailIDs: ids)
            total += ids.count
        }
        // §13.3 (5): archives and attached messages read before children had
        // their own identity are re-read even when they were "extracted".
        while !Task.isCancelled {
            let ids = try coverage.emailIDs(extractors: ["zip", "archive", "eml", "office"], below: 7, limit: 500)
            if ids.isEmpty { break }
            try await store.attachmentTextStateReset(emailIDs: ids)
            try coverage.remove(emailIDs: ids)
            total += ids.count
        }
        return total
    }

    /// FIND-07: emails whose attachments were attempted before the chunk
    /// index existed are re-queued, a page at a time. Returns how many.
    static func requeueForChunkIndex(store: SQLiteEmailStore) async throws -> Int {
        var total = 0
        while !Task.isCancelled {
            let ids = try await store.attachmentEmailsWithoutSearchDocs(limit: 500)
            if ids.isEmpty { break }
            try await store.attachmentTextStateReset(emailIDs: ids)
            total += ids.count
            if ids.count < 500 { break }
        }
        return total
    }

    /// The archive's attachment coverage, for notices. Nil when nothing has been recorded yet.
    nonisolated static func coverageSummary(store: SQLiteEmailStore) async -> AttachmentCoverageSummary? {
        let url = await store.attachmentCoverageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? AttachmentCoverageStore(url: url).summary(currentExtractorVersion: extractorVersion)
    }

    /// "No attachments matched" that says what was not searchable.
    nonisolated static func noMatchNotice(_ summary: AttachmentCoverageSummary) -> String {
        var parts: [String] = []
        if let n = summary.counts[.unsupported], n > 0 {
            let kinds = summary.unsupportedKinds.prefix(4).map(\.kind).filter { !$0.isEmpty }
            parts.append(kinds.isEmpty
                ? String(localized: "\(n) unsupported")
                : String(localized: "\(n) unsupported (\(kinds.joined(separator: ", ")))"))
        }
        if let n = summary.counts[.locked], n > 0 { parts.append(String(localized: "\(n) locked")) }
        if let n = summary.counts[.failed], n > 0 { parts.append(String(localized: "\(n) failed")) }
        if let n = summary.counts[.truncated], n > 0 { parts.append(String(localized: "\(n) cut short")) }
        if let n = summary.counts[.partial], n > 0 { parts.append(String(localized: "\(n) partly read")) }
        if let n = summary.counts[.noText], n > 0 { parts.append(String(localized: "\(n) with no text")) }
        if parts.isEmpty {
            return String(localized: "No attachments matched. Searchable text covers all \(summary.total) attachments.")
        }
        return String(localized: "No attachments matched. Searchable text covers \(summary.searchable) of \(summary.total) attachments — \(parts.joined(separator: ", ")).")
    }

    // MARK: - Extraction (nonisolated, bounded)

    /// Text from every extractable attachment of one raw MIME message.
    /// Temp files created by the extractor are removed before returning.
    nonisolated static func extractTexts(fromRaw raw: String, ocr: Bool = false) -> [(filename: String, content: String)] {
        texts(extractCoverage(fromRaw: raw, ocr: ocr) ?? [])
    }

    nonisolated static func texts(_ extractions: [Extraction]) -> [(filename: String, content: String)] {
        extractions.compactMap { e in e.text.map { (filename: e.filename, content: $0) } }
    }

    /// FIND-03: every attachment of one raw MIME message with its state. Nil
    /// when the message itself cannot be parsed.
    /// - Parameter passwords: §13.8 step 5 — passwords the person typed for
    ///   specific attachments (by ordinal), used for this read and not kept.
    nonisolated static func extractCoverage(fromRaw raw: String, ocr: Bool = false, passwords: [Int: String] = [:]) -> [Extraction]? {
        guard let extraction = try? EmailBodyExtractor.extractContents(from: raw) else { return nil }
        var out: [Extraction] = []
        for (ordinal, attachment) in extraction.attachments.enumerated() {
            defer {
                if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) }
            }
            out.append(classify(attachment, ordinal: ordinal, ocr: ocr, password: passwords[ordinal]))
        }
        return out
    }

    /// The extracted text of one attachment, if any (whole, not cut at the cap).
    nonisolated static func extractText(from attachment: AttachmentMetadata, ocr: Bool = false) -> String? {
        read(attachment, ocr: ocr).text
    }

    /// FIND-03: read one attachment and say what happened. Text longer than
    /// the cap is cut and the state says so.
    nonisolated static func classify(_ attachment: AttachmentMetadata, ordinal: Int, ocr: Bool, password: String? = nil) -> Extraction {
        var result = read(attachment, ocr: ocr, password: password)
        if password != nil, result.state != .locked, result.state != .failed, result.state != .unsupported {
            // The record says how this came to be readable — and that nothing was kept.
            let unlocked = String(localized: "unlocked with a password you entered; the password was not kept")
            result.note = result.note.map { $0 + "; " + unlocked } ?? unlocked
        }
        var text = result.text
        var fullText = result.text
        var state = result.state
        if let full = text {
            if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = nil
                fullText = nil
                state = state == .partial ? .partial : .noText
            } else if full.count > maxTextPerAttachment {
                text = String(full.prefix(maxTextPerAttachment))
                if state != .partial { state = .truncated }
            }
        }
        return Extraction(ordinal: ordinal, filename: attachment.filename, mimeType: attachment.mimeType,
                          text: text, fullText: fullText, state: state, extractor: result.extractor, note: result.note, children: result.children)
    }

    /// Audit 2026-11-06 A06: the coverage state an OCR outcome earns.
    /// Every page read and words found → extracted; every page read and no
    /// words → noText (the picture has no text); some pages failed but
    /// others were read → partial, the note lists the failed pages; nothing
    /// could be read → failed with the reasons. A failure is never "no text".
    /// What reading one attachment produced: its text and state, and (§13.3)
    /// the files inside it as children with their own identity.
    nonisolated struct Reading: Sendable {
        let text: String?
        var state: AttachmentCoverageState
        let extractor: String
        var note: String?
        var children: [ChildDocument] = []
        init(_ text: String?, _ state: AttachmentCoverageState, _ extractor: String, _ note: String?, children: [ChildDocument] = []) {
            self.text = text; self.state = state; self.extractor = extractor; self.note = note; self.children = children
        }
    }

    nonisolated static func ocrState(_ outcome: AttachmentOCR.Outcome, pages: Int)
        -> Reading {
        let read = outcome.recognised + outcome.layerPages
        let reasons = outcome.failures.prefix(3).joined(separator: "; ")
            + (outcome.failures.count > 3 ? String(localized: "; and \(outcome.failures.count - 3) more") : "")
        if outcome.isComplete {
            let words = outcome.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if words.isEmpty { return Reading("", .noText, "ocr", String(localized: "no text was recognised in the image")) }
            return Reading(outcome.text, .extracted, "ocr", nil)
        }
        if read > 0 {
            return Reading(outcome.text, .partial, "ocr",
                    String(localized: "\(outcome.failed) of \(max(pages, read + outcome.failed)) pages could not be read: \(reasons)"))
        }
        return Reading(nil, .failed, "ocr", reasons)
    }

    /// FIND-01: an Office Open XML package. Needs a file: the extractor's
    /// temp file when there is one, otherwise the bytes written to one.
    /// TYPE-01…04: every document kind through the one facade — Office Open
    /// XML, OpenDocument, iWork, Office 97–2003 and one level inside ZIPs.
    nonisolated private static func readDocument(_ attachment: AttachmentMetadata, kind: DocumentKind, data: Data, password: String? = nil)
        -> Reading {
        var url = attachment.fileURL
        var temporary: URL?
        if url == nil {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent("document-\(UUID().uuidString).\(kind.rawValue)")
            do { try data.write(to: t) } catch { return Reading(nil, .failed, kind.extractorName, error.localizedDescription) }
            temporary = t; url = t
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            // R03: the attachment's own name travels with the bytes, whatever the temp file is called.
            let result = try DocumentTextExtractor.extract(fileURL: url!, kind: kind, logicalName: attachment.filename, password: password)
            var note: String? = nil
            if !result.skipped.isEmpty {
                note = String(localized: "not read: \(result.skipped.joined(separator: "; "))")
            }
            // §13.8 step 5: an archive whose every file is password-protected is
            // itself locked — the listing of names is not its content, and the
            // lock row offers Unlock… for it.
            if kind.isContainer, !result.children.isEmpty, result.children.allSatisfy({ $0.state == .locked }) {
                let why = result.children.count == 1
                    ? String(localized: "the file inside is password-protected")
                    : String(localized: "every file inside is password-protected (\(result.children.count))")
                return Reading(nil, .locked, kind.extractorName, why, children: result.children)
            }
            return Reading(result.text, result.partial ? .partial : .extracted, kind.extractorName, note, children: result.children)
        } catch OfficeTextExtractor.ExtractError.encrypted {
            return Reading(nil, .locked, kind.extractorName, String(localized: "password-protected document"))
        } catch OfficeTextExtractor.ExtractError.wrongPassword {
            return Reading(nil, .locked, kind.extractorName, String(localized: "the password did not open the document"))
        } catch OfficeTextExtractor.ExtractError.noTextParts {
            return Reading("", .noText, kind.extractorName, nil)
        } catch {
            return Reading(nil, .failed, kind.extractorName, error.localizedDescription)
        }
    }

    /// Audit 2026-11-06 A04: children of an archive the package cannot read
    /// itself go through the same reader as a top-level attachment (PDF text
    /// layer, OCR, speech), so a PDF inside a ZIP is read, and a child
    /// nothing can read is listed in the attachment's state, never dropped.
    nonisolated static let childReaderClosure: @Sendable (URL, String) -> ArchiveChildReading = { url, name in
        let child = AttachmentMetadata(filename: name, mimeType: "", size: 0, fileURL: url)
        let reading = read(child, ocr: AttachmentOCR.isEnabled)
        switch reading.state {
        case .extracted, .truncated: return ArchiveChildReading(text: reading.text, notRead: nil, children: reading.children)
        case .partial: return ArchiveChildReading(text: reading.text, notRead: reading.note, children: reading.children)
        case .noText: return ArchiveChildReading(text: "", notRead: nil, children: reading.children)
        case .unsupported, .locked, .failed: return ArchiveChildReading(text: nil, notRead: reading.note ?? reading.state.rawValue, children: reading.children)
        }
    }

    /// Installed once on first use in production; tests that reset the reader
    /// call `installChildReader()` again, which reinstalls it every time.
    nonisolated static let childReaderInstalled: Void = { ContainerTextExtractor.childReader = childReaderClosure }()

    nonisolated static func installChildReader() { ContainerTextExtractor.childReader = childReaderClosure }

    /// R04: an attached message (.eml / message/rfc822) is a message, not a
    /// text file: its MIME parts are decoded (base64, quoted-printable,
    /// charsets) and its own attachments are read as children, labelled
    /// "EML: name", through the same reader. Nested messages stop at
    /// `maxMessageDepth`, stated.
    nonisolated static let maxMessageDepth = 3

    nonisolated private static func readEmbeddedMessage(_ data: Data, ocr: Bool, depth: Int, extractor: String = "eml")
        -> Reading {
        guard depth < maxMessageDepth else {
            return Reading(nil, .unsupported, extractor, String(localized: "a message nested deeper than \(maxMessageDepth) levels"))
        }
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return Reading(nil, .failed, extractor, String(localized: "text encoding not recognised"))
        }
        let email: MBOXParser.RawEmail
        do { email = try MBOXParser.processRawMessage(raw, senderEmail: "") } catch {
            return Reading(nil, .failed, extractor, error.localizedDescription)
        }
        return messageReading(email, extractor: extractor, ocr: ocr, depth: depth)
    }

    /// §13.8 step 5 (COMP-14): an S/MIME part (enveloped or signed). With the
    /// module off it is recorded locked and says what would open it. With it
    /// on, the Mac's keychain identity decrypts it here, offline, and the
    /// message inside is read like any attached message. Nothing is retained
    /// beyond what the person chose for the index.
    nonisolated private static func readSMIME(_ data: Data, ocr: Bool, depth: Int) -> Reading {
        guard ProtectedContentPolicy.decryptSMIME else {
            return Reading(nil, .locked, "smime", String(localized: "S/MIME-protected content — turn on \"Read S/MIME with your keychain key\" in Settings ▸ Modules to read it on this Mac"))
        }
        #if os(macOS)
        guard let plain = SMIMEHandler.decodeCMS(data) else {
            return Reading(nil, .locked, "smime", String(localized: "no matching private key in the keychain, or the part is not an S/MIME envelope"))
        }
        return readEmbeddedMessage(plain, ocr: ocr, depth: depth, extractor: "smime")
        #else
        return Reading(nil, .locked, "smime", String(localized: "S/MIME decryption runs on the Mac"))
        #endif
    }

    // MARK: - §13.8 step 5: Unlock (one password, one attachment, once)

    enum UnlockOutcome: Sendable, Equatable {
        case wrongPassword(String)
        case unreadable(String)
        /// Read. `stored` says whether the text went into the archive's index.
        case unlocked(text: String, children: [ChildDocument], stored: Bool)
    }

    /// Reads one attachment with the password the person typed. `retain`
    /// decides between showing the text once (nothing written) and recording
    /// it like any other attachment (the message's attachments are re-read
    /// and re-recorded together, so the archive stays consistent). The
    /// password is used for this call and not kept.
    func unlock(emailID: UUID, position: Int, password: String, retain: Bool) async -> UnlockOutcome {
        guard let page = try? await store.rawCandidates(ids: [emailID]), let candidate = page.candidates.first else {
            return .unreadable(String(localized: "message source not stored"))
        }
        let ocr = AttachmentOCR.isEnabled
        let raw = candidate.raw
        let extractions: [Extraction]? = await Task.detached(priority: .userInitiated) {
            Self.extractCoverage(fromRaw: raw, ocr: ocr, passwords: [position: password])
        }.value
        guard let extractions, position < extractions.count else {
            return .unreadable(String(localized: "message could not be parsed"))
        }
        let target = extractions[position]
        switch target.state {
        case .locked: return .wrongPassword(target.note ?? String(localized: "the password did not open the file"))
        case .failed, .unsupported: return .unreadable(target.note ?? target.state.rawValue)
        case .extracted, .partial, .noText, .truncated: break
        }
        if retain {
            // Only THIS attachment's record changes: an earlier unlock of a
            // sibling is not undone by re-reading the message without its password.
            do {
                if SearchChunkPolicy.isEnabled {
                    try await store.indexAttachmentSearchDocuments(emailID: emailID, documents: [target.searchDocument])
                    try await recordChildren(emailID: emailID, extraction: target)
                }
                let coverage = try AttachmentCoverageStore(url: await store.attachmentCoverageURL)
                try coverage.record(row: target.coverageRow(emailID: emailID))
            } catch {
                Self.logger.error("unlock not recorded for \(emailID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .unreadable(String(localized: "the text was read but could not be stored: \(error.localizedDescription)"))
            }
            NotificationCenter.default.post(name: .attachmentIndexUpdated, object: nil)
        }
        return .unlocked(text: target.fullText ?? "", children: target.children, stored: retain)
    }

    /// The recorded state of one attachment, for the detail view's lock row.
    func coverageRow(emailID: UUID, position: Int) async -> AttachmentCoverageRow? {
        let url = await store.attachmentCoverageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? AttachmentCoverageStore(url: url).rows(for: emailID).first { $0.ordinal == position }
    }

    /// §13.8 step 3: an Outlook message (.msg) or template (.oft) attached as
    /// a file is a message too — its MAPI properties are read by the MSG
    /// reader, and its attachments (embedded messages included) are children.
    nonisolated private static func readOutlookMessage(_ data: Data, ocr: Bool, depth: Int) -> Reading {
        guard depth < maxMessageDepth else {
            return Reading(nil, .unsupported, "msg", String(localized: "a message nested deeper than \(maxMessageDepth) levels"))
        }
        let email: MBOXParser.RawEmail
        do { email = try MSGParser.parse(data: data) } catch {
            return Reading(nil, .failed, "msg", error.localizedDescription)
        }
        return messageReading(email, extractor: "msg", ocr: ocr, depth: depth)
    }

    /// §13.8 step 3 (COMP-07): winmail.dat — the TNEF wrapper Outlook puts a
    /// message's rich body and files in. Its text is read, and every file in
    /// it is a child document under the winmail.dat attachment.
    nonisolated private static func readTNEF(_ data: Data, ocr: Bool, depth: Int) -> Reading {
        guard depth < maxMessageDepth else {
            return Reading(nil, .unsupported, "tnef", String(localized: "a message nested deeper than \(maxMessageDepth) levels"))
        }
        let content: TNEFReader.Content
        do { content = try TNEFReader.read(data) } catch TNEFReader.ReadError.truncated(let why) {
            return Reading(nil, .failed, "tnef", String(localized: "winmail.dat is cut short: \(why)"))
        } catch {
            return Reading(nil, .failed, "tnef", error.localizedDescription)
        }
        var headers: [String: String] = [:]
        if let subject = content.subject, !subject.isEmpty { headers["Subject"] = subject }
        let attachments = content.attachments.map { file in
            AttachmentMetadata(filename: file.filename, mimeType: file.isEmbeddedMessage ? "application/vnd.ms-outlook" : file.mimeType,
                               size: file.data.count, base64: file.isEmbeddedMessage ? nil : file.data.base64EncodedString())
        }
        let email = MBOXParser.RawEmail(
            id: UUID(), headers: headers, rawSource: "", messageType: "received", attachments: attachments, timestamp: "",
            domains: [], plainBody: content.bodyText, htmlBody: "", mimeRoot: nil, mimeSummary: nil, mimeDiagnostics: [],
            threadID: "", inReplyTo: nil, references: nil, tags: [], anomalies: [])
        var reading = messageReading(email, extractor: "tnef", ocr: ocr, depth: depth)
        if !content.notes.isEmpty {
            let joined = content.notes.joined(separator: "; ")
            reading.note = reading.note.map { $0 + "; " + joined } ?? joined
            if content.notes.contains(where: { $0.contains("not expanded") }), reading.state == .extracted { reading.state = .partial }
        }
        return reading
    }

    /// The text of a message (headers, body) and its attachments as children,
    /// each through the reader that fits it — shared by attached .eml, .msg
    /// and TNEF so the three arrive in the same shape.
    nonisolated private static func messageReading(_ email: MBOXParser.RawEmail, extractor: String, ocr: Bool, depth: Int) -> Reading {
        defer { for attachment in email.attachments { if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) } } }
        var text = ""
        for (key, label) in [("Subject", "Subject"), ("From", "From"), ("To", "To"), ("Date", "Date")] {
            if let value = email.headers[key], !value.isEmpty { text += "\(label): \(value)\n" }
        }
        let body = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
        text += "\n" + body + "\n"
        var notes: [String] = []
        var partial = false
        var children: [ChildDocument] = []
        for attachment in email.attachments {
            let data = attachment.fileURL.flatMap { try? Data(contentsOf: $0) } ?? attachment.base64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? Data()
            let child = read(attachment, ocr: ocr, depth: depth + 1)
            let state: ChildDocument.State
            switch child.state {
            case .extracted, .truncated: state = .extracted
            case .noText: state = .noText
            case .partial: state = .partial; partial = true; if let note = child.note { notes.append("\(attachment.filename): \(note)") }
            case .unsupported: state = .unsupported; partial = true; notes.append("\(attachment.filename) (\(child.note ?? "unsupported"))")
            case .locked: state = .locked; partial = true; notes.append("\(attachment.filename) (\(child.note ?? "locked"))")
            case .failed: state = .failed; partial = true; notes.append("\(attachment.filename) (\(child.note ?? "failed"))")
            }
            children.append(ChildDocument(path: attachment.filename, filename: attachment.filename,
                                          kind: (attachment.filename as NSString).pathExtension.lowercased(),
                                          sha256: ExportFolderManifest.hex(data), bytes: data.count,
                                          text: child.text, state: state, note: child.note))
            children.append(contentsOf: child.children.map { nested in
                var moved = nested; moved.path = attachment.filename + " › " + nested.path; return moved
            })
        }
        return Reading(text, partial ? .partial : .extracted, extractor, notes.isEmpty ? nil : String(localized: "not read: \(notes.joined(separator: "; "))"), children: children)
    }

    /// Is this attachment an Outlook message file (.msg / .oft, or the Outlook MIME type)?
    nonisolated static func isOutlookMessage(mimeType mime: String, filename: String, data: Data) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if mime.contains("vnd.ms-outlook") || ext == "msg" || ext == "oft" {
            return data.count >= 8 && data[data.startIndex] == 0xD0 && data[data.startIndex + 1] == 0xCF
        }
        return false
    }

    /// Is this attachment a TNEF wrapper (winmail.dat), by its bytes first and its name second?
    nonisolated static func isTNEF(mimeType mime: String, filename: String, data: Data) -> Bool {
        TNEFReader.isTNEF(data) || ((mime.contains("ms-tnef") || filename.lowercased() == "winmail.dat") && data.count >= 6)
    }

    /// One attachment through the extractor that fits it. `depth` counts
    /// messages inside messages (eml, msg, TNEF), bounded by `maxMessageDepth`.
    nonisolated private static func read(_ attachment: AttachmentMetadata, ocr: Bool, depth: Int = 0, password: String? = nil)
        -> Reading {
        _ = childReaderInstalled
        let data: Data?
        if let url = attachment.fileURL {
            data = try? Data(contentsOf: url)
        } else if let b64 = attachment.base64 {
            data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        } else {
            data = nil
        }
        guard let data, !data.isEmpty else {
            return Reading(nil, .failed, "none", String(localized: "attachment has no stored bytes"))
        }

        let mime = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()

        if mime.contains("pdf") || ext == "pdf" {
            guard let document = PDFDocument(data: data) else {
                return Reading(nil, .failed, "pdfkit", String(localized: "PDF could not be opened"))
            }
            if document.isLocked {
                // §13.8 step 5: a password the person typed opens it for this read.
                guard let password else { return Reading(nil, .locked, "pdfkit", String(localized: "password-protected PDF")) }
                guard document.unlock(withPassword: password) else {
                    return Reading(nil, .locked, "pdfkit", String(localized: "the password did not open the PDF"))
                }
            }
            let layer = document.string
            // E1: a PDF without a real text layer is read by OCR, page by page
            // (audit A06: text-layer pages and scanned pages mixed; every
            // failed page named, never "no text").
            if ocr, AttachmentOCR.pdfNeedsOCR(document) {
                return ocrState(AttachmentOCR.outcome(fromPDF: document), pages: document.pageCount)
            }
            if !ocr, AttachmentOCR.pdfNeedsOCR(document) {
                return Reading(nil, .unsupported, "pdfkit", String(localized: "scanned PDF — turn on attachment OCR to read it"))
            }
            return Reading(layer, .extracted, "pdfkit", nil)
        }
        if AttachmentOCR.isImage(mimeType: mime, filename: attachment.filename) {
            guard ocr else {
                return Reading(nil, .unsupported, "none", String(localized: "image — turn on attachment OCR to read it"))
            }
            return ocrState(AttachmentOCR.outcome(fromImageData: data), pages: 1)
        }
        // TYPE-05: audio and video — the spoken words, recognised on this device.
        if AttachmentSpeech.isMedia(mimeType: mime, filename: attachment.filename) {
            guard AttachmentSpeech.isEnabled else {
                return Reading(nil, .unsupported, "none", String(localized: "audio or video — turn on speech in attachments (Settings ▸ Modules) to read it"))
            }
            var url = attachment.fileURL
            var temporary: URL?
            if url == nil {
                let ext = (attachment.filename as NSString).pathExtension.lowercased()
                let t = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
                do { try data.write(to: t) } catch { return Reading(nil, .failed, "speech", error.localizedDescription) }
                temporary = t; url = t
            }
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            let transcript = AttachmentSpeech.transcribe(fileURL: url!)
            if let failure = transcript.failure, transcript.text == nil {
                return Reading(nil, transcript.notAuthorized ? .unsupported : .failed, "speech", failure)
            }
            let words = transcript.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if words.isEmpty { return Reading("", .noText, "speech", String(localized: "no speech was recognised in the recording")) }
            return Reading("[Recognised speech (\(transcript.locale ?? "?"))]\n" + words, .extracted, "speech", transcript.failure)
        }
        // §13.8 step 3: winmail.dat and Outlook message files are messages with files inside.
        if isTNEF(mimeType: mime, filename: attachment.filename, data: data) {
            return readTNEF(data, ocr: ocr, depth: depth)
        }
        if isOutlookMessage(mimeType: mime, filename: attachment.filename, data: data) {
            return readOutlookMessage(data, ocr: ocr, depth: depth)
        }
        // FIND-01 + TYPE-01…04: Office Open XML, OpenDocument, iWork, Office
        // 97–2003 and ZIP (one level inside) through the document facade —
        // before the text families, because their MIME types contain "xml"
        // and were once decoded as Latin-1 text, indexing bytes as words.
        // §13.8 step 5 (COMP-14): an S/MIME part is decoded with a key from the keychain only when the module is on.
        if mime.contains("pkcs7-mime") || ext == "p7m" {
            return readSMIME(data, ocr: ocr, depth: depth)
        }
        if let kind = DocumentKind.detect(mimeType: mime, filename: attachment.filename) {
            return readDocument(attachment, kind: kind, data: data, password: password)
        }
        // §13.8 step 4: an .xml that is a Microsoft Project plan is read as one, not as plain text.
        if ext == "xml", let kind = DocumentTextExtractor.sniff(head: data.prefix(4096)), kind == .projectXML {
            return readDocument(attachment, kind: kind, data: data)
        }
        // R04: an attached message is decoded as a message, with its own attachments as children.
        if mime.contains("message/rfc822") || ext == "eml" {
            return readEmbeddedMessage(data, ocr: ocr, depth: depth)
        }
        // A04: ZIP, tar and gzip attachments are read above (DocumentKind); these formats are not opened.
        let otherContainers: Set<String> = ["7z", "rar", "bz2", "xz"]
        if otherContainers.contains(ext) || mime.contains("x-7z") || mime.contains("x-rar") || mime.contains("bzip2") || mime.contains("x-xz") {
            return Reading(nil, .unsupported, "none", String(localized: "archive format not opened (7z, rar, bz2, xz) — ZIP, tar and gzip attachments are read; this one is kept as a file"))
        }
        if mime.contains("rtf") || ext == "rtf" {
            guard let text = (try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil))?.string else {
                return Reading(nil, .failed, "rtf", String(localized: "RTF could not be read"))
            }
            return Reading(text, .extracted, "rtf", nil)
        }
        if mime.contains("html") || ext == "html" || ext == "htm" {
            // Regex strip instead of NSAttributedString(html:) — the latter
            // requires the main thread (WebKit) and this runs detached.
            let html = String(data: data, encoding: .utf8) ?? ""
            return Reading(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression), .extracted, "html", nil)
        }
        let textualExts: Set<String> = ["txt", "csv", "log", "md", "json", "xml", "ics", "vcf", "yml", "yaml"]
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || textualExts.contains(ext) {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return Reading(nil, .failed, "text", String(localized: "text encoding not recognised"))
            }
            return Reading(text, .extracted, "text", nil)
        }
        // Binary formats without an extractor (docx/xlsx/pptx/zip/…): recorded
        // as unsupported; FIND-01 adds Office extraction and bumps the version
        // so these are retried.
        return Reading(nil, .unsupported, "none", nil)
    }
}
