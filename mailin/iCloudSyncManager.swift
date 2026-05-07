import Foundation
import SwiftUI
import os.log

private let syncLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "iCloudSync")

@MainActor
class iCloudSyncManager: ObservableObject {
    static let shared = iCloudSyncManager()

    @AppStorage("iCloudSyncEnabled") var isEnabled = false {
        didSet {
            if isEnabled {
                startSync()
            } else {
                stopSync()
            }
        }
    }

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var statusMessage = ""
    @Published var lastSyncErrors: [String] = []

    private var syncTimer: Timer?
    private let baseSyncInterval: TimeInterval = 60
    private let maxStaleFileAge: TimeInterval = 30 * 24 * 3600 // 30 days
    private var consecutiveFailures = 0
    private let maxBackoffInterval: TimeInterval = 600 // 10 minutes

    enum SyncStatus {
        case idle
        case syncing
        case synced
        case partialSync(String)
        case error(String)
        case unavailable

        var icon: String {
            switch self {
            case .idle: return "icloud"
            case .syncing: return "arrow.triangle.2.circlepath.icloud"
            case .synced: return "checkmark.icloud"
            case .partialSync: return "exclamationmark.icloud"
            case .error: return "exclamationmark.icloud"
            case .unavailable: return "xmark.icloud"
            }
        }

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .syncing: return .blue
            case .synced: return .green
            case .partialSync: return .orange
            case .error: return .red
            case .unavailable: return .orange
            }
        }

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .syncing: return "Syncing..."
            case .synced: return "Synced"
            case .partialSync(let msg): return "Partial: \(msg)"
            case .error(let msg): return "Error: \(msg)"
            case .unavailable: return "iCloud unavailable"
            }
        }
    }

    // MARK: - iCloud Container

    private var ubiquityContainerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    private var syncFolderURL: URL? {
        guard let container = ubiquityContainerURL else { return nil }
        let folder = container.appendingPathComponent("Documents/ForensicSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var isAvailable: Bool {
        ubiquityContainerURL != nil
    }

    private init() {
        if isEnabled {
            startSync()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquityIdentityChanged),
            name: .NSUbiquityIdentityDidChange,
            object: nil
        )
    }

    @objc private func ubiquityIdentityChanged() {
        Task { @MainActor in
            if FileManager.default.ubiquityIdentityToken == nil {
                syncStatus = .unavailable
                statusMessage = "Signed out of iCloud"
            } else if isEnabled {
                startSync()
            }
        }
    }

    // MARK: - Sync Lifecycle

    func startSync() {
        guard isEnabled else { return }

        guard isAvailable else {
            syncStatus = .unavailable
            statusMessage = "Sign in to iCloud in System Settings to enable sync"
            return
        }

        consecutiveFailures = 0
        scheduleNextSync()
        Task { await performSync() }
    }

    private func scheduleNextSync() {
        syncTimer?.invalidate()

        let backoff = min(baseSyncInterval * pow(2.0, Double(consecutiveFailures)), maxBackoffInterval)
        let jitter = Double.random(in: -10...10)
        let interval = max(baseSyncInterval, backoff + jitter)

        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performSync()
                self?.scheduleNextSync()
            }
        }
    }

    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        syncStatus = .idle
        statusMessage = ""
        consecutiveFailures = 0
    }

    // MARK: - Sync Operations

    func performSync() async {
        guard isEnabled, let syncFolder = syncFolderURL else { return }

        syncStatus = .syncing
        lastSyncErrors = []
        var errors: [String] = []

        do {
            try await uploadForensicState(to: syncFolder)
        } catch {
            let msg = "Upload failed: \(error.localizedDescription)"
            errors.append(msg)
            syncLog.error("Upload failed: \(error.localizedDescription)")
        }

        do {
            try await downloadForensicState(from: syncFolder)
        } catch {
            let msg = "Download failed: \(error.localizedDescription)"
            errors.append(msg)
            syncLog.error("Download failed: \(error.localizedDescription)")
        }

        let kvErrors = syncKVStore()
        errors.append(contentsOf: kvErrors)

        cleanupStaleFiles(in: syncFolder)

        lastSyncErrors = errors
        if errors.isEmpty {
            consecutiveFailures = 0
            lastSyncDate = Date()
            syncStatus = .synced
            statusMessage = "Last synced \(Date().formatted(date: .omitted, time: .shortened))"
        } else if errors.count < 3 {
            consecutiveFailures = 0
            lastSyncDate = Date()
            syncStatus = .partialSync("\(errors.count) warning(s)")
            statusMessage = errors.first ?? "Partial sync"
        } else {
            consecutiveFailures += 1
            syncStatus = .error(errors.first ?? "Sync failed")
            statusMessage = "Sync failed: \(errors.first ?? "unknown error")"
        }
    }

    // MARK: - Upload Local State

    private func uploadForensicState(to folder: URL) async throws {
        let forensic = ForensicManager.shared
        let deviceID = deviceIdentifier

        var tagTimestamps: [String: Date] = [:]
        for (uuid, _) in forensic.evidenceTags {
            tagTimestamps[uuid.uuidString] = forensic.tagTimestamps[uuid] ?? Date.distantPast
        }

        let state = SyncableState(
            version: 2,
            deviceID: deviceID,
            syncDate: Date(),
            evidenceTags: forensic.evidenceTags.reduce(into: [:]) { $0[$1.key.uuidString] = $1.value.rawValue },
            tagTimestamps: tagTimestamps,
            annotations: forensic.annotations.reduce(into: [:]) { $0[$1.key.uuidString] = AnnotationDTO(text: $1.value.text, examiner: $1.value.examiner, timestamp: $1.value.timestamp) },
            caseNumber: forensic.caseNumber,
            examinerName: forensic.examinerName,
            organization: forensic.organization
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(state)

        let kvLimit = 256 * 1024
        if data.count > kvLimit {
            syncLog.warning("Sync state size \(data.count) bytes approaching limits")
        }

        let filename = "sync_\(deviceID).json"
        let fileURL = folder.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        syncLog.info("Uploaded sync state: \(data.count) bytes")
    }

    // MARK: - Download Remote State

    private func downloadForensicState(from folder: URL) async throws {
        let fm = FileManager.default
        let deviceID = deviceIdentifier

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        } catch {
            throw SyncError.downloadFailed("Cannot list sync folder: \(error.localizedDescription)")
        }

        let syncFiles = contents.filter {
            $0.lastPathComponent.hasPrefix("sync_") &&
            $0.pathExtension == "json" &&
            !$0.lastPathComponent.contains(deviceID)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let forensic = ForensicManager.shared
        var mergedTagCount = 0
        var mergedAnnotationCount = 0
        var skippedFiles: [String] = []

        for fileURL in syncFiles {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                skippedFiles.append(fileURL.lastPathComponent)
                syncLog.error("Cannot read sync file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }

            let remote: SyncableState
            do {
                remote = try decoder.decode(SyncableState.self, from: data)
            } catch {
                skippedFiles.append(fileURL.lastPathComponent)
                syncLog.error("Cannot decode sync file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }

            for (key, value) in remote.evidenceTags {
                guard let uuid = UUID(uuidString: key),
                      let tag = ForensicManager.EvidenceTag(rawValue: value) else { continue }

                let remoteTimestamp = remote.tagTimestamps?[key] ?? remote.syncDate
                let localTimestamp = forensic.tagTimestamps[uuid] ?? Date.distantPast
                let localTag = forensic.evidenceTags[uuid]

                if localTag == nil || remoteTimestamp > localTimestamp {
                    let oldValue = localTag?.rawValue ?? "none"
                    forensic.evidenceTags[uuid] = tag
                    forensic.tagTimestamps[uuid] = remoteTimestamp
                    mergedTagCount += 1

                    if forensic.isEnabled {
                        forensic.logAction("SYNC_TAG_MERGE", detail: "Email \(key): \(oldValue) → \(tag.rawValue) from device \(remote.deviceID)")
                    }
                }
            }

            for (key, dto) in remote.annotations {
                guard let uuid = UUID(uuidString: key) else { continue }

                if let existing = forensic.annotations[uuid] {
                    if dto.timestamp > existing.timestamp {
                        forensic.annotations[uuid] = ForensicManager.Annotation(
                            text: dto.text,
                            examiner: dto.examiner,
                            timestamp: dto.timestamp
                        )
                        mergedAnnotationCount += 1

                        if forensic.isEnabled {
                            forensic.logAction("SYNC_ANNOTATION_MERGE", detail: "Email \(key): updated annotation from \(dto.examiner) via device \(remote.deviceID)")
                        }
                    }
                } else {
                    forensic.annotations[uuid] = ForensicManager.Annotation(
                        text: dto.text,
                        examiner: dto.examiner,
                        timestamp: dto.timestamp
                    )
                    mergedAnnotationCount += 1

                    if forensic.isEnabled {
                        forensic.logAction("SYNC_ANNOTATION_ADD", detail: "Email \(key): new annotation from \(dto.examiner) via device \(remote.deviceID)")
                    }
                }
            }
        }

        if !skippedFiles.isEmpty {
            syncLog.warning("Skipped \(skippedFiles.count) corrupt sync files: \(skippedFiles.joined(separator: ", "))")
        }

        syncLog.info("Merged \(mergedTagCount) tags, \(mergedAnnotationCount) annotations from \(syncFiles.count) device(s)")
    }

    // MARK: - NSUbiquitousKeyValueStore (Settings Sync)

    private func syncKVStore() -> [String] {
        let store = NSUbiquitousKeyValueStore.default
        let forensic = ForensicManager.shared
        var errors: [String] = []

        store.set(forensic.caseNumber, forKey: "sync_caseNumber")
        store.set(forensic.examinerName, forKey: "sync_examinerName")
        store.set(forensic.organization, forKey: "sync_organization")

        let synced = store.synchronize()
        if !synced {
            errors.append("KV store synchronize returned false — changes may be delayed")
            syncLog.warning("NSUbiquitousKeyValueStore.synchronize() returned false")
        }

        if forensic.caseNumber.isEmpty, let remote = store.string(forKey: "sync_caseNumber"), !remote.isEmpty {
            forensic.caseNumber = remote
            if forensic.isEnabled {
                forensic.logAction("SYNC_KV_IMPORT", detail: "Case number set to '\(remote)' from iCloud KV store")
            }
        }
        if forensic.examinerName.isEmpty, let remote = store.string(forKey: "sync_examinerName"), !remote.isEmpty {
            forensic.examinerName = remote
            if forensic.isEnabled {
                forensic.logAction("SYNC_KV_IMPORT", detail: "Examiner name set to '\(remote)' from iCloud KV store")
            }
        }
        if forensic.organization.isEmpty, let remote = store.string(forKey: "sync_organization"), !remote.isEmpty {
            forensic.organization = remote
            if forensic.isEnabled {
                forensic.logAction("SYNC_KV_IMPORT", detail: "Organization set to '\(remote)' from iCloud KV store")
            }
        }

        return errors
    }

    // MARK: - Stale File Cleanup

    private func cleanupStaleFiles(in folder: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let now = Date()
        for fileURL in contents {
            guard fileURL.lastPathComponent.hasPrefix("sync_"),
                  fileURL.pathExtension == "json",
                  !fileURL.lastPathComponent.contains(deviceIdentifier) else { continue }

            if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               now.timeIntervalSince(modified) > maxStaleFileAge {
                try? fm.removeItem(at: fileURL)
                syncLog.info("Removed stale sync file: \(fileURL.lastPathComponent)")
            }
        }
    }

    // MARK: - Device ID

    private var deviceIdentifier: String {
        if let existing = UserDefaults.standard.string(forKey: "iCloudSyncDeviceID") {
            return existing
        }
        #if os(macOS)
        let name = Host.current().localizedName ?? "mac"
        #else
        let name = UIDevice.current.name
        #endif
        let id = name.replacingOccurrences(of: " ", with: "_").lowercased().prefix(20) + "_" + UUID().uuidString.prefix(8).lowercased()
        let idString = String(id)
        UserDefaults.standard.set(idString, forKey: "iCloudSyncDeviceID")
        return idString
    }

    // MARK: - Data Models

    struct SyncableState: Codable {
        let version: Int?
        let deviceID: String
        let syncDate: Date
        let evidenceTags: [String: String]
        let tagTimestamps: [String: Date]?
        let annotations: [String: AnnotationDTO]
        let caseNumber: String
        let examinerName: String
        let organization: String
    }

    struct AnnotationDTO: Codable {
        let text: String
        let examiner: String
        let timestamp: Date
    }

    enum SyncError: LocalizedError {
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let msg): return msg
            }
        }
    }

    // MARK: - Manual Trigger

    func forceSyncNow() {
        Task { await performSync() }
    }
}
