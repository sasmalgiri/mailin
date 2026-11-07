@testable import ArchiveCore
//
//  OpenPGPKeysSection.swift
//  maxmailin
//
//  GAP-PGP (owner 2026-11-07): Settings ▸ Health ▸ OpenPGP public keys — the
//  archive's on-device keyring. Public keys only: secret keys are refused,
//  nothing is decrypted and no key server is contacted. Importing or removing
//  a key re-reads every OpenPGP row so its verdict follows the keys.
//

import SwiftUI
import UniformTypeIdentifiers

struct OpenPGPKeysSection: View {
    @State private var keys: [OpenPGPKeySummary] = []
    @State private var importing = false
    @State private var working = false
    @State private var note: String?
    @State private var rejected: [String] = []

    var body: some View {
        Section("OpenPGP public keys") {
            Text("Signatures on messages and attachments are checked against these keys, on this device. Only public keys are kept; nothing is decrypted and no key server is contacted.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if keys.isEmpty {
                Text("No public keys imported. Signatures are listed as made by an unknown key.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(keys) { key in
                HStack(alignment: .firstTextBaseline) {
                    Text(key.description)
                        .font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "Remove")) { Task { await remove(key) } }
                        .disabled(working)
                        .accessibilityIdentifier("health.openpgp.remove.\(key.fingerprint)")
                }
            }
            Button(String(localized: "Import public key…")) { importing = true }
                .disabled(working)
                .help(String(localized: "Choose a .asc, .gpg or .pgp file holding one or more public keys"))
                .accessibilityIdentifier("health.openpgp.import")
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("health.openpgp.note")
            }
            ForEach(rejected, id: \.self) { reason in
                Text(reason).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("health.openpgp")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await importKeys(from: url) }
        }
        .task { keys = await AttachmentTextIndexJob.shared.publicKeys() }
    }

    private func importKeys(from url: URL) async {
        working = true; defer { working = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let (result, reverified) = try await AttachmentTextIndexJob.shared.importPublicKeys(data)
            note = Self.importNote(imported: result.imported.count, updated: result.updated.count,
                                   rejected: result.rejected.count, reverified: reverified)
            rejected = result.rejected
        } catch {
            note = String(localized: "The file could not be read: \(error.localizedDescription)")
            rejected = []
        }
        keys = await AttachmentTextIndexJob.shared.publicKeys()
    }

    private func remove(_ key: OpenPGPKeySummary) async {
        working = true; defer { working = false }
        do {
            let reverified = try await AttachmentTextIndexJob.shared.removePublicKey(fingerprint: key.fingerprint)
            note = String(localized: "Key removed. Signatures in \(reverified) messages will be checked again.")
        } catch {
            note = String(localized: "The keyring could not be changed: \(error.localizedDescription)")
        }
        rejected = []
        keys = await AttachmentTextIndexJob.shared.publicKeys()
    }

    /// What one import did, counted — the keys themselves are listed above.
    static func importNote(imported: Int, updated: Int, rejected: Int, reverified: Int) -> String {
        String(localized: "Imported \(imported), updated \(updated), rejected \(rejected). Signatures in \(reverified) messages will be checked again.")
    }
}
