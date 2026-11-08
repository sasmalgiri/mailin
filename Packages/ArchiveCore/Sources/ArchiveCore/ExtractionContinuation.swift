//
//  ExtractionContinuation.swift
//  ArchiveCore
//
//  R5 (audit bf1a5b9, 2026-11-08): Resume CONTINUES an attachment instead of
//  reading it again from the beginning. Before R5 a Resume round re-extracted
//  every file inside the attachment under doubled budgets, so the files read
//  whole in round 0 spent the larger budget a second time — and an attachment
//  that had been unlocked with a password was re-read without it.
//
//  The durable cursor is what the archive already records: one
//  `attachment_children` row per file inside the attachment, with its state.
//  A file whose row says `extracted` or `noText` is done. The next round binds
//  their paths here; the container reader then lists such a file (so the
//  attachment's file list stays whole and in order) but does not extract it
//  again, and the store carries its recorded text and row over unchanged
//  (`SQLiteEmailStore.recordAttachmentChildrenContinuing`). Only the files
//  that stopped — over a budget, deeper than a level, or locked — are read.
//  Because the cursor is in the archive database it survives a restart.
//

import Foundation

enum ExtractionContinuation {
    /// Paths ("bundle.zip › inner/minutes.docx" relative to the attachment)
    /// of the files inside the attachment that an earlier round read whole.
    @TaskLocal static var completedPaths: Set<String> = []

    /// The states that mean "read whole; nothing left to read".
    static func isComplete(state: String) -> Bool {
        state == ChildDocument.State.extracted.rawValue || state == ChildDocument.State.noText.rawValue
    }

    /// The paths a round may carry over: completed, and unique within the
    /// attachment (two members with the same path cannot be told apart by
    /// path, so both are read again rather than one wrongly carried).
    static func carriablePaths(_ rows: [AttachmentChildRow]) -> Set<String> {
        var seen: [String: Int] = [:]
        for row in rows { seen[row.path, default: 0] += 1 }
        return Set(rows.filter { isComplete(state: $0.state) && seen[$0.path] == 1 }.map(\.path))
    }
}
