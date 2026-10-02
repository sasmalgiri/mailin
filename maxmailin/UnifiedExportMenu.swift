@testable import ArchiveCore
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
//  A8: a format button only picks the destination and builds an
//  `ExportRequest`. The request goes to the run center's pre-flight sheet
//  (folder layout, attachments, collision rule, size estimate against the
//  destination's free space); Start hands it to `ExportJobRunner`, which
//  streams the scope through ArchiveExportService (bounded memory at any
//  archive size), caps the free tier at StoreManager.freeEmailLimit with an
//  honest "Exported X of Y" notice + paywall, and ends every run — complete,
//  truncated, cancelled or failed — in an `ExportReceipt`.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers


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
    /// Exact number of emails the scope will export (shown as the menu
    /// header so the user knows the size BEFORE picking a format).
    var emailCount: Int? = nil
    /// The host's policy locks these formats behind Premium (detail view).
    /// Free users still SEE every option — labeled "(Pro)" — so the full
    /// feature surface is discoverable; clicking opens the paywall.
    var requiresPremium: Bool = false
    /// iOS delivery: hand the finished artifact to the host's share sheet.
    var share: (URL) -> Void = { _ in }
    @Binding var errorMessage: String?

    @EnvironmentObject private var storeManager: StoreManager

    var body: some View {
        if let headline = countHeadline {
            Section(headline) { EmptyView() }
        }
        if included(.word) {
            button("Word Document (.doc)", icon: "doc.richtext",
                   help: "One Word document, one page per email") { exportWord() }
        }
        if included(.csv) {
            button("Spreadsheet (.csv)", icon: "tablecells",
                   help: "One row per email — opens in Excel/Numbers") { exportCSV() }
        }
        if included(.json) {
            button("JSON Archive", icon: "curlybraces",
                   help: "Machine-readable full archive") { exportJSON() }
        }
        if included(.printText) {
            button("Batch Print Text (.txt)", icon: "printer",
                   help: "Plain text ready for printing") { exportPrintText() }
        }
        if included(.markdown) {
            button("Markdown (.md)", icon: "number",
                   help: "Notes-friendly document — Obsidian, GitHub") { exportMarkdown() }
        }
        if included(.headersCSV) {
            button("Headers-Only CSV", icon: "list.bullet.rectangle",
                   help: "Metadata only, no bodies — safe to share") { exportHeadersOnly() }
        }
        if included(.mbox) {
            button("mbox Archive", icon: "archivebox",
                   help: "Standard mailbox file — reimportable anywhere") { exportMBOX() }
        }
        if !omit.isSuperset(of: [.emlFiles, .pdfFiles, .tiffFiles]) { Divider() }
        if included(.emlFiles) {
            button("Individual .eml Files", icon: "envelope",
                   help: "One standard email file each — reimportable") { exportEML() }
        }
        if included(.pdfFiles) {
            button("PDF Files (one per email)", icon: "doc.viewfinder",
                   help: "One PDF per email") { exportPDFs() }
        }
        if included(.tiffFiles) {
            button("TIFF Images (one per email)", icon: "photo",
                   help: "Court-friendly image per email") { exportTIFFs() }
        }
        if included(.msgFiles) {
            button("Outlook Messages (.msg)", icon: "envelope.badge",
                   help: "One Outlook-compatible file per email") { exportMSGs() }
        }
        Divider()
        if included(.portableHTML) {
            button("Portable HTML Viewer", icon: "globe",
                   help: "Self-contained browser viewer folder") { exportHTML() }
        }
        if included(.vcard) {
            button("Contacts (vCard)", icon: "person.crop.rectangle.stack",
                   help: "Every address as importable contacts") { exportVCard() }
        }
        if included(.ics) {
            button("Calendar Events (.ics)", icon: "calendar",
                   help: "Detected events as a calendar file") { exportICS() }
        }
    }

    /// "Export 222 emails (current filter)" — plus the free-tier bound when
    /// it will actually bite.
    private var countHeadline: String? {
        guard let emailCount else { return nil }
        var text = emailCount == 1 ? "Export 1 email" : "Export \(emailCount) emails (current filter)"
        if !storeManager.isPremium && emailCount > StoreManager.freeEmailLimit {
            text += " — free exports first \(StoreManager.freeEmailLimit)"
        }
        return text
    }

    private func included(_ format: UnifiedExportFormat) -> Bool { !omit.contains(format) }

    private func button(_ title: String, icon: String, help: String,
                        action: @escaping () -> Void) -> some View {
        let locked = requiresPremium && !storeManager.isPremium
        return Button(action: action) {
            Label(locked ? "\(title) (Pro)" : title, systemImage: locked ? "lock" : icon)
        }
        .help(locked ? "\(help) — unlocked with Pro" : help)
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

    /// Build the request and send it to the pre-flight sheet. The runner is
    /// given this host's renderer, share sheet, error binding and store so a
    /// later Resume behaves the same way.
    private func request(_ format: UnifiedExportFormat, title: String, destination: URL, isFolder: Bool) {
        guard gate() else { return }
        let runner = ExportJobRunner.shared
        runner.emlRender = emlRender
        runner.share = share
        runner.storeManager = storeManager
        runner.onError = { message in errorMessage = message }
        ExportRunCenter.shared.requestPreflight(ExportRequest(
            format: format,
            title: title,
            scope: scope(),
            destination: destination.path,
            isFolder: isFolder,
            cap: cap,
            emailCountHint: emailCount))
    }

    // MARK: - Formats

    private func exportWord() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "doc"), type: nil) else { return }
        request(.word, title: String(localized: "Exporting Word document"), destination: url, isFolder: false)
    }

    private func exportCSV() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "csv"), type: .commaSeparatedText) else { return }
        request(.csv, title: String(localized: "Exporting CSV"), destination: url, isFolder: false)
    }

    private func exportJSON() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "json"), type: .json) else { return }
        request(.json, title: String(localized: "Exporting JSON"), destination: url, isFolder: false)
    }

    private func exportPrintText() {
        guard let url = documentDestination(timestampName("mailin_print", ext: "txt"), type: .plainText) else { return }
        request(.printText, title: String(localized: "Exporting print text"), destination: url, isFolder: false)
    }

    private func exportEML() {
        guard let folder = folderDestination(message: String(localized: "Select a folder to save .eml files"),
                                             fallbackName: "eml_export_\(UUID().uuidString)") else { return }
        request(.emlFiles, title: String(localized: "Exporting emails as EML"), destination: folder, isFolder: true)
    }

    private func exportPDFs() {
        guard let folder = folderDestination(message: String(localized: "Select a folder to save PDF files"),
                                             fallbackName: "pdf_export_\(UUID().uuidString)") else { return }
        request(.pdfFiles, title: String(localized: "Exporting PDFs"), destination: folder, isFolder: true)
    }

    private func exportTIFFs() {
        guard let folder = folderDestination(message: String(localized: "Select a folder to save TIFF images"),
                                             fallbackName: "tiff_export_\(UUID().uuidString)") else { return }
        request(.tiffFiles, title: String(localized: "Exporting TIFF images"), destination: folder, isFolder: true)
    }

    private func exportHTML() {
        guard let base = folderDestination(message: String(localized: "Select a folder for the portable HTML export"),
                                           fallbackName: "html_export_\(UUID().uuidString)") else { return }
        let folder = base.appendingPathComponent("mailin_html_export")
        request(.portableHTML, title: String(localized: "Exporting portable HTML"), destination: folder, isFolder: true)
    }

    private func exportMarkdown() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "md"), type: .plainText) else { return }
        request(.markdown, title: String(localized: "Exporting Markdown"), destination: url, isFolder: false)
    }

    private func exportHeadersOnly() {
        guard let url = documentDestination(timestampName("mailin_headers", ext: "csv"), type: .commaSeparatedText) else { return }
        request(.headersCSV, title: String(localized: "Exporting headers CSV"), destination: url, isFolder: false)
    }

    private func exportMBOX() {
        guard let url = documentDestination(timestampName("mailin_emails", ext: "mbox"), type: nil) else { return }
        request(.mbox, title: String(localized: "Exporting mbox"), destination: url, isFolder: false)
    }

    private func exportMSGs() {
        guard let folder = folderDestination(message: String(localized: "Select a folder to save .msg files"),
                                             fallbackName: "msg_export_\(UUID().uuidString)") else { return }
        request(.msgFiles, title: String(localized: "Exporting Outlook messages"), destination: folder, isFolder: true)
    }

    private func exportVCard() {
        guard let url = documentDestination(timestampName("mailin_contacts", ext: "vcf"), type: .vCard) else { return }
        request(.vcard, title: String(localized: "Exporting contacts"), destination: url, isFolder: false)
    }

    private func exportICS() {
        guard let url = documentDestination(timestampName("mailin_events", ext: "ics"), type: UTType(filenameExtension: "ics")) else { return }
        request(.ics, title: String(localized: "Exporting calendar events"), destination: url, isFolder: false)
    }
}
