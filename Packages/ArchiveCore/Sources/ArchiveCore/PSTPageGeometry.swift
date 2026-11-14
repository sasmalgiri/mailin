//
//  PSTPageGeometry.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Microsoft intake and folders": the 4 KiB-page
//  variant of the NDB layer that Outlook 2013 and later write for OST files
//  (header `wVer` 36, `bFile` 0x24). [MS-PST] documents only the 512-byte
//  page files (ANSI 14/15, Unicode 23); the 4 KiB geometry below follows the
//  libpff/libpst description of the "64-bit with 4k page" format and is the
//  ONE seam that selects a file's page layout — the reader and the spec
//  writer both take their sizes from here, so the 512-byte path is unchanged
//  byte for byte (rule 14).
//
//  Confirmed on the real `example-2013.ost` (java-libpst test resource,
//  Outlook 2013; `RealMailStoreFixtureTests`, 2026-11-07):
//   • header: the 564-byte Unicode HEADER layout (ROOT at 180, bCryptMethod
//     at 513, BBT/NBT BREFs at 216–247), `wVer` 36, `wMagicClient` "SO";
//   • BTPAGE: 4096 bytes; rgentries 4056 bytes; then cEnt (2 bytes), cEntMax
//     (2) = 169 for 24-byte entries / 126 for 32-byte, cbEnt (1), cLevel (1);
//     then the 24-byte trailer at 4072: ptype, ptypeRepeat, wSig, dwCRC over
//     the first 4072 bytes, bid, 8 reserved bytes;
//   • BTENTRY / NBTENTRY: the Unicode sizes (24 / 32). **BBTENTRY differs
//     from [MS-PST]**: `bid(8) ib(8) cb(2) cbInflated(2) cRef(2) pad(2)` —
//     the stored block is zlib-compressed when cbInflated > cb
//     (`PSTBlockInflate`; the synthetic fixture had no compressed block, so
//     this was invisible until the real file ran);
//   • blocks: Unicode XBLOCK / SLBLOCK layouts, a 24-byte BLOCKTRAILER (cb,
//     wSig, dwCRC, bid, 8 reserved), rounded up to 512 bytes (a 172-byte
//     block's trailer sits at +488);
//   • AMap: one bit per 512 bytes, 4072 map bytes per page — the file ends
//     exactly one AMap region after ROOT.ibAMapLast.
//  NOT as `PSTWriterLayout.ost4K` assumed: Outlook 2013 put the DList at
//  0x21000 and the first AMap at 0x22000 (no PMap / FMap pages); the writer's
//  fixed-page positions are its own, the reader takes every position from the
//  header and never relies on them.
//

import Foundation

struct PSTPageGeometry: Sendable, Equatable {
    /// `wVer` from the header.
    let version: UInt16
    /// Node and block B-tree page size.
    let pageSize: Int
    /// PAGETRAILER bytes at the end of every page.
    let pageTrailer: Int
    /// BLOCKTRAILER bytes at the end of every block.
    let blockTrailer: Int
    /// Blocks are placed and sized in multiples of this.
    let blockAlign: Int
    /// Where a BTPAGE's rgentries end and its counts begin.
    let entriesEnd: Int
    /// 4 KiB pages count entries in two bytes (cEnt, cEntMax), then cbEnt, cLevel.
    let wideCounts: Bool
    /// 64-bit BIDs / IBs (Unicode) or 32-bit (ANSI).
    let unicode: Bool

    /// Outlook 97–2002 (`wVer` 14, 15).
    static let ansi = PSTPageGeometry(version: 15, pageSize: 512, pageTrailer: 12, blockTrailer: 12, blockAlign: 64,
                                      entriesEnd: 496, wideCounts: false, unicode: false)
    /// Outlook 2003–2010 PST and OST (`wVer` 23).
    static let unicode512 = PSTPageGeometry(version: 23, pageSize: 512, pageTrailer: 16, blockTrailer: 16, blockAlign: 64,
                                            entriesEnd: 488, wideCounts: false, unicode: true)
    /// Outlook 2013 and later OST (`wVer` 36): 4 KiB pages.
    static let fourK = PSTPageGeometry(version: 36, pageSize: 4096, pageTrailer: 24, blockTrailer: 24, blockAlign: 512,
                                       entriesEnd: 4056, wideCounts: true, unicode: true)

    /// The dispatch seam: a header's `wVer` → the page geometry it was written with.
    /// 14/15 ANSI; 36 the 4 KiB variant; every other value ≥ 23 the Unicode 512-byte file
    /// (37 is a Unicode PST written by a WIP-capable Outlook, same layout).
    static func forHeaderVersion(_ version: UInt16) -> PSTPageGeometry {
        if version < 23 { return ansi }
        if version == 36 { return fourK }
        return unicode512
    }

    /// Reads a BTPAGE's counts at `pageOffset` in `bytes`: (cEnt, cbEnt, cLevel).
    func pageCounts(_ bytes: Data, pageOffset o: Int) -> (cEnt: Int, cbEnt: Int, cLevel: Int) {
        let base = bytes.startIndex + o + entriesEnd
        if wideCounts {
            return (Int(PSTSpecReader.u16(bytes, o + entriesEnd)), Int(bytes[base + 4]), Int(bytes[base + 5]))
        }
        return (Int(bytes[base]), Int(bytes[base + 2]), Int(bytes[base + 3]))
    }
}

/// Where the spec writer puts the fixed pages of a new file, per geometry.
struct PSTWriterLayout: Sendable, Equatable {
    let geometry: PSTPageGeometry
    /// `wMagicClient`: "SM" for a PST, "SO" for an OST.
    let magicClient: [UInt8]
    /// Density list page, first allocation map, first free byte for data.
    let dlistIB: UInt64
    let amapBase: UInt64
    let firstDataIB: UInt64

    var pageSize: Int { geometry.pageSize }
    var pageTrailer: Int { geometry.pageTrailer }
    var blockTrailer: Int { geometry.blockTrailer }
    var blockAlign: Int { geometry.blockAlign }
    /// Bytes of map in an AMap / PMap / DList page.
    var mapBytes: Int { pageSize - pageTrailer }
    /// Bytes one AMap bit stands for: the block alignment.
    var amapGranule: UInt64 { UInt64(blockAlign) }
    /// Bytes one AMap page covers.
    var amapRegion: UInt64 { UInt64(mapBytes) * 8 * amapGranule }
    /// rgentries bytes of a BTPAGE.
    var entriesBytes: Int { geometry.entriesEnd }

    /// [MS-PST] 2.2.2.7: DList at 0x4200, first AMap at 0x4400 (496 × 8 × 64 = 253,952 bytes each),
    /// PMap at 0x4600; data from 0x4800.
    static let unicodePST = PSTWriterLayout(geometry: .unicode512, magicClient: [0x53, 0x4D],
                                            dlistIB: 0x4200, amapBase: 0x4400, firstDataIB: 0x4800)
    /// The 4 KiB-page OST: the same fixed pages, each 4 KiB and 4 KiB-aligned —
    /// DList at 0x4000, first AMap at 0x5000 (4072 × 8 × 512 = 16,678,912 bytes each),
    /// PMap at 0x6000; data from 0x7000. Positions a real file must confirm.
    static let ost4K = PSTWriterLayout(geometry: .fourK, magicClient: [0x53, 0x4F],
                                       dlistIB: 0x4000, amapBase: 0x5000, firstDataIB: 0x7000)
}
