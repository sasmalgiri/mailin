import XCTest
import Foundation
@testable import ArchiveCore

final class PSTAdaptiveMemoryTests: XCTestCase {
    private actor Envelopes {
        var calls = 0
        let byteBound: Int
        init(byteBound: Int) { self.byteBound = byteBound }
        func next() -> BatchEnvelope {
            calls += 1
            return BatchEnvelope(maxMessages: calls == 1 ? 2 : 1, maxBytes: byteBound)
        }
    }

    private func fixture(at url: URL) throws {
        let writer = try PSTSpecWriter(url: url)
        for i in 0..<6 {
            let source = "Message-ID: <memory-\(i)@example.com>\r\nFrom: a@example.com\r\nTo: b@example.com\r\n"
                + "Subject: Memory \(i)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\n\r\n"
                + String(repeating: "word ", count: 800)
            let email = try MBOXParser.processRawMessage(source, senderEmail: "")
            try writer.appendMessage(email)
        }
        XCTAssertEqual(try writer.finalize(), 6)
    }

    func testPSTRechecksEnvelopeAfterEachBatchWithoutLosingMessages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pst-memory-\(UUID().uuidString).pst")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(at: url)
        let envelopes = Envelopes(byteBound: 1_048_576)
        var sizes: [Int] = []
        var ids = Set<String>()
        let result = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 500,
            envelopeProvider: { await envelopes.next() }) { batch in
                sizes.append(batch.count)
                for email in batch { ids.insert(email.headers["Message-ID"] ?? "") }
            }
        XCTAssertEqual(sizes, [2, 1, 1, 1, 1])
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(ids.count, 6)
        let calls = await envelopes.calls
        XCTAssertGreaterThan(calls, 1)
    }

    func testPSTByteLimitFlushesBeforeRetainingSiblingMessages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pst-bytes-\(UUID().uuidString).pst")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(at: url)
        var sizes: [Int] = []
        let result = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 500,
            envelopeProvider: { BatchEnvelope(maxMessages: 500, maxBytes: 6_000) }) { batch in
                sizes.append(batch.count)
            }
        XCTAssertEqual(sizes, Array(repeating: 1, count: 6))
        XCTAssertEqual(result.count, 6)
    }
}
