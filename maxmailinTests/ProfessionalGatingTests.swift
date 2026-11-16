@testable import ArchiveCore
//
//  ProfessionalGatingTests.swift
//  maxmailinTests
//
//  F-3: switching Page 3 off must stop its work and hide its surfaces, and
//  must never touch its evidence. Legal holds and Bates assignments survive
//  a disable → enable cycle untouched; the export layer's Professional hook
//  follows the page's switch; no Professional job is registered while the
//  page is off.
//

import XCTest
@testable import maxmailin

@MainActor
final class ProfessionalGatingTests: XCTestCase {

    private func registry() -> ModuleRegistry {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modules-\(UUID().uuidString).json")
        return ModuleRegistry(store: ModuleStateStore(url: url), excludedByBuild: [], trapsOnMisuse: false)
    }

    func testLegalHoldSurvivesDisableAndEnable() throws {
        let modules = registry()
        try modules.enable(.professional)
        let id = UUID()
        CustodianManager.shared.placeLegalHold(id)
        defer { CustodianManager.shared.removeLegalHold(id) }
        XCTAssertTrue(CustodianManager.shared.isUnderLegalHold(id))

        modules.disable(.professional, retention: .deleteLocalCache)
        XCTAssertFalse(modules.isEnabled(.professional))
        XCTAssertTrue(CustodianManager.shared.isUnderLegalHold(id), "disabling the page must never lift a hold")

        try modules.enable(.professional)
        XCTAssertTrue(CustodianManager.shared.isUnderLegalHold(id))
    }

    func testBatesAssignmentsSurviveDisable() throws {
        let modules = registry()
        try modules.enable(.professional)
        let id = UUID()
        let before = BatesNumberingManager.shared.startNumber
        BatesNumberingManager.shared.merge(assignments: [id: "TEST000042"], nextStart: before)
        defer { BatesNumberingManager.shared.assignments.removeValue(forKey: id) }
        modules.disable(.professional)
        XCTAssertEqual(BatesNumberingManager.shared.getBatesNumber(for: id), "TEST000042")
    }

    /// Review C2: one numbering authority. The Bates tool works on `.shared`,
    /// and no app source builds a second live manager over the same settings.
    func testBatesToolUsesTheSharedManager_andNoSecondManagerExists() throws {
        XCTAssertTrue(BatesConfigView(emails: []).manager === BatesNumberingManager.shared)
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("maxmailin", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let second = text.split(separator: "\n").filter {
                $0.contains("BatesNumberingManager()") && !$0.contains("static let shared")
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            XCTAssertTrue(second.isEmpty, "\(file.lastPathComponent) builds a second BatesNumberingManager; use .shared: \(second)")
        }
    }

    /// Review D1: the purchase is checked where every path opens a tool —
    /// the Mac menu, ⌘K, the persona toolbars and the sidebar all set the
    /// same `AppStateManager` flag — and where forensic mode is switched on
    /// (toolbar, ⌘K "Toggle Forensic Mode", Settings, the Forensic persona).
    func testProfessionalTools_needThePurchase_onEveryPathThroughTheSeam() throws {
        let professionalTools: [WritableKeyPath<AppStateManager, Bool>] = [
            \.showBatesNumbering, \.showEDiscovery, \.showRedaction, \.showGDPRReport,
            \.showChainOfCustody, \.showCustodianPanel, \.showReviewBatches, \.showInvestigationReport,
        ]
        // Free, and a lapsed Professional subscriber: refused, with the paywall.
        for store in [StoreManager(testTier: .free), StoreManager(testTier: .free, lapsedFrom: .professional),
                      StoreManager(testTier: .personal)] {
            var state = AppStateManager()
            state.isPurchased = AppStateManager.purchaseGate(store)
            for tool in professionalTools {
                state[keyPath: tool] = true
                XCTAssertFalse(state[keyPath: tool], "\(tool) opened without Professional (tier \(store.effectiveTier))")
            }
            XCTAssertEqual(store.paywallRequest?.requiredTier, .professional, "the existing purchase prompt is shown")
            // The audit trail keeps its Free view.
            state.showAuditTrail = true
            XCTAssertTrue(state.showAuditTrail)
        }
        // Professional: every tool opens.
        let pro = StoreManager(testTier: .professional)
        var owned = AppStateManager()
        owned.isPurchased = AppStateManager.purchaseGate(pro)
        for tool in professionalTools {
            owned[keyPath: tool] = true
            XCTAssertTrue(owned[keyPath: tool], "\(tool)")
        }
        XCTAssertNil(pro.paywallRequest)

        // Forensic mode: the one switch, refused without the purchase.
        let forensic = ForensicManager.shared
        let saved = forensic.isEnabled
        defer { forensic.isEnabled = saved }
        forensic.isEnabled = false
        let free = StoreManager(testTier: .free)
        XCTAssertFalse(forensic.setForensicMode(true, store: free))
        XCTAssertFalse(forensic.isEnabled)
        XCTAssertNotNil(free.paywallRequest)
        XCTAssertTrue(forensic.setForensicMode(true, store: pro))
        XCTAssertTrue(forensic.isEnabled)
        XCTAssertTrue(forensic.setForensicMode(false, store: free), "switching off never needs a purchase")
        XCTAssertFalse(forensic.isEnabled)
        // The Forensic persona is not a purchase.
        XCTAssertFalse(ForensicManager.personaDefault(true, tier: .free))
        XCTAssertFalse(ForensicManager.personaDefault(true, tier: .personal))
        XCTAssertTrue(ForensicManager.personaDefault(true, tier: .professional))

        // No app path flips the switch around the seam.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("maxmailin", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" && file.lastPathComponent != "ForensicManager.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for bypass in ["forensicManager.isEnabled = true", "forensicManager.isEnabled.toggle()",
                           "ForensicManager.shared.isEnabled.toggle()", "ForensicManager.shared.isEnabled = true",
                           "cfg.showForensicByDefault, forKey"] {
                XCTAssertFalse(text.contains(bypass), "\(file.lastPathComponent): \(bypass) bypasses setForensicMode")
            }
        }
    }

    func testRiskScorerFollowsThePageSwitch() throws {
        let modules = registry()
        try modules.enable(.professional)
        XCTAssertNotNil(ArchiveExportService.riskScoreProvider, "enabling Page 3 installs the detailed-CSV risk scorer")
        modules.disable(.professional)
        XCTAssertNil(ArchiveExportService.riskScoreProvider, "a Page-1-only install never runs forensic code through an export")
    }

    func testNoProfessionalJobRunsWhileThePageIsOff() {
        let modules = registry()
        XCTAssertFalse(modules.isEnabled(.professional))
        let chainBefore = HMACChainAuditLog.shared.entries.count
        LaunchJobs.run(modules: modules, storageActive: false, storageStateLabel: "test")
        XCTAssertTrue(modules.jobs.jobs(for: .professional).isEmpty)
        XCTAssertEqual(HMACChainAuditLog.shared.entries.count, chainBefore, "no audit-chain launch entry on a Page-1-only launch (§3.3 R6)")
    }

    func testInventoryOwnsEveryProfessionalJob() {
        let professional = LaunchJobs.jobs(for: .professional).map(\.id)
        XCTAssertEqual(Set(professional), ["workflow.seed", "audit.launch"])
        XCTAssertEqual(LaunchJobs.inventory.count, Set(LaunchJobs.inventory.map(\.id)).count, "job ids are unique")
    }
}

// MARK: - Audit F11: the HMAC chain detects truncation, replacement and loss

@MainActor
final class HMACChainHeadTests: XCTestCase {

    private func makeLog(anchors: ChainAnchors = .inMemory()) -> (HMACChainAuditLog, URL, ChainAnchors) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hmac-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("chain.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (HMACChainAuditLog(storeURL: url, anchors: anchors), url, anchors)
    }

    private func reopen(_ url: URL, anchors: ChainAnchors) -> HMACChainAuditLog {
        HMACChainAuditLog(storeURL: url, anchors: anchors)
    }

    func testIntactChainVerifiesAndRecordsItsHead() throws {
        let (log, _, anchors) = makeLog()
        XCTAssertTrue(log.verifyChain(), "an empty log with no anchor is a fresh log")
        XCTAssertEqual(log.integrityState, .verified(entryCount: 0))
        for i in 0..<3 { try log.append(action: "test", detail: "entry \(i)") }
        XCTAssertTrue(log.verifyChain())
        XCTAssertEqual(try anchors.loadHead(), ChainHead(count: 3, hmac: log.entries.last!.hmac))
    }

    func testRemovingTheLastEntryIsDetected() throws {
        let (log, url, anchors) = makeLog()
        for i in 0..<4 { try log.append(action: "test", detail: "entry \(i)") }
        // Truncate the file to a valid PREFIX — what a chain alone accepts.
        let prefix = Array(log.entries.dropLast())
        try PrivacyHardening.writeJSON(prefix, to: url)
        let reopened = reopen(url, anchors: anchors)
        XCTAssertEqual(reopened.entries.count, 3)
        XCTAssertFalse(reopened.verifyChain(), "a valid prefix is NOT an intact log")
        guard case .broken(let index, let reason) = reopened.integrityState else { return XCTFail("\(reopened.integrityState)") }
        XCTAssertEqual(index, 3)
        XCTAssertTrue(reason.contains("only 3 present"), reason)
    }

    func testEmptyingTheLogIsDetected() throws {
        let (log, url, anchors) = makeLog()
        for i in 0..<2 { try log.append(action: "test", detail: "entry \(i)") }
        try PrivacyHardening.writeJSON([HMACChainAuditLog.Entry](), to: url)
        let reopened = reopen(url, anchors: anchors)
        XCTAssertFalse(reopened.verifyChain(), "an empty presented chain must not verify while the anchor records entries")
    }

    func testReplacedLogWithTheSameLengthIsDetected() throws {
        let (log, url, anchors) = makeLog()
        for i in 0..<2 { try log.append(action: "test", detail: "entry \(i)") }
        // A different, internally valid chain of the same length (another log with the same key).
        let (other, otherURL, _) = makeLog(anchors: ChainAnchors(loadKey: anchors.loadKey, saveKey: anchors.saveKey,
                                                                loadHead: { nil }, saveHead: { _ in }))
        for i in 0..<2 { try other.append(action: "other", detail: "entry \(i)") }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: otherURL, to: url)
        let reopened = reopen(url, anchors: anchors)
        XCTAssertFalse(reopened.verifyChain())
        guard case .broken(_, let reason) = reopened.integrityState else { return XCTFail() }
        XCTAssertTrue(reason.contains("replaced"), reason)
    }

    func testMissingLogWithAnAnchorIsALossNotAFreshLog() throws {
        let (log, url, anchors) = makeLog()
        for i in 0..<2 { try log.append(action: "test", detail: "entry \(i)") }
        try FileManager.default.removeItem(at: url)
        let reopened = reopen(url, anchors: anchors)
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertFalse(reopened.verifyChain())
        // The next chain begins by recording the loss.
        try reopened.append(action: "test", detail: "after loss")
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.entries.first?.action, HMACChainAuditLog.historyUnavailableAction)
        XCTAssertTrue(reopened.entries.first!.detail.contains("recorded head was entry 2"))
        XCTAssertTrue(reopened.verifyChain(), "the new chain, with its loss entry, is intact and anchored")
    }

    func testUnreadableLogIsQuarantinedNeverOverwritten() throws {
        let (log, url, anchors) = makeLog()
        for i in 0..<2 { try log.append(action: "test", detail: "entry \(i)") }
        try Data("{ not json".utf8).write(to: url)
        let reopened = reopen(url, anchors: anchors)
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertFalse(reopened.verifyChain())
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("hmac_audit_chain.corrupt-") }, "the unreadable file is kept: \(siblings)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try reopened.append(action: "test", detail: "after corruption")
        XCTAssertEqual(reopened.entries.first?.action, HMACChainAuditLog.historyUnavailableAction)
        XCTAssertTrue(reopened.entries.first!.detail.contains("quarantined"))
        XCTAssertTrue(reopened.verifyChain())
    }

    /// Recheck R3: appending to a truncated prefix must not re-anchor it.
    func testAppendAfterTruncationIsRefusedAndTheBreakStaysVisible() throws {
        let (log, url, anchors) = makeLog()
        for i in 0..<3 { try log.append(action: "test", detail: "entry \(i)") }
        try PrivacyHardening.writeJSON(Array(log.entries.dropLast()), to: url)
        let reopened = reopen(url, anchors: anchors)
        XCTAssertEqual(reopened.entries.count, 2)
        // Append WITHOUT verifying first — the path that used to erase the trace.
        XCTAssertThrowsError(try reopened.append(action: "test", detail: "after truncation")) { error in
            guard case HMACChainAuditLog.ChainError.chainInconsistentWithAnchor = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reopened.entries.count, 2, "nothing was appended")
        XCTAssertEqual(try anchors.loadHead()?.count, 3, "the anchor still records the lost entry")
        XCTAssertFalse(reopened.verifyChain(), "the truncation is still detectable")
        // And after a verify that reported broken, append is still refused.
        XCTAssertThrowsError(try reopened.append(action: "test", detail: "still refused"))
    }

    func testUnreadableAnchorRefusesAppendAndReportsBroken() throws {
        struct AnchorDown: Error {}
        let base = ChainAnchors.inMemory()
        let (log, url, _) = makeLog(anchors: base)
        for i in 0..<2 { try log.append(action: "test", detail: "entry \(i)") }
        let down = ChainAnchors(loadKey: base.loadKey, saveKey: base.saveKey,
                                loadHead: { throw AnchorDown() }, saveHead: base.saveHead)
        let reopened = reopen(url, anchors: down)
        XCTAssertEqual(reopened.entries.count, 2, "the entries are still readable")
        XCTAssertFalse(reopened.verifyChain(), "an unreadable anchor is not a verified chain")
        XCTAssertThrowsError(try reopened.append(action: "test", detail: "x")) { error in
            guard case HMACChainAuditLog.ChainError.anchorUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reopened.entries.count, 2)
    }

    func testPreAnchorLogIsAdoptedOnFirstVerify() throws {
        // A log written before anchors existed: entries on disk, no head.
        let (log, url, anchors) = makeLog(anchors: ChainAnchors.inMemory())
        for i in 0..<3 { try log.append(action: "test", detail: "entry \(i)") }
        try anchors.saveHead(nil)   // simulate "no anchor was ever recorded"
        let reopened = reopen(url, anchors: anchors)
        XCTAssertNil(try anchors.loadHead())
        XCTAssertTrue(reopened.verifyChain(), "adopt the chain as found")
        XCTAssertEqual(try anchors.loadHead()?.count, 3, "and anchor it from now on")
    }
}
