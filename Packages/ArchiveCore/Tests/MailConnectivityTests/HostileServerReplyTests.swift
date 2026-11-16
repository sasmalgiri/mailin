//
//  HostileServerReplyTests.swift
//  MailConnectivityTests
//
//  Code review 2026-11-16, A13 / A19 / §E: one hostile or broken server reply
//  must never trap the app or grow memory without a stated limit.
//    A13  malformed sequence sets (":", "1:", "1::2" …) parse to nil, never trap
//    A19  a line without LF, a buffered literal and list nesting each have a
//         stated limit (named error); message literals routed to a sink stay
//         unlimited; Gmail's metadata JSON is bounded beside the streamed raw
//    §E   enumeration after UID 4294967295 on a server without UIDNEXT ends
//         (nothing can be newer) instead of overflowing `after + 1`
//

import XCTest
import Foundation
@testable import MailConnectivity
@testable import ArchiveCore

final class HostileServerReplyTests: XCTestCase {

    // MARK: A13 — sequence sets

    func testA13_malformedSequenceSets_areNil_neverTrap() {
        for bad in [":", "1:", ":5", "1::2", "1:2:3", "::", ",", "1,", ",1", "1,,2", "4294967296", "1:4294967296",
                    "*", "1:*", "a", "1:a", " 1", "-1"] {
            XCTAssertNil(IMAPUIDSet(sequenceSet: bad), "\"\(bad)\" is not a sequence set")
        }
        XCTAssertEqual(IMAPUIDSet(sequenceSet: ""), IMAPUIDSet())
        XCTAssertEqual(IMAPUIDSet(sequenceSet: "5:1,7")?.sequenceSet, "1:5,7")
        XCTAssertEqual(IMAPUIDSet(sequenceSet: "4294967295")?.highest, UInt32.max)
        XCTAssertEqual(IMAPUIDSet(sequenceSet: "4294967294:4294967295")?.count, 2)
    }

    /// The same text arriving as a server reply (ESEARCH ALL / VANISHED) is parsed
    /// without trapping; the caller then ignores the malformed set.
    func testA13_malformedSetInsideAReply_parsesAndIsIgnored() throws {
        for line in ["* ESEARCH (TAG \"a1\") UID ALL :\r\n", "* VANISHED (EARLIER) :\r\n", "* ESEARCH (TAG \"a1\") UID ALL 1::2\r\n"] {
            let framer = IMAPResponseFramer()
            let raws = try framer.feed(Data(line.utf8))
            XCTAssertEqual(raws.count, 1)
            guard case .data(_, let values) = try IMAPResponseParser.parse(raws[0]) else { return XCTFail(line) }
            XCTAssertNil(values.last?.atomText.flatMap { IMAPUIDSet(sequenceSet: $0) }, line)
        }
    }

    // MARK: A19 — framer limits

    /// A line that never ends: the framer stops at the stated limit, it does not
    /// keep the stream in memory until the device runs out.
    func testA19_lineWithoutLF_stopsAtTheStatedLimit() throws {
        let framer = IMAPResponseFramer()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 1 << 20)       // 1 MiB, no LF
        var fed = 0
        var thrown: Error?
        do {
            while fed <= (256 << 20) {                                       // far past any limit
                _ = try framer.feed(chunk)
                fed += chunk.count
            }
        } catch { thrown = error }
        guard let error = thrown as? IMAPProtocolError else { return XCTFail("an endless line must stop with a named error") }
        XCTAssertEqual(error, .limitExceeded(.lineLength))
        XCTAssertLessThanOrEqual(fed, IMAPResponseFramer.maximumLineBytes, "stopped at the limit, not later")
        XCTAssertTrue(error.localizedDescription.contains("128 MiB"), error.localizedDescription)
    }

    /// A long but legitimate line (a plain UID SEARCH over 200,000 UIDs) still reads.
    func testA19_longSearchLine_underTheLimit_reads() throws {
        let uids = (1...200_000).map { String($0 * 2) }
        let line = "* SEARCH " + uids.joined(separator: " ") + "\r\n"
        let raws = try IMAPResponseFramer().feed(Data(line.utf8))
        XCTAssertEqual(raws.count, 1)
        guard case .data("SEARCH", let values) = try IMAPResponseParser.parse(raws[0]) else { return XCTFail() }
        XCTAssertEqual(values.count, 200_000)
    }

    /// A literal kept in memory (not a message body) announced past the limit is
    /// refused at its marker; a message body routed to a sink has no limit.
    func testA19_bufferedLiteral_overTheLimit_refusedAtTheMarker_streamedBodyUnlimited() throws {
        let framer = IMAPResponseFramer()
        XCTAssertThrowsError(try framer.feed(Data("* 1 FETCH (X-GM-LABELS {68719476736}\r\n".utf8))) { error in
            XCTAssertEqual(error as? IMAPProtocolError, .limitExceeded(.bufferedLiteral))
        }

        let streaming = IMAPResponseFramer()
        let sink: IMAPLiteralSink = { @Sendable _ in }
        streaming.literalRouter = { preceding, _ in IMAPSession.isBodySection(preceding) ? sink : nil }
        // A 64 GiB message body: announced, accepted, counted as it arrives.
        XCTAssertNoThrow(try streaming.feed(Data("* 1 FETCH (UID 7 BODY[] {68719476736}\r\n".utf8)))
        XCTAssertFalse(streaming.isIdle)
        XCTAssertNoThrow(try streaming.feed(Data(repeating: 0x41, count: 1 << 20)))
    }

    /// One `(` per level: the parser stops at the stated depth instead of
    /// recursing until the stack overflows.
    func testA19_deeplyNestedList_stopsAtTheStatedDepth() throws {
        let depth = 1_000_000
        var line = Data("* 1 FETCH ".utf8)
        line.append(Data(repeating: UInt8(ascii: "("), count: depth))
        line.append(Data(repeating: UInt8(ascii: ")"), count: depth))
        line.append(Data("\r\n".utf8))
        let raws = try IMAPResponseFramer().feed(line)
        XCTAssertEqual(raws.count, 1)
        XCTAssertThrowsError(try IMAPResponseParser.parse(raws[0])) { error in
            XCTAssertEqual(error as? IMAPProtocolError, .limitExceeded(.nestingDepth))
        }
        // The same through the data path (`* LIST …`).
        var list = Data("* LIST ".utf8)
        list.append(Data(repeating: UInt8(ascii: "("), count: depth))
        list.append(Data("\r\n".utf8))
        let listRaws = try IMAPResponseFramer().feed(list)
        XCTAssertThrowsError(try IMAPResponseParser.parse(listRaws[0]))

        // Nesting within the limit still parses.
        let ok = "* 1 FETCH " + String(repeating: "(", count: IMAPTokenCursor.maximumNestingDepth - 1) + "UID 5"
            + String(repeating: ")", count: IMAPTokenCursor.maximumNestingDepth - 1) + "\r\n"
        let okRaws = try IMAPResponseFramer().feed(Data(ok.utf8))
        XCTAssertNoThrow(try IMAPResponseParser.parse(okRaws[0]))
    }

    // MARK: A19 — Gmail metadata beside the streamed raw value

    func testA19_gmailMetadata_isBounded_rawStillUnlimited() throws {
        // 2 MiB in a non-raw member: refused with the stated limit.
        var decoder = GmailRawStreamDecoder()
        var json = Data(#"{"id":"x","raw":"QUJD","snippet":""#.utf8)
        json.append(Data(repeating: UInt8(ascii: "a"), count: 2 << 20))
        json.append(Data(#""}"#.utf8))
        var thrown: Error?
        var offset = 0
        do {
            while offset < json.count {
                let end = min(json.count, offset + 65_536)
                try decoder.feed(json.subdata(in: offset..<end)) { _ in }
                offset = end
            }
            try decoder.finish { _ in }
        } catch { thrown = error }
        guard case .malformed(let why)? = thrown as? GmailRawDecodeError else { return XCTFail("metadata must be bounded") }
        XCTAssertTrue(why.contains("1 MiB"), why)
        XCTAssertLessThanOrEqual(decoder.metadataJSON.count, GmailRawStreamDecoder.maximumMetadataBytes)

        // A 3 MiB raw value next to small metadata: every byte arrives.
        let message = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let b64 = message.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let big = Data(#"{"id":"y","labelIds":["INBOX"],"raw":""#.utf8) + Data(b64.utf8) + Data(#""}"#.utf8)
        var d2 = GmailRawStreamDecoder()
        var out = Data()
        offset = 0
        while offset < big.count {
            let end = min(big.count, offset + 65_536)
            try d2.feed(big.subdata(in: offset..<end)) { out.append($0) }
            offset = end
        }
        try d2.finish { out.append($0) }
        XCTAssertEqual(out, message)
        XCTAssertLessThan(d2.metadataJSON.count, 200)
    }

    // MARK: §E — UID 4294967295 without UIDNEXT

    /// A real loopback transport whose server never says UIDNEXT (RFC 3501
    /// servers may omit it): every `* OK [UIDNEXT …]` line is dropped.
    final class NoUIDNextTransport: IMAPByteTransport, @unchecked Sendable {
        private let inner: any IMAPByteTransport
        private let lock = NSLock()
        private var pending = Data()
        init(_ inner: any IMAPByteTransport) { self.inner = inner }
        func receive() async throws -> Data? { try await receive(timeout: nil) }
        func receive(timeout: TimeInterval?) async throws -> Data? {
            while true {
                guard let chunk = try await inner.receive(timeout: timeout) else { return nil }
                let out: Data = lock.withLock {
                    pending.append(chunk)
                    var keep = Data()
                    while let lf = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex...lf]
                        if !String(decoding: line, as: UTF8.self).contains("[UIDNEXT ") { keep.append(line) }
                        pending = Data(pending[(lf + 1)...])
                    }
                    return keep
                }
                if !out.isEmpty { return out }
            }
        }
        func send(_ data: Data) async throws { try await inner.send(data) }
        func upgradeToTLS() async throws { try await inner.upgradeToTLS() }
        var isEncrypted: Bool { inner.isEncrypted }
        func close() { inner.close() }
    }

    func testE_enumerateAfterTheHighestUID_withoutUIDNEXT_endsWithoutOverflow() async throws {
        let model = IMAPServerModel()
        model.addMailbox("INBOX")
        model.add(IMAPAdapterTests.message("e-1"), to: "INBOX")
        let server = try LocalIMAPServer(model: model)
        try await server.start()
        defer { server.stop() }

        let account = UUID()
        let credentials = InMemoryCredentialStore()
        try credentials.write(Data(model.password.utf8), kind: .password, account: account)
        let config = IMAPAccountConfiguration(host: "127.0.0.1", port: server.port, security: .plaintextLoopbackOnly,
                                              login: model.login, maxConnections: 1, pageSize: 10, timeout: 10)
        let adapter = IMAPAdapter(accountID: account, configuration: config, credentials: credentials,
                                  transportFactory: { endpoint in NoUIDNextTransport(try await IMAPTransports.system(endpoint)) })
        let ctx = ProviderRequestContext(accountID: account, accessToken: nil, attempt: 0)
        let folders = try await adapter.listFolders(pageToken: nil, context: ctx)
        let inbox = try XCTUnwrap(folders.folders.first)
        let validity = try XCTUnwrap(model.mailboxes.first?.uidValidity)

        // A cursor whose last listed UID was the highest a UID can be.
        let cursor = "imap1;v=\(validity);after=\(UInt32.max);w=10"
        let page = try await adapter.enumerate(folder: inbox, cursor: cursor, pageSize: 10, context: ctx)
        XCTAssertEqual(page.items.count, 0, "nothing can be newer than UID 4294967295")
        XCTAssertNil(page.nextCursor, "the folder's enumeration is complete")

        // From the start, the same server still lists its message.
        let first = try await adapter.enumerate(folder: inbox, cursor: nil, pageSize: 10, context: ctx)
        XCTAssertEqual(first.items.count, 1)
        await adapter.disconnect()
    }
}
