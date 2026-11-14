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
        let eligible = chosen.filter(canChangeOnServer)
        var changed = 0
        for row in eligible {
            var applied = false
            var scope: String?
            await run {
                let op = try await self.backend.changeOnServer(request, row: row)
                if case .applied? = op.outcome { applied = true; self.noteServerMark(request, on: row.emailID) }
                scope = MailServerChangeText.missingScope(op.outcome)
            }
            if let scope {
                pendingReconsent = MailReconsentRequest(accountID: row.accountID, scope: scope, mode: .serverActions)
                break
            }
            if applied { changed += 1 }
        }
        var text = String(localized: "Changed \(changed) of \(chosen.count) messages on the server.")
        if eligible.count < chosen.count {
            text += " " + String(localized: "\(chosen.count - eligible.count) could not be changed: Change server mail is off for their account, or they are no longer on the server.")
        }
        message = text
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
