//
//  ContainerMailboxWalk.swift
//  ArchiveCore
//
//  CLOSE-02 (v4.0 plan §8.1, 2026-11-09): durable recursive mailbox intake
//  inside containers. Distinct from the attachment-extraction Resume rounds:
//  this is the IMPORT SOURCE walk — a ZIP, gzip, tar, 7z or RAR picked as a
//  source, and every archive inside it, at any depth.
//
//  Before: one level of nesting was followed (a `.tgz`, a `.mbox.gz` inside a
//  ZIP); a mailbox inside an archive inside an archive was skipped and counted
//  (`container_nested_skipped`). Now:
//
//   • Every level is opened. A member is extracted to the scratch folder of
//     its level, classified on its own bytes, and either parsed (a mailbox),
//     descended into (an archive), or counted (not mail, refused with its
//     reason). Scratch space is bounded by ONE member per level on the path
//     currently open, and each level's folder is removed when it is done.
//   • Folders come from every level by the IPAD-01 rules
//     (`SourceFormatClassifier.containerFolderPath`): an archive inside an
//     archive adds the folders it sits in (that level's wrapper stripped,
//     `.mbox` packages named as mailboxes) in front of the folders its own
//     members get. A member that gets no folder by the rules keeps what its
//     own parser gives, at any level — exactly as at the first level.
//   • The one guard is against self-containing data, and it is named:
//     an archive whose bytes equal an archive it sits inside is skipped and
//     counted (`container_cycle_skipped`), and so is an archive more than
//     `selfContainingGuardDepth` archives deep (`container_nesting_guard_skipped`)
//     — real exports never nest that deep; archives built to unpack into
//     themselves do.
//   • Unsafe member paths (absolute, drive letter, `..`) are refused before a
//     byte is extracted, for every format — the folder path is built from the
//     name, so such a name must never become a folder.
//   • Every refusal is counted in `container_member_refused` and, beside it,
//     by its reason (`reason:encrypted`, `reason:volume missing`,
//     `reason:unsafe path`, `reason:not enough scratch space`,
//     `reason:damaged or not opened`).
//   • The walk is checkpointed: after each finished member it hands out a
//     `ContainerWalkCursor` — the member's index path through the levels, the
//     messages handed on so far (the ordinal the import checkpoint counts) and
//     the report so far. A resumed walk starts after that member without
//     extracting the members before it, and its ordinals continue exactly from
//     the cursor, so the import checkpoint (SHA-256 / size / parser bound)
//     skips only what is committed: no omission, no duplicate.
//

import Foundation
import CryptoKit
import os

/// Where an interrupted container walk stands. Persisted beside the import
/// checkpoint (`ImportCheckpointStore`), bound to the same source identity.
struct ContainerWalkCursor: Codable, Sendable, Equatable {
    /// Bump when the walk's order or counting changes: a cursor written by
    /// another walk version is never resumed from.
    static let walkVersion = 1

    var walkVersion: Int = Self.walkVersion
    /// Index of the last FINISHED member at each level, outermost first. A
    /// path ending inside a nested archive means the members of that archive
    /// up to there are done; the archive itself is not.
    var memberPath: [Int]
    /// Member names along `memberPath` — checked on resume.
    var memberNames: [String]
    /// Messages handed to the batch callback up to and including that member
    /// (the parsed-message ordinal the import checkpoint counts).
    var messagesEmitted: Int
    // The report so far, so a resumed import still reports the whole source.
    var totalMessages: Int
    var parsed: Int
    var failed: Int
    var categories: [String: Int]
    var declaredFolders: [String]
    var sawMail: Bool
}

enum ContainerWalkError: Error, LocalizedError, Equatable {
    /// The archive no longer lists what the cursor names — never expected for
    /// identical bytes and reader versions; the cursor is dropped and the next
    /// import walks the source from its first member.
    case cursorMismatch(String)

    var errorDescription: String? {
        switch self {
        case .cursorMismatch(let detail):
            return "The saved place in this archive no longer matches it (\(detail)). Import it again: it is read from the start and only messages not yet in the archive are added."
        }
    }
}

/// The depth-first walk over a container source and every container in it.
/// Not thread-safe: one walk belongs to one import task.
final class ContainerMailboxWalk {

    /// Archives deeper than this are treated as built to loop (a ZIP quine
    /// unpacks into itself forever); they are skipped and counted, never
    /// silently. Not a limit on real exports — none nests this deep.
    static let selfContainingGuardDepth = 32

    /// Test seam: called with the member index path each time a member is
    /// extracted, so a test can prove a resumed walk does not re-read
    /// finished members.
    nonisolated(unsafe) static var extractionObserver: (([Int], String, URL) -> Void)?

    enum Event {
        /// A mailbox member extracted to `url`. The consumer parses it; the
        /// member is finished once the consumer calls `next()` again.
        case mailbox(url: URL, folder: String?, path: [Int], names: [String])
        /// A member finished without messages (counted, or a nested archive
        /// whose members are all done).
        case finished(path: [Int], names: [String], nestedArchive: Bool)
    }

    private struct Level {
        var url: URL
        var steps: [ParserFactory.ContainerStep]
        var wrapper: String?
        var prefix: [String]
        var path: [Int]
        var names: [String]
        var next = 0
        var resumeTail: [Int]?
        var scratch: URL?
        var sizeBytes: Int64
        var digest: String?
    }

    private static let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "ContainerWalk")

    private var stack: [Level] = []
    private var pendingLeaf: URL?
    private let resumeNames: [String]
    let topLevelCount: Int

    // The running report; the consumer adds its parsers' results here too.
    var categories: [String: Int] = [:]
    var declaredFolders = Set<String>()
    var sawMail = false

    /// Opens the top level. Reader errors on the source itself throw, as before.
    init(root url: URL, format: SourceFormat, resume: ContainerWalkCursor? = nil) throws {
        let listing = try ParserFactory.containerListing(url, format: format)
        let wrapper = listing.wrapper
        topLevelCount = listing.steps.count
        resumeNames = resume?.memberNames ?? []
        if let resume {
            categories = resume.categories
            declaredFolders = Set(resume.declaredFolders)
            sawMail = resume.sawMail
        }
        declaredFolders.formUnion(listing.declaredFolders(wrapper: wrapper))
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
        stack = [Level(url: url, steps: listing.steps, wrapper: wrapper, prefix: [], path: [], names: [],
                       resumeTail: resume.map(\.memberPath), sizeBytes: size)]
    }

    deinit { close() }

    /// Removes every scratch folder still open (cancellation, error).
    func close() {
        if let pendingLeaf { try? FileManager.default.removeItem(at: pendingLeaf) }
        pendingLeaf = nil
        for level in stack.reversed() {
            if let scratch = level.scratch { try? FileManager.default.removeItem(at: scratch) }
        }
        stack.removeAll()
    }

    /// The share of the top level's members started so far.
    var topLevelFraction: Double {
        guard let first = stack.first, topLevelCount > 0 else { return 1 }
        return Double(max(0, first.next - 1)) / Double(topLevelCount)
    }

    /// The next mailbox to parse or member finished, or nil when the walk is done.
    func next() throws -> Event? {
        if let pendingLeaf { try? FileManager.default.removeItem(at: pendingLeaf) }
        pendingLeaf = nil
        let fm = FileManager.default

        while !stack.isEmpty {
            let depth = stack.count - 1
            if stack[depth].next >= stack[depth].steps.count {
                // This level is done: its scratch goes, and the archive file it
                // was read from (a member in the parent's scratch) goes too.
                let done = stack.removeLast()
                if let scratch = done.scratch { try? fm.removeItem(at: scratch) }
                if !stack.isEmpty {
                    try? fm.removeItem(at: done.url)
                    return .finished(path: done.path, names: done.names, nestedArchive: true)
                }
                return nil
            }
            let index = stack[depth].next
            stack[depth].next += 1
            let step = stack[depth].steps[index]
            let path = stack[depth].path + [index]
            let names = stack[depth].names + [step.name]

            // Resume: members before the cursor are finished and not extracted.
            var descendTail: [Int]? = nil
            if let tail = stack[depth].resumeTail, let first = tail.first {
                if index < first { continue }
                stack[depth].resumeTail = nil
                if index == first {
                    let expected = path.count - 1 < resumeNames.count ? resumeNames[path.count - 1] : nil
                    if let expected, expected != step.name {
                        throw ContainerWalkError.cursorMismatch("member \(index + 1) is “\(step.name)”, the saved place names “\(expected)”")
                    }
                    if tail.count == 1 { continue }
                    descendTail = Array(tail.dropFirst())
                }
            }

            if let reason = SevenZipReader.unsafePathReason(step.name) {
                refuse(step.name, reason: "unsafe path", detail: reason)
                if descendTail != nil { throw ContainerWalkError.cursorMismatch("“\(step.name)” is no longer an archive") }
                return .finished(path: path, names: names, nestedArchive: false)
            }

            let scratch = try scratchFolder(depth)
            let dest = scratch.appendingPathComponent("\(index)-\(ParserFactory.safeMemberFileName(step.name))")
            Self.extractionObserver?(path, step.name, dest)
            let outcome = try ParserFactory.extractAndClassify(step, to: dest)
            switch outcome {
            case .refused(let reason, let detail):
                refuse(step.name, reason: reason, detail: detail)
                if descendTail != nil { throw ContainerWalkError.cursorMismatch("“\(step.name)” could not be read again") }
                return .finished(path: path, names: names, nestedArchive: false)
            case .notMail:
                try? fm.removeItem(at: dest)
                categories["container_member_not_mail", default: 0] += 1
                if descendTail != nil { throw ContainerWalkError.cursorMismatch("“\(step.name)” is no longer an archive") }
                return .finished(path: path, names: names, nestedArchive: false)
            case .mail:
                if descendTail != nil { throw ContainerWalkError.cursorMismatch("“\(step.name)” is no longer an archive") }
                sawMail = true
                let level = stack[depth]
                let own = SourceFormatClassifier.containerFolderPath(memberName: step.name, wrapper: level.wrapper)
                let folder = own.map { Self.compose(level.prefix, $0) }
                if let folder { declaredFolders.insert(folder) }
                pendingLeaf = dest
                return .mailbox(url: dest, folder: folder, path: path, names: names)
            case .container(let format):
                if let skip = try guardSkip(dest, depth: depth) {
                    try? fm.removeItem(at: dest)
                    categories[skip, default: 0] += 1
                    Self.log.notice("nested archive skipped (\(skip, privacy: .public)): \(step.name, privacy: .private)")
                    if descendTail != nil { throw ContainerWalkError.cursorMismatch("“\(step.name)” is now skipped") }
                    return .finished(path: path, names: names, nestedArchive: true)
                }
                let listing: ParserFactory.ContainerListing
                do {
                    listing = try ParserFactory.containerListing(dest, format: format)
                } catch where ParserFactory.isReaderRefusal(error) {
                    // An inner archive that will not open is a refused member, not a failed import.
                    try? fm.removeItem(at: dest)
                    let (reason, detail) = ParserFactory.refusalReason(error)
                    refuse(step.name, reason: reason, detail: detail)
                    if descendTail != nil { throw ContainerWalkError.cursorMismatch("“\(step.name)” could not be opened again") }
                    return .finished(path: path, names: names, nestedArchive: true)
                }
                let parent = stack[depth]
                let prefix = parent.prefix + SourceFormatClassifier.nestedContainerFolderPrefix(memberName: step.name, wrapper: parent.wrapper)
                let wrapper = listing.wrapper
                for declared in listing.declaredFolders(wrapper: wrapper) { declaredFolders.insert(Self.compose(prefix, declared)) }
                let size = ((try? fm.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber)?.int64Value ?? -1
                stack.append(Level(url: dest, steps: listing.steps, wrapper: wrapper, prefix: prefix,
                                   path: path, names: names, resumeTail: descendTail, sizeBytes: size))
                continue
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func compose(_ prefix: [String], _ folder: String) -> String {
        prefix.isEmpty ? folder : (prefix + [folder]).joined(separator: "/")
    }

    /// A member the consumer could not take (the previous engine's
    /// whole-read ceiling): counted as refused, with its reason.
    func refuseMember(_ name: String, reason: String, detail: String) {
        refuse(name, reason: reason, detail: detail)
    }

    private func refuse(_ name: String, reason: String, detail: String) {
        categories["container_member_refused", default: 0] += 1
        categories["reason:\(reason)", default: 0] += 1
        Self.log.error("container member refused (\(reason, privacy: .public)): \(detail, privacy: .private)")
    }

    private func scratchFolder(_ depth: Int) throws -> URL {
        if let existing = stack[depth].scratch { return existing }
        let made = try ParserFactory.containerScratchDirectory()
        stack[depth].scratch = made
        return made
    }

    /// The self-containing guard: a category to count the archive under, or
    /// nil to open it. Equal bytes to an archive above it is a loop; more than
    /// `selfContainingGuardDepth` archives deep is treated as one.
    private func guardSkip(_ archive: URL, depth: Int) throws -> String? {
        if stack.count >= Self.selfContainingGuardDepth { return "container_nesting_guard_skipped" }
        let size = ((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?.int64Value ?? -2
        // Only an ancestor of the same size can hold the same bytes; hash only then.
        guard stack.contains(where: { $0.sizeBytes == size }) else { return nil }
        let digest = try Self.sha256(archive)
        for i in stack.indices where stack[i].sizeBytes == size {
            if stack[i].digest == nil { stack[i].digest = try Self.sha256(stack[i].url) }
            if stack[i].digest == digest { return "container_cycle_skipped" }
        }
        return nil
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ParserFactory {

    /// What one extracted member is, with the reason when it was refused.
    enum MemberOutcome: Equatable {
        case mail
        case notMail
        case container(SourceFormat)
        /// `reason` is a short fixed label counted on the report; `detail` is logged.
        case refused(reason: String, detail: String)
    }

    /// Extracts one member and classifies it on its bytes. The scratch file is
    /// removed on anything but `.mail` / `.container`.
    /// A reader's own refusal (encrypted, damaged, missing volume, no scratch
    /// space) is an outcome; any other error (the file system failing) throws,
    /// as before — it is not a property of the member.
    static func extractAndClassify(_ step: ContainerStep, to dest: URL) throws -> MemberOutcome {
        do {
            try step.extract(dest)
        } catch where isReaderRefusal(error) {
            try? FileManager.default.removeItem(at: dest)
            let (reason, detail) = refusalReason(error)
            return .refused(reason: reason, detail: detail)
        }
        let inner = SourceFormatClassifier.classify(url: dest)
        if inner.format.isContainer { return .container(inner.format) }
        guard inner.isSupported else {
            try? FileManager.default.removeItem(at: dest)
            return .notMail
        }
        return .mail
    }

    static func isReaderRefusal(_ error: Error) -> Bool {
        error is ZIPArchiveReader.ReadError || error is TARReader.ReadError || error is SevenZipReader.ReadError
            || error is RARReader.ReadError || error is SplitVolumeError
    }

    /// The counted reason for a member that could not be extracted or opened.
    static func refusalReason(_ error: Error) -> (reason: String, detail: String) {
        let detail = String(describing: error)
        switch error {
        case let e as ZIPArchiveReader.ReadError:
            switch e {
            case .encrypted, .wrongPassword: return ("encrypted", detail)
            case .insufficientDisk: return ("not enough scratch space", detail)
            default: return ("damaged or not opened", detail)
            }
        case let e as TARReader.ReadError:
            if case .insufficientDisk = e { return ("not enough scratch space", detail) }
            return ("damaged or not opened", detail)
        case let e as SevenZipReader.ReadError:
            switch e {
            case .encrypted, .wrongPassword: return ("encrypted", detail)
            case .unsafePath: return ("unsafe path", detail)
            default: return ("damaged or not opened", detail)
            }
        case let e as RARReader.ReadError:
            switch e {
            case .encrypted, .encryptedHeaders: return ("encrypted", detail)
            case .unsafePath: return ("unsafe path", detail)
            default: return ("damaged or not opened", detail)
            }
        case let e as SplitVolumeError:
            if case .volumeMissing = e { return ("volume missing", detail) }
            return ("damaged or not opened", detail)
        default:
            return ("damaged or not opened", detail)
        }
    }
}

extension SourceFormatClassifier {
    /// CLOSE-02: the folders an archive inside an archive sits in, as path
    /// components — its directory in the outer archive, the outer wrapper
    /// stripped, `.mbox` packages named as mailboxes. Put in front of the
    /// folders its own members get by `containerFolderPath`.
    static func nestedContainerFolderPrefix(memberName: String, wrapper: String?) -> [String] {
        var dirs = memberName.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        _ = dirs.popLast()
        if let wrapper, dirs.first == wrapper { dirs.removeFirst() }
        if dirs.contains(where: { $0.lowercased().hasSuffix(".mbox") }) { return mailboxPathComponents(dirs) }
        if let index = dirs.firstIndex(where: { maildirInternalNames.contains($0) }) { return Array(dirs[..<index]) }
        return dirs
    }
}
