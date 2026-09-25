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
