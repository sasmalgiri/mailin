//
//  SplitVolumeTests.swift
//  ArchiveCoreTests
//
//  Completion directive 2026-11-07 §6 "Containers": archives split into
//  volumes. A spanned ZIP written by Info-ZIP (`zip -s 64k`, part of
//  macOS) at test time — PK\x07\x08 marker, disk numbers in the central
//  directory, a member running over the volume boundary — and 7z sets
//  split byte-wise (`.7z.001 …`). With every volume present every member
//  reads byte-exact; with one missing, the members that need it are
//  "not opened: volume N (name) missing" and the rest still read; with the
//  volume that holds the index missing, the archive itself says which one.
//

import XCTest
@testable import ArchiveCore

final class SplitVolumeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func children(_ result: OfficeTextExtractor.Result) -> [String: ChildDocument] {
        Dictionary(result.children.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Name recognition

    func testVolumeNamesAreRecognised() {
        XCTAssertEqual(SplitVolumeSet.part(ofName: "Takeout.z01"), .init(kind: .zipSpanned, stem: "Takeout", number: 1))
        XCTAssertEqual(SplitVolumeSet.part(ofName: "Takeout.Z12"), .init(kind: .zipSpanned, stem: "Takeout", number: 12))
        XCTAssertEqual(SplitVolumeSet.part(ofName: "Takeout.zip"), .init(kind: .zipSpanned, stem: "Takeout", number: nil))
        XCTAssertEqual(SplitVolumeSet.part(ofName: "big.7z.001"), .init(kind: .sevenZipSplit, stem: "big.7z", number: 1))
        XCTAssertEqual(SplitVolumeSet.part(ofName: "big.7z.017"), .init(kind: .sevenZipSplit, stem: "big.7z", number: 17))
        XCTAssertNil(SplitVolumeSet.part(ofName: "report.docx"))
        XCTAssertNil(SplitVolumeSet.part(ofName: "photo.001"), "a three-digit extension alone is not a 7z volume")
        XCTAssertEqual(SplitVolumeSet.zipVolumeName(stem: "a", number: 2, count: 3), "a.z02")
        XCTAssertEqual(SplitVolumeSet.zipVolumeName(stem: "a", number: 3, count: 3), "a.zip")
        XCTAssertEqual(SplitVolumeSet.sevenZipVolumeName(stem: "a.7z", number: 3), "a.7z.003")
    }

    // MARK: - Spanned ZIP written by Info-ZIP

    /// `zip -s 64k -0`: a.bin (70,000 bytes) starts on disk 0 and runs into disk 1; b.bin and c.txt sit on disk 1.
    private func makeInfoZipSpannedSet() throws -> (a: Data, b: Data, c: Data) {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zip.path) else { throw XCTSkip("/usr/bin/zip is not available") }
        var generator = SystemRandomNumberGenerator()
        let a = Data((0..<70_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let b = Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let c = Data("small text member MAILIN-SPANNED-ZIP\n".utf8)
        try a.write(to: dir.appendingPathComponent("a.bin"))
        try b.write(to: dir.appendingPathComponent("b.bin"))
        try c.write(to: dir.appendingPathComponent("c.txt"))
        let process = Process()
        process.executableURL = zip
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-0", "-s", "64k", "s.zip", "a.bin", "b.bin", "c.txt"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("zip -s failed (\(process.terminationStatus))") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("s.z01").path))
        return (a, b, c)
    }

    func testInfoZipSpannedSet_everyMemberReadsAcrossTheVolumeBoundary() throws {
        let (a, b, c) = try makeInfoZipSpannedSet()
        let z01 = dir.appendingPathComponent("s.z01"), last = dir.appendingPathComponent("s.zip")
        XCTAssertEqual(ZIPArchiveReader.spannedDiskCount(url: last), 2)
        XCTAssertNil(ZIPArchiveReader.spannedDiskCount(url: SevenZipReaderTests.publicPack.appendingPathComponent("02_archives/7zip_generated/7zip_ZipCrypto.zip")), "an ordinary ZIP is not a set")
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: z01), .zip, "the PK\\x07\\x08 marker is a ZIP volume")

        // Directly: the set's directory has disk numbers and absolute offsets.
        let set = try XCTUnwrap(SplitVolumeSet.zipSet(primary: last, primaryName: "s.zip", siblings: [.init(url: z01)]))
        XCTAssertEqual(set.volumeCount, 2)
        XCTAssertTrue(set.missingVolumeNumbers.isEmpty)
        let members = try ZIPArchiveReader.members(source: set)
        XCTAssertEqual(members.map(\.name), ["a.bin", "b.bin", "c.txt"])
        XCTAssertEqual(members[0].diskNumberStart, 0)
        XCTAssertEqual(members[1].diskNumberStart, 1)
        for (member, expected) in zip(members, [a, b, c]) {
            let out = dir.appendingPathComponent("out-\(member.name)")
            try ZIPArchiveReader.extract(member, source: set, to: out)
            XCTAssertEqual(try Data(contentsOf: out), expected, member.name)
        }

        // Through the container reader, from either volume as the attachment.
        for (primary, name, sibling) in [(last, "s.zip", z01), (z01, "s.z01", last)] {
            let result = try DocumentTextExtractor.extract(fileURL: primary, kind: .zip, logicalName: name, siblings: [.init(url: sibling)])
            let byPath = children(result)
            XCTAssertEqual(byPath["a.bin"]?.sha256, SevenZipReaderTests.sha256(a), "a.bin runs over the boundary (\(name))")
            XCTAssertEqual(byPath["b.bin"]?.sha256, SevenZipReaderTests.sha256(b))
            XCTAssertEqual(byPath["c.txt"]?.state, .extracted)
            XCTAssertTrue(byPath["c.txt"]?.text?.contains("MAILIN-SPANNED-ZIP") == true)
        }
    }

    func testInfoZipSpannedSet_missingVolumeIsNamed_restStillRead() throws {
        let (_, b, _) = try makeInfoZipSpannedSet()
        let last = dir.appendingPathComponent("s.zip")
        // The .zip alone: a.bin starts on the missing volume 1; b.bin and c.txt are on this one.
        let result = try DocumentTextExtractor.extract(fileURL: last, kind: .zip, logicalName: "s.zip", siblings: [])
        let byPath = children(result)
        XCTAssertEqual(byPath["a.bin"]?.state, .unsupported)
        XCTAssertEqual(byPath["a.bin"]?.note, "not opened: volume 1 (s.z01) missing")
        XCTAssertEqual(byPath["b.bin"]?.sha256, SevenZipReaderTests.sha256(b))
        XCTAssertEqual(byPath["c.txt"]?.state, .extracted)
        XCTAssertTrue(result.skipped.contains { $0.contains("volume 1 (s.z01) missing") })

        // The .z01 alone: the directory lives on the missing last volume — the archive says so.
        let z01 = dir.appendingPathComponent("s.z01")
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: z01, kind: .zip, logicalName: "s.z01", siblings: [])) { error in
            guard case .notAPackage(let detail)? = error as? OfficeTextExtractor.ExtractError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("volume 2 (s.zip) missing"), detail)
        }
    }

    // MARK: - 7z split sets

    /// Three 30,000-byte files in separate (non-solid) folders, split into 40,000-byte volumes:
    /// A lies in volume 1; B runs from 1 into 2; C from 2 into 3; the index is in volume 3.
    private func makeSevenZipSplitSet() throws -> (whole: URL, parts: [URL], payloads: [String: Data]) {
        var generator = SystemRandomNumberGenerator()
        func blob(_ marker: String) -> Data {
            var d = Data(marker.utf8); d.append(Data((d.count..<30_000).map { _ in UInt8.random(in: 0...255, using: &generator) })); return d
        }
        let payloads = ["A.bin": blob("AAAA"), "B.bin": blob("BBBB"), "C.bin": blob("CCCC")]
        let whole = dir.appendingPathComponent("set.7z")
        try SevenZipFixtureWriter.write(["A.bin", "B.bin", "C.bin"].map { .init(name: $0, data: payloads[$0]!) }, to: whole, solid: false)
        let bytes = try Data(contentsOf: whole)
        var parts: [URL] = []
        var offset = 0, n = 1
        while offset < bytes.count {
            let end = min(offset + 40_000, bytes.count)
            let url = dir.appendingPathComponent("set.7z.\(String(format: "%03d", n))")
            try bytes.subdata(in: offset..<end).write(to: url)
            parts.append(url); offset = end; n += 1
        }
        XCTAssertEqual(parts.count, 3)
        return (whole, parts, payloads)
    }

    func testSevenZipSplitSet_allVolumes_everyMemberByteExact() throws {
        let (_, parts, payloads) = try makeSevenZipSplitSet()
        let set = try XCTUnwrap(SplitVolumeSet.sevenZipSet(primary: parts[0], primaryName: "set.7z.001", siblings: parts.dropFirst().map { .init(url: $0) }))
        XCTAssertEqual(set.volumeCount, 3)
        let lastSize = Int64(try Data(contentsOf: parts[2]).count)
        XCTAssertEqual(set.length, 80_000 + lastSize)
        let result = try DocumentTextExtractor.extract(fileURL: parts[0], kind: .sevenZip, logicalName: "set.7z.001", siblings: parts.dropFirst().map { .init(url: $0) })
        let byPath = children(result)
        for (name, data) in payloads {
            XCTAssertEqual(byPath[name]?.sha256, SevenZipReaderTests.sha256(data), name)
        }
        // From a middle volume as the attachment, the same set is found.
        let fromMiddle = try DocumentTextExtractor.extract(fileURL: parts[1], kind: .sevenZip, logicalName: "set.7z.002", siblings: [parts[0], parts[2]].map { .init(url: $0) })
        XCTAssertEqual(children(fromMiddle)["B.bin"]?.sha256, SevenZipReaderTests.sha256(payloads["B.bin"]!))
    }

    func testSevenZipSplitSet_missingMiddleVolume_namedPerMember_restRead() throws {
        let (_, parts, payloads) = try makeSevenZipSplitSet()
        // Volume 2 absent: A (volume 1 only) reads; B and C need volume 2.
        let result = try DocumentTextExtractor.extract(fileURL: parts[0], kind: .sevenZip, logicalName: "set.7z.001", siblings: [.init(url: parts[2])])
        let byPath = children(result)
        XCTAssertEqual(byPath["A.bin"]?.sha256, SevenZipReaderTests.sha256(payloads["A.bin"]!))
        XCTAssertEqual(byPath["B.bin"]?.state, .unsupported)
        XCTAssertEqual(byPath["B.bin"]?.note, "not opened: volume 2 (set.7z.002) missing")
        XCTAssertEqual(byPath["C.bin"]?.note, "not opened: volume 2 (set.7z.002) missing")
        XCTAssertEqual(result.children.count, 3, "every member listed")
    }

    func testSevenZipSplitSet_missingFirstVolume_theArchiveSaysWhich() throws {
        let (_, parts, _) = try makeSevenZipSplitSet()
        // Volume 1 holds the start header, the only thing that locates the index: without it
        // nothing can be listed, and the archive names the volume instead of guessing.
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: parts[2], kind: .sevenZip, logicalName: "set.7z.003", siblings: [.init(url: parts[1])])) { error in
            guard case .notAPackage(let detail)? = error as? OfficeTextExtractor.ExtractError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("volume 1 (set.7z.001) missing"), detail)
        }
    }

    func testSevenZipSplitSet_missingLastVolume_theArchiveSaysWhich() throws {
        let (_, parts, _) = try makeSevenZipSplitSet()
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: parts[0], kind: .sevenZip, logicalName: "set.7z.001", siblings: [.init(url: parts[1])])) { error in
            guard case .notAPackage(let detail)? = error as? OfficeTextExtractor.ExtractError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("volume 3 (set.7z.003) missing"), detail)
        }
        // A lone .7z.002 (no signature, no siblings): volume 1 is what is missing.
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: parts[1], kind: .sevenZip, logicalName: "set.7z.002", siblings: [])) { error in
            guard case .notAPackage(let detail)? = error as? OfficeTextExtractor.ExtractError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("volume 1 (set.7z.001) missing"), detail)
        }
    }

    func testSiblingResolverIsUsedWhenNoSiblingsArePassed() throws {
        let (_, parts, payloads) = try makeSevenZipSplitSet()
        let saved = ContainerTextExtractor.siblingResolver
        defer { ContainerTextExtractor.siblingResolver = saved }
        let others = parts.dropFirst().map { SplitVolumeSet.Sibling(url: $0) }
        ContainerTextExtractor.siblingResolver = { _, _ in others }
        let result = try DocumentTextExtractor.extract(fileURL: parts[0], kind: .sevenZip, logicalName: "set.7z.001")
        XCTAssertEqual(children(result)["C.bin"]?.sha256, SevenZipReaderTests.sha256(payloads["C.bin"]!))
    }
}
