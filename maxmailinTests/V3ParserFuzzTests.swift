@testable import ArchiveCore
//
//  V3ParserFuzzTests.swift
//  maxmailinTests
//
//  §3-P3 (property-based part): damaged and hostile files must give a named
//  error or a partial result — never a crash, never a hang. A deterministic
//  generator mutates valid seeds and adds the known attack shapes from
//  recent mail-parser CVEs (deeply nested multiparts, header and line
//  floods, broken base64 / quoted-printable, boundary tricks, recursive
//  message/rfc822, truncation, NUL bytes, bare CR, binary noise behind a
//  valid signature), then feeds every format the parser factory routes and
//  the MIME parser directly. A crash fails the run; a hang fails the test.
//
//  MAILIN_FUZZ_ITERATIONS (default 120 per format) sets the depth;
//  MAILIN_FUZZ_SEED reproduces a failing run.
//

import Foundation
import XCTest
@testable import maxmailin

/// SplitMix64 — deterministic, so a failure reproduces from its seed.
struct FuzzRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(max(1, range.count))) }
    mutating func bool() -> Bool { next() & 1 == 1 }
}

enum FuzzCorpus {
    static let seedMessage = """
    From sender@example.com Mon Jan  1 00:00:00 2024
    Message-ID: <seed@test>
    From: Sender <sender@example.com>
    To: dest@example.com
    Subject: =?UTF-8?B?U2VlZCBtZXNzYWdl?=
    Date: Mon, 01 Jan 2024 00:00:00 +0000
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="b1"

    --b1
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Hello =C3=A9 world=
     continued
    --b1
    Content-Type: application/octet-stream; name="a.bin"
    Content-Transfer-Encoding: base64
    Content-Disposition: attachment; filename="a.bin"

    AAECAwQFBgcICQ==
    --b1--

    """

    /// Attack shapes from known parser vulnerabilities.
    static func attacks(_ rng: inout FuzzRNG) -> [Data] {
        var out: [Data] = []
        // Deeply nested multiparts.
        var nested = "From x Mon Jan  1 00:00:00 2024\nSubject: deep\nContent-Type: multipart/mixed; boundary=\"d0\"\n\n"
        for d in 0..<600 { nested += "--d\(d)\nContent-Type: multipart/mixed; boundary=\"d\(d + 1)\"\n\n" }
        out.append(Data(nested.utf8))
        // Recursive message/rfc822.
        var rfc = ""
        for _ in 0..<400 { rfc += "Content-Type: message/rfc822\n\n" }
        out.append(Data(("From x Mon Jan  1 00:00:00 2024\nSubject: r\n" + rfc + "end\n").utf8))
        // Header flood and one giant header line.
        out.append(Data(("From x Mon Jan  1 00:00:00 2024\n" + (0..<20_000).map { "X-H\($0): v\n" }.joined() + "\nbody\n").utf8))
        out.append(Data(("From x Mon Jan  1 00:00:00 2024\nSubject: " + String(repeating: "A", count: 4_000_000) + "\n\nb\n").utf8))
        // Folded header that never ends.
        out.append(Data(("From x Mon Jan  1 00:00:00 2024\nSubject: a\n" + String(repeating: " folded\n", count: 200_000)).utf8))
        // Broken encodings.
        out.append(Data(seedMessage.replacingOccurrences(of: "AAECAwQFBgcICQ==", with: "!!!!====*&^%" + String(repeating: "=", count: 10_000)).utf8))
        out.append(Data(seedMessage.replacingOccurrences(of: "=C3=A9", with: String(repeating: "=Z", count: 50_000)).utf8))
        out.append(Data(seedMessage.replacingOccurrences(of: "=?UTF-8?B?U2VlZCBtZXNzYWdl?=", with: String(repeating: "=?x-unknown?Q?", count: 20_000)).utf8))
        // Boundary tricks: empty, huge, boundary inside boundary, never closed.
        out.append(Data(seedMessage.replacingOccurrences(of: "boundary=\"b1\"", with: "boundary=\"\"").utf8))
        out.append(Data(seedMessage.replacingOccurrences(of: "boundary=\"b1\"", with: "boundary=\"" + String(repeating: "b", count: 100_000) + "\"").utf8))
        out.append(Data(seedMessage.replacingOccurrences(of: "--b1--", with: "--b1\n--b1\n--b1").utf8))
        // Line endings and bytes.
        out.append(Data(seedMessage.replacingOccurrences(of: "\n", with: "\r").utf8))
        out.append(Data(seedMessage.replacingOccurrences(of: "\n", with: "\r\r\n").utf8))
        var nul = Data(seedMessage.utf8); nul.insert(contentsOf: [UInt8](repeating: 0, count: 4_096), at: nul.count / 2)
        out.append(nul)
        out.append(Data())
        out.append(Data((0..<200_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }))
        return out
    }

    /// Format signatures, so noise reaches each binary parser past its sniff.
    static let signatures: [String: [UInt8]] = [
        "pst": [0x21, 0x42, 0x44, 0x4E],                                   // "!BDN"
        "msg": [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1],           // OLE2
        "nsf": [0x1A, 0x00],
        "zip": [0x50, 0x4B, 0x03, 0x04],
        "emlx": Array("1234      \n".utf8),
    ]

    static func mutate(_ seed: Data, _ rng: inout FuzzRNG) -> Data {
        var d = seed
        guard !d.isEmpty else { return Data([UInt8(truncatingIfNeeded: rng.next())]) }
        for _ in 0..<rng.int(1..<8) {
            switch rng.int(0..<6) {
            case 0: d[rng.int(0..<d.count)] = UInt8(truncatingIfNeeded: rng.next())                       // byte flip
            case 1: d = d.prefix(rng.int(0..<d.count))                                                     // truncate
            case 2: let a = rng.int(0..<d.count); let b = min(d.count, a + rng.int(1..<512))
                    d.insert(contentsOf: d[a..<b], at: rng.int(0..<d.count))                               // duplicate a chunk
            case 3: d.insert(contentsOf: [UInt8](repeating: 0, count: rng.int(1..<64)), at: rng.int(0..<d.count))  // NULs
            case 4: d.insert(contentsOf: (0..<rng.int(1..<256)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: rng.int(0..<d.count))
            default: let a = rng.int(0..<d.count); d.removeSubrange(a..<min(d.count, a + rng.int(1..<256))) // delete
            }
            if d.isEmpty { break }
        }
        return d
    }
}

final class V3ParserFuzzTests: XCTestCase {

    private var iterations: Int { Int(ProcessInfo.processInfo.environment["MAILIN_FUZZ_ITERATIONS"] ?? "") ?? 120 }
    private var seed: UInt64 { UInt64(ProcessInfo.processInfo.environment["MAILIN_FUZZ_SEED"] ?? "") ?? 0x6D61_696C_696E_3330 }

    /// Per-file deadline: a parser that has not returned by then is a hang.
    private static let deadline: Duration = .seconds(20)

    private enum Outcome { case parsed(Int), threw, hung }

    /// Parses `data` as a file with `ext` through the factory, with a deadline.
    private func parse(_ data: Data, ext: String, in dir: URL) async -> Outcome {
        let url = dir.appendingPathComponent("fuzz-\(UUID().uuidString).\(ext)")
        do { try data.write(to: url) } catch { return .threw }
        defer { try? FileManager.default.removeItem(at: url) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            let gate = OnceGate()
            let work = Task.detached(priority: .userInitiated) {
                var count = 0
                do {
                    _ = try await ParserFactory.parseStreamingCallback(
                        fileURL: url, senderEmail: "", batchSize: 50,
                        retainAttachmentBytes: false, materializeAttachments: false
                    ) { batch in count += batch.count }
                    if gate.claim() { cont.resume(returning: .parsed(count)) }
                } catch {
                    if gate.claim() { cont.resume(returning: .threw) }
                }
            }
            Task.detached {
                try? await Task.sleep(for: Self.deadline)
                if gate.claim() { work.cancel(); cont.resume(returning: .hung) }
            }
        }
    }

    func testEveryFormatSurvivesMutatedAndHostileFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var rng = FuzzRNG(seed: seed)
        let seedData = Data(FuzzCorpus.seedMessage.utf8)
        let attacks = FuzzCorpus.attacks(&rng)
        var hangs: [String] = []
        var tally: [String: (parsed: Int, threw: Int)] = [:]

        for ext in ["mbox", "eml", "emlx", "msg", "pst", "nsf", "zip"] {
            var inputs = attacks
            for _ in 0..<iterations {
                var base = seedData
                if let sig = FuzzCorpus.signatures[ext] { base = Data(sig) + base }
                inputs.append(FuzzCorpus.mutate(base, &rng))
            }
            for (n, input) in inputs.enumerated() {
                switch await parse(input, ext: ext, in: dir) {
                case .parsed: tally[ext, default: (0, 0)].parsed += 1
                case .threw: tally[ext, default: (0, 0)].threw += 1
                case .hung: hangs.append("\(ext) input #\(n) (\(input.count) bytes, seed \(seed))")
                }
            }
        }
        for (ext, t) in tally.sorted(by: { $0.key < $1.key }) {
            print("FUZZ \(ext): \(t.parsed) parsed, \(t.threw) named errors, seed \(seed)")
        }
        XCTAssertTrue(hangs.isEmpty, "parsers that did not return within \(Self.deadline):\n" + hangs.joined(separator: "\n"))
    }

    /// The MIME parser on its own (it is also reached from every format).
    func testMIMEParserSurvivesHostileBodies() {
        var rng = FuzzRNG(seed: seed ^ 0xA5A5)
        let inputs = FuzzCorpus.attacks(&rng).map { String(decoding: $0, as: UTF8.self) }
            + (0..<iterations).map { _ in String(decoding: FuzzCorpus.mutate(Data(FuzzCorpus.seedMessage.utf8), &rng), as: UTF8.self) }
        let started = Date()
        for input in inputs {
            let parsed = MIMEParser.parseEmail(rawEmail: input)
            XCTAssertLessThanOrEqual(parsed.parts.count, 100_000, "part count stays bounded")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 300, "MIME parsing of the hostile set finishes")
    }
}

/// Lets exactly one of several racing tasks resume a continuation.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
