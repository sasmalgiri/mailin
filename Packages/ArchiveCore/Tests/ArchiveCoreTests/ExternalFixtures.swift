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
        // Owner's pack "Online mail fixtures and S/MIME" (directive 2026-11-07 §3) was supplied as a
        // ChatGPT library file (libfile_d408d1057be08191aeabaa4482bc175d) and has never been saved on
        // this Mac. With the owner's permission of 2026-11-09 it is replaced by `owner-pack/` made here
        // (README.md in each directory says how; acceptance tests: `OwnerPackFixtureTests`):
        //   smime/   synthetic S/MIME set (OpenSSL 3.5.1, Scripts/r9_make_smime_fixtures.sh)
        //   native/  Apple-Mail-16-written mbox + the .eml of the same six synthetic messages
        // Pinned digests below; `owner-pack/SHA256SUMS` must list the same.
    ] + ownerPackDigests.keys.sorted().map { Requirement.file($0) } + [
        // Outlook for Mac is not installed on this Mac, so the native OLM of the same messages cannot be
        // made here; the MBOX + EML parts are `native/` above. Stays pending until an Outlook export exists.
        .pending("native Outlook for Mac OLM of the same messages as owner-pack/native/ (directive §3 row 6) — needs Outlook for Mac; install under <root>/owner-pack/native/ and list it in owner-pack/SHA256SUMS"),
    ]

    /// R9 owner pack (made 2026-11-09 with the owner's permission): path → SHA-256.
    static let ownerPackDigests: [String: String] = [
        "owner-pack/smime/ca.pem": "93c5f5ecde2f00af7f22e4aa8f1e88ee84f6fc4c21e6ea0a97d456a8b1cd4cb7",
        "owner-pack/smime/alice.pem": "57be7d26dc7cd5e372005ba964bf90044d6fe97c76ffbd2ebcff62ea063205c8",
        "owner-pack/smime/alice.p12": "89a705b95ea16dad64b3988c670d23f235a30e7eae0c582c05a96d6e11a68758",
        "owner-pack/smime/bob.pem": "32a3faee8b02353ad78a4b8b2dae8273090ff59de550e06bcc64937a9769de36",
        "owner-pack/smime/bob.p12": "969596471340ec64736f36782ab4655ae14a8249c49a708ac12078807e2ae1a5",
        "owner-pack/smime/entity.mime": "769b97c8b1bcf3552ffa31b5e20e5dd10d7d501979e70cc23416cddde6bb8ec3",
        "owner-pack/smime/ledger.txt": "f8cd9d43518c0886262a57bde6d64e3e9c15a00a8ceb42b33a3cd7de16489c3c",
        "owner-pack/smime/signed-opaque-rsa.eml": "4eb3e8b80f5dbaab0219165fccc6a0d5a61f0cf86acc1905f77f01e4c19a028c",
        "owner-pack/smime/signed-opaque-rsa.p7m": "068acf09721018f4f213bf8b585e592a31ecf578610981ef9fa0a332ff98d31b",
        "owner-pack/smime/signed-detached-rsa.eml": "4650b36f7c65468fc1f128c9a63f909f50809d275cb11456e97fed41782c2190",
        "owner-pack/smime/signed-detached-tampered.eml": "8cecf9a1d95ed7b3273d3e6576671bfeea3b3f9f91311a4fa90d7f29ad54f6fc",
        "owner-pack/smime/signed-opaque-ec.eml": "16ebe811b5a9e1889aa8a27a156236e61a0eb9e3e4712b92367fb039bbc256b2",
        "owner-pack/smime/enveloped-rsa.eml": "2ff5221d8b5d187244f91f27f6838e1ff444439f83919c079e7244a565f5fd2b",
        "owner-pack/smime/enveloped-rsa.p7m": "59308b84123b11e1358531ae6d4e47a0f4a6badb61e5c3e522f957292966ccce",
        "owner-pack/smime/enveloped-ec.eml": "43f57c0ece764712a8a44f3161cc0c5b22186f56d3781513bc790d416de6b47e",
        "owner-pack/smime/enveloped-ec-gcm.p7m": "dc44f18556bd7e6e00ff53573afe8f9d2b4c9ca18f376fdc4e9fdcdb5d7132d7",
        "owner-pack/smime/signed-then-enveloped.eml": "cf07e1e88724901e4026e1afe18896e467a0c2d0324de95b7a77e3abd207e45e",
        "owner-pack/native/apple-mail-export/R9-native.mbox/mbox": "f314bc9eb8a762659f1da445a082f6c6ecd4ee245aed0f5c244d07193b059332",
        "owner-pack/native/apple-mail-export/R9-native.mbox/table_of_contents": "4c28eca9f19a2281bee74fbe5a1a910a35346a21b26b70895763877c6c602df3",
        "owner-pack/native/eml/r9-native-01.eml": "b000ae44569cc7cf28b7153eeae026808db6638e56b1efe52caaa3db2cf24e9a",
        "owner-pack/native/eml/r9-native-02.eml": "8e19dd311d9dad591d193de3da56e12c1c1854a528673b4032cb9a1bb2569113",
        "owner-pack/native/eml/r9-native-03.eml": "4d66d9c254cd40c557f55456302814d2839cabf6ec3aeff99e3bbb31788ec583",
        "owner-pack/native/eml/r9-native-04.eml": "988a5ebc652047aa791cdc63e3b53ae2c552ac9e387c36874db0041582675d78",
        "owner-pack/native/eml/r9-native-05.eml": "acd7b9fdcf4ba78c465070a1547c16e6f97d0aae3e7caf26005dfe7d6b3a9102",
        "owner-pack/native/eml/r9-native-06.eml": "b6b9ead95a962b6c2c732a980fa1c8523c4ab7152f812ca1ac742a0cf5f44ad8",
        "owner-pack/native/source/R9-native.mbox": "496860db369a00ca5881f97276a8adeeb43141fdc5fb7f07a89874f0f8f6a31b",
        "owner-pack/native/source/source-inventory.json": "11e1d2f504aa87e5af2e310cf493d0664c455152fe4cc12f1ccec8d1b6b24499",
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
