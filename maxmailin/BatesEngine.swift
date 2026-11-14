@testable import ArchiveCore
//
//  BatesEngine.swift
//  maxmailin
//
//  §3-L6 (switch: `v3Bates`). Whole-scope Bates numbering.
//
//  Rule 3: a number, once assigned, is never changed or reused. The previous
//  engine renumbered every call (it replaced all assignments with a fresh
//  sequence over the loaded emails). This engine:
//   • walks the whole scope in date order (oldest first; undated first, as
//     before) through the scope engine;
//   • skips every email that already has a number;
//   • continues after the highest number ever used with the current prefix
//     (or the configured start, whichever is higher);
//   • stores numbers in the archive database (review_coding, workspace
//     "bates") and merges them into the manager so existing readers
//     (exports, the email list) see them.
//

import Foundation

@MainActor
enum BatesEngine {
    static let workspace = "bates"
    static let field = "number"

    struct AssignState: Codable, Sendable {
        var next: Int
        var assigned = 0
        var skipped = 0
        var first: String?
        var last: String?
    }

    /// The numeric part of `number` when it carries `prefix`.
    static func numericPart(_ number: String, prefix: String) -> Int? {
        guard number.hasPrefix(prefix) else { return nil }
        return Int(number.dropFirst(prefix.count))
    }

    static func assign(scope: ArchiveScope, manager: BatesNumberingManager)
        async throws -> (state: AssignState, receipt: ScopeJobReceipt) {
        if let why = OrgPolicy.denial(.produce) { throw StorePolicyError.denied(why) }   // enterprise role
        let store = ScopeJobEnvironment.store
        let stored = try await store.reviewCoding(workspace: workspace, field: field)
        // Numbers from the previous engine (kept in the manager) are part of
        // the record too: carry them into the database first, never change them.
        let legacy = manager.assignments.filter { stored[$0.key] == nil }
        if !legacy.isEmpty {
            try await store.reviewCodingSet(workspace: workspace, field: field, values: legacy.mapValues { Optional($0) })
        }
        let result = try await number(query: scope.query, prefix: manager.prefix,
                                      start: max(manager.startNumber, 1), format: manager.formatNumber)
        let all = try await store.reviewCoding(workspace: workspace, field: field)
        let new = all.filter { manager.assignments[$0.key] == nil }
        // One action, one audit entry: this one (merge's own entry is off).
        manager.merge(assignments: new, nextStart: result.state.next, log: false)
        ScopeJobEnvironment.logAction(
            "Bates Numbers Assigned",
            detail: "\(result.state.assigned) new numbers (\(result.state.first ?? "—") through \(result.state.last ?? "—")); \(result.state.skipped) already numbered, unchanged — \(result.receipt.coverageLine)")
        return (result.state, result.receipt)
    }

    /// The numbering itself, against the archive database only: every email
    /// in `query` without a number gets the next one, in date order (oldest
    /// first); numbered emails are skipped and never changed. The sequence
    /// continues after the highest number stored with `prefix`, never below
    /// `start`.
    static func number(query scopeQuery: EmailQuery, prefix: String, start: Int,
                       format: (Int) -> String) async throws -> (state: AssignState, receipt: ScopeJobReceipt) {
        if let why = OrgPolicy.denial(.produce) { throw StorePolicyError.denied(why) }   // enterprise role
        let store = ScopeJobEnvironment.store
        let alreadyNumbered = try await store.reviewCoding(workspace: workspace, field: field)
        let used = alreadyNumbered.values.compactMap { numericPart($0, prefix: prefix) }.max() ?? 0
        var query = scopeQuery
        query.sort = .dateAsc
        return try await ScopeJob.runIDs(
            key: "bates.assign", title: String(localized: "Assign Bates numbers"),
            capability: .v3Bates, query: query, batchSize: 2_000,
            initialState: AssignState(next: max(start, used + 1))
        ) { state, page in
            var batch: [UUID: String?] = [:]
            for summary in page {
                if alreadyNumbered[summary.id] != nil { state.skipped += 1; continue }
                let number = format(state.next)
                batch[summary.id] = number
                state.next += 1
                state.assigned += 1
                if state.first == nil { state.first = number }
                state.last = number
            }
            if !batch.isEmpty {
                try await store.reviewCodingSet(workspace: workspace, field: field, values: batch)
            }
        }
    }

    /// CSV index of every numbered email in scope, in Bates order — the
    /// previous columns, streamed to the file and verified.
    static func exportIndex(scope: ArchiveScope, manager: BatesNumberingManager) async -> (ExportOutcome, Int) {
        let store = ScopeJobEnvironment.store
        guard let stored = try? await store.reviewCoding(workspace: workspace, field: field) else {
            return (.failed(String(localized: "the Bates numbers could not be read")), 0)
        }
        var rows: [(number: String, id: UUID)] = []
        do {
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: scope.query, batchSize: 5_000) {
                for s in page { if let n = stored[s.id] { rows.append((n, s.id)) } }
            }
        } catch {
            return (.failed(error.localizedDescription), 0)
        }
        // By value, not text: "MAILIN1000000" follows "MAILIN999999" even
        // once a number outgrows its zero padding.
        let prefix = manager.prefix
        rows.sort { a, b in
            switch (numericPart(a.number, prefix: prefix), numericPart(b.number, prefix: prefix)) {
            case let (x?, y?): return x != y ? x < y : a.number < b.number
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.number < b.number
            }
        }
        guard !rows.isEmpty else { return (.failed(String(localized: "no emails in scope have Bates numbers")), 0) }
        let count = rows.count
        let (outcome, _) = await PlatformExport.saveStreamed(suggestedName: "BatesIndex_\(manager.prefix).csv") { url in
            try await StreamedTextFile.write(to: url) { emit in
                try emit("BatesNumber,From,To,Subject,Date,MessageID,AttachmentCount\n")
                for start in stride(from: 0, to: rows.count, by: 200) {
                    let chunk = rows[start..<min(start + 200, rows.count)]
                    let emails = try await ScopeJobEnvironment.archive.fullEmails(ids: chunk.map(\.id))
                    let byID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
                    var text = ""
                    for row in chunk {
                        guard let email = byID[row.id] else { continue }
                        text += csvEscape(row.number) + ","
                        text += csvEscape(email.headers["From"] ?? "") + ","
                        text += csvEscape(email.headers["To"] ?? "") + ","
                        text += csvEscape(email.headers["Subject"] ?? "") + ","
                        text += csvEscape(email.headers["Date"] ?? "") + ","
                        text += csvEscape(email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? "") + ","
                        text += "\(email.attachments.count)\n"
                    }
                    try emit(text)
                }
            }
        }
        if outcome.succeeded {
            ScopeJobEnvironment.logAction("Bates Index Exported", detail: "Exported CSV index with \(count) entries")
        }
        return (outcome, count)
    }

    /// Same escaping as the previous index (quotes, formula guard, no newlines).
    private static func csvEscape(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "") + "\""
    }

    /// Numbered emails in scope (for the preview line).
    static func numberedCount(scope: ArchiveScope) async -> Int {
        guard let stored = try? await ScopeJobEnvironment.store.reviewCoding(workspace: workspace, field: field),
              !stored.isEmpty else { return 0 }
        var n = 0
        do {
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: scope.query, batchSize: 5_000) {
                n += page.reduce(0) { $0 + (stored[$1.id] != nil ? 1 : 0) }
            }
        } catch {}
        return n
    }
}
