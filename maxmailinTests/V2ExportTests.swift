import XCTest
import CryptoKit
@testable import maxmailin

/// Part O regression net: every bulk export streams from the store via an
/// `ArchiveSelectionScope` (symbolic query + exclusions, or explicit ids) —
/// scope exactness, cancellation cleanup, failure surfacing, and the
/// incremental (streamed) SHA-256 matching the whole-file hash for signed
/// exports.
///
/// Fixtures live in an isolated temp SQLite store (V2VerificationTests
/// style) — production singletons are never touched.
@MainActor
final class V2ExportTests: XCTestCase {

    // MARK: - Fixtures (isolated temp store)

    private struct Env {
        let root: URL
        let archive: ArchiveDataService
        let service: ArchiveExportService
        let fixtures: [MBOXParser.RawEmail]
    }

    private func makeEmail(i: Int) -> MBOXParser.RawEmail {
        let day = String(format: "%02d", 1 + (i % 28))
        let mid = "<fx-\(i)@test>"
        let subject = "Subject \(i)"
        let body = "streamed export body \(i)"
        return MBOXParser.RawEmail(
            headers: [
                "Message-ID": mid,
                "Subject": subject,
                "From": "a@b.com",
                "To": "c@d.com",
                "Date": "Wed, \(day) Jan 2025 14:30:00 +0000"
            ],
            rawSource: "Message-ID: \(mid)\nSubject: \(subject)\n\n\(body)",
            messageType: "email",
            attachments: [],
            timestamp: "2025-01-\(day)T14:30:00Z",
            domains: ["b.com"],
            plainBody: body,
            htmlBody: ""
        )
    }

    /// ~200-row fixture in an isolated temp SQLite store; removed on teardown.
    private func makeEnv(count: Int = 200) async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-exports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let fixtures = (0..<count).map { makeEmail(i: $0) }
        try await store.insertBatch(fixtures, batchSize: 100)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        return Env(root: root, archive: archive,
                   service: ArchiveExportService(archive: archive), fixtures: fixtures)
    }

    // MARK: - (a) Scope/count exactness — CSV over a symbolic query + exclusions

    /// A "Select All minus deselected" CSV export contains EVERY matching id
    /// EXACTLY once — no drops, no duplicates, exclusions honored.
    func testCSVQueryScopeWithExclusionsExactlyOnce() async throws {
        let env = try await makeEnv()
        let excluded = Set(env.fixtures.prefix(10).map(\.id))
        let expected = Set(env.fixtures.map(\.id)).subtracting(excluded)

        let url = env.root.appendingPathComponent("out.csv")
        var ticks = 0
        let result = try await env.service.export(
            scope: .query(.all, exclusions: excluded),
            format: .csvSummaries, to: url, batchSize: 37
        ) { _ in ticks += 1 }

        XCTAssertEqual(result.recordsWritten, 190, "records = matching minus exclusions")
        XCTAssertTrue(result.completed)
        XCTAssertGreaterThan(ticks, 1, "progress per bounded batch (streamed, not one shot)")

        // Parse the id column: every expected id exactly once.
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").dropFirst()   // header
        let ids = lines.compactMap { UUID(uuidString: String($0.split(separator: ",")[0])) }
        XCTAssertEqual(ids.count, 190, "one row per record")
        XCTAssertEqual(Set(ids), expected, "every matching id exported")
        XCTAssertEqual(Set(ids).count, ids.count, "no id exported twice")
        XCTAssertTrue(Set(ids).isDisjoint(with: excluded), "exclusions honored")

        // Scope count agrees with what was streamed.
        let counted = try await env.archive.count(scope: .query(.all, exclusions: excluded))
        XCTAssertEqual(counted, 190)
    }

    /// Word (.doc) list export: one streamed Office-HTML document containing
    /// every scoped email exactly once, HTML-escaped, honoring the limit.
    func testWordArchiveExport_streamedCompleteAndEscaped() async throws {
        let env = try await makeEnv(count: 40)
        let url = env.root.appendingPathComponent("out.doc")

        let result = try await env.service.exportWordArchive(
            scope: .query(.all, exclusions: []), to: url)
        XCTAssertEqual(result.recordsWritten, 40)
        XCTAssertFalse(result.cancelled)

        let doc = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(doc.contains("schemas-microsoft-com:office:word"), "Word-flavored HTML")
        for i in 0..<40 {
            XCTAssertTrue(doc.contains("Subject \(i)"), "email \(i) present")
        }
        XCTAssertEqual(doc.components(separatedBy: "<div class=\"email\">").count - 1, 40,
                       "exactly one section per email")

        // Free-tier limit: only the first N emails are written.
        let capped = env.root.appendingPathComponent("capped.doc")
        let cappedResult = try await env.service.exportWordArchive(
            scope: .query(.all, exclusions: []), to: capped, limit: 10)
        XCTAssertEqual(cappedResult.recordsWritten, 10)
        let cappedDoc = try String(contentsOf: capped, encoding: .utf8)
        XCTAssertEqual(cappedDoc.components(separatedBy: "<div class=\"email\">").count - 1, 10)
        XCTAssertTrue(cappedDoc.hasSuffix("</body></html>"), "capped output is still a complete document")
    }

    /// Per-message EML folder export over an EXPLICIT id scope: exactly one
    /// .eml per selected message, each Message-ID appearing exactly once.
    func testEMLFilesExplicitScopeExactlyOnce() async throws {
        let env = try await makeEnv()
        let range = 20..<60
        let subset = Set(env.fixtures[range].map(\.id))
        let folder = env.root.appendingPathComponent("eml", isDirectory: true)

        let result = try await env.service.exportEMLFiles(scope: .explicit(subset), to: folder)
        XCTAssertEqual(result.recordsWritten, 40)
        XCTAssertTrue(result.completed)

        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
        XCTAssertEqual(files.count, 40, "one .eml per selected message")

        var occurrences: [Int: Int] = [:]
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for i in range where content.contains("Message-ID: <fx-\(i)@test>") {
                occurrences[i, default: 0] += 1
            }
        }
        for i in range {
            XCTAssertEqual(occurrences[i], 1, "message fx-\(i) exported exactly once")
        }
    }

    // MARK: - (b) Cancellation cleans up the partial artifact

    /// Cancelling mid-stream leaves NO partial file behind.
    func testCancellationLeavesNoPartialArtifact() async throws {
        let env = try await makeEnv()
        let url = env.root.appendingPathComponent("cancelled.txt")

        final class TaskBox { var task: Task<ArchiveExportResult, Error>? }
        let box = TaskBox()
        box.task = Task { @MainActor in
            try await env.service.exportTextDocument(
                scope: .query(.all, exclusions: []), to: url, batchSize: 20,
                onProgress: { done, _ in
                    if done >= 20 { box.task?.cancel() }   // cancel mid-export
                },
                row: { email, _ in email.id.uuidString + "\n" }
            )
        }

        let result = try? await box.task!.value
        if let result {
            XCTAssertTrue(result.cancelled, "run reports cancellation")
            XCTAssertLessThan(result.recordsWritten, 200, "did not run to completion")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "partial artifact removed on cancellation")
    }

    /// Cancelling a per-message folder export removes every file written so far.
    func testCancellationCleansUpMessageFiles() async throws {
        let env = try await makeEnv()
        let folder = env.root.appendingPathComponent("eml-cancel", isDirectory: true)

        final class TaskBox { var task: Task<ArchiveExportResult, Error>? }
        let box = TaskBox()
        box.task = Task { @MainActor in
            try await env.service.exportEMLFiles(
                scope: .query(.all, exclusions: []), to: folder,
                onProgress: { done, _ in
                    if done >= 20 { box.task?.cancel() }
                }
            )
        }

        _ = try? await box.task!.value
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "no partial per-message files survive cancellation")
    }

    // MARK: - (c) Failure surfaces an error (and cleans up)

    /// An unwritable destination throws; nothing half-written is left behind.
    func testFailureSurfacesErrorAndCleansUp() async throws {
        let env = try await makeEnv(count: 50)

        // 1. Destination directory does not exist → error surfaced.
        let bad = env.root.appendingPathComponent("no-such-dir/out.csv")
        var thrown: Error?
        do {
            _ = try await env.service.exportDetailedCSV(scope: .query(.all, exclusions: []), to: bad)
        } catch { thrown = error }
        XCTAssertNotNil(thrown, "failure is surfaced, not swallowed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))

        // 2. Mid-stream row failure → error surfaced AND partial file removed.
        struct Boom: Error {}
        let url = env.root.appendingPathComponent("midfail.txt")
        thrown = nil
        do {
            _ = try await env.service.exportTextDocument(
                scope: .query(.all, exclusions: []), to: url, batchSize: 10
            ) { _, index in
                if index >= 25 { throw Boom() }
                return "row \(index)\n"
            }
        } catch { thrown = error }
        XCTAssertTrue(thrown is Boom, "row failure propagates")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "partial artifact removed on failure")
    }

    // MARK: - (d) Incremental hash == whole-file hash for a signed export

    /// The SHA-256 computed incrementally while streaming must equal the hash
    /// of the finished artifact, and the Ed25519 signature must verify via the
    /// streaming (chunked) verifier.
    func testIncrementalHashMatchesWholeFileHashForSignedExport() async throws {
        let env = try await makeEnv(count: 60)
        let url = env.root.appendingPathComponent("hash_manifest.csv")

        let result: ArchiveExportResult
        do {
            result = try await env.service.exportHashManifest(scope: .query(.all, exclusions: []), to: url)
        } catch let error as MaxmailinError {
            throw XCTSkip("signing keychain unavailable in this test environment: \(error)")
        }

        XCTAssertEqual(result.recordsWritten, 60)
        let whole = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(result.sha256Hex, whole,
                       "incremental (streamed) digest equals whole-file digest")

        // Companion .sig verifies over the digest via the chunked verifier.
        let sigURL = try XCTUnwrap(result.signatureURL)
        let signature = try Data(contentsOf: sigURL)
        let publicKey = try ExportSigner.shared.publicKeyBytes()
        XCTAssertTrue(ExportSigner.shared.verifyStreamedFile(url, signature: signature, publicKey: publicKey),
                      "Ed25519 signature over the streamed digest verifies")

        // Digest sidecar records the same hex.
        let sidecar = try String(contentsOf: url.appendingPathExtension("sha256"), encoding: .utf8)
        XCTAssertEqual(sidecar, whole)
    }
}
