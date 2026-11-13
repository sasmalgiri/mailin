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

    var id: String {
        switch self {
        case .addAccount: return "add"
        case .compose(let id): return "compose-\(id)"
        case .reply(let id, let kind): return "reply-\(id)-\(kind.rawValue)"
        case .cleanup(let id, let only): return "cleanup-\(id)-\(only?.uuidString ?? "all")"
        case .removeAccount(let id): return "remove-\(id)"
        case .upgrade: return "upgrade"
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
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 560)
        #endif
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
                .navigationSplitViewColumnWidth(min: 260, ideal: 340)
        } detail: {
            MailDetailColumn(model: model, sheet: $sheet)
        }
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
            .help(String(localized: "Save new mail from every account that may preserve mail"))
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

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Section(String(localized: "Mailboxes")) {
                Label(String(localized: "All accounts"), systemImage: "tray.2")
                    .tag(MailWorkspaceModel.Section.unifiedInbox)
                    .accessibilityHint(Text("Captured mail of every account, newest first"))
                ForEach(model.accounts) { snapshot in
                    DisclosureGroup {
                        ForEach(model.folders[snapshot.id] ?? []) { folder in
                            HStack {
                                Label(folder.path, systemImage: folder.kind == .label ? "tag" : "folder")
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
        default: messageList
        }
    }

    private var messageList: some View {
        List(selection: $model.selectedMessage) {
            if model.rows.isEmpty {
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
                } else {
                    Text(String(localized: "No captured messages here yet."))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.rows) { row in
                MailRowView(row: row, account: model.account(row.accountID)?.account)
                    .tag(row.emailID)
            }
            if model.hasMoreRows {
                Button(String(localized: "Show more")) { Task { await model.loadMore() } }
                    .accessibilityHint(Text(model.showingCountText))
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: Spacing.xSmall) {
                Toggle(isOn: $model.unreadOnly) { Label(String(localized: "Unread"), systemImage: "envelope.badge") }
                    .toggleStyle(.button)
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .accessibilityHint(Text("Shows only messages that were unread when they were saved"))
                Toggle(isOn: $model.flaggedOnly) { Label(String(localized: "Flagged"), systemImage: "flag") }
                    .toggleStyle(.button)
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Spacer()
                Text(model.showingCountText).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mail.list.showing")
            }
            .controlSize(.small)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
            .background(.bar)
        }
        .overlay(alignment: .bottom) {
            Text("Read and flag marks are as they were when each message was saved.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(Spacing.xxSmall)
        }
    }
}

private struct MailRowView: View {
    let row: ConnectedMailboxRow
    let account: MailAccount?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            Circle()
                .fill(account.map { MailAccountBadge.color(for: $0.id) } ?? .gray)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.from.isEmpty ? String(localized: "(no sender)") : row.from)
                        .fontWeight(row.isRead == false ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    Text(row.date, format: .dateTime.day().month().year())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(row.subject.isEmpty ? String(localized: "(no subject)") : row.subject)
                    .font(.callout).lineLimit(1)
                HStack(spacing: Spacing.xxSmall) {
                    if row.isRead == false { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.blue) }
                    if row.isFlagged == true { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.orange) }
                    if row.hasAttachments { Image(systemName: "paperclip").font(.caption2) }
                    if !row.onServer {
                        Text("Removed from the server; kept here").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let account { Text(account.displayIdentity).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [row.from, row.subject, row.date.formatted(date: .abbreviated, time: .omitted)]
        if row.isRead == false { parts.append(String(localized: "Unread")) }
        if row.isFlagged == true { parts.append(String(localized: "Flagged")) }
        if row.hasAttachments { parts.append(String(localized: "Has attachments")) }
        if !row.onServer { parts.append(String(localized: "Removed from the server; kept here")) }
        if let account { parts.append(account.displayIdentity) }
        return parts.joined(separator: ", ")
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
        case .account(let id) where model.selectedMessage == nil:
            MailAccountSettingsView(model: model, accountID: id, sheet: $sheet)
        case .drafts, .outbox:
            Text("Choose an item.").foregroundStyle(.secondary)
        default:
            if let id = model.selectedMessage, let row = model.rows.first(where: { $0.emailID == id }) {
                MailMessageDetail(model: model, row: row, sheet: $sheet)
                    .id(id)
            } else {
                Text("Choose a message.").foregroundStyle(.secondary)
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
                if model.canChangeOnServer(row) {
                    Divider().frame(height: 18)
                    serverMenu
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
