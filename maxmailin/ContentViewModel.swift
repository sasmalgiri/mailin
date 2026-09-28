@testable import ArchiveCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import zlib
import CryptoKit
import os

@MainActor
class ContentViewModel: ObservableObject {
    private static let importLogger = Logger(subsystem: "com.ecosanskriti.mailin",
                                             category: "Import")

    @Published var senderEmail: String = ""
    @Published var selectedFiles: [URL] = []
    @Published var statusMessage = "No file selected."
    @Published var statusColor: Color = .gray
    @Published var aiPrompt: String = ""
    @Published var aiResponse: String = ""
    @Published var isParsed: Bool = false
    @Published var subjectList: [String] = []
    @Published var detectedDateRange: (Date?, Date?) = (nil, nil)

    @Published var loadingProgress: Double = 0.0
    @Published var loadingText: String = ""
    @Published var parseErrors: [String] = []
    @Published var memoryUsageMB: Double = 0.0
    @Published var duplicatesRemoved: Int = 0
    @Published private(set) var removedDuplicates: [DuplicateFinding] = []

    // Part Q/R: the legacy in-RAM corpus preview array is GONE. The SQLite
    // archive is the only email authority; list surfaces page it through
    // ArchiveDataService. `totalParsedCount` is the store-backed archive
    // count (committed truth), never an array count.
    @Published var totalParsedCount: Int = 0

    /// The capability matrix, injected by the shell. Import reads it here
    /// because `BulkImportCoordinator` is not main-actor and must not hold the
    /// registry. Nil in previews and tests, where every capability reads as
    /// off — which is the conservative direction: a test gets the proven
    /// streaming engine unless it asks otherwise.
    var isCapabilityOn: (@MainActor (Capability) -> Bool)?

    private(set) var metadata: [String: Any] = [:]
    private var isParsing = false
    private var memoryMonitorTask: Task<Void, Never>?
    private var pendingTempDirs: [URL] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        statusMessage = "Please enter your sender email to begin."
        monitorMemoryPressure()
    }

    deinit {
        memoryMonitorTask?.cancel()
        memoryPressureSource?.cancel()
    }

    nonisolated private static let streamingThreshold: Int64 = 100_000_000 // 100MB

    enum MemoryPressure { case normal, elevated, critical }

    nonisolated private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    nonisolated static func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }

    nonisolated static func checkMemoryPressure() -> (availableMB: Double, pressure: MemoryPressure) {
        let usedMB = currentMemoryUsageMB()
        let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0)
        let availableMB = max(0, totalMB - usedMB)
        let pressure: MemoryPressure
        if availableMB < 256 || usedMB > totalMB * 0.85 {
            pressure = .critical
        } else if availableMB < 1024 || usedMB > totalMB * 0.65 {
            pressure = .elevated
        } else {
            pressure = .normal
        }
        return (availableMB, pressure)
    }

    nonisolated func shouldUseStreaming(for url: URL) -> Bool {
        let size = fileSize(at: url)
        if size > Self.streamingThreshold { return true }
        let (_, pressure) = Self.checkMemoryPressure()
        if pressure == .elevated && size > 50_000_000 { return true }
        if pressure == .critical && size > 10_000_000 { return true }
        return false
    }

    private func startMemoryMonitoring() {
        memoryMonitorTask?.cancel()
        memoryMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.memoryUsageMB = ContentViewModel.currentMemoryUsageMB()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopMemoryMonitoring() {
        memoryMonitorTask?.cancel()
        memoryMonitorTask = nil
    }

    // MARK: - System Memory Pressure Monitoring

    private func monitorMemoryPressure() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in
            let event = source.data
            if event.contains(.critical) {
                Task { @MainActor in
                    self?.releaseNonEssentialCaches()
                }
            } else if event.contains(.warning) {
                Task { @MainActor in
                    // On warning, release derived caches but keep emails.
                    // (The legacy in-RAM EmailSearchIndex is no longer built,
                    // so there is nothing index-related left to drop here.)
                    self?.subjectList.removeAll()
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func releaseNonEssentialCaches() {
        // Release the subject list cache. (No in-RAM corpus exists anymore —
        // search and browse run through the SQLite/FTS5 substrate.)
        subjectList.removeAll()
    }

    // MARK: - Zip import
    //
    // v2.1 backlog #1: ZIP and gzip archives are containers to the import
    // funnel like any other source. `ParserFactory` extracts one member at a
    // time to scratch through `ZIPArchiveReader` (streamed, size- and
    // CRC-checked, deleted after parsing), so the whole-archive-in-memory
    // extractor that used to live here — with its 500 MB "safety cap" and no
    // checksum — is gone. Skipped and refused members are counted in the
    // import report's categories.


// MARK: - Import (delegates to BulkImportCoordinator — the sole production engine)

    /// The single production import engine (P0 cutover). Owned here so every
    /// entry point that funnels through this view model shares checkpoint,
    /// receipt, and per-run accounting state.
    let importCoordinator = BulkImportCoordinator()

    /// Thin delegating wrapper: every production entry point (open panel,
    /// fileImporter, drag/drop, Thunderbird, Apple Mail, zip members,
    /// Shortcuts, open-with-app) converges here, and the pipeline itself —
    /// hashing, checkpointed streaming parse, batched persist + FTS index,
    /// signed receipt — runs in BulkImportCoordinator. This wrapper keeps
    /// only UI side effects: progress publishing, forensic bookkeeping,
    /// widget/notification updates and temp-dir cleanup. No email preview is
    /// accumulated in RAM — list surfaces page the store after completion.
    ///
    /// **Invariant: call this only from `ContentView.startImport`.** That is
    /// the single place that decides whether the pre-import sheet is shown
    /// (`Capability.guidedImport`) and what is enqueued
    /// (`Capability.importQueue`). The doc comment above says every entry
    /// point "converges here", and for a while that was untrue: the
    /// Thunderbird button called a wrapper that came straight to this method,
    /// so it got no sheet and never appeared in the queue while Apple Mail
    /// import — the adjacent button — behaved correctly. The wrapper is gone
    /// and this now has exactly one production caller; keep it that way, or
    /// the capability switches stop meaning anything for the new route.
    func parseSelectedFiles(_ urls: [URL], removeDuplicates: Bool = true, maxEmails: Int? = nil,
                            copiesOriginals: Bool = true) {
        parseSelectedFiles(urls, dedupPolicy: removeDuplicates ? .messageID : .preserveAll,
                           maxEmails: maxEmails, copiesOriginals: copiesOriginals)
    }

    /// The import options, built from the user's choices and the capability
    /// switches. Pure and static so the wiring is testable without a run:
    /// audit F18 found the sheet's dedup choice collapsed to a Boolean on the
    /// way here, and F02 found locator recording tied to a READ switch.
    nonisolated static func importOptions(dedupPolicy: DedupPolicy,
                                          copiesOriginals: Bool,
                                          maxEmails: Int?,
                                          senderEmail: String,
                                          useOffsetEngine: Bool) -> BulkImportCoordinator.Options {
        BulkImportCoordinator.Options(
            batchSize: 500,
            senderEmail: senderEmail,
            maxEmails: maxEmails,
            dedupPolicy: dedupPolicy,
            copiesOriginals: copiesOriginals,
            useOffsetEngine: useOffsetEngine,
            // Locators are the only content a message above the full-parse
            // ceiling has, so they are recorded whenever the offset engine
            // runs. The `locatorReads` switch gates READS only (audit F02).
            recordLocators: useOffsetEngine
        )
    }

    func parseSelectedFiles(_ urls: [URL], dedupPolicy: DedupPolicy, maxEmails: Int? = nil,
                            copiesOriginals: Bool = true) {
        guard !isParsing else { return }

        statusMessage = "Parsing files..."
        statusColor = .blue
        isParsed = false
        selectedFiles = urls
        loadingProgress = 0.0
        loadingText = "Initializing..."
        isParsing = true
        parseErrors = []
        duplicatesRemoved = 0
        startMemoryMonitoring()
        let forensicEnabled = UserDefaults.standard.bool(forKey: "forensicModeEnabled")

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Chain-of-custody hashes of each source file (legacy parity).
            var fileHashes: [ForensicManager.SourceFileHash] = []
            if forensicEnabled {
                fileHashes = await Task.detached(priority: .utility) {
                    urls.compactMap { ForensicManager.computeHashes(for: $0) }
                }.value
            }

            var callbacks = BulkImportCoordinator.Callbacks()
            callbacks.onFileProgress = { [weak self] name, idx, count, prog in
                guard let self else { return }
                let totalFiles = Double(max(1, count))
                self.loadingProgress = (Double(idx) + prog) / totalFiles
                self.loadingText = "Importing \(name): \(Int(prog * 100))%"
                // A4: the run may take files out of order (queue reordering),
                // so the file is found by name, not by position.
                let fileURL = urls.first { $0.lastPathComponent == name }
                let sizeBytes = fileURL.map { self.fileSize(at: $0) } ?? 0
                ImportProgressNotifier.shared.updateProgress(
                    filename: name,
                    current: idx + 1,
                    total: count,
                    bytesProcessed: Int64(prog * Double(sizeBytes)),
                    totalBytes: sizeBytes
                )
                // A4: advance the session queue. Without this the queue only
                // ever received `enqueue`, so every import sat at "Waiting"
                // forever — including after it had finished — while the
                // capability described "pending, running and finished imports,
                // each with its verdict". Keyed by path because the queue may
                // hold several entries with the same filename.
                if let fileURL {
                    ImportQueue.shared.markRunning(path: fileURL.path, fraction: prog)
                }
            }
            // A4: the queue's order is the run's order for files not yet started.
            callbacks.nextSource = { remaining in ImportQueue.shared.preferredNext(among: remaining) }
            // (C1) Forensic email hashes over every COMMITTED batch, so hash
            // coverage matches the persisted corpus, not just the preview.
            if forensicEnabled {
                callbacks.onCommittedBatch = { batch in
                    ForensicManager.shared.storeEmailHashes(batch)
                }
            }

            // S4: the engine choice is the matrix switch, read here because
            // the coordinator is not main-actor (on by default in 3.0).
            let useOffsetEngine = self.isCapabilityOn?(.offsetParser) ?? false
            let options = Self.importOptions(dedupPolicy: dedupPolicy,
                                             copiesOriginals: copiesOriginals,
                                             maxEmails: maxEmails,
                                             senderEmail: self.senderEmail,
                                             useOffsetEngine: useOffsetEngine)

            do {
                let summary = try await self.importCoordinator.runImport(
                    urls: urls, options: options, callbacks: callbacks
                )
                self.finishImport(urls: urls, summary: summary, fileHashes: fileHashes)
            } catch is CancellationError {
                self.isParsing = false
                self.stopMemoryMonitoring()
                self.statusMessage = "Import cancelled."
                self.statusColor = .orange
                self.loadingProgress = 0.0
                self.loadingText = ""
                ImportProgressNotifier.shared.cancelProgress()
            } catch {
                self.isParsing = false
                self.stopMemoryMonitoring()
                self.parseErrors = [error.localizedDescription]
                self.statusMessage = "Import failed: \(error.localizedDescription)"
                self.statusColor = .red
                self.isParsed = false
                self.loadingProgress = 0.0
                self.loadingText = ""
                ImportProgressNotifier.shared.cancelProgress()
            }
        }
    }

    /// Completion side effects for a coordinator run: per-run accounting
    /// (committed truth, Part B4), forensic bookkeeping, widget/notification
    /// updates, temp-dir cleanup. List surfaces re-page the store on the
    /// `.parsingFinished` notification — nothing is materialized here.
    private func finishImport(
        urls: [URL],
        summary: BulkImportCoordinator.RunSummary,
        fileHashes: [ForensicManager.SourceFileHash]
    ) {
        isParsing = false
        stopMemoryMonitoring()

        // A4: close out the session queue with the SAME verdict the receipt
        // carries, derived from the same reconciliation — a queue that said
        // "done" beside a receipt that said "partial" would be worse than no
        // queue. Per-file granularity is not available here (the summary is
        // run-scoped), so a file that failed outright is marked failed by name
        // and everything else takes the run verdict. That is stated in the
        // queue UI rather than implied.
        let failedNames = Set(summary.fileErrors.map(\.filename))
        let stoppedByUser = Dictionary(summary.stoppedByUser.map { ($0.filename, $0.messagesCommitted) },
                                       uniquingKeysWith: { first, _ in first })
        let runVerdict = summary.receipt.map(ImportReconciler.verdict(for:))
        for url in urls {
            if failedNames.contains(url.lastPathComponent) {
                let reason = summary.fileErrors
                    .first { $0.filename == url.lastPathComponent }?.message
                    ?? "This file could not be imported."
                ImportQueue.shared.markFailed(path: url.path, reason: reason)
            } else if let committed = stoppedByUser[url.lastPathComponent] {
                // A4: stopped by the user — not a failure, checkpoint kept.
                ImportQueue.shared.markStopped(path: url.path, messages: committed)
            } else if let runVerdict {
                ImportQueue.shared.markFinished(path: url.path, verdict: runVerdict,
                                                messages: summary.persistAttempted)
            } else {
                // No receipt means no verdict was computed — say so rather
                // than inventing "Complete".
                ImportQueue.shared.markFailed(
                    path: url.path,
                    reason: "Import finished but no receipt was written, so its outcome could not be verified.")
            }
        }
        // Anything still pending after the run ended never started.
        ImportQueue.shared.markRemainingCancelled()

        // A3: the sheet's indexing choice takes effect now, not at next launch.
        if ImportChoices.indexAttachmentTextDefault() {
            AttachmentTextIndexJob.shared.kickIfNeeded()
        }

        // Post the import document: the run's number for custody logs and
        // intake references (IMP-2026-0001).
        let fileNames = urls.map(\.lastPathComponent).joined(separator: ", ")
        let persisted = summary.persistAttempted
        Task { @MainActor in
            _ = await DocumentRegistry.post(
                .importRun,
                summary: "\(persisted) email(s) from \(fileNames)",
                refs: fileNames)
        }

        var errors = summary.fileErrors.map { "\($0.filename): \($0.message)" }
        if summary.persistFailed > 0 {
            errors.append("\(summary.persistFailed) email(s) could not be saved to the archive and were not imported. Please retry; if this persists, free up disk space and check the log.")
            Self.importLogger.error("Import completed with \(summary.persistFailed, privacy: .public) unpersisted email(s)")
        }
        errors.append(contentsOf: summary.warnings)
        parseErrors = errors

        // Committed truth (Part B4): report what actually reached the store
        // this run, never parsed counts. When the store count was
        // unavailable, the persist-attempted count is the honest upper bound
        // (and the message says so).
        let committed = summary.inserted ?? summary.persistAttempted

        // Whole-run no-op: nothing parsed AND nothing skipped → nothing found.
        if summary.parsed == 0 && summary.skippedFiles == 0 {
            let fileNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")
            if summary.fileErrors.isEmpty {
                let extensions = urls.map { $0.pathExtension.lowercased() }
                let supported = Set(ParserFactory.allSupportedExtensions)
                let unsupported = extensions.filter { !supported.contains($0) && !$0.isEmpty }
                if !unsupported.isEmpty {
                    statusMessage = "Unsupported format: .\(unsupported.first ?? "unknown"). Supported: \(ParserFactory.allSupportedExtensions.map { ".\($0)" }.joined(separator: ", "))"
                } else {
                    statusMessage = "No emails found in \(fileNames). The file may be empty or contain no recognizable email messages."
                }
            } else {
                let errorSummary = summary.fileErrors.prefix(3).map { "\($0.filename): \($0.message)" }.joined(separator: "; ")
                statusMessage = "Failed to parse \(fileNames): \(errorSummary)"
            }
            statusColor = .orange
            isParsed = false
            loadingProgress = 0.0
            loadingText = ""
            ImportProgressNotifier.shared.cancelProgress()
            return
        }

        for hash in fileHashes {
            ForensicManager.shared.registerFileHash(hash)
        }

        // The SQLite store holds the full, deduped archive (persisted per
        // batch by the coordinator); the committed count comes from the
        // coordinator's per-run accounting and is refreshed below from the
        // store total (the authority).
        totalParsedCount = committed
        isParsed = true
        Task { @MainActor [weak self] in
            if let total = try? await ArchiveDataService.shared.count(), total > 0 {
                self?.totalParsedCount = total
            }
        }
        updateMetadataDisplay()
        // THIS RUN's duplicates (findings delta), not the store-wide total.
        duplicatesRemoved = summary.duplicates ?? 0
        removedDuplicates = []

        ForensicManager.shared.logAction("Import Complete", detail: "Imported \(committed) emails from \(urls.count) file(s) into SQLite + FTS5.")

        var notes: [String] = []
        if summary.damaged > 0 { notes.append("\(summary.damaged) unparseable skipped") }
        if let dups = summary.duplicates, dups > 0 { notes.append("\(dups) duplicate(s) skipped") }
        if summary.skippedFiles > 0 { notes.append("\(summary.skippedFiles) file(s) already imported") }
        if summary.cappedAtLimit { notes.append("free-tier limit reached") }
        if summary.ftsDegraded { notes.append("search index will finish updating on next launch") }
        if !summary.receiptPersisted { notes.append("import receipt could not be saved") }
        let noteText = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"

        if summary.fileErrors.isEmpty && summary.persistFailed == 0 {
            if summary.inserted == nil {
                statusMessage = "Imported up to \(committed) emails from \(urls.count) file(s) — final count unavailable.\(noteText)"
                statusColor = .orange
            } else {
                statusMessage = "Imported \(committed) new emails from \(urls.count) file(s).\(noteText)"
                statusColor = notes.isEmpty ? .green : .orange
            }
        } else {
            let issueCount = summary.fileErrors.count + (summary.persistFailed > 0 ? 1 : 0)
            let errorHint = summary.fileErrors.first.map { " (\($0.filename): \($0.message))" } ?? ""
            statusMessage = "Imported \(committed) new emails. \(issueCount) issue(s)\(errorHint).\(noteText)"
            statusColor = .orange
        }
        loadingProgress = 1.0
        loadingText = "Done!"
        cleanupTempDirs()

        // Notify import completion via system notification
        let importFilename = urls.count == 1 ? urls.first?.lastPathComponent ?? "archive" : "\(urls.count) files"
        ImportProgressNotifier.shared.completeImport(filename: importFilename, count: committed)

        // Update widget data from bounded services (aggregate top
        // senders + a few recent summaries) — never the whole corpus.
        let widgetImportName = urls.first?.lastPathComponent
        Task { @MainActor in
            let snap = try? await ArchiveAggregateService.shared.snapshot(topLimit: 5)
            let recent = (try? await ArchiveDataService.shared.page(query: .all, cursor: nil, limit: 5))?.summaries ?? []
            WidgetDataProvider.shared.updateWidgetData(
                totalEmails: snap?.total ?? 0,
                importFilename: widgetImportName,
                topSenders: snap?.topSenders.map(\.value) ?? [],
                recentSubjects: recent.map(\.subject)
            )
        }

        NotificationCenter.default.post(name: .parsingFinished, object: nil)
        // (Part F: the legacy in-RAM EmailSearchIndex is no longer built —
        // the FTS5 index was already updated during persist.)
    }

    // MARK: - Thunderbird Auto-Import

    @Published var thunderbirdProfiles: [URL] = []

    func scanForThunderbirdProfiles() {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profilesDir = home.appendingPathComponent("Library/Thunderbird/Profiles")
        let fm = FileManager.default
        guard fm.fileExists(atPath: profilesDir.path) else {
            thunderbirdProfiles = []
            return
        }
        do {
            let profiles = try fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil)
            var mboxFiles: [URL] = []
            for profile in profiles {
                let mailDir = profile.appendingPathComponent("Mail")
                guard fm.fileExists(atPath: mailDir.path) else { continue }
                if let enumerator = fm.enumerator(at: mailDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                    while let file = enumerator.nextObject() as? URL {
                        let ext = file.pathExtension.lowercased()
                        if ext.isEmpty && !file.hasDirectoryPath {
                            let name = file.lastPathComponent
                            if ["Inbox", "Sent", "Drafts", "Trash", "Junk", "Archives"].contains(where: { name.localizedCaseInsensitiveContains($0) }) ||
                               (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 1024 {
                                mboxFiles.append(file)
                            }
                        } else if ext == "mbox" {
                            mboxFiles.append(file)
                        }
                    }
                }
            }
            thunderbirdProfiles = mboxFiles
        } catch {
            thunderbirdProfiles = []
        }
        #else
        thunderbirdProfiles = []
        #endif
    }

    // `importThunderbirdProfile` is deliberately GONE rather than deprecated.
    //
    // It did nothing but forward to `parseSelectedFiles`, which meant the
    // Thunderbird button skipped the shared import funnel in `ContentView`
    // (`beginImport`): no pre-import sheet for a user who had switched one on,
    // and no entry in the import queue, so the import was invisible there.
    // Apple Mail import, right next to it in the UI, went through the funnel
    // correctly — two routes, different behaviour, nothing to tell them apart.
    //
    // Leaving a deprecated forwarder would leave the bypass available. Callers
    // use `handleMultipleFiles`, which is the one place that decides whether
    // to show the sheet and what to enqueue.

    // MARK: - Apple Mail Auto-Import

    @Published var appleMailBoxes: [URL] = []

    func scanForAppleMailBoxes() {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mailDir = home.appendingPathComponent("Library/Mail")
        let fm = FileManager.default
        guard fm.fileExists(atPath: mailDir.path) else {
            appleMailBoxes = []
            return
        }
        var emlxDirs: [URL] = []
        if let enumerator = fm.enumerator(at: mailDir, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "emlx" {
                    let dir = url.deletingLastPathComponent()
                    if !emlxDirs.contains(dir) {
                        emlxDirs.append(dir)
                    }
                }
            }
        }
        appleMailBoxes = emlxDirs
        #else
        appleMailBoxes = []
        #endif
    }

    // MARK: - Metadata/AI
    /// Stage 5 W2-B: metadata (top subjects + date range) now comes from bounded
    /// SQL aggregates over the SQLite store, not a whole-archive `[RawEmail]`
    /// scan. Signature kept synchronous; the bounded aggregate fetch runs in a
    /// MainActor Task so callers are unchanged.
    func autoDetectMetadata() {
        guard isParsed else {
            statusMessage = "Parse a file first."
            statusColor = .orange
            return
        }
        Task { @MainActor in
            do {
                let snap = try await ArchiveAggregateService.shared.snapshot(topLimit: 200)
                self.subjectList = snap.topSubjects.map { $0.value }
                self.detectedDateRange = (snap.minDate, snap.maxDate)
                self.statusMessage = "Metadata detected: \(self.subjectList.count) subjects."
                self.statusColor = .blue
            } catch {
                // Non-fatal: keep any prior metadata rather than clearing it.
            }
        }
    }

    /// Part G4: answers come from bounded SQL aggregates over the SQLite store
    /// (COUNT / GROUP BY), never whole-array walks over the resident preview.
    /// Signature kept synchronous (autoDetectMetadata precedent); the bounded
    /// aggregate fetch runs in a MainActor Task and publishes `aiResponse`.
    func runAIQuery() {
        guard isParsed else {
            aiResponse = "Please parse a file first."
            return
        }
        let lower = aiPrompt.lowercased()
        if lower.contains("how many") && lower.contains("sent") {
            Task { @MainActor in
                let counts = try? await ArchiveAggregateService.shared.sentReceivedCounts(senderEmail: self.senderEmail)
                self.aiResponse = "Total sent emails: \(counts?.sent ?? 0)"
            }
        } else if lower.contains("how many") && lower.contains("received") {
            Task { @MainActor in
                let counts = try? await ArchiveAggregateService.shared.sentReceivedCounts(senderEmail: self.senderEmail)
                self.aiResponse = "Total received emails: \(counts?.received ?? 0)"
            }
        } else if lower.contains("top subject") {
            Task { @MainActor in
                let subjects = (try? await ArchiveAggregateService.shared.topSubjects(limit: 5)) ?? []
                self.aiResponse = "Top Subjects:\n" + subjects.map { "\($0.value): \($0.count)" }.joined(separator: "\n")
            }
        } else if lower.contains("reply frequency") {
            Task { @MainActor in
                let freq = (try? await ArchiveAggregateService.shared.replyRecipientCounts(senderEmail: self.senderEmail)) ?? [:]
                let summary = freq.sorted { $0.value > $1.value }.prefix(5)
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n")
                self.aiResponse = "Top Reply Recipients:\n" + summary
            }
        } else {
            aiResponse = "Sorry, I didn't understand that. Try asking about 'sent emails', 'received emails', 'top subjects', or 'reply frequency'."
        }
    }

    // (Part R) The in-RAM smart-dedup and sent/received annotation passes are
    // gone with the preview array: dedup happens at insert (message-id
    // uniqueness in the store + coordinator duplicate accounting) and
    // sent/received is derived at parse time from `senderEmail`.

    private func updateMetadataDisplay() {
        autoDetectMetadata()
    }

    // Reply frequency moved to ArchiveAggregateService.replyRecipientCounts
    // (Part G4): a bounded SQL GROUP BY over the store — no preview-array walk.

    // MARK: - Clear all parsed state
    private func cleanupTempDirs() {
        for dir in pendingTempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        pendingTempDirs.removeAll()
    }

    func clearParsedData() {
        cleanupTempDirs()
        removedDuplicates = []
        totalParsedCount = 0
        isParsed = false
        subjectList = []
        detectedDateRange = (nil, nil)
        loadingProgress = 0.0
        loadingText = ""
        parseErrors = []
        duplicatesRemoved = 0
        statusMessage = "Data cleared. Select a new file to begin."
        statusColor = .gray
    }

    /// Guarded deletion path (Part M): durable delete from the FTS index then
    /// the SQLite authority. Returns whether the delete durably succeeded, so
    /// callers holding resident page windows mutate only after the authority
    /// confirms. The removed emails are recorded as duplicate findings (they
    /// are fetched from the store BEFORE deletion, bounded by the user's
    /// selection) so the "removed duplicates" review sheet keeps working.
    @discardableResult
    func removeEmailsAwaitingResult(ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return true }
        let removed = (try? await ArchiveDataService.shared.fullEmails(ids: Array(ids))) ?? []
        // Durably delete from the FTS index then the SQLite authority so
        // removed emails don't linger as searchable ghost rows (store↔FTS
        // drift). FTS-first (matches the repository's delete ordering): a
        // mid-delete failure leaves a canonical row that reconcile can
        // restore, never a ghost FTS row. Failures are surfaced (Part B3 —
        // never `try?`-swallow a correctness error).
        do {
            for id in ids {
                try await FTSSearchIndex.shared.delete(id: id)
            }
            try await SQLiteEmailStore.shared.delete(ids: ids)
            // Content-affecting mutation: bump the corpus revision so derived
            // state (Parts I–M) can detect staleness. Best-effort — the delete
            // itself already succeeded.
            _ = try? await ArchiveCorpusRevision.shared.bump()
            duplicatesRemoved += removed.count
            removedDuplicates.append(contentsOf: removed.map { DuplicateFinding(from: $0, reason: "removed") })
            totalParsedCount = (try? await ArchiveDataService.shared.count()) ?? max(0, totalParsedCount - ids.count)
            return true
        } catch {
            Self.importLogger.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Delete failed: \(error.localizedDescription). The emails were not removed."
            statusColor = .red
            return false
        }
    }

    // MARK: - Direct email ingestion (sample data / cloud fetch)

    /// Persist already-parsed emails (bundled sample data, cloud/IMAP fetches)
    /// into the SQLite authority + FTS index — the same substrate file imports
    /// land in. Nothing is retained in RAM; callers refresh their paged
    /// surfaces via `.parsingFinished`.
    func ingestEmails(_ emails: [MBOXParser.RawEmail], sourceLabel: String) async {
        guard !emails.isEmpty else { return }
        do {
            let result = try await SQLiteEmailStore.shared.insertBatch(
                emails, sourceFileHash: nil, accountID: nil,
                sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
                batchSize: 200, progress: nil)
            try await FTSSearchIndex.shared.indexBatch(emails)
            _ = try? await ArchiveCorpusRevision.shared.bump()
            totalParsedCount = (try? await ArchiveDataService.shared.count()) ?? totalParsedCount
            isParsed = totalParsedCount > 0
            updateMetadataDisplay()
            let added = result.insertedIDs.count
            var msg = "Added \(added) email\(added == 1 ? "" : "s") from \(sourceLabel)."
            let skipped = result.blockedByTombstoneIDs.count
            if skipped > 0 {
                msg += " \(skipped) previously-deleted email\(skipped == 1 ? "" : "s") skipped — Settings ▸ Deleted Emails to allow re-import."
            }
            statusMessage = msg
            statusColor = .green
            NotificationCenter.default.post(name: .parsingFinished, object: nil)
        } catch {
            statusMessage = "Failed to save emails from \(sourceLabel): \(error.localizedDescription)"
            statusColor = .red
        }
    }

    nonisolated static func formatByteCount(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
    }

    // MARK: - Export as EML (full MIME)
    nonisolated func exportEmailAsEML(_ email: MBOXParser.RawEmail) -> String {
        if !email.rawSource.isEmpty && email.rawSource.contains("MIME-Version") {
            let source = email.rawSource
            if source.hasPrefix("From ") {
                if let firstNewline = source.firstIndex(of: "\n") {
                    return String(source[source.index(after: firstNewline)...])
                }
            }
            return source
        }

        let boundary = "mailin-eml-\(UUID().uuidString)"
        var lines: [String] = []

        let orderedKeys = ["From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID", "In-Reply-To", "References"]
        for key in orderedKeys {
            if let value = email.headers[key], !value.isEmpty {
                lines.append("\(key): \(value)")
            }
        }
        for (key, value) in email.headers where !orderedKeys.contains(key) && !value.isEmpty {
            lines.append("\(key): \(value)")
        }
        lines.append("MIME-Version: 1.0")

        let hasHTML = !email.htmlBody.isEmpty
        let hasAttachments = !email.attachments.isEmpty && email.attachments.contains(where: { $0.base64 != nil })

        if hasAttachments {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")

            if hasHTML && !email.plainBody.isEmpty {
                let altBoundary = "mailin-alt-\(UUID().uuidString)"
                lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
                lines.append("")
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/plain; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(email.plainBody))
                lines.append("--\(altBoundary)")
                lines.append("Content-Type: text/html; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(email.htmlBody))
                lines.append("--\(altBoundary)--")
            } else if hasHTML {
                lines.append("Content-Type: text/html; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(email.htmlBody))
            } else {
                lines.append("Content-Type: text/plain; charset=utf-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
                lines.append("")
                lines.append(quotedPrintableEncode(email.plainBody))
            }

            for attachment in email.attachments {
                guard let b64 = attachment.base64, !b64.isEmpty else { continue }
                lines.append("--\(boundary)")
                lines.append("Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"")
                lines.append("Content-Disposition: attachment; filename=\"\(attachment.filename)\"")
                lines.append("Content-Transfer-Encoding: base64")
                if let cid = attachment.contentID, !cid.isEmpty {
                    lines.append("Content-ID: <\(cid)>")
                }
                lines.append("")
                let lineWrapped = stride(from: 0, to: b64.count, by: 76).map { start in
                    let end = min(start + 76, b64.count)
                    let startIdx = b64.index(b64.startIndex, offsetBy: start)
                    let endIdx = b64.index(b64.startIndex, offsetBy: end)
                    return String(b64[startIdx..<endIdx])
                }.joined(separator: "\r\n")
                lines.append(lineWrapped)
            }
            lines.append("--\(boundary)--")
        } else if hasHTML && !email.plainBody.isEmpty {
            let altBoundary = "mailin-alt-\(UUID().uuidString)"
            lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
            lines.append("")
            lines.append("--\(altBoundary)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(email.plainBody))
            lines.append("--\(altBoundary)")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(email.htmlBody))
            lines.append("--\(altBoundary)--")
        } else if hasHTML {
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(email.htmlBody))
        } else {
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(quotedPrintableEncode(email.plainBody))
        }

        return lines.joined(separator: "\r\n")
    }

    private nonisolated func quotedPrintableEncode(_ text: String) -> String {
        var result = ""
        var lineLength = 0
        for char in text {
            if char == "\n" {
                result += "\r\n"
                lineLength = 0
            } else if char == "\r" {
                continue
            } else if char.isASCII, let ascii = char.asciiValue, ascii >= 32 && ascii <= 126 && char != "=" {
                if lineLength >= 75 { result += "=\r\n"; lineLength = 0 }
                result.append(char)
                lineLength += 1
            } else {
                for byte in String(char).utf8 {
                    if lineLength >= 73 { result += "=\r\n"; lineLength = 0 }
                    result += String(format: "=%02X", byte)
                    lineLength += 3
                }
            }
        }
        return result
    }

    // MARK: - FileUtils EML Export (atomic & auditable!)
    @discardableResult
    func exportFilteredEmailsAsEML(to folder: URL, emails: [MBOXParser.RawEmail]) -> Int {
        var usedNames = Set<String>()
        var failedCount = 0
        for (index, email) in emails.enumerated() {
            let rawSubject = email.headers["Subject"] ?? "(no-subject)"
            let safeSubject = rawSubject
                .replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: [.regularExpression])
                .trimmingCharacters(in: .whitespaces)
                .prefix(60)
            var filename = "\(index + 1)_\(safeSubject).eml"
            var counter = 1
            while usedNames.contains(filename) {
                filename = "\(index + 1)_\(safeSubject)_\(counter).eml"
                counter += 1
            }
            usedNames.insert(filename)
            let fileURL = folder.appendingPathComponent(filename)
            do {
                // F05: a located message streams from its source; one with
                // neither content nor a reachable source counts as failed,
                // never as a headers-only stub.
                if email.rawSource.isEmpty {
                    guard let locator = RawMessageFile.locator(for: email) else {
                        throw RawMessageError.contentUnavailable(subject: rawSubject, reason: "no stored content and no reachable original file")
                    }
                    try RawMessageFile.write(located: locator, to: fileURL)
                } else {
                    let emlContent = exportEmailAsEML(email)
                    try FileUtils.writeData(Data(emlContent.utf8), to: fileURL.path)
                }
            } catch {
                failedCount += 1
                FileUtilsAudit.logError(error, context: "EML Export", path: fileURL.path)
            }
        }
        return failedCount
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let parsingFinished = Notification.Name("parsingFinished")
}
