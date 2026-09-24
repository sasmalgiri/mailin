//
//  SourceSizePolicyTests.swift
//  maxmailinTests
//
//  S1 of SIZE_LIMITS_DESIGN.md. The decisions are pure functions precisely so
//  they can be tested without fabricating 50 GB fixtures.
//
//  What these pin:
//   • ANSI PST's 2 GB ceiling is enforced (it is a real format limit that was
//     previously not checked at all)
//   • the old 50 GB PST refusal is gone — a large Unicode PST warns and
//     proceeds, because 50 GB was Outlook's configurable default, not a limit
//   • NSF's ceiling is HCL's documented 256 GB, not the pre-ODS-53 64 GB
//   • the 64–256 GB NSF band says plainly that we cannot read the ODS version,
//     instead of implying certainty either way
//

import Testing
import Foundation
@testable import maxmailin

private let GiB: Int64 = 1_073_741_824

/// A PST header prefix with the given `wVer` at offset 10 (MS-PST HEADER).
private func pstHeader(version: UInt16, magicOK: Bool = true) -> Data {
    var bytes: [UInt8] = magicOK ? [0x21, 0x42, 0x44, 0x4E] : [0x00, 0x00, 0x00, 0x00]
    bytes += [0, 0, 0, 0]                    // dwCRCPartial
    bytes += [0x53, 0x4D]                    // wMagicClient "SM"
    bytes += [UInt8(version & 0xFF), UInt8(version >> 8)]   // wVer at offset 10
    bytes += [19, 0]                         // wVerClient
    return Data(bytes)
}

@Suite("Source size policy (S1)")
struct SourceSizePolicyTests {

    // MARK: Header reading

    @Test("wVer is read from offset 10 and classified per MS-PST")
    func versionParsing() {
        #expect(SourceSizePolicy.pstFormatVersion(fromHeader: pstHeader(version: 14))?.isANSI == true)
        #expect(SourceSizePolicy.pstFormatVersion(fromHeader: pstHeader(version: 15))?.isANSI == true)
        #expect(SourceSizePolicy.pstFormatVersion(fromHeader: pstHeader(version: 23))?.isANSI == false)
        #expect(SourceSizePolicy.pstFormatVersion(fromHeader: pstHeader(version: 37))?.mayBeWIPProtected == true)
    }

    @Test("A header without the PST magic yields no version")
    func rejectsForeignHeader() {
        #expect(SourceSizePolicy.pstFormatVersion(fromHeader: pstHeader(version: 23, magicOK: false)) == nil)
        #expect(SourceSizePolicy.pstFormatVersion(fromHeader: Data([0x21, 0x42])) == nil)
    }

    // MARK: ANSI's real 2 GB ceiling

    @Test("An ANSI PST above 2 GB is refused as corrupt, with the reason")
    func ansiAboveTwoGigabytesIsRefused() {
        let verdict = SourceSizePolicy.pstVerdict(version: .ansi(14), fileSize: 3 * GiB)
        let reason = try? #require(verdict.refusal)
        #expect(reason?.contains("ANSI") == true)
        #expect(reason?.contains("2 GB") == true)
        #expect(reason?.contains("mislabelled") == true || reason?.contains("corrupt") == true)
    }

    @Test("An ANSI PST within 2 GB is fine")
    func ansiWithinCeilingIsFine() {
        #expect(SourceSizePolicy.pstVerdict(version: .ansi(15), fileSize: GiB) == .ok)
    }

    // MARK: The 50 GB refusal is gone

    @Test("A 60 GB Unicode PST warns and proceeds — it is no longer refused")
    func largeUnicodePSTIsNotRefused() {
        let verdict = SourceSizePolicy.pstVerdict(version: .unicode(23), fileSize: 60_000_000_000)
        #expect(verdict.refusal == nil, "50 GB was Outlook's configurable default, not a format limit")
        let note = try? #require(verdict.warning)
        #expect(note?.contains("not been tested") == true)
        #expect(note?.contains("will not be refused") == true)
    }

    @Test("A Unicode PST under the tested ceiling passes silently")
    func normalUnicodePSTIsSilent() {
        #expect(SourceSizePolicy.pstVerdict(version: .unicode(23), fileSize: 10_000_000_000) == .ok)
    }

    @Test("A WIP-marked PST warns that content may be encrypted")
    func wipProtectedWarns() {
        let verdict = SourceSizePolicy.pstVerdict(version: .unicode(37), fileSize: GiB)
        let note = try? #require(verdict.warning)
        #expect(note?.contains("Windows Information Protection") == true)
        #expect(note?.contains("reported rather than skipped") == true)
    }

    @Test("An unreadable header does not produce a size complaint")
    func unknownVersionDefersToTheParser() {
        #expect(SourceSizePolicy.pstVerdict(version: nil, fileSize: 80 * GiB) == .ok)
    }

    // MARK: NSF — 256 GB, not 64

    @Test("An NSF of 100 GiB is accepted, not refused as it was before")
    func nsfAboveLegacyCeilingIsAccepted() {
        let verdict = SourceSizePolicy.nsfVerdict(fileSize: 100 * GiB)
        #expect(verdict.refusal == nil, "64 GB is the pre-ODS-53 limit, not the current one")
        let note = try? #require(verdict.warning)
        #expect(note?.contains("ODS 53") == true)
        #expect(note?.contains("cannot yet read the ODS version") == true,
                "the warning must admit what we cannot determine")
    }

    @Test("An NSF within 64 GiB passes silently")
    func nsfWithinLegacyCeilingIsSilent() {
        #expect(SourceSizePolicy.nsfVerdict(fileSize: 20 * GiB) == .ok)
    }

    @Test("An NSF beyond HCL's documented 256 GB maximum is refused")
    func nsfBeyondDocumentedMaximumIsRefused() {
        let verdict = SourceSizePolicy.nsfVerdict(fileSize: 300 * GiB)
        let reason = try? #require(verdict.refusal)
        #expect(reason?.contains("256 GB") == true)
        #expect(reason?.contains("corrupt") == true)
    }

    // MARK: Constants match the documented figures

    @Test("The constants are the documented limits, not invented numbers")
    func constantsMatchDocumentation() {
        #expect(SourceSizePolicy.ansiPSTMaxBytes == 2 * GiB)
        #expect(SourceSizePolicy.nsfLegacyMaxBytes == 64 * GiB)
        #expect(SourceSizePolicy.nsfModernMaxBytes == 256 * GiB)
        // The PST figure is a *tested* ceiling, deliberately not a limit.
        #expect(SourceSizePolicy.pstTestedCeilingBytes == 50_000_000_000)
    }

    // MARK: Routing surfaces it before import

    @Test("The classifier attaches the size verdict to a detected PST")
    func classifierSurfacesTheVerdict() throws {
        // A tiny ANSI-declaring file: well under 2 GB, so no complaint.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-\(UUID().uuidString).pst")
        try (pstHeader(version: 14) + Data(repeating: 0, count: 600)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SourceFormatClassifier.classify(url: url)
        #expect(result.format == .pst)
        #expect(result.warning == nil, "a small ANSI PST has nothing to warn about")
    }
}
