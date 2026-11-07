//
//  ReleasePreflightFixtureTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §3: "the release preflight must not pass with required
//  fixtures absent". In development the preflight SKIPS, naming every required
//  fixture that is missing, unverified or still pending from the owner; with
//  `MAILIN_RELEASE_PREFLIGHT=1` the same list is a FAILURE. The helper itself
//  is tested against a temporary root so a wrong digest or an unlisted file
//  can never be handed to a test as "verified".
//

import XCTest
import Foundation

final class ReleasePreflightFixtureTests: XCTestCase {

    /// The preflight: every entry of `ExternalFixtures.required` verified.
    func testReleasePreflight_everyRequiredFixturePresentAndVerified() throws {
        let fixtures = ExternalFixtures.shared
        let unresolved = fixtures.unresolvedRequirements()
        let report = unresolved.map { "  - \($0.0.label): \($0.1)" }.joined(separator: "\n")
        let releaseMode = ProcessInfo.processInfo.environment[ExternalFixtures.releasePreflightKey] == "1"
        guard !unresolved.isEmpty else { return }
        let message = "\(unresolved.count) of \(ExternalFixtures.required.count) required fixtures unresolved under \(fixtures.root.path):\n\(report)"
        if releaseMode {
            XCTFail("RELEASE PREFLIGHT FAILED — " + message)
        } else {
            throw XCTSkip("development: " + message + "\n(set \(ExternalFixtures.releasePreflightKey)=1 to make this a failure)")
        }
    }

    /// The owner-pending rows are listed, never silently dropped.
    func testReleasePreflight_pendingOwnerPackRowsAreCountedAsUnresolved() {
        let pending = ExternalFixtures.required.filter { if case .pending = $0 { return true }; return false }
        XCTAssertFalse(pending.isEmpty, "the same-message set and S/MIME material are still owner-bound on 2026-11-07")
        let unresolved = ExternalFixtures.shared.unresolvedRequirements()
        for row in pending {
            XCTAssertTrue(unresolved.contains { $0.0 == row }, "pending row reported: \(row.label)")
        }
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
