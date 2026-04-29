import Foundation

struct EmailPersistence {
    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("saved_emails.json")
    }

    private static var metaURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("session_meta.json")
    }

    struct SessionMeta: Codable {
        let senderEmail: String
        let emailCount: Int
        let savedAt: Date
    }

    static func save(emails: [MBOXParser.RawEmail], senderEmail: String) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(emails)
                try data.write(to: storeURL, options: .atomic)

                let meta = SessionMeta(senderEmail: senderEmail, emailCount: emails.count, savedAt: Date())
                let metaData = try encoder.encode(meta)
                try metaData.write(to: metaURL, options: .atomic)
            } catch {
                print("Failed to save emails: \(error)")
            }
        }
    }

    static func load() -> (emails: [MBOXParser.RawEmail], senderEmail: String) {
        do {
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                return ([], "")
            }
            let data = try Data(contentsOf: storeURL)
            let emails = try JSONDecoder().decode([MBOXParser.RawEmail].self, from: data)

            var senderEmail = ""
            if FileManager.default.fileExists(atPath: metaURL.path) {
                let metaData = try Data(contentsOf: metaURL)
                let meta = try JSONDecoder().decode(SessionMeta.self, from: metaData)
                senderEmail = meta.senderEmail
            }
            return (emails, senderEmail)
        } catch {
            print("Failed to load emails: \(error)")
            return ([], "")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    static var hasSavedData: Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }
}
