//
//  V2Protocols.swift
//  maxmailin
//
//  Protocol-based abstractions for the v2 storage / search / parsing pipeline.
//  Each concrete type (EmailStore, FTSSearchIndex, ParserFactory) is also a
//  conformer, so tests can substitute in-memory fakes without changing the
//  consuming code.
//

import Foundation

// MARK: - Persistence

protocol PersistenceStoreProtocol: Sendable {
    func totalCount() async throws -> Int
    func page(offset: Int, limit: Int) async throws -> [MBOXParser.RawEmail]
    func fullEmail(id: UUID) async throws -> MBOXParser.RawEmail?
    func insert(
        _ email: MBOXParser.RawEmail,
        sourceFileHash: String?,
        accountID: String?
    ) async throws
    func clearAll() async throws
}

extension EmailStore: PersistenceStoreProtocol {}

// MARK: - Search

protocol SearchIndexProtocol: Sendable {
    func index(_ email: MBOXParser.RawEmail) async throws
    func search(_ query: String, limit: Int) async throws -> [UUID]
    func clear() async throws
    func rowCount() async throws -> Int
}

extension FTSSearchIndex: SearchIndexProtocol {}

// MARK: - Parsing

protocol EmailParserProtocol {
    /// Parse the file at `fileURL` into a stream of RawEmail entries.
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)?
    ) throws -> [MBOXParser.RawEmail]
}

// ParserFactory will become a conformer once it stops being a static-only
// type — for now, callers can use this protocol as a type-erased boundary
// when injecting a mock parser into tests.

// MARK: - Audit log

protocol AuditLogProtocol {
    func recordEvent(action: String, detail: String) throws
    func verifyChain() -> Bool
}

extension HMACChainAuditLog: AuditLogProtocol {
    func recordEvent(action: String, detail: String) throws {
        _ = try self.append(action: action, detail: detail)
    }
}

// MARK: - Export signing

protocol ExportSignerProtocol {
    func sign(_ data: Data) throws -> Data
    func signFile(_ url: URL) throws -> URL
    func publicKeyBytes() throws -> Data
    func verify(_ data: Data, signature: Data, publicKey: Data) -> Bool
}

extension ExportSigner: ExportSignerProtocol {}
