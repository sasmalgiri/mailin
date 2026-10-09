@testable import ArchiveCore
//
//  ExportPreflight.swift
//  maxmailin
//
//  A8: the pre-flight sheet every export passes through, and the runner that
//  executes (and resumes) it.
//
//  Flow: a format button in `UnifiedExportSections` picks the destination,
//  builds an `ExportRequest` and hands it to `ExportRunCenter.requestPreflight`.
//  The run-center overlay presents `ExportPreflightSheet`, which shows what
//  will be written, where, with which folder layout / attachment / collision
//  choices, and how much space it needs against the destination's free
//  space. Start hands the request to `ExportJobRunner`, which streams the
//  export through `ArchiveExportService` and ends in an `ExportReceipt`.
//
//  Resume: formats whose partial output is safe to continue (per-message
//  folders, and single documents with no trailer) keep it on cancel or
//  error, and the receipt carries a `resumeRequest` whose `skipFirst` is the
//  number of messages already written. Resume re-runs the same request; the
//  writer steps over what exists and appends the rest, and the receipt's
//  hash covers the whole artifact.
//

import SwiftUI
import Foundation

// MARK: - Size estimate

struct ExportSizeEstimate: Equatable, Sendable {
    var messages: Int
    var estimatedBytes: Int64
    var freeBytes: Int64?
    var sampled: Int

    var missingBytes: Int64 {
        guard let freeBytes else { return 0 }
        return max(0, estimatedBytes - freeBytes)
    }
    var isInsufficient: Bool { missingBytes > 0 }
}

enum ExportSizeEstimator {
    static let sampleSize = 200

    /// Average stored size of a bounded sample × message count × format
    /// factor. Bounded work at any archive size; an estimate, never a promise.
    @MainActor
    static func estimate(request: ExportRequest, archive: ArchiveDataService = .shared) async -> ExportSizeEstimate? {
        let total: Int
        do { total = try await archive.count(scope: request.scope) } catch { return nil }
        let bounded = request.cap.map { min(total, $0) } ?? total

        var sample: [EmailSummary] = []
        switch request.scope {
        case .none:
            break
        case .explicit(let ids):
            let head = Array(ids.sorted { $0.uuidString < $1.uuidString }.prefix(sampleSize))
            sample = (try? await archive.summaries(ids: head)) ?? []
        case .query(let query, _):
            sample = (try? await archive.page(query: query, cursor: nil, limit: sampleSize).summaries) ?? []
        }
        let average: Double = sample.isEmpty ? 64 * 1024
            : Double(sample.reduce(0) { $0 + $1.sizeBytes }) / Double(sample.count)
        let estimated = Int64(average * Double(bounded) * request.format.sizeFactor)

        return ExportSizeEstimate(messages: bounded,
                                  estimatedBytes: estimated,
                                  freeBytes: freeBytes(at: request.destinationURL),
                                  sampled: sample.count)
    }

    static func freeBytes(at destination: URL) -> Int64? {
        let probe = StoragePlanner.nearestExistingDirectory(of: destination)
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(free)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Sheet

/// The pre-flight sheet: what, where, how, and whether it fits.
struct ExportPreflightSheet: View {
    @State var request: ExportRequest
    let onStart: (ExportRequest) -> Void
    let onCancel: () -> Void

    @State private var estimate: ExportSizeEstimate?
    @State private var estimating = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            destinationSection
            if request.format.writesFolder || request.format == .mbox {
                optionsSection
            }
            spaceSection
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 440)
        .task(id: request.options) { await refreshEstimate() }
        .accessibilityIdentifier("export.preflight")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.headline)
                Text(countLine).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var countLine: String {
        let n = estimate?.messages ?? request.emailCountHint
        var line: String
        if let n { line = n == 1 ? "1 email as \(request.format.displayName)" : "\(n) emails as \(request.format.displayName)" } else { line = request.format.displayName }
        if let cap = request.cap, let n, n >= cap { line += " — free tier writes the first \(cap)" }
        if request.skipFirst > 0 { line += " — resuming at message \(request.skipFirst + 1)" }
        return line
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Destination").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: request.isFolder ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(request.destinationURL.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(request.destinationURL.deletingLastPathComponent().path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(request.destination)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Options").font(.caption).foregroundStyle(.secondary)
            if request.format.writesFolder && request.format != .portableHTML {
                Picker("Folder layout", selection: $request.options.layout) {
                    ForEach(ExportFolderLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .help("Write every file into one folder, or into a subfolder per message year")
                Picker("If a file already exists", selection: $request.options.collision) {
                    ForEach(ExportCollisionRule.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .help("What to do when the destination already holds a file with the same name")
                Toggle("Also save attachments into an Attachments folder", isOn: $request.options.includeAttachmentsFolder)
                    .help("Copies every attachment file next to the messages, in Attachments/")
            }
            if request.format == .mbox {
                Toggle("Split into 2 GB parts", isOn: $request.options.partitionMBOX)
                    .help("Writes archive-0001.mbox, archive-0002.mbox … so the export survives a 4 GB-per-file drive; Apple Mail imports the folder. A split export cannot be resumed.")
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private var spaceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Space").font(.caption).foregroundStyle(.secondary)
            if estimating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Estimating…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let estimate {
                HStack(spacing: 6) {
                    Image(systemName: estimate.isInsufficient ? "exclamationmark.triangle.fill" : "internaldrive")
                        .foregroundStyle(estimate.isInsufficient ? .red : .secondary)
                    Text(spaceLine(estimate))
                        .font(.caption)
                        .foregroundStyle(estimate.isInsufficient ? .red : .primary)
                }
                Text(estimate.sampled > 0
                     ? "Estimate from a sample of \(estimate.sampled) messages — the receipt reports what was actually written."
                     : "Estimate — the receipt reports what was actually written.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if request.isResumable {
                    Label("Can be resumed from its receipt if interrupted", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Could not estimate — the archive did not answer.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("export.preflight.space")
    }

    private func spaceLine(_ e: ExportSizeEstimate) -> String {
        let need = ExportSizeEstimator.format(e.estimatedBytes)
        guard let free = e.freeBytes else { return "About \(need) needed" }
        if e.isInsufficient {
            return "About \(need) needed, \(ExportSizeEstimator.format(free)) free — short by \(ExportSizeEstimator.format(e.missingBytes))"
        }
        return "About \(need) needed · \(ExportSizeEstimator.format(free)) free"
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(request.skipFirst > 0 ? String(localized: "Resume") : String(localized: "Start")) { onStart(request) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(estimating || (estimate?.isInsufficient ?? false))
                .help((estimate?.isInsufficient ?? false)
                      ? "Not enough free space at the destination — choose another destination or free space first"
                      : "Start the export")
                .accessibilityIdentifier("export.preflight.start")
        }
    }

    private func refreshEstimate() async {
        estimating = true
        estimate = await ExportSizeEstimator.estimate(request: request)
        estimating = false
    }
}

// MARK: - Runner

/// Executes an `ExportRequest` (fresh or resumed) through `ArchiveExportService`
/// inside the run center, and turns every outcome into a receipt.
@MainActor
final class ExportJobRunner {
    static let shared = ExportJobRunner()

    /// v1-faithful RFC-822 renderer for .eml when the host provides one.
    var emlRender: (@MainActor (MBOXParser.RawEmail) -> String)?
    /// iOS delivery: hand the finished artifact to the host's share sheet.
    var share: ((URL) -> Void)?
    /// Host error binding (menus cannot host alerts themselves).
    var onError: ((String) -> Void)?
    /// Paywall + tier, when the host has a store manager.
    weak var storeManager: StoreManager?

    private init() {}

    /// Audit F08 / third review T1: why a resume was refused.
    enum ResumeError: LocalizedError {
        case selectionChanged
        case unbound
        case boundaryMissing
        var errorDescription: String? {
            switch self {
            case .selectionChanged:
                return String(localized: "The archive changed since this export stopped, so it cannot be continued from where it was. Start the export again.")
            case .unbound:
                return String(localized: "This export's receipt does not record which selection it was writing, so it cannot be continued safely. Start the export again.")
            case .boundaryMissing:
                return String(localized: "This export's receipt does not record where its partial file ended, so it cannot be continued safely. Start the export again.")
            }
        }
    }

    /// Recheck R2: a resumable run binds itself to the selection BEFORE it
    /// writes anything. The fingerprint is taken here, once, and travels with
    /// the request into its receipt; a resume compares against this value,
    /// not against a fingerprint taken after the archive may have changed
    /// during the run. Only a FRESH run is bound (T1): a resume must already
    /// carry its fingerprint, and never receives a new one.
    static func bindSelection(_ request: ExportRequest, archive: ArchiveDataService = .shared) async throws -> ExportRequest {
        guard request.isResumable, request.skipFirst == 0, request.selectionFingerprint == nil else { return request }
        var bound = request
        bound.selectionFingerprint = try await archive.selectionFingerprint(scope: request.scope)
        return bound
    }

    /// True when `request` may continue positionally: it is not a resume, or
    /// the selection still fingerprints as it did when the run started. A
    /// resume without a recorded fingerprint is refused (R2: fail closed).
    static func resumeIsCurrent(_ request: ExportRequest, archive: ArchiveDataService = .shared) async throws -> Bool {
        guard request.skipFirst > 0 else { return true }
        guard let recorded = request.selectionFingerprint else { return false }
        return try await archive.selectionFingerprint(scope: request.scope) == recorded
    }

    /// Third review T1: the ONE entry point the runner uses. A fresh run is
    /// bound to its selection; a resume is validated against its original
    /// fingerprint and boundary BEFORE anything is written, and is never
    /// re-bound to the current archive.
    static func prepare(_ request: ExportRequest, archive: ArchiveDataService = .shared) async throws -> ExportRequest {
        if request.skipFirst > 0 {
            guard request.selectionFingerprint != nil else { throw ResumeError.unbound }
            guard try await resumeIsCurrent(request, archive: archive) else { throw ResumeError.selectionChanged }
            if !request.isFolder {
                guard request.resumeArtifactBytes != nil, request.resumeArtifactSHA256 != nil else { throw ResumeError.boundaryMissing }
            }
            return request
        }
        return try await bindSelection(request, archive: archive)
    }

    /// The request a receipt should carry so the stopped run can continue:
    /// the INPUT positions consumed at the last boundary (T3), the fingerprint
    /// the run was bound to at its start, and — for a single document — the
    /// partial artifact's length and SHA-256 (T2); a folder relies on its
    /// manifest. Nil when the format cannot resume, the run was never bound,
    /// or the partial output is not there to continue.
    static func resumeRequest(for request: ExportRequest, positions: Int) -> ExportRequest? {
        guard request.isResumable, request.selectionFingerprint != nil, positions > 0 else { return nil }
        var resume = request
        resume.skipFirst = positions
        if request.isFolder {
            guard FileManager.default.fileExists(atPath: request.destinationURL.appendingPathComponent(ExportFolderManifest.filename).path) else { return nil }
        } else {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: request.destination)[.size] as? NSNumber)?.uint64Value,
                  let digest = try? ArchiveExportService.sha256(ofFile: request.destinationURL) else { return nil }
            resume.resumeArtifactBytes = size
            resume.resumeArtifactSHA256 = digest.map { String(format: "%02x", $0) }.joined()
        }
        return resume
    }

    func start(_ request: ExportRequest, service explicitService: ArchiveExportService? = nil) {
        // Resolved here, on the main actor, rather than as a default argument
        // (a main-actor `shared` in a default argument is a Swift 6 error).
        let service = explicitService ?? ArchiveExportService.shared
        let center = ExportRunCenter.shared
        center.run(title: request.title) { [weak self] in
            guard let self else { return }
            var request = request
            do {
                // Purchase policy is evaluated when the run STARTS, not when
                // the request was built: a resume from a receipt, or a request
                // kept open across a purchase or an expiry, carries a stale
                // cap. The current tier decides; a Free resume past the cap
                // writes nothing further and ends in a truncated receipt. No
                // tier to check means no run at all (fail closed).
                request = try Self.authorized(request, isPremium: self.storeManager?.isPremium)
                request = try await Self.prepare(request)
                // Fourth review Q2: a validated resume starts AT its
                // checkpoint. If the writer fails before it reports a new
                // batch, the receipt still offers the same checkpoint —
                // never zero, never something below it.
                if request.skipFirst > 0 { center.update(done: request.skipFirst, total: 0) }
                try await self.execute(request, service: service)
            } catch {
                self.onError?("\(request.title) failed: \(error.localizedDescription)")
                // A thrown error still ends in a receipt — and, when the
                // format kept its partial output (cut back to the last
                // reported batch), one that can be resumed. A refused resume
                // offers no further resume: the positions no longer mean
                // anything.
                var resume: ExportRequest? = nil
                if !(error is ResumeError), !(error is AuthorizationError), !(error is ArchiveExportError) {
                    resume = Self.resumeRequest(for: request, positions: center.done)
                }
                center.recordFailure(destination: request.destinationURL, isFolder: request.isFolder,
                                     requested: request.emailCountHint, message: error.localizedDescription,
                                     resume: resume)
            }
        }
    }

    /// Why a run was refused before it wrote anything.
    enum AuthorizationError: LocalizedError {
        /// The runner has no store to ask, so the tier in force is unknown.
        case tierUnknown
        var errorDescription: String? {
            switch self {
            case .tierUnknown:
                return String(localized: "This export cannot start because your plan could not be checked. Open the export again from the Export menu.")
            }
        }
    }

    /// The request as it may run under the tier in force NOW. The cap saved
    /// in the request only tells us what it thought at build time; the current
    /// entitlement wins in both directions — a Free run built while Personal
    /// was active is capped, a Personal run built while Free is not. An
    /// unknown tier (`nil`) refuses the run rather than trusting the saved cap.
    nonisolated static func authorized(_ request: ExportRequest, isPremium: Bool?) throws -> ExportRequest {
        var authorized = request
        authorized.cap = try enforcedCap(savedCap: request.cap, isPremium: isPremium)
        return authorized
    }

    /// The cap a run must honour given the tier in force NOW; see `authorized`.
    nonisolated static func enforcedCap(savedCap: Int?, isPremium: Bool?) throws -> Int? {
        guard let isPremium else { throw AuthorizationError.tierUnknown }
        return isPremium ? nil : StoreManager.freeEmailLimit
    }

    private func progress(_ done: Int, _ total: Int) {
        ExportRunCenter.shared.update(done: done, total: total)
    }

    private func execute(_ request: ExportRequest, service: ArchiveExportService) async throws {
        let scope = request.scope
        let url = request.destinationURL
        let cap = request.cap
        let write = request.writeOptions
        let onProgress: @MainActor (Int, Int) -> Void = { [weak self] in self?.progress($0, $1) }
        // T3: folder formats report input position through onProgress and the
        // produced-file count separately.
        let onProduced: @MainActor (Int) -> Void = { count in ExportRunCenter.shared.noteProduced(count) }

        switch request.format {
        case .word:
            let r = try await service.exportWordArchive(scope: scope, to: url, limit: cap, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "Word")
        case .csv:
            let r = try await service.exportDetailedCSV(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "CSV")
        case .json:
            let r = try await service.exportJSONArchive(scope: scope, to: url, limit: cap, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "JSON")
        case .printText:
            let r = try await service.exportBatchPrintText(scope: scope, to: url, write: write, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "Print text")
        case .markdown:
            let r = try await service.exportMarkdownArchive(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "Markdown")
        case .headersCSV:
            let r = try await service.exportHeadersCSV(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "Headers CSV")
        case .mbox:
            if request.options.partitionMBOX {
                let directory = url.deletingPathExtension()
                let results = try await service.exportMBOXPartitions(
                    scope: scope, toDirectory: directory,
                    baseName: url.deletingPathExtension().lastPathComponent,
                    limit: cap, onProgress: onProgress)
                let last = results.last
                let combined = ArchiveExportResult(
                    recordsWritten: last?.recordsWritten ?? 0,
                    bytesWritten: results.reduce(0) { $0 + $1.bytesWritten },
                    completed: results.allSatisfy(\.completed),
                    cancelled: results.contains(where: \.cancelled))
                var folderRequest = request
                folderRequest.destination = directory.path
                folderRequest.isFolder = true
                await finish(folderRequest, result: combined, written: combined.recordsWritten,
                             cancelled: combined.cancelled, what: "mbox")
            } else {
                let r = try await service.exportMBOXArchive(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress)
                await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "mbox")
            }
        case .emlFiles:
            let r = try await service.exportEMLFiles(scope: scope, to: url, limit: cap, render: emlRender, write: write, onProgress: onProgress, onProduced: onProduced)
            try await attachmentsFolderIfRequested(request, result: r, service: service)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "EML")
        case .pdfFiles:
            let r = try await service.exportPDFFiles(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress, onProduced: onProduced)
            try await attachmentsFolderIfRequested(request, result: r, service: service)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "PDF")
        case .tiffFiles:
            let r = try await service.exportTIFFFiles(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress, onProduced: onProduced)
            try await attachmentsFolderIfRequested(request, result: r, service: service)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "TIFF")
        case .msgFiles:
            let r = try await service.exportMSGFiles(scope: scope, to: url, limit: cap, write: write, onProgress: onProgress, onProduced: onProduced)
            try await attachmentsFolderIfRequested(request, result: r, service: service)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "MSG")
        case .portableHTML:
            let r = try await service.exportPortableHTML(scope: scope, to: url, limit: cap, onProgress: onProgress)
            await finish(request, result: r, written: r.recordsWritten, cancelled: r.cancelled, what: "HTML")
        case .vcard:
            let written = try await service.exportVCard(scope: scope, to: url, onProgress: onProgress)
            await finish(request, result: nil, written: written, cancelled: Task.isCancelled, what: "Contacts")
        case .ics:
            let written = try await service.exportICS(scope: scope, to: url, onProgress: onProgress)
            await finish(request, result: nil, written: written, cancelled: Task.isCancelled, what: "Calendar")
        }
    }

    /// Folder formats with "also save attachments": copy every attachment into
    /// `Attachments/` after the messages, only when the main run completed.
    private func attachmentsFolderIfRequested(_ request: ExportRequest, result: ArchiveExportResult,
                                              service: ArchiveExportService) async throws {
        guard request.options.includeAttachmentsFolder, result.completed, !result.cancelled else { return }
        let folder = request.destinationURL.appendingPathComponent("Attachments", isDirectory: true)
        _ = try await service.exportAttachments(scope: request.scope, to: folder, onProgress: { [weak self] in
            self?.progress($0, $1)
        })
    }

    /// Free-tier honesty + A8: every outcome — complete, truncated, cancelled,
    /// failed — is recorded as a receipt with the requested count, what was
    /// written, the artifact hash, and (when the format allows) how to resume.
    private func finish(_ request: ExportRequest, result: ArchiveExportResult?,
                        written: Int, cancelled: Bool, what: String) async {
        let requested = try? await ArchiveDataService.shared.count(scope: request.scope)
        var outcome: ExportReceipt.Outcome = .complete
        var note: String? = nil
        if cancelled {
            onError?("\(what) export cancelled\(request.isResumable ? " — partial output kept; Resume continues it." : " — partial output removed.")")
            outcome = .cancelled
        } else if let cap = request.cap, let requested, requested > cap {
            storeManager?.requestPurchase(.personal, feature: "Full Export",
                                          reason: "The Free plan exports up to \(cap) emails per run. Personal and Professional export without the limit.")
            onError?("Exported \(written) of \(requested) emails. Personal and Professional export without the \(cap)-email limit.")
            outcome = .truncated
        } else if let requested, written < requested, result?.completed == false {
            outcome = .failed
        } else if let withheld = result?.withheld, withheld > 0 {
            // R5: messages this format could not produce honestly.
            outcome = .partial
            note = "\(withheld) message\(withheld == 1 ? "" : "s") withheld: content not decoded at import (above the full-parse ceiling) — export \(withheld == 1 ? "it" : "them") as MBOX or EML, which stream the original bytes"
            onError?("\(what) export: \(note!).")
        }
        if let unverified = result?.unverifiedSources, unverified > 0 {
            // R4: an unverifiable source is stated, never passed off as verified.
            let line = "\(unverified) source file\(unverified == 1 ? "" : "s") could not be verified against an import digest (imported before digests were recorded)"
            note = note.map { $0 + "; " + line } ?? line
        }

        var resume: ExportRequest? = nil
        if outcome == .cancelled || outcome == .failed {
            resume = Self.resumeRequest(for: request, positions: result?.positionsConsumed ?? written)
        }

        var isFolder: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: request.destination, isDirectory: &isFolder)
        ExportRunCenter.shared.record(ExportReceipt(
            title: "\(what) export",
            destination: request.destination,
            isFolder: isFolder.boolValue,
            requested: requested,
            written: written,
            bytesWritten: result?.bytesWritten,
            outcome: outcome,
            sha256Hex: result?.sha256Hex,
            signaturePath: result?.signatureURL?.path,
            errorMessage: outcome == .failed ? "The writer stopped before every requested message was written." : note,
            startedAt: ExportRunCenter.shared.startedAt,
            completedAt: Date(),
            resumeRequest: resume))
        #if os(iOS)
        if !cancelled { share?(request.destinationURL) }
        #endif
    }
}
