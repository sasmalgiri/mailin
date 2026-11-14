//
//  WholeMessageReadLimit.swift
//  ArchiveCore
//
//  CLOSE-01 follow-up (2026-11-09): the previous engine's honest refusal.
//
//  With the offset engine on, an Apple Mail .emlx or Outlook .msg above the
//  full-parse ceiling is imported by range wherever it is — a file of its
//  own, a message in an Apple Mail library folder, or a member of an archive
//  (`LargeMessageRoute`). With the offset engine switched off (the previous
//  engine, kept as the rollback path) the message is still read whole into
//  memory by `EMLXParser` / `MSGParser`. CLOSE-01 removed the size refusal
//  those readers had, so on that path a multi-gigabyte message could exhaust
//  memory. The refusal is back, on the whole-read path only, by name: the
//  message is not imported, the reason says why and what to switch on.
//  The ceilings are the ones the readers had before CLOSE-01.
//

import Foundation

enum WholeMessageReadLimit {
    /// The largest Outlook .msg file read whole into memory.
    static let msgBytes: Int64 = 2_000_000_000
    /// The largest Apple Mail .emlx file read whole into memory.
    static let emlxBytes: Int64 = 500_000_000

    /// Report category for messages refused this way inside a folder source
    /// (counted as unresolved, never as damaged).
    static let category = "refused_message_too_large_for_whole_read"

    /// The archive-member refusal reason (counted as `reason:<this>`).
    static let memberReason = "too large for the previous import engine"

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

/// A message refused by the whole-read path because it is above its ceiling.
struct WholeMessageReadRefusal: Error, LocalizedError, Equatable {
    enum Kind: String, Sendable { case msg = "Outlook .msg", emlx = "Apple Mail .emlx" }
    let kind: Kind
    let fileName: String
    let sizeBytes: Int64
    let limitBytes: Int64

    var errorDescription: String? {
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .file)
        return "\(fileName) (\(kind.rawValue), \(size)) was not imported: the previous import engine reads a message whole into memory and refuses one above \(limit). Turn the offset import engine on to import it by range in bounded memory."
    }

    static func check(_ url: URL, kind: Kind) throws {
        let limit = kind == .msg ? WholeMessageReadLimit.msgBytes : WholeMessageReadLimit.emlxBytes
        let size = WholeMessageReadLimit.fileSize(url)
        if size > limit {
            throw WholeMessageReadRefusal(kind: kind, fileName: url.lastPathComponent, sizeBytes: size, limitBytes: limit)
        }
    }
}
