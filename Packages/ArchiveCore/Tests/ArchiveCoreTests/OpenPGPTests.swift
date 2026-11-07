//
//  OpenPGPTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Protected mail/documents", OpenPGP: detection
//  and description without a key. Packets are built from RFC 4880 §4/§5
//  (old and new header formats, partial lengths), armored with CRC-24, and
//  wrapped as PGP/MIME and inline mail. No GnuPG or Sequoia is installed on
//  this Mac, so a run on GnuPG-written files is owner-bound (see the report).
//

import XCTest
import Foundation
@testable import ArchiveCore

final class OpenPGPTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    // MARK: Packet builders (RFC 4880 §4.2)

    static func newPacket(tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xC0 | tag]
        let n = body.count
        if n < 192 { out.append(UInt8(n)) }
        else if n < 8384 { out += [UInt8(((n - 192) >> 8) + 192), UInt8((n - 192) & 0xFF)] }
        else { out += [255, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
        return out + body
    }

    static func oldPacket(tag: UInt8, _ body: [UInt8], lengthType: UInt8 = 1) -> [UInt8] {
        var out: [UInt8] = [0x80 | (tag << 2) | lengthType]
        switch lengthType {
        case 0: out.append(UInt8(body.count))
        case 1: out += [UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        case 2: out += [UInt8(body.count >> 24), UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)]
        default: break
        }
        return out + body
    }

    static let keyA: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
    static let keyB: [UInt8] = [0xCA, 0xFE, 0xF0, 0x0D, 0xAA, 0xBB, 0xCC, 0xDD]
    static let fingerprint: [UInt8] = (0..<20).map { UInt8($0 * 11 + 1) }

    /// PKESK v3: version, key ID, algorithm, MPI(s).
    static func pkesk(keyID: [UInt8], algorithm: UInt8) -> [UInt8] {
        newPacket(tag: 1, [3] + keyID + [algorithm] + [0x04, 0x00] + [UInt8](repeating: 0x5A, count: 128))
    }
    /// SKESK v4: version, cipher, S2K (iterated+salted SHA-256).
    static func skesk(cipher: UInt8) -> [UInt8] { newPacket(tag: 3, [4, cipher, 3, 8] + [UInt8](repeating: 0x11, count: 8) + [0x60]) }
    /// SEIPD v1 (MDC) with 40 bytes of cipher text.
    static let seipdV1 = newPacket(tag: 18, [1] + [UInt8](repeating: 0x77, count: 40))
    /// SEIPD v2 (RFC 9580 AEAD): version, cipher, AEAD mode, chunk size, salt(32), body.
    static let seipdV2 = newPacket(tag: 18, [2, 9, 2, 6] + [UInt8](repeating: 0x33, count: 32) + [UInt8](repeating: 0x44, count: 40))
    /// Tag 9: encrypted data without integrity protection.
    static let sed = oldPacket(tag: 9, [UInt8](repeating: 0x99, count: 40))

    /// Signature v4 over a binary document: EdDSA / SHA-512, creation time and issuer fingerprint hashed, issuer key ID unhashed.
    static func signatureV4(issuer: [UInt8], fingerprint: [UInt8], time: UInt32 = 1_700_000_000) -> [UInt8] {
        let creation: [UInt8] = [5, 2, UInt8(time >> 24), UInt8((time >> 16) & 0xFF), UInt8((time >> 8) & 0xFF), UInt8(time & 0xFF)]
        let issuerFP: [UInt8] = [UInt8(fingerprint.count + 2), 33, 4] + fingerprint
        let hashed = creation + issuerFP
        let unhashed: [UInt8] = [9, 16] + issuer
        return newPacket(tag: 2, [4, 0x00, 22, 10, UInt8(hashed.count >> 8), UInt8(hashed.count & 0xFF)] + hashed
                         + [UInt8(unhashed.count >> 8), UInt8(unhashed.count & 0xFF)] + unhashed + [0xAB, 0xCD] + [0x01, 0x00, 0x01] + [UInt8](repeating: 0x42, count: 64))
    }
    static func signatureV3(issuer: [UInt8]) -> [UInt8] {
        oldPacket(tag: 2, [3, 5, 0x01, 0x5F, 0x5E, 0x10, 0x00] + issuer + [1, 2] + [0xAB, 0xCD] + [0x00, 0x08, 0x42])
    }
    static func literal(name: String, text: String) -> [UInt8] {
        newPacket(tag: 11, [UInt8(ascii: "b"), UInt8(name.utf8.count)] + Array(name.utf8) + [0, 0, 0, 0] + Array(text.utf8))
    }

    func writeBytes(_ name: String, _ bytes: [UInt8]) throws -> URL { let u = dir.appendingPathComponent(name); try Data(bytes).write(to: u); return u }
    func writeText(_ name: String, _ text: String) throws -> URL { let u = dir.appendingPathComponent(name); try Data(text.utf8).write(to: u); return u }

    // MARK: Packets

    func testEncryptedToTwoKeysAndAPassphrase_withMDC_isLockedNamingRecipients() throws {
        let bytes = Self.pkesk(keyID: Self.keyA, algorithm: 1) + Self.pkesk(keyID: Self.keyB, algorithm: 18) + Self.skesk(cipher: 9) + Self.seipdV1
        let s = try OpenPGP.summarize(Data(bytes))
        XCTAssertTrue(s.isEncrypted)
        XCTAssertEqual(s.recipients.map(\.keyID), ["DEADBEEF01020304", "CAFEF00DAABBCCDD"])
        XCTAssertEqual(s.recipients.map(\.algorithm), ["RSA", "ECDH"])
        XCTAssertEqual(s.symmetricSessionKeys, ["AES-256"])
        XCTAssertEqual(s.encryptedData, .mdc)
        XCTAssertEqual(s.packetTags, [1, 1, 3, 18])
        XCTAssertTrue(s.description.contains("key DEADBEEF01020304 (RSA)"), s.description)
        XCTAssertTrue(s.description.contains("key CAFEF00DAABBCCDD (ECDH)"), s.description)
        XCTAssertTrue(s.description.contains("a passphrase (AES-256)"), s.description)
        XCTAssertTrue(s.description.contains("MDC present"), s.description)
        XCTAssertTrue(s.description.contains("not decrypted — this release has no OpenPGP key store"), s.description)

        // Through the facade: locked (the coverage state), nothing decrypted.
        let url = try writeBytes("secret.gpg", bytes)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "secret.gpg"), .pgp)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .pgp)) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .encrypted) }
    }

    func testAnonymousRecipient_AEADv2_andLegacyWithoutIntegrity() throws {
        let anon = Self.pkesk(keyID: [UInt8](repeating: 0, count: 8), algorithm: 25) + Self.seipdV2
        let s = try OpenPGP.summarize(Data(anon))
        XCTAssertTrue(s.recipients[0].isAnonymous)
        XCTAssertEqual(s.encryptedData, .aead(mode: "OCB", cipher: "AES-256"))
        XCTAssertTrue(s.description.contains("an anonymous recipient (X25519)"), s.description)
        XCTAssertTrue(s.description.contains("AEAD OCB with AES-256"), s.description)

        let legacy = Self.pkesk(keyID: Self.keyA, algorithm: 16) + Self.sed
        let l = try OpenPGP.summarize(Data(legacy))
        XCTAssertEqual(l.encryptedData, .withoutIntegrity)
        XCTAssertTrue(l.description.contains("no integrity protection (SED packet, no MDC)"), l.description)
        XCTAssertTrue(l.description.contains("Elgamal"), l.description)
    }

    func testSignedCompressedLiteral_oldAndNewHeaders_signatureNotVerified() throws {
        let ops = Self.newPacket(tag: 4, [3, 0, 10, 22] + Self.keyA + [1])
        let inner = Self.literal(name: "memo.txt", text: "The quarterly numbers are attached.") + Self.signatureV4(issuer: Self.keyA, fingerprint: Self.fingerprint)
        let compressed = Self.oldPacket(tag: 8, [1] + inner, lengthType: 2)   // ZIP compression declared; the body is not inflated, only described
        let s = try OpenPGP.summarize(Data(ops + compressed))
        XCTAssertFalse(s.isEncrypted)
        XCTAssertTrue(s.isSigned)
        XCTAssertEqual(s.onePassSignatures, 1)
        XCTAssertEqual(s.compression, "ZIP")
        XCTAssertEqual(s.packetTags, [4, 8])
        XCTAssertTrue(s.description.contains("signature present, not verified (no OpenPGP trust store)"), s.description)
        XCTAssertTrue(s.description.contains("compressed (ZIP)"), s.description)

        // The same literal and signature uncompressed: issuer, fingerprint, algorithms and time are read.
        let plain = try OpenPGP.summarize(Data(inner))
        XCTAssertEqual(plain.literalFilename, "memo.txt")
        XCTAssertEqual(plain.literalBytes, "The quarterly numbers are attached.".utf8.count)
        XCTAssertEqual(plain.signatures.count, 1)
        let sig = plain.signatures[0]
        XCTAssertEqual(sig.version, 4)
        XCTAssertEqual(sig.type, "binary document")
        XCTAssertEqual(sig.publicKeyAlgorithm, "EdDSA")
        XCTAssertEqual(sig.hashAlgorithm, "SHA-512")
        XCTAssertEqual(sig.issuerKeyID, "DEADBEEF01020304")
        XCTAssertEqual(sig.issuerFingerprint, OpenPGP.hex(Self.fingerprint))
        XCTAssertEqual(sig.created?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertTrue(plain.description.contains("issuer \(OpenPGP.hex(Self.fingerprint))"), plain.description)
        XCTAssertTrue(plain.description.contains("EdDSA/SHA-512"), plain.description)

        let v3 = try OpenPGP.summarize(Data(Self.signatureV3(issuer: Self.keyB)))
        XCTAssertEqual(v3.signatures[0].version, 3)
        XCTAssertEqual(v3.signatures[0].issuerKeyID, "CAFEF00DAABBCCDD")
        XCTAssertEqual(v3.signatures[0].publicKeyAlgorithm, "RSA")
        XCTAssertEqual(v3.signatures[0].hashAlgorithm, "SHA-1")
    }

    func testNewFormatPartialBodyLengths_andLengthForms() throws {
        // Tag 11 literal with partial lengths: 512 bytes, then 256, then a final 10.
        let body: [UInt8] = [UInt8(ascii: "b"), 4] + Array("a.txt".utf8.prefix(4)) + [0, 0, 0, 0] + [UInt8](repeating: 0x61, count: 512 + 256 + 10 - 10)
        var packet: [UInt8] = [0xC0 | 11]
        packet.append(0xE0 | 9); packet += body[0..<512]           // 1 << 9
        packet.append(0xE0 | 8); packet += body[512..<768]         // 1 << 8
        packet.append(UInt8(body.count - 768)); packet += body[768...]
        let packets = try OpenPGP.packets(in: Data(packet))
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].tag, 11)
        XCTAssertTrue(packets[0].indeterminateLength)
        XCTAssertEqual(packets[0].body.count, body.count)
        // Two-octet and five-octet new-format lengths, and old-format one/two/four-octet lengths.
        let big = [UInt8](repeating: 0x20, count: 9_000)
        XCTAssertEqual(try OpenPGP.packets(in: Data(Self.newPacket(tag: 11, [UInt8](repeating: 1, count: 300))))[0].body.count, 300)
        XCTAssertEqual(try OpenPGP.packets(in: Data(Self.newPacket(tag: 11, big)))[0].body.count, 9_000)
        XCTAssertEqual(try OpenPGP.packets(in: Data(Self.oldPacket(tag: 11, [1, 2, 3], lengthType: 0)))[0].body.count, 3)
        XCTAssertEqual(try OpenPGP.packets(in: Data(Self.oldPacket(tag: 11, big, lengthType: 2)))[0].body.count, 9_000)
        // Truncation and non-PGP bytes are refused, never read as something else.
        XCTAssertThrowsError(try OpenPGP.packets(in: Data(Self.newPacket(tag: 1, [3] + Self.keyA).dropLast(3))))
        XCTAssertThrowsError(try OpenPGP.summarize(Data("plain text, no armor".utf8))) { XCTAssertNotNil($0 as? OpenPGP.ParseError) }
        XCTAssertThrowsError(try OpenPGP.summarize(Data([0x50, 0x4B, 0x03, 0x04])))
    }

    func testKeyBlock_isDescribedAsKeyMaterial_notText() throws {
        let pub = Self.newPacket(tag: 6, [4, 0, 0, 0, 0, 22, 9] + [UInt8](repeating: 0x2A, count: 33))
        let uid = Self.newPacket(tag: 13, Array("Ann Example <ann@example.org>".utf8))
        let s = try OpenPGP.summarize(Data(pub + uid + Self.signatureV4(issuer: Self.keyA, fingerprint: Self.fingerprint)))
        XCTAssertTrue(s.isKeyMaterial)
        XCTAssertEqual(s.publicKeys, 1)
        XCTAssertEqual(s.userIDs, ["Ann Example <ann@example.org>"])
        let url = try writeText("ann.asc", OpenPGP.armor(Data(pub + uid), type: "PGP PUBLIC KEY BLOCK"))
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .pgp)) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .noTextParts) }
    }

    // MARK: Armor

    func testArmor_roundTrip_CRC24_andDamageDetected() throws {
        let bytes = Self.pkesk(keyID: Self.keyA, algorithm: 1) + Self.seipdV1
        let text = OpenPGP.armor(Data(bytes), type: "PGP MESSAGE")
        XCTAssertTrue(text.hasPrefix("-----BEGIN PGP MESSAGE-----\n"))
        let armor = try OpenPGP.dearmor(text)
        XCTAssertEqual(armor.type, "PGP MESSAGE")
        XCTAssertEqual(Array(armor.data), bytes)
        XCTAssertEqual(armor.crcVerified, true)
        XCTAssertEqual(armor.headers["Version"], "mailin test")
        // RFC 4880 §6.1 test value: CRC-24 of the empty string is the initial value.
        XCTAssertEqual(OpenPGP.crc24(Data()), 0xB704CE)
        // One flipped base64 character: the CRC catches it.
        var damaged = text
        let range = damaged.range(of: "\n\n")!.upperBound
        let idx = damaged.index(range, offsetBy: 5)
        damaged.replaceSubrange(idx...idx, with: damaged[idx] == "A" ? "B" : "A")
        XCTAssertThrowsError(try OpenPGP.dearmor(damaged)) { XCTAssertEqual($0 as? OpenPGP.ParseError, .crcMismatch) }
        // Without a CRC line (RFC 9580) the block is still read; crcVerified is nil.
        let noCRC = text.components(separatedBy: "\n").filter { !($0.hasPrefix("=") && $0.count == 5) }.joined(separator: "\n")
        XCTAssertNil(try OpenPGP.dearmor(noCRC).crcVerified)

        let s = try OpenPGP.summarize(Data(text.utf8))
        XCTAssertEqual(s.armorType, "PGP MESSAGE")
        XCTAssertEqual(s.recipients.first?.keyID, "DEADBEEF01020304")
        XCTAssertTrue(s.description.hasSuffix("ASCII armor “PGP MESSAGE”, CRC-24 verified"), s.description)
    }

    func testClearsignedMessage_textIsReadAndSignatureNoted() throws {
        let sig = OpenPGP.armor(Data(Self.signatureV4(issuer: Self.keyB, fingerprint: Self.fingerprint)), type: "PGP SIGNATURE", headers: [:])
        let clear = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA512

        Dear all,
        - -- the dash-escaped line stays a line starting with two dashes
        The board meets on Monday.
        \(sig)
        """
        let armor = try OpenPGP.dearmor(clear)
        XCTAssertEqual(armor.type, "PGP SIGNED MESSAGE")
        XCTAssertEqual(armor.clearTextHash, "SHA512")
        XCTAssertEqual(armor.clearText, "Dear all,\n-- the dash-escaped line stays a line starting with two dashes\nThe board meets on Monday.")
        let s = try OpenPGP.summarize(Data(clear.utf8))
        XCTAssertTrue(s.isSigned)
        XCTAssertFalse(s.isEncrypted)
        XCTAssertEqual(s.signatures.first?.issuerKeyID, "CAFEF00DAABBCCDD")

        let url = try writeText("notice.asc", clear)
        let r = try DocumentTextExtractor.extract(fileURL: url, kind: .pgp)
        XCTAssertTrue(r.text.contains("The board meets on Monday."))
        XCTAssertEqual(r.components, ["Signed text"])
        XCTAssertTrue(r.skipped.first?.contains("signature present, not verified (no OpenPGP trust store)") == true, r.skipped.description)
        XCTAssertTrue(r.partial, "a signed text whose signature is unverified is partial, with the reason")
    }

    // MARK: Mail

    func testPGPMIME_encryptedAndSigned_classifiedFromContentType() throws {
        let encrypted = """
        From: ann@example.org\r
        To: bob@example.org\r
        Subject: ...\r
        MIME-Version: 1.0\r
        Content-Type: multipart/encrypted; boundary="b1"; protocol="application/pgp-encrypted"\r
        \r
        --b1\r
        Content-Type: application/pgp-encrypted\r
        \r
        Version: 1\r
        --b1\r
        Content-Type: application/octet-stream; name="encrypted.asc"\r
        \r
        \(OpenPGP.armor(Data(Self.pkesk(keyID: Self.keyA, algorithm: 1) + Self.seipdV1), type: "PGP MESSAGE").replacingOccurrences(of: "\n", with: "\r\n"))\
        --b1--\r

        """
        let (headers, parts) = MIMEParser.parseEmail(rawEmail: encrypted)
        XCTAssertEqual(OpenPGP.mailKind(contentType: headers["content-type"] ?? headers["Content-Type"] ?? ""), .pgpMIMEEncrypted)
        let root = MIMEPart(headers: headers, mimeType: "multipart/encrypted", subparts: parts)
        XCTAssertEqual(OpenPGP.mailKind(root: root), .pgpMIMEEncrypted)
        // The encrypted.asc part is the OpenPGP payload: described, locked, never decrypted.
        let payload = try XCTUnwrap(parts.first { ($0.filename ?? "").hasSuffix(".asc") || $0.body.contains("BEGIN PGP MESSAGE") })
        let s = try OpenPGP.summarize(Data(payload.body.utf8))
        XCTAssertEqual(s.recipients.first?.keyID, "DEADBEEF01020304")
        XCTAssertTrue(s.isEncrypted)
        XCTAssertTrue(OpenPGP.isOpenPGPAttachment(mimeType: "application/octet-stream", filename: "encrypted.asc"))
        XCTAssertTrue(OpenPGP.isOpenPGPAttachment(mimeType: "application/pgp-encrypted", filename: "x"))
        XCTAssertFalse(OpenPGP.isOpenPGPAttachment(mimeType: "application/pdf", filename: "report.pdf"))

        XCTAssertEqual(OpenPGP.mailKind(contentType: "multipart/signed; micalg=pgp-sha256; protocol=\"application/pgp-signature\"; boundary=\"x\""), .pgpMIMESigned)
        XCTAssertEqual(OpenPGP.mailKind(contentType: "multipart/signed; protocol=\"application/pkcs7-signature\""), nil, "S/MIME is not OpenPGP")
        XCTAssertEqual(OpenPGP.mailKind(contentType: "text/plain", body: "Hello\n-----BEGIN PGP MESSAGE-----\n..."), .inlineEncrypted)
        XCTAssertEqual(OpenPGP.mailKind(contentType: "text/plain", body: "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\nhi"), .inlineSigned)
        XCTAssertNil(OpenPGP.mailKind(contentType: "text/plain", body: "ordinary mail"))
    }

    func testInlinePGP_inTextBody_classifiedFromTheMIMETree() throws {
        let inline = """
        From: ann@example.org\r
        Subject: inline\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(OpenPGP.armor(Data(Self.skesk(cipher: 7) + Self.seipdV1), type: "PGP MESSAGE").replacingOccurrences(of: "\n", with: "\r\n"))
        """
        let (headers, parts) = MIMEParser.parseEmail(rawEmail: inline)
        let root = MIMEPart(headers: headers, body: parts.first?.body ?? "", mimeType: "text/plain", subparts: parts)
        XCTAssertEqual(OpenPGP.mailKind(root: root), .inlineEncrypted)
        let s = try OpenPGP.summarize(Data((parts.first?.body ?? "").utf8))
        XCTAssertEqual(s.symmetricSessionKeys, ["AES-128"])
    }
}
