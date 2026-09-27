//
//  SourceSizePolicy.swift
//  mailin
//
//  S1 of SIZE_LIMITS_DESIGN.md — what to do about a big file, decided from the
//  format's documented limits rather than from a number we picked.
//
//  What was wrong before:
//   • PST: refused above 50 GB as if that were the format's limit. It is
//     Outlook's *default* `MaxLargeFileSize` (51,200 MB), registry-configurable
//     to 100 GB and beyond, so the refusal rejected real evidence files.
//   • NSF: refused above 64 GB. That is the pre-ODS-53 limit; HCL documents
//     **256 GB** for Domino 10+ databases at ODS 53 or higher.
//   • The one genuine format ceiling — ANSI PST's 2 GB — was not checked at
//     all, so a corrupt or mislabelled ANSI file was accepted as parseable.
//
//  Deliberate limitation, recorded rather than papered over: mailin cannot yet
//  read the NSF **ODS version** from the header. The field's offset is not
//  documented in the sources consulted (the libyal `libnsfdb` spec and the
//  `sherlock-nsf-parser` crate are the references to mine for it), and guessing
//  a byte offset inside a forensic tool is not acceptable. So an NSF between
//  64 GB and 256 GB is accepted **with a warning** that says exactly that,
//  instead of pretending either capability or certainty.
//

import Foundation

enum SourceSizePolicy {

    /// What to do with a source of this size.
    enum Verdict: Sendable, Equatable {
        /// Within every documented limit.
        case ok
        /// Proceed, but the user is told something true and useful first.
        case warn(String)
        /// A documented format or product limit says this file cannot be what
        /// it claims to be. Refusing is correct here; guessing is not.
        case refuse(String)

        var warning: String? {
            if case .warn(let text) = self { return text }
            return nil
        }
        var refusal: String? {
            if case .refuse(let text) = self { return text }
            return nil
        }
    }

    // MARK: - PST / OST

    /// `wVer` values (MS-PST HEADER, offset 0x0A): 14 or 15 mean ANSI,
    /// ≥ 23 means Unicode, and 37 additionally means the file may be protected
    /// by Windows Information Protection.
    enum PSTFormatVersion: Sendable, Equatable {
        case ansi(UInt16)
        case unicode(UInt16)

        var isANSI: Bool { if case .ansi = self { return true }; return false }
        var raw: UInt16 {
            switch self {
            case .ansi(let v), .unicode(let v): return v
            }
        }
        /// Windows Information Protection marker.
        var mayBeWIPProtected: Bool { raw == 37 }
    }

    /// The ANSI format's hard ceiling. Microsoft caps it deliberately: a larger
    /// `MaxFileSize` "is ignored and the size is limited to 2 GB to prevent
    /// corruption".
    static let ansiPSTMaxBytes: Int64 = 2 * 1_073_741_824          // 2 GiB

    /// The largest PST we have actually executed a parse against. NOT a limit —
    /// a statement about evidence.
    static let pstTestedCeilingBytes: Int64 = 50_000_000_000       // 50 GB

    /// Reads `wVer` from a header probe. Returns nil when the probe is too
    /// short or the magic is wrong (the caller has already classified format).
    static func pstFormatVersion(fromHeader probe: Data) -> PSTFormatVersion? {
        guard probe.count >= 12 else { return nil }
        let start = probe.startIndex
        // MUST be "!BDN".
        guard Array(probe[start..<probe.index(start, offsetBy: 4)]) == [0x21, 0x42, 0x44, 0x4E] else {
            return nil
        }
        let lo = probe[probe.index(start, offsetBy: 10)]
        let hi = probe[probe.index(start, offsetBy: 11)]
        let version = UInt16(lo) | (UInt16(hi) << 8)
        return version >= 23 ? .unicode(version) : .ansi(version)
    }

    static func pstVerdict(version: PSTFormatVersion?, fileSize: Int64) -> Verdict {
        guard let version else {
            // Unreadable header: let the parser report the structural problem;
            // size is not the interesting fact here.
            return .ok
        }

        if version.isANSI, fileSize > ansiPSTMaxBytes {
            let gb = String(format: "%.1f", Double(fileSize) / 1_073_741_824)
            return .refuse("""
                This file declares the ANSI PST format (version \(version.raw)), which cannot exceed 2 GB — \
                Microsoft caps it at 2 GB to prevent corruption — but the file is \(gb) GB. \
                It is corrupt, truncated, or mislabelled.
                """)
        }

        if version.mayBeWIPProtected {
            return .warn("""
                This PST was written by an Outlook version that supports Windows Information Protection, \
                so some content may be encrypted and unreadable. Anything that cannot be decoded is \
                reported rather than skipped silently.
                """)
        }

        if fileSize > pstTestedCeilingBytes {
            let gb = fileSize / 1_000_000_000
            return .warn("""
                This PST is \(gb) GB. Outlook's own default maximum is 50 GB (raised by registry on some \
                systems), and mailin has not been tested above 50 GB, so import may be slow or may fail \
                partway. It will not be refused, and anything imported is reconciled in the receipt.
                """)
        }

        return .ok
    }

    // MARK: - NSF

    /// Pre-ODS-53 maximum (HCL Domino).
    static let nsfLegacyMaxBytes: Int64 = 64 * 1_073_741_824       // 64 GiB
    /// ODS 53+ maximum on Windows and UNIX (Domino 10 and later).
    static let nsfModernMaxBytes: Int64 = 256 * 1_073_741_824      // 256 GiB

    static func nsfVerdict(fileSize: Int64) -> Verdict {
        if fileSize > nsfModernMaxBytes {
            let gb = fileSize / 1_073_741_824
            return .refuse("""
                This NSF is \(gb) GiB. HCL documents 256 GB as the maximum database size (ODS 53 and later; \
                64 GB below that), so no supported Domino configuration produces a file this large — \
                it is corrupt or is not a single NSF database.
                """)
        }

        if fileSize > nsfLegacyMaxBytes {
            let gb = fileSize / 1_073_741_824
            return .warn("""
                This NSF is \(gb) GiB. Domino supports that only for ODS 53 or later databases (below \
                ODS 53 the maximum is 64 GB). mailin cannot yet read the ODS version from the file header, \
                so it cannot confirm which applies — import will proceed and report exactly what it \
                recovered.
                """)
        }

        return .ok
    }
}
