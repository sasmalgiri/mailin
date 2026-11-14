@testable import ArchiveCore
//
//  ReviewWorkspaceStore.swift
//  maxmailin
//
//  Durable state for the review workspaces (Legal Review, Journalist). Their
//  coding decisions used to live only in view @State, so closing the window
//  threw away every privilege call, issue tag, lead and quote. Each workspace
//  now saves a Codable snapshot to Application Support (file protection on)
//  and reloads it when it opens.
//

import Foundation

enum ReviewWorkspaceStore {
    private static var directory: URL {
        if let root = ScopeJobEnvironment.current?.root {
            return root.appendingPathComponent("ReviewWorkspaces", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReviewWorkspaces", isDirectory: true)
    }

    static func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// §3-F4: the database copy of a workspace (the second copy of its file).
    /// Used to recover a workspace whose file is missing.
    static func loadFromDatabase<T: Decodable>(_ type: T.Type, name: String) async -> T? {
        guard let data = try? await ScopeJobEnvironment.store.workspaceLoad(name: name) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Database writes in the order the saves happened (a later save can
    /// never be overtaken by an earlier one).
    @MainActor private static var mirrorChain: Task<Void, Never>?

    /// §3-F4 dual-write: with the legal-data engine on, the snapshot also
    /// goes to the archive database, and Legal Review's per-email coding is
    /// projected into `review_coding` so it can be counted across the archive.
    /// The file stays the first copy (rule 16).
    @MainActor
    static func mirrorToDatabase(_ data: Data, name: String, legal: LegalReviewSnapshot?) {
        guard ScopeJobEnvironment.legalMirror.isOn else { return }
        let previous = mirrorChain
        let store = ScopeJobEnvironment.store
        mirrorChain = Task { @MainActor in
            await previous?.value
            do {
                try await store.workspaceSave(name: name, json: data)
                if let legal {
                    try await store.reviewCodingReplace(workspace: "legal-review", field: "privilege", values: legal.privilege)
                    try await store.reviewCodingReplace(workspace: "legal-review", field: "responsiveness", values: legal.responsiveness)
                }
            } catch {
                EngineGuard.recordFallback(.v3LegalState, error: error)
            }
        }
    }

    /// Copies every existing workspace file into the database (when the
    /// legal-data engine is switched on). The files stay as they are.
    @MainActor
    static func mirrorExistingFiles() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        for name in names {
            guard let data = try? Data(contentsOf: url(for: name)) else { continue }
            let legal = name == LegalReviewSnapshot.fileName ? try? JSONDecoder().decode(LegalReviewSnapshot.self, from: data) : nil
            mirrorToDatabase(data, name: name, legal: legal)
        }
    }

    /// Waits for pending database writes (tests, and before reading them back).
    @MainActor static func flushDatabaseMirror() async { await mirrorChain?.value }

    /// Writes atomically with complete file protection. Returns the error so
    /// callers can surface a failed save instead of silently losing work.
    @discardableResult
    static func save<T: Encodable>(_ value: T, name: String) -> Error? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            #if os(iOS)
            try data.write(to: url(for: name), options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url(for: name), options: .atomic)
            #endif
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    mirrorToDatabase(data, name: name, legal: value as? LegalReviewSnapshot)
                }
            }
            return nil
        } catch {
            return error
        }
    }
}

/// Legal Review coding — keyed by email id, values are the designation raw values.
struct LegalReviewSnapshot: Codable, Equatable {
    struct AuditEntry: Codable, Equatable {
        var date: Date
        var emailID: UUID
        var field: String
        var oldValue: String
        var newValue: String
    }
    var privilege: [UUID: String] = [:]
    var responsiveness: [UUID: String] = [:]
    var issueTags: [UUID: [String]] = [:]
    var notes: [UUID: String] = [:]
    var definedIssueTags: [String]? = nil
    var audit: [AuditEntry] = []

    static let fileName = "legal-review"
}
