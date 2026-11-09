//
//  ImportContainerTests.swift
//  ArchiveCoreTests
//
//  Completion directive 2026-11-07 §6 "Containers": 7z, RAR and spanned-ZIP
//  IMPORT SOURCES go through the same readers as attachments — classified
//  on their bytes, expanded member by member through ParserFactory's
//  container path, each member classified on its own bytes and imported;
//  members this reader cannot open (RAR-compressed, encrypted, on a missing
//  volume) are refused and counted on the report, never silently dropped
//  and never a failure of the whole import. Preflight tells the person
//  beforehand what will and will not come in.
//

import XCTest
@testable import ArchiveCore

final class ImportContainerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    /// Every message distinct in date, Message-ID and body, so no duplicate rule collapses them.
    static func mbox(_ subjects: [String], body: String = "body") -> Data {
        var text = ""
        for (i, subject) in subjects.enumerated() {
            let day = String(format: "%02d", i % 28 + 1), hour = String(format: "%02d", i % 24)
            let id = subject.lowercased().replacingOccurrences(of: " ", with: "-")
            text += "From sender@example.com Thu Mar \(day) \(hour):00:00 2017\nFrom: sender@example.com\nTo: recipient@example.com\nSubject: \(subject)\nDate: Thu, \(day) Mar 2017 \(hour):00:00 +0000\nMessage-ID: <\(id)@example.com>\n\n\(body) [\(subject)]\n\n"
        }
        return Data(text.utf8)
    }

    private func importBothWays(_ url: URL) async throws -> (array: Int, streamed: Int, subjects: Set<String>, report: MBOXParser.ParseRecoveryReport) {
        let array = try ParserFactory.parse(fileURL: url, senderEmail: "")
        var streamed = 0
        var subjects = Set<String>()
        let report = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 3, materializeAttachments: false) { batch in
            streamed += batch.count
            for e in batch { subjects.insert(e.headers["Subject"] ?? "") }
        }
        return (array.count, streamed, subjects, report)
    }

    // MARK: - Classification on bytes

    func testSourcesAreClassifiedOnTheirBytes() throws {
        let sevenZip = SevenZipReaderTests.fixtures.appendingPathComponent("lzma2.7z")
        let c7 = SourceFormatClassifier.classify(url: sevenZip)
        XCTAssertEqual(c7.format, .sevenZip)
        XCTAssertTrue(c7.evidence.contains("7z signature"))
        XCTAssertFalse(c7.nameContentMismatch)
        XCTAssertTrue(c7.isSupported)

        let renamed = dir.appendingPathComponent("archive.mbox")
        try FileManager.default.copyItem(at: sevenZip, to: renamed)
        let mismatch = SourceFormatClassifier.classify(url: renamed)
        XCTAssertEqual(mismatch.format, .sevenZip, "content decides")
        XCTAssertTrue(mismatch.nameContentMismatch)

        let rar5 = dir.appendingPathComponent("a.rar")
        try RARFixtureWriter.writeRAR5([.init(name: "x.txt", data: Data("x".utf8))], to: rar5)
        XCTAssertEqual(SourceFormatClassifier.classify(url: rar5).format, .rar)
        XCTAssertTrue(SourceFormatClassifier.classify(url: rar5).evidence.contains("RAR 5.0"))
        let rar4 = dir.appendingPathComponent("b.rar")
        try RARFixtureWriter.writeRAR4([.init(name: "x.txt", data: Data("x".utf8))], to: rar4)
        XCTAssertTrue(SourceFormatClassifier.classify(url: rar4).evidence.contains("RAR 1.5–4.x"))

        XCTAssertEqual(ParserFactory.parserIdentity(forExtension: "7z").name, "container-7z")
        XCTAssertEqual(ParserFactory.parserIdentity(forExtension: "rar").name, "container-rar")
        XCTAssertEqual(ParserFactory.parserIdentity(for: sevenZip).name, "container-7z")
        XCTAssertTrue(ParserFactory.allSupportedExtensions.contains("7z") && ParserFactory.allSupportedExtensions.contains("rar"))
    }

    // MARK: - 7z source

    func testSevenZipSource_mailboxesImport_nonMailCounted_everyLevelOfNestingFollowed() async throws {
        let deeper = dir.appendingPathComponent("deeper.7z")
        try SevenZipFixtureWriter.write([.init(name: "lost.mbox", data: Self.mbox(["Lost"]))], to: deeper)
        let inner = dir.appendingPathComponent("inner.7z")
        try SevenZipFixtureWriter.write([
            .init(name: "deep.mbox", data: Self.mbox(["Fifth", "Sixth"])),
            .init(name: "deeper.7z", data: try Data(contentsOf: deeper)),
        ], to: inner)
        let url = dir.appendingPathComponent("mail.7z")
        try SevenZipFixtureWriter.write([
            .init(name: "Mail/", data: nil, isDirectory: true),
            .init(name: "Mail/inbox.mbox", data: Self.mbox(["First", "Second"])),
            .init(name: "Mail/sent.mbox", data: Self.mbox(["Third", "Fourth"])),
            .init(name: "Mail/readme.txt", data: Data("not mail".utf8)),
            .init(name: "inner.7z", data: try Data(contentsOf: inner)),
            .init(name: "__MACOSX/._junk", data: Data([1, 2, 3])),
        ], to: url, solid: false)

        XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .sevenZip)
        XCTAssertEqual(SourceFormatClassifier.preflight(url: url).condition, .ready)
        let result = try await importBothWays(url)
        // CLOSE-02: deeper.7z inside inner.7z (two levels down) is opened too.
        XCTAssertEqual(result.array, 7)
        XCTAssertEqual(result.streamed, 7)
        XCTAssertEqual(result.subjects, ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Lost"])
        XCTAssertEqual(result.report.failed, 0)
        XCTAssertEqual(result.report.errorCategories["container_member_not_mail"], 1)
        XCTAssertNil(result.report.errorCategories["container_nested_skipped"], "no level is skipped")
        XCTAssertNil(result.report.errorCategories["container_member_refused"])
    }

    func testSevenZipSource_realBsdtarArchive_unopenedMethodRefusedAndCounted() async throws {
        // bzip2.7z holds only text (not mail) — proves the refusal path; a Copy 7z with an mbox proves the real-file path.
        let bzip2 = SevenZipReaderTests.fixtures.appendingPathComponent("bzip2.7z")
        let preflight = SourceFormatClassifier.preflight(url: bzip2)
        XCTAssertEqual(preflight.condition, .ready)
        XCTAssertTrue(preflight.detail.contains("BZip2"), preflight.detail)
        do {
            _ = try await ParserFactory.parseStreamingCallback(fileURL: bzip2, senderEmail: "", materializeAttachments: false) { _ in }
            XCTFail("no mailbox inside")
        } catch {
            XCTAssertTrue("\(error)".contains("No mailbox files"), "\(error)")
        }
        let steps = try ParserFactory.containerSteps(bzip2, format: .sevenZip)
        XCTAssertEqual(steps.count, 2)
        let dest = dir.appendingPathComponent("m")
        XCTAssertEqual(try ParserFactory.containerMemberDisposition(steps[0], extractingTo: dest), .refused)
    }

    func testSevenZipSource_encryptedIndexIsEncryptedInPreflight_partialIsReadyWithCount() {
        let header = SevenZipReaderTests.publicPack.appendingPathComponent("02_archives/7zip_generated/7zip_AES256_header_encrypted.7z")
        let p = SourceFormatClassifier.preflight(url: header)
        XCTAssertEqual(p.condition, .encrypted)
        XCTAssertTrue(p.detail.contains("index is encrypted"), p.detail)
        let partial = SourceFormatClassifier.preflight(url: SevenZipReaderTests.publicPack.appendingPathComponent("02_archives/public/test_read_format_7zip_encryption_partially.7z"))
        XCTAssertEqual(partial.condition, .ready)
        XCTAssertEqual(partial.encryptedMembers, 1)
        XCTAssertTrue(partial.detail.contains("1 of 2"), partial.detail)
        let all = SourceFormatClassifier.preflight(url: SevenZipReaderTests.publicPack.appendingPathComponent("02_archives/public/test_read_format_7zip_encryption.7z"))
        XCTAssertEqual(all.condition, .encrypted)
    }

    // MARK: - RAR source

    func testRARSource_storedMailboxImports_compressedAndEncryptedRefusedAndCounted() async throws {
        let url = dir.appendingPathComponent("mail.rar")
        try RARFixtureWriter.writeRAR5([
            .init(name: "a.mbox", data: Self.mbox(["Alpha", "Beta"])),
            .init(name: "b.mbox", data: Data([0xDE, 0xAD]), method: 3, unpackedSize: 500),
            .init(name: "c.mbox", data: Data(repeating: 0x55, count: 32), encrypted: true),
        ], to: url)
        let preflight = SourceFormatClassifier.preflight(url: url)
        XCTAssertEqual(preflight.condition, .ready)
        // GAP-RAR: RAR 5.0 compression is decoded, so the preflight no longer
        // refuses b.mbox; its two arbitrary "packed" bytes fail in the decoder
        // during the import and are refused and counted there.
        XCTAssertFalse(preflight.detail.contains("compress"), preflight.detail)
        XCTAssertEqual(preflight.encryptedMembers, 1)
        let result = try await importBothWays(url)
        XCTAssertEqual(result.streamed, 2)
        XCTAssertEqual(result.array, 2)
        XCTAssertEqual(result.subjects, ["Alpha", "Beta"])
        XCTAssertEqual(result.report.errorCategories["container_member_refused"], 2)
        XCTAssertEqual(result.report.failed, 0)
    }

    func testRARSource_allCompressedIsUnsupported_encryptedHeadersIsEncrypted() throws {
        // GAP-RAR: only compressions the vendored decoder does not open make
        // an archive "nothing to import" — here RAR 1.3 (UNP_VER 13; RAR 1.5/2.0 are decoded since 2026-11-09).
        let compressed = dir.appendingPathComponent("c.rar")
        try RARFixtureWriter.writeRAR4([.init(name: "a.mbox", data: Data([1]), method: 5, unpackedSize: 10, rar4UnpackVersion: 13)], to: compressed)
        let p = SourceFormatClassifier.preflight(url: compressed)
        XCTAssertEqual(p.condition, .unsupported)
        XCTAssertTrue(p.detail.contains("RAR 1.3 compression not opened"), p.detail)
        let locked = dir.appendingPathComponent("l.rar")
        try RARFixtureWriter.writeRAR5EncryptedHeaders(to: locked)
        XCTAssertEqual(SourceFormatClassifier.preflight(url: locked).condition, .encrypted)
        let old = dir.appendingPathComponent("o.rar")
        try RARFixtureWriter.writeRAR4([.init(name: "a.mbox", data: Self.mbox(["Old"]))], to: old)
        XCTAssertEqual(SourceFormatClassifier.preflight(url: old).condition, .ready)
        XCTAssertEqual(try ParserFactory.parse(fileURL: old, senderEmail: "").count, 1)
    }

    // MARK: - Spanned ZIP source (Info-ZIP set in a folder)

    private func makeSpannedZipOfMailboxes() throws -> URL {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zip.path) else { throw XCTSkip("/usr/bin/zip is not available") }
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        try Self.mbox((1...40).map { "Big \($0)" }, body: filler).write(to: dir.appendingPathComponent("big.mbox"))   // ≈ 80 KB: spans the 64 KB volume
        try Self.mbox(["Small one", "Small two"]).write(to: dir.appendingPathComponent("small.mbox"))
        let process = Process()
        process.executableURL = zip
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-0", "-s", "64k", "set.zip", "big.mbox", "small.mbox"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: dir.appendingPathComponent("set.z01").path) else { throw XCTSkip("zip -s failed") }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("big.mbox"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("small.mbox"))
        return dir.appendingPathComponent("set.zip")
    }

    func testSpannedZipSource_importsAcrossVolumes_missingVolumeRefusedAndCounted() async throws {
        let last = try makeSpannedZipOfMailboxes()
        let z01 = dir.appendingPathComponent("set.z01")
        XCTAssertEqual(SourceFormatClassifier.classify(url: z01).format, .zip)
        XCTAssertTrue(SourceFormatClassifier.classify(url: z01).evidence.contains("spanning marker"))
        XCTAssertEqual(SourceFormatClassifier.preflight(url: last).condition, .ready)

        let whole = try await importBothWays(last)
        XCTAssertEqual(whole.streamed, 42)
        XCTAssertEqual(whole.array, 42)
        XCTAssertTrue(whole.subjects.contains("Big 40") && whole.subjects.contains("Small two"))
        XCTAssertNil(whole.report.errorCategories["container_member_refused"])

        // Without the first volume, the member that starts on it is refused and counted; the rest imports.
        try FileManager.default.removeItem(at: z01)
        let partial = try await importBothWays(last)
        XCTAssertEqual(partial.streamed, 2)
        XCTAssertEqual(partial.subjects, ["Small one", "Small two"])
        XCTAssertEqual(partial.report.errorCategories["container_member_refused"], 1)
    }

    // MARK: - Registry and public table (the container rows this work owns)

    func testContainerRegistryRows_carriedVerbatimInThePublicTable() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: repo.appendingPathComponent("SUPPORTED_FORMATS_AND_LIMITS.md"), encoding: .utf8)
        let table = FormatCapabilityRegistry.markdownTable().components(separatedBy: "\n")
        for id in ["zip-source", "7z-rar-source", "zip-attached", "7z", "rar", "bz2-xz"] {
            let row = try XCTUnwrap(FormatCapabilityRegistry.capability(id: id), id)
            let line = try XCTUnwrap(table.first { $0.contains("| \(row.name) | \(row.extensions.joined(separator: ", ")) |") }, "\(id) not in the generated table")
            XCTAssertTrue(doc.contains(line), "SUPPORTED_FORMATS_AND_LIMITS.md does not carry the generated row for \(id):\n\(line)")
        }
        // The readers' real-file evidence is stated as such — RAR's since GAP-RAR
        // (WinRAR-written archives from libarchive's test suite, LibArchiveRARTests).
        XCTAssertEqual(FormatCapabilityRegistry.capability(id: "7z")?.evidence, .realFixtures)
        XCTAssertEqual(FormatCapabilityRegistry.capability(id: "rar")?.evidence, .realFixtures)
        XCTAssertNotNil(FormatCapabilityRegistry.capability(id: "rar")?.externalDependency)
        // Every document kind the dispatch knows has a row.
        for kind in [DocumentKind.sevenZip, .rar, .zip] {
            XCTAssertTrue(FormatCapabilityRegistry.all.contains { $0.family != .mailSource && $0.extensions.contains(kind.rawValue) }, "\(kind)")
        }
    }

    // MARK: - Safety: the ZIP reader under mutation (7z and RAR have theirs)

    func testZIPReader_fuzz200MutationsNeverTrap() throws {
        let seeds = ["02_archives/7zip_generated/7zip_ZipCrypto.zip", "02_archives/public/test_read_format_zip_winzip_aes256_stored.zip"]
            .map { SevenZipReaderTests.publicPack.appendingPathComponent($0) }
        var generator = SystemRandomNumberGenerator()
        var outcomes: [String: Int] = [:]
        for round in 0..<200 {
            var bytes = [UInt8](try Data(contentsOf: seeds[round % seeds.count]))
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                let headerZone = Bool.random(using: &generator)
                let index = headerZone ? Int.random(in: max(0, bytes.count - 300)..<bytes.count, using: &generator) : Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
            if round % 13 == 0 { bytes.removeLast(Int.random(in: 1...min(80, bytes.count - 1), using: &generator)) }
            let url = dir.appendingPathComponent("fuzz-\(round).zip")
            try Data(bytes).write(to: url)
            do {
                let source = try FileRandomAccessSource(url: url)
                for member in try ZIPArchiveReader.members(source: source) where !member.isDirectory {
                    do { try ZIPArchiveReader.extract(member, source: source, to: dir.appendingPathComponent("out-\(round)"), password: "password"); outcomes["read", default: 0] += 1 }
                    catch { outcomes["member error", default: 0] += 1 }
                }
            } catch { outcomes["open error", default: 0] += 1 }
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertGreaterThan(outcomes.values.reduce(0, +), 0, "\(outcomes)")
    }
}
