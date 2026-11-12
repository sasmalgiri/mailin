//
//  UITestStorageRootTests.swift
//  ArchiveCoreTests
//
//  CLOSE-06: the fresh-archive hook used by the five-journey UI test is
//  engaged only by BOTH `--uitest` and `MAILIN_UITEST_FRESH_ARCHIVE`, stays
//  inside the temporary directory, and is inert otherwise.
//

import XCTest
@testable import ArchiveCore

final class UITestStorageRootTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("uitest-root-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    func testEngagedOnlyWithBothSwitches_rootedInTheTemporaryDirectory() throws {
        let key = UITestStorageRoot.environmentKey
        XCTAssertNil(UITestStorageRoot.resolve(arguments: ["app"], environment: [key: "fj1"], temporaryDirectory: tmp),
                     "environment alone does nothing")
        XCTAssertNil(UITestStorageRoot.resolve(arguments: ["app", "--uitest"], environment: [:], temporaryDirectory: tmp),
                     "--uitest alone keeps the normal UI-test behaviour")
        let url = try XCTUnwrap(UITestStorageRoot.resolve(arguments: ["app", "--uitest"], environment: [key: "fj1"], temporaryDirectory: tmp))
        XCTAssertEqual(url.path, tmp.appendingPathComponent("mailin-uitest-fj1/Application Support").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "created on first use")
    }

    func testTokenCannotEscapeTheTemporaryDirectory() {
        let key = UITestStorageRoot.environmentKey
        for token in ["../x", "a/b", "", " ", String(repeating: "a", count: 65), "é"] {
            XCTAssertNil(UITestStorageRoot.resolve(arguments: ["--uitest"], environment: [key: token], temporaryDirectory: tmp), token)
        }
    }

    func testNormalProcessSeesTheRealApplicationSupport() {
        // The test process is not launched with --uitest: the hook is off and
        // every store keeps its usual location.
        XCTAssertNil(UITestStorageRoot.override)
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        XCTAssertEqual(UITestStorageRoot.applicationSupport, real)
        XCTAssertEqual(ArchiveLayout.defaultRoot, real?.appendingPathComponent(ArchiveLayout.containerName, isDirectory: true))
    }
}
