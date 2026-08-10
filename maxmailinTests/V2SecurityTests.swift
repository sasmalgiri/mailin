import XCTest
@testable import maxmailin

/// Part V/W security qualification:
///  • Part V — the S/MIME status→verdict mapping, tested exhaustively at the
///    pure-function layer (all six required fixtures expressed as
///    fixture-equivalent input combinations — deterministic, executed, no
///    external crypto tooling required).
///  • Part W3 — at-rest artifact protection (owner-only permissions on
///    macOS; Data Protection classes are iOS-only and compile-gated).
///
/// ─────────────────────────────────────────────────────────────────────────
/// OWNER STEP (end-to-end CMSDecoder fixtures) — "S/MIME openssl fixture
/// generation", owner-runnable, NOT executed by this suite:
/// The mapping layer below is fully covered here; feeding real CMS blobs
/// through CMSDecoder additionally exercises Apple's decoder itself. The
/// script writes ONLY to /tmp and requires openssl (which this environment
/// must not run):
///
///   #!/bin/sh
///   # /tmp/smime-fixtures.sh — generates the six S/MIME test fixtures.
///   set -e; cd /tmp && mkdir -p smime-fixtures && cd smime-fixtures
///   # 1. CA + leaf certificate (untrusted unless the CA is added to a
///   #    test keychain as a trusted anchor).
///   openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem \
///     -days 365 -nodes -subj "/CN=Mailin Test CA"
///   openssl req -newkey rsa:2048 -keyout leaf.key -out leaf.csr \
///     -nodes -subj "/CN=Mailin Signer/emailAddress=signer@test.local"
///   openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key \
///     -CAcreateserial -out leaf.pem -days 365 \
///     -extfile <(printf "extendedKeyUsage=emailProtection")
///   printf 'Content-Type: text/plain\r\n\r\nfixture body\r\n' > content.txt
///   # 2. valid+trusted: sign, then (manually) trust ca.pem in a test
///   #    keychain: security add-trusted-cert -d -k <test.keychain> ca.pem
///   openssl smime -sign -in content.txt -signer leaf.pem -inkey leaf.key \
///     -certfile ca.pem -nodetach -outform DER -out valid.p7
///   # 3. valid crypto + untrusted: same valid.p7, evaluated WITHOUT the CA
///   #    trusted → validUntrustedCert.
///   # 4. tampered content: flip a byte inside the encapsulated content.
///   python3 - <<'EOF'
///   d = bytearray(open('valid.p7','rb').read())
///   i = d.find(b'fixture body'); d[i] ^= 0xFF
///   open('tampered.p7','wb').write(d)
///   EOF
///   # 5. bad signature bytes: flip a byte in the LAST 16 bytes (inside the
///   #    signature OCTET STRING).
///   python3 -c "d=bytearray(open('valid.p7','rb').read()); d[-8]^=0xFF; open('badsig.p7','wb').write(d)"
///   # 6. malformed CMS: truncate the blob.
///   head -c 40 valid.p7 > malformed.p7
///   # 7. missing certs: sign without embedding certificates.
///   openssl smime -sign -in content.txt -signer leaf.pem -inkey leaf.key \
///     -nocerts -nodetach -outform DER -out nocerts.p7
///
/// Wrap each .p7 in a pkcs7-mime MBOXParser.RawEmail and assert
/// SMIMEHandler.verifySignature(of:) returns: validTrusted / validUntrustedCert /
/// invalid / invalid / unverifiable / unverifiable respectively.
/// ─────────────────────────────────────────────────────────────────────────
final class V2SecurityTests: XCTestCase {

    typealias V = SMIMEHandler.SignatureStatus
    typealias D = SMIMEHandler.DecoderStatus
    typealias T = SMIMEHandler.TrustOutcome

    private func verdict(parseError: Bool = false,
                         status: D?,
                         trust: T = .unavailable,
                         certs: Bool = true,
                         expired: Bool = false) -> V {
        SMIMEHandler.mapVerdict(parseError: parseError,
                                decoderStatus: status,
                                trustResult: trust,
                                certsPresent: certs,
                                certExpired: expired)
    }

    // MARK: - Part V — the six required fixtures (mapping layer)

    /// Fixture 1: cryptographically valid signature chaining to a trusted
    /// anchor → the ONLY combination allowed to claim validTrusted.
    func testSMIME_fixture1_validTrustedAnchor() {
        XCTAssertEqual(verdict(status: .valid, trust: .trusted, certs: true), .validTrusted)
    }

    /// Fixture 2: valid crypto, cert chain NOT trusted (self-signed/unknown
    /// CA) → validUntrustedCert, never "Valid".
    func testSMIME_fixture2_validCryptoUntrustedChain() {
        XCTAssertEqual(verdict(status: .valid, trust: .untrusted, certs: true), .validUntrustedCert)
        // Trust evaluation unavailable is also NOT a trusted claim.
        XCTAssertEqual(verdict(status: .valid, trust: .unavailable, certs: true), .validUntrustedCert)
    }

    /// Fixture 3: TAMPERED CONTENT — CMSDecoder reports invalidSignature.
    /// This is the forensic-grade misclassification the old code had (it fell
    /// through `default:` into "Unknown Signer"). It MUST map to .invalid.
    func testSMIME_fixture3_tamperedContentIsInvalid_neverUnknownSigner() {
        for trust in T.allCases {
            for certs in [true, false] {
                for expired in [true, false] {
                    XCTAssertEqual(
                        verdict(status: .invalidSignature, trust: trust, certs: certs, expired: expired),
                        .invalid,
                        "invalidSignature must be .invalid for trust=\(trust) certs=\(certs) expired=\(expired)")
                }
            }
        }
    }

    /// Fixture 4: bad signature bytes (corrupt signature, intact structure)
    /// — same decoder status as tampering (the crypto check fails) → invalid.
    func testSMIME_fixture4_badSignatureBytesIsInvalid() {
        XCTAssertEqual(verdict(status: .invalidSignature, trust: .trusted), .invalid)
    }

    /// Fixture 5: malformed CMS (decoder update/finalize failed) → the parse
    /// never produced a status; unverifiable, NOT invalid (no tampering claim).
    func testSMIME_fixture5_malformedCMSIsUnverifiable() {
        for trust in T.allCases {
            XCTAssertEqual(verdict(parseError: true, status: nil, trust: trust, certs: false), .unverifiable)
            // Even a nonsensical "parse failed but status present" input must
            // stay unverifiable — parse failure dominates.
            XCTAssertEqual(verdict(parseError: true, status: .valid, trust: trust, certs: true), .unverifiable)
        }
    }

    /// Fixture 6: missing certificates — signature cannot be attributed →
    /// unverifiable (covers both `.valid`-without-certs and `.invalidCert`
    /// with no certificates present).
    func testSMIME_fixture6_missingCertsIsUnverifiable() {
        XCTAssertEqual(verdict(status: .valid, trust: .unavailable, certs: false), .unverifiable)
        XCTAssertEqual(verdict(status: .invalidCert, trust: .unavailable, certs: false), .unverifiable)
    }

    // MARK: - Part V — exhaustive combination matrix

    /// Every (parseError × decoderStatus(+nil) × trust × certsPresent ×
    /// certExpired) combination maps to an EXPLICIT expected verdict from an
    /// independent oracle table — no combination may drift silently.
    func testSMIME_mappingMatrixExhaustive() {
        // Independent oracle (spelled from the Part V spec, not from the
        // implementation's control flow).
        func expected(parseError: Bool, status: D?, trust: T, certs: Bool, expired: Bool) -> V {
            if parseError { return .unverifiable }         // malformed CMS
            guard let status else { return .unverifiable } // status unobtainable
            switch status {
            case .unsigned:             return .notSigned
            case .needsDetachedContent: return .unverifiable
            case .invalidIndex:         return .unverifiable
            case .invalidSignature:     return .invalid    // tampering/bad sig
            case .invalidCert:          return certs ? .validUntrustedCert : .unverifiable
            case .valid:
                if !certs { return .unverifiable }         // unattributable
                if trust == .trusted && !expired { return .validTrusted }
                return .validUntrustedCert                 // untrusted/unavailable/expired
            }
        }

        var combos = 0
        let statuses: [D?] = [nil] + D.allCases.map { Optional($0) }
        for parseError in [false, true] {
            for status in statuses {
                for trust in T.allCases {
                    for certs in [true, false] {
                        for expired in [true, false] {
                            let got = verdict(parseError: parseError, status: status,
                                              trust: trust, certs: certs, expired: expired)
                            let want = expected(parseError: parseError, status: status,
                                                trust: trust, certs: certs, expired: expired)
                            XCTAssertEqual(got, want,
                                "mapVerdict(parseError:\(parseError), status:\(String(describing: status)), trust:\(trust), certs:\(certs), expired:\(expired))")
                            combos += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combos, 2 * 7 * 3 * 2 * 2, "full 168-combination matrix executed")
    }

    /// Structural invariants of the verdict model itself.
    func testSMIME_verdictModelInvariants() {
        // Exactly the four semantic states + notSigned passthrough.
        XCTAssertEqual(Set(V.allCases),
                       [.validTrusted, .validUntrustedCert, .invalid, .unverifiable, .notSigned])
        // No ambiguous bare "Valid" label anywhere.
        for v in V.allCases where v != .notSigned {
            XCTAssertNotEqual(v.rawValue, "Valid", "no ambiguous 'Valid' presentation")
        }
        // validTrusted is reachable ONLY via (valid, trusted, certs, !expired).
        for status in [nil] + D.allCases.map({ Optional($0) }) {
            for trust in T.allCases {
                for certs in [true, false] {
                    for expired in [true, false] {
                        let v = verdict(status: status, trust: trust, certs: certs, expired: expired)
                        if v == .validTrusted {
                            XCTAssertEqual(status, .valid)
                            XCTAssertEqual(trust, .trusted)
                            XCTAssertTrue(certs)
                            XCTAssertFalse(expired)
                        }
                    }
                }
            }
        }
    }

    /// An email with no S/MIME content type passes straight through as
    /// notSigned (end-to-end over the real entry point — no CMS involved).
    func testSMIME_plainEmailIsNotSigned() {
        let email = MBOXParser.RawEmail(
            headers: ["Content-Type": "text/plain", "Subject": "s", "Message-ID": "<p@t>"],
            rawSource: "From a@b.com\nplain body",
            messageType: "email",
            attachments: [],
            timestamp: "2025-01-15T14:30:00Z",
            domains: ["b.com"],
            plainBody: "plain body",
            htmlBody: ""
        )
        XCTAssertEqual(SMIMEHandler.verifySignature(of: email).status, .notSigned)
    }

    /// A pkcs7-mime email whose "signature" is garbage bytes must come back
    /// unverifiable (malformed CMS), never invalid and never any valid state.
    /// Executes the real macOS CMSDecoder path with a deterministic non-CMS
    /// blob — no external crypto tooling needed.
    func testSMIME_garbageCMSBlobIsUnverifiable() throws {
        #if os(macOS)
        let garbage = Data("definitely-not-der-encoded-cms-content-0123456789".utf8)
            .base64EncodedString()
        let email = MBOXParser.RawEmail(
            headers: [
                "Content-Type": "application/pkcs7-mime; smime-type=signed-data",
                "Subject": "s", "Message-ID": "<g@t>"
            ],
            rawSource: "Content-Type: application/pkcs7-mime; smime-type=signed-data\n\n\(garbage)\n\(garbage)\n\(garbage)",
            messageType: "email",
            attachments: [],
            timestamp: "2025-01-15T14:30:00Z",
            domains: ["b.com"],
            plainBody: "",
            htmlBody: ""
        )
        let result = SMIMEHandler.verifySignature(of: email)
        XCTAssertEqual(result.status, .unverifiable,
            "garbage CMS must be unverifiable, got \(result.status)")
        #else
        throw XCTSkip("CMSDecoder path is macOS-only")
        #endif
    }

    // MARK: - W3 — artifact protection attributes (macOS-verifiable)

    private func posixPerms(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// The helper itself: directories → 700, files → 600, missing path → no-op.
    func testArtifactProtection_ownerOnlyPermissionsOnMacOS() throws {
        #if os(macOS)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("prot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("artifact.json")
        try Data("x".utf8).write(to: file)

        ArtifactProtection.applyBackgroundReadable(to: dir)
        ArtifactProtection.applyBackgroundReadable(to: file)
        XCTAssertEqual(try posixPerms(dir), 0o700, "code-created dir must be owner-only")
        XCTAssertEqual(try posixPerms(file), 0o600, "artifact file must be owner-only")

        // Foreground-only variant enforces the same POSIX posture on macOS.
        let file2 = dir.appendingPathComponent("fg.bin")
        try Data("y".utf8).write(to: file2)
        ArtifactProtection.applyForegroundOnly(to: file2)
        XCTAssertEqual(try posixPerms(file2), 0o600)

        // Missing path: must not throw or create anything.
        ArtifactProtection.applyBackgroundReadable(to: dir.appendingPathComponent("nope.db"))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("nope.db").path))
        #else
        throw XCTSkip("POSIX permission assertions are macOS-only; iOS uses Data Protection classes")
        #endif
    }

    /// Real artifact sites: an import receipt and an import checkpoint written
    /// through the production stores land owner-only.
    func testArtifactProtection_receiptAndCheckpointSitesApplyIt() async throws {
        #if os(macOS)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("prot-sites-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        // Receipt store.
        let receipts = ImportReceiptStore(directory: root.appendingPathComponent("receipts", isDirectory: true))
        var receipt = ImportReceipt(startedAt: Date(), completedAt: Date())
        try receipt.finalize()
        let receiptURL = try receipts.save(receipt)
        XCTAssertEqual(try posixPerms(receiptURL), 0o600, "receipt file owner-only")
        XCTAssertEqual(try posixPerms(receipts.directory), 0o700, "receipts dir owner-only")

        // Checkpoint store (isolated instance).
        let cpURL = root.appendingPathComponent("cp", isDirectory: true).appendingPathComponent("import_checkpoints.json")
        let store = ImportCheckpointStore(storeURL: cpURL)
        try await store.record(sha256: "abc", sourceName: "f.mbox", emailCount: 1)
        XCTAssertEqual(try posixPerms(cpURL), 0o600, "checkpoint file owner-only")

        // SQLite store: creating the DB applies owner-only to dir + file.
        let sqlDir = root.appendingPathComponent("sqlite", isDirectory: true)
        let sql = SQLiteEmailStore(directory: sqlDir)
        _ = try await sql.totalCount()   // forces ensureDB()
        XCTAssertEqual(try posixPerms(sqlDir), 0o700, "sqlite dir owner-only")
        XCTAssertEqual(try posixPerms(sqlDir.appendingPathComponent("emails.db")), 0o600, "emails.db owner-only")

        // FTS shard: indexing creates the shard with owner-only permissions.
        let ftsDir = root.appendingPathComponent("fts", isDirectory: true)
        let fts = FTSSearchIndex(shardsDirectory: ftsDir)
        let email = MBOXParser.RawEmail(
            headers: ["Message-ID": "<w3@t>", "Subject": "s", "Date": "Wed, 15 Jan 2025 14:30:00 +0000"],
            rawSource: "From a@b.com\nbody", messageType: "email", attachments: [],
            timestamp: "2025-01-15T14:30:00Z", domains: ["b.com"], plainBody: "body", htmlBody: "")
        try await fts.indexBatch([email])
        XCTAssertEqual(try posixPerms(ftsDir), 0o700, "fts shards dir owner-only")
        XCTAssertEqual(try posixPerms(ftsDir.appendingPathComponent("email_search_2025.db")), 0o600, "shard owner-only")
        #else
        throw XCTSkip("POSIX permission assertions are macOS-only")
        #endif
    }
}
