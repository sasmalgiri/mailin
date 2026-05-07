import Foundation

struct ParserFactory {
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mbox", "eml":
            return try MBOXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "emlx":
            return try EMLXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "msg":
            return try MSGParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        case "pst", "ost":
            return try PSTParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        default:
            return try MBOXParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        }
    }

    static let allSupportedExtensions: [String] = [
        "mbox", "eml", "emlx", "msg", "pst", "ost"
    ]
}
