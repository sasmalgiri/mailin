import Foundation
import SwiftUI

@MainActor
class CollaborationManager: ObservableObject {
    static let shared = CollaborationManager()

    @AppStorage("collaborationEnabled") var isEnabled = false
    @AppStorage("collaborationFolderBookmark") private var folderBookmarkData: Data = Data()
    @AppStorage("collaborationAutoExport") var autoExport = false
    @AppStorage("collaborationExaminerID") var examinerID = ""

    @Published var sharedFolderURL: URL?
    @Published var availableImports: [ReviewStateFile] = []
    @Published var lastExportDate: Date?
    @Published var lastImportDate: Date?
    @Published var statusMessage = ""

    private var folderMonitor: DispatchSourceFileSystemObject?
    private var monitoredFD: Int32 = -1
    private var pollTimer: Timer?

    struct ReviewStateFile: Identifiable {
        let id = UUID()
        let url: URL
        let examiner: String
        let exportDate: Date
        let caseNumber: String
        var isNew: Bool

        var filename: String { url.lastPathComponent }
        var age: String {
            let interval = Date().timeIntervalSince(exportDate)
            if interval < 60 { return "just now" }
            if interval < 3600 { return "\(Int(interval / 60))m ago" }
            if interval < 86400 { return "\(Int(interval / 3600))h ago" }
            return "\(Int(interval / 86400))d ago"
        }
    }

    private init() {
        if examinerID.isEmpty {
            examinerID = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? UUID().uuidString.prefix(8).lowercased()
        }
        restoreSharedFolder()
    }

    // MARK: - Folder Setup

    func setSharedFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        if let bookmark = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            folderBookmarkData = bookmark
        }
        sharedFolderURL = url
        startMonitoring()
        scanForReviewFiles()
        statusMessage = "Shared folder set: \(url.lastPathComponent)"
    }

    func clearSharedFolder() {
        stopMonitoring()
        sharedFolderURL = nil
        folderBookmarkData = Data()
        availableImports = []
        statusMessage = ""
    }

    private func restoreSharedFolder() {
        guard !folderBookmarkData.isEmpty else { return }
        var isStale = false
        #if os(macOS)
        let resolveOptions: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let resolveOptions: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: folderBookmarkData, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            folderBookmarkData = Data()
            return
        }

        sharedFolderURL = url
        if isEnabled {
            startMonitoring()
            scanForReviewFiles()
        }
    }

    // MARK: - Folder Monitoring

    func startMonitoring() {
        stopMonitoring()
        guard let folder = sharedFolderURL else { return }

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        monitoredFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.scanForReviewFiles()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        folderMonitor = source

        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForReviewFiles()
            }
        }
    }

    func stopMonitoring() {
        if let source = folderMonitor {
            source.cancel()
            folderMonitor = nil
        } else if monitoredFD >= 0 {
            close(monitoredFD)
        }
        monitoredFD = -1
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Scan & Detect

    func scanForReviewFiles() {
        guard let folder = sharedFolderURL else { return }
        _ = folder.startAccessingSecurityScopedResource()
        defer { folder.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }

        let reviewFiles = contents.filter { $0.pathExtension == "mailinreview" }
        var parsed: [ReviewStateFile] = []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in reviewFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let header = try? decoder.decode(ReviewStateHeader.self, from: data) else { continue }

            if header.exportedBy == examinerID { continue }

            let isNew = lastImportDate == nil || header.exportDate > (lastImportDate ?? .distantPast)
            parsed.append(ReviewStateFile(
                url: fileURL,
                examiner: header.exportedBy,
                exportDate: header.exportDate,
                caseNumber: header.caseNumber,
                isNew: isNew
            ))
        }

        availableImports = parsed.sorted { $0.exportDate > $1.exportDate }
    }

    private struct ReviewStateHeader: Codable {
        let version: Int
        let exportDate: Date
        let exportedBy: String
        let caseNumber: String
    }

    // MARK: - Auto Export

    func autoExportIfEnabled() {
        guard isEnabled, autoExport, let folder = sharedFolderURL else { return }
        guard let data = ExportManager.exportReviewState() else { return }

        _ = folder.startAccessingSecurityScopedResource()
        defer { folder.stopAccessingSecurityScopedResource() }

        let casePart = ForensicManager.shared.caseNumber.isEmpty ? "review" : ForensicManager.shared.caseNumber
        let filename = "\(casePart)_\(examinerID).mailinreview"
        let fileURL = folder.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            lastExportDate = Date()
        } catch {
            statusMessage = "Auto-export failed: \(error.localizedDescription)"
        }
    }

    func importFile(_ file: ReviewStateFile) throws -> ExportManager.ImportResult {
        _ = file.url.startAccessingSecurityScopedResource()
        defer { file.url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: file.url)
        let result = try ExportManager.importReviewState(from: data, strategy: .merge)
        lastImportDate = Date()

        if let idx = availableImports.firstIndex(where: { $0.url == file.url }) {
            availableImports[idx].isNew = false
        }

        return result
    }

    var newImportCount: Int {
        availableImports.filter(\.isNew).count
    }
}
