//
//  OLE2CompoundSniff.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": an OLE2 compound file
//  names its producer in the root directory entry's CLSID (MS-CFB §2.6.1,
//  bytes 0x50–0x5F of the entry). When the first directory sector lies
//  inside the bytes already read, a Publisher, binary Visio or Project
//  file is recognised without its name; otherwise the caller falls back to
//  the extension, as it always did for .doc/.xls/.ppt.
//

import Foundation

enum OLE2CompoundSniff {

    /// {00021201-0000-0000-00C0-000000000046} — Microsoft Publisher document.
    static let publisherCLSID: [UInt8] = [0x01, 0x12, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]
    /// {00021A13-…} Visio 5 and {00021A14-…} Visio 2000–2010 drawings; {00021A15-…} Visio 2013 on-disk compound stencils.
    static let visioCLSIDs: [[UInt8]] = [
        [0x13, 0x1A, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46],
        [0x14, 0x1A, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46],
        [0x15, 0x1A, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46],
    ]
    /// {74B78F3A-C8C8-11D1-BE11-00C04FB6FAF1} — Microsoft Project 98 and later (.mpp/.mpt).
    static let projectCLSID: [UInt8] = [0x3A, 0x8F, 0xB7, 0x74, 0xC8, 0xC8, 0xD1, 0x11, 0xBE, 0x11, 0x00, 0xC0, 0x4F, 0xB6, 0xFA, 0xF1]

    /// The root entry's CLSID when the first directory sector is within `head`, else nil.
    static func rootCLSID(head: Data) -> [UInt8]? {
        let bytes = [UInt8](head)
        guard bytes.count >= 128, Array(bytes[0..<8]) == OfficeTextExtractor.oleSignature else { return nil }
        let shift = Int(bytes[30]) | Int(bytes[31]) << 8
        guard shift >= 7, shift <= 16 else { return nil }
        let sectorSize = 1 << shift
        let firstDir = Int(Int32(bitPattern: UInt32(bytes[48]) | UInt32(bytes[49]) << 8 | UInt32(bytes[50]) << 16 | UInt32(bytes[51]) << 24))
        guard firstDir >= 0, firstDir < 1 << 20 else { return nil }
        let entry = (firstDir + 1) * sectorSize
        guard entry + 128 <= bytes.count else { return nil }
        return Array(bytes[(entry + 0x50)..<(entry + 0x60)])
    }

    /// The document kind the root CLSID names, when it is one this module reads by CLSID.
    static func kind(head: Data) -> DocumentKind? {
        guard let clsid = rootCLSID(head: head) else { return nil }
        if clsid == publisherCLSID { return .pub }
        return nil
    }
}
