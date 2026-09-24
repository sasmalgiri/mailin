//
//  ActivationMeasurementTests.swift
//  maxmailinTests
//
//  The measurements MODULE_ACTIVATION_MATRIX.md is missing, and the one claim
//  S4 actually rests on.
//
//  Method note, because it decides what these numbers are worth. `phys_footprint`
//  is PROCESS-wide and was measured earlier in this project to vary ±15% across
//  identical runs — four separate memory hypotheses were falsified by
//  measurement during P3. So:
//
//   • **Per-page/per-capability cost is measured as COUNTS, not bytes.** Live
//     hosts and running jobs are exact and attributable. An RSS figure for
//     "AI Insights enabled" would be a process reading with a page switch
//     somewhere in it, which is not attribution.
//
//   • **The offset-parser claim is measured as a DELTA between two engines
//     over the same file in the same process.** Absolute RSS is noise; the
//     difference between streaming and offset on one fixture, where the only
//     variable is the engine, is signal. The claim under test is specifically
//     that peak footprint stops scaling with the largest message.
//
//  Numbers are printed as well as asserted, so the matrix can be filled in
//  from a run rather than from an estimate.
//

import XCTest
@testable import maxmailin

// MARK: - Per-page and per-capability activation cost

@MainActor
final class ActivationCostMeasurementTests: XCTestCase {

    private func registry() -> ModuleRegistry {
        ModuleRegistry(
            store: ModuleStateStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("measure-\(UUID().uuidString).json")),
            excludedByBuild: [],
            trapsOnMisuse: false)
    }

    /// The condition a Page-1-only install must satisfy: nothing optional is
    /// constructed and nothing optional is running. This is the exact,
    /// repeatable part of the resting-cost claim.
    func testMeasure_archiveOnlyRestingCost() throws {
        let modules = registry()
        let snapshot = modules.resourceSnapshot()

        print("""

        ── Resting cost: Page 1 only ──────────────────────────────
        enabled pages      : \(snapshot.enabled.map(\.rawValue).joined(separator: ", "))
        live feature hosts : \(snapshot.liveHosts.count) \(snapshot.liveHosts.map(\.rawValue))
        running jobs       : \(snapshot.jobsByModule.values.reduce(0, +))
        process footprint  : \(snapshot.footprintBytes / 1_048_576) MiB (process-wide; context, not attribution)
        archive-only clean : \(snapshot.isArchiveOnlyClean)
        ───────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(snapshot.enabled, [.archive])
        XCTAssertTrue(snapshot.liveHosts.isEmpty,
                      "no optional page may be constructed on a Page-1-only install")
        XCTAssertEqual(snapshot.jobsByModule.values.reduce(0, +), 0)
        XCTAssertTrue(snapshot.isArchiveOnlyClean)
    }

    /// Per-page cost, one page at a time, as counts. Enabling a page must not
    /// by itself construct its host or start its jobs — the host is built on
    /// first USE, which is the whole point of `host(for:)`.
    func testMeasure_perPageActivationCost() throws {
        print("\n── Per-page activation cost (counts) ──────────────────────")
        print("page                  | hosts | jobs | capabilities running")

        for page in AppModule.allCases where page.isOptional {
            let modules = registry()
            try? modules.enable(page)
            let snapshot = modules.resourceSnapshot()
            let running = modules.activeCapabilities(of: page)

            print(String(format: "%-21@ | %5d | %4d | %d of %d",
                         page.rawValue as NSString,
                         snapshot.liveHosts.count,
                         snapshot.jobsByModule.values.reduce(0, +),
                         running.count,
                         Capability.all(for: page).count))

            // Enabling a page must not construct anything by itself.
            XCTAssertTrue(snapshot.liveHosts.isEmpty,
                          "\(page.rawValue): enabling a page must not build its host — that happens on first use")
            XCTAssertEqual(snapshot.jobsByModule.values.reduce(0, +), 0,
                           "\(page.rawValue): enabling a page must not start jobs")

            // Every other optional page stays off.
            for other in AppModule.allCases where other.isOptional && other != page {
                XCTAssertFalse(modules.isEnabled(other),
                               "enabling \(page.rawValue) must not enable \(other.rawValue)")
                XCTAssertTrue(modules.activeCapabilities(of: other).isEmpty,
                              "\(other.rawValue) capabilities must stay off")
            }
        }
        print("───────────────────────────────────────────────────────────\n")
    }

    /// The full matrix as a run produces it, so the document can quote a
    /// measurement rather than an intention.
    func testMeasure_capabilityMatrixAsShipped() throws {
        let modules = registry()
        print("\n── Capability matrix, default state ───────────────────────")
        print("capability              | page  | maturity     | default | running")

        var defaultOnCount = 0
        for capability in Capability.allCases {
            let running = modules.isOn(capability)
            if capability.defaultsOn { defaultOnCount += 1 }
            print(String(format: "%-23@ | %-5@ | %-12@ | %-7@ | %@",
                         capability.rawValue as NSString,
                         String(capability.owner.rawValue.prefix(5)) as NSString,
                         capability.maturity.label as NSString,
                         (capability.defaultsOn ? "on" : "off") as NSString,
                         (running ? "yes" : "no") as NSString))
        }
        print("""
        ───────────────────────────────────────────────────────────
        \(Capability.allCases.count) capabilities · \(defaultOnCount) default-on · \
        \(Capability.allCases.count - defaultOnCount) default-off
        running on a fresh install: \(Capability.allCases.filter { modules.isOn($0) }.count)
        ───────────────────────────────────────────────────────────

        """)

        // On a fresh install only Archive capabilities can run, and only the
        // stable ones.
        for capability in Capability.allCases where modules.isOn(capability) {
            XCTAssertEqual(capability.owner, .archive,
                           "\(capability.rawValue) runs on a fresh install but is not an Archive capability")
            XCTAssertEqual(capability.maturity, .stable,
                           "\(capability.rawValue) is unproven and must not run on a fresh install")
        }
    }
}

// MARK: - The S4 claim

final class OffsetParserMemoryMeasurementTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s4-measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// These fixtures are LARGE — a single test writes up to 110 MiB, and the
    /// suite writes several hundred megabytes in total. Leaving them behind
    /// filled the temp volume and made an unrelated pre-existing measurement
    /// test fail with `disk I/O error`, which looked like a store bug and was
    /// not. Unlike the store-backed tests elsewhere in this target, these are
    /// plain files this class owns with no handles outstanding once a test
    /// returns, so removing them is safe.
    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Writes a mailbox whose messages are `bodyMiB` each, streamed to disk so
    /// building the FIXTURE does not itself dominate the measurement.
    ///
    /// `lineLength` matters more than it looks. The first version of this
    /// helper wrote each body as ONE unbroken line, which is both unrealistic
    /// — real mail wraps, and base64 attachments wrap at 76 — and misleading:
    /// the scanner accumulates bytes until it finds a newline, so a 12 MiB
    /// single-line body forces 12 MiB of carry and the measurement showed the
    /// offset engine holding a whole message. That is a property of the LINE,
    /// not of the message, and `testMeasure_peakTracksLongestLineNotMessage`
    /// now measures it deliberately instead of by accident.
    private func writeMailbox(messages: Int, bodyMiB: Int, lineLength: Int = 76) throws -> URL {
        let url = directory.appendingPathComponent("large-\(bodyMiB)-\(lineLength).mbox")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // One MiB of body, reused, so the writer holds 1 MiB not `bodyMiB`.
        let chunk: Data = {
            if lineLength >= 1_048_576 {
                // Deliberately unwrapped: one long line.
                return Data(String(repeating: "y", count: 1_048_576).utf8)
            }
            var text = ""
            text.reserveCapacity(1_048_576 + 1_048_576 / lineLength + 8)
            while text.utf8.count < 1_048_576 {
                text += String(repeating: "y", count: lineLength)
                text += "\n"
            }
            return Data(text.utf8)
        }()
        for index in 0..<messages {
            let header = """
            From sender@example.com Tue Mar 14 09:41:00 2017
            From: sender@example.com
            To: recipient@example.com
            Subject: big-\(index)
            Date: Tue, 14 Mar 2017 09:41:00 +0000
            Message-ID: <big-\(index)@example.com>

            """
            try handle.write(contentsOf: Data(header.utf8))
            for _ in 0..<bodyMiB { try handle.write(contentsOf: chunk) }
            try handle.write(contentsOf: Data("\n\n".utf8))
        }
        return url
    }

    /// THE claim S4 rests on: peak footprint during import stops scaling with
    /// the size of the largest message.
    ///
    /// Measured as a delta in one process over one file, engine being the only
    /// variable. The streaming parser accumulates each message as a Swift
    /// String before handing it to the MIME parser, so its peak tracks message
    /// size; the offset engine reads a window and the headers.
    func testMeasure_peakFootprintDoesNotScaleWithMessageSize() async throws {
        // 3 × 12 MiB messages: over the streaming parser's per-message
        // accumulation cost, well under its 100 MB damaged-message ceiling, so
        // BOTH engines import all three and the comparison is like-for-like.
        let messages = 3
        let bodyMiB = 12
        let url = try writeMailbox(messages: messages, bodyMiB: bodyMiB)
        let fileBytes = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        // --- Streaming parser -------------------------------------------------
        var streamingCount = 0
        let streamingBaseline = currentFootprintBytes()
        var streamingPeak = streamingBaseline
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "me@example.com", batchSize: 1
        ) { batch in
            streamingCount += batch.count
            streamingPeak = max(streamingPeak, currentFootprintBytes())
        }
        let streamingDelta = Int64(streamingPeak) - Int64(streamingBaseline)

        // Let the allocator settle so the second measurement starts from a
        // comparable floor rather than inheriting the first engine's peak.
        try await Task.sleep(nanoseconds: 400_000_000)

        // --- Offset engine ----------------------------------------------------
        var offsetCount = 0
        var headerOnlyCount = 0
        let offsetBaseline = currentFootprintBytes()
        var offsetPeak = offsetBaseline
        var engine = OffsetImportEngine()
        // Force the header-only path for every message, which is what the
        // no-size-limit claim is about.
        engine.fullParseCeilingBytes = 4 * 1_048_576
        _ = try await engine.importMessages(
            fileURL: url, senderEmail: "me@example.com", batchSize: 1
        ) { batch in
            offsetCount += batch.count
            headerOnlyCount += batch.filter { !$0.bodyWasDecoded }.count
            offsetPeak = max(offsetPeak, currentFootprintBytes())
        }
        let offsetDelta = Int64(offsetPeak) - Int64(offsetBaseline)

        func mib(_ bytes: Int64) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }

        print("""

        ── S4: peak footprint vs message size ─────────────────────
        fixture              : \(messages) messages × \(bodyMiB) MiB body = \(mib(fileBytes))
        streaming parser     : \(streamingCount) messages, peak delta \(mib(streamingDelta))
        offset engine        : \(offsetCount) messages (\(headerOnlyCount) header-only), peak delta \(mib(offsetDelta))
        window + header cap  : \(mib(Int64(OffsetMBOXScanner().windowBytes + OffsetMBOXScanner().maxHeaderBytes)))
        ───────────────────────────────────────────────────────────

        """)

        // Both engines must see every message — otherwise the comparison is
        // between different amounts of work.
        XCTAssertEqual(streamingCount, messages, "the streaming parser must import all \(messages)")
        XCTAssertEqual(offsetCount, messages, "the offset engine must import all \(messages)")
        XCTAssertEqual(headerOnlyCount, messages,
                       "every message here is over the ceiling, so all should be header-only")

        // NOTE: this samples in `onBatch`, i.e. once per message, and that is
        // why its figure is optimistic —
        // `testMeasure_peakIsIndependentOfMessageSize` samples per window and
        // measures ~46 MiB on a 48 MiB fixture where this reports ~3 MiB. Kept
        // because the per-message view is still the honest answer to "what
        // does the engine hold while handing me a batch", but the bound below
        // is deliberately loose and the per-window test is the one to quote.
        XCTAssertLessThan(offsetDelta, Int64(bodyMiB) * 1_048_576,
                          "between batches the engine must not be holding a whole message body: \(mib(offsetDelta))")

        // The cross-engine comparison is PRINTED, not asserted, and the reason
        // is a lesson from running it: in isolation the streaming parser
        // measured 71.5 MiB against the offset engine's 3.0 MiB, but in the
        // full suite the streaming delta measured 0.0 MiB — by then the
        // process had already allocated enough that 71 MiB of churn fit inside
        // pages `phys_footprint` had already counted. A delta against a
        // baseline the rest of the suite controls is not a stable assertion.
        //
        // The absolute bound above IS stable (3.0 MiB isolated, 3.8 MiB in
        // suite, both far under one 12 MiB body) because it does not depend on
        // what the other engine or the other tests did first.
        if streamingDelta > 0 {
            print("   engine comparison  : offset held \(mib(offsetDelta)) vs streaming \(mib(streamingDelta))")
        } else {
            print("   engine comparison  : not usable this run — streaming delta measured 0 (process footprint already high)")
        }
    }

    /// The limit the first version of this measurement found by accident, now
    /// measured on purpose: the scanner's peak tracks the longest LINE, not
    /// the message, because it accumulates bytes until it finds a newline.
    ///
    /// This is the honest caveat on "no message size limit". A 40 MiB message
    /// of wrapped lines costs a window; a 12 MiB message that is one single
    /// line costs 12 MiB. Real mail wraps (RFC 5322 recommends 78 columns,
    /// base64 wraps at 76), so the wrapped case is the one that matters — but
    /// the unwrapped case is bounded rather than unbounded, and this records
    /// what the bound is.
    func testMeasure_peakTracksLongestLineNotMessage() async throws {
        let wrapped = try writeMailbox(messages: 2, bodyMiB: 12, lineLength: 76)
        let unwrapped = try writeMailbox(messages: 2, bodyMiB: 12, lineLength: 1_048_576)

        func peakDelta(_ url: URL) async throws -> Int64 {
            var engine = OffsetImportEngine()
            engine.fullParseCeilingBytes = 1_048_576
            let baseline = currentFootprintBytes()
            var peak = baseline
            _ = try await engine.importMessages(
                fileURL: url, senderEmail: "me@example.com", batchSize: 1
            ) { _ in peak = max(peak, currentFootprintBytes()) }
            return Int64(peak) - Int64(baseline)
        }

        let wrappedDelta = try await peakDelta(wrapped)
        try await Task.sleep(nanoseconds: 300_000_000)
        let unwrappedDelta = try await peakDelta(unwrapped)

        func mib(_ b: Int64) -> String { String(format: "%.1f MiB", Double(b) / 1_048_576) }
        print("""

        ── S4 caveat: peak tracks the longest LINE ────────────────
        12 MiB body, 76-col lines : peak delta \(mib(wrappedDelta))
        12 MiB body, one line     : peak delta \(mib(unwrappedDelta))
        maxLineBytes (the bound)  : \(mib(Int64(OffsetMBOXScanner().maxLineBytes)))
        ───────────────────────────────────────────────────────────

        """)

        XCTAssertLessThan(wrappedDelta, 12 * 1_048_576,
                          "wrapped mail must stay well under one body: \(mib(wrappedDelta))")
        // The unwrapped case is ALLOWED to be large — it just has to be
        // bounded by maxLineBytes rather than by the file.
        XCTAssertLessThan(unwrappedDelta, Int64(OffsetMBOXScanner().maxLineBytes) * 2,
                          "even an unwrapped body must stay within the documented line bound")
    }

    /// What peak footprint actually tracks, measured properly.
    ///
    /// This test replaces an earlier one that asserted peak was flat as bodies
    /// grew, and passed for the wrong reason: it sampled footprint inside
    /// `onBatch`, which fires once per MESSAGE, so on a three-message fixture
    /// it looked three times and never during the climb. Per-window sampling
    /// tells a different story, and the published "3.0 MiB" figure was an
    /// artifact of the under-sampling.
    ///
    /// Measured with per-window sampling (48 MiB fixtures):
    ///   2 messages × 24 MiB → 46.1 MiB peak
    ///  48 messages ×  1 MiB → 47.9 MiB peak
    ///   8 messages × 24 MiB (192 MiB file) → 109.4 MiB peak
    ///
    /// So: peak is **independent of message size** — 2×24 and 48×1 cost the
    /// same — which is the property that lets a single huge message import at
    /// all. It is **not** bounded by window + headers; it grows with FILE
    /// size, sub-linearly. Almost certainly the unified buffer cache, which
    /// `phys_footprint` charges to the process; those pages are evictable
    /// under pressure, but the Jetsam metric counts them, so the honest claim
    /// is the message-size one, not a fixed ceiling.
    func testMeasure_peakIsIndependentOfMessageSize() async throws {
        try TestPreconditions.requireFreeSpace(TestPreconditions.scaleFixtureBudget)

        /// Samples per WINDOW, via `onProgress`, not per message.
        func peakDelta(messages: Int, bodyMiB: Int) async throws -> Int64 {
            let url = try writeMailbox(messages: messages, bodyMiB: bodyMiB)
            defer { try? FileManager.default.removeItem(at: url) }
            try await Task.sleep(nanoseconds: 300_000_000)
            let baseline = currentFootprintBytes()
            var peak = baseline
            _ = try await OffsetMBOXScanner().scan(
                fileURL: url, collect: false,
                onProgress: { _ in peak = max(peak, currentFootprintBytes()) })
            return Int64(peak) - Int64(baseline)
        }

        // Same total bytes, message size differing 24-fold.
        let fewLarge = try await peakDelta(messages: 2, bodyMiB: 24)
        let manySmall = try await peakDelta(messages: 48, bodyMiB: 1)

        func mib(_ b: Int64) -> String { String(format: "%.1f MiB", Double(b) / 1_048_576) }
        print("""

        ── S4: peak vs message size (48 MiB both) ─────────────────
        2 messages × 24 MiB  : peak delta \(mib(fewLarge))
        48 messages × 1 MiB  : peak delta \(mib(manySmall))
        ───────────────────────────────────────────────────────────

        """)

        // The real claim: at equal file size, a 24× difference in message size
        // must not change peak materially. Tolerance is deliberately wide
        // because `phys_footprint` is process-wide and noisy; what would fail
        // here is peak tracking MESSAGE size, which is what the old streaming
        // parser did and what forced its 100 MB ceiling.
        let difference = abs(fewLarge - manySmall)
        XCTAssertLessThan(difference, 16 * 1_048_576, """
            peak should not depend on message size at equal file size: \
            \(mib(fewLarge)) for 2×24 MiB vs \(mib(manySmall)) for 48×1 MiB
            """)
    }

    /// Throughput, the one S4 claim that was still unmeasured. Memory was the
    /// question the design rested on; speed was never asserted anywhere, and
    /// this fills that in rather than leaving a blank.
    ///
    /// Reported as messages/second and MiB/second over ordinary mail (many
    /// small messages, which is the realistic shape), with BOTH engines on the
    /// same file. No assertion on the ratio: a single timing run on a shared
    /// machine is not a benchmark, and asserting one would be the same mistake
    /// as asserting the RSS delta. The numbers are printed so
    /// `SIZE_LIMITS_DESIGN.md` can quote a measurement.
    func testMeasure_throughputBothEngines() async throws {
        try TestPreconditions.requireFreeSpace(TestPreconditions.scaleFixtureBudget)

        // 2,000 small messages ≈ realistic mail, not the large-message case
        // the memory tests use.
        let url = directory.appendingPathComponent("throughput.mbox")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var text = ""
        for index in 0..<2_000 {
            text += """
            From sender@example.com Tue Mar 14 09:41:00 2017
            From: sender\(index % 25)@example.com
            To: recipient@example.com
            Subject: message \(index)
            Date: Tue, 14 Mar 2017 09:41:00 +0000
            Message-ID: <t-\(index)@example.com>

            This is the body of message \(index). It has a few lines of text so the
            parse is not trivial, and a reference to invoice \(index % 97).

            """
            if text.utf8.count > 262_144 {
                try handle.write(contentsOf: Data(text.utf8))
                text = ""
            }
        }
        if !text.isEmpty { try handle.write(contentsOf: Data(text.utf8)) }
        try handle.close()

        let fileBytes = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        func seconds(_ body: () async throws -> Int) async throws -> (count: Int, elapsed: Double) {
            let clock = ContinuousClock()
            let start = clock.now
            let count = try await body()
            let components = start.duration(to: clock.now).components
            return (count, Double(components.seconds)
                    + Double(components.attoseconds) / 1e18)
        }

        let streaming = try await seconds {
            var n = 0
            _ = try await MBOXParser.parseStreamingCallback(
                fileURL: url, senderEmail: "me@example.com", batchSize: 200
            ) { batch in n += batch.count }
            return n
        }

        let offset = try await seconds {
            var n = 0
            _ = try await OffsetImportEngine().importMessages(
                fileURL: url, senderEmail: "me@example.com", batchSize: 200
            ) { batch in n += batch.count }
            return n
        }

        func rate(_ r: (count: Int, elapsed: Double)) -> String {
            guard r.elapsed > 0 else { return "—" }
            let perSecond = Double(r.count) / r.elapsed
            let mibPerSecond = (Double(fileBytes) / 1_048_576) / r.elapsed
            return String(format: "%6.0f msg/s  %5.1f MiB/s  (%.2fs)",
                          perSecond, mibPerSecond, r.elapsed)
        }

        print("""

        ── S4: throughput on ordinary mail ────────────────────────
        fixture              : \(streaming.count) messages, \
        \(ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file))
        streaming parser     : \(rate(streaming))
        offset engine        : \(rate(offset))
        ───────────────────────────────────────────────────────────

        """)

        // The only thing asserted is correctness: both engines must see every
        // message. Timing is reported, not gated.
        XCTAssertEqual(streaming.count, 2_000, "the streaming parser must read every message")
        XCTAssertEqual(offset.count, 2_000, "the offset engine must read every message")
    }

    /// And the behavioural difference that matters to a user, measured rather
    /// than argued: a message over the streaming parser's ceiling is DROPPED
    /// by it and ARCHIVED by the offset engine.
    func testMeasure_oversizedMessageOutcomeByEngine() async throws {
        // Comfortably past MBOXParser.maxMessageBytes (100 MB).
        let url = try writeMailbox(messages: 1, bodyMiB: 110)

        var streamingImported = 0
        let streamingReport = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "me@example.com", batchSize: 1
        ) { batch in
            streamingImported += batch.count
        }

        var offsetImported = 0
        let offsetReport = try await OffsetImportEngine().importMessages(
            fileURL: url, senderEmail: "me@example.com", batchSize: 1
        ) { batch in
            offsetImported += batch.count
        }

        print("""

        ── S4: a 110 MiB message, by engine ───────────────────────
        streaming parser     : imported \(streamingImported), damaged \(streamingReport.failed) \
        \(streamingReport.errorCategories)
        offset engine        : imported \(offsetImported), damaged \(offsetReport.failed)
        ───────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(streamingImported, 0,
                       "the streaming parser drops a message over its 100 MB ceiling")
        XCTAssertEqual(streamingReport.errorCategories["oversized_message"], 1,
                       "and reports it as oversized rather than losing it silently")
        XCTAssertEqual(offsetImported, 1,
                       "the offset engine archives it — the reason S4 exists")
        XCTAssertEqual(offsetReport.failed, 0)
    }
}
