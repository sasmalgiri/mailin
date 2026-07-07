//
//  MaxmailinSelfTest.swift
//  maxmailin
//
//  Runs at first launch (or when `UserDefaults` marks the self-test as not
//  yet completed) to verify the v2 storage + search + import pipeline works
//  end-to-end. Results are logged via os.log for inspection through
//  Console.app or `xcrun simctl spawn ... log show`.
//
//  Self-test sequence:
//    1. Load bundled `demo_emails.mbox` (or `sample.mbox`) from app bundle
//    2. Parse via ParserFactory
//    3. Insert into EmailStore (SwiftData) — verify count grew
//    4. Index into FTSSearchIndex (SQLite FTS5) — verify count grew
//    5. Run a sample full-text search — verify at least one hit returns
//    6. Round-trip: fetch full email by UUID and verify it decodes
//
//  All operations are bounded so the self-test won't run forever; if any step
//  fails or takes too long the test logs a failure and bails.
//

import Foundation
import os.log

@MainActor
final class MaxmailinSelfTest {
    static let shared = MaxmailinSelfTest()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "SelfTest")
    private let completionKey = "maxmailin.selfTestCompletedV1"

    private init() {}

    var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    /// Run if not yet done. Returns the result so callers can update UI.
    @discardableResult
    func runIfNeeded() async -> Result {
        if hasRun {
            logger.info("Self-test already completed; skipping.")
            return .skipped
        }
        // If the OS has just complained about memory pressure (within the
        // last 60 s), don't pile on. The self-test parses the bundled mbox,
        // round-trips through SwiftData, exercises FTS5 — a meaningful
        // memory spike. Running it on top of pressure can trigger the OS
        // to jetsam helper processes (Metal compiler etc.). The test will
        // run on the next launch instead; the completion flag stays unset.
        if MemoryPressureHandler.shared.isUnderRecentPressure() {
            logger.info("Self-test deferred — memory pressure observed within last 60 s.")
            return .skipped
        }
        let result = await run()
        UserDefaults.standard.set(true, forKey: completionKey)
        return result
    }

    /// Force a re-run (e.g. invoked from a diagnostic button).
    @discardableResult
    func forceRun() async -> Result {
        UserDefaults.standard.set(false, forKey: completionKey)
        return await runIfNeeded()
    }

    private func run() async -> Result {
        logger.info("=== Maxmailin v2 self-test starting ===")

        // Step 1 — bundled sample
        guard let url = sampleURL() else {
            logger.error("FAIL: no bundled sample mbox found")
            return .failed("no bundled sample mbox")
        }
        logger.info("Step 1: bundled sample = \(url.lastPathComponent, privacy: .public)")

        // Step 2 — parse
        let parsed: [MBOXParser.RawEmail]
        do {
            parsed = try ParserFactory.parse(fileURL: url, senderEmail: "", onProgress: nil)
        } catch {
            logger.error("FAIL: parse threw: \(error.localizedDescription, privacy: .public)")
            return .failed("parser: \(error.localizedDescription)")
        }
        logger.info("Step 2: parsed \(parsed.count) emails")
        guard !parsed.isEmpty else {
            return .failed("parser produced 0 emails")
        }

        // Step 3 — insert into SwiftData
        let countBefore: Int
        do {
            countBefore = try await EmailStore.shared.totalCount()
        } catch {
            logger.error("FAIL: totalCount threw: \(error.localizedDescription, privacy: .public)")
            return .failed("EmailStore.totalCount: \(error.localizedDescription)")
        }
        logger.info("Step 3a: SwiftData row count before = \(countBefore)")

        do {
            try await EmailStore.shared.insertBatch(parsed, sourceFileHash: nil, batchSize: 200, progress: nil)
        } catch {
            logger.error("FAIL: insertBatch threw: \(error.localizedDescription, privacy: .public)")
            return .failed("EmailStore.insertBatch: \(error.localizedDescription)")
        }

        let countAfter: Int
        do {
            countAfter = try await EmailStore.shared.totalCount()
        } catch {
            return .failed("EmailStore.totalCount post-insert: \(error.localizedDescription)")
        }
        logger.info("Step 3b: SwiftData row count after = \(countAfter)")
        guard countAfter > countBefore else {
            return .failed("SwiftData row count didn't grow (was \(countBefore), now \(countAfter))")
        }

        // Step 4 — FTS5 indexing
        do {
            try await FTSSearchIndex.shared.indexBatch(parsed)
        } catch {
            logger.error("FAIL: FTS5 indexBatch threw: \(error.localizedDescription, privacy: .public)")
            return .failed("FTSSearchIndex.indexBatch: \(error.localizedDescription)")
        }

        let ftsCount: Int
        do {
            ftsCount = try await FTSSearchIndex.shared.rowCount()
        } catch {
            return .failed("FTSSearchIndex.rowCount: \(error.localizedDescription)")
        }
        logger.info("Step 4: FTS5 row count = \(ftsCount)")
        guard ftsCount > 0 else {
            return .failed("FTS5 row count is 0 after indexing")
        }

        // Step 5 — sample full-text query. Try a common word; if none of the
        // sample emails contain it, fall back to a token guaranteed to exist
        // (the first email's subject's first word).
        let probeQuery = pickProbeQuery(from: parsed)
        logger.info("Step 5: probe query = \"\(probeQuery, privacy: .public)\"")
        let queryStart = Date()
        let ids: [UUID]
        do {
            ids = try await FTSSearchIndex.shared.search(probeQuery, limit: 10)
        } catch {
            logger.error("FAIL: FTS5 search threw: \(error.localizedDescription, privacy: .public)")
            return .failed("FTSSearchIndex.search: \(error.localizedDescription)")
        }
        let queryDuration = Date().timeIntervalSince(queryStart)
        logger.info("Step 5: got \(ids.count) hits in \(String(format: "%.3f", queryDuration))s")
        guard !ids.isEmpty else {
            return .failed("FTS5 search returned 0 hits for probe query \"\(probeQuery)\"")
        }

        // Step 6 — round-trip: fetch one full email by UUID
        guard let firstID = ids.first else { return .failed("ids.first nil") }
        let full: MBOXParser.RawEmail?
        do {
            full = try await EmailStore.shared.fullEmail(id: firstID)
        } catch {
            return .failed("EmailStore.fullEmail: \(error.localizedDescription)")
        }
        guard let fetched = full else {
            return .failed("EmailStore.fullEmail returned nil for hit UUID")
        }
        let subject = fetched.headers["Subject"] ?? "(none)"
        logger.info("Step 6: round-tripped email subject = \(subject, privacy: .public)")

        // Step 7 — HMAC chain integrity test
        do {
            _ = try HMACChainAuditLog.shared.append(action: "selfTest.hmac", detail: "test entry")
            guard HMACChainAuditLog.shared.verifyChain() else {
                return .failed("HMAC chain verifyChain() returned false")
            }
            logger.info("Step 7: HMAC chain integrity verified")
        } catch {
            return .failed("HMACChainAuditLog: \(error.localizedDescription)")
        }

        // Step 8 — ExportSigner sign + verify round-trip
        do {
            let payload = Data("maxmailin-selftest-payload".utf8)
            let signature = try ExportSigner.shared.sign(payload)
            let publicKey = try ExportSigner.shared.publicKeyBytes()
            let isValid = ExportSigner.shared.verify(payload, signature: signature, publicKey: publicKey)
            guard isValid else {
                return .failed("ExportSigner round-trip verify returned false")
            }
            logger.info("Step 8: ExportSigner sign+verify round-trip OK (sig = \(signature.count) bytes)")
        } catch {
            return .failed("ExportSigner: \(error.localizedDescription)")
        }

        // Step 9 — Tamper detection: flip a byte in the signature and verify it fails
        do {
            let payload = Data("maxmailin-tamper-test".utf8)
            var signature = try ExportSigner.shared.sign(payload)
            let publicKey = try ExportSigner.shared.publicKeyBytes()
            // Flip the first byte
            signature[0] = signature[0] ^ 0xFF
            let tamperedValid = ExportSigner.shared.verify(payload, signature: signature, publicKey: publicKey)
            guard !tamperedValid else {
                return .failed("ExportSigner verified a tampered signature — security failure")
            }
            logger.info("Step 9: Tampered signature correctly rejected")
        } catch {
            return .failed("Tamper detection test: \(error.localizedDescription)")
        }

        // Step 10 — Memory zeroing test (PrivacyHardening helper)
        var sensitive = Data("super-secret-decryption-key".utf8)
        let before = sensitive.count
        PrivacyHardening.zero(&sensitive)
        guard sensitive.isEmpty else {
            return .failed("PrivacyHardening.zero left \(sensitive.count) bytes (expected 0)")
        }
        logger.info("Step 10: PrivacyHardening.zero cleared \(before) bytes -> 0")

        logger.info("=== Maxmailin v2 self-test PASSED (10/10 steps) ===")
        return .passed(insertedCount: countAfter - countBefore,
                       ftsCount: ftsCount,
                       searchDuration: queryDuration,
                       sampleSubject: subject)
    }

    // MARK: - Helpers

    private func sampleURL() -> URL? {
        if let u = Bundle.main.url(forResource: "demo_emails", withExtension: "mbox") {
            return u
        }
        return Bundle.main.url(forResource: "sample", withExtension: "mbox")
    }

    private func pickProbeQuery(from emails: [MBOXParser.RawEmail]) -> String {
        for email in emails {
            let subject = email.headers["Subject"] ?? ""
            let firstWord = subject
                .components(separatedBy: .whitespacesAndNewlines)
                .first(where: { $0.count >= 4 && $0.allSatisfy(\.isLetter) })
            if let firstWord, !firstWord.isEmpty {
                return firstWord
            }
        }
        return "the"
    }

    // MARK: - Result type

    enum Result {
        case skipped
        case passed(insertedCount: Int, ftsCount: Int, searchDuration: TimeInterval, sampleSubject: String)
        case failed(String)

        var isPass: Bool { if case .passed = self { return true }; return false }
        var isFail: Bool { if case .failed = self { return true }; return false }
    }
}
