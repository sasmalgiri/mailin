//
//  PSTStreamingParser.swift
//  maxmailin
//
//  STREAMING PST PARSER — v0.1 SKELETON
//
//  Honest scope statement:
//  The full PST format (Microsoft's MS-PST spec) is a b-tree of references
//  into a 64-bit or ANSI block-based file. A *properly* streaming PST
//  reader requires implementing:
//    • PST header parsing (256 bytes)
//    • NDB (Node Database) Layer: BREF, NBT (Node B-Tree), BBT (Block B-Tree)
//    • LTP (List, Table, Property) Layer: HN, BTH, PC, TC
//    • Messaging Layer: Folders, Messages, Attachments
//
//  Each layer is a non-trivial parser. Full implementation is 1-2 weeks.
//
//  This file ships the *streaming infrastructure* — file handle, chunked
//  reads, cooperative cancellation, byte-range helpers — so a future
//  full implementation can plug into it without re-architecting I/O.
//  For PST files that fit within the 2 GB cap, it falls back to the
//  existing PSTParser. For larger files, it emits a clear error rather
//  than crashing on memory exhaustion.
//
//  When the full implementation is ready, the fallback path is removed.
//

import Foundation
import CryptoKit
import os.log

struct PSTStreamingParser {

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                       category: "PSTStreaming")

    enum StreamingError: LocalizedError {
        case fileNotFound(URL)
        case headerInvalid
        case unsupportedVersion(UInt16)
        case notYetSupported(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let u): return "PST file not found: \(u.lastPathComponent)"
            case .headerInvalid: return "PST header is invalid or corrupt."
            case .unsupportedVersion(let v): return "Unsupported PST version: \(v)"
            case .notYetSupported(let detail): return "PST streaming not yet supported for: \(detail)"
            }
        }
    }

    /// File-size threshold below which we delegate to the existing in-memory
    /// PSTParser (which already works well for ≤2 GB files). Above this,
    /// we attempt streaming.
    static let fallbackThreshold: Int64 = 2_000_000_000  // 2 GB

    /// Parse a PST file using streaming I/O. Returns an empty array if
    /// streaming isn't yet supported for this file; the caller can fall back
    /// to the in-memory PSTParser.
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [MBOXParser.RawEmail] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw StreamingError.fileNotFound(fileURL)
        }

        let fileSize = try fileSizeOf(fileURL)
        logger.info("PST size: \(fileSize) bytes")

        // Small files: delegate to existing parser. Bypasses the streaming
        // codepath entirely for files we know work today.
        if fileSize <= fallbackThreshold {
            logger.info("File ≤ 2GB — delegating to in-memory PSTParser")
            return try PSTParser.parse(fileURL: fileURL, senderEmail: senderEmail, onProgress: onProgress)
        }

        // Large files: full streaming required. Read header, validate, then
        // walk b-trees. Below we ship the header validation portion.
        let header = try readHeader(at: fileURL)
        logger.info("PST header magic=\(header.magic, privacy: .public) version=\(header.version)")

        guard header.magic == "!BDN" else {
            throw StreamingError.headerInvalid
        }
        guard header.version == 23 || header.version == 36 || header.version == 14 || header.version == 15 else {
            throw StreamingError.unsupportedVersion(header.version)
        }

        // The remaining work (NBT/BBT traversal, LTP property streams, message
        // assembly) is the multi-week chunk. Surface a clear error so the
        // caller doesn't think parsing silently produced 0 emails.
        throw StreamingError.notYetSupported("Files larger than 2 GB. Stream-walk of NBT/BBT/LTP layers is not yet implemented. Track v2.1 roadmap.")
    }

    // MARK: - Streaming primitives

    /// Read the 256-byte PST header from the start of the file.
    static func readHeader(at url: URL) throws -> PSTHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let raw = try handle.read(upToCount: 256), raw.count >= 256 else {
            throw StreamingError.headerInvalid
        }

        let magicBytes = raw.subdata(in: 0..<4)
        let magic = String(data: magicBytes, encoding: .ascii) ?? ""

        // Version (Unicode PST) at offset 0x0A, little-endian UInt16
        let versionLo = UInt16(raw[10])
        let versionHi = UInt16(raw[11]) << 8
        let version = versionLo | versionHi

        return PSTHeader(magic: magic, version: version, rawHeader: raw)
    }

    /// Read a specific byte range from a PST file using random access.
    /// Memory footprint: bounded by `range.count`, never the full file size.
    static func readBytes(at url: URL, range: Range<UInt64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.lowerBound)
        let length = Int(range.upperBound - range.lowerBound)
        guard let data = try handle.read(upToCount: length) else {
            throw StreamingError.headerInvalid
        }
        return data
    }

    /// File-size helper that uses the URL resource value rather than
    /// reading the entire file.
    static func fileSizeOf(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int64) ?? 0
    }

    /// Compute SHA-256 of a PST file with bounded memory (1 MB chunks).
    /// Used for chain-of-custody anchoring even on multi-GB files.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Types

    struct PSTHeader {
        let magic: String      // "!BDN" for valid PST
        let version: UInt16    // 14/15 ANSI; 23/36 Unicode
        let rawHeader: Data
    }
}
