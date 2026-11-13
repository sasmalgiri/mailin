@testable import ArchiveCore
import MailConnectivity
//
//  MailComposeViews.swift
//  maxmailin
//
//  Plan v4 V4-13 (§6 drafts, identities): the drafts list, the draft editor
//  (wired to DraftStore, MailAddressParser and the outbox) and the reply /
//  forward setup from an archived message (ReplyBuilder).
//
//  The sending identity is a required choice from the draft's OWN account —
//  never an address taken from the archived message or an archive's former
//  owner. Protected (encrypted) originals are left out unless the person
//  chooses to include them, and a reply to an encrypted message says it will
//  not be encrypted. Attachments whose file is gone or changed are listed
//  as unavailable, never silently dropped.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drafts list

struct MailDraftsList: View {
    let model: MailWorkspaceModel
    @Binding var sheet: MailSheet?

    var body: some View {
        List {
            if model.drafts.isEmpty {
                Text("No drafts.").foregroundStyle(.secondary)
            }
            if model.unreadableDrafts > 0 {
                Label(String(localized: "\(model.unreadableDrafts) drafts could not be read"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(model.drafts) { draft in
                Button { sheet = .compose(draft.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.subject.isEmpty ? String(localized: "(no subject)") : draft.subject).lineLimit(1)
                        Text(draft.to.map(\.addrSpec).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            if let account = model.account(draft.accountID)?.account {
                                MailAccountBadge(account: account).font(.caption2)
                            }
                            Spacer()
                            Text(draft.updatedAt, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(String(localized: "Delete draft"), role: .destructive) {
                        Task { await model.run { try await model.backend.discardDraft(draft.id) }; await model.reloadDrafts() }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Drafts"))
    }
}

// MARK: - Editor

struct MailComposeSheet: View {
    let model: MailWorkspaceModel
    let draftID: UUID
    let dismiss: () -> Void

    @State private var draft: Draft?
    @State private var identities: [SendingIdentity] = []
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var addressError: String?
    @State private var unavailable: [UUID: String] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var importing = false
    @State private var error: String?
    @AppStorage("mailin.mail.undoSendSeconds") private var undoSeconds = 10

    private var sendAccounts: [MailAccountSnapshot] { model.accounts.filter { $0.account.enabledModes.contains(.send) } }

    var body: some View {
        NavigationStack {
            Group {
                if let draft { editor(draft) } else { ProgressView() }
            }
            .navigationTitle(String(localized: "Message"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { Task { await saveNow(); dismiss() } }
                        .help(String(localized: "Keeps the draft"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Send")) { Task { await send() } }
                        .disabled(!problems.isEmpty)
                        .help(problems.first.map(MailComposeGate.text) ?? String(localized: "Puts the message in the outbox"))
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .accessibilityIdentifier("mail.compose.send")
                }
            }
        }
        .task { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await attach(urls) }
        }
    }

    private var problems: [MailComposeGate.Problem] {
        guard let draft else { return [.noIdentity] }
        var p = MailComposeGate.problems(draft: draft, account: model.account(draft.accountID)?.account,
                                         identities: identities, unavailableAttachments: Array(unavailable.values))
        if addressError != nil { p.append(.noRecipients) }
        return p
    }

    @ViewBuilder
    private func editor(_ current: Draft) -> some View {
        Form {
            Section {
                Picker(String(localized: "Account"), selection: Binding(
                    get: { current.accountID },
                    set: { id in update { $0.switchAccount(to: id) }; Task { identities = await model.backend.identities(id) } })) {
                    ForEach(sendAccounts) { Text($0.account.displayIdentity).tag($0.id) }
                    if !sendAccounts.contains(where: { $0.id == current.accountID }) {
                        Text(model.account(current.accountID)?.account.displayIdentity ?? String(localized: "Unknown account")).tag(current.accountID)
                    }
                }
                Picker(String(localized: "From"), selection: Binding(
                    get: { current.senderIdentityID },
                    set: { id in update { $0.senderIdentityID = id } })) {
                    Text("Choose a sending address").tag(UUID?.none)
                    ForEach(MailComposeGate.offeredIdentities(for: current.accountID, from: identities)) { identity in
                        Text(identity.address.description).tag(UUID?.some(identity.id))
                    }
                }
                .accessibilityIdentifier("mail.compose.identity")
                .accessibilityHint(Text("Required. Only this account's own addresses are offered."))
            } footer: {
                Text("Replying to an old archive never sends as its former owner: choose one of your connected addresses.")
            }

            Section {
                TextField(String(localized: "To"), text: $to).autocorrectionDisabled()
                TextField(String(localized: "Cc"), text: $cc).autocorrectionDisabled()
                TextField(String(localized: "Bcc"), text: $bcc).autocorrectionDisabled()
                if let addressError { Text(addressError).font(.caption).foregroundStyle(.red) }
                TextField(String(localized: "Subject"), text: Binding(get: { current.subject }, set: { s in update { $0.subject = s } }))
            }
            .onChange(of: to) { _, _ in parseRecipients() }
            .onChange(of: cc) { _, _ in parseRecipients() }
            .onChange(of: bcc) { _, _ in parseRecipients() }

            if current.protectedContent != .none || current.securityNotice != .none {
                Section {
                    if current.protectedContent == .omitted {
                        Label(String(localized: "The original was encrypted. Its decrypted text and attachments were left out of this message."), systemImage: "lock")
                    }
                    if current.protectedContent == .includedByUserChoice {
                        Label(String(localized: "You chose to include the original's decrypted content. It will be sent as written here."), systemImage: "lock.open")
                    }
                    if current.securityNotice == .originalEncryptedReplyNotEncrypted {
                        Label(String(localized: "This reply will be sent without encryption."), systemImage: "exclamationmark.shield")
                    }
                }
                .font(.callout)
            }

            Section {
                TextEditor(text: Binding(get: { current.plainBody }, set: { s in update { $0.plainBody = s } }))
                    .frame(minHeight: 160)
                    .accessibilityLabel(Text("Message text"))
                if let quoted = current.quotedPlain, !quoted.isEmpty {
                    DisclosureGroup(String(localized: "Quoted original")) {
                        Text(quoted).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

            Section {
                ForEach(current.attachments) { attachment in
                    HStack {
                        Image(systemName: unavailable[attachment.id] == nil ? "paperclip" : "exclamationmark.triangle")
                            .foregroundStyle(unavailable[attachment.id] == nil ? Color.secondary : Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(attachment.filename).lineLimit(1)
                            if let why = unavailable[attachment.id] {
                                Text(why).font(.caption).foregroundStyle(.orange)
                            } else {
                                Text(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            update { $0.attachments.removeAll { $0.id == attachment.id } }
                            unavailable[attachment.id] = nil
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove \(attachment.filename)"))
                    }
                    .accessibilityElement(children: .contain)
                }
                Button(String(localized: "Attach files…")) { importing = true }
            } header: {
                Text("Attachments")
            }

            Section {
                Stepper(value: $undoSeconds, in: 0...60, step: 5) {
                    Text(undoSeconds == 0 ? String(localized: "Undo Send: off") : String(localized: "Undo Send: \(undoSeconds) seconds"))
                }
                ForEach(problems.indices, id: \.self) { i in
                    Text(MailComposeGate.text(problems[i])).font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button(String(localized: "Delete draft"), role: .destructive) {
                    Task {
                        await model.run { try await model.backend.discardDraft(current.id) }
                        await model.reloadDrafts()
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Actions

    private func load() async {
        let listing = await model.backend.drafts()
        guard let found = listing.drafts.first(where: { $0.id == draftID }) else {
            error = String(localized: "The draft no longer exists.")
            return
        }
        draft = found
        identities = await model.backend.identities(found.accountID)
        to = found.to.map(\.description).joined(separator: ", ")
        cc = found.cc.map(\.description).joined(separator: ", ")
        bcc = found.bcc.map(\.description).joined(separator: ", ")
        await checkAttachments()
    }

    private func checkAttachments() async {
        guard let draft else { return }
        var out: [UUID: String] = [:]
        for a in draft.attachments {
            if case .unavailable(let why) = await model.backend.attachmentAvailability(a, draft: draft.id) {
                switch why {
                case .missing: out[a.id] = String(localized: "The file is no longer where it was.")
                case .changedSinceAttached: out[a.id] = String(localized: "The file has changed since it was attached.")
                case .unreadable: out[a.id] = String(localized: "The file cannot be read.")
                }
            }
        }
        unavailable = out
    }

    private func parseRecipients() {
        do {
            let parsedTo = try Self.parse(to), parsedCc = try Self.parse(cc), parsedBcc = try Self.parse(bcc)
            addressError = nil
            update { $0.to = parsedTo; $0.cc = parsedCc; $0.bcc = parsedBcc }
        } catch {
            addressError = String(localized: "An address could not be read: \(error.localizedDescription)")
        }
    }

    static func parse(_ text: String) throws -> [MailAddress] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : try MailAddressParser.parseList(text)
    }

    /// Edits the draft and schedules an autosave (one second after the last edit).
    private func update(_ change: (inout Draft) -> Void) {
        guard var d = draft else { return }
        change(&d)
        draft = d
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    private func saveNow() async {
        guard let d = draft else { return }
        do {
            draft = try await model.backend.saveDraft(d)
            error = nil
        } catch {
            self.error = ConnectedMailErrorText.text(for: error)
        }
        await model.reloadDrafts()
    }

    private func attach(_ urls: [URL]) async {
        await saveNow()
        for url in urls {
            guard let d = draft else { return }
            do { draft = try await model.backend.addAttachment(url, to: d) } catch { self.error = ConnectedMailErrorText.text(for: error) }
        }
        await checkAttachments()
    }

    private func send() async {
        saveTask?.cancel()
        await saveNow()
        guard let d = draft, problems.isEmpty else { return }
        do {
            _ = try await model.backend.queue(d, undoDelay: TimeInterval(undoSeconds))
            model.message = undoSeconds > 0
                ? String(localized: "In the outbox. You can undo for \(undoSeconds) seconds.")
                : String(localized: "In the outbox.")
            await model.reloadOutbox()
            model.section = .outbox
            dismiss()
        } catch {
            self.error = ConnectedMailErrorText.text(for: error)
        }
    }
}

// MARK: - Reply / forward setup

struct MailReplySetupView: View {
    let model: MailWorkspaceModel
    let emailID: UUID
    let kind: Draft.Kind
    let dismiss: () -> Void
    @State private var accountID: UUID?
    @State private var source: ArchivedMessageSource?
    @State private var includeProtected = false
    @State private var error: String?
    @State private var openDraft: UUID?

    private var sendAccounts: [MailAccountSnapshot] { model.accounts.filter { $0.account.enabledModes.contains(.send) } }

    var body: some View {
        if let openDraft {
            MailComposeSheet(model: model, draftID: openDraft, dismiss: dismiss)
        } else {
            NavigationStack {
                Form {
                    Section {
                        Picker(String(localized: "Reply from account"), selection: $accountID) {
                            Text("Choose an account").tag(UUID?.none)
                            ForEach(sendAccounts) { Text($0.account.displayIdentity).tag(UUID?.some($0.id)) }
                        }
                    } footer: {
                        Text("Only accounts allowed to send are listed. The sending address is chosen in the message.")
                    }
                    if let source, source.protection != .none {
                        Section {
                            Toggle(String(localized: "Include the decrypted content"), isOn: $includeProtected)
                                .disabled(source.protection != .decrypted)
                        } footer: {
                            Text("The original was encrypted. By default its decrypted text and attachments are left out, and the message is sent without encryption.")
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .formStyle(.grouped)
                .navigationTitle(Self.title(kind))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel"), action: dismiss) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Continue")) { Task { await build() } }
                            .disabled(accountID == nil || source == nil)
                    }
                }
            }
            .task {
                if sendAccounts.count == 1 { accountID = sendAccounts[0].id }
                do { source = try await model.backend.archivedSource(emailID) } catch { self.error = ConnectedMailErrorText.text(for: error) }
            }
        }
    }

    static func title(_ kind: Draft.Kind) -> String {
        switch kind {
        case .reply: return String(localized: "Reply")
        case .replyAll: return String(localized: "Reply All")
        case .forward: return String(localized: "Forward")
        case .forwardAsAttachment: return String(localized: "Forward as Attachment")
        case .new: return String(localized: "Message")
        }
    }

    private func build() async {
        guard let accountID, let source else { return }
        let identities = await model.backend.identities(accountID)
        do {
            let seed: DraftSeed
            switch kind {
            case .reply, .new:
                seed = try ReplyBuilder.reply(to: source, mode: .reply, accountID: accountID, identities: identities,
                                              includeProtectedContent: includeProtected)
            case .replyAll:
                seed = try ReplyBuilder.reply(to: source, mode: .replyAll, accountID: accountID, identities: identities,
                                              includeProtectedContent: includeProtected)
            case .forward:
                seed = try ReplyBuilder.forward(source, accountID: accountID, identities: identities, includeProtectedContent: includeProtected)
            case .forwardAsAttachment:
                seed = ReplyBuilder.forwardAsAttachment(source, accountID: accountID, identities: identities)
            }
            let draft = try await model.backend.createDraft(seed)
            await model.reloadDrafts()
            openDraft = draft.id
        } catch {
            self.error = ConnectedMailErrorText.text(for: error)
        }
    }
}
