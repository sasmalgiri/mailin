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
