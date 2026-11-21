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
    @State private var confirmEmptyCleanup = false

    /// DRAFT-01: drafts left empty before Close discarded them.
    private var emptyDrafts: [Draft] { model.drafts.filter(\.isUntouched) }

    var body: some View {
        List {
            if model.drafts.isEmpty {
                Text("No drafts.").foregroundStyle(.secondary)
            }
            if !emptyDrafts.isEmpty {
                Button(role: .destructive) { confirmEmptyCleanup = true } label: {
                    Label(String(localized: "Delete \(emptyDrafts.count) empty drafts"), systemImage: "trash")
                }
                .accessibilityIdentifier("mail.drafts.deleteEmpty")
            }
            if model.unreadableDrafts > 0 {
                Label(String(localized: "\(model.unreadableDrafts) drafts could not be read"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(model.drafts) { draft in
                Button { sheet = .compose(draft.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.subject.isEmpty ? String(localized: "(no subject)") : draft.subject)
                            .fontWeight(.medium).lineLimit(1)
                        // Never an empty line: the date then looked like the next draft's.
                        Text(draft.to.isEmpty ? String(localized: "No recipients yet")
                             : String(localized: "To: \(draft.to.map(\.addrSpec).joined(separator: ", "))"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        // Rule 4: the count before the action; only drafts with nothing in them.
        .confirmationDialog(String(localized: "Delete \(emptyDrafts.count) empty drafts?"), isPresented: $confirmEmptyCleanup,
                            titleVisibility: .visible) {
            Button(String(localized: "Delete \(emptyDrafts.count) empty drafts"), role: .destructive) {
                let ids = emptyDrafts.map(\.id)
                Task {
                    for id in ids { await model.run { try await model.backend.discardDraft(id) } }
                    await model.reloadDrafts()
                }
            }
        } message: {
            Text("They have no recipients, subject, text or attachments. Drafts with anything in them are kept.")
        }
    }
}

// MARK: - Editor

struct MailComposeSheet: View {
    let model: MailWorkspaceModel
    let draftID: UUID
    let dismiss: () -> Void

    @State private var draft: Draft?
    /// Confirmed and unconfirmed identities of every account that may send
    /// (the gate and the From menu filter them to the draft's own account).
    @State private var identities: [SendingIdentity] = []
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showCcBcc = false
    @State private var addressError: String?
    @State private var unavailable: [UUID: String] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var importing = false
    @State private var error: String?
    @AppStorage("mailin.mail.undoSendSeconds") private var undoSeconds = 10
    @FocusState private var focus: Field?
    @State private var savedAt: Date?
    @State private var pickingArchive = false
    @State private var editingSignature = false
    @State private var signatureText = ""

    private enum Field: Hashable { case to, cc, bcc, subject, body }

    private var sendAccounts: [MailAccountSnapshot] { model.accounts.filter { $0.account.enabledModes.contains(.send) } }

    var body: some View {
        NavigationStack {
            Group {
                if let draft { editor(draft) }
                else if let error { ContentUnavailableView(error, systemImage: "exclamationmark.triangle") }
                else { ProgressView() }
            }
            .navigationTitle(Self.title(draft?.kind ?? .new))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { Task { await closeDraft() } }
                        .help(String(localized: "Keeps the draft"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await send() } } label: {
                        Label(String(localized: "Send"), systemImage: "paperplane.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(!problems.isEmpty)
                    .help(problems.first.map(MailComposeGate.text) ?? String(localized: "Puts the message in the outbox"))
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .accessibilityIdentifier("mail.compose.send")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $pickingArchive) {
            ArchiveEmailPickerView(onDone: { chosen in
                Task { await attachArchived(chosen.map(\.id)) }
            }, title: String(localized: "Attach from Archive"),
               hint: String(localized: "Search, tick the messages you want, then Add them. Each is attached as an .eml file."))
        }
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

    /// "New Message" for a fresh draft; Reply / Forward titles otherwise.
    static func title(_ kind: Draft.Kind) -> String {
        kind == .new ? String(localized: "New Message") : MailReplySetupView.title(kind)
    }

    /// Every confirmed address the person may send from, across accounts
    /// that may send, plus the draft's own account (so its state stays visible).
    private func fromChoices(_ current: Draft) -> [SendingIdentity] {
        var ids = Set(sendAccounts.map(\.id))
        ids.insert(current.accountID)
        return identities.filter { ids.contains($0.accountID) && $0.permission == .verified }
    }

    /// One header line in the Mail style: a right-aligned label, then the field.
    private func headerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .accessibilityHidden(true)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func addressField(_ label: String, text: Binding<String>, field: Field) -> some View {
        headerRow(label) {
            TextField(label, text: text, prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .focused($focus, equals: field)
                .labelsHidden()
                .accessibilityLabel(Text(label))
        }
    }

    @ViewBuilder
    private func editor(_ current: Draft) -> some View {
        composerScroll {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                addressField(String(localized: "To"), text: $to, field: .to)
                if !showCcBcc {
                    Button(String(localized: "Cc/Bcc")) { showCcBcc = true; focus = .cc }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 16)
                        .help(String(localized: "Show Cc and Bcc"))
                }
            }
            Divider()
            if showCcBcc {
                addressField(String(localized: "Cc"), text: $cc, field: .cc)
                Divider()
                addressField(String(localized: "Bcc"), text: $bcc, field: .bcc)
                Divider()
            }
            if let addressError {
                Label(addressError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                Divider()
            }
            headerRow(String(localized: "Subject")) {
                TextField(String(localized: "Subject"), text: Binding(get: { current.subject }, set: { s in update { $0.subject = s } }),
                          prompt: Text(verbatim: ""))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .subject)
                    .labelsHidden()
                    .accessibilityLabel(Text("Subject"))
            }
            Divider()
            headerRow(String(localized: "From")) {
                Picker(String(localized: "From"), selection: Binding(
                    get: { current.senderIdentityID },
                    set: { id in chooseSender(id) })) {
                    Text("Choose a sending address").tag(UUID?.none)
                    ForEach(fromChoices(current)) { identity in
                        Text(fromLabel(identity)).tag(UUID?.some(identity.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text("From"))
                .accessibilityIdentifier("mail.compose.identity")
                .accessibilityHint(Text("Required. Only this account's own addresses are offered."))
                .help(Text("Required. Only this account's own addresses are offered."))
                Spacer(minLength: 0)
            }
            if current.kind != .new {
                Text("Replying to an old archive never sends as its former owner: choose one of your connected addresses.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            Divider()

            if current.protectedContent != .none || current.securityNotice != .none {
                VStack(alignment: .leading, spacing: 4) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.orange.opacity(0.08))
                Divider()
            }

            actionBar(current)
            Divider()
            if #available(macOS 26.0, iOS 26.0, *) {
                MailRichBodyEditor(initialPlain: current.plainBody, initialHTML: current.htmlBody) { plain, html in
                    update { $0.plainBody = plain; $0.htmlBody = html }
                }
                .id(current.id)
            } else {
                TextEditor(text: Binding(get: { current.plainBody }, set: { s in update { $0.plainBody = s } }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: Self.minimumBodyHeight)
                    .accessibilityLabel(Text("Message text"))
            }
            if let signature = current.signature {
                Text("-- \n" + signature.plain)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityLabel(Text("Signature"))
            }

            if let quoted = current.quotedPlain, !quoted.isEmpty {
                Divider()
                DisclosureGroup(String(localized: "Quoted original")) {
                    ScrollView {
                        Text(quoted).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }

            if !current.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(current.attachments) { attachmentChip($0) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }

            Divider()
            statusBar
        }
        }
        .onChange(of: to) { _, _ in parseRecipients() }
        .onChange(of: cc) { _, _ in parseRecipients() }
        .onChange(of: bcc) { _, _ in parseRecipients() }
        // Files dropped anywhere on the message are attached (Apple Mail).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await attach(files) }
            return true
        }
        .alert(String(localized: "Signature"), isPresented: $editingSignature) {
            TextField(String(localized: "Signature"), text: $signatureText, axis: .vertical)
            Button(String(localized: "Save")) {
                MailSignatureStore.set(signatureText, for: current.accountID)
                let text = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
                update { $0.signature = text.isEmpty ? nil : DraftSignature(plain: text) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Added below your message for this account. Kept on this device.")
        }
    }

    /// Apple Mail's and Thunderbird's message actions, inside the window
    /// (a Mac sheet shows no top toolbar, so they were not visible there).
    private func actionBar(_ current: Draft) -> some View {
        HStack(spacing: Spacing.small) {
            Button { importing = true } label: { Label(String(localized: "Attach files…"), systemImage: "paperclip") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help(String(localized: "Attach files… You can also drop files on the message."))
            Button { pickingArchive = true } label: {
                Label(String(localized: "Attach from Archive…"), systemImage: "archivebox")
            }
            .help(String(localized: "Attaches messages from your archive (imported or saved mail) as .eml files"))
            Menu {
                Button(String(localized: "No Signature")) { update { $0.signature = nil } }
                if let saved = MailSignatureStore.signature(for: current.accountID) {
                    Button(String(localized: "Use Signature")) { update { $0.signature = DraftSignature(plain: saved) } }
                }
                Divider()
                Button(String(localized: "Edit Signature…")) {
                    signatureText = MailSignatureStore.signature(for: current.accountID) ?? ""
                    editingSignature = true
                }
            } label: {
                Label(String(localized: "Signature"), systemImage: "signature")
            }
            .fixedSize()
            Spacer(minLength: 0)
            if let savedAt {
                Text("Saved \(savedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await saveNow(); savedAt = Date() } } label: {
                Label(String(localized: "Save Draft"), systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            Button(role: .destructive) {
                Task {
                    await model.run { try await model.backend.discardDraft(current.id) }
                    await model.reloadDrafts()
                    dismiss()
                }
            } label: {
                Label(String(localized: "Delete draft"), systemImage: "trash")
            }
        }
        .labelStyle(MailCompactLabelStyle())
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// iPhone and iPad: the whole message scrolls, so the keyboard never squeezes the text
    /// to nothing (owner QA 2026-11-15: 34 pt, then gone after Cc/Bcc). Mac: the text fills the window.
    @ViewBuilder
    private func composerScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(iOS)
        ScrollView { content() }
            .scrollDismissesKeyboard(.interactively)
        #else
        content()
        #endif
    }

    /// The writing area never shrinks below this (iPhone landscape with the keyboard up included).
    static let minimumBodyHeight: CGFloat = {
        #if os(iOS)
        return 260
        #else
        return 0
        #endif
    }()

    private func attachmentChip(_ attachment: DraftAttachment) -> some View {
        let why = unavailable[attachment.id]
        return HStack(spacing: 6) {
            Image(systemName: why == nil ? "doc" : "exclamationmark.triangle")
                .foregroundStyle(why == nil ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename).lineLimit(1)
                Text(why ?? ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(why == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Button {
                update { $0.attachments.removeAll { $0.id == attachment.id } }
                unavailable[attachment.id] = nil
            } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Remove \(attachment.filename)"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(why == nil ? Color.clear : Color.orange.opacity(0.6)))
        .accessibilityElement(children: .contain)
    }

    /// Why Send is not available yet (or the last error), and the Undo Send delay.
    private var statusBar: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).lineLimit(2)
            } else if let first = problems.first(where: { $0 != .noRecipients || !to.isEmpty || !cc.isEmpty || !bcc.isEmpty }) {
                Label(MailComposeGate.text(first), systemImage: "info.circle")
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Picker(selection: $undoSeconds) {
                Text("Undo Send: off").tag(0)
                ForEach([5, 10, 20, 30, 60], id: \.self) { s in
                    Text("Undo Send: \(s) seconds").tag(s)
                }
            } label: {
                Text(undoSeconds == 0 ? String(localized: "Undo Send: off") : String(localized: "Undo Send: \(undoSeconds) seconds"))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func fromLabel(_ identity: SendingIdentity) -> String {
        // The account is named only when addresses of several accounts are offered.
        let accounts = Set(identities.filter { $0.permission == .verified }.map(\.accountID))
        guard accounts.count > 1, let account = model.account(identity.accountID)?.account,
              account.displayIdentity.caseInsensitiveCompare(identity.address.addrSpec) != .orderedSame else {
            return identity.address.description
        }
        return "\(identity.address.description) — \(account.displayIdentity)"
    }

    /// Choosing an address of another account moves the draft to that account.
    private func chooseSender(_ id: UUID?) {
        guard let id, let identity = identities.first(where: { $0.id == id }) else {
            update { $0.senderIdentityID = nil }
            return
        }
        update {
            if $0.accountID != identity.accountID { $0.switchAccount(to: identity.accountID) }
            $0.senderIdentityID = identity.id
        }
    }

    // MARK: Actions

    private func load() async {
        let listing = await model.backend.drafts()
        guard let found = listing.drafts.first(where: { $0.id == draftID }) else {
            error = String(localized: "The draft no longer exists.")
            return
        }
        var all: [SendingIdentity] = []
        var accountIDs = sendAccounts.map(\.id)
        if !accountIDs.contains(found.accountID) { accountIDs.append(found.accountID) }
        for id in accountIDs { all += await model.backend.identities(id) }
        identities = all
        to = found.to.map(\.description).joined(separator: ", ")
        cc = found.cc.map(\.description).joined(separator: ", ")
        bcc = found.bcc.map(\.description).joined(separator: ", ")
        showCcBcc = !cc.isEmpty || !bcc.isEmpty
        draft = found
        if found.signature == nil, found.plainBody.isEmpty, found.kind == .new,
           let saved = MailSignatureStore.signature(for: found.accountID) {
            update { $0.signature = DraftSignature(plain: saved) }
        }
        // The account's only confirmed address is filled in; several mean a choice.
        if found.senderIdentityID == nil,
           let only = MailComposeGate.defaultIdentity(for: found.accountID, from: all) {
            update { $0.senderIdentityID = only }
        }
        focus = to.isEmpty ? .to : .body
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

    /// DRAFT-01: an untouched new message is discarded on Close, not kept as an
    /// empty "(no subject)" draft; anything with content is saved as before.
    private func closeDraft() async {
        saveTask?.cancel()
        if let d = draft, d.isUntouched {
            try? await model.backend.discardDraft(d.id)
            await model.reloadDrafts()
        } else {
            await saveNow()
        }
        dismiss()
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

    /// Archived messages attached as .eml files ("X of Y" when some could not be read).
    private func attachArchived(_ ids: [UUID]) async {
        await saveNow()
        var added = 0
        for id in ids {
            guard let d = draft else { return }
            do { draft = try await model.backend.attachArchived([id], to: d); added += 1 }
            catch { self.error = ConnectedMailErrorText.text(for: error) }
        }
        if added < ids.count {
            self.error = String(localized: "Attached \(added) of \(ids.count) messages. ") + (self.error ?? "")
        }
        await model.reloadDrafts()
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
                        Picker(kind == .reply || kind == .replyAll ? String(localized: "Reply from account") : String(localized: "Send from account"), selection: $accountID) {
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

/// Each account's signature, kept on this device (not a secret, not on the server).
enum MailSignatureStore {
    private static let key = "mailin.mail.signatures"

    static func signature(for account: UUID) -> String? {
        let text = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[account.uuidString]
        return text?.isEmpty == false ? text : nil
    }

    static func set(_ text: String, for account: UUID) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        all[account.uuidString] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Title and icon where there is room; the icon alone in a compact width (iPhone), where the
/// composer's action bar wrapped its labels a letter at a time (owner QA 2026-11-15).
struct MailCompactLabelStyle: LabelStyle {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        if sizeClass == .compact {
            // The built-in icon-only style keeps the title for VoiceOver; 44-point tap target.
            IconOnlyLabelStyle().makeBody(configuration: configuration)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        } else {
            TitleAndIconLabelStyle().makeBody(configuration: configuration)
        }
        #else
        TitleAndIconLabelStyle().makeBody(configuration: configuration)
        #endif
    }
}
