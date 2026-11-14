@testable import ArchiveCore
//
//  TestPreconditions.swift
//  maxmailinTests
//
//  Environment preconditions, so a full disk reports as a SKIP with the
//  reason rather than as a defect in the code.
//
//  This exists because of a real afternoon lost to it. With the volume at 95%
//  (10 GiB free of 228), tests that write ~190 MB through SQLite began failing
//  with `step("disk I/O error")` and `CancellationError`. The failure MOVED
//  between runs — `testProductionPathImport` once, `testArchive_exportsMBOX`
//  the next time — which is the signature of resource exhaustion, but each
//  individual report looked exactly like a store bug. Clearing 1.3 GB made
//  them all pass again on unchanged code.
//
//  For a tool whose whole value is telling the truth about what it did, a test
//  suite that says "disk I/O error" when it means "your disk is full" is the
//  wrong failure. A skip that names the shortfall is diagnosable in seconds.
//

import XCTest
import CryptoKit
@testable import maxmailin

enum TestPreconditions {

    /// Skips the calling test when the volume holding `directory` has less
    /// than `requiredBytes` free.
    ///
    /// The margin is deliberately several times the test's own write: SQLite
    /// needs the database, its WAL, and temp space for a checkpoint, and the
    /// error it raises when any of those cannot be written does not say which.
    static func requireFreeSpace(_ requiredBytes: Int64,
                                 at directory: URL = FileManager.default.temporaryDirectory,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let probe = StoragePlanner.nearestExistingDirectory(of: directory)
        let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else {
            // Unreadable free space is not a reason to skip — it is a reason
            // to proceed and let the real failure speak, because an unreadable
            // volume is itself worth seeing.
            return
        }
        let freeBytes = Int64(free)
        guard freeBytes < requiredBytes else { return }

        func gb(_ b: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        }
        throw XCTSkip("""
            Skipped: this test writes through SQLite and needs about \(gb(requiredBytes)) \
            free, but only \(gb(freeBytes)) is available on the volume holding \
            \(probe.path). This is an environment shortfall, not a defect — the test \
            passes on the same code with headroom. Free space and re-run.
            """, file: file, line: line)
    }

    /// Budget for a test that imports and re-exports the ~95 MB reference
    /// fixture: ~190 MB of payload, times a factor for WAL, index and
    /// checkpoint temp space.
    static let referenceFixtureBudget: Int64 = 2 * 1_073_741_824      // 2 GiB

    /// Budget for the 2,000-row scale test and the large synthetic mailboxes.
    static let scaleFixtureBudget: Int64 = 1_073_741_824              // 1 GiB
}

// MARK: - External fixtures (twin of Packages/ArchiveCore/Tests/ArchiveCoreTests/ExternalFixtures.swift)
//
//  Directive 2026-11-07 §3: the external fixture root OUTSIDE the repository,
//  verified before use. Kept here (not in a new file) because app test files
//  must be listed in project.pbxproj, which is never edited by hand while
//  Xcode is open. Same contract as the package helper:
//
//   • Root: `$MAILIN_FIXTURE_ROOT`, else `~/Downloads/Mail/Fixtures`.
//   • Packs: the first path component (`opensource/…`, `public-pack/…`);
//     each pack carries `SHA256SUMS` (`shasum -a 256` format, paths relative
//     to the pack). A file is handed out only when its digest matches.
//   • `require(_:)` throws `XCTSkip` naming the missing file / pack; a file
//     that is present but unlisted or with a different digest is a failure.

struct ExternalFixtures {

    static let rootEnvironmentKey = "MAILIN_FIXTURE_ROOT"
    static let releasePreflightKey = "MAILIN_RELEASE_PREFLIGHT"
    static let sumsFileName = "SHA256SUMS"

    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/Mail/Fixtures", isDirectory: true)
    }

    /// The configured root: the environment variable when set (tilde expanded), else the default.
    static func resolvedRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment[rootEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultRoot
    }

    static let shared = ExternalFixtures(root: resolvedRoot())

    let root: URL

    init(root: URL) { self.root = root }

    /// A fixture the release needs (same table as the package helper).
    enum Requirement: Equatable {
        case file(String)
        case pending(String)

        var label: String {
            switch self {
            case .file(let path): return path
            case .pending(let what): return "pending owner pack: \(what)"
            }
        }
    }

    static let required: [Requirement] = [
        .file("opensource/aspose-email-net/SampleOLM.olm"),
        .file("opensource/aspose-email-net/SampleOstFile.ost"),
        .file("opensource/aspose-email-net/SampleNSF.nsf"),
        .file("opensource/java-libpst/example-2013.ost"),
        .file("opensource/olmreader/outlook_example.olm"),
        .file("public-pack/01_outlook/Set_Up_Mobile_Thru_Admin.oft"),
        .file("public-pack/04_import_ready_eml/01_Set_Up_Mobile_Thru_Admin.eml"),
        .pending("native Outlook for Mac OLM + Apple Mail MBOX + derived EML of the same message (directive §3 row 6)"),
        .pending("S/MIME fixtures (signed / enveloped messages and their test identity)"),
    ]

    enum Status: Equatable {
        case verified(URL)
        case rootMissing(URL)
        case sumsMissing(URL)
        case fileMissing(URL)
        case notListed(URL)
        case checksumMismatch(URL, expected: String, actual: String)

        var isAbsent: Bool {
            switch self {
            case .rootMissing, .sumsMissing, .fileMissing: return true
            case .verified, .notListed, .checksumMismatch: return false
            }
        }

        var description: String {
            switch self {
            case .verified(let url): return "verified \(url.path)"
            case .rootMissing(let root): return "fixture root missing: \(root.path) (set \(ExternalFixtures.rootEnvironmentKey))"
            case .sumsMissing(let sums): return "pack not installed: no \(sums.path)"
            case .fileMissing(let url): return "fixture missing: \(url.path)"
            case .notListed(let url): return "fixture present but not listed in its pack's \(ExternalFixtures.sumsFileName): \(url.path)"
            case .checksumMismatch(let url, let expected, let actual):
                return "fixture \(url.path) does not match \(ExternalFixtures.sumsFileName): expected \(expected), actual \(actual)"
            }
        }
    }

    /// `relativePath` is `<pack>/<path inside the pack>`.
    func status(of relativePath: String) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return .rootMissing(root) }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let pack = parts.first, parts.count > 1 else { return .fileMissing(root.appendingPathComponent(relativePath)) }
        let packURL = root.appendingPathComponent(pack, isDirectory: true)
        let sumsURL = packURL.appendingPathComponent(Self.sumsFileName)
        let fileURL = root.appendingPathComponent(relativePath)
        let inPack = parts.dropFirst().joined(separator: "/")
        guard fm.fileExists(atPath: sumsURL.path) else { return .sumsMissing(sumsURL) }
        guard fm.fileExists(atPath: fileURL.path) else { return .fileMissing(fileURL) }
        guard let expected = Self.listedDigests(sumsURL)[inPack] else { return .notListed(fileURL) }
        guard let actual = try? Self.sha256Hex(of: fileURL) else { return .fileMissing(fileURL) }
        return actual == expected ? .verified(fileURL) : .checksumMismatch(fileURL, expected: expected, actual: actual)
    }

    /// The verified URL, or `XCTSkip` when the fixture is absent; a present file
    /// that fails verification throws an error (the test fails).
    func require(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        switch status(of: relativePath) {
        case .verified(let url):
            return url
        case let absent where absent.isAbsent:
            throw XCTSkip("\(absent.description) — external fixture required by directive §3; install it under the fixture root (default ~/Downloads/Mail/Fixtures, override with \(Self.rootEnvironmentKey))", file: file, line: line)
        case let failure:
            throw FixtureError(failure.description)
        }
    }

    struct FixtureError: LocalizedError, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { description }
    }

    /// Every required entry that is not verified, with the reason.
    func unresolvedRequirements() -> [(Requirement, String)] {
        Self.required.compactMap { requirement in
            switch requirement {
            case .pending(let what):
                return (requirement, "not yet supplied: \(what)")
            case .file(let path):
                let status = self.status(of: path)
                if case .verified = status { return nil }
                return (requirement, status.description)
            }
        }
    }

    /// `<hex>  <path>` lines (`shasum -a 256` output; a leading `*` or `./` on the path is tolerated).
    static func listedDigests(_ sumsURL: URL) -> [String: String] {
        guard let text = try? String(contentsOf: sumsURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let digest = trimmed[..<space].lowercased()
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            var path = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("*") { path.removeFirst() }
            if path.hasPrefix("./") { path.removeFirst(2) }
            out[path] = digest
        }
        return out
    }

    /// Streamed in 1 MiB reads — no size assumption about the file.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The twin stays a twin: the contract is checked here against a pack built in a
/// temporary root — verified, missing, unlisted, mismatched — and `require`
/// skips (not fails) for an absent file.
final class ExternalFixturesTwinTests: XCTestCase {
    func testFIXROOT_statusAndRequire_followThePackageContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixroot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appendingPathComponent("public-pack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("01_outlook", isDirectory: true), withIntermediateDirectories: true)
        let good = Data("official bytes".utf8), bad = Data("tampered bytes".utf8)
        try good.write(to: pack.appendingPathComponent("01_outlook/good.oft"))
        try bad.write(to: pack.appendingPathComponent("01_outlook/bad.oft"))
        try Data("unlisted".utf8).write(to: pack.appendingPathComponent("01_outlook/unlisted.oft"))
        try """
        \(ExternalFixtures.sha256Hex(of: good))  01_outlook/good.oft
        \(ExternalFixtures.sha256Hex(of: good))  ./01_outlook/bad.oft
        """.write(to: pack.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        let fixtures = ExternalFixtures(root: root)
        XCTAssertEqual(fixtures.status(of: "public-pack/01_outlook/good.oft"), .verified(pack.appendingPathComponent("01_outlook/good.oft")))
        XCTAssertEqual(try fixtures.require("public-pack/01_outlook/good.oft"), pack.appendingPathComponent("01_outlook/good.oft"))
        guard case .checksumMismatch = fixtures.status(of: "public-pack/01_outlook/bad.oft") else { return XCTFail("a wrong digest is a mismatch") }
        XCTAssertThrowsError(try fixtures.require("public-pack/01_outlook/bad.oft")) { XCTAssertFalse($0 is XCTSkip, "a present-but-wrong file fails, never skips") }
        XCTAssertEqual(fixtures.status(of: "public-pack/01_outlook/unlisted.oft"), .notListed(pack.appendingPathComponent("01_outlook/unlisted.oft")))
        XCTAssertTrue(fixtures.status(of: "public-pack/01_outlook/absent.oft").isAbsent)
        XCTAssertThrowsError(try fixtures.require("public-pack/01_outlook/absent.oft")) { XCTAssertTrue($0 is XCTSkip, "an absent file skips, naming it") }
        XCTAssertTrue(fixtures.status(of: "opensource/x/y.olm").isAbsent, "a pack without SHA256SUMS is not installed")
        XCTAssertEqual(ExternalFixtures.resolvedRoot(environment: ["MAILIN_FIXTURE_ROOT": "~/Elsewhere"]).path, (("~/Elsewhere" as NSString).expandingTildeInPath))
        XCTAssertEqual(ExternalFixtures.resolvedRoot(environment: [:]), ExternalFixtures.defaultRoot)
        XCTAssertEqual(ExternalFixtures.required.count, 9, "the twin carries the package's directive §3 table")
    }
}
