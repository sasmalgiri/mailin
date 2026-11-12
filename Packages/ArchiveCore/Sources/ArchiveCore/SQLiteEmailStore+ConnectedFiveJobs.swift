//
//  SQLiteEmailStore+ConnectedFiveJobs.swift
//  ArchiveCore
//
//  Plan v4 V4-08 (§5.4, §5.5): what the five jobs read about connected mail.
//
//    • `connectedAcquisitionGaps` — accounts whose remote inventory is not
//      fully preserved yet (never fully listed, items queued or failed). The
//      search coverage line states them, so a query that finds nothing — or
//      an exclusion — never reads as "nothing on the account matches" while
//      mail is still to be saved (T25).
//    • `connectedSearchCounts` — search coverage of ONE account's preserved
//      mail from the chunk index (bodies / attachment documents evaluable,
//      pending, unavailable), for the account's capture status line.
//    • `hasConnectedMessages` — a cheap test so exports of archives without
//      connected mail never look for provenance.
//
//  Read-only; no schema change (v26 tables + the v22 chunk index).
//

import Foundation
import SQLite3

/// One account whose acquisition is not complete.
struct ConnectedAcquisitionGap: Sendable, Equatable {
    var accountID: UUID
    var displayIdentity: String
    /// Preserved and not deleted locally.
    var saved: Int
    /// Listed, outcome not reached yet.
    var remaining: Int
    /// Download failed with a reason; retried on the next sync.
    var failed: Int
    /// False until every selected folder was listed to its end and reconciled.
    var inventoryKnown: Bool
    /// The account was removed (secrets deleted): nothing more will be saved.
    var accountRemoved: Bool
}

/// Search coverage of one account's preserved mail (chunk index).
struct ConnectedSearchCounts: Sendable, Equatable {
    var messages: Int
    var bodiesEvaluable: Int
    var attachments: Int
    var attachmentsEvaluable: Int
    /// Attachment documents that were read and cannot be evaluated
    /// (unsupported, locked, failed, partly read).
    var attachmentsUnavailable: Int
}

extension SQLiteEmailStore {

    func hasConnectedMessages() throws -> Bool {
        try scalarInt(try ensureDB(), "SELECT EXISTS(SELECT 1 FROM remote_messages);") != 0
    }

    /// Every connected account whose acquisition is incomplete, in account order.
    func connectedAcquisitionGaps() throws -> [ConnectedAcquisitionGap] {
        var out: [ConnectedAcquisitionGap] = []
        for account in try connectedAccounts() {
            let c = try connectedCompleteness(accountID: account.accountID)
            let a = c.acquisition
            guard !a.inventoryKnown || a.remaining > 0 || a.failed > 0 else { continue }
            out.append(ConnectedAcquisitionGap(
                accountID: account.accountID, displayIdentity: account.displayIdentity,
                saved: max(0, a.captured - a.locallyDeleted), remaining: a.remaining, failed: a.failed,
                inventoryKnown: a.inventoryKnown, accountRemoved: account.connectionState == "removed"))
        }
        return out
    }

    /// The chunk-index coverage of one account's preserved (not deleted) mail.
    func connectedSearchCounts(accountID: UUID) throws -> ConnectedSearchCounts {
        let db = try ensureDB()
        let mine = "SELECT r.email_id FROM remote_messages r WHERE r.account_id = ?1 AND r.email_id IS NOT NULL"
        func count(_ sql: String) throws -> Int {
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, accountID.uuidString)
            guard try stepRow(stmt, db) else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        let kinds = SearchDocKind.attachmentContentSQL
        return ConnectedSearchCounts(
            messages: try count("SELECT COUNT(*) FROM emails e WHERE e.id IN (\(mine));"),
            bodiesEvaluable: try count("""
                SELECT COUNT(DISTINCT d.email_id) FROM search_docs d
                WHERE d.email_id IN (\(mine)) AND d.kind = 'body' AND d.state IN ('complete','noText');
                """),
            attachments: try count("SELECT COUNT(*) FROM attachments a WHERE a.email_id IN (\(mine));"),
            attachmentsEvaluable: try count("""
                SELECT COUNT(*) FROM attachments a WHERE a.email_id IN (\(mine))
                  AND EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = a.email_id AND d.ordinal = a.position
                              AND d.kind IN (\(kinds)) AND d.state IN ('complete','noText'));
                """),
            attachmentsUnavailable: try count("""
                SELECT COUNT(*) FROM attachments a WHERE a.email_id IN (\(mine))
                  AND NOT EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = a.email_id AND d.ordinal = a.position
                                  AND d.kind IN (\(kinds)) AND d.state IN ('complete','noText'))
                  AND EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = a.email_id AND d.ordinal = a.position
                              AND d.kind IN (\(kinds)) AND d.state IN ('unsupported','locked','failed','partial'));
                """))
    }
}

extension ConnectedArchiveSink {
    /// Accounts whose acquisition is incomplete (search coverage, T25).
    func acquisitionGaps() async throws -> [ConnectedAcquisitionGap] {
        try await store.connectedAcquisitionGaps()
    }

    /// Search coverage of one account's preserved mail.
    func searchCounts(accountID: UUID) async throws -> ConnectedSearchCounts {
        try await store.connectedSearchCounts(accountID: accountID)
    }
}
