//
//  StreamingZIPWriter.swift
//  ArchiveCore
//
//  CLOSE-03 / CUR-05: a file-backed ZIP writer (stored members only) whose
//  live memory does not grow with the member count. Each member's bytes are
//  copied from a file in 1 MiB reads; the central directory is spooled to its
//  own temporary file and appended at `finish()`. ZIP64 records are written
//  when an offset, a size or the member count needs them (APPNOTE 4.3.14,
//  4.5.3), which `ZIPArchiveReader` honours.
//
//  All-or-nothing: the archive is written as `<destination>.partial` and
//  renamed only when the end record is on disk. Any error — a failed write
//  (disk full), a cancellation, a read failure — goes through `abandon()`,
//  which closes and removes both temporary files, so nothing half-written is
//  left behind under either name.
//
//  `ZIPByteSink` is the seam for fault injection (a sink that fails after N
//  bytes stands in for a full disk in tests).
//

import Foundation

/// Where the writer's bytes go. `FileZIPSink` in production.
protocol ZIPByteSink: AnyObject {
    func write(_ data: Data) throws
    func close() throws
}

final class FileZIPSink: ZIPByteSink {
    private let handle: FileHandle

    /// Creates (or truncates) the file at `url`.
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() throws { try handle.close() }
}

final class StreamingZIPWriter {

    /// One copy buffer; the only member-sized-independent allocation.
    static let chunkBytes = 1 << 20

    typealias SinkFactory = (URL) throws -> ZIPByteSink

    let destination: URL
    private let partialURL: URL
    private let directoryURL: URL
    private var body: ZIPByteSink?
    private var directory: ZIPByteSink?
    private var offset: UInt64 = 0
    private var directoryBytes: UInt64 = 0
    private(set) var memberCount: UInt64 = 0
    private var finished = false

    init(destination: URL, makeSink: SinkFactory = { try FileZIPSink(url: $0) }) throws {
        self.destination = destination
        partialURL = destination.appendingPathExtension("partial")
        directoryURL = destination.appendingPathExtension("directory")
        do {
            body = try makeSink(partialURL)
            directory = try makeSink(directoryURL)
        } catch {
            abandon()
            throw error
        }
    }

    deinit { if !finished { abandon() } }

    /// Adds `source` (whole file, `size` bytes, CRC-32 `crc`) as a stored member.
    func addStored(name: String, contentsOf source: URL, size: UInt64, crc: UInt32) throws {
        guard let body, let directory else { throw CocoaError(.fileWriteUnknown) }
        let nameBytes = Data(name.utf8)
        let localOffset = offset
        let big = size >= 0xFFFF_FFFF
        var local = Data([0x50, 0x4B, 0x03, 0x04])
        le16(&local, big ? 45 : 20); le16(&local, 0x0800); le16(&local, 0); le16(&local, 0); le16(&local, 0x21)
        le32(&local, crc)
        le32(&local, big ? 0xFFFF_FFFF : UInt32(size)); le32(&local, big ? 0xFFFF_FFFF : UInt32(size))
        var localExtra = Data()
        if big { le16(&localExtra, 0x0001); le16(&localExtra, 16); le64(&localExtra, size); le64(&localExtra, size) }
        le16(&local, UInt16(nameBytes.count)); le16(&local, UInt16(localExtra.count))
        local.append(nameBytes); local.append(localExtra)
        try body.write(local)
        offset += UInt64(local.count)

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var copied: UInt64 = 0
        while copied < size {
            try autoreleasepool {
                let chunk = try handle.read(upToCount: Int(min(UInt64(Self.chunkBytes), size - copied))) ?? Data()
                guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path]) }
                try body.write(chunk)
                copied += UInt64(chunk.count)
            }
        }
        offset += size

        let farOffset = localOffset >= 0xFFFF_FFFF
        var centralExtra = Data()
        if big || farOffset {
            var fields = Data()
            if big { le64(&fields, size); le64(&fields, size) }
            if farOffset { le64(&fields, localOffset) }
            le16(&centralExtra, 0x0001); le16(&centralExtra, UInt16(fields.count)); centralExtra.append(fields)
        }
        var c = Data([0x50, 0x4B, 0x01, 0x02])
        le16(&c, 0x031E); le16(&c, (big || farOffset) ? 45 : 20); le16(&c, 0x0800); le16(&c, 0); le16(&c, 0); le16(&c, 0x21)
        le32(&c, crc)
        le32(&c, big ? 0xFFFF_FFFF : UInt32(size)); le32(&c, big ? 0xFFFF_FFFF : UInt32(size))
        le16(&c, UInt16(nameBytes.count)); le16(&c, UInt16(centralExtra.count)); le16(&c, 0); le16(&c, 0); le16(&c, 0)
        le32(&c, 0); le32(&c, farOffset ? 0xFFFF_FFFF : UInt32(localOffset))
        c.append(nameBytes); c.append(centralExtra)
        try directory.write(c)
        directoryBytes += UInt64(c.count)
        memberCount += 1
    }

    /// Appends the central directory and end records, closes, and renames the
    /// archive to `destination`. On failure nothing is left behind.
    @discardableResult
    func finish() throws -> URL {
        do {
            guard let body, let directory else { throw CocoaError(.fileWriteUnknown) }
            try directory.close(); self.directory = nil
            let directoryOffset = offset
            let handle = try FileHandle(forReadingFrom: directoryURL)
            defer { try? handle.close() }
            var more = true
            while more {
                try autoreleasepool {
                    let chunk = try handle.read(upToCount: Self.chunkBytes) ?? Data()
                    if chunk.isEmpty { more = false } else { try body.write(chunk) }
                }
            }
            let needs64 = memberCount >= 0xFFFF || directoryOffset >= 0xFFFF_FFFF || directoryBytes >= 0xFFFF_FFFF
            var tail = Data()
            if needs64 {
                let recordOffset = directoryOffset + directoryBytes
                tail.append(contentsOf: [0x50, 0x4B, 0x06, 0x06]); le64(&tail, 44)
                le16(&tail, 45); le16(&tail, 45); le32(&tail, 0); le32(&tail, 0)
                le64(&tail, memberCount); le64(&tail, memberCount); le64(&tail, directoryBytes); le64(&tail, directoryOffset)
                tail.append(contentsOf: [0x50, 0x4B, 0x06, 0x07]); le32(&tail, 0); le64(&tail, recordOffset); le32(&tail, 1)
            }
            tail.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]); le16(&tail, 0); le16(&tail, 0)
            let count16 = needs64 ? UInt16(0xFFFF) : UInt16(memberCount)
            le16(&tail, count16); le16(&tail, count16)
            le32(&tail, needs64 ? 0xFFFF_FFFF : UInt32(directoryBytes)); le32(&tail, needs64 ? 0xFFFF_FFFF : UInt32(directoryOffset)); le16(&tail, 0)
            try body.write(tail)
            try body.close(); self.body = nil
            try? FileManager.default.removeItem(at: directoryURL)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partialURL, to: destination)
            finished = true
            return destination
        } catch {
            abandon()
            throw error
        }
    }

    /// Closes and removes the partial archive and the spooled directory.
    func abandon() {
        try? body?.close(); body = nil
        try? directory?.close(); directory = nil
        try? FileManager.default.removeItem(at: partialURL)
        try? FileManager.default.removeItem(at: directoryURL)
        finished = true
    }

    private func le16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    private func le32(_ d: inout Data, _ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    private func le64(_ d: inout Data, _ v: UInt64) { for i in 0..<8 { d.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
}
