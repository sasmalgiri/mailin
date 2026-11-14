import XCTest
@testable import ArchiveCore

/// E1: the OCR pass's state file — which emails were read, and where an interrupted pass resumes.
final class AttachmentOCRStateTests: XCTestCase {

    func testDoneSet_cursor_andReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocrstate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("attachment-ocr.sqlite")
        let a = UUID(), b = UUID(), c = UUID()
        do {
            let state = try AttachmentOCRState(url: url)
            XCTAssertEqual(try state.done(among: [a, b, c]), [])
            try state.markDone([a, b])
            try state.markDone([a])   // idempotent
            XCTAssertEqual(try state.done(among: [a, b, c]), [a, b])
            XCTAssertEqual(try state.doneCount(), 2)
            XCTAssertNil(state.cursor)
            state.cursor = b.uuidString
            XCTAssertEqual(state.cursor, b.uuidString)
        }
        // A new launch (new connection) sees the same state: the pass resumes, nothing is re-read.
        let reopened = try AttachmentOCRState(url: url)
        XCTAssertEqual(try reopened.done(among: [a, b, c]), [a, b])
        XCTAssertEqual(reopened.cursor, b.uuidString)
        reopened.cursor = nil
        XCTAssertNil(reopened.cursor, "a finished pass clears its cursor")
        XCTAssertEqual(try reopened.done(among: []), [])
    }

    /// The state lives beside the archive, never inside it: the archive schema is unchanged.
    func testStateFileIsBesideTheArchive_schemaUnchanged() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocrstore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SQLiteEmailStore(directory: dir)
        let url = await store.attachmentOCRStateURL
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(url.lastPathComponent, "attachment-ocr.sqlite")
        // E1 adds no archive schema version: its state lives in its own file beside the store. The version
        // itself moved on with later work (v26 at v4.0), so it is no longer pinned here.
        XCTAssertGreaterThanOrEqual(SQLiteEmailStore.currentSchemaVersion, 20)
        let none = try await store.attachmentOCRCandidateIDs(after: nil, limit: 10)
        XCTAssertEqual(none, [])
        let count = try await store.attachmentOCRCandidateCount()
        XCTAssertEqual(count, 0)
    }
}
