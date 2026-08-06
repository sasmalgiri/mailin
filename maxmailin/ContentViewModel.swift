import Foundation
import SwiftUI
import UniformTypeIdentifiers
import zlib
import CryptoKit
import os

@MainActor
class ContentViewModel: ObservableObject {
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

    /// Synchronous extraction. Records the temp dir for later cleanup.
    func extractMailFilesFromZip(at zipURL: URL) -> [URL] {
        let (files, tempDir) = Self.extractZipCore(at: zipURL)
        pendingTempDirs.append(tempDir)
        return files
    }

    /// Off-main extraction — runs the heavy parse/inflate on a background
    /// executor so a large zip doesn't block (beachball) the main thread.
    func extractMailFilesFromZipAsync(at zipURL: URL) async -> [URL] {
        let (files, tempDir) = await Task.detached { Self.extractZipCore(at: zipURL) }.value
        pendingTempDirs.append(tempDir)
        return files
    }

    /// Pure, nonisolated extraction core so it can run off the main actor.
    /// Returns the extracted files and the temp dir they were written to.
    nonisolated static func extractZipCore(at zipURL: URL) -> (files: [URL], tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_zip_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let archive = try? Data(contentsOf: zipURL) else { return ([], tempDir) }

        var mailFiles: [URL] = []
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
                    if resolved.hasPrefix(tempDir.standardizedFileURL.path + "/"),
                       let _ = try? data.write(to: destURL) {
                        mailFiles.append(destURL)
                    }
                }
            }

            offset = dataStart + compressedSize
        }

        return (mailFiles, tempDir)
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

// MARK: - MBOX Parsing with fine-grained progress
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
        let capturedSenderEmail = senderEmail
        let forensicEnabled = UserDefaults.standard.bool(forKey: "forensicModeEnabled")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    if self.isParsing {
                        self.isParsing = false
                        self.stopMemoryMonitoring()
                        if self.loadingProgress < 1.0 {
                            self.statusMessage = "Parsing interrupted unexpectedly."
                            self.statusColor = .orange
                            self.loadingProgress = 0.0
                            self.loadingText = ""
                        }
                    }
                }
            }
            // v2 bounded streaming import: each parsed batch is persisted to the
            // SQLite store + FTS5 and then DROPPED, so peak RAM is bounded by the
            // batch size regardless of archive/file size. Only a bounded PREVIEW
            // (`previewCap`) is retained to back the legacy in-RAM UI; the true
            // count is tracked separately. Dedup is enforced by the store
            // (INSERT OR IGNORE on message_id) with persistent findings.
            let previewCap = 5000
            var preview: [MBOXParser.RawEmail] = []
            var totalParsed = 0
            var errors: [String] = []
            var fileHashes: [ForensicManager.SourceFileHash] = []
            let totalFiles = max(1.0, Double(urls.count))
            let storageActive = await StorageActivationCoordinator.shared.isActive

            for (idx, fileURL) in urls.enumerated() {
                if forensicEnabled {
                    if let hash = ForensicManager.computeHashes(for: fileURL) {
                        fileHashes.append(hash)
                    }
                }
                let fileSizeBytes = self.fileSize(at: fileURL)
                let sourceName = fileURL.lastPathComponent
                await MainActor.run { self.loadingText = "Importing \(sourceName)..." }
                do {
                    _ = try await ParserFactory.parseStreamingCallback(
                        fileURL: fileURL,
                        senderEmail: capturedSenderEmail,
                        batchSize: 500,
                        onProgress: { prog in
                            Task { @MainActor in
                                self.loadingProgress = (Double(idx) + prog) / totalFiles
                                self.loadingText = "Importing \(sourceName): \(Int(prog * 100))%"
                                ImportProgressNotifier.shared.updateProgress(
                                    filename: sourceName,
                                    current: idx + 1,
                                    total: urls.count,
                                    bytesProcessed: Int64(prog * Double(fileSizeBytes)),
                                    totalBytes: fileSizeBytes
                                )
                            }
                        }
                    ) { batch in
                        let withSource = batch.map { email -> MBOXParser.RawEmail in
                            var copy = email
                            copy.headers["sourceFile"] = sourceName
                            return copy
                        }
                        // Persist to the authority, then let the batch fall out of
                        // scope — bounded peak memory.
                        if storageActive {
                            try? await SQLiteEmailStore.shared.insertBatch(withSource, batchSize: 500)
                            try? await FTSSearchIndex.shared.indexBatch(withSource)
                        }
                        totalParsed += withSource.count
                        if preview.count < previewCap {
                            preview.append(contentsOf: withSource.prefix(previewCap - preview.count))
                        }
                    }
                } catch {
                    errors.append("\(sourceName): \(error.localizedDescription)")
                }
                await MainActor.run {
                    self.loadingText = "Imported \(idx+1) of \(urls.count) file(s)..."
                    self.loadingProgress = min(1.0, Double(idx + 1) / totalFiles)
                }
            }

            let finalPreview = maxEmails.map { Array(preview.prefix($0)) } ?? preview
            let finalTotal = maxEmails.map { min($0, totalParsed) } ?? totalParsed
            let finalErrors = errors
            let finalFileHashes = fileHashes
            let didPersist = storageActive
            await MainActor.run {
                self.isParsing = false
                self.stopMemoryMonitoring()
                self.parseErrors = finalErrors

                guard finalTotal > 0 else {
                    let fileNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")
                    if finalErrors.isEmpty {
                        let extensions = urls.map { $0.pathExtension.lowercased() }
                        let supported = Set(["mbox", "eml", "emlx", "msg", "pst", "ost", "nsf", "zip"])
                        let unsupported = extensions.filter { !supported.contains($0) && !$0.isEmpty }
                        if !unsupported.isEmpty {
                            self.statusMessage = "Unsupported format: .\(unsupported.first ?? "unknown"). Supported: .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf, .zip"
                        } else {
                            self.statusMessage = "No emails found in \(fileNames). The file may be empty or contain no recognizable email messages."
                        }
                    } else {
                        let errorSummary = finalErrors.prefix(3).joined(separator: "; ")
                        self.statusMessage = "Failed to parse \(fileNames): \(errorSummary)"
                    }
                    self.statusColor = .orange
                    self.isParsed = false
                    self.loadingProgress = 0.0
                    self.loadingText = ""
                    ImportProgressNotifier.shared.cancelProgress()
                    return
                }

                for hash in finalFileHashes {
                    ForensicManager.shared.registerFileHash(hash)
                }

                // The SQLite store holds the full, deduped archive (persisted per
                // batch during streaming above). `parsedEmails` is only a BOUNDED
                // preview that backs the legacy in-RAM UI; `totalParsedCount` is
                // the true total. Dedup is enforced by the store; the count comes
                // from its persistent findings.
                self.parsedEmails = self.annotate(finalPreview)
                self.totalParsedCount = finalTotal
                self.isParsed = true
                self.updateMetadataDisplay()
                self.duplicatesRemoved = 0
                self.removedDuplicates = []
                if didPersist {
                    Task { @MainActor in
                        self.duplicatesRemoved = (try? await SQLiteEmailStore.shared.duplicatesCount()) ?? 0
                    }
                }

                if forensicEnabled {
                    ForensicManager.shared.storeEmailHashes(self.parsedEmails)
                }
                ForensicManager.shared.logAction("Import Complete", detail: "Imported \(finalTotal) emails from \(urls.count) file(s) into SQLite + FTS5.")

                let recoveryInfo: String
                if let report = MBOXParser.lastRecoveryReport, report.hasDamage {
                    recoveryInfo = " (\(report.failed) unparseable skipped)"
                } else {
                    recoveryInfo = ""
                }
                if finalErrors.isEmpty {
                    self.statusMessage = "Imported \(finalTotal) emails from \(urls.count) file(s).\(recoveryInfo)"
                    self.statusColor = recoveryInfo.isEmpty ? .green : .orange
                } else {
                    let errorHint = finalErrors.first.map { " (\($0))" } ?? ""
                    self.statusMessage = "Imported \(finalTotal) emails. \(finalErrors.count) file(s) had errors\(errorHint).\(recoveryInfo)"
                    self.statusColor = .orange
                }
                self.loadingProgress = 1.0
                self.loadingText = "Done!"
                self.cleanupTempDirs()

                // Notify import completion via system notification
                let importFilename = urls.count == 1 ? urls.first?.lastPathComponent ?? "archive" : "\(urls.count) files"
                ImportProgressNotifier.shared.completeImport(filename: importFilename, count: finalTotal)

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

                // Build search index in background after parsing completes
                let emailsForIndexing = self.parsedEmails
                Task {
                    await self.processInBackground(emails: emailsForIndexing)
                }
            }
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
        parsedEmails.removeAll { ids.contains($0.id) }
        totalParsedCount = parsedEmails.count
        duplicatesRemoved += removed.count
        removedDuplicates.append(contentsOf: removed.map { DuplicateFinding(from: $0, reason: "removed") })
        // Durably delete from the SQLite authority AND the FTS index so removed
        // emails don't linger as searchable ghost rows (store↔FTS drift).
        // FTS-first (matches the repository's delete ordering): a mid-delete
        // failure leaves a canonical row that reconcile can restore, never a
        // ghost FTS row.
        let idList = ids
        Task {
            for id in idList {
                try? await FTSSearchIndex.shared.delete(id: id)
            }
            try? await SQLiteEmailStore.shared.delete(ids: idList)
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
