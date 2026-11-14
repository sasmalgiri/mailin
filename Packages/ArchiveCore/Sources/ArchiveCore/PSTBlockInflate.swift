//
//  PSTBlockInflate.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §3, found on the real `example-2013.ost` (java-libpst
//  test resource, Outlook 2013, header wVer 36): the 4 KiB-page OST stores
//  block data **zlib-compressed**. The BBTENTRY of that format is
//  `bid(8) ib(8) cb(2) cbInflated(2) cRef(2) padding(2)` — `cb` is the stored
//  (compressed) size and `cbInflated` the size after inflation; a block is
//  compressed exactly when `cbInflated > cb` (62 of the file's 310 blocks:
//  every message, every folder with a contents table, every subnode block).
//  The stored bytes are an RFC 1950 zlib stream (0x78 0x9C header, DEFLATE,
//  Adler-32). libpst inflates in `pst_read_block_size` and decrypts afterwards
//  (`pst_ff_getIDblock_dec`), so the order here is inflate, then decode.
//
//  Before this, the reader walked the real file's B-trees correctly (the page
//  geometry seam was right) but every compressed block came back as its raw
//  deflate bytes: three messages with no properties, folders without names.
//

import Foundation
import Compression

enum PSTBlockInflate {

    /// Inflates one zlib-wrapped block to `expected` bytes (the BBTENTRY's
    /// `cbInflated`). Returns nil when the bytes are not a deflate stream the
    /// decoder accepts — the caller then keeps the raw bytes and the item is
    /// reported unreadable, never invented.
    ///
    /// SAFETY: `compression_stream` is a C API that needs raw pointers; the
    /// `unsafe` marks sit on those calls only. `source` holds exactly the
    /// deflate payload (`stored.count - 2` bytes, the two-byte zlib header
    /// skipped); `output` is `expected` bytes, and the decoder writes at most
    /// `dst_size` into it, so `produced = expected - dst_size` stays inside.
    /// The Adler-32 trailer after the deflate data is left unread by the
    /// decoder (it stops at the stream's end marker).
    static func inflate(_ stored: [UInt8], expected: Int) -> [UInt8]? {
        guard stored.count > 2, expected > 0, stored[0] == 0x78, (UInt16(stored[0]) << 8 | UInt16(stored[1])) % 31 == 0 else { return nil }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { unsafe streamPointer.deallocate() }
        guard unsafe compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { unsafe compression_stream_destroy(streamPointer) }

        let payloadCount = stored.count - 2
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: payloadCount)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: expected)
        defer { unsafe source.deallocate(); unsafe output.deallocate() }
        unsafe source.initialize(from: Array(stored[2...]), count: payloadCount)

        unsafe streamPointer.pointee.src_ptr = UnsafePointer(source)
        unsafe streamPointer.pointee.src_size = payloadCount
        unsafe streamPointer.pointee.dst_ptr = output
        unsafe streamPointer.pointee.dst_size = expected
        let status = unsafe compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        let produced = expected - (unsafe streamPointer.pointee.dst_size)
        // END: the whole stream was consumed and fitted. OK with the output full:
        // the stream claims more than `cbInflated` — the file's own figure wins
        // and the extra is not read (a corrupt entry, reported by the caller's checks).
        guard status == COMPRESSION_STATUS_END || (status == COMPRESSION_STATUS_OK && produced == expected) else { return nil }
        guard produced == expected else { return nil }
        return unsafe Array(UnsafeBufferPointer(start: output, count: produced))
    }
}
