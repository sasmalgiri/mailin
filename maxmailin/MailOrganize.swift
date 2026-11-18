@testable import ArchiveCore
import MailConnectivity
//
//  MailOrganize.swift
//  maxmailin
//
//  Live Mail, owner 2026-11-15: Apple Mail's look with Thunderbird's tools —
//  the quick filter, colour tags, conversations, actions on several messages
//  at once and saved searches (smart folders).
//
//  Tags are local: they live in the archive's own user tags (the same tags
//  the Archive shows) and never change anything on the server. Read and flag
//  changes still go to the server only through Change server mail.
//

import SwiftUI

enum MailOrganize {
    static let groupKey = "mailin.mail.groupConversations"

    /// A read / flag state the server confirmed this session.
    struct Marks: Equatable {
        var read: Bool?
        var flagged: Bool?
    }

    /// "Asha Rao <asha@example.com>" → "Asha Rao"; a bare address stays.
    static func displayName(_ from: String) -> String {
        guard let lt = from.firstIndex(of: "<") else { return from }
        let name = from[..<lt].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        // "<asha@example.com>" alone: the address without its brackets.
        let address = from[from.index(after: lt)...].prefix { $0 != ">" }.trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? from : address
    }

    /// What VoiceOver reads for one message row (one element: sender, subject,
    /// date, then its marks) — the same sender name and "(no sender)" /
    /// "(no subject)" the row shows, so an empty field never reads as a bare
    /// comma (accessibility audit 2026-11-18).
    static func rowAccessibilityLabel(_ row: ConnectedMailboxRow, accountIdentity: String?, tags: [String],
                                      conversationCount: Int = 1) -> String {
        var parts = [row.from.isEmpty ? String(localized: "(no sender)") : displayName(row.from),
                     row.subject.isEmpty ? String(localized: "(no subject)") : row.subject,
                     row.date.formatted(date: .abbreviated, time: .omitted)]
        if conversationCount > 1 { parts.append(String(localized: "\(conversationCount) messages in this conversation")) }
        if row.isRead == false { parts.append(String(localized: "Unread")) }
        if row.isFlagged == true { parts.append(String(localized: "Flagged")) }
        if row.hasAttachments { parts.append(String(localized: "Has attachments")) }
        parts += tags
        if !row.onServer { parts.append(String(localized: "Removed from the server; kept here")) }
        if let accountIdentity { parts.append(accountIdentity) }
        return parts.joined(separator: ", ")
    }

    /// The preview on two lines: whitespace runs folded to one space.
    static func cleanPreview(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Mail's dates: time today, "Yesterday", the weekday this week, else the date.
    static func listDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The conversation a row belongs to: the archive's stored key, or the
    /// same derivation (References root → In-Reply-To → Message-ID → subject).
    static func conversationKey(_ row: ConnectedMailboxRow) -> String {
        if let key = row.threadKey, !key.isEmpty { return key }
        return ThreadKeyDeriver.derive(messageID: row.messageID, inReplyTo: row.inReplyTo, references: row.references,
                                       subject: row.subject, emailID: row.emailID).key
    }

    /// The listed rows as conversations, newest conversation first (rows
    /// arrive newest first). Grouping covers the messages shown so far.
    static func conversations(_ rows: [ConnectedMailboxRow]) -> [MailConversation] {
        var order: [String] = []
        var groups: [String: [ConnectedMailboxRow]] = [:]
        for row in rows {
            let key = conversationKey(row)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        return order.map { MailConversation(key: $0, rows: groups[$0] ?? []) }
    }
}

struct MailConversation: Identifiable, Equatable {
    let key: String
    /// Newest first.
    let rows: [ConnectedMailboxRow]
    var id: String { key }
    var latest: ConnectedMailboxRow { rows[0] }
    var hasUnread: Bool { rows.contains { $0.isRead == false } }
}

// MARK: - Move, restore and labels on the server

/// V4-11 (owner 2026-11-15, "no hidden features"): the folder moves, Trash
/// restores and Gmail label edits the server-action engine already performs,
/// offered from the message's "On the server" menu. This decides which folders
/// a message can go to and builds the request; RemoteActionService journals
/// it and checks the message is still where the request says it is.
enum MailServerMoves {
    /// Trash on each provider: IMAP special-use, Graph well-known name, Gmail system label.
    static func isTrash(_ f: ConnectedFolderSummary) -> Bool {
        guard let s = f.specialUse?.lowercased() else { return false }
        return s == "\\trash" || s == "deleteditems" || s == "trash"
    }

    static func isInbox(_ f: ConnectedFolderSummary) -> Bool {
        f.specialUse?.lowercased() == "inbox"
    }

    /// Gmail's system labels other than INBOX (SENT, DRAFT, SPAM, IMPORTANT,
    /// CATEGORY_…, All Mail) are not move targets and cannot be added by hand.
    static func isGmailSystemLabel(_ f: ConnectedFolderSummary) -> Bool {
        f.kind == .label && f.specialUse != nil && !isInbox(f)
    }

    private static func account(_ row: ConnectedMailboxRow, _ folders: [ConnectedFolderSummary]) -> [ConnectedFolderSummary] {
        folders.filter { $0.accountID == row.accountID }
    }

    /// The folder the message is in now, as the server names it. IMAP: the
    /// mailbox in the message's identity; Graph: its one folder; Gmail: the
    /// first user label or INBOX it carries (a move swaps that label).
    static func currentFolder(of row: ConnectedMailboxRow, in folders: [ConnectedFolderSummary]) -> String? {
        if case .imap(let mailbox, _, _) = row.identity { return mailbox }
        let mine = account(row, folders)
        let memberships = mine.filter { row.folderServerIDs.contains($0.serverID) }
        if case .gmail = row.identity {
            return (memberships.first(where: isInbox) ?? memberships.first { !isGmailSystemLabel($0) && !isTrash($0) })?.serverID
        }
        return memberships.first { !isTrash($0) }?.serverID ?? memberships.first?.serverID
    }

    static func isInTrash(_ row: ConnectedMailboxRow, in folders: [ConnectedFolderSummary]) -> Bool {
        if case .imap(let mailbox, _, _) = row.identity {
            return account(row, folders).contains { $0.serverID == mailbox && isTrash($0) }
        }
        return account(row, folders).contains { row.folderServerIDs.contains($0.serverID) && isTrash($0) }
    }

    /// Folders the message can be moved to: every folder of its account except
    /// the one it is in, Trash (Move to the server's Trash has its own review)
    /// and Gmail's system labels. Sorted by the path shown in the sidebar.
    static func moveTargets(for row: ConnectedMailboxRow, in folders: [ConnectedFolderSummary]) -> [ConnectedFolderSummary] {
        guard row.identity.supportsServerMoves, !isInTrash(row, in: folders),
              let current = currentFolder(of: row, in: folders) else { return [] }
        return account(row, folders)
            .filter { $0.serverID != current && !isTrash($0) && !isGmailSystemLabel($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func moveRequest(_ row: ConnectedMailboxRow, to target: ConnectedFolderSummary,
                            in folders: [ConnectedFolderSummary]) -> RemoteChangeRequest? {
        guard moveTargets(for: row, in: folders).contains(target),
              let current = currentFolder(of: row, in: folders) else { return nil }
        return .move(from: current, to: target.serverID)
    }

    /// Back out of Trash into the Inbox (Gmail: its own labels come back).
    static func restoreRequest(_ row: ConnectedMailboxRow, in folders: [ConnectedFolderSummary]) -> RemoteChangeRequest? {
        guard row.identity.supportsServerMoves, isInTrash(row, in: folders) else { return nil }
        if case .gmail = row.identity { return .restoreFromTrash(to: nil) }
        guard let inbox = account(row, folders).first(where: isInbox) else { return nil }
        return .restoreFromTrash(to: inbox.serverID)
    }

    /// Gmail (API) only: user labels the message has, and the ones it could get.
    static func labels(for row: ConnectedMailboxRow, in folders: [ConnectedFolderSummary]) -> (present: [ConnectedFolderSummary], addable: [ConnectedFolderSummary]) {
        guard case .gmail = row.identity else { return ([], []) }
        let user = account(row, folders).filter { $0.kind == .label && $0.specialUse == nil }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (user.filter { row.folderServerIDs.contains($0.serverID) },
                user.filter { !row.folderServerIDs.contains($0.serverID) })
    }
}

extension RemoteChangeRequest {
    /// Moves, restores and label edits: the message's folders on the server change.
    var changesFolders: Bool {
        switch self {
        case .move, .moveToTrash, .restoreFromTrash, .addLabel, .removeLabel, .archiveOnServer: return true
        case .markRead, .markUnread, .flag, .unflag: return false
        }
    }
}

extension ProviderMessageIdentity {
    /// Gmail over IMAP (app password) changes nothing on the server in 4.0.
    var supportsServerMoves: Bool {
        if case .gmailIMAP = self { return false }
        return true
    }
}

// MARK: - Drafts after sending

/// Which drafts the Drafts list shows once messages go to the outbox.
enum MailDraftSettling {
    /// What the outbox says about one frozen draft revision.
    struct Sending: Equatable {
        var draftID: UUID
        var revision: Int
        var state: OutboxState
    }

    static func sending(_ outbox: [OutboxOperation]) -> [Sending] {
        outbox.map { Sending(draftID: $0.draftID, revision: $0.draftRevision, state: $0.state) }
    }

    /// The send of exactly this draft revision that still counts (not cancelled or rejected).
    private static func sending(_ draft: Draft, in outbox: [Sending]) -> Sending? {
        outbox.first { op in
            guard op.draftID == draft.id, op.revision == draft.revision else { return false }
            switch op.state {
            case .cancelledBeforeSubmission, .rejected, .draft: return false
            default: return true
            }
        }
    }

    /// Drafts the server accepted unchanged: deleted, as Mail does.
    static func sent(_ drafts: [Draft], outbox: [OutboxOperation]) -> [Draft] { sent(drafts, sending: sending(outbox)) }
    static func sent(_ drafts: [Draft], sending outbox: [Sending]) -> [Draft] {
        drafts.filter { sending($0, in: outbox)?.state.isAccepted == true }
    }

    /// Drafts still to show: not sent and not waiting in the outbox.
    static func listed(_ drafts: [Draft], outbox: [OutboxOperation]) -> [Draft] { listed(drafts, sending: sending(outbox)) }
    static func listed(_ drafts: [Draft], sending outbox: [Sending]) -> [Draft] {
        drafts.filter { sending($0, in: outbox) == nil }
    }
}

// MARK: - Tag colours

/// Thunderbird's default tags and colours; any tag can take any colour.
enum MailTagPalette {
    private static let key = "mailin.mail.tagColors"

    static let colors: [(name: String, color: Color)] = [
        (String(localized: "Red"), .red), (String(localized: "Orange"), .orange), (String(localized: "Yellow"), .yellow),
        (String(localized: "Green"), .green), (String(localized: "Blue"), .blue), (String(localized: "Purple"), .purple),
        (String(localized: "Grey"), .gray),
    ]

    /// The tags offered before the person makes their own.
    static var presets: [(tag: String, colorIndex: Int)] {
        [(String(localized: "Important"), 0), (String(localized: "Work"), 1), (String(localized: "Personal"), 3),
         (String(localized: "To Do"), 4), (String(localized: "Later"), 5)]
    }

    static func colorIndex(for tag: String) -> Int {
        if let saved = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[tag], colors.indices.contains(saved) {
            return saved
        }
        if let preset = presets.first(where: { $0.tag == tag }) { return preset.colorIndex }
        // A stable colour from the name (not hashValue, which changes per launch).
        return Int(tag.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 9973 }) % colors.count
    }

    static func color(for tag: String) -> Color { colors[colorIndex(for: tag)].color }

    static func setColor(_ index: Int, for tag: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        all[tag] = index
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Saved searches (smart folders)

struct MailSmartFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text = ""
    var unreadOnly = false
    var flaggedOnly = false
    var attachmentsOnly = false
    var tag: String?

    func apply(to q: inout ConnectedMailboxQuery) {
        q.text = text
        q.unreadOnly = unreadOnly
        q.flaggedOnly = flaggedOnly
        q.attachmentsOnly = attachmentsOnly
        q.tag = tag
    }

    /// What the saved search matches, in words (the sidebar's help text).
    var summary: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append("“\(text)”") }
        if unreadOnly { parts.append(String(localized: "Unread")) }
        if flaggedOnly { parts.append(String(localized: "Flagged")) }
        if attachmentsOnly { parts.append(String(localized: "Has attachments")) }
        if let tag { parts.append(tag) }
        return parts.joined(separator: " · ")
    }
}

enum MailSmartFolderStore {
    private static let key = "mailin.mail.smartFolders"

    static func load() -> [MailSmartFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MailSmartFolder].self, from: data)) ?? []
    }

    static func save(_ folders: [MailSmartFolder]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: key)
    }
}

// MARK: - Model

extension MailWorkspaceModel {
    /// The list as shown: one row per message, or one per conversation.
    var conversations: [MailConversation] { MailOrganize.conversations(rows) }

    var selectedRows: [ConnectedMailboxRow] { rows.filter { selection.contains($0.emailID) } }

    /// True when any quick filter narrows the list.
    var isQuickFiltered: Bool {
        unreadOnly || flaggedOnly || attachmentsOnly || tagFilter != nil
            || !quickText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearQuickFilter() {
        quickText = ""; unreadOnly = false; flaggedOnly = false; attachmentsOnly = false; tagFilter = nil
    }

    func scheduleQuickReload() {
        quickReloadTask?.cancel()
        quickReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reloadMailbox()
        }
    }

    func loadTags() async {
        let ids = rows.map(\.emailID)
        tags = ids.isEmpty ? [:] : await backend.tags(ids)
        knownTags = await backend.knownTags()
    }

    /// Every tag the menus offer: the presets, then the archive's own tags.
    var offeredTags: [String] {
        var out = MailTagPalette.presets.map(\.tag)
        for tag in knownTags where !out.contains(tag) { out.append(tag) }
        return out
    }

    /// Adds the tag to every message given, or removes it when all already have it.
    func toggleTag(_ tag: String, on ids: [UUID]) async {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !ids.isEmpty else { return }
        let present = !ids.allSatisfy { tags[$0]?.contains(tag) == true }
        await run { try await self.backend.setTag(tag, on: ids, present: present) }
        if tagFilter == tag, !present { await reloadMailbox() } else { await loadTags() }
    }

    func applyingServerMarks(_ list: [ConnectedMailboxRow]) -> [ConnectedMailboxRow] {
        list.map { row in
            guard let marks = serverMarks[row.emailID] else { return row }
            var r = row
            if let read = marks.read { r.isRead = read }
            if let flagged = marks.flagged { r.isFlagged = flagged }
            return r
        }
    }

    /// The server confirmed a read / flag change: show it at once.
    func noteServerMark(_ request: RemoteChangeRequest, on id: UUID) {
        var marks = serverMarks[id] ?? MailOrganize.Marks()
        switch request {
        case .markRead: marks.read = true
        case .markUnread: marks.read = false
        case .flag: marks.flagged = true
        case .unflag: marks.flagged = false
        default: return
        }
        serverMarks[id] = marks
        rows = applyingServerMarks(rows)
    }

    /// The same server change for several messages, one at a time; reports
    /// "X of Y". Messages that cannot be changed are named, never skipped silently.
    func changeOnServer(_ request: RemoteChangeRequest, rows chosen: [ConnectedMailboxRow]) async {
        await changeOnServer(rows: chosen) { _ in request }
    }

    /// The same, with the request built for each message (a move names the
    /// folder each one is in now); a message with no request is not changed and counted.
    func changeOnServer(rows chosen: [ConnectedMailboxRow], _ requestFor: (ConnectedMailboxRow) -> RemoteChangeRequest?) async {
        let eligible = chosen.filter { canChangeOnServer($0) && requestFor($0) != nil }
        var changed = 0, refused = 0, conflicts = 0, uncertain = 0, failed = 0, attempted = 0
        var firstFailure: String?
        var moved = false
        for row in eligible {
            guard let request = requestFor(row) else { continue }
            attempted += 1
            let op: RemoteOperation
            do {
                op = try await backend.changeOnServer(request, row: row)
            } catch {
                failed += 1
                if firstFailure == nil { firstFailure = ConnectedMailErrorText.text(for: error) }
                continue
            }
            if let scope = MailServerChangeText.missingScope(op.outcome) {
                refused += 1
                pendingReconsent = MailReconsentRequest(accountID: row.accountID, scope: scope, mode: .serverActions)
                break
            }
            switch op.outcome {
            case .applied?:
                changed += 1
                noteServerMark(request, on: row.emailID)
                if request.changesFolders { moved = true }
            case .rejected?: refused += 1
            case .conflict?: conflicts += 1
            case .uncertain?: uncertain += 1
            case nil: failed += 1
            }
        }
        if failed == 0 { lastError = nil } else if let firstFailure { lastError = firstFailure }
        // A move changes where the server keeps the message: read the folders
        // again so the lists show it there (the archived copy itself is unchanged).
        if moved {
            for account in Set(eligible.map(\.accountID)) { await syncNow(account) }
        }
        message = Self.serverChangeSummary(chosen: chosen.count, ineligible: chosen.count - eligible.count,
                                           changed: changed, refused: refused, conflicts: conflicts,
                                           uncertain: uncertain, failed: failed, firstFailure: firstFailure,
                                           notTried: eligible.count - attempted)
    }

    /// "Changed X of Y" and why each of the others did not change (rule 5).
    static func serverChangeSummary(chosen: Int, ineligible: Int, changed: Int, refused: Int, conflicts: Int,
                                    uncertain: Int, failed: Int, firstFailure: String?, notTried: Int) -> String {
        var text = String(localized: "Changed \(changed) of \(chosen) messages on the server.")
        if ineligible > 0 {
            text += " " + String(localized: "\(ineligible) could not be changed: Change server mail is off for their account, they are no longer on the server, or the change does not apply to them.")
        }
        if refused > 0 {
            text += " " + String(localized: "\(refused) refused by the server or the account's permissions; nothing was changed.")
        }
        if conflicts > 0 {
            text += " " + String(localized: "\(conflicts) changed by another app first; nothing was changed.")
        }
        if uncertain > 0 {
            text += " " + String(localized: "\(uncertain) may or may not have reached the server; they are not repeated automatically.")
        }
        if failed > 0 {
            text += " " + String(localized: "\(failed) failed: \(firstFailure ?? String(localized: "the server did not answer."))")
        }
        if notTried > 0 {
            text += " " + String(localized: "\(notTried) not tried: the account needs extra permission first.")
        }
        return text
    }

    // MARK: Saved searches

    /// Saves the quick filter as a smart folder and opens it.
    func saveSmartFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = MailSmartFolder(name: trimmed, text: quickText.trimmingCharacters(in: .whitespacesAndNewlines),
                                     unreadOnly: unreadOnly, flaggedOnly: flaggedOnly, attachmentsOnly: attachmentsOnly,
                                     tag: tagFilter)
        smartFolders.append(folder)
        MailSmartFolderStore.save(smartFolders)
        clearQuickFilter()
        section = .smart(folder.id)
    }

    func deleteSmartFolder(_ id: UUID) {
        smartFolders.removeAll { $0.id == id }
        MailSmartFolderStore.save(smartFolders)
        if section == .smart(id) { section = .unifiedInbox }
    }
}
