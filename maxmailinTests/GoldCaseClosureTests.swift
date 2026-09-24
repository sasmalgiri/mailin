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

    /// The LAW-14 validator must find nothing in redacted output — the
    /// belt-and-braces second pass that gates an export.
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
}
