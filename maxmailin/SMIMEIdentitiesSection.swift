@testable import ArchiveCore
//
//  SMIMEIdentitiesSection.swift
//  maxmailin
//
//  R6: Settings ▸ Health ▸ S/MIME identities — the certificates with private
//  keys this device can open encrypted S/MIME mail with, and "Import S/MIME
//  identity (.p12)…". The password is typed once, used to open the file and
//  cleared; the key goes into this device's keychain and is used there.
//

import SwiftUI
import UniformTypeIdentifiers

struct SMIMEIdentitiesSection: View {
    @State private var identities: [SMIMEKeychainIdentities.Identity] = []
    @State private var choosing = false
    @State private var pending: Data?
    @State private var askingPassword = false
    @State private var password = ""
    @State private var working = false
    @State private var note: String?

    var body: some View {
        Section("S/MIME identities") {
            Text("Encrypted S/MIME mail is opened with a private key in this device's keychain, when \"Read S/MIME with your keychain key\" is on in Settings ▸ Modules. The key is used where it is and never copied out. On iPhone and iPad, identities installed by a configuration profile are not available to apps — import the .p12 file here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if identities.isEmpty {
                Text("No S/MIME identity in this device's keychain. Encrypted S/MIME parts stay locked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(identities) { identity in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.commonName).font(.caption)
                        Text(Self.detail(identity.certificate)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                    Spacer()
                    #if os(iOS)
                    Button(String(localized: "Remove")) { remove(identity) }
                        .disabled(working)
                        .accessibilityIdentifier("health.smime.remove")
                    #endif
                }
            }
            Button(String(localized: "Import S/MIME identity (.p12)…")) { choosing = true }
                .disabled(working)
                .help(String(localized: "Choose a .p12 or .pfx file holding your S/MIME certificate and private key"))
                .accessibilityIdentifier("health.smime.import")
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("health.smime.note")
            }
        }
        .accessibilityIdentifier("health.smime")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pkcs12, .data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                pending = try Data(contentsOf: url)
                askingPassword = true
            } catch {
                note = String(localized: "The file could not be read: \(error.localizedDescription)")
            }
        }
        .alert(String(localized: "Password for the identity"), isPresented: $askingPassword) {
            SecureField(String(localized: "Password"), text: $password)
            Button(String(localized: "Import")) { Task { await importPending() } }
            Button(String(localized: "Cancel"), role: .cancel) { pending = nil; password = "" }
        } message: {
            Text("The password opens the file once and is not kept.")
        }
        .task { await reload() }
    }

    private func reload() async {
        identities = SMIMEKeychainIdentities.mailIdentities()
    }

    private func importPending() async {
        guard let data = pending else { return }
        let typed = password
        pending = nil; password = ""   // the password is not kept past this call
        working = true; defer { working = false }
        do {
            let certificate = try SMIMEKeychainIdentities.importPKCS12(data, password: typed)
            let reread = await AttachmentTextIndexJob.shared.rereadSMIME()
            note = Self.importNote(name: certificate.commonName ?? certificate.emailAddresses.first ?? "—", reread: reread)
        } catch {
            note = SMIMEKeychainIdentities.describe(error)
        }
        await reload()
    }

    private func remove(_ identity: SMIMEKeychainIdentities.Identity) {
        note = SMIMEKeychainIdentities.remove(identity)
            ? String(localized: "Identity removed from this device's keychain.")
            : String(localized: "The keychain could not remove the identity.")
        Task { await reload() }
    }

    static func detail(_ certificate: X509Certificate) -> String {
        let email = certificate.emailAddresses.joined(separator: ", ")
        guard let until = certificate.notAfter else { return email }
        return String(localized: "\(email) — valid until \(until.formatted(date: .abbreviated, time: .omitted))")
    }

    static func importNote(name: String, reread: Int) -> String {
        String(localized: "Imported \(name). S/MIME parts in \(reread) messages will be read again.")
    }
}
