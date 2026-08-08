//
//  UnifiedExportMenu.swift
//  maxmailin
//
//  THE one export format list. Every export surface — the sidebar's
//  "Export Emails", the email list footer's "Export", and the open-email
//  "Export Email" menu — embeds these sections over its own scope, so the
//  formats offered are identical everywhere. Hosts that already provide a
//  single-email rendition of a format (the detail view's Word/CSV/PDF/TIFF/
//  plain-text buttons) omit the overlapping entries instead of duplicating.
//
//  Every export streams the scope through ArchiveExportService (bounded
//  memory at any archive size), runs in the ExportRunCenter with progress,
//  caps the free tier at StoreManager.freeEmailLimit with an honest
//  "Exported X of Y" notice + paywall, and reports failures through the
//  host's error binding (menus can't host alerts themselves).
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

enum UnifiedExportFormat: CaseIterable {
    case word, csv, json, printText      // single-document formats
    case emlFiles, pdfFiles, tiffFiles   // one file per email
    case portableHTML                    // folder with index.html viewer
    case vcard, ics                      // derived extracts
}

struct UnifiedExportSections: View {
    /// Scope resolved at CLICK time (current filtered query / this email).
    let scope: () -> ArchiveSelectionScope
    /// Gate run before any export. Bulk surfaces pass the default (free tier
    /// exports capped); the detail view passes requirePremium (its policy).
    var gate: () -> Bool = { true }
    /// v1-faithful RFC-822 renderer for .eml (default: stored raw source).
    var emlRender: (@MainActor (MBOXParser.RawEmail) -> String)? = nil
    /// Formats the host already offers with its own (single-email) rendition.
    var omit: Set<UnifiedExportFormat> = []
    /// iOS delivery: hand the finished artifact to the host's share sheet.
    var share: (URL) -> Void = { _ in }
    @Binding var errorMessage: String?

    @EnvironmentObject private var storeManager: StoreManager

    var body: some View {
        if included(.word) {
            button("Word Document (.doc)", icon: "doc.richtext") { exportWord() }
        }
        if included(.csv) {
            button("Spreadsheet (.csv)", icon: "tablecells") { exportCSV() }
        }
        if included(.json) {
            button("JSON Archive", icon: "curlybraces") { exportJSON() }
        }
        if included(.printText) {
            button("Batch Print Text (.txt)", icon: "printer") { exportPrintText() }
        }
        if !omit.isSuperset(of: [.emlFiles, .pdfFiles, .tiffFiles]) { Divider() }
        if included(.emlFiles) {
            button("Individual .eml Files", icon: "envelope") { exportEML() }
        }
        if included(.pdfFiles) {
            button("PDF Files (one per email)", icon: "doc.viewfinder") { exportPDFs() }
        }
        if included(.tiffFiles) {
            button("TIFF Images (one per email)", icon: "photo") { exportTIFFs() }
        }
        Divider()
        if included(.portableHTML) {
            button("Portable HTML Viewer", icon: "globe") { exportHTML() }
        }
        if included(.vcard) {
            button("Contacts (vCard)", icon: "person.crop.rectangle.stack") { exportVCard() }
        }
        if included(.ics) {
            button("Calendar Events (.ics)", icon: "calendar") { exportICS() }
        }
    }

    private func included(_ format: UnifiedExportFormat) -> Bool { !omit.contains(format) }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
    }

    // MARK: - Shared plumbing

    private var cap: Int? { storeManager.isPremium ? nil : StoreManager.freeEmailLimit }

    private func timestampName(_ base: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(base)_\(formatter.string(from: Date())).\(ext)"
    }

    /// Save-panel destination for single-document formats.
    private func documentDestination(_ name: String, type: UTType?) -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let type { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
        #else
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
        #endif
    }

    /// Folder destination for per-message-file formats.
    private func folderDestination(message: String, fallbackName: String) -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fallbackName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #endif
    }

    private func run(_ title: String,
                     _ body: @escaping @MainActor (ArchiveExportService) async throws -> Void) {
        guard gate() else { return }
        ExportRunCenter.shared.run(title: title) {
            do {
                try await body(ArchiveExportService.shared)
            } catch {
                errorMessage = "\(title) failed: \(error.localizedDescription)"
            }
        }
    }

    /// Free-tier honesty: when the cap truncated the export, say exactly how
    /// much was written and open the paywall.
    @MainActor
    private func handleCap(written: Int, cancelled: Bool, what: String,
                           scope: ArchiveSelectionScope, deliver: URL?) async {
        if cancelled {
            errorMessage = "\(what) export cancelled — partial output removed."
            return
        }
        if let cap {
            let total = (try? await ArchiveDataService.shared.count(scope: scope)) ?? written
            if total > cap {
                storeManager.showPaywall = true
                errorMessage = "Exported \(written) of \(total) emails. Upgrade to Pro for unlimited export."
            }
        }
        #if os(iOS)
        if let deliver { share(deliver) }
        #else
        _ = deliver
        #endif
    }

    // MARK: - Formats

    private func exportWord() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "doc"), type: nil) else { return }
        let scope = scope(), cap = cap
        run("Exporting Word document") { service in
            let result = try await service.exportWordArchive(
                scope: scope, to: url, limit: cap,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "Word", scope: scope, deliver: url)
        }
    }

    private func exportCSV() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "csv"), type: .commaSeparatedText) else { return }
        let scope = scope(), cap = cap
        run("Exporting CSV") { service in
            let result = try await service.exportDetailedCSV(
                scope: scope, to: url, limit: cap,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "CSV", scope: scope, deliver: url)
        }
    }

    private func exportJSON() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "json"), type: .json) else { return }
        let scope = scope(), cap = cap
        run("Exporting JSON") { service in
            let result = try await service.exportJSONArchive(
                scope: scope, to: url, limit: cap,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "JSON", scope: scope, deliver: url)
        }
    }

    private func exportPrintText() {
        guard let url = documentDestination(timestampName("mailin_print", ext: "txt"), type: .plainText) else { return }
        let scope = scope()
        run("Exporting print text") { service in
            let result = try await service.exportBatchPrintText(
                scope: scope, to: url,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "Print text", scope: scope, deliver: url)
        }
    }

    private func exportEML() {
        guard let folder = folderDestination(message: "Select a folder to save .eml files",
                                             fallbackName: "eml_export_\(UUID().uuidString)") else { return }
        let scope = scope(), cap = cap, render = emlRender
        run("Exporting emails as EML") { service in
            let result = try await service.exportEMLFiles(
                scope: scope, to: folder, limit: cap, render: render,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "EML", scope: scope, deliver: folder)
        }
    }

    private func exportPDFs() {
        guard let folder = folderDestination(message: "Select a folder to save PDF files",
                                             fallbackName: "pdf_export_\(UUID().uuidString)") else { return }
        let scope = scope(), cap = cap
        run("Exporting PDFs") { service in
            let result = try await service.exportPDFFiles(
                scope: scope, to: folder, limit: cap,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "PDF", scope: scope, deliver: folder)
        }
    }

    private func exportTIFFs() {
        guard let folder = folderDestination(message: "Select a folder to save TIFF images",
                                             fallbackName: "tiff_export_\(UUID().uuidString)") else { return }
        let scope = scope(), cap = cap
        run("Exporting TIFF images") { service in
            let result = try await service.exportTIFFFiles(
                scope: scope, to: folder, limit: cap,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "TIFF", scope: scope, deliver: folder)
        }
    }

    private func exportHTML() {
        guard let base = folderDestination(message: "Select a folder for the portable HTML export",
                                           fallbackName: "html_export_\(UUID().uuidString)") else { return }
        let folder = base.appendingPathComponent("mailin_html_export")
        let scope = scope(), cap = cap
        run("Exporting portable HTML") { service in
            let result = try await service.exportPortableHTML(
                scope: scope, to: folder, limit: cap,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            await handleCap(written: result.recordsWritten, cancelled: result.cancelled,
                            what: "HTML", scope: scope, deliver: folder)
        }
    }

    private func exportVCard() {
        guard let url = documentDestination(timestampName("mailin_contacts", ext: "vcf"), type: .vCard) else { return }
        let scope = scope()
        run("Exporting contacts") { service in
            _ = try await service.exportVCard(
                scope: scope, to: url,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            #if os(iOS)
            share(url)
            #endif
        }
    }

    private func exportICS() {
        guard let url = documentDestination(timestampName("mailin_events", ext: "ics"), type: UTType(filenameExtension: "ics")) else { return }
        let scope = scope()
        run("Exporting calendar events") { service in
            _ = try await service.exportICS(
                scope: scope, to: url,
                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
            #if os(iOS)
            share(url)
            #endif
        }
    }
}
