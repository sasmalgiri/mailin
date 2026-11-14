//
//  ReleasePreflightFixtureTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §3: "the release preflight must not pass with required
//  fixtures absent". In development the preflight SKIPS, naming every required
//  fixture that is missing, unverified or still pending from the owner; with
//  `MAILIN_RELEASE_PREFLIGHT=1` the same list is a FAILURE — strict mode
//  needs ZERO unresolved entries. The helper itself is tested against a
//  temporary root so a wrong digest or an unlisted file can never be handed
//  to a test as "verified". CUR-04 (2026-11-09): how a pending row is
//  reported is tested on a FAKE requirement list; nothing asserts how many
//  rows of the real list are pending.
//

import XCTest
import Foundation

final class ReleasePreflightFixtureTests: XCTestCase {

    /// The preflight: every entry of `ExternalFixtures.required` verified.
    /// Release mode (`MAILIN_RELEASE_PREFLIGHT=1`) requires ZERO unresolved
    /// entries; development reports them as a skip, never as a pass.
    func testReleasePreflight_everyRequiredFixturePresentAndVerified() throws {
        switch ExternalFixtures.shared.preflight(releaseMode: ExternalFixtures.releaseModeFromEnvironment) {
        case .passed:
            return
        case .failed(let message):
            XCTFail(message)
        case .reported(let message):
            throw XCTSkip("development: " + message + "\n(set \(ExternalFixtures.releasePreflightKey)=1 to make this a failure)")
        }
    }

    // MARK: - CUR-04: the preflight's semantics on a fake requirement list (temporary root)

    /// One verified file in a temporary pack, for the fake lists below.
    private func verifiedPack(extra sums: String = "") throws -> ExternalFixtures {
        let good = Data("good fixture".utf8)
        try write("pack/good.bin", good)
        try write("pack/SHA256SUMS", Data("\(ExternalFixtures.sha256Hex(of: good))  good.bin\n\(sums)".utf8))
        return ExternalFixtures(root: tempRoot)
    }

    func testPreflight_pendingRowIsReportedNeverPassed_andFailsInReleaseMode() throws {
        let fixtures = try verifiedPack()
        let list: [ExternalFixtures.Requirement] = [.file("pack/good.bin"), .pending("a fake owner-bound item")]
        let unresolved = fixtures.unresolvedRequirements(list)
        XCTAssertEqual(unresolved.map(\.0), [.pending("a fake owner-bound item")], "the pending row is listed, the verified one is not")
        guard case .reported(let message) = fixtures.preflight(list, releaseMode: false) else {
            return XCTFail("development: a pending row is reported (a skip), not a pass")
        }
        XCTAssertTrue(message.contains("1 of 2 required fixtures unresolved"), message)
        XCTAssertTrue(message.contains("pending owner pack: a fake owner-bound item"), message)
        guard case .failed(let strict) = fixtures.preflight(list, releaseMode: true) else {
            return XCTFail("release mode: a pending row fails the preflight")
        }
        XCTAssertTrue(strict.hasPrefix("RELEASE PREFLIGHT FAILED"), strict)
    }

    func testPreflight_strictMode_passesOnlyWithZeroUnresolved() throws {
        let fixtures = try verifiedPack()
        XCTAssertEqual(fixtures.preflight([.file("pack/good.bin")], releaseMode: true), .passed)
        XCTAssertEqual(fixtures.preflight([.file("pack/good.bin")], releaseMode: false), .passed)
    }

    func testPreflight_strictMode_failsOnAMissingFixture() throws {
        let fixtures = try verifiedPack()
        let list: [ExternalFixtures.Requirement] = [.file("pack/good.bin"), .file("pack/absent.olm")]
        guard case .failed(let message) = fixtures.preflight(list, releaseMode: true) else {
            return XCTFail("a missing required fixture fails in release mode")
        }
        XCTAssertTrue(message.contains("fixture missing") && message.contains("absent.olm"), message)
        // A missing pack (no SHA256SUMS) and a missing root fail the same way.
        guard case .failed = fixtures.preflight([.file("nopack/x.olm")], releaseMode: true) else { return XCTFail("missing pack") }
        let none = ExternalFixtures(root: tempRoot.appendingPathComponent("does-not-exist"))
        guard case .failed = none.preflight([.file("pack/good.bin")], releaseMode: true) else { return XCTFail("missing root") }
    }

    func testPreflight_strictMode_failsOnACorruptOrUnlistedFixture() throws {
        try write("pack/corrupt.olm", Data("bytes changed after listing".utf8))
        try write("pack/unlisted.olm", Data("never listed".utf8))
        let fixtures = try verifiedPack(extra: "\(ExternalFixtures.sha256Hex(of: Data("original bytes".utf8)))  corrupt.olm\n")
        guard case .failed(let corrupt) = fixtures.preflight([.file("pack/good.bin"), .file("pack/corrupt.olm")], releaseMode: true) else {
            return XCTFail("a corrupt required fixture fails in release mode")
        }
        XCTAssertTrue(corrupt.contains("does not match"), corrupt)
        guard case .failed(let unlisted) = fixtures.preflight([.file("pack/unlisted.olm")], releaseMode: true) else {
            return XCTFail("an unlisted required fixture fails in release mode")
        }
        XCTAssertTrue(unlisted.contains("not listed"), unlisted)
        // In development the same rows are reported, still not passed.
        guard case .reported = fixtures.preflight([.file("pack/corrupt.olm")], releaseMode: false) else { return XCTFail("reported") }
    }

    /// The real list's native-pack rows are files with pinned digests, and the
    /// pack's own SHA256SUMS (copied from the supplied zip) lists the same.
    func testNativePackRows_pinnedDigestsAreTheListedOnes() throws {
        for (path, digest) in ExternalFixtures.nativePackDigests {
            XCTAssertTrue(ExternalFixtures.required.contains(.file(path)), path)
            let sums = ExternalFixtures.shared.root.appendingPathComponent("native-pack-20261003/SHA256SUMS")
            guard FileManager.default.fileExists(atPath: sums.path) else { throw XCTSkip("native pack not installed: no \(sums.path)") }
            let inPack = String(path.dropFirst("native-pack-20261003/".count))
            XCTAssertEqual(ExternalFixtures.listedDigests(sums)[inPack], digest, path)
        }
        XCTAssertFalse(ExternalFixtures.required.contains { $0.label.contains("owner-pack/smime") && $0.label.contains("olm") },
                       "the native OLM is not filed under owner-pack/smime")
    }

    // MARK: - The helper against a temporary root

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("pack"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = tempRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testHelper_verifiedOnlyWhenListedDigestMatchesBytes() throws {
        let bytes = Data("real fixture bytes".utf8)
        try write("pack/sub/a.bin", bytes)
        try write("pack/other.bin", Data("other".utf8))
        let good = ExternalFixtures.sha256Hex(of: bytes)
        try write("pack/SHA256SUMS", Data("""
        # comment line
        \(good)  ./sub/a.bin
        \(String(repeating: "0", count: 64))  other.bin
        """.utf8))
        let fixtures = ExternalFixtures(root: tempRoot)
        XCTAssertEqual(fixtures.status(of: "pack/sub/a.bin"), .verified(tempRoot.appendingPathComponent("pack/sub/a.bin")))
        XCTAssertEqual(try fixtures.require("pack/sub/a.bin").lastPathComponent, "a.bin")

        // Listed with the wrong digest: a failure (thrown error), never a skip.
        if case .checksumMismatch(_, let expected, let actual) = fixtures.status(of: "pack/other.bin") {
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual, ExternalFixtures.sha256Hex(of: Data("other".utf8)))
        } else {
            XCTFail("expected checksumMismatch, got \(fixtures.status(of: "pack/other.bin"))")
        }
        XCTAssertThrowsError(try fixtures.require("pack/other.bin")) { error in
            XCTAssertFalse(error is XCTSkip, "a present file with a wrong digest must fail, not skip")
            XCTAssertTrue("\(error)".contains("does not match"), "\(error)")
        }
    }

    func testHelper_presentButUnlistedFileIsAFailureNotASkip() throws {
        try write("pack/unlisted.bin", Data("x".utf8))
        try write("pack/SHA256SUMS", Data("".utf8))
        let fixtures = ExternalFixtures(root: tempRoot)
        XCTAssertEqual(fixtures.status(of: "pack/unlisted.bin"), .notListed(tempRoot.appendingPathComponent("pack/unlisted.bin")))
        XCTAssertThrowsError(try fixtures.require("pack/unlisted.bin")) { XCTAssertFalse($0 is XCTSkip) }
    }

    func testHelper_absentFixtureIsAnExplicitSkipNamingTheFile() throws {
        try write("pack/SHA256SUMS", Data("".utf8))
        let fixtures = ExternalFixtures(root: tempRoot)
        XCTAssertEqual(fixtures.status(of: "pack/missing.olm"), .fileMissing(tempRoot.appendingPathComponent("pack/missing.olm")))
        XCTAssertThrowsError(try fixtures.require("pack/missing.olm")) { error in
            XCTAssertTrue(error is XCTSkip, "absent in development = skip")
            let message = (error as? XCTSkip)?.message ?? ""
            XCTAssertTrue(message.contains("missing.olm"), "the skip names the file: \(message)")
        }
        // No SHA256SUMS at all: the pack is not installed — also a skip.
        XCTAssertEqual(fixtures.status(of: "nopack/x.bin"), .sumsMissing(tempRoot.appendingPathComponent("nopack/SHA256SUMS")))
        XCTAssertThrowsError(try fixtures.require("nopack/x.bin")) { XCTAssertTrue($0 is XCTSkip) }
        // No root at all.
        let none = ExternalFixtures(root: tempRoot.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(none.status(of: "pack/a"), .rootMissing(none.root))
    }

    func testHelper_rootComesFromEnvironmentThenDefault() {
        XCTAssertEqual(ExternalFixtures.resolvedRoot(environment: [:]), ExternalFixtures.defaultRoot)
        XCTAssertEqual(ExternalFixtures.resolvedRoot(environment: [ExternalFixtures.rootEnvironmentKey: "/Volumes/Fixtures/"]).path, "/Volumes/Fixtures")
        XCTAssertEqual(ExternalFixtures.resolvedRoot(environment: [ExternalFixtures.rootEnvironmentKey: "~/F"]).path,
                       URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("F").path)
        XCTAssertEqual(ExternalFixtures.defaultRoot.path, URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/Mail/Fixtures").path)
    }

    func testHelper_streamedDigestEqualsOneShotDigest() throws {
        var big = Data(count: 3 * (1 << 20) + 17)   // more than one 1 MiB read
        for i in stride(from: 0, to: big.count, by: 4099) { big[i] = UInt8(truncatingIfNeeded: i) }
        try write("pack/big.bin", big)
        XCTAssertEqual(try ExternalFixtures.sha256Hex(of: tempRoot.appendingPathComponent("pack/big.bin")), ExternalFixtures.sha256Hex(of: big))
    }
}
