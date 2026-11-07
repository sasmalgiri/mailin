@testable import ArchiveCore
//
//  AttachmentUnlockView.swift
//  maxmailin
//
//  Plan v4 §13.3 (10)(12), §13.8 step 5: a locked attachment (a
//  password-protected PDF, Office file or ZIP) shows its state and an
//  "Unlock…" action. The person types the password ONCE and chooses whether
//  the text inside is shown here only or stored in the archive's search
//  index like any other attachment. The password is never kept; a wrong one
//  is said plainly.
//

import SwiftUI

/// The lock row under an attachment whose recorded state is `locked`.
struct AttachmentUnlockView: View {
    let emailID: UUID
    let position: Int
    let filename: String
    @State private var row: AttachmentCoverageRow?
    /// Files inside this attachment that are locked (a ZIP with one sealed member among plain ones).
    @State private var lockedChildren = 0
    @State private var showingSheet = false

    var body: some View {
        Group {
            if let current = row, current.state == .locked || lockedChildren > 0 {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text(current.state == .locked ? (current.note ?? String(localized: "Locked")) : String(localized: "Files inside are password-protected: \(lockedChildren)"))
                        .font(Typography.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if current.state == .locked, current.extractor == "openpgp" {
                        // Directive §6 "OpenPGP": never decrypted (GAP-PGP keeps public keys only) — a password field would be a false promise.
                        Text(String(localized: "OpenPGP: not decrypted, public keys only"))
                            .font(Typography.caption1).foregroundStyle(.secondary)
                            .help(String(localized: "The file is described from its OpenPGP packet headers; mailin keeps public keys only, so a password cannot open it here"))
                            .accessibilityIdentifier("attachment.unlock.openpgp.\(position)")
                    } else {
                        Button(String(localized: "Unlock…")) { showingSheet = true }
                            .buttonStyle(.plain)
                            .font(Typography.caption1)
                            .foregroundStyle(Color.accentColor)
                            .help(String(localized: "Type the file's password once to read what is inside"))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("attachment.unlock.\(position)")
                .sheet(isPresented: $showingSheet) {
                    AttachmentUnlockSheet(emailID: emailID, position: position, filename: filename) {
                        Task { @MainActor in await refresh() }
                    }
                }
            }
        }
        .task(id: "\(emailID.uuidString)#\(position)") { await refresh() }
    }

    @MainActor
    private func refresh() async {
        row = await AttachmentTextIndexJob.shared.coverageRow(emailID: emailID, position: position)
        lockedChildren = await ArchiveDataService.shared.attachmentChildren(emailID: emailID)
            .filter { $0.position == position && $0.state == ChildDocument.State.locked.rawValue }.count
    }
}

struct AttachmentUnlockSheet: View {
    let emailID: UUID
    let position: Int
    let filename: String
    /// Called after the text was stored, so the lock row can refresh.
    var onStored: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var keep = false
    @State private var working = false
    @State private var message: String?
    @State private var preview: String?
    @State private var children: [ChildDocument] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(String(localized: "Unlock \(filename)")).font(Typography.headline)
            Text(String(localized: "The password is used once to read the file. It is not kept anywhere."))
                .font(Typography.caption1).foregroundStyle(.secondary)
            SecureField(String(localized: "Password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !password.isEmpty && !working { Task { await unlock() } } }
            Toggle(String(localized: "Keep the contents searchable in this archive"), isOn: $keep)
            Text(keep
                 ? String(localized: "The text inside will be stored in the archive's search index, like any other attachment.")
                 : String(localized: "The text is shown here only. Nothing is stored, and search will still report the file as locked."))
                .font(Typography.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(Typography.caption1)
                    .foregroundStyle(preview == nil ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("attachment.unlock.outcome")
            }
            if let preview {
                ScrollView {
                    Text(preview.isEmpty ? String(localized: "no text found") : preview)
                        .font(Typography.caption1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 240)
                .background(.quaternary.opacity(0.4))
                if !children.isEmpty {
                    Text(String(localized: "Files inside: \(children.count)")).font(Typography.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(String(localized: "Close")) { dismiss() }
                Spacer()
                Button(working ? String(localized: "Unlocking…") : String(localized: "Unlock")) { Task { await unlock() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 440)
    }

    @MainActor
    private func unlock() async {
        working = true
        defer { working = false }
        let typed = password
        password = ""   // used once
        let outcome = await AttachmentTextIndexJob.shared.unlock(emailID: emailID, position: position, password: typed, retain: keep)
        switch outcome {
        case .wrongPassword:
            message = String(localized: "The password did not open \(filename).")
            preview = nil
        case .unreadable(let why):
            message = String(localized: "\(filename) could not be read: \(why)")
            preview = nil
        case .unlocked(let text, let files, let stored):
            preview = text
            children = files
            message = stored
                ? String(localized: "Unlocked and stored. \(filename) is now searchable like any other attachment.")
                : String(localized: "Unlocked for this view only. Nothing was stored.")
            if stored { onStored() }
        }
    }
}
