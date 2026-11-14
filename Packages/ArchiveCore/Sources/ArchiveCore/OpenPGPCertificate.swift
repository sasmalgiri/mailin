//
//  OpenPGPCertificate.swift
//  ArchiveCore
//
//  GAP-PGP: transferable public keys (RFC 4880 §11.1, RFC 9580 §10.1) —
//  split from a packet stream, checked, and summarised.
//
//  A key is ACCEPTED only when a self-signature by its primary key verifies:
//  a user-ID certification (0x10–0x13) or a direct-key signature (0x1F).
//  A user ID whose self-signatures all fail is dropped; when nothing is left
//  the key is rejected with the reason. Subkeys need a verifying binding
//  signature (0x18) and, if they sign, a verifying embedded primary-key
//  binding signature (0x19) — otherwise the subkey is kept with the reason it
//  cannot be used. Key revocations (0x20), subkey revocations (0x28), and key
//  expiry (subpacket 9) are read from verifying signatures only.
//  Third-party certifications are kept but not judged: this is a keyring
//  of keys the person chose to import, not a web of trust.
//

import Foundation

/// The packets of one transferable public key, grouped by what they sign.
struct OpenPGPTransferableKey: Sendable, Equatable {
    var primary: OpenPGP.Packet
    var direct: [OpenPGP.Packet] = []
    var userIDs: [(OpenPGP.Packet, [OpenPGP.Packet])] = []
    var subkeys: [(OpenPGP.Packet, [OpenPGP.Packet])] = []

    static func == (a: OpenPGPTransferableKey, b: OpenPGPTransferableKey) -> Bool { a.serialized() == b.serialized() }

    /// Binary transferable public key, new-format packet headers.
    func serialized() -> [UInt8] {
        var out = Self.encode(primary)
        for p in direct { out += Self.encode(p) }
        for (uid, sigs) in userIDs { out += Self.encode(uid); for s in sigs { out += Self.encode(s) } }
        for (key, sigs) in subkeys { out += Self.encode(key); for s in sigs { out += Self.encode(s) } }
        return out
    }

    static func encode(_ packet: OpenPGP.Packet) -> [UInt8] {
        let n = packet.body.count
        var out: [UInt8] = [0xC0 | packet.tag]
        if n < 192 { out.append(UInt8(n)) }
        else if n < 8384 { out += [UInt8(((n - 192) >> 8) + 192), UInt8((n - 192) & 0xFF)] }
        else { out += [255] + PGPBytes.u32(n) }
        return out + [UInt8](packet.body)
    }

    /// Union with another copy of the same key: new user IDs, subkeys and signatures are added, nothing removed.
    func merged(with other: OpenPGPTransferableKey) -> OpenPGPTransferableKey {
        var out = self
        func union(_ a: [OpenPGP.Packet], _ b: [OpenPGP.Packet]) -> [OpenPGP.Packet] {
            var seen = Set(a.map { $0.body }); var r = a
            for p in b where !seen.contains(p.body) { r.append(p); seen.insert(p.body) }
            return r
        }
        out.direct = union(direct, other.direct)
        for (uid, sigs) in other.userIDs {
            if let i = out.userIDs.firstIndex(where: { $0.0.body == uid.body }) { out.userIDs[i].1 = union(out.userIDs[i].1, sigs) }
            else { out.userIDs.append((uid, sigs)) }
        }
        for (key, sigs) in other.subkeys {
            if let i = out.subkeys.firstIndex(where: { $0.0.body == key.body }) { out.subkeys[i].1 = union(out.subkeys[i].1, sigs) }
            else { out.subkeys.append((key, sigs)) }
        }
        return out
    }

    struct Split: Sendable {
        var keys: [OpenPGPTransferableKey] = []
        /// What was not taken, with the reason (secret keys, stray packets).
        var refused: [String] = []
    }

    /// Splits a packet stream (a key block, a keyring file) into transferable public keys.
    static func split(_ packets: [OpenPGP.Packet]) -> Split {
        var out = Split()
        var current: OpenPGPTransferableKey?
        enum Slot { case direct, userID, subkey, skipping }
        var slot = Slot.skipping
        var secretKeys = 0
        var stray = 0
        for p in packets {
            switch p.tag {
            case 6:
                if let c = current { out.keys.append(c) }
                current = OpenPGPTransferableKey(primary: p)
                slot = .direct
            case 5:
                if let c = current { out.keys.append(c) }
                current = nil
                secretKeys += 1
                slot = .skipping
            case 7:
                secretKeys += 1
                slot = .skipping
            case 13:
                guard current != nil else { stray += 1; continue }
                current!.userIDs.append((p, []))
                slot = .userID
            case 17:
                // User attribute (photo): not shown; its signatures are skipped with it.
                slot = .skipping
            case 14:
                guard current != nil else { stray += 1; continue }
                current!.subkeys.append((p, []))
                slot = .subkey
            case 2:
                guard current != nil else { stray += 1; continue }
                switch slot {
                case .direct: current!.direct.append(p)
                case .userID: current!.userIDs[current!.userIDs.count - 1].1.append(p)
                case .subkey: current!.subkeys[current!.subkeys.count - 1].1.append(p)
                case .skipping: break
                }
            case 10, 12, 21:
                continue   // marker, trust, padding
            default:
                stray += 1
            }
        }
        if let c = current { out.keys.append(c) }
        if secretKeys > 0 {
            out.refused.append("\(secretKeys) secret key packet(s) not imported — mailin keeps public keys only")
        }
        if stray > 0 { out.refused.append("\(stray) packet(s) outside a public key were skipped") }
        return out
    }
}

struct OpenPGPRevocation: Sendable, Equatable {
    let date: Date
    /// RFC 9580 §5.2.3.31: 0 none, 1 superseded, 2 compromised, 3 retired, 32 user ID no longer valid.
    let code: UInt8?
    let text: String

    /// A "hard" revocation (compromised, or no reason) makes every signature by the key suspect, whenever made.
    var isHard: Bool { code == nil || code == 0 || code == 2 }

    var reasonDescription: String {
        let name: String
        switch code {
        case 1?: name = "superseded"
        case 2?: name = "compromised"
        case 3?: name = "retired"
        case 32?: name = "user ID no longer valid"
        default: name = "no reason given"
        }
        return text.isEmpty ? name : "\(name): \(text)"
    }
}

/// A verified transferable public key.
struct OpenPGPCertificate: Sendable, Equatable {
    struct UserID: Sendable, Equatable {
        let text: String
        let selfSignedAt: Date?
        let isPrimary: Bool
        let revoked: Bool
    }

    struct Subkey: Sendable, Equatable {
        let key: OpenPGPPublicKeyPacket
        /// Nil when the subkey may sign; otherwise why it cannot be used.
        let unusableReason: String?
        let expires: Date?
        let revocation: OpenPGPRevocation?
    }

    let primary: OpenPGPPublicKeyPacket
    let userIDs: [UserID]
    let subkeys: [Subkey]
    let expires: Date?
    let revocation: OpenPGPRevocation?
    /// Dropped user IDs and subkeys, with the reason.
    let notes: [String]
    let packets: OpenPGPTransferableKey

    var fingerprintHex: String { primary.fingerprintHex }
    var keyIDHex: String { primary.keyIDHex }

    /// The primary user ID: flagged primary in its newest self-signature, else the first valid one.
    var primaryUserID: String? {
        let live = userIDs.filter { !$0.revoked }
        return (live.first { $0.isPrimary } ?? live.first ?? userIDs.first)?.text
    }

    enum Rejection: Error, Equatable, LocalizedError {
        case rejected(String)
        var errorDescription: String? { if case .rejected(let why) = self { return why }; return nil }
    }

    /// Checks every self-signature of `tpk`; throws `.rejected(reason)` when the key cannot be trusted as itself.
    init(_ tpk: OpenPGPTransferableKey) throws {
        let primary: OpenPGPPublicKeyPacket
        do { primary = try OpenPGPPublicKeyPacket(body: [UInt8](tpk.primary.body)) }
        catch let error as OpenPGPFormatError {
            if case .malformed(let why) = error { throw Rejection.rejected(why) }
            throw Rejection.rejected(error.localizedDescription)
        }
        if let reason = primary.unsupportedReason {
            throw Rejection.rejected("key \(primary.fingerprintHex): algorithm \(reason) not supported — its signatures cannot be checked")
        }
        let keyFraming = primary.hashFraming
        var notes: [String] = []
        var failures: [String] = []

        func check(_ packet: OpenPGP.Packet, _ data: [[UInt8]]) -> (OpenPGPSignaturePacket, OpenPGPSignatureCheck)? {
            guard let sig = try? OpenPGPSignaturePacket(body: [UInt8](packet.body)), sig.isIssued(by: primary) else { return nil }
            return (sig, OpenPGPSignatureMath.check(sig, over: data, key: primary))
        }

        // Direct-key signatures and key revocations.
        var revocation: OpenPGPRevocation?
        var directSelfSig: OpenPGPSignaturePacket?
        for p in tpk.direct {
            guard let (sig, result) = check(p, [keyFraming]) else { continue }
            switch (sig.type, result) {
            case (0x20, .valid):
                let r = OpenPGPRevocation(date: sig.createdDate ?? primary.createdDate, code: sig.revocationReason?.code, text: sig.revocationReason?.text ?? "")
                if revocation == nil || r.date < revocation!.date { revocation = r }
            case (0x1F, .valid):
                if directSelfSig == nil || (sig.created ?? 0) > (directSelfSig!.created ?? 0) { directSelfSig = sig }
            case (0x1F, .invalid(let why)), (0x20, .invalid(let why)):
                failures.append("the direct-key self-signature does not verify (\(why))")
            case (0x1F, .unsupported(let why)):
                failures.append("the direct-key self-signature cannot be checked (\(why))")
            default: break
            }
        }

        // User IDs: the newest verifying self-certification wins; a later verifying certification revocation revokes.
        var userIDs: [UserID] = []
        var primaryUIDSig: OpenPGPSignaturePacket?
        var newestUIDSig: OpenPGPSignaturePacket?
        for (uidPacket, sigs) in tpk.userIDs {
            let uidBytes = [UInt8](uidPacket.body)
            let text = String(decoding: uidBytes, as: UTF8.self)
            let framing: [UInt8] = [0xB4] + PGPBytes.u32(uidBytes.count) + uidBytes
            var best: OpenPGPSignaturePacket?
            var revokedAt: UInt32?
            var uidFailures: [String] = []
            for p in sigs {
                guard let (sig, result) = check(p, [keyFraming, framing]) else { continue }
                switch (sig.type, result) {
                case (0x10...0x13, .valid):
                    if best == nil || (sig.created ?? 0) > (best!.created ?? 0) { best = sig }
                case (0x30, .valid):
                    revokedAt = max(revokedAt ?? 0, sig.created ?? 0)
                case (0x10...0x13, .invalid(let why)):
                    uidFailures.append("the self-signature on “\(text)” does not verify (\(why))")
                case (0x10...0x13, .unsupported(let why)):
                    uidFailures.append("the self-signature on “\(text)” cannot be checked (\(why))")
                default: break
                }
            }
            guard let best else {
                failures += uidFailures
                if !uidFailures.isEmpty { notes.append("user ID “\(text)” dropped: " + uidFailures.joined(separator: "; ")) }
                continue
            }
            let revoked = revokedAt.map { $0 >= (best.created ?? 0) } ?? false
            userIDs.append(UserID(text: text, selfSignedAt: best.createdDate, isPrimary: best.isPrimaryUserID, revoked: revoked))
            if best.isPrimaryUserID, !revoked, primaryUIDSig == nil || (best.created ?? 0) > (primaryUIDSig!.created ?? 0) { primaryUIDSig = best }
            if !revoked, newestUIDSig == nil || (best.created ?? 0) > (newestUIDSig!.created ?? 0) { newestUIDSig = best }
        }

        guard !userIDs.isEmpty || directSelfSig != nil else {
            if failures.isEmpty {
                throw Rejection.rejected("key \(primary.fingerprintHex): no self-signature binds a user ID or the key itself")
            }
            throw Rejection.rejected("key \(primary.fingerprintHex): " + failures.joined(separator: "; ") + " — the key was altered or damaged")
        }

        // Key expiry: the direct-key signature's, else the primary (or newest) user ID's self-signature.
        let expirySource = (directSelfSig?.keyExpirationSeconds != nil ? directSelfSig : nil) ?? primaryUIDSig ?? newestUIDSig ?? directSelfSig
        let expires: Date? = expirySource?.keyExpirationSeconds.flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(primary.created) + TimeInterval($0)) }

        // Subkeys.
        var subkeys: [Subkey] = []
        for (subPacket, sigs) in tpk.subkeys {
            guard let sub = try? OpenPGPPublicKeyPacket(body: [UInt8](subPacket.body)) else {
                notes.append("a subkey could not be read and was skipped")
                continue
            }
            let framing = sub.hashFraming
            var binding: OpenPGPSignaturePacket?
            var bindingProblem: String?
            var subRevocation: OpenPGPRevocation?
            for p in sigs {
                guard let (sig, result) = check(p, [keyFraming, framing]) else { continue }
                switch (sig.type, result) {
                case (0x18, .valid):
                    if binding == nil || (sig.created ?? 0) > (binding!.created ?? 0) { binding = sig }
                case (0x18, .invalid(let why)): bindingProblem = "its binding signature does not verify (\(why))"
                case (0x18, .unsupported(let why)): bindingProblem = "its binding signature cannot be checked (\(why))"
                case (0x28, .valid):
                    subRevocation = OpenPGPRevocation(date: sig.createdDate ?? sub.createdDate, code: sig.revocationReason?.code, text: sig.revocationReason?.text ?? "")
                default: break
                }
            }
            var unusable: String?
            var subExpires: Date?
            if let binding {
                subExpires = binding.keyExpirationSeconds.flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(sub.created) + TimeInterval($0)) }
                let flags = binding.keyFlags ?? 0
                if flags & 0x02 != 0 {
                    // A signing subkey must sign back (RFC 9580 §5.2.1, primary key binding 0x19).
                    let back = binding.embedded.filter { $0.type == 0x19 }
                    if back.isEmpty {
                        unusable = "the signing subkey has no primary-key binding signature"
                    } else if !back.contains(where: { OpenPGPSignatureMath.check($0, over: [keyFraming, framing], key: sub) == .valid }) {
                        unusable = "the signing subkey's primary-key binding signature does not verify"
                    }
                } else if binding.keyFlags != nil {
                    unusable = "the subkey is not marked for signing"
                }
                if unusable == nil, let reason = sub.unsupportedReason { unusable = "algorithm \(reason) not supported" }
            } else {
                unusable = "the subkey has no verifying binding signature" + (bindingProblem.map { ": \($0)" } ?? "")
                notes.append("subkey \(sub.fingerprintHex): \(unusable!)")
            }
            subkeys.append(Subkey(key: sub, unusableReason: unusable, expires: subExpires, revocation: subRevocation))
        }

        self.primary = primary
        self.userIDs = userIDs
        self.subkeys = subkeys
        self.expires = expires
        self.revocation = revocation
        self.notes = notes
        self.packets = tpk
    }

    /// The key (primary or subkey) a signature names, with why it cannot be used if so.
    func signingKey(keyID: [UInt8]?, fingerprint: [UInt8]?) -> (key: OpenPGPPublicKeyPacket, subkey: Subkey?)? {
        if primary.matches(keyID: keyID, fingerprint: fingerprint) { return (primary, nil) }
        if let sub = subkeys.first(where: { $0.key.matches(keyID: keyID, fingerprint: fingerprint) }) { return (sub.key, sub) }
        return nil
    }
}

/// What the app shows for one key in the keyring.
struct OpenPGPKeySummary: Sendable, Equatable, Identifiable {
    var id: String { fingerprint }
    let fingerprint: String
    let keyID: String
    let algorithm: String
    let userIDs: [String]
    let primaryUserID: String?
    let created: Date
    let expires: Date?
    let revocation: OpenPGPRevocation?
    let subkeys: [String]
    let notes: [String]

    init(_ c: OpenPGPCertificate) {
        fingerprint = c.fingerprintHex
        keyID = c.keyIDHex
        algorithm = c.primary.algorithmDescription
        userIDs = c.userIDs.map(\.text)
        primaryUserID = c.primaryUserID
        created = c.primary.createdDate
        expires = c.expires
        revocation = c.revocation
        subkeys = c.subkeys.map { $0.key.fingerprintHex + " (" + $0.key.algorithmDescription + ($0.unusableReason.map { "; " + $0 } ?? "") + ")" }
        notes = c.notes
    }

    /// "RSA 3072 key A0EA…7EF5 “Rhea RSA <rhea@example.org>”, expires 2027-01-01, revoked …"
    var description: String {
        var s = "\(algorithm) key \(fingerprint)"
        if let primaryUserID { s += " “\(primaryUserID)”" }
        if let expires { s += ", " + (expires < Date() ? "expired " : "expires ") + OpenPGPVerdict.day(expires) }
        if let revocation { s += ", revoked " + OpenPGPVerdict.day(revocation.date) + " (\(revocation.reasonDescription))" }
        return s
    }
}
