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

    @Published private(set) var parsedEmails: [MBOXParser.RawEmail] = []
    @Published var totalParsedCount: Int = 0
    private(set) var metadata: [String: Any] = [:]
    private var isParsing = false
    private var memoryTimer: Timer?
    private var pendingTempDirs: [URL] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        statusMessage = "Please enter your sender email to begin."
        monitorMemoryPressure()
    }

    deinit {
        memoryTimer?.invalidate()
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
        memoryTimer?.invalidate()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let usage = ContentViewModel.currentMemoryUsageMB()
            Task { @MainActor in
                self?.memoryUsageMB = usage
            }
        }
    }

    private func stopMemoryMonitoring() {
        memoryTimer?.invalidate()
        memoryTimer = nil
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
                    // On warning, clear search index caches but keep emails
                    EmailSearchIndex.shared.clear()
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func releaseNonEssentialCaches() {
        // Clear search index cache and derived data
        EmailSearchIndex.shared.clear()
        // Keep parsedEmails in memory but release subject list cache
        subjectList.removeAll()
    }

    // MARK: - Background Processing Queue

    private func processInBackground(emails: [MBOXParser.RawEmail]) async {
        // Build search index in background with utility priority
        await Task.detached(priority: .utility) {
            EmailSearchIndex.shared.build(from: emails)
        }.value
    }

    // MARK: - Zip Import Support (sandbox-safe, no Process)

    /// Supported zip members that could not be written to the temp dir —
    /// accumulated here so the next import surfaces them instead of silently
    /// dropping evidence (Part B3).
    private var pendingZipDroppedMembers = 0

    /// Synchronous extraction. Records the temp dir for later cleanup.
    func extractMailFilesFromZip(at zipURL: URL) -> [URL] {
        let (files, tempDir, dropped) = Self.extractZipCore(at: zipURL)
        pendingTempDirs.append(tempDir)
        pendingZipDroppedMembers += dropped
        return files
    }

    /// Off-main extraction — runs the heavy parse/inflate on a background
    /// executor so a large zip doesn't block (beachball) the main thread.
    func extractMailFilesFromZipAsync(at zipURL: URL) async -> [URL] {
        let (files, tempDir, dropped) = await Task.detached { Self.extractZipCore(at: zipURL) }.value
        pendingTempDirs.append(tempDir)
        pendingZipDroppedMembers += dropped
        return files
    }

    /// Drain the dropped-member tally as user-facing error strings.
    private func drainZipExtractionErrors() -> [String] {
        defer { pendingZipDroppedMembers = 0 }
        guard pendingZipDroppedMembers > 0 else { return [] }
        return ["\(pendingZipDroppedMembers) archive member(s) could not be extracted from the zip and were NOT imported."]
    }

    /// Pure, nonisolated extraction core so it can run off the main actor.
    /// Returns the extracted files, the temp dir they were written to, and
    /// how many supported members failed extraction (counted, not swallowed).
    nonisolated static func extractZipCore(at zipURL: URL) -> (files: [URL], tempDir: URL, droppedMembers: Int) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_zip_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let archive = try? Data(contentsOf: zipURL) else { return ([], tempDir, 0) }

        var mailFiles: [URL] = []
        var droppedMembers = 0
        var offset = 0
        let bytes = [UInt8](archive)

        while offset + 30 <= bytes.count {
            let sig = UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
            guard sig == 0x04034b50 else { break }

            let method = UInt16(bytes[offset+8]) | UInt16(bytes[offset+9]) << 8
            let compressedSize = Int(UInt32(bytes[offset+18]) | UInt32(bytes[offset+19]) << 8 | UInt32(bytes[offset+20]) << 16 | UInt32(bytes[offset+21]) << 24)
            let uncompressedSize = Int(UInt32(bytes[offset+22]) | UInt32(bytes[offset+23]) << 8 | UInt32(bytes[offset+24]) << 16 | UInt32(bytes[offset+25]) << 24)
            let nameLen = Int(UInt16(bytes[offset+26]) | UInt16(bytes[offset+27]) << 8)
            let extraLen = Int(UInt16(bytes[offset+28]) | UInt16(bytes[offset+29]) << 8)

            let nameStart = offset + 30
            guard nameStart + nameLen <= bytes.count else { break }
            let nameData = Data(bytes[nameStart..<nameStart+nameLen])
            let name = String(data: nameData, encoding: .utf8) ?? ""

            let dataStart = nameStart + nameLen + extraLen
            guard dataStart >= nameStart, dataStart + compressedSize <= bytes.count else { break }

            let ext = (name as NSString).pathExtension.lowercased()
            // Extract every archive format the app can parse — not just
            // mbox/eml (the landing page advertises PST/OST/NSF/MSG too).
            let supported: Set<String> = ["mbox", "eml", "emlx", "msg", "pst", "ost", "nsf"]
            if supported.contains(ext) && !name.hasSuffix("/") {
                let compressedData = Data(bytes[dataStart..<dataStart+compressedSize])
                var fileData: Data?

                if method == 0 {
                    fileData = compressedData
                } else if method == 8 {
                    fileData = Self.decompressDeflate(compressedData, uncompressedSize: uncompressedSize)
                }

                if let data = fileData {
                    // Flatten to the base filename, then verify the resolved
                    // path stays inside tempDir (zip-slip defense).
                    let safeName = (name as NSString).lastPathComponent
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "..", with: "_")
                    let destURL = tempDir.appendingPathComponent(safeName)
                    let resolved = destURL.standardizedFileURL.path
                    if resolved.hasPrefix(tempDir.standardizedFileURL.path + "/") {
                        do {
                            try data.write(to: destURL)
                            mailFiles.append(destURL)
                        } catch {
                            // A supported member failed to land on disk —
                            // count it so the import surfaces the drop (B3).
                            droppedMembers += 1
                        }
                    } else {
                        droppedMembers += 1
                    }
                } else {
                    // Supported member with undecodable payload — dropped.
                    droppedMembers += 1
                }
            }

            offset = dataStart + compressedSize
        }

        return (mailFiles, tempDir, droppedMembers)
    }

    nonisolated private static func decompressDeflate(_ data: Data, uncompressedSize: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let maxDecompressedSize = 500_000_000 // 500MB safety cap
        guard uncompressedSize >= 0 && uncompressedSize <= maxDecompressedSize else { return nil }
        let bufferSize = max(uncompressedSize, 65536)
        var decompressed = Data(count: bufferSize)
        let result = data.withUnsafeBytes { srcPtr -> Data? in
            decompressed.withUnsafeMutableBytes { dstPtr -> Data? in
                guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcBase)
                stream.avail_in = UInt32(data.count)
                stream.next_out = dstBase
                stream.avail_out = UInt32(bufferSize)

                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
                defer { inflateEnd(&stream) }

                let status = inflate(&stream, Z_FINISH)
                guard status == Z_STREAM_END || status == Z_OK else { return nil }

                return Data(dstPtr.prefix(Int(stream.total_out)))
            }
        }
        return result
    }

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
    /// only UI side effects: progress publishing, the bounded preview for
    /// the legacy in-RAM UI, forensic bookkeeping, widget/notification
    /// updates and temp-dir cleanup.
    func parseSelectedFiles(_ urls: [URL], removeDuplicates: Bool = true, maxEmails: Int? = nil) {
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

            // Bounded preview retained for the legacy in-RAM UI; the
            // coordinator never hands us the full corpus (previewCap).
            var preview: [MBOXParser.RawEmail] = []

            var callbacks = BulkImportCoordinator.Callbacks()
            callbacks.onFileProgress = { [weak self] name, idx, count, prog in
                guard let self else { return }
                let totalFiles = Double(max(1, count))
                self.loadingProgress = (Double(idx) + prog) / totalFiles
                self.loadingText = "Importing \(name): \(Int(prog * 100))%"
                let sizeBytes = idx < urls.count ? self.fileSize(at: urls[idx]) : 0
                ImportProgressNotifier.shared.updateProgress(
                    filename: name,
                    current: idx + 1,
                    total: count,
                    bytesProcessed: Int64(prog * Double(sizeBytes)),
                    totalBytes: sizeBytes
                )
            }
            callbacks.onPreviewBatch = { batch in
                preview.append(contentsOf: batch)
            }
            // (C1) Forensic email hashes over every COMMITTED batch, so hash
            // coverage matches the persisted corpus, not just the preview.
            if forensicEnabled {
                callbacks.onCommittedBatch = { batch in
                    ForensicManager.shared.storeEmailHashes(batch)
                }
            }

            let options = BulkImportCoordinator.Options(
                batchSize: 500,
                senderEmail: self.senderEmail,
                maxEmails: maxEmails,
                previewCap: 5000
            )

            do {
                let summary = try await self.importCoordinator.runImport(
                    urls: urls, options: options, callbacks: callbacks
                )
                self.finishImport(urls: urls, summary: summary, preview: preview,
                                  fileHashes: fileHashes, maxEmails: maxEmails)
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
                var errors = self.drainZipExtractionErrors()
                errors.append(error.localizedDescription)
                self.parseErrors = errors
                self.statusMessage = "Import failed: \(error.localizedDescription)"
                self.statusColor = .red
                self.isParsed = false
                self.loadingProgress = 0.0
                self.loadingText = ""
                ImportProgressNotifier.shared.cancelProgress()
            }
        }
    }

    /// Completion side effects for a coordinator run: bounded preview into
    /// the legacy UI, per-run accounting (committed truth, Part B4),
    /// forensic bookkeeping, widget/notification updates, temp-dir cleanup.
    private func finishImport(
        urls: [URL],
        summary: BulkImportCoordinator.RunSummary,
        preview: [MBOXParser.RawEmail],
        fileHashes: [ForensicManager.SourceFileHash],
        maxEmails: Int?
    ) {
        isParsing = false
        stopMemoryMonitoring()

        var errors = summary.fileErrors.map { "\($0.filename): \($0.message)" }
        if summary.persistFailed > 0 {
            errors.append("\(summary.persistFailed) email(s) could not be saved to the archive and were not imported. Please retry; if this persists, free up disk space and check the log.")
            Self.importLogger.error("Import completed with \(summary.persistFailed, privacy: .public) unpersisted email(s)")
        }
        errors.append(contentsOf: drainZipExtractionErrors())
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
                let supported = Set(["mbox", "eml", "emlx", "msg", "pst", "ost", "nsf", "zip"])
                let unsupported = extensions.filter { !supported.contains($0) && !$0.isEmpty }
                if !unsupported.isEmpty {
                    statusMessage = "Unsupported format: .\(unsupported.first ?? "unknown"). Supported: .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf, .zip"
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
        // batch by the coordinator). `parsedEmails` is only a BOUNDED preview
        // backing the legacy in-RAM UI; the committed count comes from the
        // coordinator's per-run accounting.
        let finalPreview = maxEmails.map { Array(preview.prefix($0)) } ?? preview
        parsedEmails = annotate(finalPreview)
        totalParsedCount = committed
        isParsed = true
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

        // Build the bounded in-RAM search index over the preview in background
        let emailsForIndexing = parsedEmails
        Task {
            await self.processInBackground(emails: emailsForIndexing)
        }
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

    func importThunderbirdProfile(_ urls: [URL], removeDuplicates: Bool = true, maxEmails: Int? = nil) {
        parseSelectedFiles(urls, removeDuplicates: removeDuplicates, maxEmails: maxEmails)
    }

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

    func runAIQuery() {
        guard isParsed else {
            aiResponse = "Please parse a file first."
            return
        }
        let lower = aiPrompt.lowercased()
        if lower.contains("how many") && lower.contains("sent") {
            let count = parsedEmails.filter { $0.messageType == "sent" }.count
            aiResponse = "Total sent emails: \(count)"
        } else if lower.contains("how many") && lower.contains("received") {
            let count = parsedEmails.filter { $0.messageType == "received" }.count
            aiResponse = "Total received emails: \(count)"
        } else if lower.contains("top subject") {
            let freq = Dictionary(grouping: parsedEmails.map { $0.headers["Subject"] ?? "(No Subject)" }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
            aiResponse = "Top Subjects:\n" + freq.prefix(5).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        } else if lower.contains("reply frequency") {
            let freq = replyFrequency(for: senderEmail)
            let summary = freq.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            aiResponse = "Top Reply Recipients:\n" + summary
        } else {
            aiResponse = "Sorry, I didn't understand that. Try asking about 'sent emails', 'received emails', 'top subjects', or 'reply frequency'."
        }
    }

    // MARK: - Smart Deduplication (exact + fuzzy)
    private static func deduplicate(_ emails: [MBOXParser.RawEmail]) -> (kept: [MBOXParser.RawEmail], removed: [MBOXParser.RawEmail]) {
        var seen = Set<String>()
        var fuzzyIndex: [String: [Date]] = [:]
        var result: [MBOXParser.RawEmail] = []
        var removed: [MBOXParser.RawEmail] = []

        for (_, email) in emails.enumerated() {
            let messageID = email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? ""
            if !messageID.isEmpty {
                guard seen.insert(messageID).inserted else {
                    removed.append(email)
                    continue
                }
            } else {
                let fingerprint = "\(email.headers["From"] ?? "")\(email.headers["Date"] ?? "")\(email.headers["Subject"] ?? "")"
                guard seen.insert(fingerprint).inserted else {
                    removed.append(email)
                    continue
                }
            }

            let subject = (email.headers["Subject"] ?? "").lowercased()
                .replacingOccurrences(of: "re:", with: "").replacingOccurrences(of: "fwd:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let from = (email.headers["From"] ?? "").lowercased()
            let date = MBOXParser.parseDate(email.headers["Date"]) ?? .distantPast

            let fuzzyKey = "\(subject)|\(from)"
            let isDuplicate: Bool
            if date == .distantPast {
                isDuplicate = false
            } else if let existingDates = fuzzyIndex[fuzzyKey] {
                isDuplicate = existingDates.contains { abs($0.timeIntervalSince(date)) < 60 }
            } else {
                isDuplicate = false
            }

            guard !isDuplicate else {
                removed.append(email)
                continue
            }
            fuzzyIndex[fuzzyKey, default: []].append(date)
            result.append(email)
        }
        return (result, removed)
    }

    // MARK: - Annotate parsed emails (sent/received/normalize)
    private func annotate(_ emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        var annotated = emails
        var normalizedSender = senderEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedSender.isEmpty {
            let froms = emails.compactMap { $0.headers["From"] }
            senderEmail = mostCommon(in: froms)
            normalizedSender = senderEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !normalizedSender.isEmpty else { return annotated }

        for i in 0..<annotated.count {
            let from = annotated[i].headers["From"]?.lowercased() ?? ""
            if from == normalizedSender || from.contains(normalizedSender) {
                annotated[i].messageType = "sent"
            } else {
                annotated[i].messageType = "received"
            }
        }
        return annotated
    }

    private func mostCommon(in array: [String]) -> String {
        let counts = Dictionary(grouping: array, by: { $0 }).mapValues { $0.count }
        return counts.max(by: { $0.value < $1.value })?.key ?? ""
    }

    private func updateMetadataDisplay() {
        autoDetectMetadata()
    }

    // MARK: - Reply Frequency (threading)
    func replyFrequency(for userEmail: String) -> [String: Int] {
        guard !userEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let replies = parsedEmails.filter {
            $0.headers["From"]?.lowercased().contains(userEmail.lowercased()) == true
        }

        var counts: [String: Int] = [:]
        for email in replies {
            if let toField = email.headers["To"] {
                let recipients = toField.components(separatedBy: ",")
                for recipient in recipients {
                    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        counts[trimmed, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    // MARK: - Clear all parsed state
    private func cleanupTempDirs() {
        for dir in pendingTempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        pendingTempDirs.removeAll()
    }

    func clearParsedData() {
        cleanupTempDirs()
        parsedEmails = []
        removedDuplicates = []
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

    func removeEmails(ids: Set<UUID>) {
        let removed = parsedEmails.filter { ids.contains($0.id) }
        // Snapshot state so a failed store delete can be rolled back — the UI
        // must never show emails as removed while the authority still has them.
        let previousEmails = parsedEmails
        let previousTotal = totalParsedCount
        parsedEmails.removeAll { ids.contains($0.id) }
        totalParsedCount = parsedEmails.count
        duplicatesRemoved += removed.count
        removedDuplicates.append(contentsOf: removed.map { DuplicateFinding(from: $0, reason: "removed") })
        // Durably delete from the SQLite authority AND the FTS index so removed
        // emails don't linger as searchable ghost rows (store↔FTS drift).
        // FTS-first (matches the repository's delete ordering): a mid-delete
        // failure leaves a canonical row that reconcile can restore, never a
        // ghost FTS row. Failures are surfaced and the optimistic UI removal
        // is rolled back (Part B3 — never `try?`-swallow a correctness error).
        let idList = ids
        let rollbackCount = removed.count
        Task { @MainActor in
            do {
                for id in idList {
                    try await FTSSearchIndex.shared.delete(id: id)
                }
                try await SQLiteEmailStore.shared.delete(ids: idList)
            } catch {
                Self.importLogger.error("Delete failed; rolling back UI removal: \(error.localizedDescription, privacy: .public)")
                self.parsedEmails = previousEmails
                self.totalParsedCount = previousTotal
                self.duplicatesRemoved = max(0, self.duplicatesRemoved - rollbackCount)
                self.removedDuplicates.removeLast(rollbackCount)
                self.statusMessage = "Delete failed: \(error.localizedDescription). The emails were not removed."
                self.statusColor = .red
            }
        }
    }

    // MARK: - Restore persisted emails
    func restoreEmails(_ emails: [MBOXParser.RawEmail]) {
        self.parsedEmails = emails
        self.isParsed = !emails.isEmpty
        if isParsed {
            updateMetadataDisplay()
            statusMessage = "Restored \(emails.count) emails from previous session."
            statusColor = .green
        }
    }

    // MARK: - Append Emails (from IMAP/Cloud fetch)
    func appendEmails(_ newEmails: [MBOXParser.RawEmail]) {
        guard !newEmails.isEmpty else { return }
        let existingIDs = Set(parsedEmails.map { $0.id })
        let unique = newEmails.filter { !existingIDs.contains($0.id) }
        guard !unique.isEmpty else {
            statusMessage = "No new emails to add (all duplicates)."
            return
        }
        parsedEmails.append(contentsOf: annotate(unique))
        totalParsedCount = parsedEmails.count
        isParsed = true
        updateMetadataDisplay()
        statusMessage = "Added \(unique.count) email\(unique.count == 1 ? "" : "s") from server. Total: \(parsedEmails.count)"
        statusColor = .green
    }

    // MARK: - Body Rehydration (for compacted emails)
    func rehydrateBody(for emailID: UUID) -> MBOXParser.RawEmail? {
        guard let index = parsedEmails.firstIndex(where: { $0.id == emailID }),
              parsedEmails[index].isBodyCompacted else {
            return parsedEmails.first(where: { $0.id == emailID })
        }
        if let body = EmailPersistence.loadBody(for: emailID) {
            parsedEmails[index].plainBody = body.plainBody
            parsedEmails[index].htmlBody = body.htmlBody
            parsedEmails[index].rawSource = body.rawSource
            parsedEmails[index].isBodyCompacted = false
        }
        return parsedEmails[index]
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
            let emlContent = exportEmailAsEML(email)
            do {
                try FileUtils.writeData(Data(emlContent.utf8), to: fileURL.path)
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
