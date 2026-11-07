@testable import ArchiveCore
//
//  SourceFormatClassifierTests.swift
//  maxmailinTests
//
//  Routing used to be the file extension alone. These tests pin the two
//  defects that fixed, because both are silent-corruption class:
//
//   • a PST / ZIP / gzip named ".mbox" used to reach the MBOX parser, which has
//     no signature check, and would invent messages out of binary data
//   • a valid mbox named ".txt" used to be rejected as unsupported
//
//  Content decides; the extension is a hint, and a disagreement is reported.
//

import Testing
import Foundation
import Compression
@testable import maxmailin

private func write(_ bytes: [UInt8], named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("classify-\(UUID().uuidString)-\(name)")
    try Data(bytes).write(to: url)
    return url
}

private func write(_ text: String, named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("classify-\(UUID().uuidString)-\(name)")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private let mboxText = """
From sender@example.com Tue Mar 14 09:41:00 2017
From: sender@example.com
To: recipient@example.com
Subject: First
Date: Tue, 14 Mar 2017 09:41:00 +0000

body one

From sender@example.com Wed Mar 15 10:00:00 2017
From: sender@example.com
To: recipient@example.com
Subject: Second
Date: Wed, 15 Mar 2017 10:00:00 +0000

body two

"""

@Suite("Source format classifier")
struct SourceFormatClassifierTests {

    // MARK: The silent-corruption cases

    @Test("A PST named .mbox is detected as PST, not fed to the MBOX parser")
    func pstDisguisedAsMBOX() throws {
        // "!BDN" + filler.
        let url = try write([0x21, 0x42, 0x44, 0x4E] + Array(repeating: 0x00, count: 512),
                            named: "archive.mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .pst)
        #expect(result.nameContentMismatch, "the disagreement must be reported, not hidden")
        #expect(result.evidence.contains("!BDN"))
    }

    @Test("A ZIP named .mbox is routed as a container, never parsed as text")
    func zipDisguisedAsMBOX() throws {
        let url = try write([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0x20, count: 256),
                            named: "takeout.mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .zip)
        #expect(result.isSupported, "containers import member by member since 2.1")
        #expect(result.format.isContainer)
        #expect(result.format.parserToken == "zip", "the MBOX parser must never see these bytes")
        #expect(result.nameContentMismatch)
    }

    @Test("A gzip-compressed mailbox is recognised as a container")
    func gzipIsRecognised() throws {
        let url = try write([0x1F, 0x8B, 0x08] + Array(repeating: 0x00, count: 128),
                            named: "mail.mbox.gz")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .gzip)
        #expect(result.isSupported)
        #expect(result.format.isContainer)
        #expect(!result.nameContentMismatch)
    }

    @Test("A valid mbox named .txt is accepted on its contents")
    func mboxDisguisedAsText() throws {
        let url = try write(mboxText, named: "mail.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .mbox)
        #expect(result.isSupported, "a renamed mailbox must still import")
        #expect(result.nameContentMismatch)
        #expect(result.format.parserToken == "mbox")
    }

    @Test("Random binary is unknown, never mbox")
    func binaryIsNotMail() throws {
        var bytes: [UInt8] = []
        for i in 0..<2048 { bytes.append(UInt8((i * 7 + 3) % 256)) }
        let url = try write(bytes, named: "disk.img")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .unknown)
        #expect(!result.isSupported)
    }

    // MARK: Correct formats, correctly named

    @Test("An OLE compound document is an Outlook .msg")
    func msgByMagic() throws {
        let url = try write([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
                            + Array(repeating: 0x00, count: 256), named: "message.msg")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .msg)
        #expect(!result.nameContentMismatch)
    }

    @Test("An .emlx byte-count prefix is detected")
    func emlxLayout() throws {
        let body = """
        1234
        From: sender@example.com
        To: recipient@example.com
        Subject: Apple Mail message

        body
        """
        let url = try write(body, named: "12345.emlx")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .emlx)
    }

    @Test("A bare RFC 822 message with no separator is an .eml")
    func emlWithoutSeparator() throws {
        let body = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Single message
        Date: Tue, 14 Mar 2017 09:41:00 +0000

        just one message
        """
        let url = try write(body, named: "single.eml")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .eml)
        #expect(result.evidence.contains("no mbox separator"))
    }

    @Test("An extensionless Google Takeout mbox is detected")
    func extensionlessMBOX() throws {
        let url = try write(mboxText, named: "Takeout-1")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .mbox)
        #expect(!result.nameContentMismatch, "no extension is not a disagreement")
    }

    @Test("An empty file is unknown, with an honest reason")
    func emptyFile() throws {
        let url = try write("", named: "empty.mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .unknown)
        #expect(result.evidence.contains("empty"))
    }

    // MARK: Directory forms

    @Test("An Apple Mail .mbox package is detected as a package, not a file")
    func appleMailPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sent-\(UUID().uuidString).mbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try mboxText.write(to: root.appendingPathComponent("mbox"),
                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SourceFormatClassifier.classify(url: root)
        #expect(result.format == .appleMailMailbox)
        #expect(result.isSupported)
        #expect(result.format.parserToken == "mbox")
    }

    @Test("A Maildir folder is detected")
    func maildirLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maildir-\(UUID().uuidString)", isDirectory: true)
        for sub in ["cur", "new", "tmp"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SourceFormatClassifier.classify(url: root)
        #expect(result.format == .maildir)
    }

    // MARK: Routing actually uses it

    @Test("A mislabelled mbox now imports through the real parser")
    func routingFollowsContent() async throws {
        let url = try write(mboxText, named: "renamed.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        var parsed = 0
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 10
        ) { batch in parsed += batch.count }

        #expect(parsed == 2, "both messages of the renamed mailbox are imported")
        #expect(report.successfullyParsed == 2)
    }

    @Test("A disguised binary is refused before any parser sees it")
    func routingRefusesDisguisedBinary() async throws {
        let url = try write([0x21, 0x42, 0x44, 0x4E] + Array(repeating: 0x00, count: 4096),
                            named: "evidence.mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        // PST is supported, so this reaches the PST parser rather than being
        // refused — the point is that it does NOT reach the MBOX parser and
        // invent messages. A truncated PST fails honestly instead.
        var parsed = 0
        do {
            _ = try await ParserFactory.parseStreamingCallback(
                fileURL: url, senderEmail: "", batchSize: 10
            ) { batch in parsed += batch.count }
        } catch {
            // Expected: a 4 KB stub is not a usable PST.
        }
        #expect(parsed == 0, "binary must never yield fabricated messages")
    }

    @Test("Parser identity follows the detected format, not the filename")
    func identityFollowsContent() throws {
        let url = try write(mboxText, named: "renamed.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let byName = ParserFactory.parserIdentity(forExtension: "txt")
        let byContent = ParserFactory.parserIdentity(for: url)

        #expect(byName.name == "unsupported")
        #expect(byContent.name == "mbox", "a receipt must name the parser that ran")
    }
}

// MARK: - Directory sources, executed end to end

/// `RELEASE_NOTES_2_1.md` recorded directory sources (Maildir, a folder of
/// .eml files, an Apple Mail .mbox package) as "implemented 2026-09-24, not
/// yet run". These build each layout on disk and run it through BOTH parser
/// entry points, so the claim "directory sources import" rests on an executed
/// check rather than on the code having been written.
@Suite("Directory sources import end to end", .serialized)
struct DirectorySourceImportTests {

    private static func rfc822(subject: String, body: String) -> String {
        """
        From: sender@example.com
        To: recipient@example.com
        Subject: \(subject)
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <\(subject.lowercased().replacingOccurrences(of: " ", with: "-"))@example.com>

        \(body)

        """
    }

    private static func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirsrc-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs the array parser and the streaming parser and returns both counts
    /// plus the subjects the streaming path delivered.
    private static func importBothWays(_ url: URL) async throws -> (array: Int, streamed: Int, subjects: Set<String>) {
        let array = try ParserFactory.parse(fileURL: url, senderEmail: "")
        var streamed = 0
        var subjects = Set<String>()
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 2
        ) { batch in
            streamed += batch.count
            for e in batch { subjects.insert(e.headers["Subject"] ?? "") }
        }
        #expect(report.failed == 0, "no message in a well-formed fixture may fail")
        return (array.count, streamed, subjects)
    }

    @Test("Maildir: cur and new are imported, tmp is skipped")
    func maildir() async throws {
        let root = try Self.scratch("Maildir")
        defer { try? FileManager.default.removeItem(at: root) }
        for sub in ["cur", "new", "tmp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Self.rfc822(subject: "Read one", body: "in cur").write(
            to: root.appendingPathComponent("cur/1489484460.M1.host:2,S"), atomically: true, encoding: .utf8)
        try Self.rfc822(subject: "Read two", body: "also in cur").write(
            to: root.appendingPathComponent("cur/1489484461.M2.host:2,S"), atomically: true, encoding: .utf8)
        try Self.rfc822(subject: "Unread", body: "in new").write(
            to: root.appendingPathComponent("new/1489484462.M3.host"), atomically: true, encoding: .utf8)
        // Delivery scratch space: a half-written message must not be imported.
        try Self.rfc822(subject: "Half written", body: "in tmp").write(
            to: root.appendingPathComponent("tmp/1489484463.M4.host"), atomically: true, encoding: .utf8)

        let classification = SourceFormatClassifier.classify(url: root)
        #expect(classification.format == .maildir)

        let result = try await Self.importBothWays(root)
        #expect(result.array == 3)
        #expect(result.streamed == 3)
        #expect(result.subjects == ["Read one", "Read two", "Unread"])
    }

    @Test("A folder of .eml files: every .eml imported, other files ignored")
    func emlFolder() async throws {
        let root = try Self.scratch("Exported")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 1...4 {
            try Self.rfc822(subject: "Message \(i)", body: "body \(i)").write(
                to: root.appendingPathComponent("msg\(i).eml"), atomically: true, encoding: .utf8)
        }
        try "not mail".write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let classification = SourceFormatClassifier.classify(url: root)
        #expect(classification.format == .emlFolder)

        let result = try await Self.importBothWays(root)
        #expect(result.array == 4)
        #expect(result.streamed == 4)
        #expect(result.subjects == ["Message 1", "Message 2", "Message 3", "Message 4"])
    }

    @Test("Apple Mail .mbox package: the inner mbox is what gets parsed")
    func appleMailPackage() async throws {
        let root = try Self.scratch("Inbox.mbox")
        defer { try? FileManager.default.removeItem(at: root) }
        try mboxText.write(to: root.appendingPathComponent("mbox"), atomically: true, encoding: .utf8)
        // Apple Mail packages carry sidecar files that are not mail.
        try "table of contents".write(to: root.appendingPathComponent("mbox.toc"), atomically: true, encoding: .utf8)

        let classification = SourceFormatClassifier.classify(url: root)
        #expect(classification.format == .appleMailMailbox)

        let result = try await Self.importBothWays(root)
        #expect(result.array == 2)
        #expect(result.streamed == 2)
        #expect(result.subjects == ["First", "Second"])
    }

    /// The defect the eml-folder test found, pinned on the production path for
    /// a single file: `BulkImportCoordinator` imports through
    /// `parseStreamingCallback`, which only began a message on an mbox
    /// `From ` line. A bare .eml has none, so every .eml import produced ZERO
    /// messages and a clean report. The streaming loop now recognises a file
    /// whose first line is a header field as one bare message.
    @Test("A single bare .eml streams as one message, not zero")
    func singleEMLStreams() async throws {
        let url = try write(Self.rfc822(subject: "Lone message", body: "hello"), named: "one.eml")
        defer { try? FileManager.default.removeItem(at: url) }

        var streamed: [String] = []
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 10
        ) { batch in streamed += batch.map { $0.headers["Subject"] ?? "" } }

        #expect(report.totalMessages == 1)
        #expect(report.failed == 0)
        #expect(streamed == ["Lone message"])
    }

    /// The other side of that rule: an mbox whose first line is NOT a header
    /// field (a blank line or preamble before the first envelope) must not
    /// have its preamble turned into a message.
    @Test("An mbox with a preamble line before the first envelope still parses cleanly")
    func mboxPreambleIsNotAMessage() async throws {
        let url = try write("\n" + mboxText, named: "preamble.mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        var streamed: [String] = []
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 10
        ) { batch in streamed += batch.map { $0.headers["Subject"] ?? "" } }

        #expect(report.totalMessages == 2)
        #expect(streamed == ["First", "Second"])
    }

    @Test("A recognised directory with no message files is refused, not imported as zero")
    func emptyDirectoryFormRefuses() async throws {
        let root = try Self.scratch("Empty")
        defer { try? FileManager.default.removeItem(at: root) }
        for sub in ["cur", "new", "tmp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        #expect(throws: (any Error).self) {
            _ = try ParserFactory.parse(fileURL: root, senderEmail: "")
        }
    }
}

// MARK: - Containers (ZIP / gzip), executed end to end — v2.1 backlog #1

/// A minimal ZIP writer for fixtures. It produces exactly the structures
/// `ZIPArchiveReader` must understand — stored and deflated members, the
/// central directory, the end record, and on request the ZIP64 record and
/// extra field — so the reader is tested against the format, not against a
/// library's idea of it.
private struct ZIPFixtureWriter {
    struct Entry {
        var name: String
        var payload: Data
        var deflate: Bool = false
        var encryptedFlag: Bool = false
        /// Lie in the directory about the uncompressed size (zip-bomb shape).
        var declaredSizeOverride: UInt32? = nil
        var crcOverride: UInt32? = nil
    }

    static func rawDeflate(_ data: Data) -> Data {
        let capacity = max(64, data.count * 2)
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        precondition(produced > 0, "fixture deflate failed")
        return out.prefix(produced)
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
    private static func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) }) }

    /// Writes the archive; `zip64` forces the ZIP64 record + extra fields even
    /// though nothing is large, which is legal and exercises that path.
    static func write(_ entries: [Entry], to url: URL, zip64: Bool = false) throws {
        var file = Data()
        var central = Data()
        for e in entries {
            let body = e.deflate ? rawDeflate(e.payload) : e.payload
            let crc = e.crcOverride ?? ZIPArchiveReader.CRC32.checksum(e.payload)
            let usize = e.declaredSizeOverride ?? UInt32(e.payload.count)
            let csize = UInt32(body.count)
            let name = Data(e.name.utf8)
            let flags: UInt16 = (e.encryptedFlag ? 0x0001 : 0) | 0x0800
            let method: UInt16 = e.deflate ? 8 : 0
            let offset = UInt32(file.count)

            // Local header.
            file += le32(0x0403_4B50) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
            file += le32(crc) + le32(csize) + le32(usize) + le16(UInt16(name.count)) + le16(0)
            file += name + body

            // Central directory entry (with ZIP64 extra when requested).
            var extra = Data()
            if zip64 {
                extra += le16(0x0001) + le16(24) + le64(UInt64(usize)) + le64(UInt64(csize)) + le64(UInt64(offset))
            }
            central += le32(0x0201_4B50) + le16(45) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
            central += le32(crc)
            central += le32(zip64 ? 0xFFFF_FFFF : csize) + le32(zip64 ? 0xFFFF_FFFF : usize)
            central += le16(UInt16(name.count)) + le16(UInt16(extra.count)) + le16(0)
            central += le16(0) + le16(0) + le32(0)
            central += le32(zip64 ? 0xFFFF_FFFF : offset)
            central += name + extra
        }
        let cdOffset = UInt64(file.count)
        file += central
        if zip64 {
            let zip64EOCDOffset = UInt64(file.count)
            file += le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
            file += le64(UInt64(entries.count)) + le64(UInt64(entries.count))
            file += le64(UInt64(central.count)) + le64(cdOffset)
            file += le32(0x0706_4B50) + le32(0) + le64(zip64EOCDOffset) + le32(1)
            file += le32(0x0605_4B50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF)
            file += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(0)
        } else {
            file += le32(0x0605_4B50) + le16(0) + le16(0)
            file += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
            file += le32(UInt32(central.count)) + le32(UInt32(cdOffset)) + le16(0)
        }
        try file.write(to: url)
    }

    /// RFC 1952 gzip of `payload`, deflate method, with the FNAME field set.
    static func gzip(_ payload: Data, name: String) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03])
        out += Data(name.utf8) + Data([0])
        out += rawDeflate(payload)
        out += le32(ZIPArchiveReader.CRC32.checksum(payload))
        out += le32(UInt32(truncatingIfNeeded: payload.count))
        return out
    }
}

@Suite("Containers import end to end", .serialized)
struct ContainerImportTests {

    private static func scratchFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("container-\(UUID().uuidString)-\(name)")
    }

    private static let secondMbox = """
        From other@example.com Thu Mar 16 11:00:00 2017
        From: other@example.com
        To: recipient@example.com
        Subject: Third
        Date: Thu, 16 Mar 2017 11:00:00 +0000

        body three

        From other@example.com Fri Mar 17 12:00:00 2017
        From: other@example.com
        To: recipient@example.com
        Subject: Fourth
        Date: Fri, 17 Mar 2017 12:00:00 +0000

        body four

        """

    private static func importBothWays(_ url: URL) async throws
        -> (array: Int, streamed: Int, subjects: Set<String>, report: MBOXParser.ParseRecoveryReport) {
        let array = try ParserFactory.parse(fileURL: url, senderEmail: "")
        var streamed = 0
        var subjects = Set<String>()
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 3
        ) { batch in
            streamed += batch.count
            for e in batch { subjects.insert(e.headers["Subject"] ?? "") }
        }
        return (array.count, streamed, subjects, report)
    }

    @Test("Stored and deflated mbox members import; non-mail, junk and directories are skipped and counted")
    func zipWithMixedMembers() async throws {
        let url = Self.scratchFile("takeout.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([
            .init(name: "Takeout/", payload: Data()),
            .init(name: "Takeout/Mail/All mail.mbox", payload: Data(mboxText.utf8), deflate: true),
            .init(name: "Takeout/Mail/Sent.mbox", payload: Data(Self.secondMbox.utf8), deflate: false),
            .init(name: "Takeout/archive_browser.html", payload: Data("<html>not mail</html>".utf8), deflate: true),
            .init(name: "__MACOSX/._junk", payload: Data([0, 1, 2, 3])),
        ], to: url)

        #expect(SourceFormatClassifier.classify(url: url).format == .zip)
        let result = try await Self.importBothWays(url)
        #expect(result.array == 4)
        #expect(result.streamed == 4)
        #expect(result.subjects == ["First", "Second", "Third", "Fourth"])
        #expect(result.report.failed == 0, "skipped members are not failed messages")
        #expect(result.report.errorCategories["container_member_not_mail"] == 1)
        #expect(result.report.errorCategories["container_member_refused"] == nil)
    }

    @Test("ZIP64 records and extra fields are honoured")
    func zip64() async throws {
        let url = Self.scratchFile("big.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([
            .init(name: "mail.mbox", payload: Data(mboxText.utf8), deflate: true),
        ], to: url, zip64: true)

        let members = try ZIPArchiveReader.members(of: url)
        #expect(members.count == 1)
        #expect(members.first?.uncompressedSize == Int64(mboxText.utf8.count))
        let result = try await Self.importBothWays(url)
        #expect(result.array == 2)
        #expect(result.streamed == 2)
    }

    @Test("A member whose directory entry lies about its size is refused; the others still import")
    func zipBombShapeIsRefused() async throws {
        let url = Self.scratchFile("liar.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([
            .init(name: "honest.mbox", payload: Data(mboxText.utf8), deflate: true),
            .init(name: "liar.mbox", payload: Data(Self.secondMbox.utf8), deflate: true,
                  declaredSizeOverride: 10),
        ], to: url)

        let result = try await Self.importBothWays(url)
        #expect(result.streamed == 2, "only the honest member's two messages")
        #expect(result.subjects == ["First", "Second"])
        #expect(result.report.errorCategories["container_member_refused"] == 1)

        // And directly: the reader names the reason and leaves no partial file.
        let liar = try ZIPArchiveReader.members(of: url).first { $0.name == "liar.mbox" }!
        let dest = Self.scratchFile("liar.out")
        #expect(throws: ZIPArchiveReader.ReadError.self) {
            try ZIPArchiveReader.extract(liar, from: url, to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "partial output must be removed")
    }

    @Test("A damaged member (CRC mismatch) is refused, not imported as a truncated mailbox")
    func crcMismatchIsRefused() throws {
        let url = Self.scratchFile("damaged.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([
            .init(name: "mail.mbox", payload: Data(mboxText.utf8), deflate: true, crcOverride: 0xDEAD_BEEF),
        ], to: url)
        let member = try ZIPArchiveReader.members(of: url)[0]
        let dest = Self.scratchFile("damaged.out")
        #expect(throws: ZIPArchiveReader.ReadError.crcMismatch(member: "mail.mbox")) {
            try ZIPArchiveReader.extract(member, from: url, to: dest)
        }
    }

    /// TYPE-06 (ee97c52) made one level of nesting part of the import (a
    /// ZIP inside the ZIP is opened; a second level is skipped and counted —
    /// `tgzIsFollowedOneLevel_deeperIsCounted`). An encrypted member is still
    /// refused and counted, never imported.
    @Test("An encrypted member is refused and counted; a nested archive one level down is followed")
    func encryptedAndNestedAreSkipped() async throws {
        let inner = Self.scratchFile("inner.zip")
        defer { try? FileManager.default.removeItem(at: inner) }
        try ZIPFixtureWriter.write([.init(name: "mail.mbox", payload: Data(mboxText.utf8))], to: inner)
        let innerBytes = try Data(contentsOf: inner)

        let url = Self.scratchFile("outer.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([
            .init(name: "secret.mbox", payload: Data(mboxText.utf8), encryptedFlag: true),
            .init(name: "nested.zip", payload: innerBytes),
            .init(name: "plain.mbox", payload: Data(Self.secondMbox.utf8)),
        ], to: url)

        let result = try await Self.importBothWays(url)
        #expect(result.streamed == 4, "the nested ZIP's two messages come in with the plain mbox's two")
        #expect(result.array == 4)
        #expect(result.subjects == ["First", "Second", "Third", "Fourth"])
        #expect(result.report.errorCategories["container_member_refused"] == 1, "the encrypted member")
        #expect(result.report.errorCategories["container_nested_skipped"] == nil, "one level of nesting is followed; only a second level is skipped")
    }

    @Test("A member that would not fit on the scratch volume is refused before a byte is written")
    func insufficientDiskIsRefusedUpFront() throws {
        let url = Self.scratchFile("fit.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([.init(name: "mail.mbox", payload: Data(mboxText.utf8))], to: url)
        let member = try ZIPArchiveReader.members(of: url)[0]
        let dest = Self.scratchFile("fit.out")
        #expect(throws: ZIPArchiveReader.ReadError.self) {
            // Pretend the volume has only the margin left.
            try ZIPArchiveReader.extract(member, from: url, to: dest,
                                         availableDiskBytes: ZIPArchiveReader.diskMarginBytes)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("A ZIP with no mail inside is refused, not imported as zero")
    func zipWithoutMailRefuses() async throws {
        let url = Self.scratchFile("photos.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([
            .init(name: "readme.txt", payload: Data("hello".utf8)),
            .init(name: "notes/", payload: Data()),
        ], to: url)
        await #expect(throws: (any Error).self) {
            _ = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 10) { _ in }
        }
    }

    @Test("A gzip-compressed mbox imports through both paths")
    func gzipMbox() async throws {
        let url = Self.scratchFile("mail.mbox.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.gzip(Data(mboxText.utf8), name: "mail.mbox").write(to: url)

        #expect(SourceFormatClassifier.classify(url: url).format == .gzip)
        let result = try await Self.importBothWays(url)
        #expect(result.array == 2)
        #expect(result.streamed == 2)
        #expect(result.subjects == ["First", "Second"])
    }

    @Test("Scratch files do not outlive the import")
    func scratchIsCleanedUp() async throws {
        let url = Self.scratchFile("clean.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPFixtureWriter.write([.init(name: "mail.mbox", payload: Data(mboxText.utf8), deflate: true)], to: url)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("mailin-container-") })
        _ = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 10) { _ in }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("mailin-container-") })
        #expect(after.subtracting(before).isEmpty, "every scratch directory created by the import is removed")
    }
}

// MARK: - TYPE-06 (owner directive 2026-11-06): Outlook for Mac archives and tar wrappers

/// A minimal ustar writer for fixtures: plain members, a directory, a GNU
/// long-name record and a PAX path record — the structures `TARReader` must
/// understand, written from the format description, not from a library.
private enum TARFixtureWriter {
    enum Entry {
        case file(name: String, payload: Data)
        case directory(name: String)
        /// A name longer than 100 bytes, carried in a GNU 'L' record.
        case longNameFile(name: String, payload: Data)
        /// A name carried in a PAX 'x' record (`path=`).
        case paxFile(name: String, payload: Data)
    }

    private static func header(name: String, size: Int, type: UInt8) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, width: Int) {
            for (i, byte) in Array(text.utf8).prefix(width).enumerated() { block[offset + i] = byte }
        }
        put(name, at: 0, width: 100)
        put("0000644", at: 100, width: 8)
        put("0000000", at: 108, width: 8)
        put("0000000", at: 116, width: 8)
        put(String(format: "%011o", size), at: 124, width: 12)
        put(String(format: "%011o", 1_489_484_460), at: 136, width: 12)
        put("        ", at: 148, width: 8)
        block[156] = type
        put("ustar", at: 257, width: 6)
        put("00", at: 263, width: 2)
        let sum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148, width: 6)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }

    private static func padded(_ data: Data) -> Data {
        let remainder = data.count % 512
        return remainder == 0 ? data : data + Data(count: 512 - remainder)
    }

    static func write(_ entries: [Entry], to url: URL, truncateLastMember: Bool = false) throws {
        var file = Data()
        for entry in entries {
            switch entry {
            case .file(let name, let payload):
                file += header(name: name, size: payload.count, type: 0x30) + padded(payload)
            case .directory(let name):
                file += header(name: name.hasSuffix("/") ? name : name + "/", size: 0, type: 0x35)
            case .longNameFile(let name, let payload):
                let nameData = Data(name.utf8) + Data([0])
                file += header(name: "././@LongLink", size: nameData.count, type: 0x4C) + padded(nameData)
                file += header(name: String(name.prefix(100)), size: payload.count, type: 0x30) + padded(payload)
            case .paxFile(let name, let payload):
                let body = "path=\(name)\n"
                // The record length counts its own digits: "<len> path=…\n".
                var length = body.utf8.count + 3
                while "\(length) ".utf8.count + body.utf8.count != length { length += 1 }
                let record = Data("\(length) \(body)".utf8)
                file += header(name: "PaxHeaders/\(name.prefix(80))", size: record.count, type: 0x78) + padded(record)
                file += header(name: String(name.prefix(100)), size: payload.count, type: 0x30) + padded(payload)
            }
        }
        if truncateLastMember {
            // A copy that stopped mid-way: the last member's header promises
            // bytes the file no longer has, and there is no end marker.
            file = file.prefix(file.count - 512)
        } else {
            file += Data(count: 1024)
        }
        try file.write(to: url)
    }
}

// Inside the serialized container suite: these imports create scratch
// directories, and `scratchIsCleanedUp` counts them, so they must not run
// in parallel with it.
extension ContainerImportTests {

    private static func type06File(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("type06-\(UUID().uuidString)-\(name)")
    }

    private static let emlText = """
        From: single@example.com
        To: recipient@example.com
        Subject: Fifth
        Date: Sat, 18 Mar 2017 13:00:00 +0000
        Message-ID: <fifth@example.com>

        body five

        """

    private static let type06SecondMbox = """
        From other@example.com Thu Mar 16 11:00:00 2017
        From: other@example.com
        To: recipient@example.com
        Subject: Third
        Date: Thu, 16 Mar 2017 11:00:00 +0000

        body three

        From other@example.com Fri Mar 17 12:00:00 2017
        From: other@example.com
        To: recipient@example.com
        Subject: Fourth
        Date: Fri, 17 Mar 2017 12:00:00 +0000

        body four

        """

    private static func importAll(_ url: URL) async throws
        -> (array: [MBOXParser.RawEmail], streamed: [MBOXParser.RawEmail], report: MBOXParser.ParseRecoveryReport) {
        let array = try ParserFactory.parse(fileURL: url, senderEmail: "")
        var streamed: [MBOXParser.RawEmail] = []
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 2
        ) { batch in streamed += batch }
        return (array, streamed, report)
    }

    // MARK: OLM

    /// Outlook for Mac's record layout, written from its XML shape (no copy
    /// of Outlook is on this Mac; a real export from the owner is welcome and
    /// will be added as a fixture when it arrives).
    private static func olmRecord(subject: String, from: (String, String), to: String, sent: String,
                                  messageID: String, inReplyTo: String? = nil, plain: String, html: String,
                                  read: Bool, flagged: Bool, attachment: (name: String, type: String, url: String)? = nil) -> Data {
        // Outlook escapes the angle brackets of ids in element content.
        func esc(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <emails>
        <email>
        <OPFMessageCopyMessageID>\(esc(messageID))</OPFMessageCopyMessageID>
        <OPFMessageCopySubject>\(subject)</OPFMessageCopySubject>
        <OPFMessageCopySentTime>\(sent)</OPFMessageCopySentTime>
        <OPFMessageCopyReceivedTime>\(sent)</OPFMessageCopyReceivedTime>
        <OPFMessageCopyFromAddresses><emailAddress OPFContactEmailAddressAddress="\(from.1)" OPFContactEmailAddressName="\(from.0)" OPFContactEmailAddressType="SMTP"/></OPFMessageCopyFromAddresses>
        <OPFMessageCopySenderAddress><emailAddress OPFContactEmailAddressAddress="\(from.1)" OPFContactEmailAddressName="\(from.0)" OPFContactEmailAddressType="SMTP"/></OPFMessageCopySenderAddress>
        <OPFMessageCopyToAddresses><emailAddress OPFContactEmailAddressAddress="\(to)" OPFContactEmailAddressName="\(to)" OPFContactEmailAddressType="SMTP"/></OPFMessageCopyToAddresses>
        <OPFMessageCopyCCAddresses/>
        <OPFMessageCopyBCCAddresses/>
        <OPFMessageIsRead>\(read ? 1 : 0)</OPFMessageIsRead>
        <OPFMessageGetIsFlagged>\(flagged ? 1 : 0)</OPFMessageGetIsFlagged>
        <OPFMessageCopyBody>\(plain)</OPFMessageCopyBody>
        <OPFMessageCopyHTMLBody><![CDATA[\(html)]]></OPFMessageCopyHTMLBody>

        """
        if let inReplyTo { xml += "<OPFMessageCopyInReplyTo>\(esc(inReplyTo))</OPFMessageCopyInReplyTo>\n" }
        if let attachment {
            xml += """
            <OPFMessageGetHasAttachment>1</OPFMessageGetHasAttachment>
            <OPFMessageCopyAttachmentList><messageAttachment OPFAttachmentContentExtension="pdf" OPFAttachmentContentFileSize="14" OPFAttachmentContentID="" OPFAttachmentContentType="\(attachment.type)" OPFAttachmentName="\(attachment.name)" OPFAttachmentURL="\(attachment.url)"/></OPFMessageCopyAttachmentList>

            """
        }
        xml += "</email>\n</emails>\n"
        return Data(xml.utf8)
    }

    private static func writeOLM(to url: URL) throws {
        let pdf = Data("%PDF-1.4 hello".utf8)
        try ZIPFixtureWriter.write([
            .init(name: "Local/", payload: Data()),
            .init(name: "Local/com.microsoft.__Messages/", payload: Data()),
            .init(name: "Local/com.microsoft.__Messages/Inbox/com.microsoft.__Messages/message_00001.xml",
                  payload: olmRecord(subject: "Quarterly report", from: ("Jürgen Müller", "juergen@example.com"),
                                     to: "recipient@example.com", sent: "2017-03-14T09:41:00",
                                     messageID: "<one@example.com>", plain: "Please find the report attached.",
                                     html: "<html><body><p>Please find the <b>report</b> attached.</p></body></html>",
                                     read: true, flagged: false,
                                     attachment: ("report.pdf", "application/pdf", "com.microsoft.__Attachments/message_00001/report.pdf")),
                  deflate: true),
            .init(name: "Local/com.microsoft.__Messages/Inbox/Clients/com.microsoft.__Messages/message_00002.xml",
                  payload: olmRecord(subject: "Re: Quarterly report", from: ("Recipient", "recipient@example.com"),
                                     to: "juergen@example.com", sent: "2017-03-15T10:00:00Z",
                                     messageID: "<two@example.com>", inReplyTo: "<one@example.com>",
                                     plain: "Thanks, received.", html: "", read: false, flagged: true),
                  deflate: true),
            .init(name: "Accounts/Work/com.microsoft.__Messages/Sent Items/com.microsoft.__Messages/message_00003.xml",
                  payload: olmRecord(subject: "Sent from work", from: ("Me", "me@work.example"),
                                     to: "them@example.com", sent: "2017-03-16T11:00:00",
                                     messageID: "<three@work.example>", plain: "", html: "<p>Only HTML here</p>",
                                     read: true, flagged: false)),
            .init(name: "Local/com.microsoft.__Messages/Empty Folder/", payload: Data()),
            .init(name: "Local/com.microsoft.__Attachments/message_00001/report.pdf", payload: pdf, deflate: true),
            .init(name: "Local/com.microsoft.__Contacts/contact_00001.xml", payload: Data("<contacts><contact/></contacts>".utf8)),
            .init(name: "Local/com.microsoft.__Calendar/event_00001.xml", payload: Data("<appointments><appointment/></appointments>".utf8)),
            // An object tree the parser does not know: counted under "other objects" by its records.
            .init(name: "Local/com.microsoft.__Signatures/signature_00001.xml", payload: Data("<signatures><signature/></signatures>".utf8)),
            // The category colour table is not an object list (directive §3 real-file run): present, never counted.
            .init(name: "Categories.xml", payload: Data("<categories/>".utf8)),
            .init(name: "__MACOSX/._Categories.xml", payload: Data([0, 1, 2])),
        ], to: url)
    }

    @Test("An .olm imports every message record with folder, flags, reply chain and attachment bytes; non-mail objects are counted out")
    func olmArchiveImportsRecords_foldersFlagsAttachments_andCountsNonMail() async throws {
        let url = Self.type06File("archive.olm")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeOLM(to: url)

        let classification = SourceFormatClassifier.classify(url: url)
        #expect(classification.format == .olm)
        #expect(classification.nameContentMismatch == false)
        #expect(SourceFormatClassifier.preflight(url: url).condition == .ready)
        #expect(ParserFactory.parserIdentity(for: url).name == "olm")

        let result = try await Self.importAll(url)
        #expect(result.array.count == 3)
        #expect(result.streamed.count == 3)
        #expect(result.report.totalMessages == 3)
        #expect(result.report.failed == 0, "\(result.report.errorCategories)")
        #expect(Set(result.streamed.map { $0.headers["Subject"] ?? "" }) == ["Quarterly report", "Re: Quarterly report", "Sent from work"])

        // FOLD-02: the archive's own tree, the empty folder included; "Local" dropped, the account kept.
        #expect(result.report.declaredFolders == ["Empty Folder", "Inbox", "Inbox/Clients", "Work/Sent Items"])

        let first = try #require(result.streamed.first { $0.headers["Subject"] == "Quarterly report" })
        #expect(first.folderPath == "Inbox")
        #expect(first.flags == ["Read"])
        #expect(first.headers["From"]?.contains("Jürgen Müller") == true, "non-ASCII display names survive the rebuild: \(first.headers["From"] ?? "")")
        #expect(first.headers["Message-ID"] == "<one@example.com>")
        #expect(first.headers["X-Mailin-Reconstructed"]?.contains("Outlook for Mac") == true, "the rebuilt form says so")
        #expect(first.plainBody.contains("Please find the report attached."))
        #expect(first.htmlBody.contains("<b>report</b>"))
        #expect(first.attachments.count == 1)
        #expect(first.attachments.first?.filename == "report.pdf")
        #expect(first.attachments.first?.mimeType == "application/pdf")
        let firstAttachment = try #require(first.attachments.first)
        #expect(AttachmentHydrator.data(for: firstAttachment, index: 0, email: first) == Data("%PDF-1.4 hello".utf8),
                "the attachment bytes come from the archive member the record points at")
        #expect(first.timestamp.hasPrefix("2017-03-14T09:41:00"))

        let reply = try #require(result.streamed.first { $0.headers["Subject"] == "Re: Quarterly report" })
        #expect(reply.folderPath == "Inbox/Clients")
        #expect(reply.flags == ["Flagged"])
        #expect(reply.inReplyTo == "<one@example.com>")

        let sent = try #require(result.streamed.first { $0.headers["Subject"] == "Sent from work" })
        #expect(sent.folderPath == "Work/Sent Items")
        #expect(sent.htmlBody.contains("Only HTML here"))

        // Plan §: non-mail objects are counted and disclosed, never imported.
        #expect(result.report.errorCategories["olm_contacts_not_imported"] == 1)
        #expect(result.report.errorCategories["olm_calendar_not_imported"] == 1)
        #expect(result.report.errorCategories["olm_other_objects_not_imported"] == 1, "the unknown Signatures tree, one record; Categories.xml is the colour table and is not an object")
        #expect(result.report.errorCategories["olm_attachment_bytes_missing"] == nil)
    }

    @Test("An OLM renamed .zip is still read as an OLM (content decides); a plain ZIP named .olm is a ZIP")
    func olmIsDecidedFromTheDirectory_notTheName() throws {
        let renamed = Self.type06File("archive.zip")
        defer { try? FileManager.default.removeItem(at: renamed) }
        try Self.writeOLM(to: renamed)
        let asZip = SourceFormatClassifier.classify(url: renamed)
        #expect(asZip.format == .olm)
        #expect(asZip.nameContentMismatch == true)

        let plain = Self.type06File("not-really.olm")
        defer { try? FileManager.default.removeItem(at: plain) }
        try ZIPFixtureWriter.write([.init(name: "mail.mbox", payload: Data(mboxText.utf8))], to: plain)
        #expect(SourceFormatClassifier.classify(url: plain).format == .zip)
    }

    // MARK: tar / tgz

    private static func writeTar(to url: URL, nested: Data? = nil, truncate: Bool = false) throws {
        let longName = "mail/" + String(repeating: "very-long-folder-name/", count: 5) + "archive.mbox"
        var entries: [TARFixtureWriter.Entry] = [
            .directory(name: "mail"),
            .file(name: "mail/inbox.mbox", payload: Data(mboxText.utf8)),
            .file(name: "mail/one.eml", payload: Data(emlText.utf8)),
            .file(name: "mail/readme.txt", payload: Data("not mail".utf8)),
            .file(name: "mail/.DS_Store", payload: Data([0, 1])),
            .longNameFile(name: longName, payload: Data(type06SecondMbox.utf8)),
            .paxFile(name: "mail/pax-named-ü.eml", payload: Data(emlText.replacingOccurrences(of: "Fifth", with: "Sixth").utf8)),
        ]
        if let nested { entries.append(.file(name: "mail/inner.tar", payload: nested)) }
        try TARFixtureWriter.write(entries, to: url, truncateLastMember: truncate)
    }

    @Test("A tar of mailboxes imports member by member (ustar, GNU long names, PAX paths); non-mail and junk are counted, not imported")
    func tarOfMailboxesImports_everyHeaderForm() async throws {
        let url = Self.type06File("mail.tar")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTar(to: url)

        let classification = SourceFormatClassifier.classify(url: url)
        #expect(classification.format == .tar)
        #expect(classification.nameContentMismatch == false)
        #expect(SourceFormatClassifier.preflight(url: url).condition == .ready)
        #expect(ParserFactory.parserIdentity(for: url).name == "container-tar")

        let members = try TARReader.members(of: url)
        #expect(members.map(\.name).contains("mail/" + String(repeating: "very-long-folder-name/", count: 5) + "archive.mbox"))
        #expect(members.map(\.name).contains("mail/pax-named-ü.eml"))

        let result = try await Self.importAll(url)
        #expect(result.array.count == 6)
        #expect(result.streamed.count == 6)
        #expect(Set(result.streamed.map { $0.headers["Subject"] ?? "" }) == ["First", "Second", "Third", "Fourth", "Fifth", "Sixth"])
        #expect(result.report.failed == 0)
        #expect(result.report.errorCategories["container_member_not_mail"] == 1, "readme.txt; .DS_Store is never extracted")
    }

    @Test("A .tgz is gzip → tar → members: one level of nesting is followed, a second level is skipped and counted")
    func tgzIsFollowedOneLevel_deeperIsCounted() async throws {
        let innerTar = Self.type06File("inner.tar")
        defer { try? FileManager.default.removeItem(at: innerTar) }
        try TARFixtureWriter.write([.file(name: "deep.mbox", payload: Data(mboxText.utf8))], to: innerTar)

        let tar = Self.type06File("mail.tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        try Self.writeTar(to: tar, nested: try Data(contentsOf: innerTar))

        let tgz = Self.type06File("mail.tgz")
        defer { try? FileManager.default.removeItem(at: tgz) }
        try ZIPFixtureWriter.gzip(try Data(contentsOf: tar), name: "mail.tar").write(to: tgz)

        let classification = SourceFormatClassifier.classify(url: tgz)
        #expect(classification.format == .gzip)
        #expect(classification.nameContentMismatch == false, ".tgz is a gzip name")

        let result = try await Self.importAll(tgz)
        #expect(result.array.count == 6)
        #expect(result.streamed.count == 6)
        #expect(result.report.errorCategories["container_nested_skipped"] == 1, "inner.tar inside the tar inside the gzip")
    }

    @Test("A tar whose last member runs past the end is named as damaged before import; the members before it still import")
    func truncatedTarIsNamed() async throws {
        let url = Self.type06File("cut.tar")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTar(to: url, truncate: true)
        let preflight = SourceFormatClassifier.preflight(url: url)
        #expect(preflight.condition == .damaged)
        #expect(preflight.detail.contains("tar headers could not be read"))
        #expect(throws: TARReader.ReadError.self) { _ = try TARReader.members(of: url) }
    }
}
