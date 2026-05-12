import Foundation
import os.log

private let persistLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Persistence")

struct EmailPersistence {
    private static let saveQueue = DispatchQueue(label: "com.ecosanskriti.mailin.persistence", qos: .utility)
    private static let currentVersion = 1

    private static var storeURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("mailin").appendingPathComponent("saved_emails.json")
        }
        let appDir = appSupport.appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("saved_emails.json")
    }

    private static var metaURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("session_meta.json")
    }

    struct SessionMeta: Codable {
        var version: Int = 1
        let senderEmail: String
        let emailCount: Int
        let savedAt: Date
    }

    static func save(emails: [MBOXParser.RawEmail], senderEmail: String) {
        guard !emails.isEmpty else { return }
        saveQueue.async {
            performSave(emails: emails, senderEmail: senderEmail)
        }
    }

    static func saveSync(emails: [MBOXParser.RawEmail], senderEmail: String) {
        guard !emails.isEmpty else { return }
        saveQueue.sync {
            performSave(emails: emails, senderEmail: senderEmail)
        }
    }

    private static func performSave(emails: [MBOXParser.RawEmail], senderEmail: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(emails)
            let meta = SessionMeta(senderEmail: senderEmail, emailCount: emails.count, savedAt: Date())
            let metaData = try encoder.encode(meta)

            try metaData.write(to: metaURL, options: .atomic)
            try data.write(to: storeURL, options: .atomic)
            persistLog.info("Saved \(emails.count) emails (\(data.count) bytes)")
        } catch {
            persistLog.error("Failed to save emails: \(error.localizedDescription)")
        }
    }

    static func load() -> (emails: [MBOXParser.RawEmail], senderEmail: String) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return ([], "")
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let emails = try JSONDecoder().decode([MBOXParser.RawEmail].self, from: data)

            var senderEmail = ""
            if FileManager.default.fileExists(atPath: metaURL.path) {
                let metaData = try Data(contentsOf: metaURL)
                let meta = try JSONDecoder().decode(SessionMeta.self, from: metaData)
                senderEmail = meta.senderEmail
            }
            persistLog.info("Loaded \(emails.count) emails")
            return (emails, senderEmail)
        } catch {
            persistLog.error("Failed to load emails: \(error.localizedDescription). Attempting legacy load.")
            return loadLegacy()
        }
    }

    private static func loadLegacy() -> (emails: [MBOXParser.RawEmail], senderEmail: String) {
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .deferredToDate
            let emails = try decoder.decode([MBOXParser.RawEmail].self, from: data)
            persistLog.info("Legacy load recovered \(emails.count) emails")
            return (emails, "")
        } catch {
            persistLog.error("Legacy load also failed: \(error.localizedDescription)")
            return ([], "")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    static func flushPendingSaves() {
        saveQueue.sync {}
    }

    static var hasSavedData: Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }
}
