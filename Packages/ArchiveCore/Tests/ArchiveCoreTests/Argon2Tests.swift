//
//  Argon2Tests.swift
//  ArchiveCoreTests
//
//  Audit R6 "ODF Argon2id": BLAKE2b against RFC 7693 / reference digests,
//  Argon2d/i/id against the RFC 9106 §5 test vectors, Argon2id against the
//  reference implementation's own test.c vectors (one at LibreOffice's 64 MiB),
//  and the stated limits.
//

import XCTest
@testable import ArchiveCore

final class Argon2Tests: XCTestCase {

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testBLAKE2b_referenceDigests() {
        // RFC 7693 Appendix A: BLAKE2b-512("abc").
        XCTAssertEqual(Self.hex(BLAKE2b.hash(Array("abc".utf8), outputLength: 64)),
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        // The empty message.
        XCTAssertEqual(Self.hex(BLAKE2b.hash([], outputLength: 64)),
                       "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
    }

    /// RFC 9106 §5: password 32 × 0x01, salt 16 × 0x02, secret 8 × 0x03, data 12 × 0x04, t=3, m=32 KiB, p=4, 32-byte tag.
    func rfcVector(_ variant: Argon2.Variant) throws -> String {
        Self.hex(try Argon2.hash(password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16),
                                 secret: [UInt8](repeating: 3, count: 8), associatedData: [UInt8](repeating: 4, count: 12),
                                 iterations: 3, memoryKiB: 32, lanes: 4, tagLength: 32, variant: variant))
    }

    func testRFC9106_Argon2d() throws {
        XCTAssertEqual(try rfcVector(.d), "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb")
    }

    func testRFC9106_Argon2i() throws {
        XCTAssertEqual(try rfcVector(.i), "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8")
    }

    func testRFC9106_Argon2id() throws {
        XCTAssertEqual(try rfcVector(.id), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    /// phc-winner-argon2 src/test.c, Argon2id v=19, "password" / "somesalt".
    func testReferenceTestVectors_Argon2id_smallMemory() throws {
        let pw = Array("password".utf8), salt = Array("somesalt".utf8)
        XCTAssertEqual(Self.hex(try Argon2.hash(password: pw, salt: salt, iterations: 2, memoryKiB: 256, lanes: 1, tagLength: 32)),
                       "9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe")
        XCTAssertEqual(Self.hex(try Argon2.hash(password: pw, salt: salt, iterations: 2, memoryKiB: 256, lanes: 2, tagLength: 32)),
                       "6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037")
    }

    /// The same suite at 64 MiB (2^16 KiB) — LibreOffice's Argon2id memory.
    func testReferenceTestVector_Argon2id_64MiB() throws {
        XCTAssertEqual(Self.hex(try Argon2.hash(password: Array("password".utf8), salt: Array("somesalt".utf8),
                                                iterations: 1, memoryKiB: 65_536, lanes: 1, tagLength: 32)),
                       "f6a5adc1ba723dddef9b5ac1d464e180fcd9dffc9d1cbf76cca2fed795d9ca98")
    }

    func testLimitsAndInvalidParameters_areNamed() {
        XCTAssertThrowsError(try Argon2.hash(password: [1], salt: [UInt8](repeating: 0, count: 16), iterations: 1,
                                             memoryKiB: Argon2.maxMemoryKiB + 1, lanes: 1, tagLength: 32)) { error in
            guard case Argon2.Failure.overLimit(let what)? = error as? Argon2.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(what.contains("1048576 KiB"), what)
        }
        XCTAssertThrowsError(try Argon2.hash(password: [1], salt: [UInt8](repeating: 0, count: 16), iterations: 1, memoryKiB: 16, lanes: 4, tagLength: 32))
        XCTAssertThrowsError(try Argon2.hash(password: [1], salt: [1, 2, 3], iterations: 1, memoryKiB: 64, lanes: 1, tagLength: 32))
        XCTAssertThrowsError(try Argon2.hash(password: [1], salt: [UInt8](repeating: 0, count: 16), iterations: 0, memoryKiB: 64, lanes: 1, tagLength: 32))
    }
}
