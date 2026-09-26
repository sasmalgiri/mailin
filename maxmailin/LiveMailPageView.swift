//
//  LiveMailPageView.swift
//  maxmailin
//
//  live-mail branch — Page 4 shell. What is built: the account model (L2),
//  the network gate (L1), IMAP password / XOAUTH2 authentication and a
//  connection test that lists folders (L3a). What is NOT built is stated on
//  the page rather than implied: no sync, no reading pane, no compose, no
//  send, no archive bridge (L4–L8). Nothing here writes archive tables.
//

import SwiftUI

struct LiveMailPageView: View {
    @Environment(ModuleRegistry.self) private var modules
    @State private var registry = AccountRegistry.shared
    @State private var gate = LiveMailNetworkGate.shared
    @State private var showAdd = false
    @State private var testResults: [UUID: String] = [:]
    @State private var testing: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notBuiltNotice
            Divider()
            if registry.accounts.isEmpty {
                ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Add a generic IMAP account with an app-specific password. Microsoft Graph accounts need the organisation's Entra client id, which this build does not have."))
            } else {
                List {
                    ForEach(registry.accounts) { account in
                        row(account)
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            LiveMailAddAccountSheet(registry: registry) { showAdd = false }
        }
        .accessibilityIdentifier("liveMail.page")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Mail").font(.title3.weight(.semibold))
                Text(gate.isOpen ? "Network gate open — connections are permitted while this page is on."
                                 : "Network gate closed — no connection can be made.")
                    .font(.caption).foregroundStyle(gate.isOpen ? .green : .secondary)
            }
            Spacer()
            Button { showAdd = true } label: { Label("Add Account", systemImage: "plus") }
                .accessibilityIdentifier("liveMail.addAccount")
        }
        .padding(12)
    }

    private var notBuiltNotice: some View {
        Label("""
            This branch adds accounts and tests their connection. Receiving, reading, composing and \
            sending mail, and copying messages into the Archive, are not built yet — no button here \
            pretends otherwise.
            """, systemImage: "hammer")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func row(_ account: LiveMailAccount) -> some View {
        HStack(alignment: .top) {
            Image(systemName: account.kind == .imap ? "envelope" : "cloud")
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.callout.weight(.medium))
                Text("\(account.emailAddress) · \(account.imapServer):\(account.imapPort)")
                    .font(.caption).foregroundStyle(.secondary)
                if let result = testResults[account.id] {
                    Text(result).font(.caption2).foregroundStyle(result.hasPrefix("OK") ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if testing.contains(account.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Test connection") { Task { await test(account) } }
                    .controlSize(.small)
                    .disabled(!gate.isOpen)
                    .help(gate.isOpen ? "Connect, authenticate and list folders; nothing is downloaded" : "Enable Live Mail first")
            }
            Button(role: .destructive) { registry.remove(id: account.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .help("Remove this account and its stored credentials")
        }
        .padding(.vertical, 4)
    }

    private func test(_ account: LiveMailAccount) async {
        testing.insert(account.id)
        defer { testing.remove(account.id) }
        let client = IMAPClient()
        do {
            try await client.connect(config: registry.imapConfig(for: account))
            let folders = try await client.listFolders()
            await client.disconnect()
            testResults[account.id] = "OK — authenticated, \(folders.count) folders"
        } catch {
            await client.disconnect()
            testResults[account.id] = "Failed — \(error.localizedDescription)"
        }
    }
}

struct LiveMailAddAccountSheet: View {
    let registry: AccountRegistry
    let onDone: () -> Void

    @State private var displayName = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var imapServer = ""
    @State private var imapPort = "993"
    @State private var smtpServer = ""
    @State private var smtpPort = "587"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an IMAP account").font(.headline)
            Text("Use an app-specific password, not your account password. Credentials are stored in the Keychain under this account's own id.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("iCloud") { preset("imap.mail.me.com", "smtp.mail.me.com") }
                Button("Gmail") { preset("imap.gmail.com", "smtp.gmail.com") }
                Button("Outlook.com") { preset("outlook.office365.com", "smtp.office365.com") }
                Button("Fastmail") { preset("imap.fastmail.com", "smtp.fastmail.com") }
            }
            .controlSize(.small)
            Form {
                TextField("Display name", text: $displayName)
                TextField("Email address", text: $email)
                TextField("Username", text: $username)
                SecureField("App-specific password", text: $password)
                TextField("IMAP server", text: $imapServer)
                TextField("IMAP port", text: $imapPort)
                TextField("SMTP server", text: $smtpServer)
                TextField("SMTP port", text: $smtpPort)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onDone).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    registry.add(LiveMailAccount(kind: .imap, displayName: displayName.isEmpty ? email : displayName,
                                                 emailAddress: email, username: username.isEmpty ? email : username,
                                                 imapServer: imapServer, imapPort: UInt16(imapPort) ?? 993,
                                                 smtpServer: smtpServer, smtpPort: UInt16(smtpPort) ?? 587),
                                 password: password)
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || imapServer.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func preset(_ imap: String, _ smtp: String) { imapServer = imap; smtpServer = smtp }
}
