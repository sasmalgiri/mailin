//
//  SourcePreflight.swift
//  ArchiveCore
//
//  Five jobs OPEN-01: what stands between a file and its import, decided
//  before anything is written. The classifier says what a file IS; this
//  says whether it can be opened at all, and if not, why — so the sheet can
//  tell "not a mail format" from "no permission", "truncated" and
//  "encrypted" instead of one red cross. No credential is ever asked for:
//  an encrypted source is reported, not unlocked.
//

import Foundation

enum SourceCondition: String, Sendable, Equatable, CaseIterable {
    /// Supported, readable, no known obstacle (the classifier's warnings may still apply).
    case ready
    /// Not a mail format mailin reads.
    case unsupported
    /// Missing, or not readable with this user's permissions.
    case inaccessible
    /// A known format whose structure is broken (truncated header, table
    /// beyond the end of the file, no ZIP directory). The import may still
    /// recover part of it and says so.
    case damaged
    /// Cannot be decoded without a credential mailin does not ask for.
    case encrypted

    /// Whether the import leaves this file out.
    var blocksImport: Bool {
        switch self {
        case .ready, .damaged: return false
        case .unsupported, .inaccessible, .encrypted: return true
        }
    }
}

struct SourcePreflight: Sendable, Equatable {
    let condition: SourceCondition
    /// Why — quoted on the sheet and in the receipt.
    let detail: String
    /// Members of a container that are encrypted and will be skipped while
    /// the rest imports (0 unless the whole container is `.encrypted`).
    var encryptedMembers: Int = 0

    static let ready = SourcePreflight(condition: .ready, detail: "")
}

extension SourceFormatClassifier {

    /// The condition of one source, from its bytes and its permissions.
    static func preflight(url: URL, classification given: SourceClassification? = nil) -> SourcePreflight {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return SourcePreflight(condition: .inaccessible, detail: "not found at \(url.path)")
        }
        guard fm.isReadableFile(atPath: url.path) else {
            return SourcePreflight(condition: .inaccessible, detail: "no permission to read \(url.lastPathComponent)")
        }
        if isDirectory.boolValue, (try? fm.contentsOfDirectory(atPath: url.path)) == nil {
            return SourcePreflight(condition: .inaccessible, detail: "the folder's contents cannot be listed")
        }
        let classification = given ?? classify(url: url)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        if !isDirectory.boolValue, size == 0 {
            return SourcePreflight(condition: .damaged, detail: "the file is empty (0 bytes)")
        }
        guard classification.isSupported else {
            return SourcePreflight(condition: .unsupported, detail: classification.evidence)
        }

        switch classification.format {
        case .pst, .ost:
            return pstPreflight(url: url, size: size)
        case .zip:
            return zipPreflight(url: url)
        case .nsf:
            if size < 256 { return SourcePreflight(condition: .damaged, detail: "shorter than a Notes database header (\(size) bytes)") }
            return .ready
        case .msg:
            if size < 1024 { return SourcePreflight(condition: .damaged, detail: "shorter than an OLE compound file (\(size) bytes)") }
            return .ready
        default:
            return .ready
        }
    }

    /// PST/OST: header long enough, a documented encoding, node tables that
    /// lie inside the file. Compressible (1) and cyclic (2) encodings are
    /// decoded by the reader; anything else is not an encoding we know.
    private static func pstPreflight(url: URL, size: Int64) -> SourcePreflight {
        guard size >= 564 else {
            return SourcePreflight(condition: .damaged, detail: "shorter than a PST header (\(size) bytes)")
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return SourcePreflight(condition: .inaccessible, detail: "cannot open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 1024), header.count >= 564 else {
            return SourcePreflight(condition: .damaged, detail: "the header could not be read")
        }
        func u16(_ o: Int) -> UInt16 { UInt16(header[o]) | UInt16(header[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt64 { UInt64(header[o]) | UInt64(header[o + 1]) << 8 | UInt64(header[o + 2]) << 16 | UInt64(header[o + 3]) << 24 }
        func u64(_ o: Int) -> UInt64 { u32(o) | u32(o + 4) << 32 }
        let unicode = u16(10) >= 23
        let crypt = header[unicode ? 513 : 461]
        if crypt > 2 {
            return SourcePreflight(condition: .encrypted,
                                   detail: "the file declares encoding \(crypt), which is not a documented PST encoding; it cannot be read without the software that wrote it")
        }
        let nbt = unicode ? u64(224) : u32(188)
        let bbt = unicode ? u64(240) : u32(196)
        if nbt == 0 || bbt == 0 || nbt >= UInt64(size) || bbt >= UInt64(size) {
            return SourcePreflight(condition: .damaged,
                                   detail: "the node tables point beyond the end of the file (\(size) bytes) — a truncated or partial copy")
        }
        return .ready
    }

    /// ZIP: a readable central directory; encrypted members counted. A
    /// container whose every file member is encrypted cannot be imported.
    private static func zipPreflight(url: URL) -> SourcePreflight {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: url) } catch {
            return SourcePreflight(condition: .damaged, detail: "the ZIP directory could not be read: \(error.localizedDescription)")
        }
        let files = members.filter { !$0.isDirectory && !$0.isJunk }
        let encrypted = files.filter(\.isEncrypted).count
        if !files.isEmpty, encrypted == files.count {
            return SourcePreflight(condition: .encrypted,
                                   detail: "every one of its \(files.count) files is encrypted; mailin does not ask for passwords",
                                   encryptedMembers: encrypted)
        }
        if encrypted > 0 {
            return SourcePreflight(condition: .ready,
                                   detail: "\(encrypted) of \(files.count) files are encrypted and will be skipped and counted",
                                   encryptedMembers: encrypted)
        }
        return .ready
    }
}
