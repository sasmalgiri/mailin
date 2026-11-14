//
//  NSFDeletionStubs.swift
//  ArchiveCore
//
//  3.0 B3 (recovery R8): Lotus Notes / HCL Domino deletion stubs.
//
//  Public facts used (HCL C API reference, "RRV_xxx" and "Anatomy of a Note
//  ID"; libnsfdb format notes):
//    • a note ID is the file position of its RRV entry; a deleted note's ID
//      carries RRV_DELETED = 0x80000000;
//    • a deletion stub keeps only the note's identity — UNID (OID), sequence
//      number and dates — and none of its items (no Form, no Body).
//  The on-disk layout of a stub is not publicly documented, so a stub is
//  recognised by those facts on the note records the reader already finds:
//  a note ID with the deleted bit, or a note that carries an identity and
//  nothing else. Verified on mailin's own synthetic files only; not yet on a
//  database written by HCL Notes (SUPPORTED_FORMATS_AND_LIMITS.md).
//

import Foundation

enum NSFDeletionStub {
    /// RRV_DELETED: the high bit of a note ID marks a deleted note.
    static let rrvDeleted: UInt32 = 0x8000_0000

    /// Item names that only identify a note; a note carrying nothing else is a stub.
    static let identityItems: Set<String> = ["$NoteID", "NoteID", "UNID", "$UNID", "$OID", "OID",
                                            "$Seq", "$Sequence", "$Created", "$Modified", "$Revised",
                                            "$DeletedDate", "$Deleted"]

    /// A note ID written as "0x8000002A", "8000002A" (hex) or a decimal number.
    static func noteID(_ text: String?) -> UInt32? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.lowercased().hasPrefix("0x") { t.removeFirst(2); return UInt32(t, radix: 16) }
        if t.count == 8, let hex = UInt32(t, radix: 16) { return hex }
        return UInt32(t)
    }

    /// True when the note ID carries the deleted bit.
    static func isDeletedID(_ text: String?) -> Bool {
        guard let id = noteID(text) else { return false }
        return id & rrvDeleted != 0
    }

    /// The recovery mark for a note that is a deletion stub, or nil.
    static func recovery(for note: NSFNote) -> RecoveryInfo? {
        let id = note.items["$NoteID"] ?? note.items["NoteID"]
        let unid = note.items["UNID"] ?? note.items["$UNID"] ?? note.items["$OID"] ?? note.items["OID"]
        if isDeletedID(id) {
            return RecoveryInfo(state: .deletionStub, method: "nsf-stub",
                                evidence: "note ID \(id ?? "") has RRV_DELETED (0x80000000)", partial: true)
        }
        let onlyIdentity = !note.items.isEmpty && note.items.keys.allSatisfy { identityItems.contains($0) }
        if onlyIdentity, unid != nil, note.attachments.isEmpty {
            return RecoveryInfo(state: .deletionStub, method: "nsf-stub",
                                evidence: "note keeps only its identity (UNID, sequence, dates)", partial: true)
        }
        return nil
    }

    /// The archive row for a stub: identity and dates only, marked partial —
    /// the document's content is gone from the database.
    static func email(for note: NSFNote, info: RecoveryInfo) -> MBOXParser.RawEmail {
        let unid = note.items["UNID"] ?? note.items["$UNID"] ?? note.items["$OID"] ?? note.items["OID"] ?? ""
        let noteID = note.items["$NoteID"] ?? note.items["NoteID"] ?? ""
        let when = note.items["$DeletedDate"] ?? note.items["$Modified"] ?? note.items["$Revised"] ?? note.items["$Created"] ?? ""
        let date = NSFParser.parseNotesDateForStub(when)
        let timestamp = date.map { ISO8601DateFormatter().string(from: $0) } ?? ISO8601DateFormatter().string(from: .distantPast)
        let messageID = unid.isEmpty ? "nsf-stub-\(noteID)" : "nsf-unid-\(unid)"
        var headers: [String: String] = [
            "Subject": "(deleted Notes document — deletion stub, content not in the database)",
            "From": "", "To": "", "Date": timestamp, "Message-ID": "<\(messageID)>",
            "X-Source-Format": "NSF", "X-Notes-Deletion-Stub": "true",
        ]
        if !unid.isEmpty { headers["X-Notes-UNID"] = unid }
        if !noteID.isEmpty { headers["X-Notes-NoteID"] = noteID }
        if let seq = note.items["$Seq"] ?? note.items["$Sequence"] { headers["X-Notes-Sequence"] = seq }
        var email = MBOXParser.RawEmail(headers: headers, rawSource: "", messageType: "received", attachments: [],
                                        timestamp: timestamp, domains: [], plainBody: "", htmlBody: "")
        email.recovery = info
        return email
    }
}
