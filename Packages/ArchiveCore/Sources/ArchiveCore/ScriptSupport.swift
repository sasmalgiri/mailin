//
//  ScriptSupport.swift
//  ArchiveCore
//
//  3.1 S6 `email.ai` and T8: the analysis the archive already stored for an
//  email (classification, sentiment, priority, phishing, topic, predictive
//  score). Read only — nothing is computed here.
//

import Foundation
import SQLite3

public struct StoredAnalysis: Sendable, Equatable {
    public var classification: String?
    public var sentiment: Double?
    public var priority: Int?
    public var phishing: Bool?
    public var topic: String?
    /// Predictive-coding relevance score 0…1 (nil = not scored).
    public var predictive: Double?

    public var dictionary: [String: Any] {
        var d: [String: Any] = [:]
        if let classification { d["classification"] = classification }
        if let sentiment { d["sentiment"] = sentiment }
        if let priority { d["priority"] = priority }
        if let phishing { d["phishing"] = phishing }
        if let topic { d["topic"] = topic }
        if let predictive { d["predictive"] = predictive }
        return d
    }
}

extension SQLiteEmailStore {
    public func storedAnalysis(for ids: [UUID]) throws -> [UUID: StoredAnalysis] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: StoredAnalysis] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, classification, sentiment, priority, phishing, topic, predictive FROM derived WHERE email_id IN (\(marks));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                func null(_ c: Int32) -> Bool { sqlite3_column_type(stmt, c) == SQLITE_NULL }
                out[id] = StoredAnalysis(
                    classification: null(1) ? nil : columnText(stmt, 1),
                    sentiment: null(2) ? nil : Double(columnText(stmt, 2)),
                    priority: null(3) ? nil : Int(sqlite3_column_int64(stmt, 3)),
                    phishing: null(4) ? nil : sqlite3_column_int(stmt, 4) != 0,
                    topic: null(5) ? nil : columnText(stmt, 5),
                    predictive: null(6) ? nil : sqlite3_column_double(stmt, 6))
            }
        }
        return out
    }
}
