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
                }

                Section {
                    ForEach(MailModeText.order, id: \.self) { mode in
                        Toggle(isOn: Binding(
                            get: { snapshot.account.enabledModes.contains(mode) },
                            set: { on in Task { await model.setMode(mode, enabled: on, account: accountID) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MailModeText.title(mode))
                                Text(MailModeText.explanation(mode)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(snapshot.account.connectionState == .removed)
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
        } else {
            Text("This account is no longer listed.").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Remove

struct MailRemoveAccountView: View {
    let model: MailWorkspaceModel
    let accountID: UUID
    let dismiss: () -> Void
    @State private var plan: AccountRemovalPlan?
    @State private var report: AccountRemovalReport?
    @State private var deletion: ConnectedAccountArchiveSummary?
    @State private var typedCount = ""
    @State private var deleted: ConnectedAccountArchiveDeletion?

    var body: some View {
        NavigationStack {
            Form {
                if let report {
                    Section {
                        Text(MailRemovalText.report(report))
                            .accessibilityIdentifier("mail.remove.report")
                    }
                    if let deletion, deletion.deletable > 0, deleted == nil {
                        Section {
                            Text(MailRemovalText.deletionDetail(deletion)).font(.callout)
                            TextField(String(localized: "Type the number to confirm"), text: $typedCount)
                            Button(MailRemovalText.deletionTitle(deletion), role: .destructive) {
                                Task {
                                    deleted = await model.deleteArchivedMail(accountID, confirmedCount: deletion.deletable)
                                }
                            }
                            .disabled(typedCount.trimmingCharacters(in: .whitespaces) != String(deletion.deletable))
                        } header: {
                            Text("Also delete its archived mail? (separate, optional)")
                        }
                    }
                    if let deleted {
                        Section { Text("\(deleted.deletedEmailIDs.count) archived messages deleted; \(deleted.heldKept) on hold kept.") }
                    }
                } else if let plan {
                    Section {
                        ForEach(MailRemovalText.summary(plan), id: \.self) { Text($0) }
                    } header: {
                        Text("Before removing")
                    }
                    Section {
                        Button(MailRemovalText.confirmTitle(plan), role: .destructive) {
                            Task {
                                report = await model.remove(accountID)
                                if report != nil { deletion = try? await model.backend.archiveDeletionPlan(accountID) }
                            }
                        }
                        .accessibilityIdentifier("mail.remove.confirm")
                    }
                } else if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Remove account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(report == nil ? String(localized: "Cancel") : String(localized: "Done"), action: dismiss)
                        .accessibilityIdentifier("mail.remove.close")
                }
            }
        }
        .task { plan = await model.removalPlan(accountID) }
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
