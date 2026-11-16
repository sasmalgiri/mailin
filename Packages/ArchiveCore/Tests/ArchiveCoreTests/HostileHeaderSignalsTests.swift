//
//  HostileHeaderSignalsTests.swift
//  ArchiveCoreTests
//
//  Code review 2026-11-16, A11 / A18: one hostile header or one hostile Notes
//  item table must never trap or hang the app.
//    A11  DKIM `l=-1` (was `prefix(-1)`), ARC instance 0 / negative (was
//         `1...0`), a DER BIT STRING of length 0 (was `i..<i-1`) → a named
//         failure, never a trap
//    A18  a Notes note whose item table makes the placement search explode
//         (6,000 items, no valid placement) is answered in well under a
//         second instead of O(n³–n⁴); a placeable note of the same shape is
//         still placed exactly; the search has a stated work limit
//

import XCTest
import Foundation
import CryptoKit
@testable import ArchiveCore

final class HostileHeaderSignalsTests: XCTestCase {

    // MARK: A11 — DKIM l=

    private let key = Curve25519.Signing.PrivateKey()
    private var keys: DKIMKeyCache {
        DKIMKeyCache(records: ["sel._domainkey.example.com": "v=DKIM1; k=ed25519; p=\(key.publicKey.rawRepresentation.base64EncodedString())",
                               "arc._domainkey.example.com": "v=DKIM1; k=ed25519; p=\(key.publicKey.rawRepresentation.base64EncodedString())"])
    }

    private func dkimMessage(l: String) -> String {
        "DKIM-Signature: v=1; a=ed25519-sha256; c=relaxed/relaxed; d=example.com; s=sel; h=from; l=\(l); bh=AAAA; b=AAAA\r\n"
            + "From: a@example.com\r\n\r\nhello\r\n"
    }

    func testA11_dkimNegativeBodyLength_isANamedFailure_notATrap() {
        for l in ["-1", "-9223372036854775808", "abc", ""] {
            guard case .fail(let why) = DKIMVerifier.verify(rawSource: dkimMessage(l: l), keys: keys) else {
                return XCTFail("l=\(l) must fail")
            }
            XCTAssertFalse(why.isEmpty)
        }
        // l=0 and a valid l= larger than the body are still read as before (body hash compared).
        guard case .fail(let why) = DKIMVerifier.verify(rawSource: dkimMessage(l: "0"), keys: keys) else { return XCTFail() }
        XCTAssertTrue(why.contains("body hash"), why)
        guard case .fail(let why2) = DKIMVerifier.verify(rawSource: dkimMessage(l: "99999"), keys: keys) else { return XCTFail() }
        XCTAssertTrue(why2.contains("body hash"), why2)
    }

    // MARK: A11 — ARC instance numbers

    private func arcMessage(instance: String) -> String {
        "ARC-Seal: i=\(instance); a=ed25519-sha256; cv=none; d=example.com; s=arc; b=AAAA\r\n"
            + "ARC-Message-Signature: i=\(instance); a=ed25519-sha256; c=relaxed/relaxed; d=example.com; s=arc; h=from; bh=AAAA; b=AAAA\r\n"
            + "ARC-Authentication-Results: i=\(instance); relay.example; spf=pass\r\n"
            + "From: a@example.com\r\n\r\nhello\r\n"
    }

    func testA11_arcInstanceZeroOrNegative_isANamedFailure_notATrap() {
        for i in ["0", "-1", "-50"] {
            guard case .fail(_, let why) = DKIMVerifier.verifyARCChain(rawSource: arcMessage(instance: i), keys: keys) else {
                return XCTFail("ARC i=\(i) must fail")
            }
            XCTAssertFalse(why.isEmpty)
        }
        // i=51 is still refused by the RFC 8617 limit, as before.
        guard case .fail(51, _) = DKIMVerifier.verifyARCChain(rawSource: arcMessage(instance: "51"), keys: keys) else { return XCTFail() }
    }

    // MARK: A11 — DER BIT STRING of length 0

    func testA11_derBitStringOfLengthZero_isNil_notATrap() {
        // SEQUENCE { SEQUENCE {} BIT STRING (length 0) } + one trailing byte.
        XCTAssertNil(DKIMVerifier.rsaPublicKeyPKCS1(fromSPKI: Data([0x30, 0x05, 0x30, 0x00, 0x03, 0x00, 0x00])))
        XCTAssertNil(DKIMVerifier.rsaPublicKeyPKCS1(fromSPKI: Data([0x30, 0x04, 0x30, 0x00, 0x03, 0x00])))
        // A BIT STRING of length 1 holds only the unused-bits byte: an empty key.
        XCTAssertEqual(DKIMVerifier.rsaPublicKeyPKCS1(fromSPKI: Data([0x30, 0x05, 0x30, 0x00, 0x03, 0x01, 0x00])), Data())

        // The same key published in DNS, reached through verification.
        let body = "hello\r\n"
        let bh = Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString()
        let raw = "DKIM-Signature: v=1; a=rsa-sha256; c=simple/simple; d=example.com; s=rsa; h=from; bh=\(bh); b=AAAA\r\n"
            + "From: a@example.com\r\n\r\n" + body
        let hostile = DKIMKeyCache(records: ["rsa._domainkey.example.com": "v=DKIM1; k=rsa; p=\(Data([0x30, 0x05, 0x30, 0x00, 0x03, 0x00, 0x00]).base64EncodedString())"])
        guard case .fail = DKIMVerifier.verify(rawSource: raw, keys: hostile) else { return XCTFail("a broken key fails, it does not trap") }
    }

    // MARK: A18 — Notes item placement

    typealias D = NSFODSDepthTests

    static let hostileNoteID: UInt32 = 0x200
    static let junkItems = 6_000

    /// One mail note of `junkItems` one-byte summary items and a final
    /// two-byte RFC822_TEXT item, whose header names a 3-byte non-summary
    /// record: three bytes must move out of the summary, and only
    /// `nonSummary` decides whether any placement checks out.
    static func hostileDatabase(nonSummary: [UInt8]) throws -> Data {
        var items: [D.Builder.ItemSpec] = (0..<junkItems).map { _ in
            .init(name: "Junk", cls: 5, type: 0, flags: 0x0004, value: Data([UInt8(ascii: "a")]))
        }
        items.append(.init(name: "$RFC822Text", cls: 5, type: 2, flags: 0x0004, value: Data([0x00, 0x00])))
        var b = D.Builder()
        b.notes = [.init(id: hostileNoteID, noteClass: 0x0001, items: items, bucket: 1)]
        var file = b.build()

        // Find the note header in its bucket slot.
        func u16(_ o: Int) -> UInt16 { UInt16(file[o]) | UInt16(file[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        var noteOffset: Int?
        var o = 0
        while o + 100 <= file.count {
            if u16(o) == 0x0004, u32(o + 6) == hostileNoteID, Int(u16(o + 50)) == items.count { noteOffset = o; break }
            o += 2
        }
        let off = try XCTUnwrap(noteOffset, "the note is in the file")

        // The non-summary record: LSIG 0x0010, the note ID, 68 header bytes, then the values.
        while file.count % 256 != 0 { file.append(0) }
        let nsStart = file.count
        var record = Data(count: 68)
        record.replaceSubrange(0..<2, with: D.Builder.le16(0x0010))
        record.replaceSubrange(6..<10, with: D.Builder.le32(hostileNoteID))
        record.append(contentsOf: nonSummary)
        file.append(record)
        file.replaceSubrange((off + 56)..<(off + 60), with: D.Builder.le32(UInt32(nsStart >> 8)))
        file.replaceSubrange((off + 60)..<(off + 64), with: D.Builder.le32(UInt32(record.count)))
        return file
    }

    /// Reads the hostile note on a background thread; nil when it took longer than `seconds`.
    static func readNote(_ data: Data, within seconds: TimeInterval) throws -> NSFODSReader.Record? {
        let reader = try NSFODSReader(data: data)
        final class Box: @unchecked Sendable { var record: NSFODSReader.Record? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread {
            var cursor = NSFODSReader.Cursor()
            while let r = reader.next(&cursor) {
                if case .object = r { continue }
                box.record = r
                break
            }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.record
    }

    func testA18_hostileItemTable_noPlacement_answeredFast_notO_n4() throws {
        // The checked item reads 00 00 wherever it lands: no placement exists.
        let data = try Self.hostileDatabase(nonSummary: [0, 0, 0])
        let started = Date()
        guard let record = try Self.readNote(data, within: 30) else {
            return XCTFail("the placement search did not finish in 30 s (O(n³–n⁴) over 6,001 items)")
        }
        let seconds = Date().timeIntervalSince(started)
        guard case .unplaced(let id) = record else { return XCTFail("expected unplaced, got \(record)") }
        XCTAssertEqual(id, Self.hostileNoteID)
        XCTAssertLessThan(seconds, 5, "near-linear: \(seconds) s")
    }

    /// The search's stated work limit ends it by name; under the limit the same
    /// table is searched to the end.
    func testA18_placementSearch_statedStepLimit() {
        let m = 2_000
        var sizes = [Int](repeating: 1, count: m)
        sizes[m - 1] = 2
        var required = [UInt16](repeating: 0, count: m)
        required[m - 1] = 0x000E
        let data = Data(count: 8_000)                       // reads 00 00 everywhere: nothing places
        func search(_ limit: Int) -> NSFODSReader.PlacementOutcome {
            NSFODSReader.searchPlacement(sizes: sizes, defaultSummary: Set(0..<m), required: required, nsBytes: 3,
                                         data: data, tableEnd: 0, nsBase: 4_000, noteEnd: 4_000,
                                         stepLimit: limit, confirm: { _ in XCTFail("no candidate passes"); return false })
        }
        XCTAssertEqual(search(1_000), .stepLimit)
        XCTAssertEqual(search(NSFODSReader.placementStepLimit), .notFound)
        XCTAssertEqual(NSFODSReader.placementStepLimit, 16_777_216)
    }

    func testA18_sameShape_placeable_isPlacedExactly() throws {
        // Non-summary bytes: the first junk item's value, then the RFC822_TEXT
        // version word 0x000E — the first pair in search order checks out.
        let data = try Self.hostileDatabase(nonSummary: [0x7A, 0x0E, 0x00])
        guard let record = try Self.readNote(data, within: 30) else { return XCTFail("did not finish") }
        guard case .note(let note) = record else { return XCTFail("expected a placed note, got \(record)") }
        XCTAssertEqual(note.items.count, Self.junkItems + 1)
        XCTAssertEqual(note.items.first?.value, Data([0x7A]), "item 0 moved to the non-summary record")
        XCTAssertEqual(note.items.last?.value, Data([0x0E, 0x00]), "the RFC822_TEXT item from the non-summary record")
        XCTAssertTrue(note.items.dropFirst().dropLast().allSatisfy { $0.value == Data([UInt8(ascii: "a")]) })
    }
}
