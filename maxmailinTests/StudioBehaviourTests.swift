//
//  StudioBehaviourTests.swift
//  maxmailinTests
//
//  One behavioural test per studio, so "behaviorally verified" stops being a
//  claim with nothing behind it. Before this file, no test in the target
//  referenced any of the five studios — the claim rested entirely on reading
//  the code.
//
//  Each suite targets the studio's ONE load-bearing decision: the evidence
//  gate that decides whether a numbered document may be posted, plus the
//  ranking/status rule that gate depends on. Those are the parts a reviewer
//  would be challenged on, and they are pure functions on value types, so
//  they are testable without a view host.
//
//  NOT YET EXECUTED — written under an instruction to implement first and
//  test afterwards.
//

import XCTest
@testable import maxmailin

// MARK: - Shared fixtures

private func citedEvidence(_ summary: String) -> ACHEvidence {
    ACHEvidence(summary: summary,
                emailID: UUID(),
                messageID: "<\(UUID().uuidString)@example.com>",
                fromLine: "From: sender@example.com",
                dateLine: "Date: Tue, 14 Mar 2017 09:41:00 +0000")
}

private func uncitedEvidence(_ summary: String, acknowledged: Bool) -> ACHEvidence {
    ACHEvidence(summary: summary, emailID: nil, isAssumption: acknowledged)
}

// MARK: - Studio 1: ACH matrix

final class ACHMatrixBehaviourTests: XCTestCase {

    /// ACH's defining property: hypotheses rank by REFUTATION, so the
    /// hypothesis with the fewest inconsistencies comes first even when
    /// another has more supporting evidence. A tool that ranked by support
    /// would be doing the opposite of ACH.
    func testRankingIsByFewestInconsistencies_notMostSupport() {
        let popular = ACHHypothesis(title: "Insider moved the funds")
        let surviving = ACHHypothesis(title: "Vendor invoice was genuine")

        var model = ACHMatrixModel(title: "Wire transfer", hypotheses: [popular, surviving])
        let e1 = citedEvidence("wire approved out of hours")
        let e2 = citedEvidence("vendor contract on file")
        let e3 = citedEvidence("bank confirmation matches invoice")
        model.evidence = [e1, e2, e3]

        // `popular` is strongly SUPPORTED twice, but also strongly refuted once.
        model.setRating(.cc, evidence: e1.id, hypothesis: popular.id)
        model.setRating(.cc, evidence: e2.id, hypothesis: popular.id)
        model.setRating(.ii, evidence: e3.id, hypothesis: popular.id)

        // `surviving` has almost no support, but nothing refutes it.
        model.setRating(.n, evidence: e1.id, hypothesis: surviving.id)
        model.setRating(.n, evidence: e2.id, hypothesis: surviving.id)
        model.setRating(.c, evidence: e3.id, hypothesis: surviving.id)

        XCTAssertEqual(model.inconsistencyScore(for: popular), 2)
        XCTAssertEqual(model.inconsistencyScore(for: surviving), 0)

        let ranking = model.ranking
        XCTAssertEqual(ranking.first?.hypothesis.id, surviving.id,
                       "the least-refuted hypothesis must rank first, not the best-supported one")
        XCTAssertEqual(ranking.last?.hypothesis.id, popular.id)
    }

    /// The posting gate must block an incomplete matrix, and must name every
    /// reason at once — a gate that reports only the first problem makes the
    /// user discover the rest one save at a time.
    func testPostGate_blocksUntilTheMatrixIsComplete() {
        var model = ACHMatrixModel(title: "Half-done")
        model.hypotheses = [ACHHypothesis(title: "Single hypothesis")]
        model.evidence = [citedEvidence("one row"),
                          uncitedEvidence("hearsay", acknowledged: false)]

        let blockers = model.postBlockers
        XCTAssertFalse(blockers.isEmpty, "an incomplete matrix must not be postable")
        XCTAssertTrue(blockers.contains { $0.contains("2 competing hypotheses") },
                      "missing competing hypotheses must be named: \(blockers)")
        XCTAssertTrue(blockers.contains { $0.contains("3 evidence rows") }, "\(blockers)")
        XCTAssertTrue(blockers.contains { $0.contains("unrated") }, "\(blockers)")
        XCTAssertTrue(blockers.contains { $0.contains("assumptions") },
                      "an uncited, unacknowledged row must block: \(blockers)")
    }

    /// And the gate must actually open — one that never passes is as useless
    /// as one that never blocks.
    func testPostGate_opensWhenEveryCellIsRatedAndEveryRowAccountedFor() {
        let h1 = ACHHypothesis(title: "Hypothesis A")
        let h2 = ACHHypothesis(title: "Hypothesis B")
        var model = ACHMatrixModel(title: "Complete", hypotheses: [h1, h2])
        let rows = [citedEvidence("a"), citedEvidence("b"),
                    uncitedEvidence("acknowledged assumption", acknowledged: true)]
        model.evidence = rows

        for row in rows {
            model.setRating(.c, evidence: row.id, hypothesis: h1.id)
            model.setRating(.i, evidence: row.id, hypothesis: h2.id)
        }

        XCTAssertEqual(model.unratedCellCount, 0)
        XCTAssertTrue(model.postBlockers.isEmpty,
                      "a complete matrix must be postable; blockers: \(model.postBlockers)")
    }
}

// MARK: - Studio 2: Reasoning (5W1H / 5-whys / fishbone / root cause)

final class ReasoningStudioBehaviourTests: XCTestCase {

    /// A 5W1H cell counts as answered only when it is cited OR explicitly
    /// marked unknown. A bare sentence with no email behind it is exactly the
    /// unsourced assertion this studio exists to prevent.
    func testFiveWCell_needsEvidenceOrAnExplicitUnknown() {
        var cell = FiveWCell()
        XCTAssertFalse(cell.isComplete, "an empty cell is not complete")

        cell.answer = "The operations manager"
        XCTAssertFalse(cell.isComplete,
                       "an answer with no evidence must not count as complete")

        cell.evidence = [citedEvidence("email naming the manager")]
        XCTAssertTrue(cell.isComplete, "a cited answer is complete")

        var unknown = FiveWCell()
        unknown.markedUnknown = true
        XCTAssertTrue(unknown.isComplete,
                      "an explicit UNKNOWN is an acceptable, honest answer")
    }

    /// Confirming a root cause is a HUMAN decision: the studio must refuse to
    /// post a confirmed cause without a written rationale and a named decider.
    func testPostGate_confirmedRootCauseRequiresRationaleAndDecider() {
        var model = ReasoningCaseModel(title: "Outage")
        model.problemStatement = "Payments failed for 40 minutes"
        for key in ReasoningCaseModel.fiveWKeys {
            model.fiveW[key] = FiveWCell(answer: "answered", evidence: [citedEvidence(key)])
        }
        XCTAssertTrue(model.postBlockers.isEmpty,
                      "a complete 5W1H with no confirmed cause is postable; got \(model.postBlockers)")

        let candidate = RootCauseCandidate(statement: "Expired certificate")
        model.candidates = [candidate]
        model.confirmedCandidateID = candidate.id

        let blockers = model.postBlockers
        XCTAssertTrue(blockers.contains { $0.contains("rationale") },
                      "a confirmed root cause must require a rationale: \(blockers)")
        XCTAssertTrue(blockers.contains { $0.contains("decider") },
                      "a confirmed root cause must require a named decider: \(blockers)")

        model.decisionRationale = "Cert expiry timestamp matches the first failure"
        model.decidedBy = "S. Sasmal"
        XCTAssertTrue(model.postBlockers.isEmpty,
                      "with rationale and decider it must post; got \(model.postBlockers)")
    }

    /// An incomplete 5W1H must name the missing dimensions, not merely say
    /// "incomplete".
    func testPostGate_namesTheMissingFiveWDimensions() {
        var model = ReasoningCaseModel()
        model.problemStatement = "Something went wrong"
        model.fiveW["Who"] = FiveWCell(answer: "someone", evidence: [citedEvidence("x")])

        let missing = model.fiveWIncomplete
        XCTAssertFalse(missing.contains("Who"))
        XCTAssertEqual(Set(missing), Set(["What", "When", "Where", "Why", "How"]))
        XCTAssertTrue(model.postBlockers.contains { $0.contains("When") },
                      "the blocker text must name what is missing: \(model.postBlockers)")
    }
}

// MARK: - Studio 3: Fact–Evidence matrix

final class FactEvidenceBehaviourTests: XCTestCase {

    /// The four statuses must follow from the links, and "contested" in
    /// particular must survive: evidence on both sides is not resolved by
    /// counting.
    func testFactStatus_followsTheLinkedStances() {
        var model = FactEvidenceModel(title: "Matter")
        let supported = FEFact(statement: "The invoice was approved")
        let contested = FEFact(statement: "The goods were delivered")
        let opposed = FEFact(statement: "No one was notified")
        let bare = FEFact(statement: "The manager knew")
        model.facts = [supported, contested, opposed, bare]

        let a = citedEvidence("approval email")
        let b = citedEvidence("delivery note")
        let c = citedEvidence("driver says undelivered")
        let d = citedEvidence("notification email exists")
        model.evidence = [a, b, c, d]

        model.links[supported.id] = [a.id: .supports]
        // Three supports against one opposes is still CONTESTED.
        model.links[contested.id] = [a.id: .supports, b.id: .supports,
                                     d.id: .supports, c.id: .opposes]
        model.links[opposed.id] = [d.id: .opposes]

        XCTAssertEqual(model.status(for: supported), .supported)
        XCTAssertEqual(model.status(for: contested), .contested,
                       "evidence on both sides must stay contested, not be resolved by majority")
        XCTAssertEqual(model.status(for: opposed), .opposed)
        XCTAssertEqual(model.status(for: bare), .unsupported)

        XCTAssertEqual(model.evidence(for: contested, stance: .supports).count, 3)
        XCTAssertEqual(model.evidence(for: contested, stance: .opposes).map(\.id), [c.id])
    }

    /// A fact with no evidence must block posting unless the author has
    /// explicitly acknowledged it as an open item.
    func testPostGate_unsupportedFactBlocksUnlessAcknowledgedOpen() {
        var model = FactEvidenceModel(title: "Matter")
        var bare = FEFact(statement: "The manager knew")
        model.facts = [bare]

        XCTAssertTrue(model.postBlockers.contains { $0.contains("no evidence") },
                      "an unsupported fact must block: \(model.postBlockers)")

        bare.acknowledgedOpen = true
        model.facts = [bare]
        XCTAssertTrue(model.postBlockers.isEmpty,
                      "acknowledging it as open must unblock; got \(model.postBlockers)")
    }

    /// Uncited evidence rows must be declared assumptions.
    func testPostGate_uncitedEvidenceMustBeMarkedAsAnAssumption() {
        var model = FactEvidenceModel(title: "Matter")
        let fact = FEFact(statement: "A happened")
        let hearsay = uncitedEvidence("someone mentioned it", acknowledged: false)
        model.facts = [fact]
        model.evidence = [hearsay]
        model.links[fact.id] = [hearsay.id: .supports]

        XCTAssertTrue(model.postBlockers.contains { $0.contains("assumptions") },
                      "\(model.postBlockers)")

        let acknowledged = uncitedEvidence("someone mentioned it", acknowledged: true)
        model.evidence = [acknowledged]
        model.links = [fact.id: [acknowledged.id: .supports]]
        XCTAssertTrue(model.postBlockers.isEmpty,
                      "an acknowledged assumption must be postable; got \(model.postBlockers)")
    }
}

// MARK: - Studio 4: Evidence desks (Admiralty ratings, contradictions, gaps)

@MainActor
final class EvidenceDeskBehaviourTests: XCTestCase {

    /// Seeding from the archive must aggregate by sender ADDRESS (not by the
    /// display-name form of the same address) and must leave the Admiralty
    /// rating empty — rating a source is a human judgement the app must not
    /// make on the user's behalf.
    func testSeeder_aggregatesBySenderAndLeavesRatingToTheHuman() {
        func mail(from: String) -> MBOXParser.RawEmail {
            MBOXParser.RawEmail(
                headers: ["From": from, "Subject": "s",
                          "Date": "Tue, 14 Mar 2017 09:41:00 +0000"],
                rawSource: "", messageType: "email", attachments: [],
                timestamp: "Tue, 14 Mar 2017 09:41:00 +0000",
                domains: ["example.com"], plainBody: "body", htmlBody: "")
        }

        let entries = SourceReliabilitySeeder.seed(from: [
            mail(from: "Ada Lovelace <ada@example.com>"),
            mail(from: "ada@example.com"),
            mail(from: "ADA@EXAMPLE.COM"),
            mail(from: "other@example.com")
        ])

        let ada = entries.first { $0.source == "ada@example.com" }
        XCTAssertNotNil(ada,
                        "the bracketed and bare forms must fold together; got \(entries.map(\.source))")
        XCTAssertEqual(ada?.emailCount, 3, "all three spellings are one sender")
        XCTAssertNil(ada?.reliability, "the app must not assign an Admiralty reliability")
        XCTAssertNil(ada?.credibility, "the app must not assign an Admiralty credibility")
        XCTAssertFalse(ada?.isRated ?? true)
        XCTAssertEqual(ada?.ratingCode, "—", "an unrated source shows no code")
        XCTAssertTrue(ada?.authHint.contains("3 emails") ?? false, "hint: \(ada?.authHint ?? "")")

        // Most frequent sender first, so the reviewer rates what matters most.
        XCTAssertEqual(entries.first?.source, "ada@example.com")
    }

    /// A listed-but-unrated source must block posting: a desk that shows
    /// sources with no judgement implies one.
    func testPostGate_listedSourceMustBeRatedOnBothAxes() {
        var desk = EvidenceDeskModel(title: "Desk")
        desk.sources = [SourceReliabilityEntry(source: "ada@example.com", emailCount: 3)]
        XCTAssertTrue(desk.postBlockers.contains { $0.contains("unrated") },
                      "\(desk.postBlockers)")

        desk.sources[0].reliability = .a
        XCTAssertTrue(desk.postBlockers.contains { $0.contains("unrated") },
                      "one axis is not enough: \(desk.postBlockers)")

        desk.sources[0].credibility = .one
        XCTAssertTrue(desk.postBlockers.isEmpty,
                      "both axes rated must post; got \(desk.postBlockers)")
        XCTAssertEqual(desk.sources[0].ratingCode, "A1")
    }

    /// A recorded gap is an ABSENCE, and must be acknowledged as such before
    /// it can enter a numbered document — otherwise it reads as a finding.
    func testPostGate_gapMustBeAcknowledgedAsAnAbsence() {
        var desk = EvidenceDeskModel(title: "Desk")
        desk.gaps = [GapEntry(expected: "No email from the CFO approving the wire")]
        XCTAssertTrue(desk.postBlockers.contains { $0.contains("ABSENCE") },
                      "\(desk.postBlockers)")

        desk.gaps[0].acknowledged = true
        XCTAssertTrue(desk.postBlockers.isEmpty, "\(desk.postBlockers)")
    }

    /// An entirely empty desk must not post.
    func testPostGate_emptyDeskIsNotPostable() {
        let desk = EvidenceDeskModel(title: "Empty")
        XCTAssertFalse(desk.postBlockers.isEmpty, "an empty desk must not be postable")
    }
}

// MARK: - Studio 5: Action register (CAPA)

final class ActionRegisterBehaviourTests: XCTestCase {

    /// Closing an action as EFFECTIVE is a human decision that must cite its
    /// verification evidence. The app must never declare effectiveness.
    func testCloseGate_effectiveClosureNeedsEvidenceNoteAndVerifier() {
        var action = CAPAAction(action: "Rotate the signing certificate",
                                cause: "Certificate expired unnoticed")

        let bare = ActionRegisterModel.closeBlockers(for: action, asEffective: true)
        XCTAssertTrue(bare.contains { $0.contains("effectiveness note") }, "\(bare)")
        XCTAssertTrue(bare.contains { $0.contains("verifier") }, "\(bare)")

        action.effectivenessNote = "No expiry alerts in the 90 days since rotation"
        XCTAssertTrue(ActionRegisterModel.closeBlockers(for: action, asEffective: true)
                        .contains { $0.contains("verifier") },
                      "a note without a named verifier must still block")

        action.verifiedBy = "S. Sasmal"
        XCTAssertTrue(ActionRegisterModel.closeBlockers(for: action, asEffective: true).isEmpty,
                      "note + verifier must allow an effective closure")
    }

    /// Closing as INEFFECTIVE still needs a named verifier — someone decided
    /// it did not work — but not an effectiveness note, because there is no
    /// effectiveness to evidence.
    func testCloseGate_ineffectiveClosureStillNeedsAVerifier() {
        var action = CAPAAction(action: "Add a monitoring alert", cause: "Silent failure")

        let blockers = ActionRegisterModel.closeBlockers(for: action, asEffective: false)
        XCTAssertEqual(blockers.count, 1, "only the verifier should be missing: \(blockers)")
        XCTAssertTrue(blockers.first?.contains("verifier") ?? false, "\(blockers)")

        action.verifiedBy = "S. Sasmal"
        XCTAssertTrue(ActionRegisterModel.closeBlockers(for: action, asEffective: false).isEmpty)
    }

    /// Every action must state the cause it addresses, and the open count must
    /// reflect the closed statuses.
    func testPostGate_everyActionMustNameItsCause() {
        var model = ActionRegisterModel(title: "Register")
        XCTAssertTrue(model.postBlockers.contains { $0.contains("at least one action") },
                      "\(model.postBlockers)")

        var orphan = CAPAAction(action: "Do something")     // cause deliberately blank
        model.actions = [orphan]
        XCTAssertTrue(model.postBlockers.contains { $0.contains("no linked cause") },
                      "\(model.postBlockers)")

        orphan.cause = "Root cause 3 from the reasoning case"
        model.actions = [orphan]
        XCTAssertTrue(model.postBlockers.isEmpty, "\(model.postBlockers)")

        XCTAssertEqual(model.openCount, 1)
        model.actions[0].status = .closedEffective
        XCTAssertEqual(model.openCount, 0)
        model.actions[0].status = .closedIneffective
        XCTAssertEqual(model.openCount, 0,
                       "an ineffective closure is still closed — reopening is a new action")
    }
}
