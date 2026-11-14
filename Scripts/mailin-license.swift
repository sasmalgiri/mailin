#!/usr/bin/env swift
//
// mailin-license.swift — issue enterprise license keys (LICENSING.md).
//
//   swift Scripts/mailin-license.swift keygen
//       Creates the signing key pair in ~/mailin-license-keys (once). The
//       private key never leaves that folder; back it up offline. Prints the
//       public key to paste into EnterpriseLicense.publicKeyBase64.
//
//   swift Scripts/mailin-license.swift issue --org "Acme LLP" --seats 25 --days 365 [--id ACME-2026-01]
//       Prints a key. --days 0 = no expiry. Send the key to the customer;
//       they put it in their MDM profile (licenseKey) or paste it in
//       Settings ▸ About ▸ Enter license key.
//
//   swift Scripts/mailin-license.swift show <key>
//       Decodes a key and checks its signature with the saved public key.
//
// Format: MAILIN1.<base64url payload JSON>.<base64url Ed25519 signature>.
// The app checks the signature offline with the embedded public key.
//

import Foundation
import CryptoKit

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mailin-license-keys", isDirectory: true)
let privateURL = dir.appendingPathComponent("mailin-license-private.key")
let publicURL = dir.appendingPathComponent("mailin-license-public.key")

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func unb64url(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}
func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die("usage: keygen | issue --org NAME --seats N --days D [--id ID] | show KEY") }
args.removeFirst()
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch command {
case "keygen":
    if FileManager.default.fileExists(atPath: privateURL.path) { die("A key pair already exists in \(dir.path). Delete it only if no issued key must keep working.") }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: privateURL)
    try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: publicURL)
    chmod(privateURL.path, 0o600)
    chmod(dir.path, 0o700)
    print("Private key: \(privateURL.path)  (keep it secret, back it up offline)")
    print("Public key (embed in EnterpriseLicense.publicKeyBase64):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "issue":
    guard let org = option("--org"), !org.isEmpty else { die("--org is required") }
    let seats = Int(option("--seats") ?? "") ?? 0
    let days = Int(option("--days") ?? "365") ?? 365
    guard let raw = try? String(contentsOf: privateURL, encoding: .utf8),
          let keyData = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else { die("No private key; run keygen first.") }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    let now = Date()
    var payload: [String: Any] = ["v": 1, "org": org, "seats": seats, "issued": f.string(from: now),
                                  "id": option("--id") ?? UUID().uuidString.prefix(8).uppercased()]
    if days > 0 { payload["expires"] = f.string(from: now.addingTimeInterval(Double(days) * 86_400)) }
    let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let signature = try key.signature(for: json)
    print("MAILIN1.\(b64url(json)).\(b64url(signature))")

case "show":
    guard let k = args.first else { die("show <key>") }
    let parts = k.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map(String.init)
    guard parts.count == 3, parts[0] == "MAILIN1", let json = unb64url(parts[1]), let sig = unb64url(parts[2]) else { die("Not a mailin license key.") }
    print(String(decoding: json, as: UTF8.self))
    if let raw = try? String(contentsOf: publicURL, encoding: .utf8),
       let pub = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) {
        print(key.isValidSignature(sig, for: json) ? "Signature: valid" : "Signature: INVALID")
    }

default:
    die("unknown command \(command)")
}
