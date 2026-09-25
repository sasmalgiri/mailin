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
import CryptoKit

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

    /// True when a digest was recorded at import, so `LocatorReader
    /// .verifySource` can actually establish provenance. False means the
    /// message predates digest recording — which is NOT the same as
    /// "verification failed", and callers must not present it as verified.
    var hasVerifiableSource: Bool {
        !(sourceDigest ?? "").isEmpty
    }
}

/// Where one MIME part lives.
///
/// ⚠️ DESIGN ONLY — NOT IMPLEMENTED, AND NOTHING USES IT.
///
/// The intent was that an attachment could be read without decoding its
/// siblings. That is not what S5 shipped, and this type's previous comment
/// said otherwise. Nothing produces a `PartLocator` — no scanner emits one,
/// there is no `part_locators` table — and nothing consumes one.
///
/// What S5 actually delivers is MESSAGE-scoped: `AttachmentHydrator` reads a
/// message's whole `messageRange` from the source file via `LocatorReader`
/// and decodes the MIME tree from those bytes. That is a real improvement on
/// the previous behaviour (original bytes, and it works for a message
/// imported header-only, which has no stored `rawSource` at all), but the
/// per-part economy is still owed: pulling a 10 KB attachment out of a 12 MB
/// message reads all 12 MB.
///
/// Implementing it means a producer in `OffsetMBOXScanner` that walks MIME
/// boundaries during the same pass, a schema version for the table, and a
/// consumer in `AttachmentHydrator` ahead of the whole-message path. The
/// shape below is kept because it is the shape that work needs — the ranges
/// are absolute in the source, and decoded size is deliberately not stored.
/// It is NOT evidence that any of it works.
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

    // NOTE ON VERIFICATION — read this before trusting a locator read.
    //
    // A locator read does NOT prove the source file is unchanged, and an
    // earlier version of this type claimed it did: it took an
    // `expectedDigest` parameter, documented "verify the source digest before
    // reading", carried a `verifiesDigest` flag and a `digestMismatch` error —
    // and used none of them. `AttachmentHydrator` passed the digest in good
    // faith. The effect was that an edited or swapped source file would be
    // read and its bytes presented as the original message, silently, which is
    // the worst failure mode this app has.
    //
    // It is not fixed by verifying on every read: the digest covers the WHOLE
    // source, so checking it before showing one attachment would hash a
    // possibly multi-gigabyte mailbox on every click. That is not a trade worth
    // making for an interactive read.
    //
    // So the split is explicit instead:
    //   • `read` / `stream` are cheap and bounds-checked. They detect a file
    //     that has MOVED, SHRUNK, or cannot supply the range — all of which
    //     throw. They do not detect same-length tampering.
    //   • `verifySource(_:)` does the real thing: streams the whole file and
    //     compares the digest recorded at import. Call it before anything that
    //     asserts provenance — an export, a hash claim, a produced exhibit.
    //
    // A cheap read is the right default for opening an attachment. A claim
    // about original bytes is not the same operation, and now has its own
    // name.

    func read(_ range: ByteRange, from path: String) throws -> Data {
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

    /// Streams the WHOLE source and compares its digest to the one recorded
    /// at import. This is the operation that actually establishes "these are
    /// the original bytes".
    ///
    /// Costs a full read of the file, so it is deliberately not on the path
    /// that opens an attachment. Call it before an export, a hash claim, or a
    /// produced exhibit.
    ///
    /// Returns without error when the locator carries no digest — that means
    /// the message predates digest recording, which is a different fact from
    /// "verified", and `hasVerifiableSource` distinguishes them so a caller
    /// cannot mistake one for the other.
    func verifySource(_ locator: MessageLocator,
                      chunkSize: Int = 4 * 1_048_576) throws {
        guard let expected = locator.sourceDigest, !expected.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: locator.sourcePath) else {
            throw LocatorReadError.sourceMissing(locator.sourcePath)
        }
        guard let handle = FileHandle(forReadingAtPath: locator.sourcePath) else {
            throw LocatorReadError.ioError("cannot open \(locator.sourcePath)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: chunkSize) }
            catch { throw LocatorReadError.ioError(error.localizedDescription) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw LocatorReadError.digestMismatch(expected: expected,
                                                  path: locator.sourcePath)
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
