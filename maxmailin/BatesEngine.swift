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

    /// Next free number for `prefix`: above every stored number, never below
    /// the configured start.
    static func nextNumber(manager: BatesNumberingManager, stored: [UUID: String]) -> Int {
        let used = (stored.values.compactMap { numericPart($0, prefix: manager.prefix) }
                    + manager.assignments.values.compactMap { numericPart($0, prefix: manager.prefix) }).max() ?? 0
        return max(manager.startNumber, used + 1)
    }

    static func assign(scope: ArchiveScope, manager: BatesNumberingManager)
        async throws -> (state: AssignState, receipt: ScopeJobReceipt) {
        let store = SQLiteEmailStore.shared
        var stored = try await store.reviewCoding(workspace: workspace, field: field)
        // Numbers from the previous engine (kept in the manager) are part of
        // the record too: carry them into the database first, never change them.
        let legacy = manager.assignments.filter { stored[$0.key] == nil }
        if !legacy.isEmpty {
            try await store.reviewCodingSet(workspace: workspace, field: field, values: legacy.mapValues { Optional($0) })
            stored.merge(legacy) { current, _ in current }
        }
        var query = scope.query
        query.sort = .dateAsc
        let alreadyNumbered = stored
        let result = try await ScopeJob.runIDs(
            key: "bates.assign", title: String(localized: "Assign Bates numbers"),
            capability: .v3Bates, query: query, batchSize: 2_000,
            initialState: AssignState(next: nextNumber(manager: manager, stored: stored))
        ) { state, page in
            var batch: [UUID: String?] = [:]
            for summary in page {
                if alreadyNumbered[summary.id] != nil { state.skipped += 1; continue }
                let number = manager.formatNumber(state.next)
                batch[summary.id] = number
                state.next += 1
                state.assigned += 1
                if state.first == nil { state.first = number }
                state.last = number
            }
            try await store.reviewCodingSet(workspace: workspace, field: field, values: batch)
        }
        let all = try await store.reviewCoding(workspace: workspace, field: field)
        let new = all.filter { manager.assignments[$0.key] == nil }
        manager.merge(assignments: new, nextStart: result.state.next)
        ForensicManager.shared.logAction(
            "Bates Numbers Assigned",
            detail: "\(result.state.assigned) new numbers (\(result.state.first ?? "—") through \(result.state.last ?? "—")); \(result.state.skipped) already numbered, unchanged — \(result.receipt.coverageLine)")
        return (result.state, result.receipt)
    }

    /// CSV index of every numbered email in scope, in Bates order — the
    /// previous columns, streamed to the file and verified.
    static func exportIndex(scope: ArchiveScope, manager: BatesNumberingManager) async -> (ExportOutcome, Int) {
        let store = SQLiteEmailStore.shared
        guard let stored = try? await store.reviewCoding(workspace: workspace, field: field) else {
            return (.failed(String(localized: "the Bates numbers could not be read")), 0)
        }
        var rows: [(number: String, id: UUID)] = []
        do {
            for try await page in ArchiveDataService.shared.streamSummaries(query: scope.query, batchSize: 5_000) {
                for s in page { if let n = stored[s.id] { rows.append((n, s.id)) } }
            }
        } catch {
            return (.failed(error.localizedDescription), 0)
        }
        rows.sort { $0.number < $1.number }
        guard !rows.isEmpty else { return (.failed(String(localized: "no emails in scope have Bates numbers")), 0) }
        let count = rows.count
        let (outcome, _) = await PlatformExport.saveStreamed(suggestedName: "BatesIndex_\(manager.prefix).csv") { url in
            try await StreamedTextFile.write(to: url) { emit in
                try emit("BatesNumber,From,To,Subject,Date,MessageID,AttachmentCount\n")
                for start in stride(from: 0, to: rows.count, by: 200) {
                    let chunk = rows[start..<min(start + 200, rows.count)]
                    let emails = try await ArchiveDataService.shared.fullEmails(ids: chunk.map(\.id))
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
            ForensicManager.shared.logAction("Bates Index Exported", detail: "Exported CSV index with \(count) entries")
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
        guard let stored = try? await SQLiteEmailStore.shared.reviewCoding(workspace: workspace, field: field),
              !stored.isEmpty else { return 0 }
        var n = 0
        do {
            for try await page in ArchiveDataService.shared.streamSummaries(query: scope.query, batchSize: 5_000) {
                n += page.reduce(0) { $0 + (stored[$1.id] != nil ? 1 : 0) }
            }
        } catch {}
        return n
    }
}
