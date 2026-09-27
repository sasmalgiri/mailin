@testable import ArchiveCore
//
//  SemanticIndex.swift
//  maxmailin
//
//  I4: an opt-in, resumable, on-device embedding index for Page 2.
//
//  What it stores: one sentence vector per message (NLEmbedding, English,
//  over subject + body preview) in its own SQLite file under the archive
//  root (`<root>/embeddings/embeddings.db`), keyed by email id. The job
//  walks the archive by keyset page and persists its cursor after every
//  page, so it resumes from where it stopped after a pause, a relaunch or a
//  page being switched off. Nothing here talks to a model or a network.
//
//  Prompt-injection rule (plan I4): text from messages is DATA to embed —
//  it is never concatenated into an instruction. The only consumer is
//  `neighbors(of:)`, which returns ids for the retrieval layer; the
//  retrieval layer already delimits evidence as untrusted data.
//

import Foundation
import NaturalLanguage
import SQLite3
import Observation

// MARK: - Store

actor EmbeddingStore {
    static let dimensions = 512
    private let url: URL
    private var db: OpaquePointer?

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("embeddings.db")
    }

    private func handle() throws -> OpaquePointer {
        if let db { return db }
        var h: OpaquePointer?
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            throw EmbeddingError.open(url.path)
        }
        db = h
        try exec("PRAGMA journal_mode = WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS vectors(
                email_id TEXT PRIMARY KEY,
                dims INTEGER NOT NULL,
                vector BLOB NOT NULL,
                indexed_at INTEGER NOT NULL
            );
        """)
        try exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        return h
    }

    private func exec(_ sql: String) throws {
        guard let db else { return }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EmbeddingError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    func count() throws -> Int {
        let db = try handle()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM vectors;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func meta(_ key: String) throws -> String? {
        let db = try handle()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func setMeta(_ key: String, _ value: String?) throws {
        let db = try handle()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if let value {
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            guard sqlite3_prepare_v2(db, "DELETE FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_step(stmt)
    }

    /// One transaction per page.
    func upsert(_ rows: [(id: UUID, vector: [Float])]) throws {
        let db = try handle()
        try exec("BEGIN;")
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO vectors(email_id, dims, vector, indexed_at) VALUES(?, ?, ?, ?);", -1, &stmt, nil) == SQLITE_OK else {
            try exec("ROLLBACK;"); throw EmbeddingError.sql(String(cString: sqlite3_errmsg(db)))
        }
        let now = Int64(Date().timeIntervalSince1970)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(row.vector.count))
            row.vector.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_int64(stmt, 4, now)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                try exec("ROLLBACK;"); throw EmbeddingError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
        try exec("COMMIT;")
    }

    /// Brute-force cosine over the stored vectors, one bounded page of rows
    /// at a time — never the whole table in memory. Fine to tens of
    /// thousands of messages; an ANN structure is the 3.1 follow-up.
    func neighbors(of query: [Float], limit: Int) throws -> [(id: UUID, score: Float)] {
        let db = try handle()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT email_id, vector FROM vectors;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        let qNorm = sqrt(query.reduce(0) { $0 + $1 * $1 })
        guard qNorm > 0 else { return [] }
        var best: [(UUID, Float)] = []
        best.reserveCapacity(limit + 1)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: idText)),
                  let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let bytes = Int(sqlite3_column_bytes(stmt, 1))
            let count = bytes / MemoryLayout<Float>.size
            guard count == query.count else { continue }
            let vector = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count)
            var dot: Float = 0, norm: Float = 0
            for i in 0..<count { dot += vector[i] * query[i]; norm += vector[i] * vector[i] }
            guard norm > 0 else { continue }
            let score = dot / (sqrt(norm) * qNorm)
            if best.count < limit {
                best.append((id, score)); best.sort { $0.1 > $1.1 }
            } else if score > best[best.count - 1].1 {
                best[best.count - 1] = (id, score); best.sort { $0.1 > $1.1 }
            }
        }
        return best.map { (id: $0.0, score: $0.1) }
    }

    func deleteAll() throws {
        try exec("DELETE FROM vectors;")
        try exec("DELETE FROM meta;")
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }
}

enum EmbeddingError: LocalizedError {
    case open(String)
    case sql(String)
    case modelUnavailable
    var errorDescription: String? {
        switch self {
        case .open(let path): return "Could not open the semantic index at \(path)."
        case .sql(let message): return "Semantic index error: \(message)"
        case .modelUnavailable: return "The on-device sentence model is not available for English on this Mac."
        }
    }
}

// MARK: - Embedding

enum SentenceEmbedder {
    /// English sentence embedding, on device. nil when the OS has no model.
    static func embed(_ text: String) -> [Float]? {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        let trimmed = String(text.prefix(2_000))
        guard let vector = model.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }

    /// What is embedded per message: subject + preview, as DATA.
    static func text(for summary: EmailSummary) -> String {
        (summary.subject + ". " + summary.bodyPreview).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Controller (page-owned, resumable)

@MainActor
@Observable
final class SemanticIndexController {
    static let shared = SemanticIndexController()
    static let enabledKey = "semanticIndexEnabled"
    static let cursorDateKey = "cursor.date"
    static let cursorIDKey = "cursor.id"
    static let pageSize = 200

    private(set) var isRunning = false
    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var lastError: String?
    private var task: Task<Void, Never>?

    private let archive: ArchiveDataService
    private let store: EmbeddingStore

    init(archive: ArchiveDataService = .shared,
         store: EmbeddingStore = EmbeddingStore(directory: ArchiveLayout.embeddingsDirectory(under: ArchiveLayout.productionRoot))) {
        self.archive = archive
        self.store = store
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var pending: Int { max(0, total - indexed) }
    var fraction: Double { total > 0 ? Double(indexed) / Double(total) : 0 }
    var statusLine: String {
        if let lastError { return "Stopped: \(lastError)" }
        if isRunning { return "Indexing \(indexed.formatted()) of \(total.formatted())" }
        if pending > 0 { return "\(indexed.formatted()) indexed, \(pending.formatted()) to go (paused)" }
        return total > 0 ? "Complete — \(indexed.formatted()) messages" : "Nothing indexed yet"
    }

    func setEnabled(_ on: Bool, modules: ModuleRegistry) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { resume(modules: modules) } else { pause() }
    }

    /// Launch hook and Resume button. Runs only with Page 2 on and the
    /// switch on; registers itself as a Page-2 job.
    func resume(modules: ModuleRegistry) {
        guard isEnabled, modules.isEnabled(.aiInsights), modules.isOn(.aiAssistant), task == nil else { return }
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else {
            lastError = EmbeddingError.modelUnavailable.localizedDescription
            return
        }
        lastError = nil
        isRunning = true
        modules.jobs.register(id: "semantic.index", module: .aiInsights, label: "Semantic index",
                              cancel: { [weak self] in self?.pause() })
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            await MainActor.run {
                self.isRunning = false
                self.task = nil
                modules.jobs.finish(id: "semantic.index")
            }
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func deleteIndex() {
        pause()
        Task { try? await store.deleteAll(); indexed = 0 }
    }

    /// Resumable walk: newest → oldest by keyset, cursor persisted per page.
    private func run() async {
        do {
            total = try await archive.storedTotalCount()
            indexed = try await store.count()
            var cursor: EmailPageCursor? = nil
            if let dateText = try await store.meta(Self.cursorDateKey), let idText = try await store.meta(Self.cursorIDKey),
               let seconds = Double(dateText), let id = UUID(uuidString: idText) {
                cursor = EmailPageCursor(beforeDate: Date(timeIntervalSince1970: seconds), beforeID: id)
            }
            while !Task.isCancelled {
                let page = try await archive.page(query: .all, cursor: cursor, limit: Self.pageSize)
                if page.summaries.isEmpty { break }
                var rows: [(id: UUID, vector: [Float])] = []
                for summary in page.summaries {
                    if Task.isCancelled { break }
                    let text = SentenceEmbedder.text(for: summary)
                    if !text.isEmpty, let vector = SentenceEmbedder.embed(text) { rows.append((summary.id, vector)) }
                }
                if Task.isCancelled { break }
                try await store.upsert(rows)
                if let last = page.summaries.last {
                    try await store.setMeta(Self.cursorDateKey, String(last.date.timeIntervalSince1970))
                    try await store.setMeta(Self.cursorIDKey, last.id.uuidString)
                }
                indexed = try await store.count()
                guard let next = page.nextCursor else { break }
                cursor = next
                await Task.yield()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Retrieval entry point for Ask: ids of the closest messages.
    func neighbors(of query: String, limit: Int = 20) async -> [UUID] {
        guard isEnabled, let vector = SentenceEmbedder.embed(query) else { return [] }
        return ((try? await store.neighbors(of: vector, limit: limit)) ?? []).map(\.id)
    }
}
