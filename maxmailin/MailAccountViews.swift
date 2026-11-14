@testable import ArchiveCore
import MailConnectivity
//
//  MailAccountViews.swift
//  maxmailin
//
//  Plan v4 V4-13: adding an account (Gmail, Outlook / Microsoft 365, IMAP with
//  iCloud / Fastmail / other presets), each account's permissions (all off
//  by default, each explained), folder selection with counts, status with the
//  four kinds of completeness, Sync now / pause, removal with counts first,
//  and the upgrade inventory (old sign-in items assigned only by choice;
//  earlier incomplete online imports listed for comparison).
//

import SwiftUI

// MARK: - Add account

struct MailAddAccountView: View {
    let model: MailWorkspaceModel
    let dismiss: () -> Void
    @State private var choice: MailProviderChoice
    @State private var address = ""
    @State private var form = MailIMAPForm()
    @State private var working = false

    init(model: MailWorkspaceModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        // V4-16: the build decides which Gmail path is listed (and so first).
        _choice = State(initialValue: model.offeredProviders.first ?? .iCloud)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Provider"), selection: $choice) {
                        ForEach(model.offeredProviders) { Text($0.title).tag($0) }
                    }
                    .onChange(of: choice) { _, new in form.apply(new) }
                    .accessibilityIdentifier("mail.add.provider")
                } footer: {
                    Text("A new account is allowed nothing until you switch on what it may do: preserve mail, send mail, change server mail.")
                }

                switch model.providerReadiness(choice) {
                case .unavailable(let reason):
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("mail.add.notConfigured")
                    }
                case .ready:
                    if choice.usesOAuth { oauthSection } else { imapSection }
                }

                if let error = model.lastError {
                    Section { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("mail.add.error") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Add account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: dismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(choice.usesOAuth ? String(localized: "Sign in…") : String(localized: "Add")) { Task { await add() } }
                        .disabled(!canAdd || working)
                        .help(addHelp)
                        .accessibilityIdentifier("mail.add.confirm")
                }
            }
        }
        .onAppear {
            form.apply(choice)
            // An error from elsewhere on the page is not this sheet's.
            model.lastError = nil
        }
    }

    private var canAdd: Bool {
        guard model.providerReadiness(choice).isReady else { return false }
        if choice.usesOAuth { return (try? MailAddress(parsing: address.trimmingCharacters(in: .whitespaces))) != nil }
        return form.problem == nil
    }

    private var addHelp: String {
        if case .unavailable(let reason) = model.providerReadiness(choice) { return reason }
        if choice.usesOAuth { return canAdd ? String(localized: "Opens the provider's sign-in page") : String(localized: "Enter your email address.") }
        return form.problem ?? String(localized: "Adds the account with nothing allowed yet")
    }

    private var oauthSection: some View {
        Section {
            TextField(String(localized: "Email address"), text: $address)
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityIdentifier("mail.add.address")
        } footer: {
            Text("You sign in on the provider's own page; mailin never sees your password. Only reading mail is requested now; sending or changing mail asks again when you switch it on.")
        }
    }

    @ViewBuilder
    private var imapSection: some View {
        Section {
            TextField(String(localized: "Email address"), text: $form.address)
                .autocorrectionDisabled()
            TextField(String(localized: "Login name (if different)"), text: $form.loginName)
                .autocorrectionDisabled()
            SecureField(choice.passwordLabel, text: $form.password)
                .accessibilityIdentifier("mail.add.password")
        } footer: {
            if let note = choice.signInNote { Text(note) }
        }
        Section(String(localized: "Incoming server (IMAP)")) {
            TextField(String(localized: "Server"), text: $form.host).autocorrectionDisabled()
            TextField(String(localized: "Port"), text: $form.port)
        }
        Section {
            TextField(String(localized: "Server"), text: $form.smtpHost).autocorrectionDisabled()
            TextField(String(localized: "Port"), text: $form.smtpPort)
        } header: {
            Text("Outgoing server (SMTP), for sending")
        } footer: {
            Text("Presets fill in the provider's published settings; they have not yet been checked against the real servers.")
        }
    }

    private func add() async {
        working = true
        defer { working = false }
        let ok = choice.usesOAuth ? await model.signIn(choice, address: address) : await model.addIMAP(form)
        if ok { dismiss() }
    }
}

// MARK: - Accounts list (content column)

struct MailAccountsList: View {
    @Bindable var model: MailWorkspaceModel
    @Binding var sheet: MailSheet?

    var body: some View {
        List(selection: $model.selectedAccount) {
            ForEach(model.accounts) { snapshot in
                MailAccountBadge(account: snapshot.account, headline: snapshot.headline)
                    .tag(snapshot.id)
            }
            if model.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            if !model.removedAccounts.isEmpty {
                // Removed with their mail kept: deleting that mail stays possible here.
                Section(String(localized: "Removed accounts")) {
                    ForEach(model.removedAccounts) { snapshot in
                        HStack {
                            MailAccountBadge(account: snapshot.account,
                                             headline: MailLifecycleText.keptMessages(model.removedArchive[snapshot.id]?.records ?? 0))
                            Spacer()
                            Button(String(localized: "Delete archived mail…"), role: .destructive) {
                                sheet = .deleteRemovedMail(snapshot.id)
                            }
                            .disabled((model.removedArchive[snapshot.id]?.deletable ?? 0) == 0)
                            .accessibilityIdentifier("mail.removed.delete")
                        }
                        .selectionDisabled()
                    }
                }
            }
            Section {
                Button(String(localized: "Add account…")) { sheet = .addAccount }
                Button(String(localized: "Sign-in details from an earlier version…")) { sheet = .upgrade }
                    .accessibilityHint(Text("Lists old saved sign-in items and earlier incomplete online imports"))
            }
        }
        .navigationTitle(String(localized: "Accounts"))
    }
}

// MARK: - One account

struct MailAccountSettingsView: View {
    let model: MailWorkspaceModel
    let accountID: UUID
    @Binding var sheet: MailSheet?
    @State private var unconfirmedAddress: String?
    @State private var confirmingAddress = false

    var body: some View {
        if let snapshot = model.account(accountID) {
            Form {
                Section {
                    MailAccountBadge(account: snapshot.account)
                    HStack(spacing: Spacing.xSmall) {
                        if snapshot.isRunning {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(Text("Saving mail"))
                        }
                        Text(snapshot.headline)
                            .font(.headline)
                            .accessibilityIdentifier("mail.account.headline")
                    }
                    if let reason = snapshot.unavailableReason, snapshot.status == nil, reason != snapshot.headline {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                    if snapshot.account.connectionState == .needsReauthorisation, snapshot.account.provider != .imap {
                        Button(String(localized: "Sign in again")) {
                            Task {
                                await model.reconsent(accountID, scope: snapshot.account.provider == .gmail
                                                      ? GmailOAuth.readOnlyScope : "Mail.Read")
                            }
                        }
                    }
                    if snapshot.offersReplacePassword {
                        // A password account signs in again with a new password (checked first):
                        // after sign-in is needed, a refused password or an app password requirement.
                        Button(String(localized: "Replace password…")) { sheet = .replacePassword(accountID) }
                            .accessibilityIdentifier("mail.account.replacePassword")
                    }
                    // Limits of the last folder listing, stated (rule 6).
                    ForEach(snapshot.statedLimits, id: \.self) { limit in
                        Label(limit, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("mail.account.listingLimit")
                    }
                    if let address = unconfirmedAddress {
                        Text(MailLifecycleText.addressNotConfirmed(address)).font(.callout).foregroundStyle(.secondary)
                        Button(String(localized: "Confirm Sending Address…")) { confirmingAddress = true }
                            .accessibilityIdentifier("mail.account.confirmAddress")
                    }
                }

                Section {
                    ForEach(MailModeText.order, id: \.self) { mode in
                        let unavailable = MailModeText.unavailableReason(mode, account: snapshot.account)
                        Toggle(isOn: Binding(
                            get: { unavailable == nil && snapshot.account.enabledModes.contains(mode) },
                            set: { on in Task { await model.setMode(mode, enabled: on, account: accountID) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MailModeText.title(mode))
                                Text(unavailable ?? MailModeText.explanation(mode)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(snapshot.account.connectionState == .removed || unavailable != nil)
                        .accessibilityIdentifier("mail.mode.\(mode.rawValue)")
                    }
                } header: {
                    Text("What this account may do")
                }

                if snapshot.account.enabledModes.contains(.capture) {
                    Section {
                        HStack {
                            Button(String(localized: "Sync now")) { Task { await model.syncNow(accountID) } }
                                .disabled(snapshot.isPaused || model.busy || snapshot.isRunning)
                                .accessibilityIdentifier("mail.account.syncNow")
                            Button(snapshot.isPaused ? String(localized: "Resume capture") : String(localized: "Pause capture")) {
                                Task { await model.setPaused(!snapshot.isPaused, account: accountID) }
                            }
                        }
                        if let status = snapshot.status {
                            let times = MailStatusText.syncTimes(status)
                            LabeledContent(String(localized: "Last successful sync"), value: times.successful)
                            LabeledContent(String(localized: "Last attempted sync"), value: times.attempted)
                            ForEach(Array(MailStatusText.completenessLines(status).enumerated()), id: \.offset) { offset, line in
                                LabeledContent(line.title) {
                                    Text(line.value).multilineTextAlignment(.trailing)
                                        .accessibilityIdentifier("mail.status.line.\(offset)")
                                }
                            }
                        }
                        if let summary = snapshot.lastRunSummary {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Status")
                    }
                }

                Section {
                    let folders = model.folders[accountID] ?? []
                    if folders.isEmpty {
                        Text("Folders appear after the first sync.").foregroundStyle(.secondary)
                    }
                    ForEach(folders) { folder in
                        Toggle(isOn: Binding(get: { folder.selected },
                                             set: { on in Task { await model.setFolderSelected(folder, selected: on) } })) {
                            HStack {
                                Text(folder.path)
                                Spacer()
                                Text("\(folder.messages) saved, \(folder.unread) unread")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(Text("\(folder.path): \(folder.messages) saved, \(folder.unread) unread"))
                        .accessibilityIdentifier("mail.folder")
                    }
                } header: {
                    Text("Folders to preserve")
                } footer: {
                    Text("Every folder is preserved until you switch one off. Switching a folder off keeps what was already saved.")
                }

                Section {
                    if snapshot.account.enabledModes.contains(.serverActions) {
                        Button(String(localized: "Safe server cleanup…")) { sheet = .cleanup(accountID, only: nil) }
                            .accessibilityHint(Text("Preview which saved messages could be moved to the server's Trash, with reasons, before anything changes"))
                    }
                    Button(String(localized: "Remove account…"), role: .destructive) { sheet = .removeAccount(accountID) }
                        .accessibilityIdentifier("mail.account.remove")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(snapshot.account.displayIdentity)
            .task(id: accountID) { await loadIdentity(snapshot.account) }
            .confirmationDialog(String(localized: "Confirm Sending Address…"), isPresented: $confirmingAddress) {
                Button(String(localized: "Confirm")) {
                    Task {
                        await model.confirmSendingAddress(accountID)
                        await loadIdentity(snapshot.account)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(MailLifecycleText.addressNotConfirmed(unconfirmedAddress ?? snapshot.account.displayIdentity))
            }
        } else {
            Text("This account is no longer listed.").foregroundStyle(.secondary)
        }
    }

    /// An IMAP account's typed address the person has not confirmed yet.
    private func loadIdentity(_ account: MailAccount) async {
        guard account.provider == .imap else { unconfirmedAddress = nil; return }
        let own = await model.backend.identities(accountID)
        unconfirmedAddress = !own.isEmpty && !own.contains(where: { $0.permission == .verified }) ? own.first?.address.addrSpec : nil
    }
}

// MARK: - Remove

/// The Remove account sheet's decisions (no SwiftUI): the counts are shown
/// first, removal waits for the account's running capture, and deleting its
/// archived mail re-plans after the removal — a changed count is shown in
/// the sheet and must be typed again (rule 4). Nothing is deleted on Return.
@MainActor
@Observable
final class MailRemovalFlow {
    let model: MailWorkspaceModel
    let accountID: UUID
    private(set) var plan: AccountRemovalPlan?
    private(set) var report: AccountRemovalReport?
    private(set) var deletion: ConnectedAccountArchiveSummary?
    private(set) var deleted: ConnectedAccountArchiveDeletion?
    var typedCount = ""
    /// "Remove and Delete Mail…" was chosen: the count field is shown.
    private(set) var alsoDelete = false
    private(set) var working = false
    /// This sheet's own error, shown in the sheet (never only on the page behind it).
    private(set) var error: String?

    init(model: MailWorkspaceModel, accountID: UUID) {
        self.model = model
        self.accountID = accountID
    }

    /// The typed number equals what would be deleted now (and that is not zero).
    var typedMatches: Bool {
        guard let deletable = deletion?.deletable, deletable > 0 else { return false }
        return typedCount.trimmingCharacters(in: .whitespaces) == String(deletable)
    }

    var hasDeletableMail: Bool { (deletion?.deletable ?? 0) > 0 }

    func load() async {
        // An error from elsewhere on the page is not this sheet's.
        model.lastError = nil
        error = nil
        plan = await model.removalPlan(accountID)
        if plan == nil { error = model.lastError }
        deletion = try? await model.backend.archiveDeletionPlan(accountID)
    }

    /// A removed account's sheet: only the deletion count.
    func loadDeletionOnly() async {
        error = nil
        do { deletion = try await model.backend.archiveDeletionPlan(accountID) } catch {
            self.error = ConnectedMailErrorText.text(for: error)
        }
    }

    func chooseDelete() {
        alsoDelete = true
        typedCount = ""
        error = nil
    }

    func removeKeepingMail() async {
        working = true; defer { working = false }
        alsoDelete = false
        report = await model.remove(accountID)
        guard report != nil else { error = model.lastError; return }
        deletion = try? await model.backend.archiveDeletionPlan(accountID)
        typedCount = ""
    }

    func removeAndDelete() async {
        guard let shown = deletion?.deletable, typedMatches else { return }
        working = true; defer { working = false }
        report = await model.remove(accountID)
        guard report != nil else { error = model.lastError; return }
        await delete(shown: shown)
    }

    /// After removal: the delete section's own button (the count typed against the current plan).
    func deleteNow() async {
        guard let shown = deletion?.deletable, typedMatches else { return }
        working = true; defer { working = false }
        await delete(shown: shown)
    }

    /// Re-plans first: a count that changed since it was shown deletes
    /// nothing and asks for the new number.
    private func delete(shown: Int) async {
        let fresh = try? await model.backend.archiveDeletionPlan(accountID)
        deletion = fresh
        guard let fresh, fresh.deletable == shown else {
            typedCount = ""
            error = MailLifecycleText.countChangedAfterRemoval(shown: shown, now: fresh?.deletable ?? 0)
            return
        }
        deleted = await model.deleteArchivedMail(accountID, confirmedCount: shown)
        if deleted == nil {
            error = model.lastError
            deletion = try? await model.backend.archiveDeletionPlan(accountID)
            typedCount = ""
        } else {
            error = nil
        }
    }
}

struct MailRemoveAccountView: View {
    let model: MailWorkspaceModel
    let accountID: UUID
    let dismiss: () -> Void
    /// Owner 2026-11-14: "Remove" and "Remove and Delete Mail…" are both footer
    /// buttons next to Cancel (macOS); deleting first shows the exact count to type (rule 4).
    @State private var flow: MailRemovalFlow

    init(model: MailWorkspaceModel, accountID: UUID, dismiss: @escaping () -> Void) {
        self.model = model
        self.accountID = accountID
        self.dismiss = dismiss
        _flow = State(initialValue: MailRemovalFlow(model: model, accountID: accountID))
    }

    private var typedMatches: Bool { flow.typedMatches }

    var body: some View {
        NavigationStack {
            Form {
                if let error = flow.error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                            .accessibilityIdentifier("mail.remove.error")
                    }
                }
                if let report = flow.report {
                    Section {
                        Text(MailRemovalText.report(report))
                            .accessibilityIdentifier("mail.remove.report")
                    }
                    if let deleted = flow.deleted {
                        Section { Text(MailRemovalText.deletionReport(deleted)) }
                    } else if let deletion = flow.deletion, deletion.deletable > 0 {
                        // Removed with mail kept (or the count changed): deleting it stays possible here.
                        Section {
                            Text(MailRemovalText.deletionDetail(deletion)).font(.callout)
                            TextField(String(localized: "Type the number to confirm"), text: $flow.typedCount)
                                .accessibilityIdentifier("mail.remove.typedCount")
                            Button(MailRemovalText.deletionTitle(deletion), role: .destructive) { Task { await flow.deleteNow() } }
                                .disabled(!typedMatches || flow.working)
                                .accessibilityIdentifier("mail.remove.deleteAfter")
                        } header: {
                            Text("Also delete its archived mail? (separate, optional)")
                        }
                    }
                } else if let plan = flow.plan {
                    Section {
                        ForEach(MailRemovalText.summary(plan), id: \.self) { Text($0) }
                    } header: {
                        Text("Before removing")
                    } footer: {
                        // What Remove does, visible (not only as a tooltip).
                        Text(MailRemovalText.confirmTitle(plan))
                    }
                    if flow.alsoDelete, let deletion = flow.deletion {
                        Section {
                            Text(MailRemovalText.deletionDetail(deletion)).font(.callout)
                            if deletion.deletable > 0 {
                                TextField(String(localized: "Type the number to confirm"), text: $flow.typedCount)
                                    .accessibilityIdentifier("mail.remove.typedCount")
                            }
                        } header: {
                            Text("Delete its archived mail too")
                        }
                    }
                    #if os(iOS)
                    // iPhone / iPad: the actions sit in the form, under what they do.
                    Section {
                        removeButton(plan)
                        deleteChoiceButton
                    }
                    #endif
                } else if flow.error == nil {
                    ProgressView()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Remove account"))
            .toolbar { footer }
        }
        .task { await flow.load() }
    }

    @ToolbarContentBuilder
    private var footer: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(flow.report == nil ? String(localized: "Cancel") : String(localized: "Done"), action: dismiss)
                .accessibilityIdentifier("mail.remove.close")
        }
        #if os(macOS)
        if flow.report == nil, let plan = flow.plan {
            ToolbarItem(placement: .destructiveAction) { deleteChoiceButton }
            ToolbarItem(placement: .confirmationAction) { removeButton(plan) }
        }
        #endif
    }

    /// Remove (keeps the mail). Return triggers it only while no delete count
    /// is being typed: Return in the count field must never remove-and-keep.
    private func removeButton(_ plan: AccountRemovalPlan) -> some View {
        Button(String(localized: "Remove")) { Task { await flow.removeKeepingMail() } }
            .keyboardShortcut(flow.alsoDelete ? nil : KeyboardShortcut.defaultAction)
            .disabled(flow.working)
            .help(MailRemovalText.confirmTitle(plan))
            .accessibilityIdentifier("mail.remove.confirm")
    }

    @ViewBuilder
    private var deleteChoiceButton: some View {
        if flow.alsoDelete, let deletion = flow.deletion {
            Button(MailRemovalText.removeAndDeleteTitle(deletion), role: .destructive) { Task { await flow.removeAndDelete() } }
                .disabled(!typedMatches || flow.working)
                .accessibilityIdentifier("mail.remove.andDelete")
        } else {
            Button(flow.deletion.map { $0.deletable == 0 } == true ? MailLifecycleText.nothingToDelete : String(localized: "Remove and Delete Mail…"),
                   role: .destructive) { flow.chooseDelete() }
                .disabled(!flow.hasDeletableMail || flow.working)
                .accessibilityIdentifier("mail.remove.chooseDelete")
        }
    }
}

/// A removed account's archived mail, deleted later: the count is shown,
/// typed, and re-checked before anything is deleted.
struct MailDeleteRemovedMailView: View {
    let model: MailWorkspaceModel
    let accountID: UUID
    let dismiss: () -> Void
    @State private var flow: MailRemovalFlow

    init(model: MailWorkspaceModel, accountID: UUID, dismiss: @escaping () -> Void) {
        self.model = model
        self.accountID = accountID
        self.dismiss = dismiss
        _flow = State(initialValue: MailRemovalFlow(model: model, accountID: accountID))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = flow.error {
                    Section { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("mail.deleteRemoved.error") }
                }
                if let deleted = flow.deleted {
                    Section { Text(MailRemovalText.deletionReport(deleted)) }
                } else if let deletion = flow.deletion {
                    Section {
                        Text(MailRemovalText.deletionDetail(deletion)).font(.callout)
                        if deletion.deletable > 0 {
                            TextField(String(localized: "Type the number to confirm"), text: $flow.typedCount)
                                .accessibilityIdentifier("mail.deleteRemoved.typedCount")
                            Button(MailRemovalText.deletionTitle(deletion), role: .destructive) { Task { await flow.deleteNow() } }
                                .disabled(!flow.typedMatches || flow.working)
                                .accessibilityIdentifier("mail.deleteRemoved.confirm")
                        }
                    }
                } else if flow.error == nil {
                    ProgressView()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Delete archived mail"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.deleted == nil ? String(localized: "Cancel") : String(localized: "Done"), action: dismiss)
                }
            }
        }
        .task {
            model.lastError = nil
            await flow.loadDeletionOnly()
        }
    }
}

/// IMAP account that needs sign-in: a new password, checked with the
/// servers before it replaces the old one.
struct MailReplacePasswordView: View {
    let model: MailWorkspaceModel
    let accountID: UUID
    let dismiss: () -> Void
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let account = model.account(accountID)?.account {
                        Text(account.displayIdentity).font(.headline)
                    }
                    SecureField(String(localized: "Password or app password"), text: $password)
                        .accessibilityIdentifier("mail.password.field")
                } footer: {
                    if let host = model.account(accountID)?.account.host, ConnectedMailErrorText.isGmailHost(host) {
                        Text(MailProviderChoice.gmailAppPasswordGuidance)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("mail.password.error") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Replace password"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel"), action: dismiss) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task {
                            working = true; defer { working = false }
                            if await model.replacePassword(password, account: accountID) { dismiss() } else { error = model.lastError }
                        }
                    }
                    .disabled(password.isEmpty || working)
                    .accessibilityIdentifier("mail.password.save")
                }
            }
        }
        .onAppear { model.lastError = nil }
    }
}

// MARK: - Upgrade inventory

struct MailUpgradeInventoryView: View {
    let model: MailWorkspaceModel
    let dismiss: () -> Void
    @State private var legacy: [LegacyCredential] = []
    @State private var chosen: Set<String> = []
    @State private var target: UUID?
    @State private var captures: [LegacyOnlineCapture] = []
    @State private var comparisons: [UUID: LegacyRecaptureComparison] = [:]
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if legacy.isEmpty {
                        Text("No sign-in items from an earlier version were found.").foregroundStyle(.secondary)
                    }
                    ForEach(legacy) { item in
                        Toggle(isOn: Binding(get: { chosen.contains(item.key) },
                                             set: { if $0 { chosen.insert(item.key) } else { chosen.remove(item.key) } })) {
                            Text(verbatim: "\(item.key) (\(item.purpose.rawValue))")
                        }
                    }
                    if !legacy.isEmpty {
                        Picker(String(localized: "Belongs to"), selection: $target) {
                            Text("Choose an account").tag(UUID?.none)
                            ForEach(model.accounts) { Text($0.account.displayIdentity).tag(UUID?.some($0.id)) }
                        }
                        Button(String(localized: "Assign the chosen items to this account")) {
                            guard let target else { return }
                            let items = legacy.filter { chosen.contains($0.key) }
                            Task {
                                await model.run { try await model.backend.assignLegacy(items, to: target) }
                                await model.refresh()
                                legacy = model.backend.legacyCredentials()
                                chosen = []
                            }
                        }
                        .disabled(target == nil || chosen.isEmpty)
                    }
                } header: {
                    Text("Old saved sign-in items")
                } footer: {
                    Text("Earlier versions kept one sign-in for the whole app. mailin never guesses which account an old item belongs to: choose the items and the account yourself.")
                }

                Section {
                    if captures.isEmpty {
                        Text(loaded ? String(localized: "No earlier incomplete online imports.") : String(localized: "Checking…"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(captures.count) messages from earlier online imports have no original source.")
                            .font(.callout)
                    }
                    ForEach(captures, id: \.emailID) { capture in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.subject.isEmpty ? String(localized: "(no subject)") : capture.subject).lineLimit(1)
                            Text(capture.date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                            if let c = comparisons[capture.emailID] {
                                Text(Self.verdict(c.verdict)).font(.caption)
                            } else if let account = model.accounts.first {
                                Button(String(localized: "Compare with recaptured copy")) {
                                    Task {
                                        if let c = try? await model.backend.compareRecapture(capture, account: account.id) {
                                            comparisons[capture.emailID] = c
                                        }
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Earlier online imports")
                } footer: {
                    Text("Nothing is replaced or deleted. Preserve the account's mail again, then compare: both copies stay.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "From an earlier version"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done"), action: dismiss) }
            }
        }
        .task {
            legacy = model.backend.legacyCredentials()
            captures = (try? await model.backend.legacyRecaptures()) ?? []
            loaded = true
        }
    }

    static func verdict(_ v: LegacyRecaptureComparison.Verdict) -> String {
        switch v {
        case .noMessageID: return String(localized: "It has no Message-ID, so it cannot be matched automatically.")
        case .notRecapturedYet: return String(localized: "Not preserved again yet.")
        case .recaptured(_, let differences):
            return differences.isEmpty
                ? String(localized: "Preserved again: the same content, now with its original source.")
                : String(localized: "Preserved again; these differ: \(differences.map(\.rawValue).joined(separator: ", "))")
        case .ambiguous(let ids): return String(localized: "\(ids.count) preserved copies match; open them to choose.")
        }
    }
}
