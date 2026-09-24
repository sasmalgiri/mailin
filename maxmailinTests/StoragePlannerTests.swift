//
//  StoragePlannerTests.swift
//  maxmailinTests
//
//  S2 of SIZE_LIMITS_DESIGN.md. The preflight is what makes S1's removal of
//  the size refusals honest: "not tested above 50 GB, proceeding" is only
//  defensible if something still stops an import that genuinely cannot finish.
//
//  The planning arithmetic is a pure function so a 500 GB scenario costs
//  nothing to test.
//

import Testing
import Foundation
@testable import maxmailin

private let GiB: Int64 = 1_073_741_824
private let TiB: Int64 = 1_099_511_627_776

@Suite("Storage preflight (S2)")
struct StoragePlannerTests {

    // MARK: The requirement

    @Test("The requirement accounts for every consumer, not just the source")
    func requirementCoversEveryConsumer() {
        let requirement = StoragePlanner.requirement(
            sourceBytes: 100 * GiB, copyOriginals: true, volumeCapacityBytes: TiB)

        #expect(requirement.originalCopyBytes == 100 * GiB, "a copied original is counted")
        #expect(requirement.storeBytes > 100 * GiB, "the store holds raw MIME plus extracted text")
        #expect(requirement.indexBytes > 0)
        // Overheads scale with the work and are capped, so a small import is
        // not told it needs gigabytes.
        #expect(requirement.walBytes == StoragePlanner.maxWALAllowanceBytes)
        #expect(requirement.spoolBytes == StoragePlanner.maxSpoolAllowanceBytes)
        #expect(requirement.hardFloorBytes == StoragePlanner.hardFloorBytes)
        #expect(requirement.total > requirement.sourceBytes * 2,
                "copy + store + index + overheads exceed twice the source")
    }

    @Test("Referencing originals instead of copying removes that cost")
    func referencingIsCheaper() {
        let copied = StoragePlanner.requirement(
            sourceBytes: 50 * GiB, copyOriginals: true, volumeCapacityBytes: TiB)
        let referenced = StoragePlanner.requirement(
            sourceBytes: 50 * GiB, copyOriginals: false, volumeCapacityBytes: TiB)

        #expect(referenced.originalCopyBytes == 0)
        #expect(referenced.total == copied.total - 50 * GiB)
    }

    @Test("Refusal uses a small hard floor; the volume-proportional margin only warns")
    func refusalAndComfortAreSeparate() {
        // The hard need does not grow with the size of the user's disk...
        let onSmallVolume = StoragePlanner.requirement(
            sourceBytes: GiB, copyOriginals: false, volumeCapacityBytes: 64 * GiB)
        let onHugeVolume = StoragePlanner.requirement(
            sourceBytes: GiB, copyOriginals: false, volumeCapacityBytes: 8 * TiB)
        #expect(onSmallVolume.total == onHugeVolume.total,
                "a bigger disk must not make the same import need more space")

        // ...but the comfort margin that triggers `tight` does, within bounds.
        #expect(StoragePlanner.comfortMargin(volumeCapacityBytes: 64 * GiB)
                == StoragePlanner.minimumComfortMarginBytes)
        #expect(StoragePlanner.comfortMargin(volumeCapacityBytes: 8 * TiB)
                == StoragePlanner.maximumComfortMarginBytes,
                "2 % of 8 TiB is clamped rather than demanding 160 GiB")
    }

    @Test("Coefficients trace to the measured fixture, not to a guess")
    func coefficientsAreMeasured() {
        // Measured: store 1.243×, FTS 0.044× of source on the owner fixture.
        // The store ratio rounds that up; the index ratio is deliberately far
        // higher because that corpus was attachment-heavy and text-heavy mail
        // indexes much more.
        #expect(StoragePlanner.storeRatio >= 1.243, "must not under-estimate the measured store growth")
        #expect(StoragePlanner.indexRatio > 0.044, "text-heavy mail indexes more than the measured corpus")
    }

    // MARK: Verdicts

    @Test("Plenty of space is ok, and reports the numbers")
    func spaciousVolumeIsOK() {
        let plan = StoragePlanner.plan(sourceBytes: 10 * GiB, copyOriginals: true,
                                       freeBytes: 2 * TiB, volumeCapacityBytes: 4 * TiB)
        #expect(plan.canProceed)
        if case .ok = plan {} else { Issue.record("expected .ok, got \(plan)") }
        #expect(plan.summary.contains("free"))
    }

    @Test("A fit that leaves almost nothing proceeds but says so")
    func tightFitProceedsWithAWarning() {
        let requirement = StoragePlanner.requirement(
            sourceBytes: 20 * GiB, copyOriginals: true, volumeCapacityBytes: 500 * GiB)
        // Just enough, plus a little slack — below the comfort margin.
        let free = requirement.total + GiB

        let plan = StoragePlanner.plan(sourceBytes: 20 * GiB, copyOriginals: true,
                                       freeBytes: free, volumeCapacityBytes: 500 * GiB)
        #expect(plan.canProceed, "a tight import still runs")
        if case .tight = plan {} else { Issue.record("expected .tight, got \(plan)") }
        #expect(plan.summary.contains("free up space"))
    }

    @Test("An import that cannot finish is refused with the exact shortfall")
    func insufficientSpaceReportsTheShortfall() {
        let plan = StoragePlanner.plan(sourceBytes: 500 * GiB, copyOriginals: true,
                                       freeBytes: 100 * GiB, volumeCapacityBytes: 512 * GiB)
        #expect(!plan.canProceed)
        guard case .insufficient(_, _, let missing) = plan else {
            Issue.record("expected .insufficient, got \(plan)")
            return
        }
        #expect(missing > 0)
        #expect(plan.summary.contains("short"))
        #expect(plan.summary.contains("Free up space"))
    }

    @Test("Unknown free space is treated as insufficient, never as unlimited")
    func unknownFreeSpaceIsRefused() {
        // A volume whose capacity cannot be read reports 0 free.
        let plan = StoragePlanner.plan(sourceBytes: 200 * GiB, copyOriginals: true,
                                       freeBytes: 0, volumeCapacityBytes: 0)
        #expect(!plan.canProceed,
                "an unreadable volume must not silently unlock a huge import")
    }

    @Test("A 1 TB import on a 250 GB Mac is refused — the directive's case")
    func theTerabyteOnASmallMacCase() {
        let plan = StoragePlanner.plan(sourceBytes: 1_000 * GiB, copyOriginals: true,
                                       freeBytes: 200 * GiB, volumeCapacityBytes: 250 * GiB)
        guard case .insufficient(let requirement, _, let missing) = plan else {
            Issue.record("expected refusal")
            return
        }
        #expect(missing > 2_000 * GiB - 400 * GiB, "the shortfall is stated, not hand-waved")
        #expect(requirement.breakdown.count >= 5, "and the requirement is itemised")
    }

    // MARK: Against a real volume

    @Test("Planning against a real directory returns usable numbers")
    func realVolumeQuery() throws {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("planner-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 4096).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let plan = StoragePlanner.plan(sources: [file], destination: dir, copyOriginals: true)
        #expect(plan.requirement.sourceBytes == 4096)
        #expect(plan.requirement.total > 0)
        // A 4 KB import on a working Mac must not be refused.
        #expect(plan.canProceed, "a trivial import should fit: \(plan.summary)")
    }

    @Test("The breakdown names each consumer for a refusal the user can argue with")
    func breakdownIsItemised() {
        let requirement = StoragePlanner.requirement(
            sourceBytes: 10 * GiB, copyOriginals: true, volumeCapacityBytes: TiB)
        let labels = requirement.breakdown.map(\.label)

        #expect(labels.contains { $0.contains("original") })
        #expect(labels.contains { $0.contains("database") })
        #expect(labels.contains { $0.contains("Search index") })
        #expect(labels.contains { $0.contains("Reserved") })
        #expect(requirement.breakdown.allSatisfy { $0.bytes > 0 })
    }
}


@Suite("Storage preflight — scaled overheads and missing destinations")
struct StoragePlannerScalingTests {

    @Test("A small import is not told it needs gigabytes of overhead")
    func smallImportHasSmallOverheads() {
        let requirement = StoragePlanner.requirement(
            sourceBytes: 95_000_000, copyOriginals: true, volumeCapacityBytes: 500 * GiB)

        #expect(requirement.walBytes == 95_000_000 / 2, "WAL scales with the work")
        #expect(requirement.spoolBytes == 95_000_000, "the spool cannot exceed the source")
        // A 95 MB import needs well under 2 GiB in total: the hard need is the
        // work plus a 1 GiB floor, not a slice of the user's disk.
        #expect(requirement.total < 2 * GiB)
    }

    @Test("A huge import keeps the capped overheads")
    func hugeImportCapsOverheads() {
        let requirement = StoragePlanner.requirement(
            sourceBytes: 800 * GiB, copyOriginals: true, volumeCapacityBytes: 4 * TiB)
        #expect(requirement.walBytes == StoragePlanner.maxWALAllowanceBytes)
        #expect(requirement.spoolBytes == StoragePlanner.maxSpoolAllowanceBytes)
    }

    @Test("A destination that does not exist yet still resolves a volume")
    func missingDestinationResolvesToAnAncestor() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)

        let resolved = StoragePlanner.nearestExistingDirectory(of: missing)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        // And planning against it does not refuse a trivial import, which is
        // the bug this fixes: the first import creates its own directory, and
        // treating "missing path" as "unreadable volume" refused everything.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-scale-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let plan = StoragePlanner.plan(sources: [file], destination: missing, copyOriginals: true)
        #expect(plan.canProceed, "a 2 KB import into a not-yet-created directory must fit: \(plan.summary)")
    }
}
