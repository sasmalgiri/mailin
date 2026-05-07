import Foundation

struct EMLXParser {
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let ext = fileURL.pathExtension.lowercased()

        if ext == "emlx" {
            let email = try parseSingleEMLX(fileURL: fileURL, senderEmail: senderEmail)
            onProgress?(1.0)
            return [email]
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw EMLXError.invalidFormat("Expected .emlx file or directory")
        }

        let contents = try fm.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil)
        let emlxFiles = contents.filter { $0.pathExtension.lowercased() == "emlx" }
        guard !emlxFiles.isEmpty else {
            throw EMLXError.noEmailsFound
        }

        var emails: [MBOXParser.RawEmail] = []
        let total = Double(emlxFiles.count)
        for (idx, file) in emlxFiles.enumerated() {
            do {
                let email = try parseSingleEMLX(fileURL: file, senderEmail: senderEmail)
                emails.append(email)
            } catch {
                continue
            }
            onProgress?((Double(idx + 1)) / total)
        }
        return emails
    }

    // EMLX format: first line = byte count, then RFC822 message, then Apple plist metadata
    private static func parseSingleEMLX(fileURL: URL, senderEmail: String) throws -> MBOXParser.RawEmail {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if fileSize > 500_000_000 { throw EMLXError.invalidFormat("EMLX file too large (\(fileSize / 1_000_000) MB)") }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw EMLXError.invalidFormat("Cannot decode file content")
        }

        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else {
            throw EMLXError.invalidFormat("Empty file")
        }

        let byteCountLine = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = Int(byteCountLine) ?? 0

        let afterFirstLine = lines.dropFirst().joined(separator: "\n")

        let rfc822Message: String
        let afterData = Data(afterFirstLine.utf8)
        if byteCount > 0 && byteCount < afterData.count {
            rfc822Message = String(decoding: afterData[0..<byteCount], as: UTF8.self)
        } else {
            rfc822Message = afterFirstLine
        }

        var plistFlags: [String: Any] = [:]
        if byteCount > 0 && byteCount < afterData.count {
            let plistStr = String(decoding: afterData[byteCount...], as: UTF8.self)
            if let plistData = plistStr.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                plistFlags = plist
            }
        }

        var email = try MBOXParser.processRawMessage(rfc822Message, senderEmail: senderEmail)

        if let flags = plistFlags["flags"] as? Int {
            if flags & 0x01 != 0 { email.tags.append("Read") }
            if flags & 0x02 != 0 { email.tags.append("Deleted") }
            if flags & 0x04 != 0 { email.tags.append("Answered") }
            if flags & 0x10 != 0 { email.tags.append("Flagged") }
            if flags & 0x80 != 0 { email.tags.append("Draft") }
        }

        return email
    }

    static func scanMailDirectory(at path: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var emlxFiles: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "emlx" {
                emlxFiles.append(url)
            }
        }
        return emlxFiles
    }

    enum EMLXError: LocalizedError {
        case invalidFormat(String)
        case noEmailsFound

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let reason): return "Invalid EMLX format: \(reason)"
            case .noEmailsFound: return "No EMLX emails found in directory"
            }
        }
    }
}
