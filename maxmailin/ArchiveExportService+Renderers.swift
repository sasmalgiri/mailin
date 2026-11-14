//
//  ArchiveExportService+Renderers.swift
//  maxmailin
//
//  C-1 boundary: these writers render through `ExportManager` (PDF and TIFF
//  drawing, the HTML viewer, print blocks, vCard/ICS extraction), which is
//  AppKit/SwiftUI-bound and therefore lives in the app. They sit here as an
//  extension over ArchiveCore's streaming pipeline — nothing about how they
//  write changed.
//

import Foundation
@testable import ArchiveCore

extension ArchiveExportService {

    /// TIFF: one multi-page TIFF per message, rendered per message (bounded).
    @discardableResult
    func exportTIFFFiles(scope: ArchiveSelectionScope, to folder: URL,
                         limit: Int? = nil,
                         write options: ExportWriteOptions = ExportWriteOptions(),
                         onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
                        onProduced: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let result = try await exportMessageFiles(scope: scope, to: folder, limit: limit, write: options, onProgress: onProgress, onProduced: onProduced) { email, index in
            guard let data = ExportManager.exportAsTIFF(email: email) else { return nil }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: "tiff"), data)
        }
        // V4: connected mail in the folder → its provenance sidecar, as for EML.
        return await withProvenanceSidecar(result, folder: folder)
    }

    /// PDFs: one PDF per message, rendered per message (bounded).
    @discardableResult
    func exportPDFFiles(scope: ArchiveSelectionScope, to folder: URL,
                        limit: Int? = nil,
                        write options: ExportWriteOptions = ExportWriteOptions(),
                        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
                        onProduced: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let result = try await exportMessageFiles(scope: scope, to: folder, limit: limit, write: options, onProgress: onProgress, onProduced: onProduced) { email, index in
            let data = ExportManager.generateSinglePDFData(email: email)
            guard !data.isEmpty else { return nil }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: "pdf"), data)
        }
        // V4: connected mail in the folder → its provenance sidecar, as for EML.
        return await withProvenanceSidecar(result, folder: folder)
    }

    /// Headers-only CSV.
    @discardableResult
    func exportHeadersCSV(scope: ArchiveSelectionScope, to url: URL,
                          limit: Int? = nil,
                          write options: ExportWriteOptions = ExportWriteOptions(),
                          onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try await exportTextDocument(
            scope: scope, to: url, limit: limit, write: options,
            header: { _ in ExportManager.headersOnlyCSVHeaderRow() },
            onProgress: onProgress
        ) { email, _ in
            ExportManager.headersOnlyCSVRow(email: email)
        }
    }

    /// Batch print text — one continuous printable text file, streamed.
    @discardableResult
    func exportBatchPrintText(scope: ArchiveSelectionScope, to url: URL,
                              write options: ExportWriteOptions = ExportWriteOptions(),
                              onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        var total = 0
        return try await exportTextDocument(
            scope: scope, to: url, write: options,
            header: { t in total = t; return "" },
            onProgress: onProgress
        ) { email, index in
            ExportManager.batchPrintBlock(email: email, index: index, total: total)
        }
    }

    /// CAP-04 (owner 2026-11-06, no hidden caps): the portable viewer has no
    /// message cap. Messages are written in `data/part-NNNN.js` chunks of
    /// `portableHTMLChunkSize`, streamed from the scope, and `index.html`
    /// loads them one after another. `limit` is only the plan's cap.
    static let portableHTMLChunkSize = 2_000

    @discardableResult
    func exportPortableHTML(scope: ArchiveSelectionScope, to folder: URL,
                            limit: Int? = nil,
                            onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let fm = FileManager.default
        let dataFolder = folder.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let total = try await boundedTotal(scope: scope, limit: limit)
        var written = 0, skipped = 0, bytes = 0, parts = 0, inChunk = 0, cancelled = false
        var handle: FileHandle?
        var partFiles: [URL] = []

        func openPart() throws {
            parts += 1
            let url = dataFolder.appendingPathComponent(String(format: "part-%04d.js", parts))
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw ArchiveExportError.nothingToExport("the viewer's data file could not be created at \(url.path)")
            }
            let h = try FileHandle(forWritingTo: url)
            partFiles.append(url)
            let opening = Data("mailinChunk([\n".utf8)
            try h.write(contentsOf: opening); bytes += opening.count
            handle = h; inChunk = 0
        }
        func closePart() throws {
            guard let h = handle else { return }
            let closing = Data("\n]);\n".utf8)
            try h.write(contentsOf: closing); bytes += closing.count
            try h.close(); handle = nil
        }
        func cleanup() {
            try? handle?.close(); handle = nil
            for url in partFiles { try? fm.removeItem(at: url) }
            try? fm.removeItem(at: dataFolder)
        }

        do {
            stream: for try await batch in archive.streamSelected(scope: scope) {
                if Task.isCancelled { cancelled = true; break }
                for email in batch {
                    if let limit, written >= limit { break stream }
                    guard let entry = ExportManager.portableHTMLEntryJSON(email: email) else { skipped += 1; continue }
                    if handle == nil || inChunk >= Self.portableHTMLChunkSize { try closePart(); try openPart() }
                    let line = Data(((inChunk == 0 ? "" : ",\n") + entry).utf8)
                    try handle?.write(contentsOf: line)
                    bytes += line.count; inChunk += 1; written += 1
                }
                onProgress?(written, total)
            }
            try closePart()
        } catch {
            cleanup()
            throw error
        }
        if cancelled || Task.isCancelled {
            cleanup()
            return ArchiveExportResult(recordsWritten: 0, bytesWritten: 0, completed: false, cancelled: true, skipped: skipped)
        }
        let viewer = ExportManager.portableHTMLViewer(total: written, parts: parts, chunkSize: Self.portableHTMLChunkSize)
        try viewer.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return ArchiveExportResult(recordsWritten: written, bytesWritten: bytes + viewer.utf8.count, completed: true, cancelled: false, skipped: skipped)
    }

    /// vCard: contacts are a SMALL derived record (distinct addresses), but the
    /// source is the streamed scope — never a preview array.
    @discardableResult
    func exportVCard(scope: ArchiveSelectionScope, to url: URL,
                     onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        var contacts: [String: (name: String, email: String)] = [:]
        var done = 0
        let total = try await archive.count(scope: scope)
        for try await batch in archive.streamSelected(scope: scope) {
            try Task.checkCancellation()
            for email in batch { ExportManager.collectContacts(from: email, into: &contacts) }
            done += batch.count
            onProgress?(done, total)
        }
        guard let data = ExportManager.vcardData(contacts: contacts) else {
            throw ArchiveExportError.nothingToExport("contacts")
        }
        try data.write(to: url, options: .atomic)
        return contacts.count
    }

    /// ICS: calendar events are small derived records extracted while streaming;
    /// written incrementally. Returns the event count (0 → file removed, error).
    @discardableResult
    func exportICS(scope: ArchiveSelectionScope, to url: URL,
                   onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        var events = 0
        let result = try await exportTextDocument(
            scope: scope, to: url,
            header: { _ in "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//mailin//EN\r\n" },
            footer: { _ in "END:VCALENDAR\r\n" },
            onProgress: onProgress
        ) { email, _ in
            let blocks = ExportManager.calendarEventBlocks(from: email)
            events += blocks.count
            return blocks.joined()
        }
        if result.cancelled { return 0 }
        if events == 0 {
            try? FileManager.default.removeItem(at: url)
            throw ArchiveExportError.nothingToExport("calendar events")
        }
        return events
    }
}
