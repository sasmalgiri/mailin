@testable import ArchiveCore
//
//  GoldCaseClosureTests.swift
//  maxmailinTests
//
//  Closes three checks the 2.1 line claimed but never had a test for:
//  the Bates-stamped PDF (gold case #9), predictive-coding ranking
//  (gold case #8), and the V3-D1 standalone-name redaction leak.
//
//  NOT YET EXECUTED — written under an explicit instruction to implement
//  first and test afterwards. Signatures are aligned with the real APIs
//  (`BatesPDFRenderer.render(lines:metadata:to:)`,
//  `PredictiveCodingEngine.buildVectors/tagRelevant/predictionScore`,
//  `RedactionEngine.redactPerson(emails:name:email:) -> [RedactedEmail]`),
//  so the assertions are against the shipping shape of the code.
//

import XCTest
import PDFKit
import NaturalLanguage
import CryptoKit
@testable import maxmailin

private func probeEmail(subject: String, body: String) -> MBOXParser.RawEmail {
    MBOXParser.RawEmail(
        headers: [
            "From": "sender@example.com",
            "To": "recipient@example.com",
            "Subject": subject,
            "Date": "Tue, 14 Mar 2017 09:41:00 +0000",
            "Message-ID": "<gold-\(UUID().uuidString)@example.com>"
        ],
        rawSource: "",
        messageType: "email",
        attachments: [],
        timestamp: "Tue, 14 Mar 2017 09:41:00 +0000",
        domains: ["example.com"],
        plainBody: body,
        htmlBody: ""
    )
}

// MARK: - Gold case #9: the Bates stamp is really on the page

final class BatesPDFReadBackTests: XCTestCase {

    /// The claim was that a Bates-stamped PDF shows the number on the page.
    /// Only the code path had ever been inspected; PDFKit read-back is what
    /// actually proves it.
    func testBatesStamp_isVisibleOnPageOne() throws {
        let stamp = "MAILIN000001"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bates-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let pages = BatesPDFRenderer.render(
            lines: ["Subject: Exhibit A", "", "the quoted passage under review"],
            metadata: .init(batesNumber: stamp,
                            caseNumber: "CASE-2026-0001",
                            examiner: "Test Examiner"),
            to: out)

        XCTAssertGreaterThan(pages, 0, "the renderer must report at least one page")
        let document = try XCTUnwrap(PDFDocument(url: out), "PDFKit must be able to open the export")
        XCTAssertEqual(document.pageCount, pages, "reported page count must match the file")

        let text = try XCTUnwrap(document.page(at: 0)?.string)
        XCTAssertTrue(text.contains(stamp),
                      "page 1 must carry \(stamp); page text was: \(text.prefix(300))")
        XCTAssertTrue(text.contains("quoted passage"),
                      "the stamp must not displace the exhibit content")
    }

    /// Every page of a multi-page production must carry the stamp — that is
    /// precisely what a production set gets challenged on.
    func testBatesStamp_appearsOnEveryPage() throws {
        let stamp = "MAILIN000042"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bates-multi-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let lines = (1...400).map { "line \($0) of the exhibit body text" }
        let pages = BatesPDFRenderer.render(
            lines: lines, metadata: .init(batesNumber: stamp), to: out)
        XCTAssertGreaterThan(pages, 1, "400 lines should paginate past one page")

        let document = try XCTUnwrap(PDFDocument(url: out))
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertTrue(text.contains(stamp),
                          "page \(index + 1) of \(document.pageCount) is missing the Bates stamp")
        }
    }

    /// When a hash is supplied it must appear on the page — it is the tie
    /// between the exhibit and the source bytes.
    func testBatesStamp_carriesTheSourceHashWhenGiven() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bates-hash-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let hash = "9f2c1a77e5b3d0c4"
        _ = BatesPDFRenderer.render(
            lines: ["body"],
            metadata: .init(batesNumber: "MAILIN000007", md5Hash: hash),
            to: out)

        let document = try XCTUnwrap(PDFDocument(url: out))
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains(hash),
                      "the exhibit must show its source hash; page text was: \(text.prefix(300))")
    }
}

// MARK: - Gold case #8: predictive coding actually ranks

@MainActor
final class PredictiveCodingRankingTests: XCTestCase {

    private var taggedIDs: [UUID] = []

    /// The engine is a persisted singleton, so every label written here has
    /// to be withdrawn — otherwise the tests leak training data into the
    /// user's archive scoring.
    override func tearDown() async throws {
        let engine = PredictiveCodingEngine.shared
        for id in taggedIDs { engine.removeTag(id) }
        taggedIDs.removeAll()
    }

    /// Training is a detached task that publishes back on the main actor, so
    /// scores are not readable the instant a label is applied.
    private func awaitTraining(_ engine: PredictiveCodingEngine,
                               timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !engine.isTraining && !engine.predictions.isEmpty { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("predictive coding did not finish training within \(timeout)s")
    }

    private func label(relevant: [MBOXParser.RawEmail],
                       irrelevant: [MBOXParser.RawEmail],
                       on engine: PredictiveCodingEngine) {
        for item in relevant {
            engine.tagRelevant(item.id)
            taggedIDs.append(item.id)
        }
        for item in irrelevant {
            engine.tagIrrelevant(item.id)
            taggedIDs.append(item.id)
        }
    }

    /// Skips rather than fails when the OS ships no English sentence
    /// embedding: that is an environment fact, not a defect in the engine.
    private func requireEmbedding() throws {
        if NLEmbedding.sentenceEmbedding(for: .english) == nil {
            throw XCTSkip("no English sentence embedding on this host, so vectors cannot be built")
        }
    }

    /// Gold case #8: after training, a held-out responsive document must
    /// outrank a held-out irrelevant one.
    func testTAR_relevantOutranksIrrelevant() async throws {
        try requireEmbedding()
        let engine = PredictiveCodingEngine.shared

        let responsive = [
            "the shipment of turbine parts was delayed at customs again",
            "customs held the turbine consignment pending the invoice",
            "we re-routed the turbine shipment through Rotterdam"
        ].map { probeEmail(subject: "Shipment", body: $0) }

        let nonResponsive = [
            "lunch options for the offsite next Thursday",
            "please update your timesheet before Friday",
            "the printer on the third floor is jammed again"
        ].map { probeEmail(subject: "Admin", body: $0) }

        let heldOutResponsive = probeEmail(
            subject: "Shipment", body: "the turbine shipment cleared customs this morning")
        let heldOutIrrelevant = probeEmail(
            subject: "Admin", body: "the coffee machine is being serviced tomorrow")

        engine.buildVectors(
            from: responsive + nonResponsive + [heldOutResponsive, heldOutIrrelevant])
        label(relevant: responsive, irrelevant: nonResponsive, on: engine)
        try await awaitTraining(engine)

        let relevantScore = try XCTUnwrap(engine.predictionScore(for: heldOutResponsive.id),
                                          "the held-out responsive document must be scored")
        let irrelevantScore = try XCTUnwrap(engine.predictionScore(for: heldOutIrrelevant.id),
                                            "the held-out irrelevant document must be scored")

        XCTAssertGreaterThan(relevantScore, irrelevantScore,
                             "a responsive document must outrank unrelated office traffic "
                             + "(got \(relevantScore) vs \(irrelevantScore))")
    }

    /// Ranking a mixed held-out set must put the responsive documents on
    /// top — the property a reviewer actually relies on.
    func testTAR_rankingPutsResponsiveFirst() async throws {
        try requireEmbedding()
        let engine = PredictiveCodingEngine.shared

        let relevant = [
            "breach of the supply agreement clause 7",
            "clause 7 was not honoured by the supplier",
            "the supply agreement termination notice"
        ].map { probeEmail(subject: "Dispute", body: $0) }
        let irrelevant = [
            "team photo on Friday",
            "parking permit renewal",
            "canteen menu update"
        ].map { probeEmail(subject: "Admin", body: $0) }

        let heldOut = [
            probeEmail(subject: "Admin", body: "canteen menu for next week"),
            probeEmail(subject: "Dispute", body: "clause 7 breach escalated to counsel"),
            probeEmail(subject: "Admin", body: "parking permit for the new car"),
            probeEmail(subject: "Dispute", body: "supply agreement dispute timeline")
        ]

        engine.buildVectors(from: relevant + irrelevant + heldOut)
        label(relevant: relevant, irrelevant: irrelevant, on: engine)
        try await awaitTraining(engine)

        var scored: [(body: String, score: Double)] = []
        for item in heldOut {
            let score = try XCTUnwrap(engine.predictionScore(for: item.id),
                                      "every held-out document must be scored")
            scored.append((item.plainBody, score))
        }
        let ordered = scored.sorted { $0.score > $1.score }.map(\.body)
        let topTwo = ordered.prefix(2).joined(separator: " | ")

        XCTAssertTrue(topTwo.contains("clause 7"),
                      "the clause-7 document must rank in the top two; order was \(ordered)")
        XCTAssertTrue(topTwo.contains("supply agreement"),
                      "both responsive documents must outrank office traffic; order was \(ordered)")
    }

    /// With no labels at all there must be no predictions — an untrained
    /// engine must not hand a reviewer confident scores.
    func testTAR_withoutLabelsThereIsNoPrediction() async throws {
        try requireEmbedding()
        let engine = PredictiveCodingEngine.shared
        let lonely = probeEmail(subject: "Unlabelled", body: "nothing has been tagged yet")

        engine.buildVectors(from: [lonely])

        // Clear labels this process loaded from disk so the "no labels"
        // precondition really holds, then put them back.
        let restoreRelevant = engine.relevantIDs
        let restoreIrrelevant = engine.irrelevantIDs
        defer {
            engine.relevantIDs = restoreRelevant
            engine.irrelevantIDs = restoreIrrelevant
        }
        engine.relevantIDs = []
        engine.irrelevantIDs = []
        engine.removeTag(lonely.id)

        XCTAssertNil(engine.predictionScore(for: lonely.id),
                     "an untrained engine must not produce a score")
    }
}

// MARK: - Quarantined types were DELETED
//
// `EncryptedStorageLossTests` lived here. It pinned two facts about
// `EncryptedStorageManager` (raw source silently truncated to 2,000
// characters, so a restored message failed its own integrity hash) and
// guarded that neither it nor `PSTStreamingParser` gained a caller.
//
// Both files have now been removed from the target, so there is nothing left
// to guard. See REACHABILITY_AUDIT.md defects 18 and 19 for what they claimed
// and why wiring either up would have destroyed evidence or regressed
// large-PST import.

// MARK: - V3-E3/E4 sealed case bundles

/// The whole of `CaseBundleService` — export, seal verification, and the
/// attributed additive merge — had no production caller AND no test. E3/E4
/// shipped as enterprise features that could not be reached or, until now,
/// had never been executed at all.
@MainActor
final class CaseBundleTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The studio stores are singletons that persist to Application Support,
    /// so every test restores what it found.
    private func withIsolatedStudioStores(_ body: () throws -> Void) rethrows {
        let ach = ACHMatrixStore.shared.matrices
        let fact = FactEvidenceStore.shared.matrices
        let regs = ActionRegisterStore.shared.registers
        let desks = EvidenceDeskStore.shared.desks
        let cases = ReasoningCaseStore.shared.cases
        defer {
            ACHMatrixStore.shared.matrices = ach
            FactEvidenceStore.shared.matrices = fact
            ActionRegisterStore.shared.registers = regs
            EvidenceDeskStore.shared.desks = desks
            ReasoningCaseStore.shared.cases = cases
        }
        ACHMatrixStore.shared.matrices = []
        FactEvidenceStore.shared.matrices = []
        ActionRegisterStore.shared.registers = []
        EvidenceDeskStore.shared.desks = []
        ReasoningCaseStore.shared.cases = []
        try body()
    }

    private func bundledEmail() -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<bundle@example.com>", "Subject": "Handoff",
                      "From": "a@example.com", "To": "b@example.com",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000"],
            rawSource: "From a@example.com\nSubject: Handoff\n\nevidence body\n",
            messageType: "received", attachments: [],
            timestamp: "2017-03-14T09:41:00Z", domains: ["example.com"],
            plainBody: "evidence body", htmlBody: "")
    }

    /// Export → open round trip: the seal verifies and every field survives.
    func testExportedBundleVerifiesAndRoundTrips() throws {
        try withIsolatedStudioStores {
            ACHMatrixStore.shared.matrices = [ACHMatrixModel(title: "Working hypothesis")]
            let url = root.appendingPathComponent("case.mailincase")

            try CaseBundleService.export(
                caseTitle: "Matter 42", emails: [bundledEmail()], note: "first handoff", to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a bundle file must be written")

            let (bundle, receipt) = try CaseBundleService.open(url: url)
            XCTAssertEqual(bundle.caseTitle, "Matter 42")
            XCTAssertEqual(bundle.note, "first handoff")
            XCTAssertEqual(bundle.emails.count, 1)
            XCTAssertEqual(bundle.achMatrices.count, 1)
            XCTAssertEqual(bundle.achMatrices.first?.title, "Working hypothesis")
            XCTAssertEqual(receipt.sha256Hex.count, 64)
            XCTAssertFalse(receipt.publicKeyBase64.isEmpty,
                           "the public key must travel with the seal so any machine can verify")

            // The per-email digest lets the receiver recompute independently.
            let expected = SHA256.hash(data: Data(bundledEmail().rawSource.utf8))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(bundle.emails.first?.sha256Hex, expected)
        }
    }

    /// A bundle modified after sealing is REFUSED, and the payload is never
    /// handed back. This is the enterprise rule the file header states.
    func testTamperedBundleIsRefusedWithoutYieldingThePayload() throws {
        try withIsolatedStudioStores {
            let url = root.appendingPathComponent("tampered.mailincase")
            try CaseBundleService.export(caseTitle: "Matter 42", emails: [bundledEmail()], to: url)

            // Re-encode the envelope around a payload one byte different, so
            // the digest cannot match. Editing the file text would risk
            // producing something that merely fails to decode.
            struct Envelope: Codable { var payloadBase64: String; var receipt: SealedReceipt }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var envelope = try dec.decode(Envelope.self, from: Data(contentsOf: url))
            var payload = try XCTUnwrap(Data(base64Encoded: envelope.payloadBase64))
            let original = payload
            payload[payload.count / 2] = payload[payload.count / 2] == 0x41 ? 0x42 : 0x41
            XCTAssertNotEqual(payload, original)
            envelope.payloadBase64 = payload.base64EncodedString()
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(envelope).write(to: url, options: .atomic)

            do {
                _ = try CaseBundleService.open(url: url)
                XCTFail("a tampered bundle must not open")
            } catch let error as CaseBundleService.BundleError {
                guard case .sealBroken(let result) = error else {
                    return XCTFail("expected sealBroken, got \(error)")
                }
                XCTAssertNotEqual(result, .valid)
                let message = try XCTUnwrap(error.errorDescription)
                XCTAssertTrue(message.contains("REFUSED"),
                              "the refusal must say so plainly: \(message)")
            }
        }
    }

    /// A file that is not a bundle at all is a named error, not a crash.
    func testNonBundleFileIsANamedError() throws {
        let url = root.appendingPathComponent("notabundle.mailincase")
        try Data("this is not JSON".utf8).write(to: url)
        XCTAssertThrowsError(try CaseBundleService.open(url: url)) { error in
            guard case .notABundle? = error as? CaseBundleService.BundleError else {
                return XCTFail("expected .notABundle, got \(error)")
            }
        }
    }

    /// Merge is ADDITIVE and attributed: an unseen artifact arrives labelled
    /// with the sender, and nothing local is overwritten.
    func testMergeAddsUnseenArtifactsLabelledWithTheSender() throws {
        try withIsolatedStudioStores {
            let incoming = ACHMatrixModel(title: "Their analysis")
            var bundle = CaseBundle(caseTitle: "Matter 42", exportedBy: "Ada",
                                    exportedAt: Date())
            bundle.achMatrices = [incoming]

            ACHMatrixStore.shared.matrices = [ACHMatrixModel(title: "My analysis")]
            let report = CaseBundleService.mergeArtifacts(from: bundle)

            XCTAssertEqual(report.artifactsAdded, 1)
            XCTAssertEqual(report.conflictsLabelled, 0)
            XCTAssertEqual(report.from, "Ada")
            XCTAssertEqual(ACHMatrixStore.shared.matrices.count, 2,
                           "the local artifact must survive the merge")
            XCTAssertTrue(ACHMatrixStore.shared.matrices.contains { $0.title == "My analysis" })
            XCTAssertTrue(ACHMatrixStore.shared.matrices.contains { $0.title == "Their analysis (from Ada)" },
                          "an incoming artifact must be attributed to its sender")
        }
    }

    /// Same id, different content: BOTH readings stand. The copy gets a fresh
    /// id so it can persist alongside, which is the point of E4 — a conflict is
    /// surfaced, never silently resolved.
    func testMergeKeepsBothSidesOfAConflict() throws {
        try withIsolatedStudioStores {
            let shared = UUID()
            let mine = ACHMatrixModel(id: shared, title: "Shared analysis")
            var theirs = ACHMatrixModel(id: shared, title: "Shared analysis")
            theirs.assumptionsNote = "they reached a different reading"

            ACHMatrixStore.shared.matrices = [mine]
            var bundle = CaseBundle(caseTitle: "Matter 42", exportedBy: "Ada", exportedAt: Date())
            bundle.achMatrices = [theirs]

            let report = CaseBundleService.mergeArtifacts(from: bundle)
            XCTAssertEqual(report.conflictsLabelled, 1)
            XCTAssertEqual(report.artifactsAdded, 0)

            let result = ACHMatrixStore.shared.matrices
            XCTAssertEqual(result.count, 2, "both readings must stand")
            XCTAssertEqual(Set(result.map(\.id)).count, 2,
                           "the conflict copy needs a fresh id or one of them is lost")
            XCTAssertTrue(result.contains { $0.id == shared && $0.assumptionsNote.isEmpty },
                          "my version must be untouched")
            XCTAssertTrue(result.contains { $0.title.contains("(from Ada)")
                                            && $0.assumptionsNote == "they reached a different reading" },
                          "their version must arrive attributed")
        }
    }

    /// Re-merging the same bundle must not multiply it — a handoff often
    /// arrives twice, and before merged ids were derived from (origin, sender)
    /// each pass filed another "conflict": three imports left four copies.
    func testMergingTheSameBundleTwiceIsIdempotent() throws {
        try withIsolatedStudioStores {
            var bundle = CaseBundle(caseTitle: "Matter 42", exportedBy: "Ada", exportedAt: Date())
            bundle.achMatrices = [ACHMatrixModel(title: "Their analysis")]

            let first = CaseBundleService.mergeArtifacts(from: bundle)
            XCTAssertEqual(first.artifactsAdded, 1)
            XCTAssertEqual(ACHMatrixStore.shared.matrices.count, 1)

            for pass in 2...4 {
                let again = CaseBundleService.mergeArtifacts(from: bundle)
                XCTAssertEqual(again.artifactsAdded, 0, "pass \(pass) must add nothing")
                XCTAssertEqual(again.conflictsLabelled, 0, "pass \(pass) is not a conflict")
                XCTAssertEqual(again.alreadyPresent, 1, "pass \(pass) must report it as already present")
                XCTAssertEqual(ACHMatrixStore.shared.matrices.count, 1,
                               "pass \(pass) left \(ACHMatrixStore.shared.matrices.count) copies")
            }
        }
    }

    /// If the sender revises an artifact and sends it again, that IS a change
    /// and both readings must stand — idempotency must not swallow real edits.
    func testARevisedArtifactFromTheSameSenderIsKeptAlongside() throws {
        try withIsolatedStudioStores {
            let origin = UUID()
            var bundle = CaseBundle(caseTitle: "Matter 42", exportedBy: "Ada", exportedAt: Date())
            bundle.achMatrices = [ACHMatrixModel(id: origin, title: "Their analysis")]
            _ = CaseBundleService.mergeArtifacts(from: bundle)
            XCTAssertEqual(ACHMatrixStore.shared.matrices.count, 1)

            var revised = ACHMatrixModel(id: origin, title: "Their analysis")
            revised.assumptionsNote = "revised after review"
            bundle.achMatrices = [revised]

            let second = CaseBundleService.mergeArtifacts(from: bundle)
            XCTAssertEqual(second.conflictsLabelled, 1)
            XCTAssertEqual(second.alreadyPresent, 0)
            XCTAssertEqual(ACHMatrixStore.shared.matrices.count, 2,
                           "a genuine revision must not be skipped as already present")
            XCTAssertTrue(ACHMatrixStore.shared.matrices.contains { $0.assumptionsNote == "revised after review" })
        }
    }
}

// MARK: - Concordance .dat load-file format

/// A superseded `ExportManager.generateConcordanceLoadFile` used \u{14} as both
/// the delimiter and the text qualifier — indistinguishable to a review
/// platform — and omitted BCC, the SHA-256 hash, the custodian and the tag. It
/// had no caller but carried the more obvious name, so it was removed. These
/// pin what the shipping path emits, so the convention cannot drift back.
@MainActor
final class ConcordanceLoadFileTests: XCTestCase {

    private let delimiter = "\u{14}"
    private let qualifier = "\u{FE}"

    func testHeader_usesDistinctDelimiterAndQualifier() {
        let header = ForensicManager.concordanceDATHeader
        XCTAssertTrue(header.contains(qualifier),
                      "the text qualifier must be þ (U+00FE), not the delimiter")
        XCTAssertTrue(header.contains(delimiter), "fields must be delimited by U+0014")
        XCTAssertFalse(header.contains("\(qualifier)\(qualifier)"),
                       "two qualifiers must never abut — that was the broken form")
    }

    func testHeader_carriesTheColumnsAProductionIsJudgedOn() {
        let header = ForensicManager.concordanceDATHeader
        for column in ["DOCID", "BEGBATES", "ENDBATES", "FROM", "TO", "CC", "BCC",
                       "SUBJECT", "DATESENT", "MSGID", "HASHSHA256", "CUSTODIAN", "TAG"] {
            XCTAssertTrue(header.contains(column), "missing column \(column)")
        }
    }

    func testRow_hasOneFieldPerHeaderColumnAndCarriesTheHash() {
        // A real rawSource, because the hash column is computed from it — a
        // fixture with none would make the assertion below vacuous.
        let email = MBOXParser.RawEmail(
            headers: ["From": "sender@example.com", "To": "recipient@example.com",
                      "Cc": "cc@example.com", "Bcc": "bcc@example.com",
                      "Subject": "Production probe",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000",
                      "Message-ID": "<dat-probe@example.com>"],
            rawSource: "From sender@example.com\nSubject: Production probe\n\nbody\n",
            messageType: "email", attachments: [],
            timestamp: "Tue, 14 Mar 2017 09:41:00 +0000", domains: ["example.com"],
            plainBody: "body", htmlBody: "")
        let row = ForensicManager.shared.concordanceDATRow(email, bates: "MAIL000001")

        func fieldCount(_ line: String) -> Int {
            line.trimmingCharacters(in: .newlines).components(separatedBy: delimiter).count
        }
        XCTAssertEqual(fieldCount(row), fieldCount(ForensicManager.concordanceDATHeader),
                       "a row with a different field count than the header cannot be loaded")
        XCTAssertTrue(row.hasSuffix("\n"), "rows must be newline-terminated")

        let expected = ForensicManager.computeEmailHash(rawSource: email.rawSource).sha256
        XCTAssertEqual(expected.count, 64, "a SHA-256 hex digest is 64 characters")
        XCTAssertTrue(row.contains(expected),
                      "the row must carry the message's SHA-256 — the column the removed version dropped")
        XCTAssertTrue(row.contains("bcc@example.com"),
                      "BCC is another column the removed version dropped")
    }
}

// MARK: - Defect V3-D1: the standalone-name redaction leak

final class RedactionDefectV3D1Tests: XCTestCase {

    private func email(_ body: String) -> MBOXParser.RawEmail {
        probeEmail(subject: "Redaction probe", body: body)
    }

    /// The exact reported leak: "Priya will bring it." survived redaction
    /// because the rules covered the full name and the address but not a
    /// standalone first-name token. The fix is in `personRedactionRules`;
    /// this pins it so it cannot silently regress.
    func testStandaloneFirstNameIsRedacted() throws {
        let results = RedactionEngine.redactPerson(
            emails: [email("Priya will bring it. Contact Priya Sharma at priya.sharma@example.com.")],
            name: "Priya Sharma",
            email: "priya.sharma@example.com")

        let redacted = try XCTUnwrap(results.first)
        XCTAssertFalse(redacted.body.contains("Priya"),
                       "a standalone first name must not survive: \(redacted.body)")
        XCTAssertFalse(redacted.body.contains("Sharma"), redacted.body)
        XCTAssertFalse(redacted.body.contains("priya.sharma@example.com"), redacted.body)
        XCTAssertTrue(redacted.body.contains("[REDACTED"),
                      "the body must show a redaction marker: \(redacted.body)")
        XCTAssertGreaterThan(redacted.redactionCount, 0, "redactions must be counted")
    }

    /// Case must not be an escape hatch — "priya" and "PRIYA" leak just as
    /// badly as "Priya".
    func testRedactionIsCaseInsensitive() throws {
        let results = RedactionEngine.redactPerson(
            emails: [email("PRIYA said so, and priya agreed, and Priya confirmed.")],
            name: "Priya Sharma")
        let redacted = try XCTUnwrap(results.first)
        XCTAssertFalse(redacted.body.lowercased().contains("priya"),
                       "case must not defeat redaction: \(redacted.body)")
    }

    /// The LAW-14 validator must find nothing in redacted output — the second
    /// pass that `RedactionConfigView.exportRedacted()` runs before it writes
    /// anything, and that blocks the export when it finds a surviving term.
    func testValidatorFindsNoLeakInRedactedOutput() throws {
        let results = RedactionEngine.redactPerson(
            emails: [email("Priya will bring it. Ask Priya Sharma or priya.sharma@example.com.")],
            name: "Priya Sharma",
            email: "priya.sharma@example.com")
        let redacted = try XCTUnwrap(results.first)

        let leaks = RedactionEngine.validateRedaction(
            text: redacted.body, targets: ["Priya", "Sharma", "priya.sharma@example.com"])
        XCTAssertTrue(leaks.isEmpty, "validator found surviving targets: \(leaks)")

        let personLeaks = RedactionEngine.validatePersonRedaction(
            redacted, name: "Priya Sharma", email: "priya.sharma@example.com")
        XCTAssertTrue(personLeaks.isEmpty,
                      "person-level validation must be clean: \(personLeaks)")
    }

    /// And the validator must be capable of failing — one that always passes
    /// would prove nothing about the test above.
    func testValidatorDetectsAnActualLeak() {
        let leaks = RedactionEngine.validateRedaction(
            text: "Priya will bring it.", targets: ["Priya"])
        XCTAssertEqual(leaks, ["Priya"], "the validator must catch a plain leak")
    }

    /// Headers are produced material too: From/To/Subject must be redacted,
    /// not only the body.
    func testRedactionCoversHeaderFields() throws {
        var probe = email("body text")
        probe.headers["From"] = "Priya Sharma <priya.sharma@example.com>"
        probe.headers["To"] = "Priya Sharma <priya.sharma@example.com>"
        probe.headers["Subject"] = "Call with Priya"

        let results = RedactionEngine.redactPerson(
            emails: [probe], name: "Priya Sharma", email: "priya.sharma@example.com")
        let redacted = try XCTUnwrap(results.first)

        XCTAssertFalse(redacted.from.contains("Priya"), "From: \(redacted.from)")
        XCTAssertFalse(redacted.from.contains("priya.sharma@example.com"), "From: \(redacted.from)")
        XCTAssertFalse(redacted.to.contains("Priya"), "To: \(redacted.to)")
        XCTAssertFalse(redacted.subject.contains("Priya"), "Subject: \(redacted.subject)")
    }

    // MARK: The export gate

    /// Mirrors what `RedactionConfigView.exportRedacted()` now does: apply the
    /// default categories PLUS the generated person rules, then validate every
    /// item in the batch. This is the gate's pass path — if it ever fails, a
    /// legitimate export is being blocked, which is as much a defect as a leak.
    func testExportGate_passesAcrossTheWholeBatch() throws {
        let batch = [
            email("Priya will bring it."),
            email("Ask Priya Sharma about the invoice."),
            email("Sharma, Priya signed off on 2024-03-04."),
            email("Forwarded by P. Sharma <priya.sharma@example.com>."),
            email("Nothing sensitive in this one at all."),
        ]
        let rules = RedactionEngine.defaultRules
            + RedactionEngine.personRedactionRules(
                name: "Priya Sharma", email: "priya.sharma@example.com")
        let redacted = RedactionEngine.redactBatch(emails: batch, rules: rules)

        XCTAssertEqual(redacted.count, batch.count, "every email must appear in the output")

        var leaks = Set<String>()
        for item in redacted {
            leaks.formUnion(
                RedactionEngine.validatePersonRedaction(
                    item, name: "Priya Sharma", email: "priya.sharma@example.com"))
        }
        XCTAssertTrue(leaks.isEmpty,
                      "the gate would block a correct export over: \(leaks.sorted())")
    }

    /// And the person rules must be load-bearing. Without them the default
    /// categories — SSN, card, phone, … — match nothing in a name, so the gate
    /// blocks. This is the reason the gate exists: before it, this export was
    /// written to disk and handed over.
    func testExportGate_blocksWhenOnlyTheDefaultCategoriesAreApplied() {
        let redacted = RedactionEngine.redactBatch(
            emails: [email("Priya will bring it. Ask priya.sharma@example.com.")],
            rules: RedactionEngine.defaultRules)

        var leaks = Set<String>()
        for item in redacted {
            leaks.formUnion(
                RedactionEngine.validatePersonRedaction(
                    item, name: "Priya Sharma", email: "priya.sharma@example.com"))
        }
        XCTAssertFalse(leaks.isEmpty,
                       "the default categories do not redact a name — the gate must catch this")
        XCTAssertTrue(leaks.contains("Priya"), "the leaked term must be named: \(leaks.sorted())")
    }

    /// The generated rule set has to actually cover the variants the UI claims
    /// it covers, because the count is shown to the user as justification for
    /// not hand-writing regex.
    func testGeneratedPersonRulesCoverTheNameVariants() {
        let rules = RedactionEngine.personRedactionRules(
            name: "Priya Sharma", email: "priya.sharma@example.com")
        XCTAssertGreaterThanOrEqual(rules.count, 6,
                                    "full name, First Last, Last-comma-First, F. Last, each part, address")
        XCTAssertTrue(rules.allSatisfy(\.isEnabled), "a generated rule that ships disabled would leak")

        // An empty name must generate nothing rather than a rule matching
        // everything — the view leaves the field blank by default.
        XCTAssertTrue(RedactionEngine.personRedactionRules(name: "   ").isEmpty,
                      "a blank name must not generate rules")
    }
}

// MARK: - AIMetrics: an unmeasured metric is not a zero (audit defect 22)

/// `AIMetrics.begin`/`finalize` had no caller, so the instrumentation that was
/// meant to "prove (or disprove)" AI-pipeline changes had recorded nothing.
/// Wiring it exposed the second trap: engines see different things, so
/// averaging every field over every record would dilute measured values with
/// zeros from engines that cannot measure them — and report the result as a
/// measurement. These pin the rule that prevents that.
final class AIMetricsSummaryTests: XCTestCase {

    private func record(_ engine: String,
                        elapsed: Int,
                        findings: Int? = nil,
                        cited: Int = 0,
                        fallback: Bool = false) -> AIMetrics.QueryRecord {
        var r = AIMetrics.QueryRecord(query: "q", intent: engine, persona: "general",
                                      archiveEmailCount: 100)
        r.totalElapsedMs = elapsed
        r.citedEmailCount = cited
        r.fallbackUsed = fallback
        r.reported = [AIMetrics.QueryRecord.Group.identity,
                      AIMetrics.QueryRecord.Group.timing,
                      AIMetrics.QueryRecord.Group.output]
        if let findings {
            r.totalFindings = findings
            r.reported.insert(AIMetrics.QueryRecord.Group.findings)
        }
        return r
    }

    /// The core rule: findings averaged over the ONE engine that measured
    /// them, not diluted by the three that could not.
    func testFindingsAreAveragedOnlyOverEnginesThatMeasuredThem() {
        let summary = AIMetrics.summarize([
            record("hybrid", elapsed: 1_000, findings: 12),
            record("appleAI", elapsed: 800),
            record("appleAIMoE", elapsed: 900),
            record("nlp", elapsed: 100),
        ])

        XCTAssertEqual(summary.findings.samples, 1, "only hybrid measured findings")
        XCTAssertEqual(summary.findings.value, 12, accuracy: 0.001,
                       "diluting across all four would have reported 3.0")
        XCTAssertEqual(summary.elapsedMs.samples, 4, "every engine measures time")
        XCTAssertEqual(summary.elapsedMs.value, 700, accuracy: 0.001)
    }

    /// A metric no engine in the window measured must say so, not read 0.0.
    func testUnmeasuredMetricReadsAsNotMeasured() {
        let summary = AIMetrics.summarize([
            record("nlp", elapsed: 100),
            record("appleAI", elapsed: 200),
        ])
        XCTAssertFalse(summary.findings.isMeasured)
        XCTAssertFalse(summary.kgNodes.isMeasured,
                       "no engine reports knowledge-graph citations yet")
        XCTAssertEqual(summary.findings.description(), "not measured")
        XCTAssertNotEqual(summary.findings.description(), "0.0",
                          "a zero here would be a fabricated measurement")
    }

    /// A summary must never read as one engine's output.
    func testSummaryBreaksQueriesDownByEngine() {
        let summary = AIMetrics.summarize([
            record("hybrid", elapsed: 1),
            record("hybrid", elapsed: 1),
            record("nlp", elapsed: 1),
        ])
        XCTAssertEqual(summary.byEngine["hybrid"], 2)
        XCTAssertEqual(summary.byEngine["nlp"], 1)
        XCTAssertEqual(summary.sampleSize, 3)
    }

    /// Fallback is recorded by every path, so its rate is over the whole window.
    func testFallbackRateIsOverTheWholeWindow() {
        let summary = AIMetrics.summarize([
            record("hybrid", elapsed: 1, fallback: true),
            record("hybrid", elapsed: 1, fallback: false),
            record("cloudAI", elapsed: 1, fallback: true),
            record("nlp", elapsed: 1),
        ])
        XCTAssertEqual(summary.fallbackRate, 0.5, accuracy: 0.001)
    }

    func testEmptyWindowMeasuresNothing() {
        let summary = AIMetrics.summarize([])
        XCTAssertEqual(summary.sampleSize, 0)
        XCTAssertFalse(summary.elapsedMs.isMeasured)
    }

    /// A record that claims no groups counts toward no average. (There are no
    /// pre-`reported` records on disk to worry about: `finalize` had never
    /// been called before this change, so no metrics file was ever written.)
    func testRecordWithNoReportedGroupsContributesToNoAverage() {
        var legacy = AIMetrics.QueryRecord(query: "old", intent: "hybrid",
                                           persona: "general", archiveEmailCount: 1)
        legacy.totalElapsedMs = 99_999
        legacy.reported = []
        let summary = AIMetrics.summarize([legacy, record("nlp", elapsed: 100)])
        XCTAssertEqual(summary.elapsedMs.samples, 1)
        XCTAssertEqual(summary.elapsedMs.value, 100, accuracy: 0.001)
    }

    // MARK: Reading surface (AIMetricsView) — the file from earlier launches

    /// The screen reads the JSONL written by earlier launches. One corrupt
    /// line must cost one record, not the file, and `reported` must survive
    /// the round trip or every loaded record would count toward nothing.
    func testDecodeRecordsSkipsMalformedLinesAndKeepsReportedGroups() throws {
        let encoder = JSONEncoder()
        let a = record("hybrid", elapsed: 500, findings: 7)
        let b = record("nlp", elapsed: 50)
        var file = Data()
        file.append(try encoder.encode(a)); file.append(UInt8(ascii: "\n"))
        file.append(Data("{not json".utf8));  file.append(UInt8(ascii: "\n"))
        file.append(try encoder.encode(b));  file.append(UInt8(ascii: "\n"))

        let decoded = AIMetrics.decodeRecords(from: file)
        XCTAssertEqual(decoded.map(\.id), [a.id, b.id], "the bad line is skipped, order kept")
        XCTAssertTrue(decoded[0].reported.contains(AIMetrics.QueryRecord.Group.findings))
        XCTAssertEqual(AIMetrics.summarize(decoded).findings.samples, 1,
                       "a loaded record must still count toward the groups it reported")
    }

    /// A record finalized this launch is also on disk: merging must not show
    /// it twice, must keep newest first, and must respect the retention cap.
    func testMergeDedupesByIDNewestFirstAndCaps() {
        let shared = record("hybrid", elapsed: 1)
        var older = record("nlp", elapsed: 2)
        older = withTimestamp(older, offset: -3600)
        var oldest = record("appleAI", elapsed: 3)
        oldest = withTimestamp(oldest, offset: -7200)

        let merged = AIMetrics.merge(persisted: [shared, older, oldest],
                                     inMemory: [shared],
                                     cap: 2)
        XCTAssertEqual(merged.map(\.id), [shared.id, older.id],
                       "shared appears once, newest first, oldest dropped by the cap")
    }

    /// The per-engine table averages time only over that engine's records
    /// that reported timing, and counts fallbacks over all of its records.
    func testEngineStatsAverageTimeOnlyOverRecordsThatReportedIt() {
        var untimed = record("hybrid", elapsed: 9_999, fallback: true)
        untimed.reported.remove(AIMetrics.QueryRecord.Group.timing)
        let stats = AIMetricsView.engineStats([
            record("hybrid", elapsed: 1_000),
            record("hybrid", elapsed: 3_000, fallback: true),
            untimed,
            record("nlp", elapsed: 100),
        ])
        XCTAssertEqual(stats.map(\.engine), ["hybrid", "nlp"], "most-queried engine first")
        let hybrid = stats[0]
        XCTAssertEqual(hybrid.queries, 3)
        XCTAssertEqual(hybrid.elapsed.samples, 2)
        XCTAssertEqual(hybrid.elapsed.value, 2_000, accuracy: 0.001,
                       "the untimed record must not drag the average to 4,666")
        XCTAssertEqual(hybrid.fallbacks, 2, "fallback is recorded by every path")
        XCTAssertEqual(AIMetricsView.displayName(for: "appleAIMoE"), "Apple AI MoE")
        XCTAssertEqual(AIMetricsView.displayName(for: "unknownEngine"), "unknownEngine",
                       "an unmapped engine shows its raw label rather than vanishing")
    }

    /// `timestamp` is `let`; shift it through the Codable round trip.
    private func withTimestamp(_ record: AIMetrics.QueryRecord, offset: TimeInterval) -> AIMetrics.QueryRecord {
        _withTimestamp(record, offset: offset)
    }
}

// Shared by the metrics tests above; kept file-private so the helper does not
// leak into the app's namespace.
private func _withTimestamp(_ record: AIMetrics.QueryRecord, offset: TimeInterval) -> AIMetrics.QueryRecord {
    guard var json = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] else {
        XCTFail("encode"); return record
    }
    json["timestamp"] = record.timestamp.addingTimeInterval(offset).timeIntervalSinceReferenceDate
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let shifted = try? JSONDecoder().decode(AIMetrics.QueryRecord.self, from: data) else {
        XCTFail("decode"); return record
    }
    return shifted
}

// MARK: - Streamed archive comparison (v2.1 backlog #3)

/// The comparison used to hold two `[RawEmail]` arrays capped at 2,000 per
/// side. `ArchiveComparisonEngine` reduces both sides to key rows in a scratch
/// SQLite file and matches in SQL, so the whole archive is compared and the
/// difference list is paged. These pin the matching rules, the paging, and
/// the fact that the bound is gone.
final class ArchiveComparisonEngineTests: XCTestCase {

    private var root: URL!
    private var service: ArchiveDataService!
    private var store: SQLiteEmailStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-compare-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        service = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func email(mid: String?, subject: String, from: String, day: Int) -> MBOXParser.RawEmail {
        var headers = ["Subject": subject, "From": from, "To": "x@y.z",
                       "Date": "Wed, \(String(format: "%02d", day)) Jan 2025 10:00:00 +0000"]
        if let mid { headers["Message-ID"] = mid }
        return MBOXParser.RawEmail(headers: headers, rawSource: "From a@b.com\nbody \(subject)",
                                   messageType: "received", attachments: [],
                                   timestamp: "2025-01-\(String(format: "%02d", day))T10:00:00Z",
                                   domains: ["y.z"], plainBody: "body \(subject)", htmlBody: "")
    }

    /// Writes an mbox for side B from the given messages.
    private func mbox(_ emails: [MBOXParser.RawEmail]) throws -> URL {
        var text = ""
        for e in emails {
            text += "From sender@example.com Wed Jan 01 10:00:00 2025\n"
            for (k, v) in e.headers.sorted(by: { $0.key < $1.key }) { text += "\(k): \(v)\n" }
            text += "\n\(e.plainBody)\n\n"
        }
        let url = root.appendingPathComponent("second-\(UUID().uuidString).mbox")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func seedA(_ emails: [MBOXParser.RawEmail]) async throws {
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil,
                                        firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 100, progress: nil)
    }

    /// Exact Message-ID first; fuzzy for the rest; one-to-one; the remainder
    /// is "only in" its side.
    func testMatchingRules_messageIDThenFuzzyThenOnlyIn() async throws {
        try await seedA([
            email(mid: "<shared@x>", subject: "Shared by ID", from: "a@x", day: 1),
            email(mid: "<a-only@x>", subject: "A only", from: "a@x", day: 2),
            email(mid: nil, subject: "Fuzzy twin", from: "f@x", day: 3),
            email(mid: nil, subject: "Fuzzy twin", from: "f@x", day: 3),   // a second twin: only ONE may match
        ])
        let b = try mbox([
            email(mid: "<shared@x>", subject: "Shared by ID (renamed on B)", from: "a@x", day: 1),
            email(mid: nil, subject: "Fuzzy Twin", from: "F@X", day: 3),           // case-insensitive fuzzy
            email(mid: "<b-only@x>", subject: "B only", from: "b@x", day: 4),
        ])

        let engine = try ArchiveComparisonEngine(dataService: service, scratchDirectory: root)
        defer { engine.close() }
        try await engine.indexCurrentArchive()
        try await engine.indexSecondArchive(url: b, senderEmail: "")
        let totals = try engine.match()

        XCTAssertEqual(totals.countA, 4)
        XCTAssertEqual(totals.countB, 3)
        XCTAssertEqual(totals.byMessageID, 1, "the renamed subject must not defeat an exact Message-ID match")
        XCTAssertEqual(totals.byFuzzy, 1, "two A twins, one B twin: exactly one fuzzy match")
        XCTAssertEqual(totals.common, 2)
        XCTAssertEqual(totals.onlyInA, 2, "A only + the unmatched twin")
        XCTAssertEqual(totals.onlyInB, 1)

        let common = try engine.page(filter: .common, after: nil, limit: 10)
        XCTAssertEqual(Set(common.map(\.matchKind)), ["message-id", "fuzzy"])
        XCTAssertEqual(common.first { $0.matchKind == "message-id" }?.matchedSubject, "Shared by ID (renamed on B)")

        let stats = try engine.stats(.a)
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.uniqueSenders, 2)
    }

    /// The whole point: no 2,000-per-side bound. 5,000 A rows against 5,000 B
    /// rows with a 1,000-row overlap, compared exactly, and paged.
    func testWholeArchive_noBound_andKeysetPagingCoversEveryRowOnce() async throws {
        let a = (0..<5_000).map { email(mid: "<m\($0)@x>", subject: "S\($0)", from: "s\($0 % 7)@x", day: 1 + $0 % 28) }
        try await seedA(a)
        let bEmails = (4_000..<9_000).map { email(mid: "<m\($0)@x>", subject: "S\($0)", from: "s\($0 % 7)@x", day: 1 + $0 % 28) }
        let b = try mbox(bEmails)

        let engine = try ArchiveComparisonEngine(dataService: service, scratchDirectory: root)
        defer { engine.close() }
        try await engine.indexCurrentArchive()
        try await engine.indexSecondArchive(url: b, senderEmail: "")
        let totals = try engine.match()

        XCTAssertEqual(totals.countA, 5_000, "the old view would have stopped at 2,000")
        XCTAssertEqual(totals.countB, 5_000)
        XCTAssertEqual(totals.common, 1_000)
        XCTAssertEqual(totals.onlyInA, 4_000)
        XCTAssertEqual(totals.onlyInB, 4_000)

        // Page the interleaved list to exhaustion; every row exactly once.
        var seen = Set<String>()
        var cursor: ArchiveComparisonEngine.Cursor? = nil
        var pages = 0
        while true {
            let page = try engine.page(filter: nil, after: cursor, limit: 700)
            if page.isEmpty { break }
            pages += 1
            for row in page { XCTAssertTrue(seen.insert(row.source.rawValue + row.id).inserted, "row repeated across pages") }
            guard let last = page.last else { break }
            cursor = ArchiveComparisonEngine.Cursor(date: last.date, id: last.id)
            if page.count < 700 { break }
        }
        XCTAssertEqual(seen.count, 4_000 + 4_000 + 1_000)
        XCTAssertGreaterThan(pages, 10)

        // The side-B full-text sample stays bounded regardless of size.
        XCTAssertEqual(engine.sampleB.count, ArchiveComparisonEngine.sampleCap)
        XCTAssertLessThanOrEqual(try engine.onlyInBSample().count, ArchiveComparisonEngine.sampleCap)
    }

    /// Side B goes through the ordinary parser, so a ZIP of mailboxes works
    /// as the second archive too.
    func testSecondArchiveMayBeAContainer() async throws {
        try await seedA([email(mid: "<z1@x>", subject: "Z1", from: "a@x", day: 1)])
        let inner = try mbox([
            email(mid: "<z1@x>", subject: "Z1", from: "a@x", day: 1),
            email(mid: "<z2@x>", subject: "Z2", from: "a@x", day: 2),
        ])
        // A stored ZIP with one member, built by hand (see ContainerImportTests
        // for the full writer; this only needs a single stored entry).
        let payload = try Data(contentsOf: inner)
        let name = Data("inner.mbox".utf8)
        let crc = ZIPArchiveReader.CRC32.checksum(payload)
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        var zip = Data()
        zip += le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0)
        zip += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(payload.count)) + le16(UInt16(name.count)) + le16(0)
        zip += name + payload
        let cdOffset = UInt32(zip.count)
        var central = Data()
        central += le32(0x0201_4B50) + le16(45) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0)
        central += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(payload.count))
        central += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + name
        zip += central
        zip += le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        let zipURL = root.appendingPathComponent("second.zip")
        try zip.write(to: zipURL)

        let engine = try ArchiveComparisonEngine(dataService: service, scratchDirectory: root)
        defer { engine.close() }
        try await engine.indexCurrentArchive()
        try await engine.indexSecondArchive(url: zipURL, senderEmail: "")
        let totals = try engine.match()
        XCTAssertEqual(totals.common, 1)
        XCTAssertEqual(totals.onlyInB, 1)
    }

    func testCloseRemovesTheScratchDatabase() throws {
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let engine = try ArchiveComparisonEngine(dataService: service, scratchDirectory: scratch)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count, 1)
        engine.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count, 0)
    }
}


// MARK: - Export receipts (A8)

/// Every bulk export ends in an `ExportReceipt`, including cancelled and
/// failed runs. These pin the record's shape and the store's ordering.
final class ExportReceiptTests: XCTestCase {

    private func store() -> (ExportReceiptStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-export-receipts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (ExportReceiptStore(directory: dir), dir)
    }

    func testRoundTripPreservesEveryField() throws {
        let (store, _) = store()
        let receipt = ExportReceipt(title: "mbox export", destination: "/tmp/out.mbox", isFolder: false,
                                    requested: 526, written: 526, bytesWritten: 94_929_888,
                                    outcome: .complete, sha256Hex: "abc123", signaturePath: "/tmp/out.mbox.sig",
                                    errorMessage: nil, startedAt: Date(timeIntervalSince1970: 1_000),
                                    completedAt: Date(timeIntervalSince1970: 1_012))
        let url = try store.save(receipt)
        let loaded = try store.load(url)
        XCTAssertEqual(loaded, receipt)
        XCTAssertEqual(loaded.durationSeconds, 12, accuracy: 0.001)
        XCTAssertNil(loaded.shortfall, "a complete export has no shortfall")
    }

    func testOutcomesReadHonestly() {
        let base = ExportReceipt(title: "CSV export", destination: "/tmp/x.csv", isFolder: false,
                                 requested: 100, written: 40, outcome: .cancelled,
                                 startedAt: Date(), completedAt: Date())
        XCTAssertEqual(base.shortfall, 60)
        XCTAssertTrue(base.verdictLine.hasPrefix("Cancelled — 40 written"))

        var truncated = base; truncated.outcome = .truncated
        XCTAssertTrue(truncated.verdictLine.contains("40 of 100"), truncated.verdictLine)

        var failed = base; failed.outcome = .failed; failed.errorMessage = "disk full"
        XCTAssertTrue(failed.plainText().contains("Error: disk full"))
        XCTAssertTrue(failed.plainText().contains("Requested: 100"))
    }

    func testStoreListsNewestFirst() throws {
        let (store, _) = store()
        let older = ExportReceipt(title: "a", destination: "/a", isFolder: false, requested: nil, written: 1,
                                  outcome: .complete, startedAt: Date(), completedAt: Date())
        let olderURL = try store.save(older)
        // Push the modification date back so ordering does not depend on timing.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: olderURL.path)
        let newer = ExportReceipt(title: "b", destination: "/b", isFolder: true, requested: nil, written: 2,
                                  outcome: .complete, startedAt: Date(), completedAt: Date())
        _ = try store.save(newer)
        let listed = store.list()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(try store.load(listed[0]).title, "b")
    }
}

// MARK: - Guided search composition (A7)

final class GuidedSearchCompositionTests: XCTestCase {

    private func compose(from: String = "", to: String = "", subject: String = "", phrase: String = "",
                         any: String = "", none: String = "", attachment: String = "", source: String = "",
                         tag: String = "", hasAttachments: Bool = false) -> String {
        GuidedSearchView.compose(from: from, to: to, subject: subject, phrase: phrase, anyWords: any,
                                 noneOfWords: none, attachmentName: attachment, sourceFile: source, tag: tag,
                                 hasAttachments: hasAttachments, after: nil, before: nil)
    }

    func testEveryFieldBecomesAnOperatorTheCompilerUnderstands() {
        let q = compose(from: "alice", subject: "quarterly report", attachment: "pdf", source: "takeout", tag: "Important")
        XCTAssertEqual(q, "from:alice subject:\"quarterly report\" filename:pdf source:takeout tag:Important")
        let compiled = ArchiveQueryCompiler.compile(q)
        XCTAssertEqual(compiled.sender, "alice")
        XCTAssertEqual(compiled.subjectContains, "quarterly report")
        XCTAssertEqual(compiled.attachmentFilename, "pdf")
        XCTAssertEqual(compiled.hasAttachments, true, "an attachment name implies has:attachment")
        XCTAssertEqual(compiled.sourceFileName, "takeout")
        XCTAssertEqual(compiled.userTag, "Important")
        XCTAssertNil(compiled.text, "nothing leaked into free text")
    }

    func testPhraseAnyAndNotComposeToFTSBooleanGrammar() {
        XCTAssertEqual(compose(phrase: "wire transfer", any: "invoice receipt", none: "newsletter"),
                       "\"wire transfer\" AND (invoice OR receipt) NOT newsletter")
        XCTAssertEqual(compose(any: "invoice"), "invoice")
    }

    func testNotWithoutAPositiveTermIsDropped() {
        // FTS5 NOT is binary; "NOT x" alone is invalid. The sheet says so and
        // the composer refuses to emit it.
        XCTAssertEqual(compose(from: "alice", none: "spam"), "from:alice")
    }

    func testHasAttachmentIsRedundantWithAFilename() {
        XCTAssertEqual(compose(attachment: "xlsx", hasAttachments: true), "filename:xlsx")
        XCTAssertEqual(compose(hasAttachments: true), "has:attachment")
    }
}

// MARK: - Filter memory per persona (v2.1 backlog #15)

@MainActor
final class FilterMemoryTests: XCTestCase {

    private func makeVM() throws -> ParsedEmailListViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-filtermem-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        return ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: archive, pageSize: 10, maxRetained: 50)
    }

    private func clear(_ persona: String) {
        ParsedEmailListViewModel.filterMemoryDefaults.removeObject(forKey: ParsedEmailListViewModel.filterMemoryKey(for: persona))
    }

    /// The memory suite is process-wide; a value saved under the REAL persona
    /// here would be restored by every other view model built in this run
    /// (it was, once — every paging test then saw an empty list). Start and
    /// end with an empty suite.
    private func wipeSuite() {
        let suite = ParsedEmailListViewModel.filterMemoryDefaults
        for key in suite.dictionaryRepresentation().keys where key.hasPrefix("mailin.filterMemory.") {
            suite.removeObject(forKey: key)
        }
    }

    override func setUp() async throws {
        wipeSuite()
        ParsedEmailListViewModel.filterMemoryEnabled = true    // opt in: off under XCTest by default
    }
    override func tearDown() async throws {
        ParsedEmailListViewModel.filterMemoryEnabled = false
        wipeSuite()
    }

    /// The memory applies the remembered choices and nothing else: free text
    /// and sidebar selections are left as they were.
    func testApplyRestoresTheRememberedChoicesOnly() throws {
        let vm = try makeVM()
        vm.restoreFilters(for: "test-persona-apply-\(UUID().uuidString)")   // never the real persona
        vm.searchText = "keep me"
        let memory = ParsedEmailListViewModel.FilterMemory(
            sortBy: ParsedEmailListViewModel.SortOption.sizeDesc.rawValue,
            hasAttachmentFilter: true,
            reviewStateFilter: "trashed",
            quickTypeFilter: "sent",
            showPinnedOnly: true,
            groupByThread: true)
        ParsedEmailListViewModel.apply(memory, to: vm)
        XCTAssertEqual(vm.sortBy, .sizeDesc)
        XCTAssertTrue(vm.hasAttachmentFilter)
        XCTAssertEqual(vm.reviewStateFilter.rawValue, "trashed")
        XCTAssertEqual(vm.quickTypeFilter, "sent")
        XCTAssertTrue(vm.showPinnedOnly)
        XCTAssertTrue(vm.groupByThread)
        XCTAssertEqual(vm.searchText, "keep me", "free text is a moment's search, not remembered state")
        XCTAssertEqual(vm.currentFilterMemory, memory)
    }

    /// Changing a filter under persona A and switching to persona B and back
    /// restores A's set; B, never used, keeps whatever was on screen.
    func testMemoryIsPerPersonaAndSurvivesASwitch() throws {
        let a = "test-persona-a-\(UUID().uuidString)", b = "test-persona-b-\(UUID().uuidString)"
        defer { clear(a); clear(b) }
        let vm = try makeVM()
        vm.restoreFilters(for: a)             // start "under" persona A
        vm.hasAttachmentFilter = true         // → applyFilters → remembered for A
        vm.sortBy = .subjectAsc

        let savedA = ParsedEmailListViewModel.filterMemoryDefaults.data(forKey: ParsedEmailListViewModel.filterMemoryKey(for: a))
        XCTAssertNotNil(savedA, "a filter change under A must be saved for A")

        vm.restoreFilters(for: b)             // B has no memory: screen unchanged
        XCTAssertTrue(vm.hasAttachmentFilter)
        vm.hasAttachmentFilter = false        // now B remembers "off"
        vm.sortBy = .dateDesc

        vm.restoreFilters(for: a)
        XCTAssertTrue(vm.hasAttachmentFilter, "A's set comes back")
        XCTAssertEqual(vm.sortBy, .subjectAsc)

        vm.restoreFilters(for: b)
        XCTAssertFalse(vm.hasAttachmentFilter, "B's set comes back")
        XCTAssertEqual(vm.sortBy, .dateDesc)
    }
}

// MARK: - Import checkpoints in the store (v17, v2.1 backlog #7)

/// The JSON checkpoint file is replaced by two tables in the archive's own
/// database, and the mid-file ordinal is written INSIDE the batch insert's
/// transaction. These pin: same-transaction atomicity, identity-bound resume
/// through the store backend, session completion clearing progress, and the
/// one-time migration of a legacy file.
final class StoreBackedCheckpointTests: XCTestCase {

    private var root: URL!
    private var store: SQLiteEmailStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-ckpt-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
    }

    override func tearDown() async throws {
        ImportCheckpointStore.legacyJSONURLOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ i: Int) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<ck-\(i)@t>", "Subject": "S\(i)", "From": "a@b.com", "To": "c@d.com",
                      "Date": "Wed, \(String(format: "%02d", 1 + i % 28)) Jan 2025 10:00:00 +0000"],
            rawSource: "raw \(i)", messageType: "email", attachments: [],
            timestamp: "2025-01-01T10:00:00Z", domains: ["b.com"], plainBody: "b \(i)", htmlBody: "")
    }

    /// One `insertBatch` call, one checkpoint, and a fresh instance of the
    /// store (crash simulation) sees BOTH the rows and the ordinal.
    func testCheckpointCommitsWithTheRowsItVouchesFor() async throws {
        let checkpoints = ImportCheckpointStore(store: store)
        let identity = ImportCheckpointStore.ResumeIdentity(sha256: "src-1", sizeBytes: 4_096, parser: "mbox", parserVersion: 1)
        let cp = await checkpoints.progressCheckpoint(identity: identity, sourceName: "big.mbox", firstOrdinal: 100, store: store)
        XCTAssertNotNil(cp, "a store-backed checkpoint store hands out an atomic checkpoint for its own store")

        _ = try await store.insertBatch((0..<7).map(fixture), sourceFileHash: "src-1", accountID: nil,
                                        sourceID: nil, firstOrdinal: 100, dedupPolicy: .messageID,
                                        batchSize: 3, progress: nil, progressCheckpoint: cp)

        let reopened = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let reopenedCheckpoints = ImportCheckpointStore(store: reopened)
        let resume = await reopenedCheckpoints.resumePoint(for: identity)
        XCTAssertEqual(resume, 107, "first ordinal 100 + 7 committed rows, visible after reopen")
        let rows = try await reopened.totalCount()
        XCTAssertEqual(rows, 7)
    }

    /// A different store gets no atomic checkpoint: the coordinator must then
    /// record progress separately, and does.
    func testForeignStoreGetsNoAtomicCheckpoint() async throws {
        let other = SQLiteEmailStore(directory: root.appendingPathComponent("other"))
        let checkpoints = ImportCheckpointStore(store: store)
        let identity = ImportCheckpointStore.ResumeIdentity(sha256: "x", sizeBytes: 1, parser: "mbox", parserVersion: 1)
        let cp = await checkpoints.progressCheckpoint(identity: identity, sourceName: "f", firstOrdinal: 0, store: other)
        XCTAssertNil(cp)
        let json = ImportCheckpointStore(storeURL: root.appendingPathComponent("cp.json"))
        let cpJSON = await json.progressCheckpoint(identity: identity, sourceName: "f", firstOrdinal: 0, store: store)
        XCTAssertNil(cpJSON, "the JSON backend never rides the store's transaction")
    }

    /// Identity binding through the store backend, and completion semantics.
    func testIdentityBoundResumeAndCompletionThroughTheStore() async throws {
        let checkpoints = ImportCheckpointStore(store: store)
        let identity = ImportCheckpointStore.ResumeIdentity(sha256: "abc", sizeBytes: 9_999, parser: "mbox", parserVersion: 1)
        try await checkpoints.recordProgress(identity: identity, sourceName: "big.mbox", messagesIngested: 137)
        var resume = await checkpoints.resumePoint(for: identity)
        XCTAssertEqual(resume, 137)

        var differentSize = identity; differentSize.sizeBytes = 10_000
        var differentParser = identity; differentParser.parser = "pst"
        var differentVersion = identity; differentVersion.parserVersion = 2
        let r1 = await checkpoints.resumePoint(for: differentSize)
        let r2 = await checkpoints.resumePoint(for: differentParser)
        let r3 = await checkpoints.resumePoint(for: differentVersion)
        XCTAssertEqual([r1, r2, r3], [0, 0, 0], "any identity mismatch restarts the file")

        var imported = await checkpoints.isImported(sha256: "abc")
        XCTAssertFalse(imported)
        try await checkpoints.record(sha256: "abc", sourceName: "big.mbox", emailCount: 500)
        imported = await checkpoints.isImported(sha256: "abc")
        XCTAssertTrue(imported)
        resume = await checkpoints.resumePoint(for: identity)
        XCTAssertEqual(resume, 0, "completion clears the in-progress row")
        let count = await checkpoints.importedCount()
        XCTAssertEqual(count, 1)

        try await checkpoints.reset()
        let afterReset = await checkpoints.importedCount()
        XCTAssertEqual(afterReset, 0)
    }

    /// An existing user's JSON file is read once, copied into the tables, and
    /// renamed. Legacy schema-v1 progress rows are not carried over.
    func testLegacyJSONFileMigratesIntoTheStoreOnce() async throws {
        let legacy = root.appendingPathComponent("import_checkpoints.json")
        let json = """
        {"entries":{"done-1":{"sha256":"done-1","completedAt":0,"emailCount":42,"sourceName":"a.mbox"}},
         "inProgress":{
           "half":{"sha256":"half","sourceName":"b.mbox","lastUpdatedAt":0,"schemaVersion":2,"sizeBytes":777,"parser":"mbox","parserVersion":1,"messagesIngested":12},
           "legacyhash":{"sha256":"legacyhash","sourceName":"old.mbox","batchesIngested":4,"lastUpdatedAt":0}}}
        """
        try Data(json.utf8).write(to: legacy)
        ImportCheckpointStore.legacyJSONURLOverride = legacy

        let checkpoints = ImportCheckpointStore(store: store)
        let imported = await checkpoints.isImported(sha256: "done-1")
        XCTAssertTrue(imported, "completed sessions migrate")
        let half = await checkpoints.resumePoint(for: .init(sha256: "half", sizeBytes: 777, parser: "mbox", parserVersion: 1))
        XCTAssertEqual(half, 12, "schema-v2 progress migrates with its identity")
        let old = await checkpoints.resumePoint(for: .init(sha256: "legacyhash", sizeBytes: 0, parser: "mbox", parserVersion: 1))
        XCTAssertEqual(old, 0, "batch-count checkpoints were never resumable and are not migrated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "the file is renamed so it is never read again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated-v17").path))
        let corrupt = await checkpoints.corruptionDetected()
        XCTAssertFalse(corrupt)
    }
}

// MARK: - Shared browse state (v2.1 backlog #6)

final class ArchiveBrowseStateTests: XCTestCase {

    func testDefaultStateIsTheUnfilteredArchive() {
        let q = ArchiveBrowseState().query()
        XCTAssertEqual(q, EmailQuery.all)
        XCTAssertTrue(ArchiveBrowseState().isDefault)
    }

    /// Both lists now compile the search string the same way: an operator is
    /// a field, not literal text.
    func testSearchStringCompilesToOperatorsNotLiteralText() {
        let q = ArchiveBrowseState(searchText: "from:alice filename:pdf budget").query()
        XCTAssertEqual(q.sender, "alice")
        XCTAssertEqual(q.attachmentFilename, "pdf")
        XCTAssertEqual(q.text, "budget")
    }

    func testFieldsLayerOnTopOfTheSurfaceBase() {
        let after = Date(timeIntervalSince1970: 1_700_000_000)
        var base = EmailQuery.all
        base.senders = ["a@x"]
        base.pinnedOnly = true
        let q = ArchiveBrowseState(searchText: "", afterDate: after, hasAttachments: true, sort: .subjectAZ).query(base: base)
        XCTAssertEqual(q.senders, ["a@x"], "the surface's own predicates survive")
        XCTAssertTrue(q.pinnedOnly)
        XCTAssertEqual(q.afterDate, after)
        XCTAssertEqual(q.hasAttachments, true)
        XCTAssertEqual(q.sort, .subjectAZ)
        XCTAssertNil(q.text)
    }
}
