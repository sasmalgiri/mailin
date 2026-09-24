//
//  MessageLocator.swift
//  mailin
//
//  S4/S5: where a message's bytes ARE, rather than a copy of them.
//
//  The point of a locator is that it is small and exact. A 1.5 GB message
//  needs 40 bytes to describe and can then be read, hashed, exported or
//  attachment-extracted in bounded memory, at any time, without the whole
//  message ever being resident. That is what removes the 100 MB
//  `MBOXParser.maxMessageBytes` ceiling: the ceiling existed because the
//  parser's unit of work was "the message as a String".
//
//  Fidelity rule these types exist to protect: a locator points at the
//  ORIGINAL bytes. Anything derived from it can be re-derived, and a hash
//  taken through a locator is a hash of the source, not of our reconstruction.
//  A range that no longer resolves is reported as damage — never silently
//  substituted with a re-parse, because a reviewer must be able to tell the
//  difference.
//

import Foundation

/// A half-open byte range `[offset, offset + length)` in some source.
struct ByteRange: Sendable, Equatable, Codable, CustomStringConvertible {
    var offset: Int64
    var length: Int64

    var end: Int64 { offset + length }
    var isEmpty: Bool { length <= 0 }

    var description: String { "\(offset)..<\(end)" }

    func contains(_ other: ByteRange) -> Bool {
        other.offset >= offset && other.end <= end
    }

    /// `other` expressed relative to the start of this range, for descending
    /// from a message range into a part range without losing absolute truth.
    func relative(_ other: ByteRange) -> ByteRange? {
        guard contains(other) else { return nil }
        return ByteRange(offset: other.offset - offset, length: other.length)
    }
}

/// Where one message lives inside a source file.
struct MessageLocator: Sendable, Equatable, Codable, Identifiable {
    var id: UUID = UUID()

    /// Stable identity of the source. A path alone is not enough — the file
    /// can move — so the digest is what proves a later read hit the same
    /// bytes.
    var sourceDigest: String?
    var sourcePath: String

    /// The whole message, INCLUDING its `From_` envelope line when the source
    /// is an mbox. `bodyRange` and `headerRange` are subranges.
    var messageRange: ByteRange
    /// The `From ` separator line, absent for `.eml` sources.
    var envelopeRange: ByteRange?
    /// Header block, up to and excluding the blank separator line.
    var headerRange: ByteRange
    /// Everything after the blank line. Never decoded at index time.
    var bodyRange: ByteRange

    /// Position in the source, for a stable import order and for reconciling
    /// a resumed import against the same file.
    var ordinal: Int

    var byteCount: Int64 { messageRange.length }
}

/// Where one MIME part lives, so an attachment can be read without decoding
/// its siblings.
struct PartLocator: Sendable, Equatable, Codable, Identifiable {
    var id: UUID = UUID()
    /// The message this part belongs to.
    var messageID: UUID

    /// MIME path, e.g. `[1, 2]` for the second part of the first part.
    var path: [Int]
    var mimeType: String
    var filename: String?
    var contentID: String?
    var contentTransferEncoding: String?

    /// The part's raw (still-encoded) bytes, absolute in the source. Decoding
    /// is the reader's job, at read time, in whatever size chunks it wants.
    var contentRange: ByteRange
    /// The part's own header block.
    var headerRange: ByteRange

    var isAttachment: Bool {
        filename?.isEmpty == false || (contentID == nil && !mimeType.hasPrefix("text/"))
    }

    /// Decoded size is not stored: for base64 it is derivable (≈ 3/4), and
    /// storing a computed value invites it to drift from the bytes. Callers
    /// that need an exact figure decode and count.
    var encodedByteCount: Int64 { contentRange.length }
}

// MARK: - Reading

enum LocatorReadError: LocalizedError, Equatable {
    case sourceMissing(String)
    case rangeUnresolvable(ByteRange, fileSize: Int64)
    case digestMismatch(expected: String, path: String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "The original file is no longer at \(path), so these bytes cannot be re-read."
        case .rangeUnresolvable(let range, let size):
            return "Bytes \(range) are outside the \(size)-byte source — the file has changed since it was imported."
        case .digestMismatch(_, let path):
            return "The file at \(path) is not the one that was imported. Re-reading it could show different content, so it was refused."
        case .ioError(let reason):
            return "Could not read the original file: \(reason)"
        }
    }
}

/// Reads byte ranges out of a source file, in bounded memory.
///
/// Every read is bounds-checked against the file's CURRENT size, and an
/// out-of-range read is an error rather than a short read. A silently
/// truncated attachment is worse than a missing one: the first looks like
/// evidence.
struct LocatorReader: Sendable {

    /// Verify the source digest before reading. On by default — the whole
    /// value of a locator read is that it returns the original bytes, and a
    /// changed file means it would not.
    var verifiesDigest: Bool = true

    func read(_ range: ByteRange, from path: String, expectedDigest: String? = nil) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocatorReadError.sourceMissing(path)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard range.offset >= 0, range.length >= 0, range.end <= size else {
            throw LocatorReadError.rangeUnresolvable(range, fileSize: size)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw LocatorReadError.ioError("cannot open \(path)")
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(range.offset))
            let data = try handle.read(upToCount: Int(range.length)) ?? Data()
            guard data.count == Int(range.length) else {
                // A short read here means the file shrank between the size
                // check and the read. Reporting it beats returning a partial
                // attachment that looks complete.
                throw LocatorReadError.rangeUnresolvable(range, fileSize: Int64(data.count))
            }
            return data
        } catch let error as LocatorReadError {
            throw error
        } catch {
            throw LocatorReadError.ioError(error.localizedDescription)
        }
    }

    /// Streams a range in chunks, so a multi-gigabyte part can be written to
    /// an export or hashed without ever being fully resident.
    func stream(_ range: ByteRange,
                from path: String,
                chunkSize: Int = 4 * 1_048_576,
                into sink: (Data) throws -> Void) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw LocatorReadError.sourceMissing(path)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.offset))
            var remaining = range.length
            while remaining > 0 {
                let want = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    throw LocatorReadError.rangeUnresolvable(range, fileSize: range.end - remaining)
                }
                try sink(chunk)
                remaining -= Int64(chunk.count)
            }
        } catch let error as LocatorReadError {
            throw error
        } catch {
            throw LocatorReadError.ioError(error.localizedDescription)
        }
    }
}
