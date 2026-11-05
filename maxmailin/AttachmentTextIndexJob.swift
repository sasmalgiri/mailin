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
    nonisolated static let extractorVersion = 3

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
                                            state: docState, extractorVersion: AttachmentTextIndexJob.extractorVersion, ocr: extractor == "ocr")
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
    nonisolated static func extractCoverage(fromRaw raw: String, ocr: Bool = false) -> [Extraction]? {
        guard let extraction = try? EmailBodyExtractor.extractContents(from: raw) else { return nil }
        var out: [Extraction] = []
        for (ordinal, attachment) in extraction.attachments.enumerated() {
            defer {
                if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) }
            }
            out.append(classify(attachment, ordinal: ordinal, ocr: ocr))
        }
        return out
    }

    /// The extracted text of one attachment, if any (whole, not cut at the cap).
    nonisolated static func extractText(from attachment: AttachmentMetadata, ocr: Bool = false) -> String? {
        read(attachment, ocr: ocr).text
    }

    /// FIND-03: read one attachment and say what happened. Text longer than
    /// the cap is cut and the state says so.
    nonisolated static func classify(_ attachment: AttachmentMetadata, ordinal: Int, ocr: Bool) -> Extraction {
        let result = read(attachment, ocr: ocr)
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
                          text: text, fullText: fullText, state: state, extractor: result.extractor, note: result.note)
    }

    /// FIND-01: an Office Open XML package. Needs a file: the extractor's
    /// temp file when there is one, otherwise the bytes written to one.
    nonisolated private static func readOffice(_ attachment: AttachmentMetadata, kind: OfficeTextExtractor.Kind, data: Data)
        -> (text: String?, state: AttachmentCoverageState, extractor: String, note: String?) {
        var url = attachment.fileURL
        var temporary: URL?
        if url == nil {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent("office-\(UUID().uuidString).\(kind.rawValue)")
            do { try data.write(to: t) } catch { return (nil, .failed, "office", error.localizedDescription) }
            temporary = t; url = t
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let result = try OfficeTextExtractor.extract(fileURL: url!, kind: kind)
            var note: String? = nil
            if !result.skipped.isEmpty {
                note = String(localized: "not read: \(result.skipped.joined(separator: "; "))")
            }
            return (result.text, result.partial ? .partial : .extracted, "office", note)
        } catch OfficeTextExtractor.ExtractError.encrypted {
            return (nil, .locked, "office", String(localized: "password-protected Office file"))
        } catch {
            return (nil, .failed, "office", error.localizedDescription)
        }
    }

    /// One attachment through the extractor that fits it.
    nonisolated private static func read(_ attachment: AttachmentMetadata, ocr: Bool)
        -> (text: String?, state: AttachmentCoverageState, extractor: String, note: String?) {
        let data: Data?
        if let url = attachment.fileURL {
            data = try? Data(contentsOf: url)
        } else if let b64 = attachment.base64 {
            data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        } else {
            data = nil
        }
        guard let data, !data.isEmpty else {
            return (nil, .failed, "none", String(localized: "attachment has no stored bytes"))
        }

        let mime = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()

        if mime.contains("pdf") || ext == "pdf" {
            guard let document = PDFDocument(data: data) else {
                return (nil, .failed, "pdfkit", String(localized: "PDF could not be opened"))
            }
            if document.isLocked {
                return (nil, .locked, "pdfkit", String(localized: "password-protected PDF"))
            }
            let layer = document.string
            // E1: a scanned PDF (no real text layer) is read by OCR, page by page.
            if ocr, AttachmentOCR.pdfNeedsOCR(text: layer, pageCount: document.pageCount),
               let scanned = AttachmentOCR.text(fromPDF: document) {
                let stamp = layer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (stamp.isEmpty ? scanned : stamp + "\n" + scanned, .extracted, "ocr", nil)
            }
            if !ocr, AttachmentOCR.pdfNeedsOCR(text: layer, pageCount: document.pageCount) {
                return (nil, .unsupported, "pdfkit", String(localized: "scanned PDF — turn on attachment OCR to read it"))
            }
            return (layer, .extracted, "pdfkit", nil)
        }
        if AttachmentOCR.isImage(mimeType: mime, filename: attachment.filename) {
            guard ocr else {
                return (nil, .unsupported, "none", String(localized: "image — turn on attachment OCR to read it"))
            }
            return (AttachmentOCR.text(fromImageData: data), .extracted, "ocr", nil)
        }
        // FIND-01: DOCX / XLSX / PPTX through the Office Open XML extractor.
        if let kind = OfficeTextExtractor.Kind.detect(mimeType: mime, filename: attachment.filename) {
            return readOffice(attachment, kind: kind, data: data)
        }
        // Other Office and compressed containers before the text families:
        // their MIME types contain "xml" ("…officedocument…") and were once
        // decoded as Latin-1 text, indexing bytes as words.
        let legacyOffice: Set<String> = ["doc", "xls", "ppt", "odt", "ods", "odp", "pages", "numbers", "key"]
        if legacyOffice.contains(ext) || mime.contains("msword") || mime.contains("ms-excel") || mime.contains("ms-powerpoint")
            || mime.contains("opendocument") {
            return (nil, .unsupported, "none", String(localized: "older Office or iWork format — only DOCX, XLSX and PPTX are read"))
        }
        let containerExts: Set<String> = ["zip", "gz", "tgz", "7z", "rar", "tar"]
        if mime.contains("zip") || mime.contains("compressed") || containerExts.contains(ext) {
            return (nil, .unsupported, "none", nil)
        }
        if mime.contains("rtf") || ext == "rtf" {
            guard let text = (try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil))?.string else {
                return (nil, .failed, "rtf", String(localized: "RTF could not be read"))
            }
            return (text, .extracted, "rtf", nil)
        }
        if mime.contains("html") || ext == "html" || ext == "htm" {
            // Regex strip instead of NSAttributedString(html:) — the latter
            // requires the main thread (WebKit) and this runs detached.
            let html = String(data: data, encoding: .utf8) ?? ""
            return (html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression), .extracted, "html", nil)
        }
        let textualExts: Set<String> = ["txt", "csv", "log", "md", "json", "xml", "ics", "vcf", "eml", "yml", "yaml"]
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || textualExts.contains(ext) {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return (nil, .failed, "text", String(localized: "text encoding not recognised"))
            }
            return (text, .extracted, "text", nil)
        }
        // Binary formats without an extractor (docx/xlsx/pptx/zip/…): recorded
        // as unsupported; FIND-01 adds Office extraction and bumps the version
        // so these are retried.
        return (nil, .unsupported, "none", nil)
    }
}
