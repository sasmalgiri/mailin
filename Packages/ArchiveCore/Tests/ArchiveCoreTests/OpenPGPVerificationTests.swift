//
//  OpenPGPVerificationTests.swift
//  ArchiveCoreTests
//
//  GAP-PGP (owner decision 2026-11-07): public keys imported into an
//  on-device keyring; signatures verified good / bad / unknown key /
//  cannot verify. Fixtures are written by implementations independent of
//  this code (Fixtures/openpgp/MANIFEST.txt):
//
//    rfc9580/    RFC 9580 Appendix A: the v4 Ed25519Legacy key and signature,
//                the v6 Ed25519 certificate, cleartext and inline-signed message
//    pgpy/       PGPy 0.6.0 (pure-Python OpenPGP on pyca/cryptography):
//                RSA 3072 (+ RSA signing subkey), EdDSA Ed25519, ECDSA
//                P-256/P-384/P-521 keys; detached, cleartext, inline (plain,
//                ZIP, ZLIB) signatures; expired and revoked keys; PGP/MIME mail
//    gnupg-org/  GnuPG's own release-signing keys and a GnuPG-made detached
//                signature of swdb.lst, as published on gnupg.org
//

import XCTest
import Foundation
@testable import ArchiveCore

final class OpenPGPVerificationTests: XCTestCase {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/openpgp", isDirectory: true)

    func fixture(_ path: String) throws -> Data { try Data(contentsOf: Self.root.appendingPathComponent(path)) }

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgpv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    func keyring(_ keys: String...) throws -> OpenPGPKeyring {
        let ring = OpenPGPKeyring(fileURL: nil)
        for k in keys {
            let result = try ring.importKeys(data: try fixture(k))
            XCTAssertEqual(result.imported.count, 1, "\(k): \(result.rejected)")
        }
        return ring
    }

    func good(_ verdict: OpenPGPVerdict?, file: StaticString = #filePath, line: UInt = #line) -> OpenPGPVerdict.Good? {
        guard case .good(let g)? = verdict else { XCTFail("expected good, got \(String(describing: verdict?.description))", file: file, line: line); return nil }
        return g
    }

    static let fingerprints = [
        "rsa3072": "DCC9E1C1B678123C596A4F2BE476BE48C98B2CF4",
        "ed25519": "73BFAF48F14347B5D6A3A2A3F254F06911C009EF",
        "nistp256": "CD9AFC70394341A74B5E209DF451415C9CB38C38",
        "nistp384": "5ABA8B6B4B53BB9FB501B6EEF732B0D6F821765A",
        "nistp521": "503E6132170427B6B546DD6E9E4333C327574EEB",
    ]
    static let algorithms = ["rsa3072": "RSA 3072", "ed25519": "EdDSA (Ed25519)", "nistp256": "ECDSA P-256", "nistp384": "ECDSA P-384", "nistp521": "ECDSA P-521"]

    // MARK: RFC 9580 Appendix A (second, independent source)

    func testRFC9580_v4Ed25519Legacy_sampleKeyAndSignature() throws {
        let keyPackets = try OpenPGP.packets(in: OpenPGP.dearmor(String(decoding: try fixture("rfc9580/A1-v4-ed25519legacy.pub.asc"), as: UTF8.self)).data)
        let key = try OpenPGPPublicKeyPacket(body: [UInt8](keyPackets[0].body))
        XCTAssertEqual(key.fingerprintHex, "C959BDBAFA32A2F89A153B678CFDE12197965A9A")
        XCTAssertEqual(key.algorithmDescription, "EdDSA (Ed25519)")
        let sigPackets = try OpenPGP.packets(in: OpenPGP.dearmor(String(decoding: try fixture("rfc9580/A2-v4-ed25519legacy-OpenPGP.sig.asc"), as: UTF8.self)).data)
        let sig = try OpenPGPSignaturePacket(body: [UInt8](sigPackets[0].body))
        XCTAssertEqual(OpenPGPSignatureMath.check(sig, over: [Array("OpenPGP".utf8)], key: key), .valid)
        if case .invalid = OpenPGPSignatureMath.check(sig, over: [Array("OpenPGQ".utf8)], key: key) {} else { XCTFail("one changed byte must be invalid") }
        // The bare key has no self-signature: the keyring refuses it, with the reason.
        let ring = OpenPGPKeyring(fileURL: nil)
        let result = try ring.importKeys(data: try fixture("rfc9580/A1-v4-ed25519legacy.pub.asc"))
        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertTrue(result.rejected.first?.contains("no self-signature") == true, result.rejected.description)
    }

    func testRFC9580_v6Certificate_cleartextAndInlineSignedMessages() throws {
        let ring = OpenPGPKeyring(fileURL: nil)
        let result = try ring.importKeys(data: try fixture("rfc9580/A3-v6-certificate.pub.asc"))
        XCTAssertEqual(result.imported.map(\.fingerprint), ["CB186C4F0609A697E4D52DFA6C722B0C1F1E27C18A56708F6525EC27BAD9ACC9"], result.rejected.description)
        XCTAssertEqual(result.imported.first?.algorithm, "Ed25519")
        XCTAssertEqual(result.imported.first?.subkeys.first?.hasPrefix("12C83F1E706F6308FE151A417743A1F033790E93E9978488D1DB378DA9930885"), true)

        let clear = try OpenPGP.summarize(try fixture("rfc9580/A6-cleartext-signed.asc"), keyring: ring)
        let g = try XCTUnwrap(good(clear.verdicts.first))
        XCTAssertEqual(g.fingerprint, "CB186C4F0609A697E4D52DFA6C722B0C1F1E27C18A56708F6525EC27BAD9ACC9")
        XCTAssertEqual(g.hash, "SHA-512")
        XCTAssertEqual(g.signedAt, ISO8601DateFormatter().date(from: "2022-12-13T16:08:03Z"))
        XCTAssertTrue(clear.description.contains("good signature from (key CB186C4F"), clear.description)

        let inline = try OpenPGP.summarize(try fixture("rfc9580/A7-inline-signed.asc"), keyring: ring)
        XCTAssertNotNil(good(inline.verdicts.first))

        // One changed letter in the signed text → BAD.
        let tampered = String(decoding: try fixture("rfc9580/A6-cleartext-signed.asc"), as: UTF8.self).replacingOccurrences(of: "tofu", with: "tofx")
        let bad = try OpenPGP.summarize(Data(tampered.utf8), keyring: ring)
        XCTAssertTrue(bad.verdicts.first?.isBad == true, bad.description)
        XCTAssertTrue(bad.description.hasPrefix("BAD signature by key CB186C4F"), bad.description)
        // Trailing spaces are not signed (RFC 9580 §7): adding some keeps it good.
        let spaced = String(decoding: try fixture("rfc9580/A6-cleartext-signed.asc"), as: UTF8.self).replacingOccurrences(of: "- - tofu", with: "- - tofu  \t")
        XCTAssertNotNil(good(try OpenPGP.summarize(Data(spaced.utf8), keyring: ring).verdicts.first))
        // Without the key: unknown key, named by its fingerprint.
        let unknown = try OpenPGP.summarize(try fixture("rfc9580/A6-cleartext-signed.asc"), keyring: OpenPGPKeyring(fileURL: nil))
        XCTAssertEqual(unknown.verdicts, [.unknownKey(issuer: "CB186C4F0609A697E4D52DFA6C722B0C1F1E27C18A56708F6525EC27BAD9ACC9")])
        XCTAssertTrue(unknown.description.contains("signature by unknown key CB186C4F0609A697E4D52DFA6C722B0C1F1E27C18A56708F6525EC27BAD9ACC9"), unknown.description)
    }

    // MARK: Detached signatures, every algorithm (PGPy)

    func testDetached_goodForEachAlgorithm_badOnOneFlippedByte_unknownWithoutKey() throws {
        let memo = try fixture("pgpy/memo.txt")
        var flipped = memo
        flipped[5] ^= 0x01
        for (name, fp) in Self.fingerprints.sorted(by: { $0.key < $1.key }) {
            let ring = try keyring("pgpy/\(name).pub.asc")
            XCTAssertEqual(ring.list().first?.fingerprint, fp, name)
            XCTAssertEqual(ring.list().first?.algorithm, Self.algorithms[name], name)
            for ext in ["sig", "asc"] {
                let sig = try fixture("pgpy/memo.txt.\(name).\(ext)")
                let s = try OpenPGP.summarize(sig, keyring: ring, signedData: memo)
                let g = try XCTUnwrap(good(s.verdicts.first), "\(name).\(ext)")
                XCTAssertEqual(g.fingerprint, fp)
                XCTAssertEqual(g.algorithm, Self.algorithms[name])
                XCTAssertNotNil(g.userID)
                XCTAssertNil(g.keyExpiredOn)
                XCTAssertNil(g.revocation)
                XCTAssertTrue(s.description.hasPrefix("good signature from “"), s.description)

                let b = try OpenPGP.summarize(sig, keyring: ring, signedData: flipped)
                XCTAssertTrue(b.verdicts.first?.isBad == true, "\(name).\(ext): \(b.description)")
            }
            // A flipped byte in the signature's own MPI also fails (not only the quick check).
            var sigBytes = [UInt8](try fixture("pgpy/memo.txt.\(name).sig"))
            sigBytes[sigBytes.count - 3] ^= 0x40
            let b = try OpenPGP.summarize(Data(sigBytes), keyring: ring, signedData: memo)
            XCTAssertTrue(b.verdicts.first?.isBad == true, "\(name) MPI flip: \(b.description)")

            let unknown = try OpenPGP.summarize(try fixture("pgpy/memo.txt.\(name).sig"), keyring: OpenPGPKeyring(fileURL: nil), signedData: memo)
            guard case .unknownKey(let issuer)? = unknown.verdicts.first else { return XCTFail("\(name): \(unknown.description)") }
            XCTAssertEqual(issuer, fp)
        }
    }

    func testDetached_rsaSHA512_andSigningSubkey() throws {
        let ring = try keyring("pgpy/rsa3072.pub.asc")
        let memo = try fixture("pgpy/memo.txt")
        let g = try XCTUnwrap(good(try OpenPGP.summarize(try fixture("pgpy/memo.txt.rsa3072-sha512.sig"), keyring: ring, signedData: memo).verdicts.first))
        XCTAssertEqual(g.hash, "SHA-512")
        let sub = try XCTUnwrap(good(try OpenPGP.summarize(try fixture("pgpy/memo.txt.rsa3072-subkey.sig"), keyring: ring, signedData: memo).verdicts.first))
        XCTAssertEqual(sub.fingerprint, Self.fingerprints["rsa3072"])
        XCTAssertEqual(sub.subkeyFingerprint, "891F9AC482DC979D3763AA926329678DF650EEAB")
        XCTAssertEqual(sub.algorithm, "RSA 2048")
    }

    func testDetached_signedFileIsTheSiblingOfTheSameNameMinusTheExtension() throws {
        let previous = OpenPGPKeyring.active
        defer { OpenPGPKeyring.active = previous }
        OpenPGPKeyring.active = try keyring("pgpy/ed25519.pub.asc")
        XCTAssertEqual(OpenPGP.signedFileName(forDetachedSignature: "memo.txt.sig"), "memo.txt")
        XCTAssertEqual(OpenPGP.signedFileName(forDetachedSignature: "memo.txt.asc"), "memo.txt")
        XCTAssertNil(OpenPGP.signedFileName(forDetachedSignature: "memo.txt"))
        XCTAssertNil(OpenPGP.signedFileName(forDetachedSignature: ".sig"))

        // With the sibling's bytes (the active keyring is used by default): good.
        let withSibling = try OpenPGP.summarize(try fixture("pgpy/memo.txt.ed25519.sig"), signedData: try fixture("pgpy/memo.txt"))
        XCTAssertNotNil(good(withSibling.verdicts.first))
        // Without it: the key is known, the data is not here — said so, never "good" or "bad".
        let without = try OpenPGP.summarize(try fixture("pgpy/memo.txt.ed25519.sig"))
        XCTAssertEqual(without.verdicts.count, 1)
        XCTAssertEqual(without.description, "signature cannot be verified: the signed data is not with the signature (key \(Self.fingerprints["ed25519"]!) is in the keyring)")
    }

    // MARK: Cleartext and inline (PGPy)

    func testCleartextSigned_goodBadAndForeignArmorHeader() throws {
        for name in ["rsa3072", "ed25519", "nistp256"] {
            let ring = try keyring("pgpy/\(name).pub.asc")
            let text = String(decoding: try fixture("pgpy/clearsigned.\(name).asc"), as: UTF8.self)
            let s = try OpenPGP.summarize(Data(text.utf8), keyring: ring)
            XCTAssertEqual(try XCTUnwrap(good(s.verdicts.first), name).fingerprint, Self.fingerprints[name])
            XCTAssertEqual(s.clearText, "Dear all,\n-- this line starts with two dashes\nThe board meets on Monday.\n")
            // CRLF storage (as mail stores it) signs the same text.
            XCTAssertNotNil(good(try OpenPGP.summarize(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8), keyring: ring).verdicts.first), name)
            let tampered = text.replacingOccurrences(of: "Monday", with: "Friday")
            XCTAssertTrue(try OpenPGP.summarize(Data(tampered.utf8), keyring: ring).verdicts.first?.isBad == true, name)
            // RFC 9580 §7.1: an armor header other than Hash: in the signed part → declined, never "good".
            let foreign = text.replacingOccurrences(of: "Hash: SHA256\n", with: "Hash: SHA256\nComment: trust me\n")
            let declined = try OpenPGP.summarize(Data(foreign.utf8), keyring: ring)
            guard case .cannotVerify(let why)? = declined.verdicts.first else { return XCTFail(declined.description) }
            XCTAssertTrue(why.contains("Comment: trust me"), why)
        }
        // Through the document facade: the text is read, and a good signature makes the reading complete.
        let previous = OpenPGPKeyring.active
        defer { OpenPGPKeyring.active = previous }
        OpenPGPKeyring.active = try keyring("pgpy/ed25519.pub.asc")
        let url = dir.appendingPathComponent("notice.asc")
        try fixture("pgpy/clearsigned.ed25519.asc").write(to: url)
        let r = try DocumentTextExtractor.extract(fileURL: url, kind: .pgp)
        XCTAssertTrue(r.text.contains("The board meets on Monday."))
        XCTAssertFalse(r.partial, r.skipped.description)
        XCTAssertTrue(r.notText.first?.hasPrefix("good signature from “Ed Legacy <ed@example.org>”") == true, r.notText.description)
    }

    func testInlineSigned_plainZIPAndZLIB() throws {
        for (name, compression) in [("ed25519", nil), ("rsa3072", "ZIP"), ("nistp256", "ZLIB")] as [(String, String?)] {
            let ring = try keyring("pgpy/\(name).pub.asc")
            for ext in ["gpg", "asc"] {
                let s = try OpenPGP.summarize(try fixture("pgpy/inline.\(name).\(ext)"), keyring: ring)
                XCTAssertEqual(s.compression, compression, name)
                XCTAssertEqual(try XCTUnwrap(good(s.verdicts.first), "\(name).\(ext)").fingerprint, Self.fingerprints[name])
                XCTAssertEqual(s.literalBytes, try fixture("pgpy/memo.txt").count)
            }
            // The text is read through the facade.
            let url = dir.appendingPathComponent("inline-\(name).gpg")
            try fixture("pgpy/inline.\(name).gpg").write(to: url)
            let r = try DocumentTextExtractor.extract(fileURL: url, kind: .pgp)
            XCTAssertTrue(r.text.contains("The numbers are final."), name)
        }
        // A byte changed inside the uncompressed literal data → BAD.
        let ring = try keyring("pgpy/ed25519.pub.asc")
        var bytes = [UInt8](try fixture("pgpy/inline.ed25519.gpg"))
        let memo = [UInt8](try fixture("pgpy/memo.txt"))
        let at = try XCTUnwrap(bytes.indices.first { Array(bytes[$0..<min(bytes.count, $0 + memo.count)]) == memo })
        bytes[at + 2] ^= 0x20
        XCTAssertTrue(try OpenPGP.summarize(Data(bytes), keyring: ring).verdicts.first?.isBad == true)
    }

    // MARK: PGP/MIME (RFC 3156)

    func testPGPMIME_signedEntityFromTheRawMessage() throws {
        for name in ["ed25519", "rsa3072"] {
            let ring = try keyring("pgpy/\(name).pub.asc")
            let raw = try fixture("pgpy/pgpmime.\(name).eml")
            let verdicts = try XCTUnwrap(OpenPGP.verifyPGPMIME(rawMessage: raw, keyring: ring))
            XCTAssertEqual(try XCTUnwrap(good(verdicts.first), name).fingerprint, Self.fingerprints[name])
            // Stored with LF line endings (mbox): the entity is canonicalised back to CRLF.
            let lf = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            XCTAssertNotNil(good(OpenPGP.verifyPGPMIME(rawMessage: lf, keyring: ring)?.first), name)
            // The body changed after signing → BAD.
            let changed = lf.replacingOccurrences(of: "attached in spirit", with: "attached in sprit")
            XCTAssertTrue(OpenPGP.verifyPGPMIME(rawMessage: changed, keyring: ring)?.first?.isBad == true, name)
            // A header of the signed part changed → BAD (the part's headers are signed too).
            let header = lf.replacingOccurrences(of: "charset=utf-8", with: "charset=us-ascii")
            XCTAssertTrue(OpenPGP.verifyPGPMIME(rawMessage: header, keyring: ring)?.first?.isBad == true, name)
            // No key → unknown key.
            guard case .unknownKey? = OpenPGP.verifyPGPMIME(rawMessage: raw, keyring: OpenPGPKeyring(fileURL: nil))?.first else { return XCTFail(name) }
        }
        XCTAssertNil(OpenPGP.verifyPGPMIME(rawMessage: "From: a@b\r\nContent-Type: text/plain\r\n\r\nhello\r\n"))
    }

    // MARK: Keys: self-signatures, expiry, revocation

    func testTamperedSelfSignature_keyRejectedWithTheReason() throws {
        let armor = try OpenPGP.dearmor(String(decoding: try fixture("pgpy/ed25519.pub.asc"), as: UTF8.self))
        var packets = try OpenPGP.packets(in: armor.data)
        let uidIndex = try XCTUnwrap(packets.firstIndex { $0.tag == 13 })
        packets[uidIndex] = OpenPGP.Packet(tag: 13, body: Data("Mallory <ed@example.org>".utf8), newFormat: true, indeterminateLength: false)
        let forged = Data(packets.flatMap { OpenPGPTransferableKey.encode($0) })
        let ring = OpenPGPKeyring(fileURL: nil)
        let result = try ring.importKeys(data: forged)
        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
        XCTAssertTrue(result.rejected[0].contains("self-signature on “Mallory <ed@example.org>” does not verify"), result.rejected[0])
        XCTAssertTrue(result.rejected[0].contains("the key was altered or damaged"), result.rejected[0])
        XCTAssertTrue(ring.isEmpty)
        // Described as a key block, the same verdict.
        let s = try OpenPGP.summarize(forged, keyring: ring)
        XCTAssertTrue(s.description.contains("public key rejected: key \(Self.fingerprints["ed25519"]!)"), s.description)
        // The genuine key block is described as verified, and whether it is in the keyring.
        let genuine = try OpenPGP.summarize(try fixture("pgpy/ed25519.pub.asc"), keyring: ring)
        XCTAssertTrue(genuine.description.contains("public key \(Self.fingerprints["ed25519"]!) “Ed Legacy <ed@example.org>”: self-signature verified, not in the keyring"), genuine.description)
    }

    func testExpiredKey_statedAtTheSignatureTime() throws {
        let ring = try keyring("pgpy/expired.pub.asc")
        let summary = try XCTUnwrap(ring.list().first)
        XCTAssertEqual(summary.expires, ISO8601DateFormatter().date(from: "2020-01-02T00:00:00Z"))
        XCTAssertTrue(summary.description.contains("expired 2020-01-02"), summary.description)
        let memo = try fixture("pgpy/memo.txt")
        let within = try XCTUnwrap(good(try OpenPGP.summarize(try fixture("pgpy/memo.txt.expired-within.sig"), keyring: ring, signedData: memo).verdicts.first))
        XCTAssertNil(within.keyExpiredOn, "signed while the key was valid")
        let after = try OpenPGP.summarize(try fixture("pgpy/memo.txt.expired-after.sig"), keyring: ring, signedData: memo)
        XCTAssertNotNil(try XCTUnwrap(good(after.verdicts.first)).keyExpiredOn)
        XCTAssertTrue(after.description.contains("the key had expired on 2020-01-02 when it signed"), after.description)
    }

    func testRevokedKey_beforeAndAfterTheRevocation_andReimportMerges() throws {
        let memo = try fixture("pgpy/memo.txt")
        // First the key as it was before the revocation (the 0x20 signature left out) …
        let armor = try OpenPGP.dearmor(String(decoding: try fixture("pgpy/revoked.pub.asc"), as: UTF8.self))
        let packets = try OpenPGP.packets(in: armor.data)
        let unrevoked = packets.filter { !($0.tag == 2 && $0.body.count > 1 && [UInt8]($0.body)[1] == 0x20) }
        XCTAssertEqual(unrevoked.count, packets.count - 1)
        let ring = OpenPGPKeyring(fileURL: dir.appendingPathComponent("ring/public-keyring.pgp"))
        XCTAssertEqual(try ring.importKeys(data: Data(unrevoked.flatMap { OpenPGPTransferableKey.encode($0) })).imported.count, 1)
        XCTAssertNil(try XCTUnwrap(good(try OpenPGP.summarize(try fixture("pgpy/memo.txt.revoked-after.sig"), keyring: ring, signedData: memo).verdicts.first)).revocation)
        // … then the published revocation: merged into the same key.
        let update = try ring.importKeys(data: try fixture("pgpy/revoked.pub.asc"))
        XCTAssertEqual(update.imported.count, 0)
        XCTAssertEqual(update.updated.count, 1)
        XCTAssertEqual(update.updated.first?.revocation?.code, 1)
        XCTAssertEqual(update.updated.first?.revocation?.text, "replaced by a new key")
        XCTAssertEqual(ring.list().count, 1)

        let before = try OpenPGP.summarize(try fixture("pgpy/memo.txt.revoked-before.sig"), keyring: ring, signedData: memo)
        let b = try XCTUnwrap(good(before.verdicts.first))
        XCTAssertFalse(b.madeAfterRevocation)
        XCTAssertTrue(before.description.contains("(superseded: replaced by a new key), after this signature was made"), before.description)
        let after = try OpenPGP.summarize(try fixture("pgpy/memo.txt.revoked-after.sig"), keyring: ring, signedData: memo)
        XCTAssertTrue(try XCTUnwrap(good(after.verdicts.first)).madeAfterRevocation)
        XCTAssertTrue(after.description.contains("WARNING: the key was revoked on"), after.description)
        XCTAssertTrue(after.description.contains("this signature was made after the revocation"), after.description)
    }

    // MARK: Keyring storage

    func testKeyring_persistsAtomically_reopens_removes() throws {
        let url = OpenPGPKeyring.fileURL(underArchiveRoot: dir)
        XCTAssertEqual(url.path, dir.appendingPathComponent("openpgp/public-keyring.pgp").path)
        let ring = OpenPGPKeyring(fileURL: url)
        XCTAssertTrue(ring.isEmpty)
        // Several keys in one armored file are all imported.
        let bundle = Data((try ["rsa3072", "ed25519", "nistp256"].map { String(decoding: try fixture("pgpy/\($0).pub.asc"), as: UTF8.self) }).joined(separator: "\n").utf8)
        let result = try ring.importKeys(data: bundle)
        XCTAssertEqual(result.imported.map(\.fingerprint), ["rsa3072", "ed25519", "nistp256"].map { Self.fingerprints[$0]! })
        XCTAssertEqual(result.imported.first?.primaryUserID, "Rhea RSA <rhea@example.org>")
        // Importing again changes nothing and reports them as already present.
        let again = try ring.importKeys(data: bundle)
        XCTAssertEqual(again.imported.count, 0)
        XCTAssertEqual(again.updated.count, 3)

        let reopened = OpenPGPKeyring(fileURL: url)
        XCTAssertEqual(reopened.list(), ring.list())
        XCTAssertTrue(reopened.loadProblems.isEmpty)
        // The stored file is binary transferable public keys — no secret material, readable as packets.
        let stored = try OpenPGP.packets(in: Data(contentsOf: url))
        XCTAssertFalse(stored.contains { $0.tag == 5 || $0.tag == 7 })

        XCTAssertTrue(try reopened.remove(fingerprint: "CD9A FC70 3943 41A7 4B5E  209D F451 415C 9CB3 8C38"))
        XCTAssertFalse(try reopened.remove(fingerprint: Self.fingerprints["nistp256"]!))
        XCTAssertEqual(OpenPGPKeyring(fileURL: url).list().map(\.fingerprint), ["rsa3072", "ed25519"].map { Self.fingerprints[$0]! })

        // A verdict follows the keyring: removed key → unknown key on the next description.
        let memo = try fixture("pgpy/memo.txt")
        guard case .unknownKey? = try OpenPGP.summarize(try fixture("pgpy/memo.txt.nistp256.sig"), keyring: reopened, signedData: memo).verdicts.first else { return XCTFail() }
    }

    func testSecretKeysAndNonKeysAreRefused() throws {
        // A secret-key packet (tag 5) is never imported, whatever follows it.
        let ring = OpenPGPKeyring(fileURL: nil)
        let secret = OpenPGPTransferableKey.encode(OpenPGP.Packet(tag: 5, body: Data([4, 0, 0, 0, 0, 22] + [UInt8](repeating: 1, count: 40)), newFormat: true, indeterminateLength: false))
        let result = try ring.importKeys(data: Data(secret))
        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertTrue(result.rejected.first?.contains("secret key packet(s) not imported — mailin keeps public keys only") == true, result.rejected.description)
        XCTAssertThrowsError(try ring.importKeys(data: Data("not a key at all".utf8)))
        XCTAssertThrowsError(try ring.importKeys(data: Data()))
        XCTAssertTrue(ring.isEmpty)
    }

    func testUnsupportedAlgorithmAndHash_areCannotVerify_neverBad() throws {
        // A DSA key (algorithm 17) with a user ID: refused with the algorithm named.
        let dsa = OpenPGPTransferableKey.encode(OpenPGP.Packet(tag: 6, body: Data([4, 0x5F, 0, 0, 0, 17] + [0, 8, 0xFF] + [0, 8, 0xFF] + [0, 8, 0xFF] + [0, 8, 0xFF]), newFormat: true, indeterminateLength: false))
            + OpenPGPTransferableKey.encode(OpenPGP.Packet(tag: 13, body: Data("Dee <dsa@example.org>".utf8), newFormat: true, indeterminateLength: false))
        let r = try OpenPGPKeyring(fileURL: nil).importKeys(data: Data(dsa))
        XCTAssertTrue(r.rejected.first?.contains("algorithm DSA not supported") == true, r.rejected.description)

        // A known key's signature that names SHA-224: "cannot verify", not "bad".
        let ring = try keyring("pgpy/ed25519.pub.asc")
        var sig = [UInt8](try OpenPGP.packets(in: try fixture("pgpy/memo.txt.ed25519.sig"))[0].body)
        sig[3] = 11
        let packet = OpenPGPTransferableKey.encode(OpenPGP.Packet(tag: 2, body: Data(sig), newFormat: true, indeterminateLength: false))
        let s = try OpenPGP.summarize(Data(packet), keyring: ring, signedData: try fixture("pgpy/memo.txt"))
        XCTAssertEqual(s.verdicts, [.cannotVerify(reason: "hash SHA-224 not supported")])
        XCTAssertEqual(s.description, "signature cannot be verified: hash SHA-224 not supported")
    }

    // MARK: GnuPG-written (gnupg.org)

    func testGnuPGOrg_releaseKeysAndADetachedSignatureMadeByGnuPG() throws {
        let ring = OpenPGPKeyring(fileURL: nil)
        let result = try ring.importKeys(data: try fixture("gnupg-org/gnupg_signature_key.asc"))
        XCTAssertGreaterThanOrEqual(result.imported.count, 1, result.rejected.description)
        for key in result.imported { XCTAssertNotNil(key.primaryUserID, key.fingerprint) }
        let s = try OpenPGP.summarize(try fixture("gnupg-org/swdb.lst.sig"), keyring: ring, signedData: try fixture("gnupg-org/swdb.lst"))
        XCTAssertFalse(s.verdicts.isEmpty)
        for v in s.verdicts { XCTAssertNotNil(good(v), s.description) }
        var changed = try fixture("gnupg-org/swdb.lst")
        changed[10] ^= 0x01
        XCTAssertTrue(try OpenPGP.summarize(try fixture("gnupg-org/swdb.lst.sig"), keyring: ring, signedData: changed).verdicts.allSatisfy(\.isBad))
    }

    // MARK: Malformed input

    func testMalformedInput_neverCrashes_andIsNeverGood() throws {
        let ring = try keyring("pgpy/rsa3072.pub.asc")
        try OpenPGPKeyring(fileURL: nil).importKeys(data: try fixture("pgpy/ed25519.pub.asc"))
        let memo = try fixture("pgpy/memo.txt")
        let names = ["pgpy/memo.txt.rsa3072.sig", "pgpy/rsa3072.pub.asc", "pgpy/inline.rsa3072.gpg", "pgpy/inline.nistp256.gpg",
                     "rfc9580/A3-v6-certificate.pub.asc", "pgpy/memo.txt.nistp521.sig"]
        for name in names {
            let bytes = [UInt8](try fixture(name))
            var binary = bytes
            if let armor = try? OpenPGP.dearmor(String(decoding: Data(bytes), as: UTF8.self)) { binary = [UInt8](armor.data) }
            // Every truncation, and a flipped byte at every 7th position.
            for cut in stride(from: 0, to: binary.count, by: max(1, binary.count / 60)) {
                let data = Data(binary.prefix(cut))
                _ = try? OpenPGP.summarize(data, keyring: ring, signedData: memo)
                _ = try? OpenPGPKeyring(fileURL: nil).importKeys(data: data)
            }
            let original = name.hasSuffix(".sig") ? try? OpenPGPSignaturePacket(body: [UInt8](OpenPGP.packets(in: Data(binary))[0].body)) : nil
            for i in stride(from: 0, to: binary.count, by: 7) {
                var m = binary
                m[i] ^= 0xA5
                if let s = try? OpenPGP.summarize(Data(m), keyring: ring, signedData: memo), let original {
                    // A flip in the UNHASHED subpackets (e.g. the issuer key ID hint) legitimately still
                    // verifies (RFC 9580 §5.2.3.7); everything that is signed or is the signature must not.
                    let mutated = (try? OpenPGP.packets(in: Data(m))).flatMap { $0.first }.flatMap { try? OpenPGPSignaturePacket(body: [UInt8]($0.body)) }
                    let onlyUnhashed = mutated.map { $0.hashedPortion == original.hashedPortion && $0.left16 == original.left16
                        && $0.material == original.material && $0.salt == original.salt && $0.unhashed != original.unhashed } ?? false
                    if !onlyUnhashed {
                        XCTAssertFalse(s.verdicts.contains(where: \.isGood), "\(name) flipped at \(i): \(s.description)")
                    }
                }
                _ = try? OpenPGPKeyring(fileURL: nil).importKeys(data: Data(m))
            }
        }
        _ = OpenPGPVerifier.pgpMIMESigned(rawMessage: Data("Content-Type: multipart/signed; protocol=\"application/pgp-signature\"; boundary=x\r\n\r\n--x\r\n".utf8))
        _ = OpenPGPVerifier.cleartext(Data("-----BEGIN PGP SIGNED MESSAGE-----\n".utf8))
    }
}
