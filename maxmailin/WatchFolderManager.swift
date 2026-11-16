@testable import ArchiveCore
//
//  WatchFolderManager.swift
//  mailin
//
//  Monitors a folder for new .mbox/.eml files and auto-imports them
//

import Foundation
import SwiftUI

extension Notification.Name {
    static let newEmailsImported = Notification.Name("com.mailin.newEmailsImported")
}

// MARK: - Import Log Entry

struct ImportLogEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let fileName: String
    let count: Int

    init(date: Date, fileName: String, count: Int) {
        self.id = UUID()
        self.date = date
        self.fileName = fileName
        self.count = count
    }
}

// MARK: - WatchFolderManager

// Thread-safety is managed internally: `knownFiles` is guarded by `importQueue`
// and all `@Published` state is mutated on the main actor. The `@unchecked`
// conformance asserts that contract so the manager can be used from the
// background file-watch closures.
final class WatchFolderManager: ObservableObject, @unchecked Sendable {
    static let shared = WatchFolderManager()

    @Published var watchPath: URL? {
        didSet { persistWatchPath() }
    }
    @Published var isWatching: Bool = false
    @Published var lastImportDate: Date?
    /// The newest `maxLogEntries` files taken in (stated beside the count).
    @Published var importLog: [ImportLogEntry] = []
    /// Every file whose messages reached the archive, since the log began —
    /// the log itself keeps only the newest `maxLogEntries`.
    @Published private(set) var filesTakenIn: Int = 0

    /// The sender email used for parsing. Set this before starting the watcher.
    var senderEmail: String = ""

    private static let watchPathKey = "com.mailin.watchFolderPath"
    private static let importLogKey = "com.mailin.importLog"
    private static let filesTakenInKey = "com.mailin.importLog.filesTakenIn"
    /// Real limit, stated in the Triage bar: the log keeps the newest 50 files.
    static let maxLogEntries = 50

    /// Writes a parsed file's messages to the archive. The file counts as taken
    /// in only after this returns; a throw leaves it to the next scan.
    var storeWriter: @MainActor ([MBOXParser.RawEmail], String) async throws -> Void = { emails, fileName in
        try await TriageQueueService.shared.intake(emails, from: fileName)
    }
    private let defaults: UserDefaults

    #if os(macOS)
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    #else
    private var pollingTask: Task<Void, Never>?
    #endif

    /// Tracks already-imported file names so the same file is not imported twice.
    private var knownFiles: Set<String> = []
    /// Files parsed and on their way to the archive (not scanned again meanwhile).
    private var inFlight: Set<String> = []

    private let importQueue = DispatchQueue(label: "com.mailin.watchImport", qos: .utility)

    // MARK: - Init

    private convenience init() { self.init(defaults: .standard) }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        restoreWatchPath()
        restoreImportLog()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Start / Stop

    func startWatching(directory: URL) {
        stopWatching()

        watchPath = directory
        isWatching = true

        // Snapshot the current directory contents so we only react to new files
        snapshotDirectory(directory)

        #if os(macOS)
        startMacOSWatcher(directory: directory)
        #else
        startIOSWatcher(directory: directory)
        #endif
    }

    func stopWatching() {
        isWatching = false

        #if os(macOS)
        dispatchSource?.cancel()
        dispatchSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        #else
        pollingTask?.cancel()
        pollingTask = nil
        #endif
    }

    // MARK: - macOS: DispatchSource File System Monitoring

    #if os(macOS)
    private func startMacOSWatcher(directory: URL) {
        fileDescriptor = open(directory.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            isWatching = false
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: importQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.scanForNewFiles() }
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        dispatchSource = source
        source.resume()
    }
    #endif

    // MARK: - iOS: Polling Timer

    #if os(iOS)
    private func startIOSWatcher(directory: URL) {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { break }
                await self.scanForNewFiles()
            }
        }
    }
    #endif

    // MARK: - Directory Scanning

    private func snapshotDirectory(_ directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let snapshot = Set(contents.map { $0.lastPathComponent })
        importQueue.sync { knownFiles = snapshot }
    }

    /// One scan: every new .mbox/.eml file is parsed and written to the
    /// archive; returns when those writes have finished. A file is recorded
    /// (known, logged, "last intake") only after its write succeeded — a
    /// failed write leaves it to the next scan.
    func scanForNewFiles() async {
        guard let directory = watchPath else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let supportedExtensions: Set<String> = ["mbox", "eml"]
        let candidates: [URL] = importQueue.sync {
            var picked: [URL] = []
            for fileURL in contents {
                let fileName = fileURL.lastPathComponent
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()),
                      !knownFiles.contains(fileName), !inFlight.contains(fileName) else { continue }
                inFlight.insert(fileName)
                picked.append(fileURL)
            }
            return picked
        }
        for fileURL in candidates {
            let fileName = fileURL.lastPathComponent
            let taken = await importFile(at: fileURL)
            importQueue.sync {
                inFlight.remove(fileName)
                if taken { knownFiles.insert(fileName) }
            }
        }
    }

    // MARK: - File Import

    @discardableResult
    private func importFile(at fileURL: URL) async -> Bool {
        let emails: [MBOXParser.RawEmail]
        do {
            switch fileURL.pathExtension.lowercased() {
            case "mbox":
                emails = try MBOXParser.parse(fileURL: fileURL, senderEmail: senderEmail)
            case "eml":
                // Treat a single .eml as a raw message string
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let email = try MBOXParser.processRawMessage(content, senderEmail: senderEmail)
                emails = [email]
            default:
                return false
            }
        } catch {
            #if DEBUG
            print("[WatchFolderManager] Failed to read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            #endif
            return false
        }
        guard !emails.isEmpty else { return false }
        let fileName = fileURL.lastPathComponent

        return await recordAfterWrite(emails, fileName: fileName)
    }

    /// Writes to the archive first; only a write that succeeded is logged.
    @MainActor
    private func recordAfterWrite(_ emails: [MBOXParser.RawEmail], fileName: String) async -> Bool {
        do {
            try await storeWriter(emails, fileName)
        } catch {
            return false   // not recorded; the next scan tries again
        }
        let logEntry = ImportLogEntry(date: Date(), fileName: fileName, count: emails.count)
        lastImportDate = logEntry.date
        filesTakenIn += 1
        importLog.insert(logEntry, at: 0)
        if importLog.count > Self.maxLogEntries {
            importLog = Array(importLog.prefix(Self.maxLogEntries))
        }
        persistImportLog()
        NotificationCenter.default.post(name: .newEmailsImported, object: self, userInfo: ["fileName": fileName])
        return true
    }

    // MARK: - Persistence

    private func persistWatchPath() {
        if let path = watchPath?.path {
            defaults.set(path, forKey: Self.watchPathKey)
        } else {
            defaults.removeObject(forKey: Self.watchPathKey)
        }
    }

    private func restoreWatchPath() {
        if let path = defaults.string(forKey: Self.watchPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                watchPath = url
            }
        }
    }

    private func persistImportLog() {
        guard let data = try? JSONEncoder().encode(importLog) else { return }
        defaults.set(data, forKey: Self.importLogKey)
        defaults.set(filesTakenIn, forKey: Self.filesTakenInKey)
    }

    private func restoreImportLog() {
        guard let data = defaults.data(forKey: Self.importLogKey),
              let log = try? JSONDecoder().decode([ImportLogEntry].self, from: data) else { return }
        importLog = log
        filesTakenIn = max(defaults.integer(forKey: Self.filesTakenInKey), log.count)
    }

    // MARK: - Utility

    func clearImportLog() {
        importLog.removeAll()
        filesTakenIn = 0
        persistImportLog()
    }
}
