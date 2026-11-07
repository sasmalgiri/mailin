//
//  OpenPGPKeyring.swift
//  ArchiveCore
//
//  GAP-PGP: the on-device store of PUBLIC keys the person imported.
//
//  Storage: one file, `<archive root>/openpgp/public-keyring.pgp` — binary
//  transferable public keys laid end to end (the same layout as a GnuPG
//  `pubring.gpg` export), written atomically. No database table, so no
//  schema migration. The file holds exactly what was imported (after the
//  self-signature check); every load re-checks every key, so a damaged file
//  can never smuggle in an unchecked key.
//
//  Nothing here holds secret keys or passphrases, and nothing is fetched:
//  a key enters only through `importKeys(data:)`.
//
//  Verification results are derived each time a message or attachment is
//  described; they are never written into the original message.
//

import Foundation

final class OpenPGPKeyring: @unchecked Sendable {
    /// Where the archive at `root` keeps its keyring.
    static func fileURL(underArchiveRoot root: URL) -> URL {
        root.appendingPathComponent("openpgp", isDirectory: true).appendingPathComponent("public-keyring.pgp")
    }

    /// The archive's keyring for this process — the app sets it when the
    /// archive opens (`OpenPGPKeyring.active = OpenPGPKeyring(fileURL: …)`).
    /// Until then an empty keyring: every signature is "unknown key".
    static var active: OpenPGPKeyring {
        get { activeLock.lock(); defer { activeLock.unlock() }; return activeStorage }
        set { activeLock.lock(); activeStorage = newValue; activeLock.unlock() }
    }
    nonisolated(unsafe) private static var activeStorage = OpenPGPKeyring(fileURL: nil)
    private static let activeLock = NSLock()

    /// What one import did.
    struct ImportResult: Sendable, Equatable {
        /// Keys new to the keyring.
        var imported: [OpenPGPKeySummary] = []
        /// Keys already present, merged with any new user IDs, subkeys or signatures (a revocation, a new expiry).
        var updated: [OpenPGPKeySummary] = []
        /// Not taken, with the reason (bad self-signature, unsupported algorithm, secret key, not a key).
        var rejected: [String] = []

        var count: Int { imported.count + updated.count }
    }

    enum KeyringError: Error, LocalizedError, Equatable {
        case notAKey(String)
        case write(String)
        var errorDescription: String? {
            switch self {
            case .notAKey(let why): return "No OpenPGP public key found: \(why)"
            case .write(let why): return "The keyring could not be saved: \(why)"
            }
        }
    }

    let fileURL: URL?
    private let lock = NSLock()
    private var certificates: [OpenPGPCertificate] = []
    /// Keys in the file that no longer pass the check (never used; dropped at the next write).
    private(set) var loadProblems: [String] = []

    /// Opens (or starts) the keyring at `fileURL`; nil keeps it in memory only (tests, no archive open).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        guard let packets = try? OpenPGP.packets(in: data) else {
            loadProblems = ["the keyring file \(fileURL.lastPathComponent) is damaged and was not read"]
            return
        }
        for tpk in OpenPGPTransferableKey.split(packets).keys {
            do { certificates.append(try OpenPGPCertificate(tpk)) }
            catch { loadProblems.append(error.localizedDescription) }
        }
    }

    /// The keys, in import order.
    func list() -> [OpenPGPKeySummary] {
        lock.lock(); defer { lock.unlock() }
        return certificates.map(OpenPGPKeySummary.init)
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return certificates.isEmpty }

    /// Imports every public key in `data` (ASCII-armored or binary; several
    /// keys in one file are fine). Secret keys are refused, keys whose
    /// self-signature fails are rejected with the reason, a key already present
    /// is merged. The file is written once, atomically, when anything changed.
    @discardableResult
    func importKeys(data: Data) throws -> ImportResult {
        let packets = try Self.keyPackets(in: data)
        let split = OpenPGPTransferableKey.split(packets)
        var result = ImportResult()
        result.rejected += split.refused
        if split.keys.isEmpty {
            if result.rejected.isEmpty { throw KeyringError.notAKey("the file holds no public-key packet") }
            return result
        }
        lock.lock(); defer { lock.unlock() }
        var next = certificates
        var changed = false
        for tpk in split.keys {
            let incoming: OpenPGPCertificate
            do { incoming = try OpenPGPCertificate(tpk) }
            catch { result.rejected.append(error.localizedDescription); continue }
            if let i = next.firstIndex(where: { $0.primary.fingerprint == incoming.primary.fingerprint }) {
                let merged = next[i].packets.merged(with: tpk)
                guard merged != next[i].packets, let cert = try? OpenPGPCertificate(merged) else {
                    result.updated.append(OpenPGPKeySummary(next[i]))
                    continue
                }
                next[i] = cert
                result.updated.append(OpenPGPKeySummary(cert))
                changed = true
            } else {
                next.append(incoming)
                result.imported.append(OpenPGPKeySummary(incoming))
                changed = true
            }
        }
        if changed {
            try write(next)
            certificates = next
        }
        return result
    }

    /// Removes the key with this primary fingerprint (hex, spaces ignored). Returns whether one was removed.
    @discardableResult
    func remove(fingerprint: String) throws -> Bool {
        let wanted = fingerprint.replacingOccurrences(of: " ", with: "").uppercased()
        lock.lock(); defer { lock.unlock() }
        let next = certificates.filter { $0.fingerprintHex != wanted }
        guard next.count != certificates.count else { return false }
        try write(next)
        certificates = next
        return true
    }

    /// The certificate and key a signature names (by issuer fingerprint, else key ID).
    func lookup(keyID: [UInt8]?, fingerprint: [UInt8]?) -> (certificate: OpenPGPCertificate, key: OpenPGPPublicKeyPacket, subkey: OpenPGPCertificate.Subkey?)? {
        lock.lock(); defer { lock.unlock() }
        for c in certificates {
            if let hit = c.signingKey(keyID: keyID, fingerprint: fingerprint) { return (c, hit.key, hit.subkey) }
        }
        // A fingerprint the signature names but no key matches: fall back to its key ID.
        if fingerprint != nil, let keyID {
            for c in certificates {
                if let hit = c.signingKey(keyID: keyID, fingerprint: nil) { return (c, hit.key, hit.subkey) }
            }
        }
        return nil
    }

    private func write(_ certs: [OpenPGPCertificate]) throws {
        guard let fileURL else { return }
        var bytes: [UInt8] = []
        for c in certs { bytes += c.packets.serialized() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: fileURL, options: .atomic)
        } catch {
            throw KeyringError.write(error.localizedDescription)
        }
    }

    /// Key packets from armored or binary data.
    static func keyPackets(in data: Data) throws -> [OpenPGP.Packet] {
        if let text = String(data: data.prefix(16_384), encoding: .utf8) ?? String(data: data.prefix(16_384), encoding: .isoLatin1),
           text.contains("-----BEGIN PGP ") {
            let whole = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            // Every armored block in the file (people paste several keys into one .asc).
            var packets: [OpenPGP.Packet] = []
            var rest = Substring(whole)
            while let begin = rest.range(of: "-----BEGIN PGP ") {
                let block = rest[begin.lowerBound...]
                guard let endMarker = block.range(of: "-----END PGP "),
                      let lineEnd = block[endMarker.upperBound...].range(of: "-----") else { break }
                let armorText = String(block[..<lineEnd.upperBound])
                rest = block[lineEnd.upperBound...]
                do {
                    let armor = try OpenPGP.dearmor(armorText)
                    packets += try OpenPGP.packets(in: armor.data)
                } catch {
                    throw KeyringError.notAKey(error.localizedDescription)
                }
            }
            guard !packets.isEmpty else { throw KeyringError.notAKey("no armored block could be read") }
            return packets
        }
        if data.isEmpty { throw KeyringError.notAKey("the file is empty") }
        do { return try OpenPGP.packets(in: data) } catch { throw KeyringError.notAKey(error.localizedDescription) }
    }
}
