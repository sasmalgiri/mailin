@testable import ArchiveCore
//
//  ExportRunCenter.swift
//  maxmailin
//
//  Part O: one shared progress/cancellation surface for streaming exports.
//  Every bulk export runs as a cancellable Task and reports (done, total)
//  after each bounded batch; the small overlay below shows progress and a
//  Cancel button. Deliberately minimal — the streaming pipeline itself lives
//  in `ArchiveExportService`.
//
//  A8: when a run finishes, the overlay turns into the run's receipt
//  (`ExportReceipt`): requested / written / outcome / SHA-256 / destination,
//  with Reveal and Save. A run that ends in an error or a cancel produces a
//  receipt that says so, in the same place, instead of a bar that vanishes.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ExportRunCenter {
    static let shared = ExportRunCenter()

    private(set) var isActive = false
    private(set) var title = ""
    /// Input positions consumed at the last reported boundary (what a resume skips).
    private(set) var done = 0
    private(set) var total = 0
    /// Files produced so far, when the writer reports it separately (folder
    /// formats, third review T3). Nil when produced == done.
    private(set) var produced: Int?
    /// What the receipt calls "written".
    var writtenForReceipt: Int { produced ?? done }
    private(set) var startedAt = Date()

    /// The most recent finished run. Shown by the overlay until dismissed.
    private(set) var lastReceipt: ExportReceipt?
    var showReceipt = false
    /// Where the receipt was saved, if it could be.
    private(set) var lastReceiptURL: URL?

    private var task: Task<Void, Never>?
    /// Set by the export body when it knows its outcome; consulted by finish().
    private var pendingReceipt: ExportReceipt?

    /// A8: a request waiting for the user's pre-flight confirmation. The
    /// overlay presents it as a sheet; Start hands it to `ExportJobRunner`.
    var pendingPreflight: ExportRequest?

    /// Where receipts are kept (tests use a temporary folder).
    let receiptStore: ExportReceiptStore

    init(receiptStore: ExportReceiptStore = .production) {
        self.receiptStore = receiptStore
        #if os(iOS)
        deliverHandler = { await PlatformExport.shareAndWait($0) }
        #endif
    }

    // MARK: R1 — delivery, tracked apart from the run

    /// How a written file is handed on once the run has ended (iOS: the Share
    /// sheet). Nil where the destination was chosen before writing (Mac).
    var deliverHandler: (@MainActor (URL) async -> ExportOutcome)?
    /// The receipt whose file is being handed on right now, if any.
    private(set) var deliveringReceiptID: UUID?
    private var deliveryTask: Task<Void, Never>?
    private var restoredAfterLaunch = false

    /// Every export enters here: show the pre-flight sheet for `request`.
    /// Refused while a run is active, like `run`.
    func requestPreflight(_ request: ExportRequest) {
        guard !isActive else { return }
        pendingPreflight = request
    }

    /// Resume an interrupted export from its receipt (Resume button).
    func resume(_ receipt: ExportReceipt) {
        guard let request = receipt.resumeRequest, !isActive else { return }
        showReceipt = false
        pendingPreflight = request
    }

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    /// Run `operation` as the single active export. A second export while one
    /// is running is refused (the overlay is already showing).
    func run(title: String, operation: @escaping @MainActor () async -> Void) {
        guard !isActive else { return }
        isActive = true
        self.title = title
        done = 0
        total = 0
        produced = nil
        startedAt = Date()
        pendingReceipt = nil
        showReceipt = false
        task = Task { @MainActor [weak self] in
            await operation()
            self?.finish()
        }
    }

    /// Batch progress callback — pass directly as `onProgress`.
    func update(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// Folder formats: files produced so far (differs from `done` when
    /// messages were skipped or withheld).
    func noteProduced(_ count: Int) {
        produced = count
    }

    /// The run card's Cancel: stops the run, and a hand-off waiting on screen.
    func cancel() {
        task?.cancel()
        cancelDelivery()
    }

    /// R1: stop waiting for the Share sheet / Save to Files. The hand-off
    /// settles as cancelled and the receipt says "not saved"; the file stays offered.
    func cancelDelivery() {
        deliveryTask?.cancel()
    }

    /// R1: hand a written file on — the Share sheet (default) or `handler`
    /// (Save to Files). The receipt was saved as awaiting delivery before this
    /// runs; it is saved again with what the hand-off really did. A hand-off
    /// already on its way is cancelled first, so only one ever waits.
    func deliver(_ receipt: ExportReceipt, using handler: (@MainActor (URL) async -> ExportOutcome)? = nil) {
        guard let handler = handler ?? deliverHandler else { return }
        let previous = deliveryTask
        previous?.cancel()
        deliveringReceiptID = receipt.id
        deliveryTask = Task { @MainActor [weak self] in
            await previous?.value
            let outcome = await handler(receipt.destinationURL)
            guard let self else { return }
            if let shown = self.lastReceipt, shown.id == receipt.id {
                self.replace(Self.receipt(shown, afterDelivery: outcome))
            } else {
                // A newer export's receipt is on screen: record this one on disk only.
                _ = try? self.receiptStore.save(Self.receipt(receipt, afterDelivery: outcome))
            }
            if self.deliveringReceiptID == receipt.id { self.deliveringReceiptID = nil }
            // v4.0 REC-02: the hand-off changed the receipt on disk; a waiting
            // recipe step re-reads it (the job stays bound to its first report).
            if self.receiptStore.directory == ExportReceiptStore.production.directory {
                RecipeJobBroker.shared.reportExport(Self.receipt(receipt, afterDelivery: outcome), receiptURL: self.receiptStore.directory.appendingPathComponent("export-\(receipt.id.uuidString).json"))
            }
        }
    }

    /// What a hand-off did, on the receipt. A later Share sheet closed without
    /// saving does not undo an earlier hand-off that really happened.
    nonisolated static func receipt(_ receipt: ExportReceipt, afterDelivery outcome: ExportOutcome) -> ExportReceipt {
        var updated = ExportJobRunner.receipt(receipt, after: outcome)
        if case .cancelled = outcome, receipt.delivery == .shared || receipt.delivery == .saved {
            updated.delivery = receipt.delivery
            updated.deliveryNote = receipt.deliveryNote
        }
        return updated
    }

    /// R1: after a relaunch, the newest receipt that was still waiting to be
    /// handed on is shown again, waiting, with its file offered — never a run
    /// in progress. If the system removed the written file meanwhile, the
    /// receipt says so instead of offering a file that is gone.
    nonisolated static func relaunchReceipt(_ receipt: ExportReceipt, fileExists: Bool) -> ExportReceipt? {
        guard receipt.delivery == .awaitingDelivery else { return nil }
        if fileExists { return receipt }
        var gone = receipt
        gone.delivery = .failed
        gone.deliveryNote = String(localized: "the written file was removed from mailin's temporary folder before it was saved or shared; export again")
        return gone
    }

    /// Called once when the export overlay first appears.
    func restoreAfterLaunch() async {
        guard !restoredAfterLaunch else { return }
        restoredAfterLaunch = true
        guard !isActive, lastReceipt == nil else { return }
        let store = receiptStore
        let newest: (URL, ExportReceipt)? = await Task.detached(priority: .utility) {
            guard let url = store.list().first, let stored = try? store.load(url) else { return nil }
            // R8 (rule 9): an interrupted export whose partial file is there again is offered Recover and resume.
            if Self.offersRecoveryAtLaunch(stored) { return (url, stored) }
            guard let receipt = Self.relaunchReceipt(stored, fileExists: FileManager.default.fileExists(atPath: stored.destination))
            else { return nil }
            return (url, receipt)
        }.value
        guard let (url, found) = newest, !isActive, lastReceipt == nil else { return }
        if found.delivery == .awaitingDelivery || found.offersRecovery {
            lastReceipt = found
            lastReceiptURL = url
            showReceipt = true
        } else {
            replace(found)
        }
    }

    /// Tests: wait for the run and any hand-off it started to end.
    func waitUntilIdle() async {
        await task?.value
        await deliveryTask?.value
    }

    /// The export body records what it did. Called at most once per run; a
    /// later call replaces the earlier (an error after a partial result).
    func record(_ receipt: ExportReceipt) {
        pendingReceipt = receipt
    }

    /// A failure the body did not turn into a receipt itself (thrown error).
    func recordFailure(destination: URL?, isFolder: Bool, requested: Int?, message: String,
                       resume: ExportRequest? = nil, recoverable: ExportRequest? = nil) {
        pendingReceipt = ExportReceipt(
            title: title,
            destination: destination?.path ?? "—",
            isFolder: isFolder,
            requested: requested,
            written: writtenForReceipt,
            outcome: .failed,
            errorMessage: message,
            startedAt: startedAt,
            completedAt: Date(),
            resumeRequest: resume,
            recoverableRequest: resume == nil ? recoverable : nil)
    }

    // MARK: - R8 / OUT-06a: Recover and resume

    /// The "interrupted" receipt saved while a recoverable run is under way;
    /// removed when the run records its real receipt.
    private var provisionalReceiptURL: URL?
    /// The receipt Recover and resume is working on right now, if any.
    private(set) var recoveringReceiptID: UUID?

    /// Rule 9: a recoverable run (single-file mbox) saves a receipt that says
    /// "interrupted" when it starts. The run's own receipt replaces it; if
    /// mailin quits or crashes first, the next launch finds it and offers
    /// Recover and resume.
    func markInterruptible(_ request: ExportRequest) {
        guard isActive, let recoverable = ExportJobRunner.recoverableRequest(request) else { return }
        let receipt = ExportReceipt(
            title: title, destination: request.destination, isFolder: false,
            requested: request.emailCountHint, written: request.skipFirst, outcome: .failed,
            errorMessage: String(localized: "mailin stopped before this export finished (it quit, crashed or the device restarted)."),
            startedAt: startedAt, completedAt: Date(),
            recoverableRequest: recoverable, interrupted: true)
        if let previous = provisionalReceiptURL { try? FileManager.default.removeItem(at: previous) }
        provisionalReceiptURL = try? receiptStore.save(receipt)
    }

    /// What Recover and resume found for a receipt.
    enum RecoveryStep: Equatable, Sendable {
        /// The file was cut back to a verified boundary; `request` continues it there.
        case resume(ExportReceipt, ExportRequest)
        /// No boundary could be verified: nothing was cut; Export again is offered.
        case exportAgain(ExportReceipt)
        /// The partial file is not reachable (the drive is still gone): nothing was touched.
        case unreachable(ExportReceipt)
        /// The file's manifest has an end mark: the export finished; Verify export checks it.
        case finished(ExportReceipt)
    }

    /// R8: recover the receipt's partial file to its last verified boundary
    /// (`ContainerManifest.recover`) and say what was found. The receipt's
    /// "written" becomes the records the boundary vouches for — "X of Y" is
    /// what the file really holds, never what the run last reported.
    /// Nil when the receipt has nothing to recover. Runs file I/O: call off the main actor.
    nonisolated static func recoveryStep(for receipt: ExportReceipt) -> RecoveryStep? {
        guard let request = receipt.recoverableRequest else { return nil }
        var updated = receipt
        let output = request.destinationURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: output.path) else {
            updated.recoveryLine = String(localized: "The partial file is not reachable. Reconnect the drive that holds it, then choose Recover and resume again.")
            return .unreachable(updated)
        }
        do {
            let recovery = try ContainerManifest.recover(output: output)
            guard recovery.positions > 0 else { throw ContainerManifest.RecoveryError.noVerifiedBoundary("the boundary vouches for no record") }
            updated.written = recovery.records
            updated.bytesWritten = Int(recovery.offset)
            updated.recoveryFailed = nil
            updated.recoveryDetail = recovery.summary
            updated.recoveryLine = recoveryText(recovery, requested: receipt.requested)
            let resume = request.resumed(from: recovery)
            updated.resumeRequest = resume
            return .resume(updated, resume)
        } catch ContainerManifest.RecoveryError.alreadyFinished {
            let end = (try? ContainerManifest.scan(url: ContainerManifest.url(for: output)))?.end
            if let records = end?.records { updated.written = records }
            if let hash = end?.sha256 { updated.sha256Hex = hash }
            updated.recoveryDetail = ContainerManifest.RecoveryError.alreadyFinished.localizedDescription
            updated.recoveryLine = String(localized: "The export's file is complete (its manifest has an end mark): nothing to recover. Verify export checks it.")
            updated.recoverableRequest = nil
            return .finished(updated)
        } catch {
            updated.recoveryFailed = true
            updated.recoveryDetail = error.localizedDescription
            updated.recoveryLine = String(localized: "No verified boundary could be found in the partial file; nothing was cut. Export again writes a new file.")
            return .exportAgain(updated)
        }
    }

    /// The recovery in the person's language: what the boundary vouches for,
    /// what lay past it, and checkpoints that did not verify.
    nonisolated static func recoveryText(_ r: ContainerManifest.Recovery, requested: Int?) -> String {
        var line = requested.map { String(localized: "Recovered: \(r.records) of \($0) records verified at byte \(Int(r.offset))") }
            ?? String(localized: "Recovered: \(r.records) records verified at byte \(Int(r.offset))")
        if r.tailBytes > 0 {
            line += " · " + String(localized: "past it: \(r.tailCompleteRecords) complete and \(r.tailLastRecordCut ? 1 : 0) cut record(s) the receipt never counted — removed; the resume writes them again")
        }
        if r.checkpointsRejected > 0 {
            line += " · " + String(localized: "\(r.checkpointsRejected) later checkpoint(s) did not verify and were not used")
        }
        return line
    }

    /// The receipt card's Recover and resume: recover, show what was found,
    /// resume at the boundary, then the normal one-to-one verification of
    /// the finished file. `run` and `lookup` are the tests' seams; the app
    /// resumes through `ExportJobRunner` and verifies against the archive.
    func recoverAndResume(_ receipt: ExportReceipt,
                          run: (@MainActor (ExportRequest) -> Void)? = nil,
                          lookup: ExportReconciliation.SourceLookup? = nil) async {
        guard !isActive, recoveringReceiptID == nil, receipt.offersRecovery else { return }
        recoveringReceiptID = receipt.id
        let step = await Task.detached(priority: .userInitiated) { Self.recoveryStep(for: receipt) }.value
        recoveringReceiptID = nil
        guard let step else { return }
        switch step {
        case .resume(let recovered, let request):
            replace(recovered)
            let runner = run ?? { ExportJobRunner.shared.start($0) }
            runner(request)
            await waitUntilIdle()
            if let finished = lastReceipt, finished.id != recovered.id, finished.outcome == .complete,
               finished.destination == recovered.destination {
                await verifyExport(finished, lookup: lookup)
            }
        case .exportAgain(let updated), .unreachable(let updated), .finished(let updated):
            replace(updated)
        }
    }

    /// No boundary could be verified: start the same selection again from
    /// its first message, through the pre-flight sheet (a fresh run is bound anew).
    func exportAgain(_ receipt: ExportReceipt) {
        guard var request = receipt.recoverableRequest, !isActive else { return }
        request.id = UUID()
        request.skipFirst = 0
        request.selectionFingerprint = nil
        request.resumeArtifactBytes = nil
        request.resumeArtifactSHA256 = nil
        showReceipt = false
        pendingPreflight = request
    }

    /// Rule 9: at launch, a receipt that can be recovered is offered again
    /// when its partial file and its manifest are there.
    nonisolated static func offersRecoveryAtLaunch(_ receipt: ExportReceipt) -> Bool {
        guard receipt.offersRecovery, let request = receipt.recoverableRequest else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: request.destination)
            && fm.fileExists(atPath: ContainerManifest.url(for: request.destinationURL).path)
    }

    // MARK: - R3 (iOS): the manifest of a file handed on alone

    /// A single mbox / PST written inside the app (the temporary folder, iOS)
    /// is handed on by the Share sheet as one file. Its manifest is copied
    /// into the receipts folder as `export-<id>.mailin-manifest`, and the
    /// receipt points at it, so Verify export still checks one-to-one.
    nonisolated static func keepingManifest(_ receipt: ExportReceipt, in store: ExportReceiptStore,
                                            temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> ExportReceipt {
        guard receipt.manifestPath == nil, !receipt.isFolder, receipt.destination != "—",
              ["mbox", "pst"].contains(receipt.destinationURL.pathExtension.lowercased()),
              ExportPreflightSheet.handOffNote(for: receipt.destinationURL, temporaryDirectory: temporaryDirectory) != nil
        else { return receipt }
        let sidecar = ContainerManifest.url(for: receipt.destinationURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sidecar.path) else { return receipt }
        let kept = store.directory.appendingPathComponent("export-\(receipt.id.uuidString).mailin-manifest")
        do {
            try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: kept.path) { try fm.removeItem(at: kept) }
            try fm.copyItem(at: sidecar, to: kept)
        } catch { return receipt }
        var updated = receipt
        updated.manifestPath = kept.path
        return updated
    }

    /// iOS PST: the items the Share sheet hands on — the file, and its
    /// manifest beside it when there is one, so a saved copy verifies too.
    nonisolated static func shareItems(for output: URL) -> [URL] {
        let sidecar = ContainerManifest.url(for: output)
        return FileManager.default.fileExists(atPath: sidecar.path) ? [output, sidecar] : [output]
    }

    /// The older exports (`runStreamingExport`) say how they ended in a status line rather than a
    /// receipt; without this every one of them finished as "Failed — N written before the error",
    /// even a complete export. Records the real outcome unless the body already recorded one.
    func recordOutcome(_ outcome: ExportReceipt.Outcome, destination: URL? = nil, message: String? = nil) {
        guard pendingReceipt == nil else { return }
        pendingReceipt = ExportReceipt(
            title: title,
            destination: destination?.path ?? "—",
            isFolder: false,
            requested: total > 0 ? total : nil,
            written: writtenForReceipt,
            outcome: outcome,
            errorMessage: outcome == .failed ? message : nil,
            startedAt: startedAt,
            completedAt: Date())
    }

    func dismissReceipt() {
        showReceipt = false
    }

    // MARK: - R06: finishing and verifying a folder export after the fact

    /// The inventory could not be written when the run ended: build it from the
    /// retained manifest, re-hash every listed file, and update the receipt.
    func finishInventory(_ receipt: ExportReceipt) async {
        var updated = receipt
        let folder = receipt.destinationURL
        let outcome: Result<(URL, ExportInventory.Verification), Error> = await Task.detached(priority: .utility) {
            do {
                let url = try ExportInventory.repair(folder: folder)
                return .success((url, try ExportInventory.verify(folder: folder)))
            } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let (url, verification)):
            updated.inventoryPath = url.path
            updated.checked = verification.listed
            updated.verificationLine = Self.verificationText(verification)
            if verification.isClean {
                updated.outcome = .complete
                updated.errorMessage = nil
            }
        case .failure(let error):
            updated.verificationLine = String(localized: "Inventory could not be finished: \(error.localizedDescription)")
        }
        replace(updated)
    }

    /// Re-read what the export wrote. Two statements, kept apart on the receipt:
    /// the byte re-hash (`verificationLine` — every listed file against the
    /// inventory, or the single file against the receipt's SHA-256) and the
    /// content reconciliation (`contentLine`, OUT-04 — every output message
    /// parsed back and compared with the archive's record, streamed a page at
    /// a time). The content line is always written: when nothing could be
    /// checked it says why. The full report is saved beside the receipt.
    func verifyExport(_ receipt: ExportReceipt, lookup explicitLookup: ExportReconciliation.SourceLookup? = nil) async {
        let lookup = explicitLookup ?? Self.sourceLookup()
        var updated = receipt
        let destination = receipt.destinationURL
        if receipt.isFolder {
            let outcome: Result<ExportInventory.Verification, Error> = await Task.detached(priority: .utility) {
                do { return .success(try ExportInventory.verify(folder: destination)) } catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let verification):
                updated.verificationLine = Self.verificationText(verification)
            case .failure(let error):
                updated.verificationLine = String(localized: "Verification could not run: \(error.localizedDescription)")
            }
        } else {
            updated.verificationLine = await Self.fileRehashText(file: destination, recorded: receipt.sha256Hex)
        }
        let report = receipt.isFolder
            ? await ExportReconciliation.reconcile(folder: destination, lookup: lookup)
            : await ExportReconciliation.reconcile(file: destination, promised: receipt.written,
                                                   manifest: receipt.manifestPath.map { URL(fileURLWithPath: $0) }, lookup: lookup)
        updated.contentLine = Self.reconciliationText(report)
        updated.contentReportPath = (try? receiptStore.saveContentReport(report, for: receipt))?.path
        replace(updated)
    }

    /// A single-file export (mbox, PST, one .eml): its SHA-256 now against the one the receipt recorded.
    nonisolated static func fileRehashText(file: URL, recorded: String?) async -> String {
        let outcome: Result<String, Error> = await Task.detached(priority: .utility) {
            do { return .success(try ExportInventory.sha256(of: file)) } catch { return .failure(error) }
        }.value
        switch outcome {
        case .failure(let error):
            return String(localized: "Verification could not run: \(error.localizedDescription)")
        case .success(let hash):
            guard let recorded, !recorded.isEmpty else {
                return String(localized: "rehash: the receipt recorded no SHA-256, so the bytes could not be compared")
            }
            return hash.lowercased() == recorded.lowercased()
                ? String(localized: "rehash checked: the file matches the receipt's SHA-256")
                : String(localized: "rehash checked: the file's SHA-256 differs from the receipt")
        }
    }

    /// OUT-04: the archive's records a page at a time — the engine hands at
    /// most `ExportReconciliation.maxPageSize` ids per call, so no
    /// whole-archive dictionary is ever built. Container outputs (mbox, PST)
    /// are tied to their records by Message-ID. A header-only (located)
    /// record is completed by the engine through the hydrator's locator
    /// route, which `CapabilityWiring` installs under `.locatorReads`.
    nonisolated static func sourceLookup(store: SQLiteEmailStore = .shared) -> ExportReconciliation.SourceLookup {
        ExportReconciliation.SourceLookup(
            records: { ids in
                var out: [UUID: MBOXParser.RawEmail] = [:]
                for id in ids { if let email = try await store.fullEmail(id: id) { out[id] = email } }
                return out
            },
            recordsByMessageID: { messageIDs in
                var out: [String: MBOXParser.RawEmail] = [:]
                for (key, id) in try await store.emailIDs(forMessageIDs: messageIDs) {
                    if let email = try await store.fullEmail(id: id) { out[key] = email }
                }
                return out
            })
    }

    /// The receipt's content statement: outcome, counts, named differences,
    /// and every lossy-but-permitted transformation the format imposed.
    nonisolated static func reconciliationText(_ r: ExportReconciliation.ContentReport) -> String {
        var line: String
        switch r.outcome {
        case .complete:
            line = String(localized: "content checked: \(r.matching) of \(r.eligible) messages say what the archive says")
        case .partial:
            line = String(localized: "content check incomplete: \(r.matching) of \(r.eligible) messages reached say what the archive says")
        case .failed:
            line = String(localized: "content check failed: \(r.matching) of \(r.eligible) messages say what the archive says")
        case .unavailable:
            line = String(localized: "content not checked")
        }
        if let reason = r.reason, !reason.isEmpty { line += " — " + reason }
        if r.mismatched > 0 {
            let named = r.mismatches.prefix(3)
                .map { "\(($0.path as NSString).lastPathComponent) (\($0.lostFields.map(\.rawValue).joined(separator: ", ")))" }
                .joined(separator: "; ")
            line += " · " + String(localized: "differ \(r.mismatched): \(named)")
        }
        if r.unverifiable > 0 { line += " · " + String(localized: "not verifiable \(r.unverifiable)") }
        if r.withoutRecord > 0 { line += " · " + String(localized: "no record \(r.withoutRecord)") }
        if r.unparsed > 0 { line += " · " + String(localized: "unparsable \(r.unparsed)") }
        // R3: the one-to-one selection check's shortfalls as counts, not only as the engine's English reason.
        if let s = r.selection {
            if s.missing > 0 { line += " · " + String(localized: "missing \(s.missing)") }
            if s.extra > 0 { line += " · " + String(localized: "extra \(s.extra)") }
        }
        if r.hydrated > 0 { line += " · " + String(localized: "\(r.hydrated) located record(s) read from their source bytes") }
        if !r.transformations.isEmpty {
            let named = r.transformations.sorted { $0.key < $1.key }
                .map { "\(transformationText($0.key)) (\($0.value))" }
                .joined(separator: "; ")
            line += " · " + String(localized: "re-expressed, not lost: \(named)")
        }
        return line
    }

    /// The transformations `ExportReconciliation` names, in the user's
    /// language. The engine writes English keys; the ones it is known to emit
    /// are translated here, anything else is shown as the engine wrote it.
    nonisolated static func transformationText(_ key: String) -> String {
        switch key {
        case "the .msg writer does not carry attachment Content-IDs":
            return String(localized: "the .msg writer does not carry attachment Content-IDs")
        case "the .msg writer does not carry the inline disposition":
            return String(localized: "the .msg writer does not carry the inline disposition")
        case "mbox carries no folder path":
            return String(localized: "mbox carries no folder path")
        case "the PST export writes every message into its export folder; the source folder path is not carried":
            return String(localized: "the PST export writes every message into its export folder; the source folder path is not carried")
        case "the file layout did not record the folder":
            return String(localized: "the file layout did not record the folder")
        case "date re-expressed (same instant to the second)":
            return String(localized: "date re-expressed (same instant to the second)")
        default:
            break
        }
        let minutePrefix = "date compared to the minute because ", minuteSuffix = " carries no seconds"
        if key.hasPrefix(minutePrefix), key.hasSuffix(minuteSuffix), key.count > minutePrefix.count + minuteSuffix.count {
            let side = String(key.dropFirst(minutePrefix.count).dropLast(minuteSuffix.count))
            return String(localized: "date compared to the minute because \(side) carries no seconds")
        }
        let deliveryPrefix = "date: the ", deliverySuffix = " carries a delivery time derived from the record (the source had no Date header)"
        if key.hasPrefix(deliveryPrefix), key.hasSuffix(deliverySuffix), key.count > deliveryPrefix.count + deliverySuffix.count {
            let format = String(key.dropFirst(deliveryPrefix.count).dropLast(deliverySuffix.count))
            return String(localized: "date: the \(format) carries a delivery time derived from the record (the source had no Date header)")
        }
        let addressSuffix = ": same addresses, display names or order re-expressed"
        if key.hasSuffix(addressSuffix), key.count > addressSuffix.count {
            let field = String(key.dropLast(addressSuffix.count))
            return String(localized: "\(field): same addresses, display names or order re-expressed")
        }
        return key
    }

    /// "written", "hashes recorded while writing" and this re-read stay three different statements.
    static func verificationText(_ v: ExportInventory.Verification) -> String {
        var line = String(localized: "rehash checked: \(v.matching) of \(v.listed) files match")
        if !v.missing.isEmpty { line += " · " + String(localized: "missing \(v.missing.count)") }
        if !v.changed.isEmpty { line += " · " + String(localized: "changed \(v.changed.count)") }
        if !v.unlisted.isEmpty { line += " · " + String(localized: "unlisted \(v.unlisted.count)") }
        return line
    }

    private func replace(_ receipt: ExportReceipt) {
        lastReceipt = receipt
        lastReceiptURL = try? receiptStore.save(receipt)
        showReceipt = true
    }

    private func finish() {
        // A run that recorded nothing still gets a receipt: silence is not an
        // outcome. It is marked failed with an explicit reason.
        let recorded = pendingReceipt ?? ExportReceipt(
            title: title, destination: "—", isFolder: false, requested: total > 0 ? total : nil,
            written: done, outcome: .failed,
            errorMessage: "The export ended without reporting a result.",
            startedAt: startedAt, completedAt: Date())
        // R3 (iOS): a container written inside the app keeps its manifest with the receipt.
        let receipt = Self.keepingManifest(recorded, in: receiptStore)
        // R1: the receipt is on disk (awaiting delivery, where the file is still
        // to be handed on) and the run is over BEFORE any Share sheet is shown.
        lastReceipt = receipt
        lastReceiptURL = try? receiptStore.save(receipt)
        // v4.0 REC-02: a recipe step waiting on an export re-reads this receipt
        // (and its later delivery) from disk; nothing is taken on trust.
        if receiptStore.directory == ExportReceiptStore.production.directory {
            RecipeJobBroker.shared.reportExport(receipt, receiptURL: lastReceiptURL)
        }
        // R8: the run ended and said how — the "interrupted" placeholder goes.
        if let provisional = provisionalReceiptURL, provisional != lastReceiptURL {
            try? FileManager.default.removeItem(at: provisional)
        }
        provisionalReceiptURL = nil
        showReceipt = true
        isActive = false
        task = nil
        done = 0
        total = 0
        pendingReceipt = nil
        if receipt.delivery == .awaitingDelivery { deliver(receipt) }
    }
}

/// Progress + cancel while running; the receipt when finished. Attached once
/// at the ContentView level; hidden unless an export is running or a receipt
/// is waiting to be read.
struct ExportProgressOverlayView: View {
    @State private var center = ExportRunCenter.shared
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    /// §3-F1: with the 3.0 scope engine on, progress shows in the shell's
    /// job bar with every other running job; the receipt card stays here.
    private var progressInJobBar: Bool { modules?.isOn(.v3ScopeEngine) ?? false }
    @State private var copied = false
    @State private var receiptSaveNote: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            // An always-present anchor so the pre-flight sheet can be
            // presented even when neither card is showing.
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            if center.isActive {
                if !progressInJobBar { progressCard }
            } else if center.showReceipt, let receipt = center.lastReceipt {
                receiptCard(receipt)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.isActive)
        .animation(.easeInOut(duration: 0.2), value: center.showReceipt)
        // R1: a receipt still waiting to be handed on when mailin last closed is offered again.
        .task { await center.restoreAfterLaunch() }
        // A8: every export passes through the pre-flight sheet.
        .sheet(item: Binding(get: { center.pendingPreflight },
                             set: { center.pendingPreflight = $0 })) { request in
            ExportPreflightSheet(request: request,
                                 onStart: { confirmed in
                                     center.pendingPreflight = nil
                                     ExportJobRunner.shared.start(confirmed)
                                 },
                                 onCancel: { center.pendingPreflight = nil })
        }
    }

    private var progressCard: some View {
        VStack(spacing: 10) {
            Text(center.title)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if center.total > 0 {
                ProgressView(value: center.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("\(center.done) / \(center.total)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                center.cancel()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 32)
        .transition(.opacity)
    }

    private func receiptCard(_ receipt: ExportReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: receipt))
                    .foregroundColor(color(for: receipt))
                Text(receipt.title)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button {
                    center.dismissReceipt()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss — the receipt is kept on disk")
                .accessibilityLabel("Dismiss export receipt")
            }

            Text(receipt.verdictLine)
                .font(.system(size: 11))
                .foregroundColor(color(for: receipt))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("export.receipt.verdict")
            // OUT-04/07: what was selected, written, checked, excluded, failed — and where the inventory is.
            if let reconciliation = receipt.reconciliationLine {
                Text(reconciliation)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("export.receipt.reconciliation")
            }
            if let inventory = receipt.inventoryPath {
                Text(String(localized: "Inventory: \((inventory as NSString).lastPathComponent) — every file with its SHA-256, beside the files"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .help(inventory)
                    .accessibilityIdentifier("export.receipt.inventory")
            }

            // R1: where the file stands after the write — waiting, or what the hand-off did.
            if let delivery = Self.deliveryLine(receipt) {
                Text(delivery)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.receipt.delivery")
            }

            if let error = receipt.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verification = receipt.verificationLine {
                Text(verification)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.receipt.verification")
            }
            // OUT-04: the content statement, apart from the byte re-hash above.
            if let content = receipt.contentLine {
                Text(content)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(receipt.contentReportPath ?? content)
                    .accessibilityIdentifier("export.receipt.content")
            }
            // R8: what Recover and resume found.
            if let recovery = receipt.recoveryLine {
                Text(recovery)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(receipt.recoveryDetail ?? recovery)
                    .accessibilityIdentifier("export.receipt.recovery")
            }

            Text(receipt.destinationURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(receipt.destination)

            if let hash = receipt.sha256Hex {
                HStack(spacing: 4) {
                    Text("SHA-256 \(hash.prefix(16))…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button {
                        PlatformClipboard.copyString(hash)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the full SHA-256")
                    .accessibilityLabel("Copy SHA-256")
                }
            }

            HStack(spacing: 8) {
                if receipt.isResumable {
                    Button {
                        center.resume(receipt)
                    } label: {
                        Label("Resume", systemImage: "arrow.clockwise")
                    }
                    .font(.system(size: 11))
                    .help("Continue this export from message \((receipt.resumeRequest?.skipFirst ?? 0) + 1); what was written stays")
                    .accessibilityIdentifier("export.receipt.resume")
                }
                // R8 / OUT-06a: the partial file could not be cut back when the run
                // stopped (drive removed, mailin quit) — recover it once it is back.
                if receipt.offersRecovery {
                    Button {
                        Task { await center.recoverAndResume(receipt) }
                    } label: {
                        Label(String(localized: "Recover and resume"), systemImage: "arrow.uturn.forward")
                    }
                    .font(.system(size: 11))
                    .disabled(center.recoveringReceiptID != nil)
                    .help(String(localized: "Find the last verified boundary in the partial file, cut away what no checkpoint vouches for, and continue from there"))
                    .accessibilityIdentifier("export.receipt.recover")
                }
                if receipt.offersExportAgain {
                    Button {
                        center.exportAgain(receipt)
                    } label: {
                        Label(String(localized: "Export again"), systemImage: "arrow.counterclockwise")
                    }
                    .font(.system(size: 11))
                    .help(String(localized: "Start this export again from the first message; the partial file is replaced"))
                    .accessibilityIdentifier("export.receipt.exportAgain")
                }
                // R06: the files are there, the record is not — finish it here, from the kept manifest.
                if receipt.outcome == .unverified {
                    Button {
                        Task { await center.finishInventory(receipt) }
                    } label: {
                        Label(String(localized: "Finish inventory"), systemImage: "list.bullet.clipboard")
                    }
                    .font(.system(size: 11))
                    .help(String(localized: "Build the inventory from the kept manifest and re-hash every file; nothing is rewritten"))
                    .accessibilityIdentifier("export.receipt.finishInventory")
                } else if receipt.destination != "—", receipt.isFolder ? receipt.inventoryPath != nil : receipt.written > 0 {
                    // A folder needs its inventory; a single mbox / PST / .eml is re-hashed against the receipt.
                    Button {
                        Task { await center.verifyExport(receipt) }
                    } label: {
                        Label(String(localized: "Verify export"), systemImage: "checkmark.shield")
                    }
                    .font(.system(size: 11))
                    .help(String(localized: "Re-read what was written: the bytes against the recorded hashes, then every message parsed back and compared with the archive"))
                    .accessibilityIdentifier("export.receipt.verify")
                }
                #if os(iOS)
                // IPAD-09 / R1: the written file is still inside mailin — offer it again,
                // or stop waiting for a hand-off that is on its way.
                if center.deliveringReceiptID == receipt.id {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "Cancel")) { center.cancelDelivery() }
                        .font(.system(size: 11))
                        .accessibilityIdentifier("export.receipt.cancelDelivery")
                } else if receipt.destination != "—", !receipt.isDelivered {
                    Button {
                        center.deliver(receipt)
                    } label: {
                        Label(String(localized: "Save or share…"), systemImage: "square.and.arrow.up")
                    }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("export.receipt.shareAgain")
                    Button {
                        center.deliver(receipt, using: { await PlatformExport.saveToFilesAndWait($0) })
                    } label: {
                        Label(String(localized: "Save to Files…"), systemImage: "folder")
                    }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("export.receipt.saveToFiles")
                }
                #endif
                #if os(macOS)
                if receipt.destination != "—" {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([receipt.destinationURL])
                    }
                    .font(.system(size: 11))
                    .help("Show the exported file or folder in Finder")
                }
                Button(receiptSaveNote ?? String(localized: "Save receipt…")) { saveReceipt(receipt) }
                    .font(.system(size: 11))
                    .help(receiptSaveNote ?? String(localized: "Save this receipt as plain text"))
                #endif
                Spacer()
                Text(receipt.completedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 300)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 32)
        .transition(.opacity)
        .accessibilityIdentifier("export.receipt")
    }

    /// R1: the receipt's delivery state in the person's language. Nil where
    /// nothing is handed on after writing (Mac).
    static func deliveryLine(_ receipt: ExportReceipt) -> String? {
        guard let delivery = receipt.delivery else { return nil }
        switch delivery {
        case .awaitingDelivery:
            return String(localized: "Written — waiting for you to save or share it")
        case .failed where receipt.outcome == .complete:
            return nil   // the verdict line already carries the reason
        case .saved, .shared, .notSaved, .failed:
            return receipt.deliveryNote
        }
    }

    /// IPAD-09: a file written but not handed on is not shown as a green "Complete".
    private func icon(for receipt: ExportReceipt) -> String {
        receipt.isDelivered ? icon(for: receipt.outcome) : "tray.and.arrow.up"
    }

    private func color(for receipt: ExportReceipt) -> Color {
        receipt.isDelivered ? color(for: receipt.outcome) : .orange
    }

    private func icon(for outcome: ExportReceipt.Outcome) -> String {
        switch outcome {
        case .complete: return "checkmark.seal.fill"
        case .truncated, .partial: return "exclamationmark.circle.fill"
        case .unverified: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for outcome: ExportReceipt.Outcome) -> Color {
        switch outcome {
        case .complete: return .green
        case .truncated, .partial, .unverified: return .orange
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }

    #if os(macOS)
    private func saveReceipt(_ receipt: ExportReceipt) {
        let panel = ManagedSavePanel()
        panel.nameFieldStringValue = "mailin-export-receipt.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try receipt.plainText().write(to: url, atomically: true, encoding: .utf8)
            receiptSaveNote = String(localized: "Receipt saved")
        } catch {
            receiptSaveNote = String(localized: "Receipt not saved: \(error.localizedDescription)")
        }
    }
    #endif
}
