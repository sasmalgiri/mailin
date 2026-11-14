//
//  LargeMessageRoute.swift
//  ArchiveCore
//
//  CLOSE-01 follow-up (2026-11-09): a large .emlx or .msg is imported in
//  bounded memory wherever it sits, not only as a file of its own.
//
//  CLOSE-01 routed a single large .emlx/.msg FILE to
//  `OffsetImportEngine.importLargeSingleMessage`. Two places still read such
//  a message whole: an .emlx inside an Apple Mail library folder, and an
//  .emlx or .msg member of an archive (ZIP, TAR, 7z, RAR, at any depth —
//  `ContainerMailboxWalk`). With the offset engine on, `BulkImportCoordinator`
//  now hands `ParserFactory.parseStreamingCallback` a route, and a message
//  above the full-parse ceiling takes the same road as a standalone file:
//
//   • library .emlx — range reads of the .emlx itself (headers plus a byte
//     locator, digest of the file recorded). With the self-contained archive
//     on (LIFE-01) the message range is copied into the archive first and the
//     locator points at the copy, so the archive still needs no original.
//   • archive member .emlx — the member's extracted scratch file is read by
//     range; because the scratch file is deleted once the member is done, the
//     message range is copied into the archive (`sources/<sha256>/members/
//     <member path>/`) and imported from there. Flags come from the member's
//     own property list.
//   • archive member .msg — rendered from the scratch file into the same
//     place by `MSGStreamRenderer` (OLE2Reader streaming), then imported by
//     range, exactly as a standalone .msg.
//
//  A copy or rendering already in place (a repeated or resumed import) is
//  reused, so the locators of an earlier import stay valid. The place is
//  keyed by the source's SHA-256 and the member's index path, which are
//  stable for the same bytes.
//

import Foundation

/// Where large single messages found inside a source go, and who takes them.
struct LargeMessageRoute: Sendable {
    var engine: OffsetImportEngine
    /// Inside the archive: `sources/<source sha256>/`.
    var keepDirectory: URL
    /// LIFE-01 on: a library .emlx is copied into the archive, not referenced.
    var copyLibraryMessages: Bool
    var retainAttachmentBytes: Bool = true
    var materializeAttachments: Bool = true
    /// Receives each imported message with its locator.
    var onImported: @Sendable ([OffsetImportEngine.Imported]) async throws -> Void

    /// The large-message kind of a file, or nil when it is read as before.
    func kind(of url: URL) -> OffsetImportEngine.LargeSingleMessageKind? {
        engine.largeSingleMessageKind(fileURL: url, format: SourceFormatClassifier.classify(url: url).format)
    }

    /// The archive folder kept for one archive member.
    func memberDirectory(path: [Int]) -> URL {
        keepDirectory.appendingPathComponent("members", isDirectory: true)
            .appendingPathComponent(path.map(String.init).joined(separator: "."), isDirectory: true)
    }

    /// The archive folder kept for a library message, by its path below the library.
    func libraryDirectory(member: URL, root: URL) -> URL {
        let rootParts = root.standardizedFileURL.pathComponents
        var parts = member.standardizedFileURL.deletingLastPathComponent().pathComponents
        if parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts {
            parts.removeFirst(rootParts.count)
        }
        let flat = parts.map { ParserFactory.safeMemberFileName($0) }.joined(separator: "_")
        return keepDirectory.appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(flat.isEmpty ? "root" : flat, isDirectory: true)
    }

    /// Imports one large message.
    /// - Parameters:
    ///   - transient: the file is deleted after the import (an archive
    ///     member), so what the locator points at must be kept in the archive.
    ///   - keepIn: where a rendering or copy is kept.
    func importMessage(_ url: URL, kind: OffsetImportEngine.LargeSingleMessageKind, transient: Bool, keepIn: URL,
                       senderEmail: String, folder: String?,
                       onProgress: ((Double) -> Void)?) async throws -> MBOXParser.ParseRecoveryReport {
        let deliver: ([OffsetImportEngine.Imported]) async throws -> Void = { batch in
            let stamped = batch.map { item -> OffsetImportEngine.Imported in
                var item = item
                if let folder, !folder.isEmpty, item.email.folderPath == nil { item.email.folderPath = folder }
                return item
            }
            try await onImported(stamped)
        }
        switch kind {
        case .msg:
            return try await engine.importLargeSingleMessage(
                fileURL: url, kind: .msg, renderDirectory: keepIn, senderEmail: senderEmail,
                retainAttachmentBytes: retainAttachmentBytes, materializeAttachments: materializeAttachments,
                onProgress: onProgress, onBatch: deliver)
        case .emlx:
            if transient || copyLibraryMessages {
                return try await engine.importLargeEMLXByCopy(
                    fileURL: url, keepIn: keepIn, senderEmail: senderEmail,
                    retainAttachmentBytes: retainAttachmentBytes, materializeAttachments: materializeAttachments,
                    onProgress: onProgress, onBatch: deliver)
            }
            let digest = try OffsetImportEngine.digest(of: url)
            return try await engine.importLargeSingleMessage(
                fileURL: url, kind: .emlx, renderDirectory: keepIn, senderEmail: senderEmail,
                retainAttachmentBytes: retainAttachmentBytes, materializeAttachments: materializeAttachments,
                sourceDigest: digest, onProgress: onProgress, onBatch: deliver)
        }
    }
}

extension OffsetImportEngine {

    /// Where the kept copy of a large .emlx's message lives: `<keepIn>/<name>.message.eml`.
    static func keptMessageURL(for fileURL: URL, in keepIn: URL) -> URL {
        keepIn.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".message.eml")
    }

    /// A large .emlx whose message must live in the archive: its message
    /// range is copied into `keepIn` in slices (a copy already there is
    /// reused), located there by range, and given the flags, mailbox and
    /// recovery state of the .emlx's own property list.
    @discardableResult
    func importLargeEMLXByCopy(
        fileURL: URL,
        keepIn: URL,
        senderEmail: String,
        retainAttachmentBytes: Bool = true,
        materializeAttachments: Bool = true,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([Imported]) async throws -> Void
    ) async throws -> MBOXParser.ParseRecoveryReport {
        try Task.checkCancellation()
        let layout = try EMLXParser.layout(of: fileURL)
        let plist = EMLXParser.plist(of: fileURL, layout: layout)
        try FileManager.default.createDirectory(at: keepIn, withIntermediateDirectories: true)
        let kept = Self.keptMessageURL(for: fileURL, in: keepIn)
        if !FileManager.default.fileExists(atPath: kept.path) {
            // Copied under a temporary name and moved into place, so an
            // interrupted copy is never taken for a finished one.
            let partial = keepIn.appendingPathComponent(".copying-\(UUID().uuidString)")
            do {
                try Self.copyRange(layout.message, of: fileURL, to: partial)
                try FileManager.default.moveItem(at: partial, to: kept)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        }
        onProgress?(0.5)
        let digest = try Self.digest(of: kept)
        let length = ((try FileManager.default.attributesOfItem(atPath: kept.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var (locator, headers, _) = try scanner.locate(fileURL: kept, messageRange: ByteRange(offset: 0, length: length))
        locator.sourceDigest = digest
        var imported = try build(locator: locator, headers: headers, senderEmail: senderEmail,
                                 retainAttachmentBytes: retainAttachmentBytes,
                                 materializeAttachments: materializeAttachments, reader: LocatorReader())
        EMLXParser.applyMetadata(plist: plist, fileURL: fileURL, to: &imported.email)
        if !imported.bodyWasDecoded { Self.classifyDirection(&imported.email, senderEmail: senderEmail) }
        onProgress?(1.0)
        try await onBatch([imported])
        return MBOXParser.ParseRecoveryReport(totalMessages: 1, successfullyParsed: 1, failed: 0, errorCategories: [:])
    }

    /// Copies `range` of `source` to `destination` in slices; a slice of zero
    /// bytes is left as a hole (the file system reads it back as zeros).
    static func copyRange(_ range: ByteRange, of source: URL, to destination: URL, sliceBytes: Int = 4 << 20) throws {
        let input = try FileRandomAccessSource(url: source)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = FileHandle(forWritingAtPath: destination.path) else {
            throw LocatorReadError.ioError("cannot write \(destination.lastPathComponent)")
        }
        defer { try? output.close() }
        let zeros = Data(count: sliceBytes)
        var done: Int64 = 0
        while done < range.length {
            try Task.checkCancellation()
            let count = Int(min(Int64(sliceBytes), range.length - done))
            let slice = try input.read(at: range.offset + done, count: count)
            guard slice.count == count else {
                throw LocatorReadError.ioError("\(source.lastPathComponent) ended \(range.length - done) bytes early")
            }
            try autoreleasepool {
                if slice == (count == sliceBytes ? zeros : Data(count: count)) {
                    try output.seek(toOffset: UInt64(done + Int64(count)))
                } else {
                    try output.seek(toOffset: UInt64(done))
                    try output.write(contentsOf: slice)
                }
            }
            done += Int64(count)
        }
        try output.truncate(atOffset: UInt64(range.length))
        try output.synchronize()
    }
}

extension ParserFactory {

    struct LibraryMailboxCounts {
        var total = 0
        var parsed = 0
        var failed = 0
        var categories: [String: Int] = [:]
    }

    /// One mailbox folder of an Apple Mail library with the offset engine on:
    /// the same files in the same order as `EMLXParser.parseWithReport`, read
    /// one at a time — an .emlx above the full-parse ceiling by range through
    /// `route`, the rest whole, handed on in batches of `batchSize`.
    static func parseLibraryMailbox(
        _ member: URL, root: URL, folder: String?, senderEmail: String, batchSize: Int,
        route: LargeMessageRoute, onProgress: ((Double) -> Void)?,
        onBatch: ([MBOXParser.RawEmail]) async throws -> Void
    ) async throws -> LibraryMailboxCounts {
        let files: [URL]
        if member.pathExtension.lowercased() == "emlx" {
            files = [member]
        } else {
            files = try FileManager.default.contentsOfDirectory(at: member, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "emlx" }
            guard !files.isEmpty else { throw EMLXParser.EMLXError.noEmailsFound }
        }
        var counts = LibraryMailboxCounts()
        var buffer: [MBOXParser.RawEmail] = []
        func flush() async throws {
            guard !buffer.isEmpty else { return }
            let batch = buffer
            buffer.removeAll(keepingCapacity: true)
            try await onBatch(stamp(batch, folder: folder))
        }
        func damaged() {
            counts.failed += 1
            counts.categories["emlx_damaged", default: 0] += 1
        }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            counts.total += 1
            if route.kind(of: file) == .emlx {
                try await flush()   // the order the files are in is the order handed on
                do {
                    let report = try await route.importMessage(
                        file, kind: .emlx, transient: false, keepIn: route.libraryDirectory(member: file, root: root),
                        senderEmail: senderEmail, folder: folder, onProgress: nil)
                    counts.parsed += report.successfullyParsed
                    counts.failed += report.failed
                } catch is EMLXParser.EMLXError {
                    damaged()
                } catch is ExtractionError {
                    damaged()
                }
            } else {
                do {
                    buffer.append(try EMLXParser.parseSingleEMLX(fileURL: file, senderEmail: senderEmail))
                    counts.parsed += 1
                } catch is WholeMessageReadRefusal {
                    counts.categories[WholeMessageReadLimit.category, default: 0] += 1
                } catch {
                    damaged()
                }
                if buffer.count >= max(1, batchSize) { try await flush() }
            }
            onProgress?(Double(index + 1) / Double(files.count))
        }
        try await flush()
        return counts
    }
}
