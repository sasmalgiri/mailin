//
//  ODFEncryptionTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Protected mail/documents": encrypted OpenDocument.
//  Spec-built packages with LibreOffice's parameters (AES-256-CBC, PBKDF2
//  100,000 rounds, SHA-256 start key, SHA256/1K) and OpenOffice.org's legacy
//  ones (Blowfish 8-bit CFB, SHA-1, 1,024 rounds, SHA1/1K), plus AES-256-GCM,
//  round-trip through the facade; a wrong password is `wrongPassword`, no
//  password is `encrypted` (locked), Argon2id is named, never guessed. The
//  real LibreOffice-written file is `TikaODFIWorkFixtureTests
//  .testREAL_ODT_encrypted_lockedWithoutPassword_opensWithTika`.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ODFEncryptionTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("odfenc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    static let secret = "MAILIN-ODF-SECRET-20261107 is the sentence inside the protected document."

    static func content(_ sentence: String = secret) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2">
        <office:body><office:text><text:h text:outline-level="1">Protected heading</text:h><text:p>\(sentence)</text:p>
        <text:p>\(String(repeating: "Padding paragraph so the deflated part passes one kilobyte. ", count: 60))</text:p></office:text></office:body></office:document-content>
        """.utf8)
    }
    static let styles = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2">
    <office:master-styles><style:master-page style:name="Standard"><style:footer><text:p>Footer of the protected file</text:p></style:footer></style:master-page></office:master-styles></office:document-styles>
    """.utf8)

    func write(_ name: String, password: String, parameters: ODFEncryption.Parameters) throws -> URL {
        let bytes = try ODFEncryption.encrypt(members: [("content.xml", Self.content()), ("styles.xml", Self.styles)],
                                              mimetype: "application/vnd.oasis.opendocument.text", password: password, parameters: parameters)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testLibreOfficeParameters_AES256CBC_roundTripWrongAndMissingPassword() throws {
        var p = ODFEncryption.Parameters.libreOffice
        p.iterations = 2_000   // the real file uses 100,000; the derivation is the same code path
        let url = try write("lo.odt", password: "correct horse", parameters: p)
        // The package is a ZIP whose encrypted members are stored, as LibreOffice writes them.
        let members = try ZIPArchiveReader.members(of: url)
        XCTAssertEqual(members.first?.name, "mimetype")
        XCTAssertEqual(members.first { $0.name == "content.xml" }?.method, 0)

        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .odt)) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .encrypted) }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "wrong")) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .wrongPassword) }
        let r = try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "correct horse")
        XCTAssertTrue(r.text.contains(Self.secret), r.text)
        XCTAssertTrue(r.text.contains("Footer of the protected file"), "styles.xml is decrypted too")
        XCTAssertEqual(r.components, ["Document", "Footer"])
    }

    func testOpenOfficeLegacy_BlowfishCFB_SHA1_roundTrip() throws {
        let url = try write("ooo.odt", password: "pässwörd ✓", parameters: .openOfficeLegacy)
        let manifest = try ZIPArchiveReader.members(of: url).first { $0.name == "META-INF/manifest.xml" }!
        let scratch = try DocumentTextExtractor.scratchDirectory("t")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let entries = ODFEncryption.encryptedEntries(manifest: try DocumentTextExtractor.memberData(manifest, from: url, scratch: scratch))
        XCTAssertEqual(entries["content.xml"]?.algorithmName, "Blowfish CFB")
        XCTAssertEqual(entries["content.xml"]?.checksumType, "SHA1/1K")
        XCTAssertEqual(entries["content.xml"]?.iterationCount, 1024)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "pässwörd")) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .wrongPassword) }
        let r = try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "pässwörd ✓")
        XCTAssertTrue(r.text.contains(Self.secret), r.text)
    }

    func testBlowfishCFB8_knownAnswer_encryptDecryptAndFeedbackWidth() throws {
        // Byte-oriented CFB: a one-byte change in the cipher text damages at most nine plain bytes (the byte and the 8-byte shift register).
        let key = Array("sixteen byte key".utf8), iv: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let plain = Array("The quick brown fox jumps over the lazy dog, twice over.".utf8)
        let cipher = try ODFEncryption.blowfishCFB8(plain, key: key, iv: iv, encrypt: true)
        XCTAssertEqual(cipher.count, plain.count)
        XCTAssertNotEqual(cipher, plain)
        XCTAssertEqual(try ODFEncryption.blowfishCFB8(cipher, key: key, iv: iv, encrypt: false), plain)
        var damaged = cipher; damaged[10] ^= 0xFF
        let back = try ODFEncryption.blowfishCFB8(damaged, key: key, iv: iv, encrypt: false)
        XCTAssertEqual(Array(back[0..<10]), Array(plain[0..<10]))
        XCTAssertEqual(Array(back[19...]), Array(plain[19...]), "an 8-bit feedback register recovers after nine bytes")
        XCTAssertNotEqual(Array(back[10..<19]), Array(plain[10..<19]))
    }

    func testAES256GCM_LibreOffice24_roundTripAndTamperIsWrongPassword() throws {
        var p = ODFEncryption.Parameters.libreOffice
        p.algorithm = .aes256GCM; p.iterations = 1_000
        let url = try write("gcm.odt", password: "gcm", parameters: p)
        let r = try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "gcm")
        XCTAssertTrue(r.text.contains(Self.secret))
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "gcm ")) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .wrongPassword) }
    }

    func testArgon2id_isNamedNotGuessed() throws {
        var p = ODFEncryption.Parameters.libreOffice
        p.keyDerivationName = "urn:org:documentfoundation:names:experimental:office:manifest:argon2id"
        p.iterations = 1_000
        let url = try write("argon.odt", password: "x", parameters: p)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .odt)) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .encrypted) }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: url, kind: .odt, password: "x")) { error in
            XCTAssertEqual(error as? ODFEncryption.UnlockError, .keyDerivationUnsupported("Argon2"))
            XCTAssertEqual(error.localizedDescription, "locked: Argon2 key derivation not supported")
        }
    }

    func testManifestWithoutEncryptionData_isPlain() throws {
        let plainManifest = Data("""
        <?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
        <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """.utf8)
        XCTAssertFalse(ODFEncryption.isEncrypted(manifest: plainManifest))
        XCTAssertTrue(ODFEncryption.encryptedEntries(manifest: plainManifest).isEmpty)
    }

    func testRawDeflate_roundTripAndLimit() throws {
        let plain = Data(String(repeating: "deflate me ", count: 5_000).utf8)
        let packed = try RawDeflate.deflate(plain)
        XCTAssertLessThan(packed.count, plain.count / 10)
        XCTAssertEqual(try RawDeflate.inflate(packed, limit: plain.count), plain)
        XCTAssertThrowsError(try RawDeflate.inflate(packed, limit: 4_096)) { XCTAssertEqual($0 as? RawDeflate.Failure, .overLimit(4_096)) }
        XCTAssertThrowsError(try RawDeflate.inflate(Data([0xFF, 0xFE, 0x00, 0x11]), limit: 1_000)) { XCTAssertEqual($0 as? RawDeflate.Failure, .corrupt) }
    }
}
