//
//  ExternalFixtures.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §3 "Use both supplied fixture packs now": the external
//  fixture root OUTSIDE the repository, verified before use.
//
//   • Root: `$MAILIN_FIXTURE_ROOT`, else `~/Downloads/Mail/Fixtures`.
//   • Packs: the first path component of a fixture's relative path
//     (`opensource/…`, `public-pack/…`). Every pack carries a `SHA256SUMS`
//     (`shasum -a 256` format, paths relative to the pack directory); a file
//     is handed to a test only when its listed digest matches the bytes.
//   • Provenance: `MANIFEST.md` / `PROVENANCE.md` beside the files and
//     `FIXTURE_ACQUISITION_2026-11-07.md` at the root (URL, licence, SHA-256).
//   • Microsoft's OFT material lives only here (`public-pack/`), never in Git.
//   • Development: `require(_:)` throws `XCTSkip` naming the missing file or
//     pack when the fixture is absent — one test method per required case,
//     so the report names each. A file that IS present but does not match
//     its digest, or is not listed, is a failure, never a skip.
//   • Release: `ReleasePreflightFixtureTests` lists every required fixture
//     that is missing or unresolved; it skips with that list in development
//     and FAILS with it when `MAILIN_RELEASE_PREFLIGHT=1`.
//

import Foundation
import CryptoKit
import XCTest

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

    // MARK: - What the directive requires

    /// A fixture the release needs. `.file` is a path under the root; `.pending`
    /// is a case the directive names whose files have not arrived (owner pack),
    /// so no path or digest can be stated yet — the preflight lists it as
    /// unresolved until the owner supplies it and the entry becomes a `.file`.
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

    /// Directive §3 table, one entry per acceptance anchor's file.
    static let required: [Requirement] = [
        // Aspose public samples (MIT; aspose-email/Aspose.Email-for-.NET, Examples/Data/…).
        .file("opensource/aspose-email-net/SampleOLM.olm"),
        .file("opensource/aspose-email-net/SampleOstFile.ost"),
        .file("opensource/aspose-email-net/SampleNSF.nsf"),
        // java-libpst test resource (Apache-2.0 / LGPL-3.0 dual): version-36, 4 KiB-page OST.
        .file("opensource/java-libpst/example-2013.ost"),
        // Native Outlook 16 for Mac export (BSD-2-Clause; teverett/OLMReader test resource).
        .file("opensource/olmreader/outlook_example.olm"),
        // Earlier public pack: Microsoft's OFT and its import-ready wrapper — outside Git.
        .file("public-pack/01_outlook/Set_Up_Mobile_Thru_Admin.oft"),
        .file("public-pack/04_import_ready_eml/01_Set_Up_Mobile_Thru_Admin.eml"),
        // Owner's first pack ("Online mail fixtures and S/MIME") has not arrived (2026-11-07):
        // the same-message set and the S/MIME material cannot be named or hashed yet.
        .pending("native Outlook for Mac OLM + Apple Mail MBOX + derived EML of the same message (directive §3 row 6)"),
        .pending("S/MIME fixtures (signed / enveloped messages and their test identity)"),
    ]

    // MARK: - Status of one fixture

    enum Status: Equatable {
        /// Present, listed in its pack's SHA256SUMS, digest equal.
        case verified(URL)
        /// The root directory does not exist.
        case rootMissing(URL)
        /// The pack's SHA256SUMS is absent (pack not installed).
        case sumsMissing(URL)
        /// The file is absent.
        case fileMissing(URL)
        /// Present but not listed in SHA256SUMS — unknown provenance, a failure.
        case notListed(URL)
        /// Present and listed, bytes differ — a failure.
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

    // MARK: - SHA256SUMS

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
