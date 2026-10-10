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
