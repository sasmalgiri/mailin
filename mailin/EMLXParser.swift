import Foundation

struct EMLXParser {

    struct ParseResult {
        let emails: [MBOXParser.RawEmail]
        let totalFiles: Int
        let failedFiles: Int
        let errors: [(filename: String, reason: String)]

        var summary: String? {
            guard failedFiles > 0 else { return nil }
            return "Recovered \(emails.count) of \(totalFiles) EMLX files (\(failedFiles) damaged)"
        }
    }

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let result = try parseWithReport(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        return result.emails
    }

    static func parseWithReport(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> ParseResult {
        let ext = fileURL.pathExtension.lowercased()

        if ext == "emlx" {
            let email = try parseSingleEMLX(fileURL: fileURL, senderEmail: senderEmail)
            onProgress?(1.0)
            return ParseResult(emails: [email], totalFiles: 1, failedFiles: 0, errors: [])
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
        var errors: [(filename: String, reason: String)] = []
        let total = Double(emlxFiles.count)
        for (idx, file) in emlxFiles.enumerated() {
            do {
                let email = try parseSingleEMLX(fileURL: file, senderEmail: senderEmail)
                emails.append(email)
            } catch {
                errors.append((filename: file.lastPathComponent, reason: error.localizedDescription))
            }
            onProgress?((Double(idx + 1)) / total)
        }
        return ParseResult(emails: emails, totalFiles: emlxFiles.count, failedFiles: errors.count, errors: errors)
    }

    private static func parseSingleEMLX(fileURL: URL, senderEmail: String) throws -> MBOXParser.RawEmail {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        guard fileSize > 0 else { throw EMLXError.invalidFormat("Empty file (0 bytes)") }
        if fileSize > 500_000_000 { throw EMLXError.invalidFormat("EMLX file too large (\(fileSize / 1_000_000) MB)") }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw EMLXError.invalidFormat("Cannot decode file content")
        }

        let lines = content.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            throw EMLXError.invalidFormat("File too short — expected byte count + RFC822 message")
        }

        let byteCountLine = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let byteCount = Int(byteCountLine), byteCount > 0 else {
            throw EMLXError.invalidFormat("Invalid byte count line: \(byteCountLine.prefix(20))")
        }

        let afterFirstLine = lines.dropFirst().joined(separator: "\n")
        guard !afterFirstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EMLXError.invalidFormat("No message content after byte count line")
        }

        let rfc822Message: String
        let afterData = Data(afterFirstLine.utf8)
        if byteCount > 0 && byteCount <= afterData.count {
            rfc822Message = String(decoding: afterData[afterData.startIndex..<afterData.index(afterData.startIndex, offsetBy: min(byteCount, afterData.count))], as: UTF8.self)
        } else {
            rfc822Message = afterFirstLine
        }

        var plistFlags: [String: Any] = [:]
        if byteCount > 0 && byteCount < afterData.count {
            let plistStart = afterData.index(afterData.startIndex, offsetBy: byteCount)
            let plistStr = String(decoding: afterData[plistStart...], as: UTF8.self)
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
