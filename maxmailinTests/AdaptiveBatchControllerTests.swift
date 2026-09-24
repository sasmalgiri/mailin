//
//  AdaptiveBatchControllerTests.swift
//  maxmailinTests
//
//  Plan task P3 / §5.1. Signals are injected, so the policy is tested
//  deterministically rather than by hoping the machine is under pressure while
//  the suite runs.
//
//  The behaviours pinned here are the ones the measured failure demands: the
//  envelope bounds BYTES as well as count, it shrinks promptly on any bad
//  signal, it grows only on a sustained healthy trend, it pauses with an
//  actionable reason at hard limits, and one oversized message is spooled
//  rather than allowed to break the bound.
//

import Testing
import Foundation
@testable import maxmailin

private let mib = 1_048_576

private func healthy(footprint: UInt64 = 200 * 1_048_576) -> PressureSample {
    PressureSample(
        footprintBytes: footprint,
        memoryBudgetBytes: UInt64(2 * 1024) * UInt64(mib),
        memoryPressure: .nominal,
        freeDiskBytes: UInt64(200 * 1024) * UInt64(mib),
        diskReserveBytes: UInt64(5 * 1024) * UInt64(mib),
        thermalState: .nominal,
        lastCommitSeconds: 0.1,
        indexBacklog: false
    )
}

private let cheapBatch = BatchOutcome(messages: 50, bytes: 4 * mib, commitSeconds: 0.1)

@Suite("Adaptive batch controller (P3)")
struct AdaptiveBatchControllerTests {

    // MARK: Start envelope

    @Test("The start envelope scales with machine memory and stays bounded")
    func startEnvelopeScales() {
        let small = BatchEnvelope.starting(forPhysicalMemory: UInt64(8 * 1024) * UInt64(mib))
        let large = BatchEnvelope.starting(forPhysicalMemory: UInt64(128 * 1024) * UInt64(mib))

        #expect(small.maxBytes >= mib)
        #expect(small.maxBytes <= 64 * mib)
        // The byte bound is derived backwards from a resident-memory target
        // through the measured expansion factor, so it must be far smaller
        // than the target itself.
        let target = BatchEnvelope.targetResidentBytes(
            forPhysicalMemory: UInt64(8 * 1024) * UInt64(mib))
        #expect(Double(small.maxBytes) <= Double(target) / 4,
                "a source-byte bound must allow for in-memory expansion")
        #expect(large.maxBytes >= small.maxBytes, "more RAM must not mean a smaller envelope")
        #expect(large.maxBytes <= 64 * mib, "the ceiling holds even on a huge machine")
        #expect(small.maxMessages >= 32)
        #expect(large.maxMessages <= 256)
    }

    @Test("Both dimensions are bounded, which the old count-only policy was not")
    func envelopeBoundsBytesAndCount() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        let decision = await controller.next(after: nil, sample: healthy())
        let envelope = decision.envelope

        #expect(envelope?.maxMessages == 128)
        #expect(envelope?.maxBytes == 16 * mib)
    }

    // MARK: Growth

    @Test("Growth needs a sustained healthy trend, not one good batch")
    func growthRequiresSustainedHealth() async {
        let start = BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib)
        let controller = AdaptiveBatchController(start: start)

        let first = await controller.next(after: cheapBatch, sample: healthy())
        #expect(first.envelope == start, "one healthy batch is noise, not a trend")

        let second = await controller.next(after: cheapBatch, sample: healthy())
        #expect((second.envelope?.maxBytes ?? 0) > start.maxBytes)
        #expect((second.envelope?.maxMessages ?? 0) > start.maxMessages)
    }

    @Test("Growth stops at the ceiling")
    func growthIsCapped() async {
        let start = BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib)
        let controller = AdaptiveBatchController(start: start)
        for _ in 0..<40 {
            _ = await controller.next(after: cheapBatch, sample: healthy())
        }
        let envelope = await controller.envelope
        #expect(envelope.maxBytes <= max(start.maxBytes * 8, 256 * mib))
        #expect(envelope.maxMessages <= max(start.maxMessages * 8, 512))
    }

    // MARK: Shrink

    @Test("Memory-pressure warning shrinks the envelope immediately")
    func warningShrinks() async {
        let start = BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib)
        let controller = AdaptiveBatchController(start: start)

        var sample = healthy()
        sample.memoryPressure = .warning
        let decision = await controller.next(after: cheapBatch, sample: sample)

        #expect(decision.envelope?.maxBytes == 8 * mib)
        #expect(decision.envelope?.maxMessages == 64)
    }

    @Test("Reaching the import memory budget shrinks even with no OS pressure")
    func budgetShrinks() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        var sample = healthy()
        sample.footprintBytes = sample.memoryBudgetBytes + 1
        let decision = await controller.next(after: cheapBatch, sample: sample)
        #expect((decision.envelope?.maxBytes ?? .max) < 16 * mib)
    }

    @Test("Slow store commits shrink the envelope")
    func slowCommitsShrink() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        let slow = BatchOutcome(messages: 128, bytes: 16 * mib, commitSeconds: 3.0)
        let decision = await controller.next(after: slow, sample: healthy())
        #expect((decision.envelope?.maxBytes ?? .max) < 16 * mib)
    }

    @Test("An index backlog and thermal throttling both shrink")
    func backlogAndThermalShrink() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))

        var backlog = healthy()
        backlog.indexBacklog = true
        #expect((await controller.next(after: cheapBatch, sample: backlog).envelope?.maxBytes ?? .max) < 16 * mib)

        var hot = healthy()
        hot.thermalState = .serious
        let after = await controller.next(after: cheapBatch, sample: hot).envelope
        #expect((after?.maxBytes ?? .max) < 8 * mib)
    }

    @Test("Shrinking stops at the floor rather than reaching zero")
    func shrinkHasAFloor() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        var sample = healthy()
        sample.memoryPressure = .warning
        for _ in 0..<30 {
            _ = await controller.next(after: cheapBatch, sample: sample)
        }
        let envelope = await controller.envelope
        #expect(envelope.maxMessages >= 8, "a batch of zero messages would never finish")
        #expect(envelope.maxBytes >= mib)
    }

    // MARK: Hard stops

    @Test("Critical memory pressure pauses with an actionable reason")
    func criticalMemoryPauses() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        var sample = healthy()
        sample.memoryPressure = .critical

        let decision = await controller.next(after: cheapBatch, sample: sample)
        #expect(decision.envelope == nil)
        let reason = decision.pauseReason ?? ""
        #expect(reason.contains("memory"))
        #expect(reason.contains("resumes"), "a pause must tell the user what happens next")
    }

    @Test("Low disk pauses and names the space the archive needs")
    func lowDiskPauses() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        var sample = healthy()
        sample.freeDiskBytes = sample.diskReserveBytes - 1

        let reason = await controller.next(after: cheapBatch, sample: sample).pauseReason ?? ""
        #expect(reason.contains("disk"))
        #expect(reason.contains("free"))
    }

    @Test("A pause clears on its own once the condition passes")
    func pauseResumes() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        var critical = healthy()
        critical.memoryPressure = .critical
        #expect(await controller.next(after: cheapBatch, sample: critical).pauseReason != nil)

        let resumed = await controller.next(after: cheapBatch, sample: healthy())
        #expect(resumed.envelope != nil, "import must resume without user action")

        let trace = await controller.trace
        #expect(trace.contains { $0.kind == .paused })
        #expect(trace.contains { $0.kind == .resumed })
    }

    // MARK: Oversized items

    @Test("A message larger than the envelope is spooled, never inlined")
    func oversizedItemIsSpooled() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))

        #expect(await controller.plan(forItemOfSize: 8 * mib) == .inline)
        #expect(await controller.plan(forItemOfSize: 40 * mib) == .spoolAlone(bytes: 40 * mib))

        // The envelope must be unchanged by encountering a huge item.
        let envelope = await controller.envelope
        #expect(envelope.maxBytes == 16 * mib, "the envelope is never grown to fit one item")
    }

    // MARK: Diagnostics

    @Test("Every transition is recorded with a cause, and the trace stays bounded")
    func traceIsUsefulAndBounded() async {
        let controller = AdaptiveBatchController(
            start: BatchEnvelope(maxMessages: 128, maxBytes: 16 * mib))
        var warning = healthy()
        warning.memoryPressure = .warning

        for i in 0..<700 {
            _ = await controller.next(after: cheapBatch,
                                      sample: i % 2 == 0 ? warning : healthy())
        }
        let trace = await controller.trace
        #expect(trace.count <= 512, "diagnostics must not leak on a long import")
        #expect(trace.allSatisfy { !$0.cause.isEmpty }, "every change needs a recorded cause")
        #expect(trace.contains { $0.kind == .shrank })
    }
}


@Suite("Envelope-driven batching in the parser (P3.1)")
struct EnvelopeBatchingTests {

    /// Writes an mbox of `count` messages, each padded to roughly `bodyKB`.
    private func writeMBOX(count: Int, bodyKB: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("envelope-\(UUID().uuidString).mbox")
        var text = ""
        let filler = String(repeating: "abcdefgh", count: bodyKB * 128)   // ~bodyKB KiB
        for i in 0..<count {
            text += "From sender@example.com Tue Mar 14 09:41:00 2017\n"
            text += "From: sender@example.com\n"
            text += "To: recipient@example.com\n"
            text += "Subject: Envelope probe \(i)\n"
            text += "Date: Tue, 14 Mar 2017 09:41:00 +0000\n"
            text += "Message-ID: <envelope-\(i)@example.com>\n\n"
            text += filler + "\n\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("A small byte bound splits batches even when the message count allows more")
    func byteBoundSplitsBatches() async throws {
        // 20 messages of ~64 KiB. A 256 KiB byte bound must force several
        // batches even though the message bound (500) would take them all.
        let url = try writeMBOX(count: 20, bodyKB: 64)
        defer { try? FileManager.default.removeItem(at: url) }

        let envelope = BatchEnvelope(maxMessages: 500, maxBytes: 256 * 1024)
        var batchSizes: [Int] = []
        let report = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 500,
            envelopeProvider: { envelope }
        ) { batch in
            batchSizes.append(batch.count)
        }

        #expect(report.successfullyParsed == 20)
        #expect(batchSizes.count > 1, "the byte bound must split what the count bound would not")
        #expect(batchSizes.reduce(0, +) == 20, "every message is delivered exactly once")
    }

    @Test("Without a provider the fixed batch size still applies")
    func fixedBatchingUnchanged() async throws {
        let url = try writeMBOX(count: 10, bodyKB: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        var batchSizes: [Int] = []
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 4
        ) { batch in
            batchSizes.append(batch.count)
        }
        #expect(batchSizes == [4, 4, 2], "manual override keeps the old count-only behaviour")
    }

    @Test("A shrinking envelope takes effect mid-file, not at the next file")
    func envelopeShrinksMidFile() async throws {
        let url = try writeMBOX(count: 24, bodyKB: 8)
        defer { try? FileManager.default.removeItem(at: url) }

        // First ask allows 8 messages; every later ask allows 2. If the parser
        // only read the envelope once, all batches would be 8.
        let asks = Counter()
        var batchSizes: [Int] = []
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 500,
            envelopeProvider: {
                let n = await asks.next()
                return BatchEnvelope(maxMessages: n == 0 ? 8 : 2, maxBytes: Int.max)
            }
        ) { batch in
            batchSizes.append(batch.count)
        }

        #expect(batchSizes.first == 8)
        #expect(batchSizes.dropFirst().contains(2), "the envelope is re-read after every flush")
        #expect(batchSizes.reduce(0, +) == 24)
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { defer { value += 1 }; return value }
}
