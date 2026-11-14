//
//  OutboxStore.swift
//  MailConnectivity
//
//  Plan v4 V4-10: the outbox on disk, owner-only, beside the drafts:
//
//      <store>/ConnectedOutbox/                 0700
//          <operation UUID>/                    0700
//              message.eml                      0600  (frozen MIME, written once)
//              operation.json                   0600  (the record, atomically replaced)
//
//  The message is published before the record that names it; the record is
//  replaced with the same write-flush-rename-flush sequence as `DraftStore`,
//  so a process killed at any instant leaves the previous record or the new
//  one. A folder holding a message but no record (a kill during enqueue) was
//  never queued and is reported, not sent.
//

import CryptoKit
import Foundation

public struct OutboxListing: Sendable {
    public var operations: [OutboxOperation]
    public var unreadable: [(id: String, reason: String)]
    /// Folders with a frozen message but no record: an enqueue killed half-way; never sent.
    public var incompleteEnqueues: Int
}

public actor OutboxStore {
    public static let folderName = "ConnectedOutbox"
    public nonisolated let root: URL
    /// Tests only: after `writesBeforeFailure` more successful record writes,
    /// the next `failingWrites` fail (a full or failing disk).
    private var writesBeforeFailure = 0
    private var failingWrites = 0

    public init(storeDirectory: URL) throws {
        root = storeDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        do { try DraftStore.makeProtectedDirectory(root) } catch { throw OutboxError.io(error.localizedDescription) }
        DraftStore.sweepTemporaryFiles(under: root)
    }

    func injectWriteFailures(_ count: Int, afterSuccessfulWrites skip: Int = 0) { failingWrites = count; writesBeforeFailure = skip }

    nonisolated func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    nonisolated func recordFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("operation.json") }
    nonisolated func messageFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("message.eml") }

    /// Freezes the message bytes (once) and saves the first record.
    func create(_ operation: OutboxOperation, message: Data) throws {
        try protectedDirectory(folder(operation.id))
        guard !FileManager.default.fileExists(atPath: messageFile(operation.id).path) else { throw OutboxError.alreadyQueued(operation.id) }
        try writeDurably(message, to: messageFile(operation.id))
        try save(operation)
    }

    func save(_ operation: OutboxOperation) throws {
        if failingWrites > 0 {
            if writesBeforeFailure > 0 { writesBeforeFailure -= 1 } else { failingWrites -= 1; throw OutboxError.io("simulated write failure") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data: Data
        do { data = try encoder.encode(operation) } catch { throw OutboxError.io(error.localizedDescription) }
        try writeDurably(data, to: recordFile(operation.id))
    }

    func load(_ id: UUID) throws -> OutboxOperation {
        let url = recordFile(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw OutboxError.notFound(id) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw OutboxError.io(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let op: OutboxOperation
        do { op = try decoder.decode(OutboxOperation.self, from: data) } catch { throw OutboxError.corrupt("\(id.uuidString): \(error.localizedDescription)") }
        guard op.formatVersion <= OutboxOperation.formatVersion else { throw OutboxError.newerFormat(op.formatVersion) }
        guard op.id == id else { throw OutboxError.corrupt("\(id.uuidString) holds \(op.id.uuidString)") }
        return op
    }

    /// The frozen bytes, verified against the recorded SHA-256 and size.
    func message(for op: OutboxOperation) throws -> Data {
        guard let data = try? Data(contentsOf: messageFile(op.id)) else { throw OutboxError.messageDamaged(op.id) }
        guard data.count == op.messageSize, DraftStore.hex(SHA256.hash(data: data)) == op.messageSHA256 else {
            throw OutboxError.messageDamaged(op.id)
        }
        return data
    }

    public func all() -> OutboxListing {
        DraftStore.sweepTemporaryFiles(under: root)
        var ops: [OutboxOperation] = []
        var unreadable: [(String, String)] = []
        var incomplete = 0
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for f in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: f.lastPathComponent) else { continue }
            do { ops.append(try load(id)) } catch OutboxError.notFound {
                incomplete += 1
            } catch {
                unreadable.append((id.uuidString, error.localizedDescription))
            }
        }
        ops.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return OutboxListing(operations: ops, unreadable: unreadable, incompleteEnqueues: incomplete)
    }

    /// Removes a finished or cancelled item (the user cleared it).
    func remove(_ id: UUID) throws {
        guard FileManager.default.fileExists(atPath: folder(id).path) else { return }
        do { try FileManager.default.removeItem(at: folder(id)) } catch { throw OutboxError.io(error.localizedDescription) }
    }

    // MARK: Primitives (shared with DraftStore)

    private func protectedDirectory(_ url: URL) throws {
        do { try DraftStore.makeProtectedDirectory(url) } catch { throw OutboxError.io(error.localizedDescription) }
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let handle = try DraftStore.createProtectedFile(tmp)
            do {
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                try DraftStore.flush(handle)
            }
            try DraftStore.publish(tmp, as: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw OutboxError.io(error.localizedDescription)
        }
    }
}
