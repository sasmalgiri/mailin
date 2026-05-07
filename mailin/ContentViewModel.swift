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

    @Published private(set) var parsedEmails: [MBOXParser.RawEmail] = []
    private(set) var metadata: [String: Any] = [:]
    private var isParsing = false
    private var memoryTimer: Timer?
    private var pendingTempDirs: [URL] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        statusMessage = "Please enter your sender email to begin."
        monitorMemoryPressure()
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
    func extractMailFilesFromZip(at zipURL: URL) -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_zip_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        pendingTempDirs.append(tempDir)

        guard let archive = try? Data(contentsOf: zipURL) else { return [] }

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
            guard dataStart + compressedSize <= bytes.count else { break }

            let ext = (name as NSString).pathExtension.lowercased()
            if (ext == "mbox" || ext == "eml") && !name.hasSuffix("/") {
                let compressedData = Data(bytes[dataStart..<dataStart+compressedSize])
                var fileData: Data?

                if method == 0 {
                    fileData = compressedData
                } else if method == 8 {
                    fileData = decompressDeflate(compressedData, uncompressedSize: uncompressedSize)
                }

                if let data = fileData {
                    let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
                    let destURL = tempDir.appendingPathComponent(safeName)
                    if let _ = try? data.write(to: destURL) {
                        mailFiles.append(destURL)
                    }
                }
            }

            offset = dataStart + compressedSize
        }

        return mailFiles
    }

    private func decompressDeflate(_ data: Data, uncompressedSize: Int) -> Data? {
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
    func parseSelectedFiles(_ urls: [URL]) {
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
            var allEmails: [MBOXParser.RawEmail] = []
            var errors: [String] = []
            var fileHashes: [ForensicManager.SourceFileHash] = []
            let totalFiles = Double(urls.count)
            for (idx, fileURL) in urls.enumerated() {
                if forensicEnabled {
                    if let hash = ForensicManager.computeHashes(for: fileURL) {
                        fileHashes.append(hash)
                    }
                }
                do {
                    let emails: [MBOXParser.RawEmail]
                    let ext = fileURL.pathExtension.lowercased()
                    let useStreaming = (ext == "mbox" || ext == "eml") && self.shouldUseStreaming(for: fileURL)

                    if useStreaming {
                        let fileSizeBytes = self.fileSize(at: fileURL)
                        await MainActor.run {
                            self.loadingText = "Streaming \(fileURL.lastPathComponent) (\(Self.formatByteCount(fileSizeBytes)))..."
                        }
                        emails = try MBOXParser.parseStreaming(
                            fileURL: fileURL,
                            senderEmail: capturedSenderEmail,
                            onProgress: { prog in
                                Task { @MainActor in
                                    self.loadingProgress = (Double(idx) + prog) / totalFiles
                                    let processed = Int64(prog * Double(fileSizeBytes))
                                    self.loadingText = "Streaming \(fileURL.lastPathComponent): \(Self.formatByteCount(processed)) / \(Self.formatByteCount(fileSizeBytes))"
                                    ImportProgressNotifier.shared.updateProgress(
                                        filename: fileURL.lastPathComponent,
                                        current: idx + 1,
                                        total: urls.count,
                                        bytesProcessed: processed,
                                        totalBytes: fileSizeBytes
                                    )
                                }
                            }
                        )
                    } else {
                        let fileSizeBytesNonStream = self.fileSize(at: fileURL)
                        await MainActor.run {
                            self.loadingText = "Parsing \(fileURL.lastPathComponent)..."
                        }
                        emails = try ParserFactory.parse(
                            fileURL: fileURL,
                            senderEmail: capturedSenderEmail,
                            onProgress: { prog in
                                Task { @MainActor in
                                    self.loadingProgress = (Double(idx) + prog) / totalFiles
                                    self.loadingText = "Parsing \(fileURL.lastPathComponent): \(Int(prog * 100))%"
                                    ImportProgressNotifier.shared.updateProgress(
                                        filename: fileURL.lastPathComponent,
                                        current: idx + 1,
                                        total: urls.count,
                                        bytesProcessed: Int64(prog * Double(fileSizeBytesNonStream)),
                                        totalBytes: fileSizeBytesNonStream
                                    )
                                }
                            }
                        )
                    }
                    let withSource = emails.map { email -> MBOXParser.RawEmail in
                        var copy = email
                        copy.headers["sourceFile"] = fileURL.lastPathComponent
                        return copy
                    }
                    allEmails.append(contentsOf: withSource)
                } catch {
                    errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
                await MainActor.run {
                    self.loadingText = "Parsed \(idx+1) of \(urls.count) file(s)..."
                    self.loadingProgress = min(1.0, Double(idx + 1) / totalFiles)
                }
            }

            let finalAllEmails = allEmails
            let finalErrors = errors
            let finalFileHashes = fileHashes
            await MainActor.run {
                self.isParsing = false
                self.stopMemoryMonitoring()
                self.parseErrors = finalErrors

                guard !finalAllEmails.isEmpty else {
                    let fileNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")
                    if finalErrors.isEmpty {
                        self.statusMessage = "No emails found in \(fileNames). Supported formats: .mbox, .eml, .emlx, .msg, .pst, .ost"
                    } else {
                        self.statusMessage = "Failed to parse \(fileNames): \(finalErrors.first ?? "Unknown error"). Try a smaller file or check the format."
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

                let beforeCount = finalAllEmails.count
                let deduplicated = Self.deduplicate(finalAllEmails)
                self.duplicatesRemoved = beforeCount - deduplicated.count
                self.parsedEmails = self.annotate(deduplicated)
                self.isParsed = true
                self.updateMetadataDisplay()

                if forensicEnabled {
                    ForensicManager.shared.storeEmailHashes(self.parsedEmails)
                }
                ForensicManager.shared.logAction("Parse Complete", detail: "Parsed \(self.parsedEmails.count) emails from \(urls.count) file(s). \(self.duplicatesRemoved) duplicates removed.")
                if finalErrors.isEmpty {
                    self.statusMessage = "Parsed \(self.parsedEmails.count) emails from \(urls.count) file(s)."
                    self.statusColor = .green
                } else {
                    self.statusMessage = "Parsed \(self.parsedEmails.count) emails. \(finalErrors.count) file(s) had errors."
                    self.statusColor = .orange
                }
                self.loadingProgress = 1.0
                self.loadingText = "Done!"
                self.cleanupTempDirs()

                // Notify import completion via system notification
                let importFilename = urls.count == 1 ? urls.first?.lastPathComponent ?? "archive" : "\(urls.count) files"
                ImportProgressNotifier.shared.completeImport(filename: importFilename, count: self.parsedEmails.count)

                // Update widget data for future WidgetKit extension
                WidgetDataProvider.shared.updateWidgetData(
                    totalEmails: self.parsedEmails.count,
                    importFilename: urls.first?.lastPathComponent,
                    emails: self.parsedEmails
                )

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

    func importThunderbirdProfile(_ urls: [URL]) {
        parseSelectedFiles(urls)
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
    func autoDetectMetadata() {
        guard isParsed else {
            statusMessage = "Parse a file first."
            statusColor = .orange
            return
        }
        let replyCounts = replyFrequency(for: senderEmail)
        let sortedSubjects = Dictionary(grouping: parsedEmails, by: { $0.headers["Subject"] ?? "(No Subject)" })
            .mapValues { $0.count }
            .sorted { replyCounts[$0.key, default: 0] < replyCounts[$1.key, default: 0] }

        subjectList = sortedSubjects.map { $0.key }
        let dates = parsedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }
        detectedDateRange = (dates.min(), dates.max())
        statusMessage = "Metadata detected: \(subjectList.count) subjects."
        statusColor = .blue
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
    private static func deduplicate(_ emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        var seen = Set<String>()
        var fuzzyIndex: [String: [Date]] = [:]
        var result: [MBOXParser.RawEmail] = []

        for (_, email) in emails.enumerated() {
            let messageID = email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? ""
            if !messageID.isEmpty {
                guard seen.insert(messageID).inserted else { continue }
            } else {
                let fingerprint = "\(email.headers["From"] ?? "")\(email.headers["Date"] ?? "")\(email.headers["Subject"] ?? "")"
                guard seen.insert(fingerprint).inserted else { continue }
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

            guard !isDuplicate else { continue }
            fuzzyIndex[fuzzyKey, default: []].append(date)
            result.append(email)
        }
        return result
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
        isParsed = false
        subjectList = []
        detectedDateRange = (nil, nil)
        loadingProgress = 0.0
        loadingText = ""
        parseErrors = []
        statusMessage = "Data cleared. Select a new file to begin."
        statusColor = .gray
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

    nonisolated static func formatByteCount(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
    }

    // MARK: - Export as EML (raw string)
    nonisolated func exportEmailAsEML(_ email: MBOXParser.RawEmail) -> String {
        var result = ""
        for (key, value) in email.headers {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"
        result += email.plainBody
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
