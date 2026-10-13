//
//  ForensicSignalsTests.swift
//  ArchiveCoreTests
//
//  3.1 F1–F4: hidden timestamps, Received trace, missing DKIM, offline DKIM
//  verification and tampering signals. The DKIM tests build the signed data
//  by hand from RFC 6376 rules (not with the verifier's own helpers) and sign
//  it with keys made in the test.
//

import XCTest
import Foundation
import CryptoKit
import Security
@testable import ArchiveCore

final class ForensicSignalsTests: XCTestCase {

    private func fileTime(_ d: Date) -> UInt64 { UInt64((d.timeIntervalSince1970 + 11_644_473_600) * 10_000_000) }
    private let when = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

    // MARK: F1

    func testThreadIndex_headerAndChildBlocks() {
        let ft = fileTime(when)
        var bytes: [UInt8] = []
        let top = ft >> 16
        for i in (0..<6).reversed() { bytes.append(UInt8((top >> (UInt64(i) * 8)) & 0xFF)) }
        bytes += [UInt8](repeating: 0xAB, count: 16)          // GUID
        // One child block: +1 hour, short form (<< 18).
        let delta = UInt32((UInt64(36_000_000_000) >> 18) & 0x7FFF_FFFF)
        bytes += [UInt8(delta >> 24), UInt8((delta >> 16) & 0xFF), UInt8((delta >> 8) & 0xFF), UInt8(delta & 0xFF), 0x01]
        let stamps = HiddenTimestamps.threadIndex(Data(bytes).base64EncodedString())
        XCTAssertEqual(stamps.count, 2)
        XCTAssertEqual(stamps[0].date.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(stamps[1].date.timeIntervalSince(stamps[0].date), 3600, accuracy: 0.1)
    }

    func testOutlookBoundary_decodesFileTime() throws {
        let ft = fileTime(when)
        let boundary = String(format: "----=_NextPart_000_0001_%08X.%08X", UInt32(ft >> 32), UInt32(ft & 0xFFFF_FFFF))
        let t = try XCTUnwrap(HiddenTimestamps.outlookBoundary(boundary))
        XCTAssertEqual(t.date.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.01)
    }

    func testEpochInMessageIDAndJavaMailBoundary() throws {
        let ms = try XCTUnwrap(HiddenTimestamps.epoch(in: "<1234.5678.1700000000123@host>", source: "x"))
        XCTAssertEqual(ms.date.timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.001)
        XCTAssertNil(HiddenTimestamps.epoch(in: "<abcdef@host>", source: "x"))
        XCTAssertNil(HiddenTimestamps.epoch(in: "<9999999999@host>", source: "x"), "years outside 2000…next year are not times")
    }

    // MARK: F4 Received trace

    private let traced = """
    Received: from mx.example.org (mx.example.org [203.0.113.5]) by inbox.example.net with ESMTP; Tue, 14 Nov 2023 22:20:00 +0000
    Received: from client (unknown [198.51.100.7]) by mx.example.org with ESMTPSA; Tue, 14 Nov 2023 22:30:00 +0000
    From: a@example.com
    Date: Tue, 14 Nov 2023 22:13:20 +0000
    Subject: trace

    body
    """

    func testReceivedTrace_travelOrder_andBackwardsClock() {
        let hops = ReceivedTrace.hops(rawSource: traced)
        XCTAssertEqual(hops.count, 2)
        XCTAssertEqual(hops[0].by, "mx.example.org", "the bottom header is the first hop")
        XCTAssertEqual(hops[1].by, "inbox.example.net")
        XCTAssertEqual(hops[1].delay ?? 0, -600, accuracy: 0.1)
        let signals = TamperingSignals.find(headers: ["Date": "Tue, 14 Nov 2023 22:13:20 +0000"], rawSource: traced, attachmentCount: 0)
        XCTAssertTrue(signals.contains { $0.contains("before the previous one") })
    }

    func testRemovedAttachmentSignals() {
        let raw = "Content-Type: text/x-moz-deleted; name=\"a.pdf\"\n\nx"
        XCTAssertFalse(TamperingSignals.find(headers: [:], rawSource: raw, attachmentCount: 0).isEmpty)
        XCTAssertFalse(TamperingSignals.find(headers: ["X-MS-Has-Attach": "yes"], rawSource: "", attachmentCount: 0).isEmpty)
        XCTAssertTrue(TamperingSignals.find(headers: ["X-MS-Has-Attach": "yes"], rawSource: "", attachmentCount: 1).isEmpty)
    }

    // MARK: F2

    func testMissingDKIM_onlyForSigningProvidersAfterTheirDate() {
        let date = RFC5322Date.parse("Tue, 14 Nov 2023 22:13:20 +0000")
        XCTAssertNotNil(DKIMExpectations.missingSignature(headers: ["From": "A <a@gmail.com>"], date: date))
        XCTAssertNil(DKIMExpectations.missingSignature(headers: ["From": "a@gmail.com", "DKIM-Signature": "v=1"], date: date))
        XCTAssertNil(DKIMExpectations.missingSignature(headers: ["From": "a@small-company.example"], date: date))
        XCTAssertNil(DKIMExpectations.missingSignature(headers: ["From": "a@gmail.com"], date: RFC5322Date.parse("Mon, 3 Jan 2005 10:00:00 +0000")))
    }

    // MARK: F3 offline DKIM

    private let body = "Hello,  world \r\n\r\n\r\n"

    /// relaxed/relaxed by hand: h=from:subject.
    private func signedMessage(sign: (Data) throws -> Data, alg: String, subject: String = "Test") throws -> String {
        let bh = Data(SHA256.hash(data: Data("Hello, world\r\n".utf8))).base64EncodedString()
        let sigTags = "v=1; a=\(alg); c=relaxed/relaxed; d=example.com; s=sel; h=from:subject; bh=\(bh); b="
        let canon = "from:A <a@example.com>\r\nsubject:\(subject)\r\ndkim-signature:\(sigTags)"
        let b = try sign(Data(canon.utf8)).base64EncodedString()
        return "DKIM-Signature: \(sigTags)\(b)\r\nFrom: A <a@example.com>\r\nSubject:   \(subject)\r\n\r\n" + body
    }

    func testDKIM_ed25519_passes_andTamperingFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keys = DKIMKeyCache(records: ["sel._domainkey.example.com": "v=DKIM1; k=ed25519; p=\(key.publicKey.rawRepresentation.base64EncodedString())"])
        let raw = try signedMessage(sign: { try key.signature(for: Data(SHA256.hash(data: $0))) }, alg: "ed25519-sha256")
        XCTAssertEqual(DKIMVerifier.verify(rawSource: raw, keys: keys), .pass(domain: "example.com", selector: "sel"))

        let changedSubject = raw.replacingOccurrences(of: "Subject:   Test", with: "Subject:   Tost")
        guard case .fail = DKIMVerifier.verify(rawSource: changedSubject, keys: keys) else { return XCTFail("a changed header must fail") }
        let changedBody = raw.replacingOccurrences(of: "Hello,", with: "Hullo,")
        guard case .fail(let why) = DKIMVerifier.verify(rawSource: changedBody, keys: keys) else { return XCTFail("a changed body must fail") }
        XCTAssertTrue(why.contains("body"))
        XCTAssertEqual(DKIMVerifier.verify(rawSource: raw, keys: DKIMKeyCache()), .noKey(domain: "example.com", selector: "sel"))
    }

    func testDKIM_rsa_spkiKey_passes() throws {
        var error: Unmanaged<CFError>?
        let priv = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(priv))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, &error) as Data?)
        // Wrap PKCS#1 in SubjectPublicKeyInfo, as DNS records carry it.
        func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            var len: [UInt8]
            if content.count < 0x80 { len = [UInt8(content.count)] }
            else if content.count < 0x100 { len = [0x81, UInt8(content.count)] }
            else { len = [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] }
            return [tag] + len + content
        }
        let algID: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let spki = der(0x30, algID + der(0x03, [0x00] + [UInt8](pkcs1)))
        let keys = DKIMKeyCache(records: ["sel._domainkey.example.com": "v=DKIM1; k=rsa; p=\(Data(spki).base64EncodedString())"])
        let raw = try signedMessage(sign: { data in
            var e: Unmanaged<CFError>?
            guard let s = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &e) as Data? else {
                throw e!.takeRetainedValue() as Error
            }
            return s
        }, alg: "rsa-sha256")
        XCTAssertEqual(DKIMVerifier.verify(rawSource: raw, keys: keys), .pass(domain: "example.com", selector: "sel"))
    }

    func testDKIM_simpleSimple_passes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keys = DKIMKeyCache(records: ["sel._domainkey.example.com": "v=DKIM1; k=ed25519; p=\(key.publicKey.rawRepresentation.base64EncodedString())"])
        // simple body: trailing empty lines collapse to one CRLF; spaces kept.
        let bh = Data(SHA256.hash(data: Data("Hello,  world \r\n".utf8))).base64EncodedString()
        let tags = "v=1; a=ed25519-sha256; c=simple/simple; d=example.com; s=sel; h=from:subject; bh=\(bh); b="
        let canon = "From: A <a@example.com>\r\nSubject:   Test\r\nDKIM-Signature: \(tags)"
        let b = try key.signature(for: Data(SHA256.hash(data: Data(canon.utf8)))).base64EncodedString()
        let raw = "DKIM-Signature: \(tags)\(b)\r\nFrom: A <a@example.com>\r\nSubject:   Test\r\n\r\n" + body
        XCTAssertEqual(DKIMVerifier.verify(rawSource: raw, keys: keys), .pass(domain: "example.com", selector: "sel"))
        let respaced = raw.replacingOccurrences(of: "Subject:   Test", with: "Subject: Test")
        guard case .fail = DKIMVerifier.verify(rawSource: respaced, keys: keys) else { return XCTFail("simple canonicalization keeps whitespace") }
    }

    func testKeyCacheParsesTxtLines() {
        let c = DKIMKeyCache.parse("sel._domainkey.Example.com.  \"v=DKIM1; k=rsa; p=ABC\"\n# comment line\n")
        XCTAssertEqual(c.record(selector: "sel", domain: "example.com"), "v=DKIM1; k=rsa; p=ABC")
    }
}

final class DKIMMultiSignatureTests: XCTestCase {
    func testAnyValidSignaturePasses_andARCMessageSignatureIsChecked() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let keys = DKIMKeyCache(records: ["sel._domainkey.example.com": "v=DKIM1; k=ed25519; p=\(key.publicKey.rawRepresentation.base64EncodedString())"])
        let bh = Data(SHA256.hash(data: Data("hi\r\n".utf8))).base64EncodedString()
        func sign(_ header: String, _ k: Curve25519.Signing.PrivateKey) throws -> String {
            let tags = "i=1; a=ed25519-sha256; c=relaxed/relaxed; d=example.com; s=sel; h=from; bh=\(bh); b="
            let canon = "from:a@example.com\r\n\(header.lowercased()):\(tags)"
            let b = try k.signature(for: Data(SHA256.hash(data: Data(canon.utf8)))).base64EncodedString()
            return "\(header): \(tags)\(b)\r\n"
        }
        // First signature is from a key we do not hold (fails), the second verifies.
        let raw = try sign("DKIM-Signature", other) + sign("DKIM-Signature", key) + "From: a@example.com\r\n\r\nhi\r\n"
        XCTAssertEqual(DKIMVerifier.verify(rawSource: raw, keys: keys), .pass(domain: "example.com", selector: "sel"))
        let arc = try sign("ARC-Message-Signature", key) + "From: a@example.com\r\n\r\nhi\r\n"
        XCTAssertEqual(DKIMVerifier.verify(rawSource: arc, keys: keys, signatureHeader: "ARC-Message-Signature"),
                       .pass(domain: "example.com", selector: "sel"))
        XCTAssertEqual(DKIMVerifier.verify(rawSource: arc, keys: keys), .noSignature)
    }
}


final class GmailTimestampTests: XCTestCase {
    private func utc(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: d)
    }

    func testPublishedGmailBoundaryExample() throws {
        let t = try XCTUnwrap(HiddenTimestamps.gmailBoundary("000000000000b6809105a0ae7b18"))
        XCTAssertEqual(utc(t.date), "2020-03-12 20:49:03.864")
        XCTAssertNil(HiddenTimestamps.gmailBoundary("----=_Part_1_2.3"))
        XCTAssertNil(HiddenTimestamps.gmailBoundary("Apple-Mail=_0D7F3F3A-3B1E-4B5A-9C0A-1A2B3C4D5E6F"))
    }

    func testPublishedGmailMessageIDExample_hexAndDecimal() throws {
        let hex = try XCTUnwrap(HiddenTimestamps.gmailInternalID("172ed79b0337c14f", source: "x"))
        XCTAssertEqual(utc(hex.date), "2020-06-25 21:54:34.675")
        let decimal = String(UInt64("172ed79b0337c14f", radix: 16)!)
        XCTAssertEqual(try XCTUnwrap(HiddenTimestamps.gmailInternalID(decimal, source: "x")).date, hex.date, "Takeout writes it in decimal")
    }

    func testUUIDv1_isDated_v4IsNot() throws {
        // RFC 4122 v1 for 2020-01-01T00:00:00Z: ticks = (1577836800 + 12219292800) * 1e7.
        let ticks = UInt64(1_577_836_800 + 12_219_292_800) * 10_000_000
        let low = ticks & 0xFFFF_FFFF, mid = (ticks >> 32) & 0xFFFF, hi = (ticks >> 48) & 0x0FFF
        let uuid = String(format: "%08llx-%04llx-1%03llx-8000-00aabbccddee", low, mid, hi)
        let t = try XCTUnwrap(HiddenTimestamps.uuidV1(in: "<\(uuid)@host>"))
        XCTAssertEqual(t.date.timeIntervalSince1970, 1_577_836_800, accuracy: 0.001)
        XCTAssertNil(HiddenTimestamps.uuidV1(in: "<\(UUID().uuidString)@host>"), "v4 UUIDs carry no time")
    }

    func testAll_collectsGmailSources() {
        let raw = "Content-Type: multipart/alternative; boundary=\"000000000000b6809105a0ae7b18\"\n\nbody"
        let stamps = HiddenTimestamps.all(headers: ["X-GM-THRID": String(UInt64("172ed79b0337c14f", radix: 16)!)], rawSource: raw)
        XCTAssertTrue(stamps.contains { $0.source == "MIME boundary (Gmail)" })
        XCTAssertTrue(stamps.contains { $0.source.hasPrefix("Gmail thread id") })
    }
}


final class ARCChainTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var keys: DKIMKeyCache { DKIMKeyCache(records: ["arc._domainkey.relay.example": "v=DKIM1; k=ed25519; p=\(key.publicKey.rawRepresentation.base64EncodedString())"]) }

    private func sign(_ s: String) throws -> String {
        try key.signature(for: Data(SHA256.hash(data: Data(s.utf8)))).base64EncodedString()
    }

    /// Builds a message carrying `hops` ARC sets, hand-canonicalized per RFC 8617.
    private func message(hops: Int, cvOverride: [Int: String] = [:]) throws -> String {
        let body = "hello\r\n"
        let bh = Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString()
        var setsCanon = ""     // relaxed text of every earlier complete set
        var headers: [String] = []
        for i in 1...hops {
            let aarValue = "i=\(i); relay.example; spf=pass"
            let amsTags = "i=\(i); a=ed25519-sha256; c=relaxed/relaxed; d=relay.example; s=arc; h=from; bh=\(bh); b="
            let amsSig = try sign("from:a@example.com\r\narc-message-signature:\(amsTags)")
            let cv = cvOverride[i] ?? (i == 1 ? "none" : "pass")
            let sealTags = "i=\(i); a=ed25519-sha256; cv=\(cv); d=relay.example; s=arc; b="
            let sealInput = setsCanon + "arc-authentication-results:\(aarValue)\r\n" + "arc-message-signature:\(amsTags)\(amsSig)\r\n" + "arc-seal:\(sealTags)"
            let sealSig = try sign(sealInput)
            setsCanon += "arc-authentication-results:\(aarValue)\r\narc-message-signature:\(amsTags)\(amsSig)\r\narc-seal:\(sealTags)\(sealSig)\r\n"
            headers.insert(contentsOf: ["ARC-Seal: \(sealTags)\(sealSig)", "ARC-Message-Signature: \(amsTags)\(amsSig)", "ARC-Authentication-Results: \(aarValue)"], at: 0)
        }
        return headers.joined(separator: "\r\n") + "\r\nFrom: a@example.com\r\n\r\n" + body
    }

    func testOneAndThreeHopChainsPass() throws {
        XCTAssertEqual(DKIMVerifier.verifyARCChain(rawSource: try message(hops: 1), keys: keys), .pass(instances: 1))
        XCTAssertEqual(DKIMVerifier.verifyARCChain(rawSource: try message(hops: 3), keys: keys), .pass(instances: 3))
    }

    func testChangedEarlierResults_failAtTheRightSeal() throws {
        let raw = try message(hops: 3).replacingOccurrences(of: "i=1; relay.example; spf=pass", with: "i=1; relay.example; spf=fail")
        guard case .fail(let i, _) = DKIMVerifier.verifyARCChain(rawSource: raw, keys: keys) else { return XCTFail("must fail") }
        XCTAssertEqual(i, 1, "seal 1 covers set 1")
    }

    func testCvRules_andMissingSet() throws {
        guard case .fail(2, _) = DKIMVerifier.verifyARCChain(rawSource: try message(hops: 2, cvOverride: [2: "fail"]), keys: keys) else { return XCTFail() }
        guard case .fail(1, _) = DKIMVerifier.verifyARCChain(rawSource: try message(hops: 2, cvOverride: [1: "pass"]), keys: keys) else { return XCTFail() }
        let gap = try message(hops: 2).components(separatedBy: "\r\n").filter { !$0.hasPrefix("ARC-Authentication-Results: i=1") }.joined(separator: "\r\n")
        guard case .fail(1, _) = DKIMVerifier.verifyARCChain(rawSource: gap, keys: keys) else { return XCTFail("missing set") }
        XCTAssertEqual(DKIMVerifier.verifyARCChain(rawSource: "From: a\r\n\r\nb", keys: keys), .none)
        guard case .noKey = DKIMVerifier.verifyARCChain(rawSource: try message(hops: 1), keys: DKIMKeyCache()) else { return XCTFail() }
    }
}

/// The open-source ARC validation suite (ValiMail, MIT — Fixtures/arc/LICENSE.txt),
/// written against the ARC drafts; known disagreements with RFC 8617 are listed.
final class ARCOpenSuiteTests: XCTestCase {
    struct Case: Decodable { let name: String; let message: String; let cv: String; let txt: [String: String] }

    func testValiMailValidationSuite() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/arc/arc-validation.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        var agree = 0, total = 0
        var mismatches: [String] = []
        for c in cases where ["Pass", "Fail", "None"].contains(c.cv) {
            total += 1
            let r = DKIMVerifier.verifyARCChain(rawSource: c.message, keys: DKIMKeyCache(records: c.txt.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }))
            let got: String
            switch r {
            case .pass: got = "Pass"
            case .none: got = "None"
            case .fail, .noKey: got = "Fail"
            }
            if got == c.cv { agree += 1 } else { mismatches.append("\(c.name): expected \(c.cv), got \(got) (\(r))") }
        }
        print("ARC-SUITE \(agree)/\(total)\n" + mismatches.joined(separator: "\n"))
        XCTAssertGreaterThan(total, 100)
        // The two cases where the draft-era suite and RFC 8617 / RFC 6376 disagree
        // (mailauth reports the same two): an AMS without c= (RFC: simple/simple,
        // the suite assumed relaxed) and an AMS with an empty h= (RFC 6376: h= must
        // list at least From). We follow the RFCs.
        let knownRFCDifferences: Set<String> = ["ams_fields_c_na", "ams_fields_h_empty"]
        let unexpected = mismatches.filter { m in !knownRFCDifferences.contains(where: { m.hasPrefix($0 + ":") }) }
        XCTAssertTrue(unexpected.isEmpty, unexpected.joined(separator: "\n"))
        XCTAssertEqual(agree, total - knownRFCDifferences.count)
    }
}
