//
//  WatchFolderManager.swift
//  mailin
//
//  Monitors a folder for new .mbox/.eml files and auto-imports them
//

import Foundation
import Combine

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

final class WatchFolderManager: ObservableObject {
    static let shared = WatchFolderManager()

    @Published var watchPath: URL? {
        didSet { persistWatchPath() }
    }
    @Published var isWatching: Bool = false
    @Published var lastImportDate: Date?
    @Published var importLog: [ImportLogEntry] = []

    /// The sender email used for parsing. Set this before starting the watcher.
    var senderEmail: String = ""

    private static let watchPathKey = "com.mailin.watchFolderPath"
    private static let importLogKey = "com.mailin.importLog"
    private static let maxLogEntries = 50

    #if os(macOS)
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    #else
    private var pollingTimer: Timer?
    #endif

    /// Tracks already-imported file names so the same file is not imported twice.
    private var knownFiles: Set<String> = []

    private let importQueue = DispatchQueue(label: "com.mailin.watchImport", qos: .utility)

    // MARK: - Init

    private init() {
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
        pollingTimer?.invalidate()
        pollingTimer = nil
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
            self?.scanForNewFiles()
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
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.importQueue.async {
                self?.scanForNewFiles()
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

    private func scanForNewFiles() {
        guard let directory = watchPath else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let supportedExtensions: Set<String> = ["mbox", "eml"]

        for fileURL in contents {
            let fileName = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()

            guard supportedExtensions.contains(ext),
                  !knownFiles.contains(fileName) else { continue }

            if importFile(at: fileURL) {
                knownFiles.insert(fileName)
            }
        }
    }

    // MARK: - File Import

    @discardableResult
    private func importFile(at fileURL: URL) -> Bool {
        do {
            let emails: [MBOXParser.RawEmail]

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

            guard !emails.isEmpty else { return false }

            let logEntry = ImportLogEntry(date: Date(), fileName: fileURL.lastPathComponent, count: emails.count)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastImportDate = logEntry.date
                self.importLog.insert(logEntry, at: 0)
                if self.importLog.count > Self.maxLogEntries {
                    self.importLog = Array(self.importLog.prefix(Self.maxLogEntries))
                }
                self.persistImportLog()

                NotificationCenter.default.post(
                    name: .newEmailsImported,
                    object: self,
                    userInfo: ["emails": emails, "fileName": fileURL.lastPathComponent]
                )
            }
            return true
        } catch {
            #if DEBUG
            print("[WatchFolderManager] Failed to import \(fileURL.lastPathComponent): \(error.localizedDescription)")
            #endif
            return false
        }
    }

    // MARK: - Persistence

    private func persistWatchPath() {
        if let path = watchPath?.path {
            UserDefaults.standard.set(path, forKey: Self.watchPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.watchPathKey)
        }
    }

    private func restoreWatchPath() {
        if let path = UserDefaults.standard.string(forKey: Self.watchPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                watchPath = url
            }
        }
    }

    private func persistImportLog() {
        guard let data = try? JSONEncoder().encode(importLog) else { return }
        UserDefaults.standard.set(data, forKey: Self.importLogKey)
    }

    private func restoreImportLog() {
        guard let data = UserDefaults.standard.data(forKey: Self.importLogKey),
              let log = try? JSONDecoder().decode([ImportLogEntry].self, from: data) else { return }
        importLog = log
    }

    // MARK: - Utility

    func clearImportLog() {
        importLog.removeAll()
        persistImportLog()
    }
}
