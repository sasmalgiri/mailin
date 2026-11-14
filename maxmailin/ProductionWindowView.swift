@testable import ArchiveCore
//
//  ProductionWindowView.swift
//  maxmailin
//
//  F-4: the production window. One run turns a scope into a produced set:
//  requested / included / excluded counts, attachment families, a Bates
//  sequence stamped on one PDF per message, a SHA-256 manifest, an exclusion
//  log with the reason per message, and a numbered production record
//  (`DocumentRegistry`) that is the signed-off version. Streams the scope
//  in bounded batches; ends in an `ExportReceipt` like every other export.
//

import SwiftUI
import CryptoKit
#if os(macOS)
import AppKit
#endif

struct ProductionRun: Codable, Equatable, Sendable {
    var productionNumber: String?
    var title: String
    var caseNumber: String
    var requested: Int
    var included: Int
    var excluded: Int
    var excludedByTag: Int
    var excludedOnHold: Int
    /// Audit F05: messages whose content the archive could not supply —
    /// imported from headers only (above the full-parse ceiling) or with the
    /// original file gone. Withheld with the reason in excluded.csv, never
    /// produced as a headers-only PDF over an empty hash.
    var excludedNoContent: Int = 0
    var firstBates: String?
    var lastBates: String?
    var pages: Int
    var attachmentFamilies: [String: Int]
    var folder: String
    var manifestSHA256: String?
    var seconds: Double

    var summary: String {
        "\(included) of \(requested) produced (\(excluded) excluded), Bates \(firstBates ?? "—")–\(lastBates ?? "—"), \(pages) pages"
    }
}

struct ProductionWindowView: View {
    @Environment(ModuleRegistry.self) private var modules
    @ObservedObject private var bates = BatesNumberingManager.shared
    @State private var title = "Production"
    @State private var caseNumber = ""
    @State private var excludeTag = "Privileged"
    @State private var excludeHeld = false
    @State private var scopeText = ""
    @State private var destination: URL?
    @State private var isRunning = false
    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var result: ProductionRun?
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var showPicker = false
    #endif

    var body: some View {
        Form {
            Section("What") {
                TextField("Production title", text: $title)
                TextField("Case / matter number", text: $caseNumber)
                TextField("Scope (search operators; empty = whole archive)", text: $scopeText)
                    .help("The same syntax as the search field: from:, tag:, after:, source:… Empty produces the whole archive.")
            }
            Section("Exclusions") {
                TextField("Exclude messages tagged", text: $excludeTag)
                    .help("Any message carrying this user tag or parser label is withheld and logged with the reason")
                Toggle("Also withhold messages under legal hold", isOn: $excludeHeld)
                    .help("Holds are never lifted by a production; this only decides whether held messages are produced")
            }
            Section("Bates") {
                TextField("Prefix", text: $bates.prefix)
                Stepper("Start at \(bates.startNumber)", value: $bates.startNumber, in: 1...999_999_999)
                Stepper("Zero padding \(bates.zeroPadding)", value: $bates.zeroPadding, in: 1...12)
                Text("Next number: \(bates.formatNumber(bates.startNumber)). The sequence continues from the last number after this run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Where") {
                HStack {
                    Text(destination?.path ?? "No folder chosen")
                        .font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }.disabled(isRunning)
                }
            }
            Section {
                Button(isRunning ? String(localized: "Producing…") : String(localized: "Produce")) { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil || isRunning || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("production.run")
                if isRunning, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                    Text("\(progress.done) of \(progress.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
            if let result {
                Section("Production record") {
                    if let number = result.productionNumber {
                        LabeledContent("Production number", value: number)
                    }
                    LabeledContent("Requested", value: "\(result.requested)")
                    LabeledContent("Included", value: "\(result.included)")
                    LabeledContent("Excluded", value: "\(result.excluded) (\(result.excludedByTag) by tag, \(result.excludedOnHold) on hold)")
                    LabeledContent("Bates range", value: "\(result.firstBates ?? "—") – \(result.lastBates ?? "—")")
                    LabeledContent("Pages", value: "\(result.pages)")
                    LabeledContent("Attachment families", value: result.attachmentFamilies.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                    if let hash = result.manifestSHA256 {
                        LabeledContent("Manifest SHA-256") { Text(hash).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                    #if os(macOS)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.folder)]) }
                    #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Production")
        #if os(iOS)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { destination = url }
        }
        #endif
    }

    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose where to write the production set"
        panel.prompt = "Produce here"
        if panel.runModal() == .OK { destination = panel.url }
        #else
        showPicker = true
        #endif
    }

    // MARK: Run

    private func run() async {
        guard let destination else { return }
        isRunning = true
        errorMessage = nil
        result = nil
        defer { isRunning = false }
        do {
            result = try await ProductionEngine.produce(
                title: title, caseNumber: caseNumber,
                scope: .query(ArchiveQueryCompiler.compile(scopeText), exclusions: []),
                excludeTag: excludeTag.trimmingCharacters(in: .whitespaces),
                excludeHeld: excludeHeld,
                into: destination,
                bates: bates,
                onProgress: { done, total in Task { @MainActor in progress = (done, total) } })
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Engine

enum ProductionError: LocalizedError {
    /// Tags or holds could not be read, so exclusions could not be applied.
    case exclusionMetadataUnavailable(underlying: String)

    var errorDescription: String? {
        switch self {
        case .exclusionMetadataUnavailable(let why):
            return "Exclusion tags could not be read (\(why)); the production was stopped rather than risk releasing a withheld document."
        }
    }
}

enum ProductionEngine {

    static func attachmentFamily(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "pages", "numbers", "key": return "documents"
        case "jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "bmp", "webp": return "images"
        case "zip", "gz", "7z", "rar", "tar": return "archives"
        case "eml", "msg", "emlx": return "messages"
        case "": return "unnamed"
        default: return "other"
        }
    }

    @MainActor
    static func produce(title: String, caseNumber: String, scope: ArchiveSelectionScope,
                        excludeTag: String, excludeHeld: Bool, into destination: URL,
                        bates: BatesNumberingManager,
                        archive: ArchiveDataService = .shared,
                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ProductionRun {
        let clock = ContinuousClock(); let start = clock.now
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = destination.appendingPathComponent("production-\(stamp)", isDirectory: true)
        let pdfFolder = folder.appendingPathComponent("PDF", isDirectory: true)
        try fm.createDirectory(at: pdfFolder, withIntermediateDirectories: true)

        let requested = try await archive.count(scope: scope)
        var included = 0, excludedByTag = 0, excludedOnHold = 0, excludedNoContent = 0, pages = 0
        var families: [String: Int] = [:]
        var firstBates: String?, lastBates: String?
        var number = bates.startNumber
        var assignments: [UUID: String] = [:]

        var manifest = "BatesNumber,EmailID,MessageID,Date,From,Subject,Attachments,SHA256,PDFSHA256\n"
        var exclusions = "EmailID,MessageID,Subject,Reason\n"
        func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

        let holds = CustodianManager.shared.legalHolds
        var done = 0
        do {
        for try await batch in archive.streamSelected(scope: scope, batchSize: 100) {
            try Task.checkCancellation()
            // Audit F09a: exclusion metadata that cannot be read fails the run.
            // Substituting "no tags" would release documents the tag was
            // meant to withhold.
            let tagsByID: [UUID: Set<String>]
            do {
                tagsByID = try await archive.userTags(ids: batch.map(\.id))
            } catch {
                throw ProductionError.exclusionMetadataUnavailable(underlying: error.localizedDescription)
            }
            for email in batch {
                done += 1
                let messageID = email.headers["Message-ID"] ?? ""
                let subject = email.headers["Subject"] ?? ""
                // Exclusions, each logged with its reason.
                if !excludeTag.isEmpty,
                   (tagsByID[email.id]?.contains(excludeTag) == true) || email.tags.contains(excludeTag) {
                    excludedByTag += 1
                    exclusions += [email.id.uuidString, messageID, subject, "tagged \(excludeTag)"].map(csv).joined(separator: ",") + "\n"
                    continue
                }
                if excludeHeld, holds.contains(email.id) {
                    excludedOnHold += 1
                    exclusions += [email.id.uuidString, messageID, subject, "under legal hold"].map(csv).joined(separator: ",") + "\n"
                    continue
                }
                // F05: a message with no stored content cannot be produced
                // honestly here — a PDF of its headers over a hash of "" would
                // claim completeness it does not have. Withheld, with the
                // reason and the way to get it (MBOX/EML export streams it).
                if email.rawSource.isEmpty, email.plainBody.isEmpty, email.htmlBody.isEmpty {
                    let reason: String
                    switch await archive.rawMessageSource(for: email) {
                    case .located:
                        reason = "content not decoded at import (message above the full-parse ceiling) — export it as MBOX or EML, which stream it from the original file"
                    case .unavailable(let why):
                        reason = "content unavailable: \(why)"
                    case .stored:
                        reason = "no content"
                    }
                    excludedNoContent += 1
                    exclusions += [email.id.uuidString, messageID, subject, reason].map(csv).joined(separator: ",") + "\n"
                    continue
                }
                // Bates + PDF.
                let batesNumber = bates.formatNumber(number)
                number += 1
                assignments[email.id] = batesNumber
                if firstBates == nil { firstBates = batesNumber }
                lastBates = batesNumber
                var lines: [String] = []
                for key in ["From", "To", "Cc", "Date", "Subject", "Message-ID"] {
                    if let v = email.headers[key], !v.isEmpty { lines.append("\(key): \(v)") }
                }
                if !email.attachments.isEmpty {
                    lines.append("Attachments: " + email.attachments.map(\.filename).joined(separator: ", "))
                }
                lines.append("")
                lines.append(contentsOf: (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).components(separatedBy: .newlines))
                let raw = email.rawSource.isEmpty ? email.plainBody : email.rawSource
                let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
                let pdfURL = pdfFolder.appendingPathComponent("\(batesNumber).pdf")
                // Audit F09b: a document is "included" only when its PDF was
                // written. A render that yields nothing fails the run — the
                // receipt must never say complete over a missing file.
                let rendered = try BatesPDFRenderer.renderVerified(
                    lines: lines,
                    metadata: .init(batesNumber: batesNumber, caseNumber: caseNumber, examiner: "", md5Hash: nil),
                    to: pdfURL)
                pages += rendered.pages
                for att in email.attachments { families[attachmentFamily(att.filename), default: 0] += 1 }
                manifest += [batesNumber, email.id.uuidString, messageID, email.headers["Date"] ?? "", email.headers["From"] ?? "",
                             subject, String(email.attachments.count), hash, rendered.sha256Hex].map(csv).joined(separator: ",") + "\n"
                included += 1
            }
            onProgress?(done, requested)
        }
        } catch {
            // Fail closed: no manifest, no production record, no numbered
            // document, and a receipt that says so. Whatever PDFs were written
            // stay in the folder for inspection, named by an unpublished run.
            ExportRunCenter.shared.recordFailure(destination: folder, isFolder: true, requested: requested,
                                                 message: "Production stopped after \(included) document\(included == 1 ? "" : "s"): \(error.localizedDescription). Nothing was published.")
            throw error
        }

        try manifest.write(to: folder.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        try exclusions.write(to: folder.appendingPathComponent("excluded.csv"), atomically: true, encoding: .utf8)
        let manifestHash = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()

        // Bates sequence continues after this run; assignments are kept.
        bates.merge(assignments: assignments, nextStart: number)

        let excluded = excludedByTag + excludedOnHold + excludedNoContent
        let elapsed = start.duration(to: clock.now).components
        var run = ProductionRun(productionNumber: nil, title: title, caseNumber: caseNumber,
                                requested: requested, included: included, excluded: excluded,
                                excludedByTag: excludedByTag, excludedOnHold: excludedOnHold,
                                excludedNoContent: excludedNoContent,
                                firstBates: firstBates, lastBates: lastBates, pages: pages,
                                attachmentFamilies: families, folder: folder.path,
                                manifestSHA256: manifestHash,
                                seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        // The signed-off version: a numbered production record.
        run.productionNumber = await DocumentRegistry.post(
            .export,
            summary: "Production “\(title)”\(caseNumber.isEmpty ? "" : " (\(caseNumber))"): \(run.summary); manifest sha256 \(manifestHash.prefix(16))…",
            refs: firstBates.map { "\($0)–\(lastBates ?? $0)" } ?? "")
        let record = try JSONEncoder.pretty.encode(run)
        try record.write(to: folder.appendingPathComponent("production.json"), options: .atomic)

        // Tag and hold exclusions are the production's intent and leave it
        // complete; a message withheld for want of content is a shortfall,
        // and the receipt says partial.
        ExportRunCenter.shared.record(ExportReceipt(
            title: "Production \(run.productionNumber ?? title)", destination: folder.path, isFolder: true,
            requested: requested, written: included, bytesWritten: nil,
            outcome: excludedNoContent > 0 ? .partial : .complete, sha256Hex: manifestHash,
            errorMessage: excluded > 0
                ? "\(excluded) withheld — see excluded.csv"
                    + (excludedNoContent > 0 ? " (\(excludedNoContent) had no producible content; export those as MBOX or EML)" : "")
                : nil,
            startedAt: Date().addingTimeInterval(-run.seconds), completedAt: Date()))
        return run
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
