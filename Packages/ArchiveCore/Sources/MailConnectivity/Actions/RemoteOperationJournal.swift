//
//  RemoteOperationJournal.swift
//  MailConnectivity
//
//  Plan v4 V4-11: the server-action journal on disk, owner-only, beside the
//  outbox:
//
//      <store>/ConnectedServerActions/            0700
//          operations/<operation UUID>.json        0600  (atomically replaced)
//          receipts/<plan UUID>.json               0600  (cleanup receipts)
//
//  Every record is written with the same write → F_FULLFSYNC → rename →
//  folder-flush sequence as `DraftStore` / `OutboxStore`, so a process killed
//  at any instant leaves the previous record or the new one. A failed write
//  is thrown: an operation whose `executing` state could not be persisted is
//  never sent.
//

import Foundation

public enum RemoteOperationJournalError: LocalizedError, Equatable {
    case io(String)
    case corrupt(String)
    case notFound(UUID)
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .io(let why): return "The server-action journal could not be written: \(why)"
        case .corrupt(let why): return "A server-action record could not be read: \(why)"
        case .notFound(let id): return "No server action \(id.uuidString)."
        case .newerFormat(let v): return "A server action was saved by a newer mailin (format \(v))."
        }
    }
}

public actor RemoteOperationJournal {
    public static let folderName = "ConnectedServerActions"
    public nonisolated let root: URL
    nonisolated var operationsFolder: URL { root.appendingPathComponent("operations", isDirectory: true) }
    nonisolated var receiptsFolder: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    /// Tests only: the next `failingWrites` record writes fail.
    private var failingWrites = 0

    public init(storeDirectory: URL) throws {
        root = storeDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        do {
            try DraftStore.makeProtectedDirectory(root)
            try DraftStore.makeProtectedDirectory(root.appendingPathComponent("operations", isDirectory: true))
            try DraftStore.makeProtectedDirectory(root.appendingPathComponent("receipts", isDirectory: true))
        } catch { throw RemoteOperationJournalError.io(error.localizedDescription) }
        DraftStore.sweepTemporaryFiles(under: root)
    }

    func injectWriteFailures(_ count: Int) { failingWrites = count }

    nonisolated func file(_ id: UUID) -> URL { operationsFolder.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ operation: RemoteOperation) throws {
        if failingWrites > 0 { failingWrites -= 1; throw RemoteOperationJournalError.io("simulated write failure") }
        try write(Self.encode(operation), to: file(operation.id))
    }

    public func load(_ id: UUID) throws -> RemoteOperation {
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RemoteOperationJournalError.notFound(id) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw RemoteOperationJournalError.io(error.localizedDescription) }
        let op: RemoteOperation
        do { op = try Self.decoder.decode(RemoteOperation.self, from: data) } catch {
            throw RemoteOperationJournalError.corrupt("\(id.uuidString): \(error.localizedDescription)")
        }
        guard op.formatVersion <= RemoteOperation.formatVersion else { throw RemoteOperationJournalError.newerFormat(op.formatVersion) }
        guard op.id == id else { throw RemoteOperationJournalError.corrupt("\(id.uuidString) holds \(op.id.uuidString)") }
        return op
    }

    /// Every journalled operation (oldest first); unreadable records are
    /// listed with their reason, never hidden.
    public func all() -> (operations: [RemoteOperation], unreadable: [(id: String, reason: String)]) {
        DraftStore.sweepTemporaryFiles(under: root)
        var ops: [RemoteOperation] = []
        var bad: [(String, String)] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: operationsFolder, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
            do { ops.append(try load(id)) } catch { bad.append((id.uuidString, error.localizedDescription)) }
        }
        ops.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return (ops, bad.map { (id: $0.0, reason: $0.1) })
    }

    /// Operations a killed process left planned or executing: the app calls
    /// `RemoteActionService.execute` on each at launch to reconcile them.
    public func unfinished() -> [RemoteOperation] { all().operations.filter { !$0.isFinished } }

    // MARK: Receipts

    public func saveReceipt(_ receipt: CleanupReceipt) throws {
        try write(Self.encode(receipt), to: receiptsFolder.appendingPathComponent("\(receipt.planID.uuidString).json"))
    }

    public func receipt(planID: UUID) throws -> CleanupReceipt? {
        let url = receiptsFolder.appendingPathComponent("\(planID.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try Self.decoder.decode(CleanupReceipt.self, from: data) } catch {
            throw RemoteOperationJournalError.corrupt("receipt \(planID.uuidString): \(error.localizedDescription)")
        }
    }

    // MARK: Primitives

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        do { return try encoder.encode(value) } catch { throw RemoteOperationJournalError.io(error.localizedDescription) }
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func write(_ data: Data, to url: URL) throws {
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
            throw RemoteOperationJournalError.io(error.localizedDescription)
        }
    }
}
