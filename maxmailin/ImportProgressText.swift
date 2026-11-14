//
//  ImportProgressText.swift
//  maxmailin
//
//  Five jobs OPEN-04: what the import queue says about progress, in one
//  place so it is testable. Two rules:
//    • A percentage is shown only when it is grounded — the parser reported
//      a real fraction. With no fraction, the line shows what WAS processed
//      (messages saved, bytes committed), never an invented percentage.
//    • "Mail imported" and "attachment text indexed" are two different
//      facts. Imported mail is browsable and its headers and bodies are
//      searchable at once; attachment contents become searchable as the
//      background pass reaches them, and the queue says how many are left.
//

import Foundation

enum ImportProgressText {
    /// Progress of the file being imported.
    /// - fraction: the parser's own fraction, nil when it has none.
    /// - bytesDone: bytes committed to the store so far for this file.
    /// - fileBytes: the source's size; 0 or smaller than `bytesDone` means no reliable total.
    static func fileProgress(fraction: Double?, bytesDone: Int, fileBytes: Int64, messagesSaved: Int) -> String {
        var parts: [String] = []
        if let fraction {
            parts.append("\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%")
        }
        let totalReliable = fileBytes > 0 && Int64(bytesDone) <= fileBytes
        if bytesDone > 0 {
            let done = ByteCountFormatter.string(fromByteCount: Int64(bytesDone), countStyle: .file)
            if totalReliable {
                parts.append(String(localized: "\(done) of \(ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file))"))
            } else {
                parts.append(String(localized: "\(done) processed"))
            }
        }
        if fraction == nil, messagesSaved > 0 {
            parts.append(String(localized: "\(messagesSaved) messages saved"))
        }
        if parts.isEmpty { parts.append(String(localized: "starting")) }
        return parts.joined(separator: " · ")
    }

    /// The attachment-text line under the queue: imported mail versus
    /// attachment contents still to index.
    /// - attempted: emails whose attachments the pass has processed.
    /// - pending: emails with attachments the pass has not reached.
    static func attachmentIndexing(attempted: Int, pending: Int, running: Bool) -> String {
        if pending == 0 {
            return attempted == 0
                ? String(localized: "Imported mail is searchable now. No attachment text is waiting to be indexed.")
                : String(localized: "Imported mail is searchable now. Attachment text is indexed for every email with attachments (\(attempted)).")
        }
        let tail = running
            ? String(localized: "indexing in the background — attachment contents become searchable as it goes")
            : String(localized: "waiting for the next indexing pass")
        return String(localized: "Imported mail is searchable now (headers and bodies). Attachment text: \(pending) emails still to index, \(attempted) done — \(tail).")
    }
}
