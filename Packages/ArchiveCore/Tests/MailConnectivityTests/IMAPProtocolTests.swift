//
//  IMAPProtocolTests.swift
//  MailConnectivityTests
//
//  V4-07: the IMAP response reader and session over pure byte streams.
//    T13  8-bit / binary literals, UTF-8 split across packets, bodies that
//         contain "M5 OK", "* BYE", "\r\n.\r\n" and literal markers → the
//         bytes and SHA-256 equal the oracle; the parser never mistakes
//         message content for protocol completion (every split point).
//    Security: STARTTLS on the same connection, pre-TLS capabilities
//    discarded, STARTTLS absent → no AUTH, unencrypted channel → no AUTH,
//    STARTTLS response injection refused, tokens masked in the log.
//

import XCTest
import Foundation
import CryptoKit
import Network
@testable import MailConnectivity
@testable import ArchiveCore

final class IMAPProtocolTests: XCTestCase {

    // MARK: Fixtures

    /// A message no line-based parser survives: 8-bit and NUL bytes, invalid
    /// UTF-8, a UTF-8 sequence, apparent completions, an SMTP terminator and
    /// an apparent literal marker at a line end.
    static let hostileBody: Data = {
        var d = Data("From: Asha <asha@example.com>\r\nSubject: =?UTF-8?B?w7w=?= test\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        d.append(Data("M5 OK FETCH completed\r\n* BYE server shutting down\r\n* 9 FETCH (UID 99 BODY[] {3}\r\nabc)\r\n".utf8))
        d.append(Data("\r\n.\r\n".utf8))
        d.append(Data("日本語 Entwürfe ✉️\r\n".utf8))
        d.append(contentsOf: (0...255).map { UInt8($0) })                      // every byte value incl. NUL, CR, LF
        d.append(contentsOf: [0xC3, 0x28, 0xFF, 0xFE, 0x0D, 0x0D, 0x0A, 0x0A])   // invalid UTF-8, bare CR/LF
        d.append(Data("\r\nM5 OK\r\n{12}\r\n".utf8))
        return d
    }()

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func fetchResponse(_ body: Data, tag: String = "M5", uidFirst: Bool = true) -> Data {
        var d = Data("* 7 FETCH (".utf8)
        if uidFirst { d.append(Data("UID 42 ".utf8)) }
        d.append(Data("RFC822.SIZE \(body.count) FLAGS (\\Answered) BODY[] {\(body.count)}\r\n".utf8))
        d.append(body)
        if !uidFirst { d.append(Data(" UID 42".utf8)) }
        d.append(Data(")\r\n\(tag) OK UID FETCH completed\r\n".utf8))
        return d
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var chunks = 0
        func write(_ d: Data) { lock.withLock { data.append(d); chunks += 1 } }
        var bytes: Data { lock.withLock { data } }
    }

    func frame(_ stream: Data, splits: [Int], routeBody: Collector?) throws -> [IMAPResponse] {
        let framer = IMAPResponseFramer()
        if let routeBody {
            let sink: IMAPLiteralSink = { @Sendable d in routeBody.write(d) }
            framer.literalRouter = { preceding, _ in IMAPSession.isBodySection(preceding) ? sink : nil }
        }
        var out: [IMAPResponse] = []
        var start = 0
        for end in splits + [stream.count] where end > start {
            for raw in try framer.feed(stream.subdata(in: start..<end)) { out.append(try IMAPResponseParser.parse(raw)) }
            start = end
        }
        XCTAssertTrue(framer.isIdle, "no partial response left")
        return out
    }

    // MARK: T13 — literals by byte count

    func testT13_bodyLiteral_everyTwoWaySplit_bytesEqualOracle_contentNeverEndsTheResponse() throws {
        let body = Self.hostileBody
        let stream = Self.fetchResponse(body)
        for split in 1..<stream.count {
            let c = Collector()
            let responses = try frame(stream, splits: [split], routeBody: c)
            XCTAssertEqual(responses.count, 2, "split at \(split): exactly the FETCH and its completion")
            XCTAssertEqual(Self.sha(c.bytes), Self.sha(body), "split at \(split)")
            guard case .fetch(let seq, let items)? = responses.first else { return XCTFail("split \(split): no FETCH") }
            XCTAssertEqual(seq, 7)
            XCTAssertEqual(items.first { $0.name == "UID" }?.value.number, 42)
            XCTAssertEqual(items.first { $0.name == "BODY[]" }?.value, .streamed(Int64(body.count)))
            guard case .tagged(let tag, let status)? = responses.last else { return XCTFail("split \(split): no completion") }
            XCTAssertEqual(tag, "M5"); XCTAssertEqual(status.status, .ok)
        }
    }

    func testT13_onePacketPerByte_andUIDAfterBody_bytesEqualOracle() throws {
        let body = Self.hostileBody
        let stream = Self.fetchResponse(body, uidFirst: false)
        let c = Collector()
        let responses = try frame(stream, splits: Array(1..<stream.count), routeBody: c)
        XCTAssertEqual(c.bytes, body)
        XCTAssertEqual(responses.count, 2)
        guard case .fetch(_, let items)? = responses.first else { return XCTFail() }
        XCTAssertEqual(items.first { $0.name == "UID" }?.value.number, 42, "attribute order is the server's")
    }

    func testT13_unroutedLiteralIsBufferedExactly_andLiteralPlusAndLiteral8Markers() throws {
        let body = Self.hostileBody
        var stream = Data("* 3 FETCH (UID 8 BODY[] {\(body.count)+}\r\n".utf8) + body + Data(")\r\n".utf8)
        stream += Data("* 4 FETCH (UID 9 BINARY[] ~{5}\r\n".utf8) + Data([0, 1, 2, 0x0D, 0x0A]) + Data(")\r\nM1 OK\r\n".utf8)
        let responses = try frame(stream, splits: [17, 200, 201], routeBody: nil)
        XCTAssertEqual(responses.count, 3)
        guard case .fetch(_, let a)? = responses.first, case .fetch(_, let b) = responses[1] else { return XCTFail() }
        XCTAssertEqual(a.first { $0.name == "BODY[]" }?.value, .string([UInt8](body)))
        XCTAssertEqual(b.first { $0.name == "BINARY[]" }?.value, .string([0, 1, 2, 0x0D, 0x0A]))
    }

    func testT13_utf8SplitInsideAQuotedMailboxName_andLiteralName() throws {
        let name = "Archiv/Entwürfe/日本語"
        var stream = Data("* LIST (\\HasNoChildren \\Drafts) \"/\" \"\(name)\"\r\n".utf8)
        let literalName = Data("Projekt \"Ä\" (neu)".utf8)
        stream += Data("* LIST (\\HasChildren) \"/\" {\(literalName.count)}\r\n".utf8) + literalName + Data("\r\n".utf8)
        // Split inside the 3-byte sequence of 日 and inside ü.
        let ue = stream.range(of: Data("ü".utf8))!.lowerBound + 1
        let ni = stream.range(of: Data("日".utf8))!.lowerBound + 2
        let responses = try frame(stream, splits: [ue, ni], routeBody: nil)
        guard case .data("LIST", let v1)? = responses.first, case .data("LIST", let v2) = responses[1] else { return XCTFail() }
        XCTAssertEqual(IMAPMailboxName(wire: v1[2].bytes!, utf8: true).name, name)
        XCTAssertEqual(v1[0].list?.compactMap(\.atomText), ["\\HasNoChildren", "\\Drafts"])
        XCTAssertEqual(v2[2].bytes.map { Data($0) }, literalName)
    }

    func testQuotedEscapesNILAndNestedLists() throws {
        let stream = Data(##"* NAMESPACE (("" "/")) (("~" "/")) (("#shared/" "/" "X-PARAM" ("a\"b" "c\\d")))"##.utf8) + Data("\r\n".utf8)
            + Data("* 1 FETCH (UID 5 FLAGS () MODSEQ (12345) INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" X NIL)\r\n".utf8)
            + Data("* ESEARCH (TAG \"M3\") UID ALL 1:3,7,9:12\r\n".utf8)
        let r = try frame(stream, splits: [], routeBody: nil)
        guard case .data("NAMESPACE", let ns) = r[0] else { return XCTFail() }
        let shared = ns[2].list?.first?.list
        XCTAssertEqual(shared?[3].list?.compactMap(\.text), ["a\"b", "c\\d"])
        guard case .fetch(_, let items) = r[1] else { return XCTFail() }
        XCTAssertEqual(items.first { $0.name == "X" }?.value, .nilValue)
        XCTAssertEqual(items.first { $0.name == "MODSEQ" }?.value.list?.first?.number, 12345)
        XCTAssertNotNil(IMAPSession.parseInternalDate(items.first { $0.name == "INTERNALDATE" }!.value.text!))
        guard case .data("ESEARCH", let es) = r[2] else { return XCTFail() }
        XCTAssertEqual(es.last?.atomText, "1:3,7,9:12")
    }

    func testStatusResponsesAndCodes() throws {
        let stream = Data("""
        * OK [UIDVALIDITY 3857529045] UIDs valid\r
        * OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r
        M1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r
        * BYE [UNAVAILABLE] Server going down\r
        + \r
        +Ready\r
        * 23 EXISTS\r

        """.utf8)
        let r = try frame(stream, splits: [5, 40], routeBody: nil)
        XCTAssertEqual(r.count, 7)
        guard case .untaggedStatus(let s0) = r[0], case .untaggedStatus(let s1) = r[1], case .tagged("M1", let s2) = r[2],
              case .untaggedStatus(let s3) = r[3] else { return XCTFail("\(r)") }
        XCTAssertEqual(s0.code?.name, "UIDVALIDITY"); XCTAssertEqual(s0.code?.number, 3_857_529_045); XCTAssertEqual(s0.text, "UIDs valid")
        XCTAssertEqual(s1.code?.name, "PERMANENTFLAGS"); XCTAssertEqual(s1.text, "Limited")
        XCTAssertEqual(s2.status, .no); XCTAssertEqual(s2.code?.name, "AUTHENTICATIONFAILED")
        XCTAssertEqual(s3.status, .bye); XCTAssertEqual(s3.code?.name, "UNAVAILABLE")
        XCTAssertEqual(r[4], .continuation("")); XCTAssertEqual(r[5], .continuation("Ready"))
        XCTAssertEqual(r[6], .numbered(23, "EXISTS"))
    }

    func testErrorMapping() {
        func map(_ status: IMAPStatus, _ code: String?, _ ctx: IMAPCommandContext, oauth: Bool = false) -> MailProviderError {
            IMAPSession.mapped(IMAPStatusResponse(status: status, code: code.map { IMAPResponseCode(name: $0, argument: "") }, text: "x"),
                               context: ctx, oauth: oauth)
        }
        XCTAssertEqual(map(.no, "AUTHENTICATIONFAILED", .authenticate), .reauthorisationRequired)
        XCTAssertEqual(map(.no, "AUTHENTICATIONFAILED", .authenticate, oauth: true), .unauthorized)
        XCTAssertEqual(map(.no, "OVERQUOTA", .fetch), .quotaExceeded(resetAfter: nil))
        XCTAssertEqual(map(.no, "LIMIT", .other), .rateLimited(retryAfter: nil))
        if case .transient = map(.no, "UNAVAILABLE", .examine) {} else { XCTFail("UNAVAILABLE is transient") }
        XCTAssertEqual(map(.no, "NONEXISTENT", .examine), .folderUnavailable("x"))
        XCTAssertEqual(map(.no, "NONEXISTENT", .fetch), .itemUnavailable)
        XCTAssertEqual(map(.no, "EXPUNGEISSUED", .fetch), .itemUnavailable)
        if case .permanent = map(.bad, nil, .other) {} else { XCTFail("BAD is permanent") }
        if case .transient = map(.no, nil, .fetch) {} else { XCTFail("a plain NO to FETCH is transient") }
    }

    func testBodySectionDetection() {
        XCTAssertTrue(IMAPSession.isBodySection(Array("* 1 FETCH (UID 4 BODY[] ".utf8)))
        XCTAssertTrue(IMAPSession.isBodySection(Array("* 1 FETCH (UID 4 BODY[]<0> ".utf8)))
        XCTAssertTrue(IMAPSession.isBodySection(Array("* 1 FETCH (BINARY[] ".utf8)))
        XCTAssertFalse(IMAPSession.isBodySection(Array("* LIST () \"/\" ".utf8)))
        XCTAssertFalse(IMAPSession.isBodySection(Array("* 1 FETCH (BODY[HEADER] ".utf8)))
    }

    // MARK: Mailbox names and UID sets

    func testModifiedUTF7_RFCVectors_roundTrip_andInvalidInput() {
        XCTAssertEqual(IMAPModifiedUTF7.encode("Entwürfe"), "Entw&APw-rfe")
        XCTAssertEqual(IMAPModifiedUTF7.encode("~peter/mail/日本語/台北"), "~peter/mail/&ZeVnLIqe-/&U,BTFw-")
        XCTAssertEqual(IMAPModifiedUTF7.encode("A&B"), "A&-B")
        XCTAssertEqual(IMAPModifiedUTF7.decode(Array("~peter/mail/&ZeVnLIqe-/&U,BTFw-".utf8)), "~peter/mail/日本語/台北")
        for name in ["📧 Posteingang", "Gesendete Objekte", "Корзина", "受信トレイ/2024", "a&b&-c", "Élément envoyé"] {
            XCTAssertEqual(IMAPModifiedUTF7.decode(Array(IMAPModifiedUTF7.encode(name).utf8)), name)
        }
        XCTAssertNil(IMAPModifiedUTF7.decode(Array("&Jjo".utf8)), "no closing '-'")
        XCTAssertNil(IMAPModifiedUTF7.decode(Array("&2D3-".utf8)), "an unpaired surrogate")
        XCTAssertEqual(IMAPMailboxName(wire: Array("inbox".utf8), utf8: false).name, "INBOX")
        XCTAssertEqual(IMAPMailboxName.wireBytes(for: "Entwürfe", utf8: true), Array("Entwürfe".utf8))
    }

    func testUIDSet() {
        var s = IMAPUIDSet(sequenceSet: "9:12,1:3,7")!
        XCTAssertEqual(s.sequenceSet, "1:3,7,9:12")
        XCTAssertEqual(s.count, 8)
        s.insert(8)
        XCTAssertEqual(s.sequenceSet, "1:3,7:12")
        s.remove(10)
        XCTAssertEqual(s.sequenceSet, "1:3,7:9,11:12")
        XCTAssertTrue(s.contains(11)); XCTAssertFalse(s.contains(10))
        XCTAssertEqual(s.subtracting(IMAPUIDSet([1, 2, 3, 8])), [7, 9, 11, 12])
        XCTAssertEqual(IMAPUIDSet(sequenceSet: ""), IMAPUIDSet())
        XCTAssertNil(IMAPUIDSet(sequenceSet: "1:*"))
    }

    // MARK: Session over a scripted byte stream

    static let endpoint993 = IMAPEndpoint(host: "imap.example.net", port: 993, security: .implicitTLS)

    /// A minimal post-auth server: PLAIN with SASL-IR, EXAMINE, one message.
    static func scriptedServer(body: Data, packetSize: Int) -> ScriptedIMAPTransport {
        func packets(_ d: Data) -> [Data] {
            stride(from: 0, to: d.count, by: packetSize).map { d.subdata(in: $0..<min(d.count, $0 + packetSize)) }
        }
        let greeting = Data("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n".utf8)
        return ScriptedIMAPTransport(packets: packets(greeting)) { line, _ in
            let tag = String(line.prefix { $0 != " " })
            let cmd = line.dropFirst(tag.count + 1)
            if cmd.hasPrefix("AUTHENTICATE PLAIN") {
                return packets(Data("\(tag) OK [CAPABILITY IMAP4rev1 UIDPLUS] done\r\n".utf8))
            } else if cmd.hasPrefix("EXAMINE") {
                return packets(Data("* 1 EXISTS\r\n* OK [UIDVALIDITY 77] ok\r\n* OK [UIDNEXT 43] ok\r\n\(tag) OK [READ-ONLY] done\r\n".utf8))
            } else if cmd.hasPrefix("UID FETCH 42") {
                return packets(fetchResponse(body, tag: tag, uidFirst: false))
            }
            return packets(Data("\(tag) BAD unexpected\r\n".utf8))
        }
    }

    func testT13_sessionStreamsBody_onePacketPerByte_hashEqualsOracle() async throws {
        let body = Self.hostileBody
        for packetSize in [1, 2, 7, 4_096] {
            let t = Self.scriptedServer(body: body, packetSize: packetSize)
            let s = IMAPSession(transport: t, endpoint: Self.endpoint993, log: IMAPProtocolLog())
            try await s.establish(.password(login: "asha", password: "pw"))
            let status = try await s.examine(Array("INBOX".utf8))
            XCTAssertEqual(status.uidValidity, 77); XCTAssertEqual(status.uidNext, 43)
            let c = Collector()
            let fetched = try await s.fetchBody(uid: 42, into: { c.write($0) })
            XCTAssertEqual(fetched?.byteCount, Int64(body.count))
            XCTAssertEqual(Self.sha(c.bytes), Self.sha(body), "packet size \(packetSize)")
            if packetSize == 1 { XCTAssertGreaterThan(c.chunks, body.count / 2, "streamed as it arrived, not buffered whole") }
            XCTAssertTrue(t.lines.contains { $0.hasSuffix("UID FETCH 42 (UID RFC822.SIZE FLAGS INTERNALDATE BODY.PEEK[])") })
        }
    }

    func testSTARTTLS_sameConnection_preTLSCapabilitiesDiscarded_authOnlyAfterUpgrade() async throws {
        let ep = IMAPEndpoint(host: "mail.example.org", port: 143, security: .startTLS)
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] hi\r\n".utf8)]) { line, tr in
            let tag = String(line.prefix { $0 != " " })
            if line == "M1 STARTTLS" { return [Data("\(tag) OK Begin TLS\r\n".utf8)] }
            if line.hasSuffix(" CAPABILITY") {
                // After TLS the server offers sign-in; pre-TLS capabilities are a downgrade target.
                return [Data(((tr.isEncrypted ? "* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n" : "* CAPABILITY IMAP4rev1 STARTTLS\r\n") + "\(tag) OK\r\n").utf8)]
            }
            if line == "M3 AUTHENTICATE PLAIN" { return [Data((tr.isEncrypted ? "+ \r\n" : "\(tag) NO cleartext\r\n").utf8)] }
            if !line.hasPrefix("M") { return [Data("M3 OK [CAPABILITY IMAP4rev1] done\r\n".utf8)] }
            return [Data("\(tag) BAD\r\n".utf8)]
        }
        let log = IMAPProtocolLog()
        let s = IMAPSession(transport: t, endpoint: ep, log: log)
        try await s.establish(.password(login: "asha", password: "pa55"))
        XCTAssertTrue(t.upgraded)
        let lines = t.lines
        XCTAssertEqual(lines.first, "M1 STARTTLS", "STARTTLS is the first command (the greeting carried the capabilities)")
        XCTAssertEqual(lines[1], "M2 CAPABILITY", "capabilities are re-read after TLS")
        XCTAssertTrue(lines[2].hasPrefix("M3 AUTHENTICATE PLAIN"))
        XCTAssertFalse(log.lines.joined().contains(Data("\u{0}asha\u{0}pa55".utf8).base64EncodedString()), "credentials masked")
    }

    func testSTARTTLSAbsent_noAuthSent() async throws {
        let ep = IMAPEndpoint(host: "mail.example.org", port: 143, security: .startTLS)
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] hi\r\n".utf8)]) { line, _ in
            [Data("\(line.prefix { $0 != " " }) OK\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: ep, log: IMAPProtocolLog())
        do {
            try await s.establish(.password(login: "asha", password: "pa55"))
            XCTFail("must refuse")
        } catch MailProviderError.permanent(let why) {
            XCTAssertTrue(why.contains("STARTTLS"), why)
        }
        XCTAssertTrue(t.lines.isEmpty, "nothing at all was sent: \(t.lines)")
        XCTAssertFalse(String(decoding: t.sentRaw, as: UTF8.self).contains("pa55"))
    }

    func testUnencryptedChannel_neverAuthenticates_andPreauthOnPlaintextRefused() async throws {
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] hi\r\n".utf8)], encrypted: false) { line, _ in
            [Data("\(line.prefix { $0 != " " }) OK\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: Self.endpoint993, log: IMAPProtocolLog())
        do { try await s.establish(.password(login: "asha", password: "pa55")); XCTFail("must refuse") }
        catch MailProviderError.permanent {}
        XCTAssertTrue(t.lines.isEmpty)

        let ep = IMAPEndpoint(host: "mail.example.org", port: 143, security: .startTLS)
        let p = ScriptedIMAPTransport(packets: [Data("* PREAUTH [CAPABILITY IMAP4rev1 STARTTLS] welcome\r\n".utf8)], encrypted: false)
        let s2 = IMAPSession(transport: p, endpoint: ep, log: IMAPProtocolLog())
        do { try await s2.establish(.password(login: "asha", password: "pa55")); XCTFail("must refuse") }
        catch MailProviderError.permanent {}
    }

    func testSTARTTLSResponseInjection_refused() async throws {
        let ep = IMAPEndpoint(host: "mail.example.org", port: 143, security: .startTLS)
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 STARTTLS] hi\r\n".utf8)]) { line, _ in
            let tag = line.prefix { $0 != " " }
            // The OK and a forged pre-TLS capability arrive in one packet.
            return [Data("\(tag) OK Begin TLS\r\n* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: ep, log: IMAPProtocolLog())
        do { try await s.establish(.password(login: "asha", password: "pa55")); XCTFail("must refuse") }
        catch MailProviderError.permanent {}
        XCTAssertFalse(t.upgraded)
        XCTAssertEqual(t.lines, ["M1 STARTTLS"])
    }

    func testXOAUTH2_failureChallengeAnswered_mapsUnauthorized_tokenNeverLogged() async throws {
        let token = "ya29.SECRET-TOKEN-VALUE"
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR] hi\r\n".utf8)]) { line, _ in
            if line.contains("AUTHENTICATE XOAUTH2") {
                return [Data(("+ " + Data(#"{"status":"401"}"#.utf8).base64EncodedString() + "\r\n").utf8)]
            }
            if line.isEmpty { return [Data("M1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n".utf8)] }
            return [Data("M9 BAD\r\n".utf8)]
        }
        let log = IMAPProtocolLog()
        let s = IMAPSession(transport: t, endpoint: Self.endpoint993, log: log)
        do { try await s.establish(.oauth(login: "asha@example.com", accessToken: token)); XCTFail("must fail") }
        catch let e as MailProviderError { XCTAssertEqual(e, .unauthorized) }
        XCTAssertEqual(t.lines.count, 2, "the error challenge got the empty response")
        XCTAssertEqual(t.lines[1], "")
        let b64 = Data("user=asha@example.com\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
        XCTAssertEqual(t.lines[0], "M1 AUTHENTICATE XOAUTH2 \(b64)", "the token goes to the server …")
        XCTAssertFalse(log.lines.joined(separator: "\n").contains(b64), "… but never into the log")
        XCTAssertFalse(log.lines.joined(separator: "\n").contains(token))
    }

    func testOAUTHBEARERPreferred_andLoginLiteralWaitsForContinuation() async throws {
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2 AUTH=OAUTHBEARER] hi\r\n".utf8)]) { line, _ in
            if line == "M1 AUTHENTICATE OAUTHBEARER" { return [Data("+ \r\n".utf8)] }
            if !line.hasPrefix("M") { return [Data("M1 OK [CAPABILITY IMAP4rev1] ok\r\n".utf8)] }
            return [Data("\(line.prefix { $0 != " " }) OK\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: Self.endpoint993, log: IMAPProtocolLog())
        try await s.establish(.oauth(login: "asha@example.com", accessToken: "tok"))
        let gs2 = Data("n,a=asha@example.com,\u{1}host=imap.example.net\u{1}port=993\u{1}auth=Bearer tok\u{1}\u{1}".utf8).base64EncodedString()
        XCTAssertEqual(t.lines.prefix(2), ["M1 AUTHENTICATE OAUTHBEARER", gs2])

        // LOGIN with a non-ASCII password: a synchronising literal (no LITERAL+).
        let l = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1] hi\r\n".utf8)]) { line, _ in
            if line.hasPrefix("M1 LOGIN") { return [Data("+ go\r\n".utf8)] }
            if line.hasPrefix("M") { return [Data("\(line.prefix { $0 != " " }) OK\r\n".utf8)] }
            return [Data("M1 OK [CAPABILITY IMAP4rev1 UIDPLUS] done\r\n".utf8)]
        }
        let log = IMAPProtocolLog()
        let s2 = IMAPSession(transport: l, endpoint: Self.endpoint993, log: log)
        try await s2.establish(.password(login: "asha", password: "pässwört"))
        XCTAssertEqual(l.lines.first, "M1 LOGIN \"asha\" {10}", "the server's '+' was awaited before the literal")
        XCTAssertEqual(l.lines.dropFirst().first, "pässwört")
        XCTAssertFalse(log.lines.joined().contains("pässwört"))
    }

    func testExamineAnsweredReadWrite_isRefused() async throws {
        let t = ScriptedIMAPTransport(packets: [Data("* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n".utf8)]) { line, _ in
            let tag = line.prefix { $0 != " " }
            return [Data("* OK [UIDVALIDITY 5] x\r\n\(tag) OK [READ-WRITE] selected\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: Self.endpoint993, log: IMAPProtocolLog())
        try await s.establish(.password(login: "a", password: "b"))
        do { _ = try await s.examine(Array("INBOX".utf8)); XCTFail("must refuse") } catch MailProviderError.permanent {}
    }

    // MARK: Audit 2026-11-14

    /// Finding 1: a refused sign-in keeps the server's [ALERT] text and is
    /// told apart (IMAP disabled / web login / app password / too many
    /// connections / wrong password). Before: every one was "sign in again".
    func testSignInRefusals_keepTheServerText_andCarryStableCodes() {
        func map(_ code: String, _ text: String, oauth: Bool = false) -> MailProviderError {
            IMAPSession.mapped(IMAPStatusResponse(status: .no, code: IMAPResponseCode(name: code, argument: ""), text: text),
                               context: .authenticate, oauth: oauth)
        }
        let cases: [(String, String, String)] = [
            ("ALERT", "Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)", IMAPErrorCode.imapDisabled),
            ("ALERT", "IMAP access is disabled for your domain. Please contact your domain administrator for questions about this feature. (Failure)", IMAPErrorCode.imapDisabled),
            ("ALERT", "Please log in via your web browser: https://support.google.com/mail/accounts/answer/78754 (Failure)", IMAPErrorCode.webLoginRequired),
            ("WEBALERT", "Web login required.", IMAPErrorCode.webLoginRequired),
            ("ALERT", "Application-specific password required: https://support.google.com/accounts/answer/185833 (Failure)", IMAPErrorCode.appPasswordRequired),
        ]
        for (code, text, expected) in cases {
            guard case .permanent(let why) = map(code, text) else { XCTFail("\(text) → \(map(code, text))"); continue }
            XCTAssertEqual(IMAPErrorCode.code(in: why), expected, why)
            XCTAssertEqual(IMAPErrorCode.detail(in: why), text, "the server's words are kept verbatim")
            XCTAssertEqual(IMAPErrorCode.code(of: map(code, text, oauth: true)), expected, "OAuth too")
        }
        let busy = map("ALERT", "Too many simultaneous connections. (Failure)")
        guard case .transient(let busyWhy) = busy else { return XCTFail("too many connections is retried: \(busy)") }
        XCTAssertEqual(IMAPErrorCode.code(in: busyWhy), IMAPErrorCode.tooManyConnections)
        // A plain refusal stays sign-in (the engine asks for the password / token again).
        XCTAssertEqual(map("AUTHENTICATIONFAILED", "Invalid credentials (Failure)"), .reauthorisationRequired)
        XCTAssertEqual(map("AUTHENTICATIONFAILED", "Invalid credentials (Failure)", oauth: true), .unauthorized)
        let plain = IMAPSignInRefusal.classify(IMAPStatusResponse(status: .no, code: IMAPResponseCode(name: "ALERT", argument: ""),
                                                                  text: "Invalid credentials (Failure)"))
        XCTAssertEqual(plain, IMAPSignInRefusal(code: IMAPErrorCode.authenticationFailed, serverText: "Invalid credentials (Failure)", isAlert: true))
        // Outside sign-in nothing changes.
        if case .transient(let why) = IMAPSession.mapped(IMAPStatusResponse(status: .no, code: nil, text: "too many connections"), context: .fetch) {
            XCTAssertNil(IMAPErrorCode.code(in: why))
        } else { XCTFail("a NO to FETCH stays a plain transient") }
    }

    func testSignInRefusal_throughTheSession_andBusyGreeting() async throws {
        let alert = "Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)"
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] hi\r\n".utf8)]) { line, _ in
            [Data("\(line.prefix { $0 != " " }) NO [ALERT] \(alert)\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: Self.endpoint993, log: IMAPProtocolLog())
        do {
            try await s.establish(.password(login: "asha", password: "pa55"))
            XCTFail("must refuse")
        } catch MailProviderError.permanent(let why) {
            XCTAssertEqual(why, "\(IMAPErrorCode.imapDisabled): \(alert)")
        }
        let refusal = await s.signInRefusal
        XCTAssertEqual(refusal, IMAPSignInRefusal(code: IMAPErrorCode.imapDisabled, serverText: alert, isAlert: true))

        let bye = ScriptedIMAPTransport(packets: [Data("* BYE Maximum number of connections from user+IP exceeded (mail_max_userip_connections=10)\r\n".utf8)])
        let s2 = IMAPSession(transport: bye, endpoint: Self.endpoint993, log: IMAPProtocolLog())
        do { try await s2.establish(.password(login: "asha", password: "pa55")); XCTFail("must refuse") }
        catch MailProviderError.transient(let why) { XCTAssertEqual(IMAPErrorCode.code(in: why), IMAPErrorCode.tooManyConnections, why) }
    }

    /// Finding 2: TLS failures are recognised in Network.framework,
    /// URLSession and Security errors; a certificate failure maps to a
    /// permanent coded error naming the host (before: a transient "could not be reached").
    func testTLSFailures_areRecognised_andCertificateFailuresArePermanent() {
        XCTAssertEqual(MailTLSFailure.classify(NWError.tls(-9807)), MailTLSFailure.Classified(status: -9807, certificate: true), "errSSLXCertChainInvalid")
        XCTAssertEqual(MailTLSFailure.classify(NWError.tls(-9843)), MailTLSFailure.Classified(status: -9843, certificate: true), "errSSLHostNameMismatch")
        XCTAssertEqual(MailTLSFailure.classify(NWError.tls(-67843)), MailTLSFailure.Classified(status: -67843, certificate: true), "errSecNotTrusted")
        XCTAssertEqual(MailTLSFailure.classify(NWError.tls(-9800)), MailTLSFailure.Classified(status: -9800, certificate: false), "errSSLProtocol")
        XCTAssertNil(MailTLSFailure.classify(NWError.tls(-9806)), "errSSLClosedAbort is a dropped connection")
        XCTAssertNil(MailTLSFailure.classify(NWError.posix(.ECONNREFUSED)))
        XCTAssertNil(MailTLSFailure.classify(URLError(.timedOut)))
        XCTAssertEqual(MailTLSFailure.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateHasBadDate))?.certificate, true)
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9843)])
        XCTAssertEqual(MailTLSFailure.classify(wrapped), MailTLSFailure.Classified(status: -9843, certificate: true))
        XCTAssertEqual(MailTLSFailure.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                                                       userInfo: ["_kCFStreamErrorCodeKey": -9813]))?.certificate, true)

        let cert = NWIMAPTransport.failure(.tls(-9807), host: "imap.example.net")
        XCTAssertEqual(cert as? IMAPTLSError, IMAPTLSError(host: "imap.example.net", status: -9807, isCertificateFailure: true,
                                                          detail: NWError.tls(-9807).localizedDescription))
        guard case MailProviderError.permanent(let why) = IMAPAdapter.map(cert) else { return XCTFail("\(IMAPAdapter.map(cert))") }
        XCTAssertEqual(IMAPErrorCode.code(in: why), IMAPErrorCode.certificateNotTrusted)
        XCTAssertTrue(why.contains("imap.example.net"), why)
        guard case MailProviderError.permanent(let why2) = IMAPAdapter.map(NWIMAPTransport.failure(.tls(-9800), host: "h")) else { return XCTFail() }
        XCTAssertEqual(IMAPErrorCode.code(in: why2), IMAPErrorCode.tlsHandshakeFailed)
        if case MailProviderError.transient = IMAPAdapter.map(NWIMAPTransport.failure(.posix(.ECONNREFUSED), host: "h")) {} else {
            XCTFail("a refused connection is still retried")
        }
        // Errors after STARTTLS (URLSessionStreamTask) the same way.
        XCTAssertEqual((StreamTaskIMAPTransport.failure(wrapped, host: "h") as? IMAPTLSError)?.isCertificateFailure, true)
    }

    /// Finding 4: sparse UID sets of 50,000 UIDs parse, insert and remove in
    /// near-linear time (before: one O(n) array rebuild per range — minutes).
    func testUIDSet_50kSparseUIDs_linearTime() {
        let uids = (0..<50_000).map { UInt32($0 * 2 + 1) }                 // 1,3,5,… no two adjacent
        let text = uids.map(String.init).joined(separator: ",")
        let start = Date()
        let parsed = IMAPUIDSet(sequenceSet: text)
        XCTAssertEqual(parsed?.count, 50_000)
        XCTAssertEqual(parsed?.ranges.count, 50_000)
        XCTAssertEqual(parsed?.sequenceSet, text)
        var built = IMAPUIDSet()
        for u in uids.reversed() { built.insert(u) }                       // worst order for an append
        XCTAssertEqual(built, parsed)
        XCTAssertTrue(uids.allSatisfy { built.contains($0) })
        XCTAssertFalse(built.contains(2))
        let shuffled = IMAPUIDSet(sequenceSet: uids.shuffled().map(String.init).joined(separator: ","))
        XCTAssertEqual(shuffled, parsed)
        for u in uids where u % 4 == 1 { built.remove(u) }
        XCTAssertEqual(built.count, 25_000)
        XCTAssertEqual(built.ranges.first, 3...3)
        // Filling the gaps merges everything into one range.
        for u in stride(from: UInt32(2), through: 100_000, by: 2) { built.insert(u) }
        for u in uids where u % 4 == 1 { built.insert(u) }
        XCTAssertEqual(built.ranges, [1...100_000])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5, "50k sparse UIDs took \(elapsed) s")
        // Overlapping and out-of-order ranges still merge correctly.
        XCTAssertEqual(IMAPUIDSet(sequenceSet: "10:20,1:3,4,15:30,40,32:31")?.sequenceSet, "1:4,10:32,40")
        var s = IMAPUIDSet(sequenceSet: "1:3,7,9:12")!
        s.insert(5...8)
        XCTAssertEqual(s.sequenceSet, "1:3,5:12")
        s.insert(4294967295)
        s.remove(4294967295)
        s.remove(1)
        XCTAssertEqual(s.sequenceSet, "2:3,5:12")
    }

    /// Finding 7: two 8-bit folder names that are neither UTF-8 nor modified
    /// UTF-7 decode to the same lossy text; they stay two folders, keyed on
    /// their wire bytes, and the exact bytes go back to the server.
    func testUndecodable8BitFolderNames_areKeyedOnWireBytes_andNeverCollide() async throws {
        let a: [UInt8] = [0x41, 0xE9], b: [UInt8] = [0x41, 0xEA]           // "Aé" / "Aê" in Latin-1
        let na = IMAPMailboxName(wire: a, utf8: false), nb = IMAPMailboxName(wire: b, utf8: true)
        XCTAssertEqual(na.name, nb.name, "the display text is lossy for both")
        XCTAssertNotEqual(na.serverID, nb.serverID)
        XCTAssertTrue(na.serverID.hasPrefix(IMAPMailboxName.rawPrefix))
        XCTAssertEqual(IMAPMailboxName.wireBytes(for: na.serverID, utf8: false), a, "without a LIST: the exact bytes")
        XCTAssertEqual(IMAPMailboxName.wireBytes(for: nb.serverID, utf8: true), b)
        XCTAssertEqual(IMAPMailboxName.displayName(forServerID: na.serverID), "A\u{FFFD}")
        XCTAssertEqual(IMAPMailboxName(wire: Array("Entwürfe".utf8), utf8: false).serverID, "Entwürfe", "raw UTF-8 stays its name")
        XCTAssertEqual(IMAPMailboxName(wire: Array("Entw&APw-rfe".utf8), utf8: false).serverID, "Entwürfe")

        var listing = Data("* LIST (\\HasNoChildren) \"/\" INBOX\r\n".utf8)
        for name in [a, b] { listing += Data("* LIST (\\HasNoChildren) \"/\" {2}\r\n".utf8) + Data(name) + Data("\r\n".utf8) }
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] hi\r\n".utf8)]) { line, _ in
            let tag = String(line.prefix { $0 != " " })
            if line.contains("AUTHENTICATE") { return [Data("\(tag) OK [CAPABILITY IMAP4rev1] done\r\n".utf8)] }
            if line.contains(" LIST ") { return [listing + Data("\(tag) OK LIST done\r\n".utf8)] }
            return [Data("\(tag) BAD unexpected\r\n".utf8)]
        }
        let account = UUID()
        let credentials = InMemoryCredentialStore()
        try credentials.write(Data("pa55".utf8), kind: .password, account: account)
        let adapter = IMAPAdapter(accountID: account, configuration: IMAPAccountConfiguration(host: "imap.example.net", login: "asha"),
                                  credentials: credentials, transportFactory: { _ in t })
        let folders = try await adapter.listFolders(pageToken: nil, context: ProviderRequestContext(accountID: account, accessToken: nil, attempt: 0)).folders
        XCTAssertEqual(folders.count, 3, "two distinct 8-bit folders, not one: \(folders.map(\.serverID))")
        XCTAssertEqual(Set(folders.map(\.serverID)), ["INBOX", na.serverID, nb.serverID])
        let wireA = await adapter.actionWire(na.serverID, utf8: false)
        let wireB = await adapter.actionWire(nb.serverID, utf8: false)
        XCTAssertEqual(wireA, a); XCTAssertEqual(wireB, b)
    }

    /// Finding 9: Gmail sends X-GM-LABELS in modified UTF-7 even with
    /// UTF8=ACCEPT on (folder names then arrive as UTF-8): both decode alike.
    func testGmailLabelNames_modifiedUTF7AndUTF8_decodeToTheFolderName() {
        let name = "Отчёты/日本"
        let mutf7 = Array(IMAPModifiedUTF7.encode(name).utf8)
        XCTAssertEqual(IMAPSession.gmailLabelName(mutf7, utf8: true), name, "modified UTF-7 under UTF8=ACCEPT")
        XCTAssertEqual(IMAPSession.gmailLabelName(mutf7, utf8: false), name)
        XCTAssertEqual(IMAPSession.gmailLabelName(Array(name.utf8), utf8: true), name)
        XCTAssertEqual(IMAPSession.gmailLabelName(Array(name.utf8), utf8: false), name, "raw UTF-8 without UTF8=ACCEPT")
        XCTAssertEqual(IMAPSession.gmailLabelName(Array("R&D".utf8), utf8: true), "R&D", "a plain '&' is not a shift")
        XCTAssertEqual(IMAPSession.gmailLabelName(Array("Work".utf8), utf8: true), "Work")
    }
}
