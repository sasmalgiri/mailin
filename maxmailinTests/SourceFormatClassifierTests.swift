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

    @Test("A ZIP named .mbox is refused with advice, not parsed as text")
    func zipDisguisedAsMBOX() throws {
        let url = try write([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0x20, count: 256),
                            named: "takeout.mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .zip)
        #expect(!result.isSupported)
        #expect(result.format.advice?.contains("Unzip") == true)
    }

    @Test("A gzip-compressed mailbox is recognised and explained")
    func gzipIsRecognised() throws {
        let url = try write([0x1F, 0x8B, 0x08] + Array(repeating: 0x00, count: 128),
                            named: "mail.mbox.gz")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .gzip)
        #expect(!result.isSupported)
        #expect(result.format.advice?.contains("Decompress") == true)
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
