//
//  RARDecompressor.swift
//  ArchiveCore
//
//  GAP-RAR (owner decision 2026-11-07): compressed RAR members are decoded
//  by libarchive 3.8.11's RAR 1.5–4.x and RAR 5.0 readers, vendored as the
//  C target `CLibArchiveRAR` (BSD-2-Clause, see its VENDORED.md). The header
//  walk in RARReader.swift stays the authority on what an archive holds and
//  what is refused before a byte is decoded (encryption, unsafe paths, links,
//  a missing volume, a compression the vendored decoder does not open); this
//  file only turns the members it lets through into bytes.
//
//  libarchive reads an archive front to back, so one `Decoder` is one pass:
//  asking for a later member skips forward (a solid stream is decoded through
//  the members in between, without writing them); asking for an earlier one
//  starts a new pass. Every member's CRC-32 (or BLAKE2sp, RAR 5.0) is checked
//  by libarchive at its end and the CRC-32 again here; a member that fails is
//  named with the decoder's reason, never dropped. A ceiling that bites stops
//  the copy with the ceiling named (`budgetExceeded`), as the stored path does.
//

import Foundation
import CLibArchiveRAR

extension RARReader {

    /// "libarchive 3.8.11" — recorded in the capability registry evidence.
    static var decoderVersion: String { String(cString: mailin_rar_libarchive_version()) }

    /// The largest RAR 5.0 dictionary the vendored decoder accepts (libarchive refuses a larger one).
    static let maxDecoderDictionaryBytes: Int64 = 64 * 1_048_576

    /// One sequential libarchive pass over a RAR file or a complete run of volumes.
    final class Decoder {
        let volumePaths: [URL]
        private var handle: OpaquePointer?
        /// Ordinal (index among file headers) of the entry libarchive is positioned on; -1 before the first.
        private var position = -1
        /// True once any byte of the current entry has been asked for.
        private var entryTouched = false
        /// A header libarchive could not get past: no later entry is reachable in this archive.
        private var stoppedAt: (ordinal: Int, reason: String)?

        init(volumePaths: [URL]) { self.volumePaths = volumePaths }
        deinit { close() }

        private func close() {
            if let handle { mailin_rar_close(handle) }
            handle = nil
            position = -1
            entryTouched = false
        }

        private func lastError() -> String {
            guard let handle else { return "the decoder is not open" }
            let message = String(cString: mailin_rar_error(handle))
            return message.isEmpty ? "unknown libarchive error" : message
        }

        private func open() throws {
            close()
            let paths = volumePaths.map { $0.path }
            var cStrings = paths.map { strdup($0) }
            defer { cStrings.forEach { free($0) } }
            let opened: OpaquePointer? = cStrings.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                    mailin_rar_open($0, Int32(buffer.count))
                }
            }
            guard let opened else { throw ReadError.malformed("the RAR decoder could not be started (out of memory)") }
            handle = opened
            guard mailin_rar_open_status(opened) == Int32(MAILIN_RAR_OK) else {
                let reason = lastError()
                close()
                throw ReadError.malformed("the RAR decoder could not open the archive: \(reason)")
            }
        }

        /// Positions the pass on `member` (by its ordinal), reopening when it lies behind.
        private func seek(to member: Member) throws {
            let target = member.ordinal
            if let stop = stoppedAt, target >= stop.ordinal {
                throw ReadError.decodeFailed(member: member.name, detail: "the decoder stopped at an earlier header: \(stop.reason)")
            }
            if handle == nil || target < position || (target == position && entryTouched) { try open() }
            while position < target {
                let status = mailin_rar_next(handle)
                if status == Int32(MAILIN_RAR_OK) {
                    position += 1
                    entryTouched = false
                    continue
                }
                if status == Int32(MAILIN_RAR_EOF) {
                    let reached = position
                    close()
                    throw ReadError.malformed("\(member.name): the decoder found \(reached + 1) entries, fewer than the headers list")
                }
                let reason = lastError()
                stoppedAt = (position + 1, reason)
                close()
                throw ReadError.decodeFailed(member: member.name, detail: reason)
            }
            // The decoder and the header walk must agree on what this entry is.
            if let raw = mailin_rar_entry_name(handle) {
                let decoded = String(cString: raw).replacingOccurrences(of: "\\", with: "/")
                let listed = member.name.replacingOccurrences(of: "\\", with: "/")
                if decoded.allSatisfy(\.isASCII), listed.allSatisfy(\.isASCII), decoded != listed {
                    close()
                    throw ReadError.malformed("the decoder found \"\(decoded)\" where the headers list \"\(listed)\"")
                }
            }
        }

        /// Decodes `member` into `destination`, stopping at `maxOutputBytes`.
        /// Returns the bytes written and their CRC-32.
        func decode(_ member: Member, to out: FileHandle, maxOutputBytes: Int64?) throws -> (written: Int64, crc: UInt32) {
            try seek(to: member)
            entryTouched = true
            var crc = ZIPArchiveReader.CRC32()
            var written: Int64 = 0
            let chunkSize = 256 * 1024
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let n = buffer.withUnsafeMutableBytes { mailin_rar_read(handle, $0.baseAddress, chunkSize) }
                if n == 0 { break }
                if n < 0 {
                    let reason = lastError()
                    close()   // the next request starts a fresh pass
                    if reason.contains("CRC") && !reason.contains("Header") { throw ReadError.crcMismatch(member: member.name) }
                    throw ReadError.decodeFailed(member: member.name, detail: reason)
                }
                written += Int64(n)
                if let maxOutputBytes, written > maxOutputBytes { throw ReadError.budgetExceeded(member: member.name, limit: maxOutputBytes) }
                let chunk = Data(buffer[0..<n])
                crc.update(chunk)
                try out.write(contentsOf: chunk)
            }
            return (written, crc.value)
        }
    }
}
