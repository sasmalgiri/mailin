//
//  ContainerReaderTests.swift
//  ArchiveCoreTests
//
//  Completion directive 2026-11-07 §6 "Containers": 7z and RAR attachments
//  through the same `ContainerTextExtractor` the ZIP path uses — every
//  member a child document with its state and note; compressed RAR members
//  and 7z methods this reader does not open NAMED, never silent; locked /
//  wrong-password surfaced; nested archives opened; a run that stops at a
//  ceiling resumes under `ExtractionLimits.round(1)` without re-reading the
//  members it already read (dedupe by child path). RAR fixtures are built
//  from the format description (no RAR tool exists on this Mac, and none
//  may be bundled); the RAR 2.9 Unicode name decoder is checked on vectors.
//

import XCTest
@testable import ArchiveCore

final class ContainerReaderTests: XCTestCase {

    private var scratch: URL!
    private var savedOverride: ExtractionLimits?

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("container-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedOverride = ExtractionLimits.baseOverride
    }
    override func tearDown() {
        ExtractionLimits.baseOverride = savedOverride
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private static let fixtures = SevenZipReaderTests.fixtures
    private static let publicPack = SevenZipReaderTests.publicPack

    private func children(_ result: OfficeTextExtractor.Result) -> [String: ChildDocument] {
        Dictionary(result.children.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - 7z attachments

    func testSevenZipAttachment_everyMemberIsAChildWithText() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixtures.appendingPathComponent("lzma2.7z"), kind: .sevenZip, logicalName: "lzma2.7z")
        let byPath = children(result)
        XCTAssertEqual(Set(byPath.keys), ["README.txt", "nested/large.txt", "nested/notes.txt"])
        for child in result.children {
            XCTAssertEqual(child.state, .extracted, child.path)
            XCTAssertEqual(child.kind, "txt")
            XCTAssertFalse(child.sha256.isEmpty)
        }
        XCTAssertTrue(byPath["README.txt"]?.text?.contains("MAILIN-SEVENZIP-FIXTURE-2026") == true)
        XCTAssertEqual(byPath["README.txt"]?.sha256, SevenZipReaderTests.inputHashes["README.txt"])
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        XCTAssertTrue(result.text.contains("[Contents]"))
    }

    func testSevenZipAttachment_detectedByNameAndByBytes() throws {
        XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: "a.7z"), .sevenZip)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/x-7z-compressed", filename: "blob"), .sevenZip)
        XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: "a.7z.001"), .sevenZip)
        XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: "a.z01"), .zip)
        XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: "a.rar"), .rar)
        XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: "a.r00"), .rar)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/vnd.rar", filename: "blob"), .rar)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: Self.fixtures.appendingPathComponent("copy.7z")), .sevenZip)
        XCTAssertEqual(DocumentKind.sevenZip.rawValue, "7z")
        XCTAssertTrue(DocumentKind.sevenZip.isContainer && DocumentKind.rar.isContainer)
    }

    func testNestedSevenZipInsideSevenZip_isOpenedWithTheChain() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixtures.appendingPathComponent("nested.7z"), kind: .sevenZip, logicalName: "nested.7z")
        let byPath = children(result)
        XCTAssertEqual(byPath["README.txt"]?.state, .extracted)
        XCTAssertEqual(byPath["inner.7z › README.txt"]?.state, .extracted)
        XCTAssertEqual(byPath["inner.7z › nested/notes.txt"]?.state, .extracted)
        XCTAssertEqual(byPath["inner.7z › nested/large.txt"]?.sha256, SevenZipReaderTests.inputHashes["nested/large.txt"])
    }

    func testUnopenedMethod_isNamedPerMember_attachmentPartialNotFailed() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixtures.appendingPathComponent("bzip2.7z"), kind: .sevenZip, logicalName: "bzip2.7z")
        XCTAssertEqual(result.children.count, 2)
        for child in result.children {
            XCTAssertEqual(child.state, .unsupported, child.path)
            XCTAssertEqual(child.note, "compression method BZip2 not opened")
        }
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertTrue(result.partial)
    }

    func testSevenZip_encryptedHeader_lockedWithoutPassword_openedWithIt() throws {
        let url = Self.publicPack.appendingPathComponent("02_archives/7zip_generated/7zip_AES256_header_encrypted.7z")
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "x.7z")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted)
        }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "x.7z", password: "wrong")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword)
        }
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "x.7z", password: "mailin-fixture-2026")
        let byPath = children(result)
        XCTAssertEqual(byPath["README.txt"]?.state, .extracted)
        XCTAssertTrue(byPath["README.txt"]?.text?.contains("MAILIN-PROTECTED-CONTENT-20261107") == true)
        let docx = try XCTUnwrap(byPath["nested/W05_tracked_retained.docx"])
        XCTAssertEqual(docx.kind, "docx")
        XCTAssertEqual(docx.sha256, "395614e777bdd348376c739104ade830649977bea877e9144e90b86c245e31b7", "the nested Word file is byte-identical to the public sample")
        XCTAssertTrue(docx.state.isSearchable, "\(docx.state) \(docx.note ?? "")")
        XCTAssertTrue(docx.text?.isEmpty == false)
    }

    func testSevenZip_partiallyEncrypted_plainMemberReadLockedMemberSaidSo() throws {
        let url = Self.publicPack.appendingPathComponent("02_archives/public/test_read_format_7zip_encryption_partially.7z")
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "p.7z")
        let byPath = children(result)
        XCTAssertEqual(byPath["bar_unencrypted.txt"]?.state, .extracted)
        XCTAssertEqual(byPath["bar_encrypted.txt"]?.state, .locked)
        XCTAssertEqual(byPath["bar_encrypted.txt"]?.note, "password-protected")
        let wrong = try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "p.7z", password: "nope")
        XCTAssertEqual(children(wrong)["bar_encrypted.txt"]?.state, .locked)
        XCTAssertEqual(children(wrong)["bar_encrypted.txt"]?.note, "the password did not open it")
        let right = try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "p.7z", password: "12345678")
        XCTAssertEqual(children(right)["bar_encrypted.txt"]?.state, .extracted)
    }

    /// A member or attachment of 4–7 bytes is sniffed without trapping (the OLE
    /// check read 8 bytes after a 4-byte guard).
    func testSniff_fourToSevenByteFiles_doNotTrap() {
        for length in 4...7 {
            XCTAssertNil(DocumentTextExtractor.sniff(head: Data("abcdefg".utf8.prefix(length))), "\(length) bytes")
        }
        XCTAssertNil(DocumentTextExtractor.sniff(head: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1])), "an OLE prefix of 5 bytes is not an OLE file")
    }

    // MARK: - Continuation (directive §6: resumable by ExtractionLimits.round)

    func testCeilingStopIsNamed_andRoundOneReadsTheRestWithoutDuplicates() throws {
        // Round 0: 100 KB per part — the 150 KB member is over the guard; the small ones are read.
        // (The stored archive: no dictionary, so the guard bites one member only.)
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 100_000, totalArchiveBytes: 10_000_000, archiveDepth: 3)
        let url = Self.fixtures.appendingPathComponent("copy.7z")
        let first = try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "copy.7z")
        let firstByPath = children(first)
        XCTAssertEqual(firstByPath["README.txt"]?.state, .extracted, firstByPath["README.txt"]?.note ?? "")
        XCTAssertEqual(firstByPath["nested/notes.txt"]?.state, .extracted)
        let stopped = try XCTUnwrap(firstByPath["nested/large.txt"])
        XCTAssertEqual(stopped.state, .unsupported)
        XCTAssertTrue(ExtractionLimits.noteNamesALimit(stopped.note), "\(stopped.note ?? "")")
        XCTAssertTrue(stopped.note?.contains("100000-byte guard") == true)

        // Round 1 doubles the ceilings; the previously stopped member is read.
        let second = try ExtractionLimits.$current.withValue(ExtractionLimits.round(1)) {
            try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "copy.7z")
        }
        let secondByPath = children(second)
        XCTAssertEqual(secondByPath["nested/large.txt"]?.state, .extracted, secondByPath["nested/large.txt"]?.note ?? "no note")
        XCTAssertEqual(secondByPath["nested/large.txt"]?.sha256, SevenZipReaderTests.inputHashes["nested/large.txt"])

        // Dedupe by child path: the union of both rounds is exactly one row per member.
        var merged: [String: ChildDocument] = firstByPath.filter { $0.value.state.isSearchable }
        for (path, child) in secondByPath where merged[path] == nil { merged[path] = child }
        XCTAssertEqual(Set(merged.keys), ["README.txt", "nested/large.txt", "nested/notes.txt"])
        XCTAssertTrue(merged.values.allSatisfy { $0.state == .extracted })
    }

    func testSolidBlockNeedsItsDictionary_everyMemberSaysSo_roundOneOpensThem() throws {
        // A solid LZMA2 block: even the 75-byte README needs the block's 150 KB window,
        // so under a 100 KB guard every member is stopped with the dictionary note (resumable).
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 100_000, totalArchiveBytes: 10_000_000, archiveDepth: 3)
        let url = Self.fixtures.appendingPathComponent("lzma2.7z")
        let first = try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "lzma2.7z")
        XCTAssertEqual(first.children.count, 3)
        for child in first.children {
            XCTAssertEqual(child.state, .unsupported, child.path)
            XCTAssertTrue(child.note?.contains("100000-byte guard") == true, child.note ?? "")
            XCTAssertTrue(ExtractionLimits.noteNamesALimit(child.note))
        }
        // The small members are stopped by the block's dictionary, not by their own size.
        for path in ["README.txt", "nested/notes.txt"] {
            XCTAssertTrue(children(first)[path]?.note?.contains("LZMA dictionary") == true, children(first)[path]?.note ?? "")
        }
        let second = try ExtractionLimits.$current.withValue(ExtractionLimits.round(1)) {
            try DocumentTextExtractor.extract(fileURL: url, kind: .sevenZip, logicalName: "lzma2.7z")
        }
        XCTAssertTrue(second.children.allSatisfy { $0.state == .extracted }, "\(second.children.map { "\($0.path): \($0.note ?? "")" })")
    }

    // MARK: - RAR

    func testRAR5_listingExact_storedRead_compressedEncryptedNamed() throws {
        let stored = Data("Stored text with the marker MAILIN-RAR5-STORED.\n".utf8)
        let url = scratch.appendingPathComponent("spec.rar")
        try RARFixtureWriter.writeRAR5([
            .init(name: "docs/", data: Data(), isDirectory: true),
            .init(name: "docs/plain.txt", data: stored),
            .init(name: "docs/packed.txt", data: Data([1, 2, 3, 4]), method: 3, unpackedSize: 40),
            .init(name: "docs/secret.txt", data: Data(repeating: 0xAA, count: 32), encrypted: true),
            .init(name: "docs/link", data: Data(), symlinkTo: "plain.txt"),
        ], to: url, solid: false)

        let archive = try RARReader.read(url: url)
        XCTAssertEqual(archive.format, .rar5)
        XCTAssertNil(archive.damage)
        XCTAssertEqual(archive.members.map(\.name), ["docs/", "docs/plain.txt", "docs/packed.txt", "docs/secret.txt", "docs/link"])
        let byName = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
        XCTAssertTrue(try XCTUnwrap(byName["docs/"]).isDirectory)
        let plain = try XCTUnwrap(byName["docs/plain.txt"])
        XCTAssertEqual(plain.method, 0); XCTAssertEqual(plain.unpackedSize, Int64(stored.count)); XCTAssertEqual(plain.crc32, ZIPArchiveReader.CRC32.checksum(stored))
        let packed = try XCTUnwrap(byName["docs/packed.txt"])
        XCTAssertEqual(packed.method, 3); XCTAssertEqual(packed.methodName, "RAR5.0 method 3"); XCTAssertEqual(packed.unpackedSize, 40); XCTAssertEqual(packed.packedSize, 4)
        XCTAssertTrue(try XCTUnwrap(byName["docs/secret.txt"]).isEncrypted)
        XCTAssertTrue(try XCTUnwrap(byName["docs/link"]).isSymlink)

        // Through the container reader: stored read, the rest named.
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: "spec.rar")
        let byPath = children(result)
        XCTAssertEqual(byPath["docs/plain.txt"]?.state, .extracted)
        XCTAssertTrue(byPath["docs/plain.txt"]?.text?.contains("MAILIN-RAR5-STORED") == true)
        // GAP-RAR: compressed members now go to the vendored decoder; this
        // fixture's "packed" bytes are 4 arbitrary bytes, so the member is
        // named as damaged with the decoder's reason (real archives:
        // LibArchiveRARTests).
        XCTAssertEqual(byPath["docs/packed.txt"]?.state, .failed)
        XCTAssertTrue(byPath["docs/packed.txt"]?.note?.hasPrefix("docs/packed.txt: the RAR data could not be decoded (") == true, byPath["docs/packed.txt"]?.note ?? "")
        XCTAssertEqual(byPath["docs/secret.txt"]?.state, .locked)
        XCTAssertEqual(byPath["docs/link"]?.state, .unsupported)
        XCTAssertEqual(byPath["docs/link"]?.note, "a symbolic link, not followed")
        XCTAssertNil(byPath["docs/"], "directories are not children")
        XCTAssertTrue(result.partial)
    }

    func testRAR5_encryptedHeaders_locked_andDamagedHeaderNamed() throws {
        let url = scratch.appendingPathComponent("enc.rar")
        try RARFixtureWriter.writeRAR5EncryptedHeaders(to: url)
        XCTAssertThrowsError(try RARReader.read(url: url)) { error in
            XCTAssertEqual(error as? RARReader.ReadError, .encryptedHeaders)
        }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: "enc.rar")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted)
        }
        // A header whose CRC fails ends the walk with the damage named; earlier members stay.
        let good = scratch.appendingPathComponent("good.rar")
        try RARFixtureWriter.writeRAR5([.init(name: "a.txt", data: Data("A".utf8)), .init(name: "b.txt", data: Data("B".utf8))], to: good)
        var bytes = [UInt8](try Data(contentsOf: good))
        let secondHeader = try XCTUnwrap(RARFixtureWriter.rar5HeaderOffsets(in: Data(bytes)).dropFirst(2).first)
        bytes[secondHeader + 8] ^= 0x01
        let damaged = scratch.appendingPathComponent("damaged.rar")
        try Data(bytes).write(to: damaged)
        let archive = try RARReader.read(url: damaged)
        XCTAssertEqual(archive.members.map(\.name), ["a.txt"])
        XCTAssertTrue(archive.damage?.contains("CRC") == true, archive.damage ?? "")
    }

    func testRAR4_listingExact_storedRead_unicodeNames() throws {
        let stored = Data("Old-style RAR, stored. MAILIN-RAR4-STORED\n".utf8)
        let url = scratch.appendingPathComponent("old.rar")
        try RARFixtureWriter.writeRAR4([
            .init(name: "notes.txt", data: stored),
            .init(name: "deep.txt", data: Data([9, 9]), method: 5, unpackedSize: 1_000),
            .init(name: "locked.txt", data: Data(repeating: 1, count: 16), encrypted: true),
        ], to: url)
        let archive = try RARReader.read(url: url)
        XCTAssertEqual(archive.format, .rar4)
        XCTAssertNil(archive.damage)
        XCTAssertEqual(archive.members.map(\.name), ["notes.txt", "deep.txt", "locked.txt"])
        XCTAssertEqual(archive.members[1].methodName, "RAR2.9 method 5")
        XCTAssertTrue(archive.members[2].isEncrypted)
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: "old.rar")
        let byPath = children(result)
        XCTAssertEqual(byPath["notes.txt"]?.state, .extracted)
        XCTAssertEqual(byPath["notes.txt"]?.sha256, SevenZipReaderTests.sha256(stored))
        // GAP-RAR: two arbitrary "packed" bytes reach the decoder and are named as damaged.
        XCTAssertEqual(byPath["deep.txt"]?.state, .failed)
        XCTAssertTrue(byPath["deep.txt"]?.note?.hasPrefix("deep.txt: ") == true, byPath["deep.txt"]?.note ?? "")
        XCTAssertEqual(byPath["locked.txt"]?.state, .locked)

        // RAR 2.9 Unicode names: a run copied from the 8-bit name; a high-byte character.
        XCTAssertEqual(RARReader.decodeRAR4UnicodeName(Array("f.txt".utf8) + [0, 0x00, 0b1100_0000, 3]), "f.txt")
        XCTAssertEqual(RARReader.decodeRAR4UnicodeName(Array("a".utf8) + [0, 0x04, 0b0100_0000, 0x10]), "\u{0410}")
    }

    func testRAR_detectedByBytes_andFuzz200MutationsNeverTrap() throws {
        let url = scratch.appendingPathComponent("seed.rar")
        try RARFixtureWriter.writeRAR5([
            .init(name: "a.txt", data: Data("alpha".utf8)), .init(name: "b/c.txt", data: Data(repeating: 7, count: 300)),
            .init(name: "p.bin", data: Data([1, 2, 3]), method: 2, unpackedSize: 9),
        ], to: url)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: url), .rar)
        let seed4 = scratch.appendingPathComponent("seed4.rar")
        try RARFixtureWriter.writeRAR4([.init(name: "a.txt", data: Data("alpha".utf8)), .init(name: "b.txt", data: Data(repeating: 3, count: 200))], to: seed4)
        var generator = SystemRandomNumberGenerator()
        var outcomes: [String: Int] = [:]
        for round in 0..<200 {
            var bytes = [UInt8](try Data(contentsOf: round % 2 == 0 ? url : seed4))
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if round % 9 == 0 { bytes.removeLast(Int.random(in: 1...min(40, bytes.count - 1), using: &generator)) }
            let mutated = scratch.appendingPathComponent("fuzz-\(round).rar")
            try Data(bytes).write(to: mutated)
            do {
                let archive = try RARReader.read(url: mutated)
                let source = try FileRandomAccessSource(url: mutated)
                for member in archive.members where !member.isDirectory {
                    do { try RARReader.extract(member, source: source, to: scratch.appendingPathComponent("out-\(round)"), maxOutputBytes: 1 << 20); outcomes["read", default: 0] += 1 }
                    catch { outcomes["member error", default: 0] += 1 }
                }
            } catch { outcomes["open error", default: 0] += 1 }
            try? FileManager.default.removeItem(at: mutated)
        }
        XCTAssertGreaterThan(outcomes.values.reduce(0, +), 0, "\(outcomes)")
    }
}

// MARK: - RAR fixtures from the format description

enum RARFixtureWriter {
    struct Entry {
        let name: String
        let data: Data
        var isDirectory = false
        /// 0 = stored. A compressed method is declared with `data` as the (opaque) packed bytes.
        var method = 0
        var unpackedSize: Int64? = nil
        var encrypted = false
        var symlinkTo: String? = nil
        /// RAR 1.5–4.x UNP_VER: 29 = RAR 2.9–4.x; 15 / 20 = the older algorithms.
        var rar4UnpackVersion: UInt8 = 29
        init(name: String, data: Data, isDirectory: Bool = false, method: Int = 0, unpackedSize: Int64? = nil, encrypted: Bool = false, symlinkTo: String? = nil,
             rar4UnpackVersion: UInt8 = 29) {
            self.name = name; self.data = data; self.isDirectory = isDirectory; self.method = method
            self.unpackedSize = unpackedSize; self.encrypted = encrypted; self.symlinkTo = symlinkTo
            self.rar4UnpackVersion = rar4UnpackVersion
        }
    }

    static func vint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = v
        repeat {
            var b = UInt8(v & 0x7F); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    // MARK: RAR 5.0

    /// CRC32 | header size | type | flags | [extra size] | [data size] | body | extra
    static func rar5Header(type: UInt64, flags: UInt64, body: [UInt8], extra: [UInt8] = [], dataSize: Int? = nil) -> [UInt8] {
        var flags = flags
        if !extra.isEmpty { flags |= 0x0001 }
        if dataSize != nil { flags |= 0x0002 }
        var h = vint(type) + vint(flags)
        if !extra.isEmpty { h += vint(UInt64(extra.count)) }
        if let dataSize { h += vint(UInt64(dataSize)) }
        h += body + extra
        let sizeField = vint(UInt64(h.count))
        let crc = ZIPArchiveReader.CRC32.checksum(Data(sizeField + h))
        return le32(crc) + sizeField + h
    }

    static func writeRAR5(_ entries: [Entry], to url: URL, solid: Bool = false) throws {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        out += rar5Header(type: 1, flags: 0, body: vint(solid ? 0x0004 : 0))
        for e in entries {
            var fileFlags: UInt64 = 0
            if e.isDirectory { fileFlags |= 0x0001 }
            if !e.isDirectory { fileFlags |= 0x0004 }   // CRC present
            let unpacked = UInt64(e.unpackedSize ?? Int64(e.data.count))
            var body = vint(fileFlags) + vint(unpacked) + vint(e.isDirectory ? 0x10 : 0x20)
            if !e.isDirectory { body += le32(ZIPArchiveReader.CRC32.checksum(e.data)) }
            let compression: UInt64 = UInt64(e.method & 0x7) << 7 | (solid ? 0x40 : 0)
            body += vint(compression) + vint(1) + vint(UInt64(e.name.utf8.count)) + Array(e.name.utf8)
            var extra: [UInt8] = []
            if e.encrypted {
                // File encryption record: version, flags, KDF count, salt, IV, check value.
                let record = vint(1) + vint(0) + vint(0) + [15] + [UInt8](repeating: 0x11, count: 16) + [UInt8](repeating: 0x22, count: 16)
                extra += vint(UInt64(record.count)) + record
            }
            if let target = e.symlinkTo {
                let record = vint(5) + vint(1) + vint(0) + vint(UInt64(target.utf8.count)) + Array(target.utf8)
                extra += vint(UInt64(record.count)) + record
            }
            out += rar5Header(type: 2, flags: 0, body: body, extra: extra, dataSize: e.isDirectory ? nil : e.data.count)
            if !e.isDirectory { out += [UInt8](e.data) }
        }
        out += rar5Header(type: 5, flags: 0, body: vint(0))
        try Data(out).write(to: url)
    }

    static func writeRAR5EncryptedHeaders(to url: URL) throws {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        // Archive encryption header: version 0, flags 1 (password check), KDF count, salt, check value.
        let body = vint(0) + vint(0x0001) + [15] + [UInt8](repeating: 0x33, count: 16) + [UInt8](repeating: 0x44, count: 12)
        out += rar5Header(type: 4, flags: 0, body: body)
        out += [UInt8](repeating: 0x5A, count: 64)   // encrypted headers follow (opaque here)
        try Data(out).write(to: url)
    }

    /// Offsets of every RAR5 header in a file this writer produced (for targeted damage).
    static func rar5HeaderOffsets(in data: Data) -> [Int] {
        let b = [UInt8](data)
        var offsets: [Int] = []
        var pos = 8
        while pos + 7 <= b.count {
            offsets.append(pos)
            var sizeBytes = 0
            var size: UInt64 = 0
            for i in 0..<3 { let x = b[pos + 4 + i]; size |= UInt64(x & 0x7F) << UInt64(7 * i); sizeBytes += 1; if x & 0x80 == 0 { break } }
            let headerEnd = pos + 4 + sizeBytes + Int(size)
            guard headerEnd <= b.count else { break }
            // Read type/flags/data size to find the next header.
            var r = pos + 4 + sizeBytes
            func v() -> UInt64 { var val: UInt64 = 0; var i = 0; while r < b.count { let x = b[r]; r += 1; val |= UInt64(x & 0x7F) << UInt64(7 * i); i += 1; if x & 0x80 == 0 { break } }; return val }
            let type = v(), flags = v()
            if flags & 1 != 0 { _ = v() }
            var dataSize: UInt64 = 0
            if flags & 2 != 0 { dataSize = v() }
            if type == 5 { break }
            pos = headerEnd + Int(dataSize)
        }
        return offsets
    }

    // MARK: RAR 1.5–4.x

    static func rar4Block(type: UInt8, flags: UInt16, body: [UInt8]) -> [UInt8] {
        let size = UInt16(7 + body.count)
        let rest: [UInt8] = [type] + le16(flags) + le16(size) + body
        let crc = ZIPArchiveReader.CRC32.checksum(Data(rest))
        return le16(UInt16(truncatingIfNeeded: crc)) + rest
    }

    static func writeRAR4(_ entries: [Entry], to url: URL) throws {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        out += rar4Block(type: 0x73, flags: 0, body: le16(0) + le32(0))   // main header: HighPosAV, PosAV
        for e in entries {
            let unpacked = UInt32(truncatingIfNeeded: e.unpackedSize ?? Int64(e.data.count))
            var flags: UInt16 = 0x8000
            if e.encrypted { flags |= 0x0004 }
            if e.isDirectory { flags |= 0x00E0 }
            let name = Array(e.name.utf8)
            let body = le32(UInt32(e.data.count)) + le32(unpacked) + [3] + le32(ZIPArchiveReader.CRC32.checksum(e.data)) + le32(0)
                + [e.rar4UnpackVersion, UInt8(0x30 + e.method)] + le16(UInt16(name.count)) + le32(e.isDirectory ? 0x4000 : 0x81A4) + name
            out += rar4Block(type: 0x74, flags: flags, body: body)
            out += [UInt8](e.data)
        }
        out += rar4Block(type: 0x7B, flags: 0x4000, body: [])
        try Data(out).write(to: url)
    }
}
