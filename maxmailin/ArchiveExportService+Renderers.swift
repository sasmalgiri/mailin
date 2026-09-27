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
                         onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try await exportMessageFiles(scope: scope, to: folder, limit: limit, write: options, onProgress: onProgress) { email, index in
            guard let data = ExportManager.exportAsTIFF(email: email) else { return nil }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: "tiff"), data)
        }
    }

    /// PDFs: one PDF per message, rendered per message (bounded).
    @discardableResult
    func exportPDFFiles(scope: ArchiveSelectionScope, to folder: URL,
                        limit: Int? = nil,
                        write options: ExportWriteOptions = ExportWriteOptions(),
                        onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try await exportMessageFiles(scope: scope, to: folder, limit: limit, write: options, onProgress: onProgress) { email, index in
            let data = ExportManager.generateSinglePDFData(email: email)
            guard !data.isEmpty else { return nil }
            return (Self.messageFilename(index: index, subject: email.headers["Subject"], ext: "pdf"), data)
        }
    }

    /// Headers-only CSV.
    @discardableResult
    func exportHeadersCSV(scope: ArchiveSelectionScope, to url: URL,
                          limit: Int? = nil,
                          write options: ExportWriteOptions = ExportWriteOptions(),
                          onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
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
                              onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        var total = 0
        return try await exportTextDocument(
            scope: scope, to: url, write: options,
            header: { t in total = t; return "" },
            onProgress: onProgress
        ) { email, index in
            ExportManager.batchPrintBlock(email: email, index: index, total: total)
        }
    }

    @discardableResult
    func exportPortableHTML(scope: ArchiveSelectionScope, to folder: URL,
                            limit: Int? = nil,
                            onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cap = min(limit ?? Self.portableHTMLMaxEmails, Self.portableHTMLMaxEmails)
        let url = folder.appendingPathComponent("index.html")
        var first = true
        return try await exportTextDocument(
            scope: scope, to: url, limit: cap,
            header: { total in ExportManager.portableHTMLPrefix(emailCount: total) },
            footer: { _ in ExportManager.portableHTMLSuffix },
            onProgress: onProgress
        ) { email, _ in
            guard let entry = ExportManager.portableHTMLEntryJSON(email: email) else { return "" }
            defer { first = false }
            return (first ? "" : ",") + entry
        }
    }

    /// vCard: contacts are a SMALL derived record (distinct addresses), but the
    /// source is the streamed scope — never a preview array.
    @discardableResult
    func exportVCard(scope: ArchiveSelectionScope, to url: URL,
                     onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
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
                   onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
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
