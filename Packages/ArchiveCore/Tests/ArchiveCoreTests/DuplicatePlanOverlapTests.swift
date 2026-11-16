//
//  DuplicatePlanOverlapTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16 (E): an exact group [A, B] and a near group [B, C] chosen
//  independently gave "B survives C" while "A survives B" trashed B — C's tags
//  went into a copy in the Trash. The store resolves such chains to the copy
//  that really stays.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class DuplicatePlanOverlapTests: XCTestCase {

    private func email(_ i: Int) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<overlap-\(i)-\(UUID().uuidString)@test>", "Subject": "Same", "From": "a@test", "To": "me@test",
                      "Date": "Wed, 15 Jan 2025 14:30:00 +0000"],
            rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
            plainBody: "body", htmlBody: "")
    }

    func testResolvedPlans_followTheChainToTheCopyThatStays() {
        let a = UUID(), b = UUID(), c = UUID()
        let plans = SQLiteEmailStore.resolvedRemovalPlans([.init(survivor: a, removed: [b]), .init(survivor: b, removed: [c])])
        let removed = Set(plans.flatMap(\.removed))
        XCTAssertEqual(removed, [b, c])
        XCTAssertTrue(plans.allSatisfy { $0.survivor == a }, "\(plans)")
        // A cycle never trashes every copy.
        let cycle = SQLiteEmailStore.resolvedRemovalPlans([.init(survivor: a, removed: [b]), .init(survivor: b, removed: [a])])
        let cycleRemoved = Set(cycle.flatMap(\.removed))
        XCTAssertLessThan(cycleRemoved.count, 2, "one of the two copies stays: \(cycle)")
        XCTAssertTrue(cycle.allSatisfy { !cycleRemoved.contains($0.survivor) })
    }

    func testOverlappingPlans_mergeIntoTheSurvivorThatStays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        let a = email(1), b = email(2), c = email(3)
        try await store.insertBatch([a, b, c], batchSize: 10)
        try await store.userTagAdd("from-c", ids: [c.id])

        let result = try await store.removeDuplicateCopies([.init(survivor: a.id, removed: [b.id]),
                                                            .init(survivor: b.id, removed: [c.id])])
        XCTAssertEqual(Set(result.trashed), [b.id, c.id])
        let tags = try await store.userTags(ids: [a.id])
        XCTAssertEqual(tags[a.id], ["from-c"], "C's tag reaches the copy that stays")
        let states = try await store.reviewStates(ids: [a.id])
        XCTAssertNotEqual(states[a.id]?.trashed, true)
    }
}
