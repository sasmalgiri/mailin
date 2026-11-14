@testable import ArchiveCore
import MailConnectivity
//
//  MailWorkspaceView.swift
//  maxmailin
//
//  Plan v4 V4-13 (§2, §6): the Mail workspace — the page that replaced the
//  "Live Mail is not built yet" placeholder. Accounts, a unified inbox with
//  account badges, each account's folders / labels, unread and flagged
//  filters, the existing safe message view, drafts, the outbox, status.
//
//  In a build without the mail transports (the offline edition) the page
//  shows one honest state and no actionable control. With the transports but
//  Connected mail off, it offers exactly one control: turning it on.
//
//  Keyboard (Mail page only): ⌥⌘N compose · ⌥⌘R sync now · ⌥⌘A add account ·
//  ⌥⌘I unified inbox · ⌥⌘E drafts · ⌥⌘O outbox · ⌥⌘U unread only ·
//  ⌥⌘L flagged only · in a message: ⌘R reply · ⌥⇧⌘R reply all · ⌥⌘F forward.
//  (Drafts is not ⌥⌘D: macOS uses that to show and hide the Dock.)
//

import Combine
import SwiftUI

struct MailWorkspaceView: View {
    @Environment(ModuleRegistry.self) private var modules
    @State private var model = MailWorkspaceModel(backend: ConnectedMailBackend.current())
    @State private var sheet: MailSheet?

    var body: some View {
        Group {
            if model.availability == .ready {
                MailWorkspaceReadyView(model: model, sheet: $sheet)
            } else {
                MailUnavailableView(availability: model.availability) {
                    modules.set(.connectedMail, enabled: true)
                }
            }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ConnectedMailRuntime.didChange).receive(on: RunLoop.main)) { _ in
            rebuildIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: ConnectedMailRuntime.progress).receive(on: RunLoop.main)) { _ in
            // A running capture's counts (the runtime posts at most every 2 s).
            Task { await model.refreshAccounts() }
        }
        .onChange(of: modules.isOn(.connectedMail)) { _, _ in
            // The runtime is created asynchronously after the switch.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                rebuildIfNeeded()
            }
        }
        .sheet(item: $sheet) { sheet in
            MailSheetHost(sheet: sheet, model: model) { self.sheet = nil }
        }
    }

    private func rebuildIfNeeded() {
        let current = ConnectedMailBackend.current()
        if current !== model.backend || current.availability != model.availability {
            model = MailWorkspaceModel(backend: current)
        }
        Task { await model.refresh() }
    }
}

// MARK: - Sheets

enum MailSheet: Identifiable, Equatable {
    case addAccount
    case compose(UUID)                       // draft id
    case reply(emailID: UUID, kind: Draft.Kind)
    case cleanup(UUID, only: UUID?)          // account id, one message (nil = the listed ones)
    case removeAccount(UUID)
    case upgrade
    /// IMAP account that needs sign-in: a new password.
    case replacePassword(UUID)
    /// A removed account's archived mail, deleted later (count typed first).
    case deleteRemovedMail(UUID)

    var id: String {
        switch self {
        case .addAccount: return "add"
        case .compose(let id): return "compose-\(id)"
        case .reply(let id, let kind): return "reply-\(id)-\(kind.rawValue)"
        case .cleanup(let id, let only): return "cleanup-\(id)-\(only?.uuidString ?? "all")"
        case .removeAccount(let id): return "remove-\(id)"
        case .upgrade: return "upgrade"
        case .replacePassword(let id): return "password-\(id)"
        case .deleteRemovedMail(let id): return "delete-removed-\(id)"
        }
    }
}

private struct MailSheetHost: View {
    let sheet: MailSheet
    let model: MailWorkspaceModel
    let dismiss: () -> Void

    var body: some View {
        Group {
            switch sheet {
            case .addAccount: MailAddAccountView(model: model, dismiss: dismiss)
            case .compose(let id): MailComposeSheet(model: model, draftID: id, dismiss: dismiss)
            case .reply(let emailID, let kind): MailReplySetupView(model: model, emailID: emailID, kind: kind, dismiss: dismiss)
            case .cleanup(let account, let only): MailCleanupView(model: model, accountID: account, only: only, dismiss: dismiss)
            case .removeAccount(let account): MailRemoveAccountView(model: model, accountID: account, dismiss: dismiss)
            case .upgrade: MailUpgradeInventoryView(model: model, dismiss: dismiss)
            case .replacePassword(let account): MailReplacePasswordView(model: model, accountID: account, dismiss: dismiss)
            case .deleteRemovedMail(let account): MailDeleteRemovedMailView(model: model, accountID: account, dismiss: dismiss)
            }
        }
        #if os(macOS)
        .frame(minWidth: isComposer ? 640 : 520, idealWidth: isComposer ? 760 : 620,
               minHeight: isComposer ? 560 : 420, idealHeight: isComposer ? 720 : 560)
        #endif
    }

    /// Writing a message gets a window sized like Mail's, not a settings sheet.
    private var isComposer: Bool {
        switch sheet {
        case .compose, .reply: return true
        default: return false
        }
    }
}

// MARK: - Not available

struct MailUnavailableView: View {
    let availability: MailWorkspaceAvailability
    let turnOn: () -> Void

    var body: some View {
        VStack(spacing: Spacing.small) {
            Image(systemName: availability == .notInThisEdition ? "envelope.badge.shield.half.filled" : "envelope")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(availability.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(availability.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            // Only a build that has the mail code offers the one control.
            if availability == .mailSwitchedOff {
                Button(String(localized: "Turn on Connected mail"), action: turnOn)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(Text("Allows accounts to be added. Nothing connects until you add an account and allow it."))
                    .accessibilityIdentifier("mail.turnOn")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mail.unavailable")
    }
}

// MARK: - Workspace

private struct MailWorkspaceReadyView: View {
    @Bindable var model: MailWorkspaceModel
    @Binding var sheet: MailSheet?

    var body: some View {
        NavigationSplitView {
            MailSidebar(model: model, sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            MailContentColumn(model: model, sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            MailDetailColumn(model: model, sheet: $sheet)
        }
        .mailNoTopFade()
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { statusLine }
        .onChange(of: model.section) { _, _ in
            model.selectedMessage = nil
            Task { await model.reloadMailbox() }
        }
        .alert(String(localized: "Extra permission needed"), isPresented: Binding(
            get: { model.pendingReconsent != nil },
            set: { shown in
                // Cleared after the button's own action has read the request.
                guard !shown, let asked = model.pendingReconsent else { return }
                Task { @MainActor in if model.pendingReconsent == asked { model.pendingReconsent = nil } }
            })) {
            Button(String(localized: "Sign in again")) {
                if let r = model.pendingReconsent { Task { await model.reconsent(r.accountID, scope: r.scope, mode: r.mode) } }
            }
            Button(String(localized: "Not now"), role: .cancel) {
                // The mode that needed the permission goes back off.
                if let r = model.pendingReconsent { Task { await model.declineReconsent(r) } }
            }
        } message: {
            Text(model.pendingReconsent?.text ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await newDraft() } } label: {
                Label(String(localized: "Compose"), systemImage: "square.and.pencil")
            }
            .disabled(!model.actions.contains(.compose))
            .help(model.actions.contains(.compose) ? String(localized: "New message") : String(localized: "Turn on Send mail for an account to compose"))
            .keyboardShortcut("n", modifiers: [.command, .option])
            .accessibilityIdentifier("mail.compose")

            Button { Task { await model.syncNow() } } label: {
                if model.busy || model.anyRunning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("Saving mail"))
                } else {
                    Label(String(localized: "Sync now"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(!model.actions.contains(.syncNow) || model.busy || model.anyRunning)
            .help(model.syncNowHelp)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .accessibilityIdentifier("mail.syncNow")

            Button { sheet = .addAccount } label: {
                Label(String(localized: "Add account"), systemImage: "person.crop.circle.badge.plus")
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .accessibilityIdentifier("mail.addAccount")
        }
    }

    private func newDraft() async {
        guard let account = model.accounts.first(where: { $0.account.enabledModes.contains(.send) }) else { return }
        await model.run {
            let draft = try await model.backend.createDraft(DraftSeed(draft: Draft(accountID: account.id)))
            await model.reloadDrafts()
            sheet = .compose(draft.id)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let text = model.lastError ?? model.message {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: model.lastError == nil ? "info.circle" : "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text(text).font(.caption).lineLimit(3)
                Spacer()
                Button {
                    model.lastError = nil; model.message = nil
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(model.lastError == nil ? "mail.status.message" : "mail.status.error")
        }
    }
}

// MARK: - Sidebar

private struct MailSidebar: View {
    @Bindable var model: MailWorkspaceModel
    @Binding var sheet: MailSheet?
    /// Accounts whose folder list the person closed; every account starts open.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Section(String(localized: "Mailboxes")) {
                Label(String(localized: "All accounts"), systemImage: "tray.2")
                    .tag(MailWorkspaceModel.Section.unifiedInbox)
                    .accessibilityHint(Text("Captured mail of every account, newest first"))
                ForEach(model.accounts) { snapshot in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsed.contains(snapshot.id) },
                        set: { open in if open { collapsed.remove(snapshot.id) } else { collapsed.insert(snapshot.id) } })) {
                        ForEach(MailFolderStyle.ordered(model.folders[snapshot.id] ?? [])) { folder in
                            HStack {
                                Label(folder.path, systemImage: MailFolderStyle.role(folder).symbol)
                                Spacer()
                                if folder.unread > 0 {
                                    Text("\(folder.unread)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(MailWorkspaceModel.Section.folder(snapshot.id, folder.serverID))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text("\(folder.path), \(folder.messages) messages, \(folder.unread) unread"))
                            .accessibilityIdentifier("mail.sidebar.folder")
                        }
                    } label: {
                        HStack(spacing: Spacing.xxSmall) {
                            MailAccountBadge(account: snapshot.account, headline: snapshot.headline)
                            if snapshot.isRunning {
                                Spacer(minLength: 0)
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel(Text("Saving mail"))
                            }
                        }
                        .accessibilityIdentifier("mail.sidebar.account")
                        .tag(MailWorkspaceModel.Section.account(snapshot.id))
                    }
                }
            }
            if !model.smartFolders.isEmpty {
                Section(String(localized: "Smart Folders")) {
                    ForEach(model.smartFolders) { folder in
                        Label(folder.name, systemImage: "line.3.horizontal.decrease.circle")
                            .tag(MailWorkspaceModel.Section.smart(folder.id))
                            .help(folder.summary)
                            .contextMenu {
                                Button(String(localized: "Delete Smart Folder"), role: .destructive) { model.deleteSmartFolder(folder.id) }
                            }
                            .accessibilityHint(Text(folder.summary))
                    }
                }
            }
            Section(String(localized: "Sending")) {
                Label {
                    Text("Drafts")
                } icon: { Image(systemName: "doc.text") }
                .badge(model.drafts.count)
                .tag(MailWorkspaceModel.Section.drafts)
                Label {
                    Text("Outbox")
                } icon: { Image(systemName: "tray.and.arrow.up") }
                .badge(model.outbox.filter { !$0.state.isAccepted && $0.state.name != "cancelledBeforeSubmission" }.count)
                .tag(MailWorkspaceModel.Section.outbox)
            }
            Section(String(localized: "Settings")) {
                Label(String(localized: "Accounts and status"), systemImage: "person.2")
                    .tag(MailWorkspaceModel.Section.accounts)
            }
        }
        .navigationTitle(String(localized: "Mail"))
        .safeAreaInset(edge: .bottom) {
            // Where Mail users look for it: always visible under the account list.
            Button { sheet = .addAccount } label: {
                Label(String(localized: "Add account"), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xSmall)
            .background(.bar)
            .accessibilityIdentifier("mail.addAccount.sidebar")
        }
        .background {
            // Section shortcuts (hidden buttons: they work while the page shows).
            Group {
                Button("") { model.section = .unifiedInbox }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("") { model.section = .drafts }.keyboardShortcut("e", modifiers: [.command, .option])
                Button("") { model.section = .outbox }.keyboardShortcut("o", modifiers: [.command, .option])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

/// Mail's folder order and icons: Inbox, Drafts, Sent, Archive, Junk, Trash,
/// Outbox, then the person's own folders A–Z, then labels. The provider's
/// special-use mark decides (IMAP `\Sent`, Graph `sentitems`, Gmail `\Junk`);
/// the folder's name is used only when the server marks nothing.
enum MailFolderStyle {
    enum Role: Int, Comparable {
        case inbox, drafts, sent, archive, junk, trash, outbox, other, label
        static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }

        var symbol: String {
            switch self {
            case .inbox: return "tray"
            case .drafts: return "doc"
            case .sent: return "paperplane"
            case .archive: return "archivebox"
            case .junk: return "xmark.bin"
            case .trash: return "trash"
            case .outbox: return "tray.and.arrow.up"
            case .other: return "folder"
            case .label: return "tag"
            }
        }
    }

    static func role(_ folder: ConnectedFolderSummary) -> Role {
        if let mark = folder.specialUse.map(normalised), let role = role(named: mark) { return role }
        if folder.kind == .label { return .label }
        let name = normalised(folder.path.split(separator: "/").last.map(String.init) ?? folder.path)
        return folder.path.contains("/") ? .other : (role(named: name) ?? .other)
    }

    static func ordered(_ folders: [ConnectedFolderSummary]) -> [ConnectedFolderSummary] {
        folders.sorted {
            let (a, b) = (role($0), role($1))
            return a != b ? a < b : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: " ", with: "")
    }

    private static func role(named s: String) -> Role? {
        switch s {
        case "inbox": return .inbox
        case "drafts": return .drafts
        case "sent", "sentitems", "sentmail", "sentmessages": return .sent
        case "archive", "all", "allmail": return .archive
        case "junk", "junkemail", "spam": return .junk
        case "trash", "deleteditems", "deletedmessages", "bin": return .trash
        case "outbox": return .outbox
        default: return nil
        }
    }
}

/// An account's colour badge and address — the same in the sidebar and in every row.
struct MailAccountBadge: View {
    let account: MailAccount
    var headline: String?

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            Circle()
                .fill(Self.color(for: account.id))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayIdentity).lineLimit(1)
                if let headline {
                    Text(headline).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func color(for id: UUID) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        let value = id.uuid.0 ^ id.uuid.5 ^ id.uuid.10 ^ id.uuid.15
        return palette[Int(value) % palette.count]
    }
}

// MARK: - Content column

private struct MailContentColumn: View {
    @Bindable var model: MailWorkspaceModel
    @Binding var sheet: MailSheet?

    var body: some View {
        switch model.section {
        case .drafts: MailDraftsList(model: model, sheet: $sheet)
        case .outbox: MailOutboxList(model: model)
        case .accounts: MailAccountsList(model: model, sheet: $sheet)
        default: MailMessageList(model: model, sheet: $sheet)
        }
    }
}

/// Apple Mail's list (sender, subject, two-line preview, hover and swipe
/// actions) with Thunderbird's quick filter, tags, conversations and
/// actions on several selected messages.
private struct MailMessageList: View {
    @Bindable var model: MailWorkspaceModel
    @Binding var sheet: MailSheet?
    @State private var savingSearch = false
    @State private var searchName = ""
    @State private var newTagFor: [UUID] = []
    @State private var newTagName = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            if model.rows.isEmpty { emptyState }
            if model.groupConversations {
                ForEach(model.conversations) { conversation in
                    if conversation.rows.count == 1 {
                        row(conversation.latest)
                    } else {
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expandedConversations.contains(conversation.key) },
                            set: { open in
                                if open { model.expandedConversations.insert(conversation.key) }
                                else { model.expandedConversations.remove(conversation.key) }
                            })) {
                            ForEach(conversation.rows.dropFirst()) { row($0) }
                        } label: {
                            row(conversation.latest, conversationCount: conversation.rows.count)
                        }
                    }
                }
            } else {
                ForEach(model.rows) { row($0) }
            }
            if model.hasMoreRows {
                Button(String(localized: "Show more")) { Task { await model.loadMore() } }
                    .accessibilityHint(Text(model.showingCountText))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            selectionMenu(Array(ids))
        }
        .mailTopBar { quickFilterBar }
        .overlay(alignment: .bottom) {
            if !model.rows.isEmpty {
                Text("Read and flag marks are as they were when each message was saved.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(Spacing.xxSmall)
            }
        }
        .alert(String(localized: "Save as Smart Folder"), isPresented: $savingSearch) {
            TextField(String(localized: "Name"), text: $searchName)
            Button(String(localized: "Save")) { model.saveSmartFolder(named: searchName); searchName = "" }
            Button(String(localized: "Cancel"), role: .cancel) { searchName = "" }
        } message: {
            Text("The smart folder lists every message that matches this filter, now and after each sync.")
        }
        .alert(String(localized: "New Tag"), isPresented: Binding(get: { !newTagFor.isEmpty }, set: { if !$0 { newTagFor = [] } })) {
            TextField(String(localized: "Name"), text: $newTagName)
            Button(String(localized: "Add")) {
                let ids = newTagFor, name = newTagName
                newTagFor = []; newTagName = ""
                Task { await model.toggleTag(name, on: ids) }
            }
            Button(String(localized: "Cancel"), role: .cancel) { newTagFor = []; newTagName = "" }
        } message: {
            Text("Tags stay in mailin; nothing changes on the server.")
        }
    }

    private func row(_ row: ConnectedMailboxRow, conversationCount: Int = 1) -> some View {
        MailRowView(row: row, account: model.account(row.accountID)?.account,
                    tags: model.tags[row.emailID].map { Array($0).sorted() } ?? [],
                    conversationCount: conversationCount,
                    canChange: model.canChangeOnServer(row),
                    onReply: { sheet = .reply(emailID: row.emailID, kind: .reply) },
                    canReply: model.accounts.contains { $0.account.enabledModes.contains(.send) },
                    onServer: { request in Task { await model.changeOnServer(request, row: row) } },
                    onTrash: { sheet = .cleanup(row.accountID, only: row.emailID) },
                    tagMenu: { AnyView(tagMenu([row.emailID])) })
            .tag(row.emailID)
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if model.accounts.isEmpty {
            VStack(spacing: Spacing.small) {
                Text(String(localized: "No accounts yet. Add one to start."))
                    .foregroundStyle(.secondary)
                Button { sheet = .addAccount } label: {
                    Label(String(localized: "Add account"), systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("mail.addAccount.empty")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.large)
        } else if model.isQuickFiltered {
            ContentUnavailableView {
                Label(String(localized: "No messages match the filter."), systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button(String(localized: "Clear filter")) { model.clearQuickFilter() }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        } else {
            ContentUnavailableView {
                Label(String(localized: "No captured messages here yet."), systemImage: "tray")
            } description: {
                Text("Mail appears here once Preserve mail has saved it. Sync now checks the server again.")
            } actions: {
                Button(String(localized: "Sync now")) { Task { await model.syncNow() } }
                    .disabled(!model.actions.contains(.syncNow) || model.busy || model.anyRunning)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: Quick filter (Thunderbird)

    private var quickFilterBar: some View {
        VStack(spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(String(localized: "Filter these messages"), text: $model.quickText)
                        .textFieldStyle(.plain)
                        .focused($filterFocused)
                        .accessibilityIdentifier("mail.quickFilter")
                    if !model.quickText.isEmpty {
                        Button { model.quickText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Clear filter"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
                .help(String(localized: "Matches the sender, recipients, subject and preview of the listed messages"))
                Menu {
                    Toggle(String(localized: "Group by Conversation"), isOn: $model.groupConversations)
                    Divider()
                    Button(String(localized: "Save as Smart Folder…")) { savingSearch = true }
                        .disabled(!model.isQuickFiltered)
                    Button(String(localized: "Clear filter")) { model.clearQuickFilter() }
                        .disabled(!model.isQuickFiltered)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("List options"))
            }
            HStack(spacing: Spacing.xxSmall) {
                Toggle(isOn: $model.unreadOnly) { Label(String(localized: "Unread"), systemImage: "envelope.badge") }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .help(String(localized: "Unread"))
                    .accessibilityHint(Text("Shows only messages that were unread when they were saved"))
                Toggle(isOn: $model.flaggedOnly) { Label(String(localized: "Flagged"), systemImage: "flag") }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .help(String(localized: "Flagged"))
                Toggle(isOn: $model.attachmentsOnly) { Label(String(localized: "Attachments"), systemImage: "paperclip") }
                    .help(String(localized: "Attachments"))
                Menu {
                    Button(String(localized: "Any tag")) { model.tagFilter = nil }
                    Divider()
                    ForEach(model.offeredTags, id: \.self) { tag in
                        Button { model.tagFilter = tag } label: {
                            Label(tag, systemImage: model.tagFilter == tag ? "checkmark.circle.fill" : "circle.fill")
                        }
                        .tint(MailTagPalette.color(for: tag))
                    }
                } label: {
                    Label(model.tagFilter ?? String(localized: "Tags"), systemImage: "tag")
                }
                .fixedSize()
                .help(String(localized: "Tags"))
                Spacer(minLength: 0)
            }
            .toggleStyle(.button)
            // Icons only: the list column is narrow; each says its name on hover and to VoiceOver.
            .labelStyle(.iconOnly)
            Text(model.showingCountText).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mail.list.showing")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xxSmall)
        .background {
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0).accessibilityHidden(true)
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func tagMenu(_ ids: [UUID]) -> some View {
        ForEach(model.offeredTags, id: \.self) { tag in
            let all = ids.allSatisfy { model.tags[$0]?.contains(tag) == true }
            Button { Task { await model.toggleTag(tag, on: ids) } } label: {
                Label(tag, systemImage: all ? "checkmark.circle.fill" : "circle.fill")
            }
            .tint(MailTagPalette.color(for: tag))
        }
        Divider()
        Button(String(localized: "New Tag…")) { newTagFor = ids }
    }

    @ViewBuilder
    private func selectionMenu(_ ids: [UUID]) -> some View {
        let chosen = model.rows.filter { ids.contains($0.emailID) }
        if chosen.count == 1, let only = chosen.first {
            Button(String(localized: "Reply")) { sheet = .reply(emailID: only.emailID, kind: .reply) }
            Button(String(localized: "Reply All")) { sheet = .reply(emailID: only.emailID, kind: .replyAll) }
            Button(String(localized: "Forward")) { sheet = .reply(emailID: only.emailID, kind: .forward) }
            Divider()
        }
        if !chosen.isEmpty {
            Menu(String(localized: "Tag")) { tagMenu(chosen.map(\.emailID)) }
            if chosen.contains(where: model.canChangeOnServer) {
                Menu(String(localized: "On the server")) {
                    Button(String(localized: "Mark as read on the server")) { Task { await model.changeOnServer(.markRead, rows: chosen) } }
                    Button(String(localized: "Mark as unread on the server")) { Task { await model.changeOnServer(.markUnread, rows: chosen) } }
                    Button(String(localized: "Flag on the server")) { Task { await model.changeOnServer(.flag, rows: chosen) } }
                    Button(String(localized: "Remove flag on the server")) { Task { await model.changeOnServer(.unflag, rows: chosen) } }
                    if chosen.count == 1, let only = chosen.first {
                        Divider()
                        Button(String(localized: "Move to the server's Trash…")) { sheet = .cleanup(only.accountID, only: only.emailID) }
                    }
                }
            }
        }
    }
}

/// One message in the Apple Mail layout: sender and date, subject, a
/// two-line preview, then tags and the account. Hover (Mac) and swipe show
/// the quick actions; server ones only when Change server mail allows them.
private struct MailRowView: View {
    let row: ConnectedMailboxRow
    let account: MailAccount?
    let tags: [String]
    var conversationCount = 1
    let canChange: Bool
    let onReply: () -> Void
    let canReply: Bool
    let onServer: (RemoteChangeRequest) -> Void
    let onTrash: () -> Void
    let tagMenu: () -> AnyView
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            Circle()
                .fill(row.isRead == false ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.from.isEmpty ? String(localized: "(no sender)") : MailOrganize.displayName(row.from))
                        .fontWeight(row.isRead == false ? .semibold : .medium)
                        .lineLimit(1)
                    if conversationCount > 1 {
                        Text("\(conversationCount)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .accessibilityLabel(Text("\(conversationCount) messages in this conversation"))
                    }
                    Spacer(minLength: 4)
                    if hovering { hoverActions } else {
                        Text(MailOrganize.listDate(row.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(row.subject.isEmpty ? String(localized: "(no subject)") : row.subject)
                        .font(.callout).lineLimit(1)
                    Spacer(minLength: 0)
                    if row.isFlagged == true { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    if row.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                }
                if !row.preview.isEmpty {
                    Text(MailOrganize.cleanPreview(row.preview))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !tags.isEmpty || account != nil || !row.onServer {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Circle().fill(MailTagPalette.color(for: tag)).frame(width: 7, height: 7)
                                Text(tag)
                            }
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(MailTagPalette.color(for: tag).opacity(0.15)))
                        }
                        if !row.onServer {
                            Text("Removed from the server; kept here").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let account {
                            HStack(spacing: 3) {
                                Circle().fill(MailAccountBadge.color(for: account.id)).frame(width: 6, height: 6)
                                Text(account.displayIdentity).lineLimit(1)
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canChange {
                Button { onServer(row.isRead == false ? .markRead : .markUnread) } label: {
                    Label(row.isRead == false ? String(localized: "Read") : String(localized: "Unread"),
                          systemImage: row.isRead == false ? "envelope.open" : "envelope.badge")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canChange {
                Button(role: .destructive, action: onTrash) { Label(String(localized: "Trash"), systemImage: "trash") }
                Button { onServer(row.isFlagged == true ? .unflag : .flag) } label: {
                    Label(row.isFlagged == true ? String(localized: "Unflag") : String(localized: "Flag"), systemImage: "flag")
                }
                .tint(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// Mac: quick buttons where the date was while the pointer is over the row.
    private var hoverActions: some View {
        HStack(spacing: 6) {
            Button(action: onReply) { Image(systemName: "arrowshape.turn.up.left") }
                .disabled(!canReply)
                .help(String(localized: "Reply"))
            if canChange {
                Button { onServer(row.isFlagged == true ? .unflag : .flag) } label: {
                    Image(systemName: row.isFlagged == true ? "flag.slash" : "flag")
                }
                .help(row.isFlagged == true ? String(localized: "Remove flag on the server") : String(localized: "Flag on the server"))
                Button(action: onTrash) { Image(systemName: "trash") }
                    .help(String(localized: "Move to the server's Trash…"))
            }
            Menu { tagMenu() } label: { Image(systemName: "tag") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Tag"))
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var accessibilityText: String {
        var parts = [row.from, row.subject, row.date.formatted(date: .abbreviated, time: .omitted)]
        if conversationCount > 1 { parts.append(String(localized: "\(conversationCount) messages in this conversation")) }
        if row.isRead == false { parts.append(String(localized: "Unread")) }
        if row.isFlagged == true { parts.append(String(localized: "Flagged")) }
        if row.hasAttachments { parts.append(String(localized: "Has attachments")) }
        parts += tags
        if !row.onServer { parts.append(String(localized: "Removed from the server; kept here")) }
        if let account { parts.append(account.displayIdentity) }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    /// A bar pinned above a list, on its own bar background.
    func mailTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { bar(); Divider() }.background(.bar) }
    }

    /// The Live Mail page sits below the page strip, not under the window's
    /// toolbar, yet macOS 26 drew the window toolbar's background band (one
    /// toolbar tall) over the top of the list and reading columns: the first
    /// message and the filter bar were hidden under it (owner screenshots
    /// 2026-11-15; measured: the columns' safe-area top is 0, the band is an
    /// overlay). Nothing scrolls under the toolbar here (the page is clipped
    /// below the strip), so the band and the top fade are switched off.
    @ViewBuilder
    func mailNoTopFade() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

// MARK: - Tags and several selected messages

/// Add or remove tags (local) on the given messages; the colour of each tag can be changed.
struct MailTagMenu: View {
    let model: MailWorkspaceModel
    let ids: [UUID]
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(model.offeredTags, id: \.self) { tag in
                let all = !ids.isEmpty && ids.allSatisfy { model.tags[$0]?.contains(tag) == true }
                Button { Task { await model.toggleTag(tag, on: ids) } } label: {
                    Label(tag, systemImage: all ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            Divider()
            Button(String(localized: "New Tag…")) { naming = true }
            Menu(String(localized: "Tag Colour")) {
                ForEach(model.offeredTags, id: \.self) { tag in
                    Menu(tag) {
                        ForEach(MailTagPalette.colors.indices, id: \.self) { i in
                            Button(MailTagPalette.colors[i].name) { MailTagPalette.setColor(i, for: tag); Task { await model.loadTags() } }
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "Tag"), systemImage: "tag")
        }
        .fixedSize()
        .help(String(localized: "Tags stay in mailin; nothing changes on the server."))
        .alert(String(localized: "New Tag"), isPresented: $naming) {
            TextField(String(localized: "Name"), text: $name)
            Button(String(localized: "Add")) { let n = name; name = ""; Task { await model.toggleTag(n, on: ids) } }
            Button(String(localized: "Cancel"), role: .cancel) { name = "" }
        }
    }
}

/// Several messages selected: what can be done to all of them at once.
private struct MailSelectionSummary: View {
    let model: MailWorkspaceModel
    let rows: [ConnectedMailboxRow]

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(rows.count) messages selected").font(.title3.weight(.semibold))
            HStack(spacing: Spacing.small) {
                MailTagMenu(model: model, ids: rows.map(\.emailID))
                if rows.contains(where: model.canChangeOnServer) {
                    Menu {
                        Button(String(localized: "Mark as read on the server")) { Task { await model.changeOnServer(.markRead, rows: rows) } }
                        Button(String(localized: "Mark as unread on the server")) { Task { await model.changeOnServer(.markUnread, rows: rows) } }
                        Button(String(localized: "Flag on the server")) { Task { await model.changeOnServer(.flag, rows: rows) } }
                        Button(String(localized: "Remove flag on the server")) { Task { await model.changeOnServer(.unflag, rows: rows) } }
                    } label: {
                        Label(String(localized: "On the server"), systemImage: "server.rack")
                    }
                    .fixedSize()
                }
                Button(String(localized: "Clear Selection")) { model.selection = [] }
            }
            .controlSize(.large)
            if !rows.contains(where: model.canChangeOnServer) {
                Text("Turn on Change server mail for the account to mark or flag these on the server.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail column

private struct MailDetailColumn: View {
    @Bindable var model: MailWorkspaceModel
    @Binding var sheet: MailSheet?

    var body: some View {
        switch model.section {
        case .accounts:
            if let id = model.selectedAccount, model.account(id) != nil {
                MailAccountSettingsView(model: model, accountID: id, sheet: $sheet)
            } else {
                Text("Choose an account to see its settings and status.").foregroundStyle(.secondary)
            }
        case .account(let id) where model.selection.isEmpty:
            MailAccountSettingsView(model: model, accountID: id, sheet: $sheet)
        case .drafts, .outbox:
            Text("Choose an item.").foregroundStyle(.secondary)
        default:
            if model.selection.count > 1 {
                MailSelectionSummary(model: model, rows: model.selectedRows)
            } else if let id = model.selectedMessage, let row = model.rows.first(where: { $0.emailID == id }) {
                MailMessageDetail(model: model, row: row, sheet: $sheet)
                    .id(id)
            } else {
                ContentUnavailableView(String(localized: "Choose a message."), systemImage: "envelope")
            }
        }
    }
}

/// The existing safe message view, with Mail's own actions above it.
/// Opening a message changes nothing on the server.
private struct MailMessageDetail: View {
    let model: MailWorkspaceModel
    let row: ConnectedMailboxRow
    @Binding var sheet: MailSheet?
    @State private var email: MBOXParser.RawEmail?
    @State private var loadError: String?

    private var canReply: Bool { model.accounts.contains { $0.account.enabledModes.contains(.send) } }

    var body: some View {
        VStack(spacing: 0) {
            actions
            Divider()
            if let email {
                EmailDetailView(email: email)
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                ProgressView().padding()
                Spacer()
            }
        }
        .task {
            do { email = try await model.backend.email(row.emailID) } catch { loadError = ConnectedMailErrorText.text(for: error) }
            if email == nil, loadError == nil { loadError = String(localized: "The archived message is no longer in the archive.") }
        }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xSmall) {
                replyButtons
                    .disabled(!canReply)
                    .help(canReply ? "" : String(localized: "Turn on Send mail for an account to reply or forward"))
                Divider().frame(height: 18)
                MailTagMenu(model: model, ids: [row.emailID])
                if model.canChangeOnServer(row) {
                    Button { Task { await model.changeOnServer(row.isFlagged == true ? .unflag : .flag, row: row) } } label: {
                        Label(row.isFlagged == true ? String(localized: "Unflag") : String(localized: "Flag"),
                              systemImage: row.isFlagged == true ? "flag.slash" : "flag")
                    }
                    .help(row.isFlagged == true ? String(localized: "Remove flag on the server") : String(localized: "Flag on the server"))
                    serverMenu
                }
                ForEach(model.tags[row.emailID].map { Array($0).sorted() } ?? [], id: \.self) { tag in
                    HStack(spacing: 3) {
                        Circle().fill(MailTagPalette.color(for: tag)).frame(width: 7, height: 7)
                        Text(tag)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(MailTagPalette.color(for: tag).opacity(0.15)))
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
        }
    }

    @ViewBuilder
    private var replyButtons: some View {
        Group {
                Button { sheet = .reply(emailID: row.emailID, kind: .reply) } label: {
                    Label(String(localized: "Reply"), systemImage: "arrowshape.turn.up.left")
                }
                .keyboardShortcut("r", modifiers: .command)
                Button { sheet = .reply(emailID: row.emailID, kind: .replyAll) } label: {
                    Label(String(localized: "Reply All"), systemImage: "arrowshape.turn.up.left.2")
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                Button { sheet = .reply(emailID: row.emailID, kind: .forward) } label: {
                    Label(String(localized: "Forward"), systemImage: "arrowshape.turn.up.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button { sheet = .reply(emailID: row.emailID, kind: .forwardAsAttachment) } label: {
                    Label(String(localized: "Forward as Attachment"), systemImage: "paperclip")
                }
        }
    }

    private var serverMenu: some View {
                    Menu {
                        Button(String(localized: "Mark as read on the server")) { Task { await model.changeOnServer(.markRead, row: row) } }
                        Button(String(localized: "Mark as unread on the server")) { Task { await model.changeOnServer(.markUnread, row: row) } }
                        Button(String(localized: "Flag on the server")) { Task { await model.changeOnServer(.flag, row: row) } }
                        Button(String(localized: "Remove flag on the server")) { Task { await model.changeOnServer(.unflag, row: row) } }
                        Divider()
                        Button(String(localized: "Move to the server's Trash…")) { sheet = .cleanup(row.accountID, only: row.emailID) }
                    } label: {
                        Label(String(localized: "On the server"), systemImage: "server.rack")
                    }
                    .help(String(localized: "Changes this message on the mail server. The copy saved in mailin is not changed."))
    }
}
