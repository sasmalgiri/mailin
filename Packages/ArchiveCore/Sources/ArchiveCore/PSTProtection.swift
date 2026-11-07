//
//  PSTProtection.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Protected mail/documents": what "protection"
//  means in an Outlook data file, said precisely ([MS-PST] 2.2.2.6 and 5):
//
//    bCryptMethod 0x00  NDB_CRYPT_NONE        plain
//    bCryptMethod 0x01  NDB_CRYPT_PERMUTE     "compressible encryption" — a fixed
//                                             byte substitution; decoded on read
//    bCryptMethod 0x02  NDB_CRYPT_CYCLIC      "high encryption" — a block-keyed
//                                             substitution; decoded on read
//    bCryptMethod 0x10  NDB_CRYPT_EDPCRYPTED  Windows Information Protection: data
//                                             blocks are encrypted with a key held by
//                                             Windows — locked, named, not read
//
//  The Outlook "password" (PidTagPstPassword, 0x67FF, on the message store)
//  is a CRC of the password Outlook checks before opening the file. It is
//  not encryption and protects nothing in the bytes; a file carrying it is
//  read in full, and the import receipt says so — no secret is bypassed, this
//  is the documented behaviour of the format.
//

import Foundation

enum PSTProtection {

    enum CryptMethod: Equatable, Sendable {
        case none, permute, cyclic, windowsProtected, unknown(UInt8)

        init(raw: UInt8) {
            switch raw {
            case 0x00: self = .none
            case 0x01: self = .permute
            case 0x02: self = .cyclic
            case 0x10: self = .windowsProtected
            default: self = .unknown(raw)
            }
        }

        var raw: UInt8 {
            switch self {
            case .none: return 0; case .permute: return 1; case .cyclic: return 2
            case .windowsProtected: return 0x10; case .unknown(let v): return v
            }
        }

        /// Decoded on read by both PST readers.
        var isReadable: Bool { self == .none || self == .permute || self == .cyclic }

        var name: String {
            switch self {
            case .none: return "no encoding (bCryptMethod 0)"
            case .permute: return "compressible encryption (permutation, bCryptMethod 1)"
            case .cyclic: return "high encryption (cyclic, bCryptMethod 2)"
            case .windowsProtected: return "Windows Information Protection (bCryptMethod 0x10)"
            case .unknown(let v): return "unknown bCryptMethod 0x\(String(v, radix: 16, uppercase: true))"
            }
        }

        /// The refusal, by name, for a file this build cannot decode.
        var lockedDescription: String {
            switch self {
            case .windowsProtected:
                return "locked: this file is protected by Windows Information Protection (bCryptMethod 0x10) — its data blocks are encrypted with a key held by the enrolled Windows device, and mailin cannot read them. Export the mailbox again from Outlook on that device without protection."
            default:
                return "locked: \(name) — mailin reads bCryptMethod 0 (none), 1 (compressible) and 2 (high) only."
            }
        }
    }

    struct Report: Equatable, Sendable {
        var cryptMethod: CryptMethod
        /// PidTagPstPassword when present and non-zero.
        var passwordCRC: UInt32?
        var isUnicode: Bool
        var isOST: Bool

        var isPasswordProtected: Bool { (passwordCRC ?? 0) != 0 }

        /// What the import receipt records about this file's protection, or nil when there is nothing to say.
        var receiptNote: String? {
            var parts: [String] = []
            if isPasswordProtected {
                parts.append("Outlook password set (PidTagPstPassword CRC 0x\(String(passwordCRC ?? 0, radix: 16, uppercase: true))): MS-PST stores only a checksum of the password and encrypts nothing with it, so the file was read in full — no secret was bypassed")
            }
            switch cryptMethod {
            case .permute, .cyclic: parts.append("data blocks use \(cryptMethod.name) and were decoded on read")
            case .windowsProtected, .unknown: parts.append(cryptMethod.lockedDescription)
            case .none: break
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    /// bCryptMethod from the header: offset 513 in a Unicode header, 461 in an ANSI one ([MS-PST] 2.2.2.6).
    static func cryptMethod(header data: Data) -> CryptMethod? {
        guard data.count >= 564, data[data.startIndex] == 0x21, data[data.startIndex + 1] == 0x42 else { return nil }
        let version = UInt16(data[data.startIndex + 10]) | UInt16(data[data.startIndex + 11]) << 8
        let offset = version >= 23 ? 513 : 461
        return CryptMethod(raw: data[data.startIndex + offset])
    }

    /// Header facts plus the message store's password CRC (read through the spec reader when the file is decodable).
    static func inspect(data: Data) -> Report? {
        guard let method = cryptMethod(header: data) else { return nil }
        let version = UInt16(data[data.startIndex + 10]) | UInt16(data[data.startIndex + 11]) << 8
        let client = UInt16(data[data.startIndex + 8]) | UInt16(data[data.startIndex + 9]) << 8
        var report = Report(cryptMethod: method, passwordCRC: nil, isUnicode: version >= 23, isOST: client == 0x4F53)
        if method.isReadable, let spec = try? PSTSpecReader(data: data), let store = spec.nodes[0x21] {
            let props = spec.propertyContext(dataBid: store.dataBid, subBid: store.subBid)
            if let crc = props[0x67FF]?.int, crc != 0 { report.passwordCRC = UInt32(truncatingIfNeeded: crc) }
        }
        return report
    }

    static func inspect(fileURL: URL) -> Report? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return inspect(data: data)
    }

    /// The receipt line for a PST/OST source, or nil when the file carries no protection of any kind.
    static func receiptNote(fileURL: URL) -> String? {
        inspect(fileURL: fileURL)?.receiptNote
    }
}
