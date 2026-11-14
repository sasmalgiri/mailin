//
//  StreamedBodyIndexTests.swift
//  ArchiveCoreTests
//
//  R5 (audit bf1a5b9; owner 2026-11-08: "there should be no limit at all"):
//  a message above the full-parse ceiling — kept by its byte range in the
//  original file — has its text streamed from that range into the chunk
//  index, in bounded memory, and is found by a word in its LAST chunk.
//
//  The full-size row (a 101 MiB message through the production default
//  ceiling of 100 MiB) runs every time; the rest use a 64 KiB ceiling and an
//  in-memory slice source so the MIME walk is exercised slice edge by slice
//  edge.
//

import XCTest
import Foundation
import SQLite3
@preconcurrency @testable import ArchiveCore

final class StreamedBodyIndexTests: XCTestCase {

    private var root: URL!
    private var wasOn = false

    override func setUp() async throws {
        wasOn = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("r5-streamed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        SearchChunkPolicy.isEnabled = wasOn
        try? FileManager.default.removeItem(at: root)
    }

    private struct Env {
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        var archive: ArchiveDataService { ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)) }
    }

    private func makeEnv(_ name: String) -> Env {
        Env(store: SQLiteEmailStore(directory: root.appendingPathComponent("\(name)-store", isDirectory: true)),
            fts: FTSSearchIndex(shardsDirectory: root.appendingPathComponent("\(name)-fts", isDirectory: true)))
    }

    private func importMBOX(_ url: URL, into env: Env, ceiling: Int64?) async throws -> BulkImportCoordinator.RunSummary {
        let coordinator = await BulkImportCoordinator(store: env.store, fts: env.fts,
                                                      checkpoints: ImportCheckpointStore(store: env.store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        options.fullParseCeilingBytes = ceiling
        return try await coordinator.runImport(urls: [url], options: options)
    }

    private func count(_ env: Env, _ field: SearchCondition.Field, _ words: String) async throws -> Int {
        var q = EmailQuery.all
        q.spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(field, .allWords, words)])])
        return try await env.archive.count(query: q)
    }

    /// Writes an mbox with one small message and one large multipart message
    /// whose plain-text body is `lines` lines of base64 text ending in `tail`,
    /// streamed to disk so the fixture is never resident.
    private func writeLargeMBOX(_ url: URL, filler: String, targetBytes: Int64, tail: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("""
        From a@example.com Thu Mar 16 11:00:00 2017
        From: a@example.com
        To: b@example.com
        Subject: Small
        Date: Thu, 16 Mar 2017 11:00:00 +0000
        Message-ID: <small-r5@example.com>

        nothing here

        From big@example.com Fri Mar 17 12:00:00 2017
        From: big@example.com
        To: b@example.com
        Subject: Very large
        Date: Fri, 17 Mar 2017 12:00:00 +0000
        Message-ID: <large-r5@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="R5-OUTER"

        This is the preamble; it is not text of the message.
        --R5-OUTER
        Content-Type: multipart/alternative; boundary="R5-ALT"

        --R5-ALT
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64


        """.utf8))
        // The plain text, base64 in 76-character lines, written a slice at a time.
        let paragraph = Data(String(repeating: filler, count: 9_000).utf8)   // ~ few hundred KB of text per slice
        var written: Int64 = 0
        while written < targetBytes {
            let encoded = paragraph.base64EncodedData(options: [.lineLength76Characters, .endLineWithLineFeed])
            try handle.write(contentsOf: encoded)
            try handle.write(contentsOf: Data("\n".utf8))
            written += Int64(encoded.count + 1)
        }
        let last = Data(" the closing word is \(tail) indeed\n".utf8).base64EncodedData(options: [.lineLength76Characters, .endLineWithLineFeed])
        try handle.write(contentsOf: last)
        try handle.write(contentsOf: Data("""

        --R5-ALT
        Content-Type: text/html; charset=utf-8

        <p>the html alternative says htmlonlyword</p>
        --R5-ALT--
        --R5-OUTER
        Content-Type: application/pdf; name="exhibit-r5.pdf"
        Content-Disposition: attachment; filename="exhibit-r5.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQKJcfsj6IKNSAwIG9iago8PC9MZW5ndGggNiAwIFI+PgpzdHJlYW0K
        --R5-OUTER--


        """.utf8))
    }

    // MARK: - The real size: a 101 MiB message through the production ceiling

    /// A message just above the 100 MiB full-parse ceiling is imported from its
    /// headers (the production default — no override), and its text is then
    /// streamed from the original file: a word in its last chunk is found, the
    /// HTML alternative is not repeated, its attachment's name is searchable,
    /// and the reader never holds more than a few slices.
    func testR5_aMessageAboveTheOldCeilingIsSearchableByItsLastWord_streamedInBoundedMemory() async throws {
        let env = makeEnv("full")
        let mbox = root.appendingPathComponent("large.mbox")
        try writeLargeMBOX(mbox, filler: "streamed filler text about the quarterly ledger. ", targetBytes: 101 * 1_048_576, tail: "zygomorphic")
        let size = (try FileManager.default.attributesOfItem(atPath: mbox.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, OffsetImportEngine().fullParseCeilingBytes, "the fixture is above the old ceiling")

        let summary = try await importMBOX(mbox, into: env, ceiling: nil)
        XCTAssertEqual(summary.bodiesNotDecoded, 1, "the large message is kept by its byte range")
        let page = try await env.archive.page(query: .all, cursor: nil, limit: 10)
        let large = try XCTUnwrap(page.summaries.first { $0.subject == "Very large" }?.id)
        let pending = try await env.store.bodyDocumentState(emailID: large)
        XCTAssertEqual(pending, .partial, "until it is streamed the body may match — never 'no text'")
        let beforeCount = try await count(env, .body, "zygomorphic")
        XCTAssertEqual(beforeCount, 0)

        let stored = try await env.store.locator(forEmailID: large)
        let locator = try XCTUnwrap(stored)
        var source = try LocatorSliceSource(locator: locator, sliceBytes: 1 << 20)
        let result = try await StreamedBodyIndexer().index(emailID: large, source: &source, store: env.store)
        XCTAssertEqual(result.state, .complete)
        XCTAssertGreaterThan(result.chunks, 1_000, "the whole text, chunk by chunk: \(result.chunks)")
        XCTAssertLessThan(result.peakBufferedBytes, 8 * 1_048_576,
                          "bounded by slices, not by the \(size)-byte message: peak \(result.peakBufferedBytes)")
        let chunks = try await env.store.searchChunks(emailID: large, kind: .body, ordinal: 0)
        XCTAssertTrue(chunks.last?.contains("zygomorphic") == true, "the word is in the last chunk")
        XCTAssertFalse(chunks.contains { $0.contains("preamble") }, "the multipart preamble is not text of the message")
        let found = try await count(env, .body, "zygomorphic")
        XCTAssertEqual(found, 1, "found by a word in its last chunk")
        let htmlRepeat = try await count(env, .body, "htmlonlyword")
        XCTAssertEqual(htmlRepeat, 0, "the HTML alternative of a plain part is not indexed twice")
        XCTAssertEqual(result.attachmentNames, ["exhibit-r5.pdf"])
        let nameChunks = try await env.store.searchChunks(emailID: large, kind: .attachmentName, ordinal: 0)
        XCTAssertEqual(nameChunks, ["exhibit-r5.pdf"])
        // "exhibit" is only in the attachment's name (part headers are not body text).
        let name = try await count(env, .anyText, "exhibit")
        XCTAssertEqual(name, 1, "the attachment's name is searchable")
        let after = try await env.store.bodyDocumentState(emailID: large)
        XCTAssertEqual(after, .complete)
    }

    // MARK: - The pass: work list, restart, a missing original

    func testR5_pendingPassStreamsEveryDeferredBody_resumesAfterAnInterruption_andMarksAMissingOriginalFailed() async throws {
        let env = makeEnv("pass")
        let mbox = root.appendingPathComponent("pass.mbox")
        try writeLargeMBOX(mbox, filler: "pass filler words ", targetBytes: 400_000, tail: "quincunx")
        _ = try await importMBOX(mbox, into: env, ceiling: 64 * 1024)
        let list = try await env.store.streamedBodyWorkList(limit: 10)
        XCTAssertEqual(list.count, 1)
        let id = list[0]

        // An interrupted stream leaves the body partial; the next pass starts it again.
        try await env.store.beginStreamedBody(emailID: id)
        try await env.store.appendStreamedBodyChunks(emailID: id, firstIndex: 0, chunks: ["half of it"])
        let stillListed = try await env.store.streamedBodyWorkList(limit: 10)
        XCTAssertEqual(stillListed, [id])

        let pass = await StreamedBodyIndexer().indexPending(store: env.store, sliceBytes: 8_192)
        XCTAssertEqual(pass, StreamedBodyIndexer.PassOutcome(indexed: 1, failed: 0))
        let chunks = try await env.store.searchChunks(emailID: id, kind: .body, ordinal: 0)
        XCTAssertFalse(chunks.contains("half of it"), "the interrupted chunks were replaced, not appended to")
        let found = try await count(env, .body, "quincunx")
        XCTAssertEqual(found, 1)
        let empty = try await env.store.streamedBodyWorkList(limit: 10)
        XCTAssertTrue(empty.isEmpty)

        // A message whose original is gone is recorded failed, not "no text".
        let env2 = makeEnv("gone")
        let mbox2 = root.appendingPathComponent("gone.mbox")
        try writeLargeMBOX(mbox2, filler: "gone filler ", targetBytes: 200_000, tail: "vanished")
        _ = try await importMBOX(mbox2, into: env2, ceiling: 64 * 1024)
        try FileManager.default.removeItem(at: mbox2)
        let gone = await StreamedBodyIndexer().indexPending(store: env2.store)
        XCTAssertEqual(gone, StreamedBodyIndexer.PassOutcome(indexed: 0, failed: 1))
        let deferredIDs = try await env2.store.deferredBodyIDs(limit: 5)
        let goneID = try XCTUnwrap(deferredIDs.first)
        let state = try await env2.store.bodyDocumentState(emailID: goneID)
        XCTAssertEqual(state, .failed)
    }

    // MARK: - The MIME walk, slice edge by slice edge

    /// Supplies fixed bytes in slices of `size`, so every boundary, encoded
    /// group and multi-byte character is split somewhere.
    private struct MemorySource: MessageSliceSource {
        let data: Data
        let size: Int
        var offset = 0
        mutating func next() throws -> Data? {
            guard offset < data.count else { return nil }
            let end = min(data.count, offset + size)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    private func streamedText(_ raw: String, slice: Int, encoding: String.Encoding = .utf8) -> String {
        var reader = StreamingMIMETextReader()
        var source = MemorySource(data: raw.data(using: encoding)!, size: slice)
        var out = ""
        while let piece = try? source.next() { out += reader.feed(piece) }
        out += reader.finish()
        return out
    }

    func testR5_streamingReaderDecodesEncodingsCharsetsAndStructure_atEverySliceSize() throws {
        let utf8Text = "Grüße aus Köln — বাংলা পরীক্ষা — 東京 final"
        let b64 = Data(utf8Text.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let raw = """
        From: x@example.com\r
        Subject: structure\r
        Content-Type: multipart/mixed;\r
         boundary="OUT"\r
        \r
        preamble words\r
        --OUT\r
        Content-Type: multipart/alternative; boundary=ALT\r
        \r
        --ALT\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        soft=\r
        broken line and caf=C3=A9\r
        --ALT\r
        Content-Type: text/html\r
        \r
        <b>html copy</b>\r
        --ALT--\r
        --OUT\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64.replacingOccurrences(of: "\n", with: "\r\n"))\r
        --OUT\r
        Content-Type: message/rfc822\r
        \r
        Subject: inner\r
        Content-Type: text/html; charset=iso-8859-1\r
        \r
        <p>inner &amp; outer</p>\r
        --OUT\r
        Content-Type: image/png; name="scan.png"\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw0KGgo=\r
        --OUT--\r
        epilogue words\r

        """
        let expectedPieces = ["softbroken line and café", utf8Text, "inner & outer"]
        for slice in [1, 3, 7, 64, 4_096] {
            let text = streamedText(raw, slice: slice)
            for piece in expectedPieces { XCTAssertTrue(text.contains(piece), "slice \(slice): \(piece) missing in \(text.debugDescription)") }
            XCTAssertFalse(text.contains("html copy"), "slice \(slice): the HTML alternative repeats the plain part")
            XCTAssertFalse(text.contains("preamble") || text.contains("epilogue"), "slice \(slice)")
            XCTAssertFalse(text.contains("iVBOR"), "slice \(slice): an attachment's bytes are not text")
            XCTAssertFalse(text.contains("\u{FFFD}"), "slice \(slice): no character was broken at a slice edge")
        }
        var reader = StreamingMIMETextReader()
        _ = reader.feed(Data(raw.utf8)); _ = reader.finish()
        XCTAssertEqual(reader.attachmentNames, ["scan.png"])

        // A Latin-1 single part, and a line far longer than one line slice.
        let latin = "Subject: l\nContent-Type: text/plain; charset=iso-8859-1\n\nna\u{EF}ve r\u{E9}sum\u{E9}\n"
        XCTAssertTrue(streamedText(latin, slice: 5, encoding: .isoLatin1).contains("naïve résumé"))
        let longLine = String(repeating: "word ", count: 40_000) + "lastonthelongline"
        let long = streamedText("Subject: long\n\n" + longLine + "\n", slice: 10_000)
        XCTAssertTrue(long.hasSuffix("lastonthelongline\n"))
        XCTAssertEqual(long.count, longLine.count + 1, "nothing of the long line was lost")
    }

    func testR5_streamingChunkerProducesTheSameContiguousTextAsTheWholeTextChunker() {
        let text = (0..<30_000).map { "w\($0)" }.joined(separator: " ")
        var chunker = StreamingChunker(chunk: 4_000)
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 1_337, limitedBy: text.endIndex) ?? text.endIndex
            chunks += chunker.append(String(text[index..<end]))
            index = end
            XCTAssertLessThan(chunker.bufferedBytes, 4_000 + 1_337 + 1, "holds at most one chunk and one piece")
        }
        if let last = chunker.finish() { chunks.append(last) }
        XCTAssertEqual(chunks.joined(), text, "contiguous: nothing repeated, nothing dropped")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 4_000 })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.last == " " }, "no word is cut in two")
    }

    // MARK: - R5b: attachments of a streamed message, by byte range

    /// Deterministic bytes covering every value, so a decode error cannot hide.
    private static func binaryPayload(_ count: Int) -> Data {
        var state: UInt32 = 0x9E37_79B9
        var out = Data(capacity: count)
        for _ in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            out.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        return out
    }

    /// R5b: a message above the ceiling with a 3 MB base64 attachment, a
    /// quoted-printable one and a 7-bit one: the stream registers each part's
    /// byte range in the original file (and the message's attachment list);
    /// each part streams out decoded byte for byte, with memory bounded by the
    /// slice — never by the attachment; a body streamed by version 1 (names
    /// only) is streamed again once so its parts are registered.
    func testR5b_attachmentPartsAreRegisteredByByteRange_andStreamOutDecodedInBoundedMemory() async throws {
        let env = makeEnv("parts")
        let mbox = root.appendingPathComponent("parts.mbox")
        let binary = Self.binaryPayload(3 * 1_048_576 + 17)
        let qpText = "caf\u{E9} line one\nsecond line with = sign and a very long tail " + String(repeating: "x", count: 200)
        let qpEncoded = "caf=E9 line one\r\nsecond line with =3D sign and a very long tail " + String(repeating: "x", count: 60) + "=\r\n" + String(repeating: "x", count: 140)
        let plain = "seven bit attachment text\r\nends here"
        let filler = String(repeating: "body filler words about nothing in particular.\r\n", count: 3_000)
        var text = "From big@example.com Fri Mar 17 12:00:00 2017\r\nFrom: big@example.com\r\nSubject: With parts\r\n"
            + "Message-ID: <r5b-parts@example.com>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"P\"\r\n\r\n"
            + "--P\r\nContent-Type: text/plain\r\n\r\n" + filler
            + "--P\r\nContent-Type: application/octet-stream; name=\"blob.bin\"\r\nContent-Disposition: attachment; filename=\"blob.bin\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n"
        text += binary.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        text += "\r\n--P\r\nContent-Type: text/plain; charset=iso-8859-1; name=\"note.txt\"\r\nContent-Disposition: attachment; filename=\"note.txt\"\r\n"
            + "Content-Transfer-Encoding: quoted-printable\r\n\r\n" + qpEncoded + "\r\n"
            + "--P\r\nContent-Type: text/csv; name=\"plain.csv\"\r\nContent-Disposition: attachment; filename=\"plain.csv\"\r\n\r\n"
            + plain + "\r\n--P--\r\n\r\n"
        try Data(text.utf8).write(to: mbox)
        _ = try await importMBOX(mbox, into: env, ceiling: 64 * 1024)
        let pass = await StreamedBodyIndexer().indexPending(store: env.store, sliceBytes: 8_192)
        XCTAssertEqual(pass, StreamedBodyIndexer.PassOutcome(indexed: 1, failed: 0))
        let ids = try await env.store.deferredBodyIDs(limit: 5)
        let id = try XCTUnwrap(ids.first)

        // Registered: ranges, the attachment list, on the attachment job's work list.
        let located = try await env.store.streamedAttachmentParts(emailID: id)
        let (sourcePath, parts) = try XCTUnwrap(located)
        XCTAssertEqual(parts.map { $0.filename ?? "" }, ["blob.bin", "note.txt", "plain.csv"])
        XCTAssertTrue(parts.allSatisfy(\.isAttachment), "the attachment hydrator addresses them by the same list")
        let listed = try await env.store.attachmentMetadata(forEmailID: id)
        XCTAssertEqual(listed.map(\.filename), ["blob.bin", "note.txt", "plain.csv"])
        XCTAssertEqual(listed.first?.size, binary.count, "the decoded size, counted on the way past")
        let work = try await env.store.streamedAttachmentWorkList(limit: 10)
        XCTAssertEqual(work, [id])
        let candidates = try await env.store.attachmentTextCandidates(limit: 10)
        XCTAssertFalse(candidates.rawless.contains(id) || candidates.candidates.contains { $0.id == id },
                       "never offered to the whole-message path, which would call it 'source not stored'")

        // Each part streams out decoded, byte for byte, in bounded memory.
        let out = root.appendingPathComponent("part.out")
        let blob = try StreamedPartDecoder.decode(part: parts[0], sourcePath: sourcePath, to: out, sliceBytes: 8_192)
        XCTAssertEqual(try Data(contentsOf: out), binary)
        XCTAssertLessThan(blob.peakBufferedBytes, 32 * 1_024, "bounded by the slice, not by the \(binary.count)-byte attachment")
        _ = try StreamedPartDecoder.decode(part: parts[1], sourcePath: sourcePath, to: out, sliceBytes: 4_096)
        XCTAssertEqual(try Data(contentsOf: out), qpText.replacingOccurrences(of: "\n", with: "\r\n").data(using: .isoLatin1))
        _ = try StreamedPartDecoder.decode(part: parts[2], sourcePath: sourcePath, to: out)
        XCTAssertEqual(String(decoding: try Data(contentsOf: out), as: UTF8.self), plain,
                       "the line break before the boundary belongs to the boundary")

        // The same ranges at every slice size (offsets relative to the stream's start).
        let locatorValue = try await env.store.locator(forEmailID: id)
        let base = try XCTUnwrap(locatorValue).headerRange.offset
        let raw = try Data(contentsOf: mbox).subdata(in: Int(base)..<text.utf8.count)
        for slice in [7, 77, 8_192] {
            var reader = StreamingMIMETextReader(baseOffset: base)
            var source = MemorySource(data: raw, size: slice)
            while let piece = try source.next() { _ = reader.feed(piece) }
            _ = reader.finish()
            XCTAssertEqual(reader.attachmentParts.map(\.locator.contentRange), parts.map(\.contentRange), "slice \(slice)")
        }

        // A body streamed by version 1 (names only) goes back on the stream's work list once.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("parts-store/emails.db").path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE search_docs SET extractor_version = 1 WHERE kind = 'body' AND email_id = '\(id.uuidString)';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let again = try await env.store.streamedBodyWorkList(limit: 10)
        XCTAssertEqual(again, [id])
        let notYet = try await env.store.streamedAttachmentWorkList(limit: 10)
        XCTAssertEqual(notYet, [], "its attachments wait for the re-stream")
        let rerun = await StreamedBodyIndexer().indexPending(store: env.store)
        XCTAssertEqual(rerun.indexed, 1)
        let done = try await env.store.streamedBodyWorkList(limit: 10)
        XCTAssertEqual(done, [])
    }
}
