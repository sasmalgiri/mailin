//
//  LargeSingleMessageTests.swift
//  ArchiveCoreTests
//
//  CLOSE-01 (v4 plan §8.1): an Outlook .msg above 2,000,000,000 bytes and an
//  Apple Mail .emlx above 500,000,000 bytes were refused because they were
//  read whole into memory. These rows hold the replacement to its promise:
//  fixtures on each side of both former cutoffs (sparse files — the structure
//  and markers are written, the bulk is a hole), bounded resident memory
//  (peak footprint far below the file), byte-exact body and attachment hashes
//  streamed, cancellation mid-read, and damaged compound files (loops,
//  out-of-range sectors, short chains, a looping DIFAT, a looping directory)
//  refused cleanly with their reason.
//

import CryptoKit
import XCTest
@preconcurrency @testable import ArchiveCore

final class LargeSingleMessageTests: XCTestCase {

    private var root: URL!
    private var wasChunking = false

    override func setUp() async throws {
        wasChunking = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("close01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        SearchChunkPolicy.isEnabled = wasChunking
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture writers

    /// A compound file (MS-CFB version 3, 512-byte sectors) written sparsely:
    /// a `.sparse` stream is allocated and only its markers are written.
    struct CFB {
        enum Content {
            case none
            case data(Data)
            case sparse(length: Int64, markers: [(Int64, Data)])

            var length: Int64 {
                switch self {
                case .none: return 0
                case .data(let d): return Int64(d.count)
                case .sparse(let length, _): return length
                }
            }
        }

        struct Entry {
            var name: String
            var type: UInt8          // 1 storage, 2 stream, 5 root
            var child: Int32 = -1
            var left: Int32 = -1
            var right: Int32 = -1
            var content: Content = .none
        }

        struct Layout {
            var startSector: [Int: Int] = [:]   // regular streams, by entry index
            var fatStart = 0
            var fatCount = 0
            var directoryStart = 0
            var difatStart = 0
            var difatCount = 0
            var totalSectors = 0
            var fileLength: Int64 = 0

            func fatEntryOffset(_ sector: Int) -> UInt64 {
                UInt64((fatStart + sector / 128 + 1) * 512 + (sector % 128) * 4)
            }
            func directoryEntryOffset(_ index: Int) -> UInt64 {
                UInt64((directoryStart + index / 4 + 1) * 512 + (index % 4) * 128)
            }
        }

        static let sectorSize = 512
        static let miniCutoff = 4096

        @discardableResult
        static func write(_ input: [Entry], to url: URL) throws -> Layout {
            var entries = input
            let ss = sectorSize
            var layout = Layout()

            // Mini stream: streams under the cutoff, 64-byte mini sectors.
            var mini = Data()
            var miniFat: [Int32] = []
            var miniStart: [Int: Int] = [:]
            for (i, e) in entries.enumerated() where e.type == 2 {
                if case .data(let d) = e.content, d.count < miniCutoff, !d.isEmpty {
                    let first = miniFat.count
                    let count = (d.count + 63) / 64
                    for k in 0..<count { miniFat.append(k == count - 1 ? -2 : Int32(first + k + 1)) }
                    miniStart[i] = first
                    var padded = d
                    padded.append(Data(count: count * 64 - d.count))
                    mini.append(padded)
                }
            }

            // Regular sectors: big streams, the mini container, the mini FAT, the directory.
            var regions: [(start: Int, count: Int)] = []
            var next = 0
            func allocate(_ bytes: Int64) -> Int {
                let count = Int((bytes + Int64(ss) - 1) / Int64(ss))
                let start = next
                if count > 0 { regions.append((start, count)); next += count }
                return count > 0 ? start : -2
            }
            for (i, e) in entries.enumerated() where e.type == 2 && miniStart[i] == nil && e.content.length > 0 {
                layout.startSector[i] = allocate(e.content.length)
            }
            let miniContainer = allocate(Int64(mini.count))
            let miniFatStart = allocate(Int64(miniFat.count * 4))
            while entries.count % 4 != 0 { entries.append(Entry(name: "", type: 0)) }
            layout.directoryStart = allocate(Int64(entries.count * 128))
            let dataSectors = next

            // FAT and DIFAT sectors: a fixed point.
            var fatCount = 1, difatCount = 0
            while true {
                let total = dataSectors + fatCount + difatCount
                let needFat = (total + 127) / 128
                let needDifat = needFat > 109 ? (needFat - 109 + 126) / 127 : 0
                if needFat == fatCount && needDifat == difatCount { break }
                fatCount = needFat; difatCount = needDifat
            }
            layout.fatStart = dataSectors
            layout.fatCount = fatCount
            layout.difatStart = dataSectors + fatCount
            layout.difatCount = difatCount
            layout.totalSectors = dataSectors + fatCount + difatCount
            layout.fileLength = Int64(layout.totalSectors + 1) * Int64(ss)

            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            func put(_ data: Data, at offset: Int64) throws {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            }
            func sectorOffset(_ s: Int) -> Int64 { Int64(s + 1) * Int64(ss) }

            // Header.
            var header = Data(count: 512)
            header.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
            header.le16(0x3E, at: 24); header.le16(3, at: 26); header.le16(0xFFFE, at: 28)
            header.le16(9, at: 30); header.le16(6, at: 32)
            header.le32(UInt32(fatCount), at: 44)
            header.le32(UInt32(layout.directoryStart), at: 48)
            header.le32(UInt32(miniCutoff), at: 56)
            header.le32(UInt32(bitPattern: Int32(miniFat.isEmpty ? -2 : miniFatStart)), at: 60)
            header.le32(UInt32((miniFat.count * 4 + ss - 1) / ss), at: 64)
            header.le32(UInt32(bitPattern: Int32(difatCount > 0 ? layout.difatStart : -2)), at: 68)
            header.le32(UInt32(difatCount), at: 72)
            for i in 0..<109 {
                header.le32(UInt32(bitPattern: Int32(i < fatCount ? layout.fatStart + i : -1)), at: 76 + i * 4)
            }
            try put(header, at: 0)

            // Stream contents.
            for (i, e) in entries.enumerated() {
                guard let start = layout.startSector[i] else { continue }
                switch e.content {
                case .data(let d): try put(d, at: sectorOffset(start))
                case .sparse(_, let markers):
                    for (offset, bytes) in markers { try put(bytes, at: sectorOffset(start) + offset) }
                case .none: break
                }
            }
            if !mini.isEmpty { try put(mini, at: sectorOffset(miniContainer)) }
            if !miniFat.isEmpty {
                var d = Data(); for v in miniFat { d.le32append(UInt32(bitPattern: v)) }
                try put(d, at: sectorOffset(miniFatStart))
            }

            // Directory.
            var dir = Data()
            for (i, e) in entries.enumerated() {
                var rec = Data(count: 128)
                if e.type != 0 {
                    let name = Data(e.name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) + Data([0, 0])
                    rec.replaceSubrange(0..<name.count, with: name)
                    rec.le16(UInt16(name.count), at: 64)
                }
                rec[66] = e.type
                rec[67] = 1
                rec.le32(UInt32(bitPattern: e.type == 0 ? -1 : e.left), at: 68)
                rec.le32(UInt32(bitPattern: e.type == 0 ? -1 : e.right), at: 72)
                rec.le32(UInt32(bitPattern: e.type == 0 ? -1 : e.child), at: 76)
                if e.type == 5 {
                    rec.le32(UInt32(bitPattern: Int32(mini.isEmpty ? -2 : miniContainer)), at: 116)
                    rec.le32(UInt32(mini.count), at: 120)
                } else if e.type == 2 {
                    let start = miniStart[i] ?? layout.startSector[i] ?? -2
                    rec.le32(UInt32(bitPattern: Int32(start)), at: 116)
                    rec.le32(UInt32(truncatingIfNeeded: e.content.length), at: 120)
                } else {
                    rec.le32(0, at: 116)
                }
                dir.append(rec)
            }
            try put(dir, at: sectorOffset(layout.directoryStart))

            // FAT, written a block at a time.
            func fatValue(_ s: Int) -> UInt32 {
                if s >= layout.fatStart && s < layout.fatStart + fatCount { return 0xFFFF_FFFD }
                if s >= layout.difatStart && s < layout.difatStart + difatCount { return 0xFFFF_FFFC }
                for r in regions where s >= r.start && s < r.start + r.count {
                    return s == r.start + r.count - 1 ? 0xFFFF_FFFE : UInt32(s + 1)
                }
                return 0xFFFF_FFFF
            }
            var block = Data()
            block.reserveCapacity(1 << 16)
            try handle.seek(toOffset: UInt64(sectorOffset(layout.fatStart)))
            for s in 0..<(fatCount * 128) {
                block.le32append(fatValue(s))
                if block.count >= 1 << 16 { try handle.write(contentsOf: block); block.removeAll(keepingCapacity: true) }
            }
            try handle.write(contentsOf: block)

            // DIFAT.
            if difatCount > 0 {
                var difat = Data()
                var fatIndex = 109
                for d in 0..<difatCount {
                    for _ in 0..<127 {
                        difat.le32append(UInt32(bitPattern: Int32(fatIndex < fatCount ? layout.fatStart + fatIndex : -1)))
                        fatIndex += 1
                    }
                    difat.le32append(UInt32(bitPattern: Int32(d == difatCount - 1 ? -2 : layout.difatStart + d + 1)))
                }
                try put(difat, at: sectorOffset(layout.difatStart))
            }
            try handle.truncate(atOffset: UInt64(layout.fileLength))
            return layout
        }

        static func utf16(_ s: String) -> Data {
            Data(s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        }
    }

    /// An Outlook message: subject, sender, Message-ID, a body, and one attachment.
    private static func msgEntries(subject: String, body: CFB.Content, attachmentName: String,
                                   attachment: CFB.Content, messageID: String) -> [CFB.Entry] {
        var attachProps = Data(count: 8)
        attachProps.le16append(0x0003); attachProps.le16append(0x3705)
        attachProps.le32append(0); attachProps.le32append(1); attachProps.le32append(0)
        return [
            CFB.Entry(name: "Root Entry", type: 5, child: 1),
            CFB.Entry(name: "__substg1.0_0037001F", type: 2, right: 2, content: .data(CFB.utf16(subject))),
            CFB.Entry(name: "__substg1.0_0C1F001F", type: 2, right: 3, content: .data(CFB.utf16("big@example.com"))),
            CFB.Entry(name: "__substg1.0_1035001F", type: 2, right: 4, content: .data(CFB.utf16(messageID))),
            CFB.Entry(name: "__substg1.0_1000001F", type: 2, right: 5, content: body),
            CFB.Entry(name: "__properties_version1.0", type: 2, right: 6, content: .data(Data(count: 32))),
            CFB.Entry(name: "__attach_version1.0_#00000000", type: 1, child: 7),
            CFB.Entry(name: "__substg1.0_3707001F", type: 2, right: 8, content: .data(CFB.utf16(attachmentName))),
            CFB.Entry(name: "__substg1.0_370E001F", type: 2, right: 9, content: .data(CFB.utf16("application/octet-stream"))),
            CFB.Entry(name: "__substg1.0_37010102", type: 2, right: 10, content: attachment),
            CFB.Entry(name: "__properties_version1.0", type: 2, content: .data(attachProps)),
        ]
    }

    private static let attachmentEntryIndex = 9

    /// Markers at the start, the middle and the end of a sparse run of `length` bytes.
    private static func markers(_ length: Int64) -> [(Int64, Data)] {
        [(0, Data("MARKERSTART0123456789".utf8)),
         (length / 2 + 7, Data("MARKERMIDDLE9876543210".utf8)),
         (length - 19, Data("MARKEREND0123456789".utf8))]
    }

    /// SHA-256 of a run of zeros with `markers` written into it, computed a slice at a time.
    private static func sparseDigest(length: Int64, markers: [(Int64, Data)]) -> String {
        var hasher = SHA256()
        let slice = 4 << 20
        let zeros = Data(count: slice)
        var offset: Int64 = 0
        while offset < length {
            let n = Int(min(Int64(slice), length - offset))
            var piece = n == slice ? zeros : Data(count: n)
            for (at, bytes) in markers where at < offset + Int64(n) && at + Int64(bytes.count) > offset {
                for (k, b) in bytes.enumerated() {
                    let p = at + Int64(k) - offset
                    if p >= 0 && p < Int64(n) { piece[Int(p)] = b }
                }
            }
            hasher.update(data: piece)
            offset += Int64(n)
        }
        return Self.hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Each read in its own pool: the helper must not be what a peak-memory row measures.
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 4 << 20) }), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    /// A sparse .emlx: headers, a text part, a binary attachment of `attachmentLength` bytes, Apple Mail's plist.
    private func writeSparseEMLX(_ url: URL, attachmentLength: Int64, flags: Int) throws -> (attachmentDigest: String, messageLength: Int64) {
        let head = """
        From: big@example.com\r
        To: you@example.com\r
        Subject: Large emlx\r
        Message-ID: <close01-emlx-\(attachmentLength)@example.com>\r
        Date: Fri, 17 Mar 2017 12:00:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="B"\r
        \r
        --B\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        The needle word zanzibar is in the body.\r
        \(String(repeating: "Ordinary words of a long text part, before the attachment.\r\n", count: 120))--B\r
        Content-Type: application/octet-stream; name="huge.bin"\r
        Content-Disposition: attachment; filename="huge.bin"\r
        Content-Transfer-Encoding: binary\r
        \r

        """
        let tail = "\r\n--B--\r\n"
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>flags</key>\n\t<integer>\(flags)</integer>\n</dict>\n</plist>\n"
        let headData = Data(head.utf8)
        let messageLength = Int64(headData.count) + attachmentLength + Int64(tail.utf8.count)
        let countLine = Data("\(messageLength)\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: countLine + headData)
        let base = Int64(countLine.count + headData.count)
        let marks = Self.markers(attachmentLength)
        for (offset, bytes) in marks {
            try handle.seek(toOffset: UInt64(base + offset))
            try handle.write(contentsOf: bytes)
        }
        try handle.seek(toOffset: UInt64(base + attachmentLength))
        try handle.write(contentsOf: Data(tail.utf8) + Data(plist.utf8))
        return (Self.sparseDigest(length: attachmentLength, markers: marks), messageLength)
    }

    private struct Env {
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        var archive: ArchiveDataService { ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)) }
    }

    private func makeEnv(_ name: String) -> Env {
        Env(store: SQLiteEmailStore(directory: root.appendingPathComponent("\(name)-store", isDirectory: true)),
            fts: FTSSearchIndex(shardsDirectory: root.appendingPathComponent("\(name)-fts", isDirectory: true)))
    }

    private func importFile(_ url: URL, into env: Env, ceiling: Int64?) async throws -> BulkImportCoordinator.RunSummary {
        let coordinator = await BulkImportCoordinator(store: env.store, fts: env.fts,
                                                      checkpoints: ImportCheckpointStore(store: env.store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        options.fullParseCeilingBytes = ceiling
        return try await coordinator.runImport(urls: [url], options: options)
    }

    /// Peak footprint sampler: `sample()` inside the work, `peakDelta` after.
    private final class Footprint {
        let baseline = currentFootprintBytes()
        private(set) var peak: UInt64 = 0
        init() { peak = baseline }
        func sample() { peak = max(peak, currentFootprintBytes()) }
        var peakDelta: Int64 { Int64(peak) - Int64(baseline) }
    }

    private static let mib: Int64 = 1 << 20

    // MARK: - .msg on each side of the former 2,000,000,000-byte cutoff

    func testCLOSE01_msgOnEachSideOfTheFormer2GBCutoff_streamsItsAttachmentByteExactInBoundedMemory() throws {
        for attachmentLength: Int64 in [1_980_000_000, 2_000_100_000] {
            let url = root.appendingPathComponent("large-\(attachmentLength).msg")
            let marks = Self.markers(attachmentLength)
            let layout = try CFB.write(Self.msgEntries(subject: "Large msg \(attachmentLength)", body: .data(CFB.utf16("A short body.")),
                                                       attachmentName: "huge.bin", attachment: .sparse(length: attachmentLength, markers: marks),
                                                       messageID: "<close01-\(attachmentLength)@example.com>"), to: url)
            let fileSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
            XCTAssertEqual(fileSize, layout.fileLength)
            if attachmentLength > 2_000_000_000 {
                XCTAssertGreaterThan(fileSize, 2_000_000_000, "above the former cutoff")
                XCTAssertGreaterThan(layout.difatCount, 0, "large enough to need DIFAT sectors beyond the header's 109")
            } else {
                XCTAssertLessThan(fileSize, 2_000_000_000, "below the former cutoff")
            }
            let expected = Self.sparseDigest(length: attachmentLength, markers: marks)

            let meter = Footprint()
            let ole = try OLE2Reader(fileURL: url)
            let properties = try ole.readMAPIProperties(storage: 0, propertiesHeader: 32, deferStreamsAbove: MSGStreamRenderer.inPlaceStreamBytes)
            XCTAssertEqual(MSGParser.messageHeaders(properties).subject, "Large msg \(attachmentLength)")
            let records = try ole.readAttachments(storage: 0, deferStreamsAbove: MSGStreamRenderer.inPlaceStreamBytes)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.metadata.filename, "huge.bin")
            XCTAssertEqual(records.first?.metadata.size, Int(attachmentLength), "the size from the directory, nothing read")
            XCTAssertNil(records.first?.metadata.base64)
            let entry = try XCTUnwrap(records.first?.deferredData)
            var hasher = SHA256()
            var slices = 0
            let delivered = try ole.streamEntry(entry) { slice in
                hasher.update(data: slice)
                slices += 1
                if slices % 64 == 0 { meter.sample() }
            }
            meter.sample()
            XCTAssertEqual(delivered, attachmentLength)
            XCTAssertEqual(Self.hex(hasher.finalize()), expected, "attachment of \(attachmentLength) bytes byte for byte")
            XCTAssertLessThan(meter.peakDelta, 96 * Self.mib, "peak footprint \(meter.peakDelta / Self.mib) MiB for a \(fileSize / Self.mib) MiB file")
            print("CLOSE-01 msg \(fileSize) bytes: attachment streamed, peak footprint delta \(meter.peakDelta / Self.mib) MiB")

            // The rendering for import: same bounded memory, every attachment byte base64-encoded.
            let renderMeter = Footprint()
            final class Counting: RenderSink {
                var bytes: Int64 = 0
                var tail = Data()
                func write(_ data: Data) throws { bytes += Int64(data.count); tail = Data((tail + data).suffix(64)) }
            }
            let counting = Counting()
            let sink = RenderedMessageSink { data in try counting.write(data); renderMeter.sample() }
            XCTAssertEqual(try MSGStreamRenderer.render(ole: ole, into: sink), 1)
            _ = try sink.finish()
            let base64Lines = (attachmentLength + 56) / 57
            XCTAssertGreaterThan(counting.bytes, (attachmentLength + 2) / 3 * 4 + base64Lines * 2, "the whole attachment rendered")
            XCTAssertTrue(String(decoding: counting.tail, as: UTF8.self).hasSuffix("--\r\n"), "closed by its boundary")
            XCTAssertLessThan(sink.peakBufferedBytes, 4 * Int(Self.mib), "output buffered one slice at a time")
            XCTAssertLessThan(renderMeter.peakDelta, 96 * Self.mib, "rendering peak \(renderMeter.peakDelta / Self.mib) MiB")
            print("CLOSE-01 msg \(fileSize) bytes: rendered \(counting.bytes) bytes, peak footprint delta \(renderMeter.peakDelta / Self.mib) MiB")
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - .emlx on each side of the former 500,000,000-byte cutoff

    func testCLOSE01_emlxOnEachSideOfTheFormer500MBCutoff_importsByRange_attachmentStreamsOutByteExact() async throws {
        for attachmentLength: Int64 in [499_000_000, 500_100_000] {
            let env = makeEnv("emlx-\(attachmentLength)")
            let folder = root.appendingPathComponent("Inbox.mbox/Messages", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(attachmentLength).emlx")
            let (expected, messageLength) = try writeSparseEMLX(url, attachmentLength: attachmentLength, flags: 0x11)
            let fileSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
            if attachmentLength > 500_000_000 { XCTAssertGreaterThan(fileSize, 500_000_000) } else { XCTAssertLessThan(fileSize, 500_000_000) }

            let meter = Footprint()
            var clock = Date()
            func lap(_ what: String) { print("CLOSE-01 emlx \(fileSize) bytes: \(what) in \(String(format: "%.1f", Date().timeIntervalSince(clock))) s"); clock = Date() }
            let summary = try await importFile(url, into: env, ceiling: nil)
            lap("imported")
            meter.sample()
            XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
            XCTAssertEqual(summary.inserted, 1)
            XCTAssertEqual(summary.bodiesNotDecoded, 1, "above the full-parse ceiling: headers plus a locator")

            let ids = try await env.store.deferredBodyIDs(limit: 5)
            let id = try XCTUnwrap(ids.first)
            let storedLocator = try await env.store.locator(forEmailID: id)
            let locator = try XCTUnwrap(storedLocator)
            XCTAssertEqual(locator.sourcePath, url.path, "the locator points into the .emlx itself")
            XCTAssertEqual(locator.messageRange.length, messageLength, "the byte count's range")
            XCTAssertEqual(locator.messageRange.offset, Int64("\(messageLength)\n".utf8.count))
            let stored = try await env.archive.fullEmail(id: id)
            let email = try XCTUnwrap(stored)
            XCTAssertEqual(email.headers["Subject"], "Large emlx")
            XCTAssertTrue(email.tags.contains("Read") && email.tags.contains("Flagged"), "flags from the plist: \(email.tags)")
            XCTAssertTrue(email.tags.contains("Inbox"), "the mailbox from the path: \(email.tags)")

            // Its text and attachment stream out of the range after import.
            let pass = await StreamedBodyIndexer().indexPending(store: env.store)
            meter.sample()
            lap("text streamed into the index")
            XCTAssertEqual(pass, StreamedBodyIndexer.PassOutcome(indexed: 1, failed: 0))
            let state = try await env.store.bodyDocumentState(emailID: id)
            XCTAssertEqual(state, .complete)
            let located = try await env.store.streamedAttachmentParts(emailID: id)
            let (sourcePath, parts) = try XCTUnwrap(located)
            XCTAssertEqual(parts.map { $0.filename ?? "" }, ["huge.bin"])
            let out = root.appendingPathComponent("emlx-part.out")
            let decoded = try StreamedPartDecoder.decode(part: parts[0], sourcePath: sourcePath, to: out)
            meter.sample()
            lap("attachment streamed out")
            XCTAssertEqual(decoded.bytesWritten, attachmentLength)
            XCTAssertEqual(try Self.fileDigest(out), expected, "attachment of \(attachmentLength) bytes byte for byte")
            try FileManager.default.removeItem(at: out)
            XCTAssertLessThan(meter.peakDelta, 160 * Self.mib, "peak footprint \(meter.peakDelta / Self.mib) MiB for a \(fileSize / Self.mib) MiB file")
            print("CLOSE-01 emlx \(fileSize) bytes: imported, indexed, attachment streamed; peak footprint delta \(meter.peakDelta / Self.mib) MiB")
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - A .msg above the ceiling, imported through its rendering

    func testCLOSE01_msgAboveTheCeiling_importsThroughARenderingInsideTheArchive_bodyAndAttachmentHashesMatch() async throws {
        let env = makeEnv("msg-rendered")
        var attachment = Data(count: 2_500_000 + 13)
        for i in 0..<attachment.count { attachment[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        let bodyText = (0..<40_000).map { "Line \($0) of a long body, zanzibar at the end." }.joined(separator: "\r\n") + " lastwordquokka"
        let url = root.appendingPathComponent("rendered.msg")
        try CFB.write(Self.msgEntries(subject: "Rendered msg", body: .data(CFB.utf16(bodyText)), attachmentName: "data.bin",
                                      attachment: .data(attachment), messageID: "<close01-rendered@example.com>"), to: url)

        // The in-memory reader (now through a file handle) reads the same message.
        let whole = try XCTUnwrap(try MSGParser.parse(fileURL: url, senderEmail: "").first)
        XCTAssertEqual(whole.plainBody, bodyText)
        XCTAssertEqual(whole.attachments.first.flatMap { $0.base64.flatMap { Data(base64Encoded: $0) } }, attachment)

        let summary = try await importFile(url, into: env, ceiling: Self.mib)
        XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
        XCTAssertEqual(summary.inserted, 1)
        let ids = try await env.store.deferredBodyIDs(limit: 5)
        let id = try XCTUnwrap(ids.first)
        let storedLocator = try await env.store.locator(forEmailID: id)
            let locator = try XCTUnwrap(storedLocator)
        let sources = SourceCopies.directory(in: env.store.storeDirectory)
        XCTAssertTrue(locator.sourcePath.hasPrefix(sources.path), "the rendering lives inside the archive: \(locator.sourcePath)")
        XCTAssertTrue(locator.sourcePath.hasSuffix("rendered.rendered.eml"))
        XCTAssertEqual(locator.sourceDigest, try Self.fileDigest(URL(fileURLWithPath: locator.sourcePath)), "its digest proves later reads")
        let stored = try await env.archive.fullEmail(id: id)
            let email = try XCTUnwrap(stored)
        XCTAssertEqual(email.headers["Subject"], "Rendered msg")
        XCTAssertEqual(email.messageType, "received")

        let pass = await StreamedBodyIndexer().indexPending(store: env.store, sliceBytes: 64 * 1024)
        XCTAssertEqual(pass, StreamedBodyIndexer.PassOutcome(indexed: 1, failed: 0))
        let located = try await env.store.streamedAttachmentParts(emailID: id)
        let (sourcePath, parts) = try XCTUnwrap(located)
        XCTAssertEqual(parts.map { $0.filename ?? "" }, ["data.bin"])
        let out = root.appendingPathComponent("msg-part.out")
        _ = try StreamedPartDecoder.decode(part: parts[0], sourcePath: sourcePath, to: out, sliceBytes: 8_192)
        XCTAssertEqual(try Data(contentsOf: out), attachment, "the attachment byte for byte out of the rendering")
        // The body (a 2 MB UTF-16 stream, transcoded in slices) is whole in the rendering.
        let rendered = try String(contentsOf: URL(fileURLWithPath: sourcePath), encoding: .utf8)
        let bodyPart = try XCTUnwrap(rendered.components(separatedBy: "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n").dropFirst().first)
        let encoded = bodyPart.components(separatedBy: "\r\n--").first ?? ""
        XCTAssertEqual(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters).map { String(decoding: $0, as: UTF8.self) }, bodyText)

        // A second import reuses the rendering, so the first locators stay valid.
        let before = try Self.fileDigest(URL(fileURLWithPath: sourcePath))
        _ = try await importFile(url, into: env, ceiling: Self.mib)
        XCTAssertEqual(try Self.fileDigest(URL(fileURLWithPath: sourcePath)), before)
    }

    /// A real Outlook message (Apache Tika) imported through its rendering:
    /// its attachment is the same bytes the in-memory reader returns.
    func testCLOSE01_realMSG_renderedAndStreamed_matchesTheInMemoryReader() async throws {
        // <repo>/Packages/ArchiveCore/Tests/ArchiveCoreTests/this file → <repo>/maxmailinTests/Fixtures/…
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("maxmailinTests/Fixtures/opensource/tika/testMSG_att_doc.msg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "fixture at \(fixture.path)")
        let whole = try XCTUnwrap(try MSGParser.parse(fileURL: fixture, senderEmail: "").first)
        XCTAssertEqual(try MSGParser.parse(data: Data(contentsOf: fixture)).attachments.map(\.base64), whole.attachments.map(\.base64),
                       "file handle and memory read the same compound file")
        let wanted = whole.attachments.filter { $0.base64 != nil }
        XCTAssertFalse(wanted.isEmpty)

        let env = makeEnv("tika")
        let summary = try await importFile(fixture, into: env, ceiling: 1_024)
        XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
        let ids = try await env.store.deferredBodyIDs(limit: 5)
        let id = try XCTUnwrap(ids.first)
        _ = await StreamedBodyIndexer().indexPending(store: env.store)
        let located = try await env.store.streamedAttachmentParts(emailID: id)
        let (sourcePath, parts) = try XCTUnwrap(located)
        XCTAssertEqual(parts.compactMap(\.filename), wanted.map(\.filename))
        for (part, original) in zip(parts, wanted) {
            let out = root.appendingPathComponent("tika-part.out")
            _ = try StreamedPartDecoder.decode(part: part, sourcePath: sourcePath, to: out)
            XCTAssertEqual(try Data(contentsOf: out), Data(base64Encoded: original.base64 ?? ""), original.filename)
        }
    }

    // MARK: - Cancellation

    func testCLOSE01_cancellationStopsAStreamMidRead_andLeavesNoPartialRendering() async throws {
        let length: Int64 = 300 * Self.mib
        let url = root.appendingPathComponent("cancel.msg")
        try CFB.write(Self.msgEntries(subject: "Cancel", body: .data(CFB.utf16("b")), attachmentName: "big.bin",
                                      attachment: .sparse(length: length, markers: Self.markers(length)), messageID: "<cancel@example.com>"), to: url)
        let task = Task<(Int64, Bool), Error> {
            let ole = try OLE2Reader(fileURL: url)
            let entry = try XCTUnwrap(try ole.readAttachments(storage: 0, deferStreamsAbove: MSGStreamRenderer.inPlaceStreamBytes).first?.deferredData)
            var seen: Int64 = 0
            do {
                try ole.streamEntry(entry) { slice in
                    seen += Int64(slice.count)
                    if seen >= 8 * Self.mib { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch is CancellationError {
                return (seen, true)
            }
            return (seen, false)
        }
        let (seen, cancelled) = try await task.value
        XCTAssertTrue(cancelled, "a CancellationError, not a finished stream")
        XCTAssertLessThan(seen, 16 * Self.mib, "stopped within a slice or two of the cancel")

        // Cancelled while rendering for import: no rendering is left behind.
        let renderDirectory = root.appendingPathComponent("renders", isDirectory: true)
        let importTask = Task<Bool, Error> {
            var engine = OffsetImportEngine()
            engine.fullParseCeilingBytes = Self.mib
            let kind = try XCTUnwrap(engine.largeSingleMessageKind(fileURL: url, format: .msg))
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await engine.importLargeSingleMessage(fileURL: url, kind: kind, renderDirectory: renderDirectory, senderEmail: "") { _ in }
            } catch is CancellationError { return true }
            return false
        }
        let importCancelled = try await importTask.value
        XCTAssertTrue(importCancelled)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: renderDirectory.path)) ?? []
        XCTAssertEqual(left, [], "neither a partial nor a finished rendering: \(left)")
    }

    // MARK: - Damaged compound files are refused cleanly

    private func patch(_ url: URL, at offset: UInt64, _ value: UInt32) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var d = Data(); d.le32append(value)
        try handle.write(contentsOf: d)
    }

    private func damagedMSG(_ name: String) throws -> (URL, CFB.Layout) {
        let url = root.appendingPathComponent("\(name).msg")
        let layout = try CFB.write(Self.msgEntries(subject: "Damaged", body: .data(CFB.utf16("body")), attachmentName: "a.bin",
                                                   attachment: .data(Data(repeating: 0x41, count: 3 * 1_048_576)),
                                                   messageID: "<damaged-\(name)@example.com>"), to: url)
        return (url, layout)
    }

    private func refusal(_ url: URL) -> String? {
        do {
            let ole = try OLE2Reader(fileURL: url)
            _ = try MSGStreamRenderer.render(ole: ole, into: RenderedMessageSink { _ in })
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testCLOSE01_damagedCompoundFiles_loopsOutOfRangeSectorsAndShortChains_areRefusedWithTheirReason() async throws {
        // A chain that loops back on itself.
        var (url, layout) = try damagedMSG("loop")
        let start = try XCTUnwrap(layout.startSector[Self.attachmentEntryIndex])
        try patch(url, at: layout.fatEntryOffset(start + 100), UInt32(start + 10))
        XCTAssertTrue(refusal(url)?.contains("loops back to sector \(start + 10)") == true, refusal(url) ?? "accepted")

        // A sector number outside the file.
        (url, layout) = try damagedMSG("outside")
        try patch(url, at: layout.fatEntryOffset(start + 50), 0x00FF_FFF0)
        XCTAssertTrue(refusal(url)?.contains("outside") == true, refusal(url) ?? "accepted")

        // A chain that ends before the declared size.
        (url, layout) = try damagedMSG("short")
        try patch(url, at: layout.directoryEntryOffset(Self.attachmentEntryIndex) + 120, UInt32(5 * 1_048_576))
        XCTAssertTrue(refusal(url)?.contains("ends after") == true, refusal(url) ?? "accepted")

        // The import says why, and the archive holds nothing invented.
        let env = makeEnv("damaged")
        let summary = try await importFile(url, into: env, ceiling: Self.mib)
        XCTAssertEqual(summary.inserted, 0)
        XCTAssertTrue(summary.fileErrors.first?.message.contains("ends after") == true, "\(summary.fileErrors.map(\.message))")
        let renders = SourceCopies.directory(in: env.store.storeDirectory)
        let leftovers = (FileManager.default.enumerator(atPath: renders.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".eml") || $0.contains(".rendering-") }
        XCTAssertEqual(leftovers, [], "no rendering of a refused file")

        // A DIFAT chain that loops, with a huge declared count: the reader ends, it does not spin.
        (url, layout) = try damagedMSG("difat")
        try patch(url, at: 68, UInt32(layout.directoryStart))      // first DIFAT sector: a directory sector
        try patch(url, at: 72, 0x7FFF_FFFF)                          // and "two billion" of them
        try patch(url, at: UInt64((layout.directoryStart + 1) * 512 + 508), UInt32(layout.directoryStart))   // whose next is itself
        let began = Date()
        _ = try? OLE2Reader(fileURL: url)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)

        // A directory whose sibling chain loops: the walk ends.
        (url, layout) = try damagedMSG("siblings")
        try patch(url, at: layout.directoryEntryOffset(5) + 72, 1)   // properties → back to the subject
        let message = try MSGParser.parse(fileURL: url, senderEmail: "").first
        XCTAssertEqual(message?.headers["Subject"], "Damaged")

        // Not a compound file at all, and a truncated header.
        let junk = root.appendingPathComponent("junk.msg")
        try Data(repeating: 0x20, count: 4_096).write(to: junk)
        XCTAssertThrowsError(try OLE2Reader(fileURL: junk))
        try Data([0xD0, 0xCF, 0x11, 0xE0]).write(to: junk)
        XCTAssertThrowsError(try OLE2Reader(fileURL: junk))
    }

    func testCLOSE01_damagedEMLX_areRefusedWithTheirReason_andAByteCountPastTheEndKeepsTheRest() throws {
        let url = root.appendingPathComponent("bad.emlx")
        try Data().write(to: url)
        XCTAssertThrowsError(try EMLXParser.parse(fileURL: url, senderEmail: "")) { XCTAssertTrue("\($0.localizedDescription)".contains("Empty file")) }
        try Data("abc\nFrom: a@b.c\n\nbody".utf8).write(to: url)
        XCTAssertThrowsError(try EMLXParser.parse(fileURL: url, senderEmail: "")) { XCTAssertTrue("\($0.localizedDescription)".contains("Invalid byte count line")) }
        try Data("12".utf8).write(to: url)
        XCTAssertThrowsError(try EMLXParser.parse(fileURL: url, senderEmail: "")) { XCTAssertTrue("\($0.localizedDescription)".contains("File too short")) }
        try Data("12\n   \n".utf8).write(to: url)
        XCTAssertThrowsError(try EMLXParser.parse(fileURL: url, senderEmail: "")) { XCTAssertTrue("\($0.localizedDescription)".contains("No message content")) }
        try Data("99999\nFrom: a@b.c\nSubject: Short\n\nbody text\n".utf8).write(to: url)
        let layout = try EMLXParser.layout(of: url)
        XCTAssertNil(layout.plist)
        XCTAssertEqual(layout.message, ByteRange(offset: 6, length: Int64("From: a@b.c\nSubject: Short\n\nbody text\n".utf8.count)))
        XCTAssertEqual(try EMLXParser.parse(fileURL: url, senderEmail: "").first?.headers["Subject"], "Short")
    }
}

// MARK: - CLOSE-01 follow-up: large messages inside library folders and archives

extension LargeSingleMessageTests {

    /// Peak footprint sampled on a background thread every millisecond, so a
    /// whole-message read inside the coordinator cannot slip between samples.
    final class BackgroundPeak: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak: UInt64
        let baseline: UInt64
        init() {
            baseline = currentFootprintBytes()
            peak = baseline
            Thread { [self] in
                while true {
                    let now = currentFootprintBytes()
                    lock.lock()
                    if now > peak { peak = now }
                    let go = running
                    lock.unlock()
                    if !go { break }
                    usleep(1_000)
                }
            }.start()
        }
        /// Stops sampling; the peak growth over the baseline, in bytes.
        func stop() -> Int64 {
            let now = currentFootprintBytes()
            lock.lock(); running = false; if now > peak { peak = now }; let p = peak; lock.unlock()
            usleep(5_000)
            return Int64(p) - Int64(baseline)
        }
    }

    private func runImport(_ url: URL, into env: Env, offsetEngine: Bool) async throws -> BulkImportCoordinator.RunSummary {
        let coordinator = await BulkImportCoordinator(store: env.store, fts: env.fts,
                                                      checkpoints: ImportCheckpointStore(store: env.store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = offsetEngine
        options.recordLocators = true
        return try await coordinator.runImport(urls: [url], options: options)
    }

    /// Copies `source` into `handle` at `offset`, leaving runs of zeros as holes.
    private static func sparseCopy(_ source: URL, into handle: FileHandle, at offset: UInt64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let slice = 4 << 20
        let zeros = Data(count: slice)
        var at = offset
        while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: slice) }), !chunk.isEmpty {
            if !(chunk.count == slice && chunk == zeros) {
                try handle.seek(toOffset: at)
                try handle.write(contentsOf: chunk)
            }
            at += UInt64(chunk.count)
        }
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc = ZIPArchiveReader.CRC32()
        while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: 4 << 20) }), !chunk.isEmpty { crc.update(chunk) }
        return crc.value
    }

    /// A ZIP holding `file` as one STORED member named `name`, written sparsely.
    private static func writeStoredZIP(member file: URL, name: String, to url: URL) throws {
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).uint32Value
        let crc = try crc32(of: file)
        let nameData = Data(name.utf8)
        func fixed(_ signature: UInt32, central: Bool) -> Data {
            var d = Data()
            d.le32append(signature)
            if central { d.le16append(20) }               // version made by
            d.le16append(20); d.le16append(0); d.le16append(0)   // version needed, flags, stored
            d.le16append(0); d.le16append(0x5821)                // time, date
            d.le32append(crc); d.le32append(size); d.le32append(size)
            d.le16append(UInt16(nameData.count)); d.le16append(0)
            if central {
                d.le16append(0); d.le16append(0); d.le16append(0)   // comment, disk, internal attributes
                d.le32append(0); d.le32append(0)                     // external attributes, local header offset
            }
            return d + nameData
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let local = fixed(0x0403_4B50, central: false)
        try handle.write(contentsOf: local)
        try sparseCopy(file, into: handle, at: UInt64(local.count))
        let centralOffset = UInt64(local.count) + UInt64(size)
        let central = fixed(0x0201_4B50, central: true)
        var end = Data()
        end.le32append(0x0605_4B50); end.le16append(0); end.le16append(0)
        end.le16append(1); end.le16append(1)
        end.le32append(UInt32(central.count)); end.le32append(UInt32(centralOffset)); end.le16append(0)
        try handle.seek(toOffset: centralOffset)
        try handle.write(contentsOf: central + end)
    }

    /// A ustar TAR holding `file` as one member named `name`, written sparsely.
    private static func writeTAR(member file: URL, name: String, to url: URL) throws {
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).int64Value
        var header = Data(count: 512)
        func put(_ text: String, at offset: Int) { for (k, b) in text.utf8.enumerated() { header[offset + k] = b } }
        put(name, at: 0)
        put("0000644", at: 100); put("0000000", at: 108); put("0000000", at: 116)
        put(String(String(size, radix: 8).leftPadded(to: 11)), at: 124)
        put("00000000000", at: 136)
        put("        ", at: 148)
        header[156] = 0x30
        put("ustar", at: 257); put("00", at: 263)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(sum, radix: 8).leftPadded(to: 6), at: 148)
        header[154] = 0; header[155] = 0x20
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        try sparseCopy(file, into: handle, at: 512)
        let padded = (size + 511) / 512 * 512
        try handle.truncate(atOffset: UInt64(512 + padded + 1024))   // two zero blocks end it
    }

    /// The one message whose body was not decoded: its locator, text indexed,
    /// and its attachment streamed out — returns the attachment's SHA-256.
    private func streamedAttachment(_ env: Env, expectedName: String) async throws -> (locator: MessageLocator, email: MBOXParser.RawEmail, digest: String, bytes: Int64) {
        let ids = try await env.store.deferredBodyIDs(limit: 5)
        XCTAssertEqual(ids.count, 1, "exactly one message imported by range")
        let id = try XCTUnwrap(ids.first)
        let storedLocator = try await env.store.locator(forEmailID: id)
        let locator = try XCTUnwrap(storedLocator)
        let stored = try await env.archive.fullEmail(id: id)
        let email = try XCTUnwrap(stored)
        let indexPeak = BackgroundPeak()
        let pass = await StreamedBodyIndexer().indexPending(store: env.store)
        let indexGrew = indexPeak.stop()
        XCTAssertEqual(pass, StreamedBodyIndexer.PassOutcome(indexed: 1, failed: 0))
        let located = try await env.store.streamedAttachmentParts(emailID: id)
        let (sourcePath, parts) = try XCTUnwrap(located)
        XCTAssertEqual(parts.map { $0.filename ?? "" }, [expectedName])
        let out = root.appendingPathComponent("part-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: out) }
        let decodePeak = BackgroundPeak()
        let decoded = try StreamedPartDecoder.decode(part: parts[0], sourcePath: sourcePath, to: out)
        let decodeGrew = decodePeak.stop()
        print("CLOSE-01 after import: text index peak \(indexGrew / Self.mib) MiB, attachment decode peak \(decodeGrew / Self.mib) MiB")
        return (locator, email, try Self.fileDigest(out), decoded.bytesWritten)
    }

    private func smallEMLX(_ url: URL, subject: String) throws {
        let message = "From: small@example.com\nTo: you@example.com\nSubject: \(subject)\nMessage-ID: <\(subject)@example.com>\nDate: Fri, 17 Mar 2017 12:00:00 +0000\n\nA small message.\n"
        try Data("\(message.utf8.count)\n\(message)".utf8).write(to: url)
    }

    // (1) .emlx inside an Apple Mail library folder

    func testCLOSE01_emlxAbove500MBInsideALibraryFolder_importsByRangeInBoundedMemory_attachmentByteExact() async throws {
        let attachmentLength: Int64 = 500_100_000
        let library = root.appendingPathComponent("V10", isDirectory: true)
        let messages = library.appendingPathComponent("Inbox.mbox/1F2E3D4C/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let big = messages.appendingPathComponent("101.emlx")
        let (expected, messageLength) = try writeSparseEMLX(big, attachmentLength: attachmentLength, flags: 0x11)
        XCTAssertGreaterThan(WholeMessageReadLimit.fileSize(big), 500_000_000)
        try smallEMLX(messages.appendingPathComponent("102.emlx"), subject: "SmallOne")
        XCTAssertEqual(SourceFormatClassifier.classify(url: library).format, .appleMailLibrary)

        let env = makeEnv("library")
        let peak = BackgroundPeak()
        let summary = try await runImport(library, into: env, offsetEngine: true)
        let importPeak = peak.stop()
        XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
        XCTAssertEqual(summary.inserted, 2)
        XCTAssertEqual(summary.bodiesNotDecoded, 1, "the large one by headers plus a locator")
        XCTAssertLessThan(importPeak, 160 * Self.mib, "import peak \(importPeak / Self.mib) MiB for a \(attachmentLength / Self.mib) MiB message")

        let after = BackgroundPeak()
        let result = try await streamedAttachment(env, expectedName: "huge.bin")
        let streamPeak = after.stop()
        XCTAssertEqual(URL(fileURLWithPath: result.locator.sourcePath).resolvingSymlinksInPath().path, big.resolvingSymlinksInPath().path, "range reads of the .emlx in the library itself")
        XCTAssertEqual(result.locator.messageRange.length, messageLength)
        XCTAssertEqual(result.locator.sourceDigest, try Self.fileDigest(big), "the .emlx's digest proves later reads")
        XCTAssertEqual(result.email.headers["Subject"], "Large emlx")
        XCTAssertTrue(result.email.tags.contains("Read") && result.email.tags.contains("Flagged"), "flags: \(result.email.tags)")
        XCTAssertTrue(result.email.tags.contains("Inbox"), "the mailbox from the library path: \(result.email.tags)")
        XCTAssertEqual(result.bytes, attachmentLength)
        XCTAssertEqual(result.digest, expected, "attachment of \(attachmentLength) bytes byte for byte")
        XCTAssertLessThan(streamPeak, 160 * Self.mib)
        print("CLOSE-01 library emlx \(WholeMessageReadLimit.fileSize(big)) bytes: import peak \(importPeak / Self.mib) MiB, index+decode peak \(streamPeak / Self.mib) MiB")
    }

    // (2) .emlx member of a ZIP (stored)

    func testCLOSE01_emlxAbove500MBStoredInAZIP_importsFromItsScratchFileByRange_keptInTheArchive_attachmentByteExact() async throws {
        let attachmentLength: Int64 = 500_100_000
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let member = staging.appendingPathComponent("big.emlx")
        let (expected, messageLength) = try writeSparseEMLX(member, attachmentLength: attachmentLength, flags: 0x11)
        let zip = root.appendingPathComponent("mail.zip")
        try Self.writeStoredZIP(member: member, name: "Inbox.mbox/Messages/big.emlx", to: zip)
        try FileManager.default.removeItem(at: member)
        XCTAssertEqual(SourceFormatClassifier.classify(url: zip).format, .zip)

        func scratchFolders() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
                .filter { $0.hasPrefix("mailin-container-") })
        }
        let scratchBefore = scratchFolders()   // other runs may have left theirs
        let env = makeEnv("zip")
        let peak = BackgroundPeak()
        let summary = try await runImport(zip, into: env, offsetEngine: true)
        let importPeak = peak.stop()
        XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.bodiesNotDecoded, 1)
        XCTAssertLessThan(importPeak, 160 * Self.mib, "import peak \(importPeak / Self.mib) MiB")

        let after = BackgroundPeak()
        let result = try await streamedAttachment(env, expectedName: "huge.bin")
        let streamPeak = after.stop()
        let sources = SourceCopies.directory(in: env.store.storeDirectory)
        XCTAssertTrue(result.locator.sourcePath.hasPrefix(sources.path), "kept inside the archive, not the deleted scratch file: \(result.locator.sourcePath)")
        XCTAssertTrue(result.locator.sourcePath.contains("/members/0/"), result.locator.sourcePath)
        XCTAssertEqual(WholeMessageReadLimit.fileSize(URL(fileURLWithPath: result.locator.sourcePath)), messageLength, "the message range, copied")
        XCTAssertEqual(result.locator.sourceDigest, try Self.fileDigest(URL(fileURLWithPath: result.locator.sourcePath)))
        XCTAssertEqual(result.email.headers["Subject"], "Large emlx")
        XCTAssertTrue(result.email.tags.contains("Read") && result.email.tags.contains("Flagged"), "flags from the member's plist: \(result.email.tags)")
        XCTAssertTrue(result.email.tags.contains("Inbox"), "the folder from the member's path in the archive: \(result.email.tags)")
        XCTAssertEqual(result.digest, expected, "attachment of \(attachmentLength) bytes byte for byte")
        XCTAssertLessThan(streamPeak, 160 * Self.mib)
        XCTAssertEqual(scratchFolders().subtracting(scratchBefore), [], "this import's scratch folder is gone")
        print("CLOSE-01 zip emlx member \(messageLength) bytes: import peak \(importPeak / Self.mib) MiB, index+decode peak \(streamPeak / Self.mib) MiB")
    }

    // (2) .msg member of a TAR

    func testCLOSE01_msgAbove2GBInsideATAR_renderedFromItsScratchFileInsideTheArchive_attachmentByteExact() async throws {
        let attachmentLength: Int64 = 2_000_100_000
        let marks = Self.markers(attachmentLength)
        let staging = root.appendingPathComponent("staging-msg", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let member = staging.appendingPathComponent("huge.msg")
        try CFB.write(Self.msgEntries(subject: "Huge msg in tar", body: .data(CFB.utf16("A short body.")),
                                      attachmentName: "huge.bin", attachment: .sparse(length: attachmentLength, markers: marks),
                                      messageID: "<close01-tar@example.com>"), to: member)
        let msgSize = WholeMessageReadLimit.fileSize(member)
        XCTAssertGreaterThan(msgSize, 2_000_000_000)
        let tar = root.appendingPathComponent("outlook.tar")
        try Self.writeTAR(member: member, name: "Outlook/huge.msg", to: tar)
        try FileManager.default.removeItem(at: member)
        XCTAssertEqual(SourceFormatClassifier.classify(url: tar).format, .tar)

        let env = makeEnv("tar")
        let peak = BackgroundPeak()
        let summary = try await runImport(tar, into: env, offsetEngine: true)
        let importPeak = peak.stop()
        XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.bodiesNotDecoded, 1)
        XCTAssertLessThan(importPeak, 160 * Self.mib, "import peak \(importPeak / Self.mib) MiB for a \(msgSize / Self.mib) MiB .msg")

        let after = BackgroundPeak()
        let result = try await streamedAttachment(env, expectedName: "huge.bin")
        let streamPeak = after.stop()
        let sources = SourceCopies.directory(in: env.store.storeDirectory)
        XCTAssertTrue(result.locator.sourcePath.hasPrefix(sources.path), result.locator.sourcePath)
        XCTAssertTrue(result.locator.sourcePath.hasSuffix("/members/0/0-huge.rendered.eml"), result.locator.sourcePath)
        XCTAssertEqual(result.email.headers["Subject"], "Huge msg in tar")
        XCTAssertEqual(result.bytes, attachmentLength)
        XCTAssertEqual(result.digest, Self.sparseDigest(length: attachmentLength, markers: marks), "attachment of \(attachmentLength) bytes byte for byte")
        XCTAssertLessThan(streamPeak, 160 * Self.mib)
        print("CLOSE-01 tar msg member \(msgSize) bytes: import (render) peak \(importPeak / Self.mib) MiB, index+decode peak \(streamPeak / Self.mib) MiB")
    }

    // (3) the previous engine: a named refusal above its ceiling, small files unchanged

    func testCLOSE01_offsetEngineOff_refusesAboveTheWholeReadCeilingByName_smallFilesImportAsBefore() async throws {
        // A standalone .emlx and .msg above the ceilings.
        let bigEMLX = root.appendingPathComponent("big.emlx")
        _ = try writeSparseEMLX(bigEMLX, attachmentLength: 500_100_000, flags: 0)
        let bigMSG = root.appendingPathComponent("big.msg")
        try CFB.write(Self.msgEntries(subject: "Too big", body: .data(CFB.utf16("b")), attachmentName: "huge.bin",
                                      attachment: .sparse(length: 2_000_100_000, markers: Self.markers(2_000_100_000)),
                                      messageID: "<too-big@example.com>"), to: bigMSG)
        for url in [bigEMLX, bigMSG] {
            let env = makeEnv("off-\(url.pathExtension)")
            let peak = BackgroundPeak()
            let summary = try await runImport(url, into: env, offsetEngine: false)
            let grew = peak.stop()
            XCTAssertEqual(summary.inserted, 0)
            let message = summary.fileErrors.first?.message ?? ""
            XCTAssertTrue(message.contains("previous import engine") && message.contains("offset import engine on"), message)
            XCTAssertLessThan(grew, 64 * Self.mib, "refused before anything is read: \(grew / Self.mib) MiB")
        }
        try FileManager.default.removeItem(at: bigMSG)

        // In a library folder: the small message imports, the large one is counted as refused.
        let messages = root.appendingPathComponent("Lib/Work.mbox/AB12/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bigEMLX, to: messages.appendingPathComponent("1.emlx"))
        try smallEMLX(messages.appendingPathComponent("2.emlx"), subject: "Kept")
        var env = makeEnv("off-library")
        var summary = try await runImport(root.appendingPathComponent("Lib"), into: env, offsetEngine: false)
        XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.damaged, 0, "refused is not damaged")
        XCTAssertTrue(summary.warnings.contains { $0.contains("1 message not imported") && $0.contains("previous import engine") }, "\(summary.warnings)")

        // In a ZIP: the member is refused with its reason, the rest imports.
        let zipMember = root.appendingPathComponent("zip-big.emlx")
        try FileManager.default.moveItem(at: messages.appendingPathComponent("1.emlx"), to: zipMember)
        let zip = root.appendingPathComponent("off.zip")
        try Self.writeStoredZIP(member: zipMember, name: "Inbox.mbox/Messages/big.emlx", to: zip)
        try FileManager.default.removeItem(at: zipMember)
        env = makeEnv("off-zip")
        summary = try await runImport(zip, into: env, offsetEngine: false)
        XCTAssertEqual(summary.fileErrors.count, 0, "a refused member is not a failed import: \(summary.fileErrors.map(\.message))")
        XCTAssertEqual(summary.inserted, 0)
        XCTAssertTrue(summary.warnings.contains { $0.contains("1 archive member not imported") && $0.contains(WholeMessageReadLimit.memberReason) }, "\(summary.warnings)")

        // Small files: unchanged with the engine off.
        let smallMSG = root.appendingPathComponent("small.msg")
        try CFB.write(Self.msgEntries(subject: "Small msg", body: .data(CFB.utf16("A short body.")), attachmentName: "a.bin",
                                      attachment: .data(Data(repeating: 0x42, count: 10_000)), messageID: "<small-msg@example.com>"), to: smallMSG)
        let smallEMLXURL = root.appendingPathComponent("small.emlx")
        try smallEMLX(smallEMLXURL, subject: "SmallAlone")
        for url in [smallMSG, smallEMLXURL] {
            env = makeEnv("off-small-\(url.pathExtension)")
            summary = try await runImport(url, into: env, offsetEngine: false)
            XCTAssertEqual(summary.fileErrors.count, 0, "\(summary.fileErrors.map(\.message))")
            XCTAssertEqual(summary.inserted, 1)
            XCTAssertEqual(summary.bodiesNotDecoded, 0, "read whole, as before")
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func le16(_ v: UInt16, at offset: Int) {
        self[offset] = UInt8(v & 0xFF); self[offset + 1] = UInt8(v >> 8)
    }
    mutating func le32(_ v: UInt32, at offset: Int) {
        for k in 0..<4 { self[offset + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) }
    }
    mutating func le16append(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32append(_ v: UInt32) { for k in 0..<4 { append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) } }
}
