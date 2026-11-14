//
//  OwnerPackFixtureTests.swift
//  ArchiveCoreTests
//
//  R9 (release preflight), the two halves of directive 2026-11-07 §3's
//  owner pack, installed under `<fixture root>/owner-pack/` with
//  `owner-pack/SHA256SUMS` (owner permission 2026-11-09):
//
//   • smime/   synthetic S/MIME set made with OpenSSL 3.5.1
//              (`Scripts/r9_make_smime_fixtures.sh`): a throwaway CA, Alice
//              (RSA) and Bob (EC P-256) as .p12 with a known password, signed
//              (opaque / detached, RSA / ECDSA), enveloped (RSA / ECDH / GCM),
//              signed-then-enveloped and a tampered message. Read here by the
//              PORTABLE CMS reader (`CMSEnvelope`, `CMSSignedData`) with the
//              private keys from `SecPKCS12Import(kSecImportToMemoryOnly)` —
//              no keychain is touched.
//   • native/  an mbox WRITTEN BY APPLE MAIL 16 (Mailbox ▸ Export Mailbox…) of
//              six synthetic messages and the .eml set of the same messages
//              (each message's source as Mail holds it). mailin imports both;
//              the message sets must be identical and match the inventory
//              written when the source was made.
//
//  The Outlook for Mac OLM of the same messages is NOT here (no Outlook on this
//  Mac); that row stays `.pending` in `ExternalFixtures.required`.
//
//  Every fixture goes through `ExternalFixtures.require` (absent = skip naming
//  the file, present but wrong digest = failure).
//

import XCTest
import Foundation
import CryptoKit
import Security
@preconcurrency @testable import ArchiveCore

final class OwnerPackFixtureTests: XCTestCase {

    static let fixtures = ExternalFixtures.shared
    static let p12Password = "mailin-fixture-2026"

    private func url(_ relative: String) throws -> URL { try Self.fixtures.require(relative) }
    private func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }
    private static func sha256(_ d: Data) -> String { ExternalFixtures.sha256Hex(of: d) }

    // MARK: - Pinned digests

    /// The listed digests are the ones recorded in the repository: a regenerated
    /// pack (new keys, new bytes) is noticed here, not silently accepted.
    func testR9_ownerPack_listedDigestsAreThePinnedOnes() throws {
        let sums = Self.fixtures.root.appendingPathComponent("owner-pack/\(ExternalFixtures.sumsFileName)")
        guard FileManager.default.fileExists(atPath: sums.path) else {
            throw XCTSkip("pack not installed: no \(sums.path)")
        }
        let listed = ExternalFixtures.listedDigests(sums)
        XCTAssertFalse(ExternalFixtures.ownerPackDigests.isEmpty)
        for (path, pinned) in ExternalFixtures.ownerPackDigests.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(listed[String(path.dropFirst("owner-pack/".count))], pinned, path)
            if case .verified = Self.fixtures.status(of: path) {} else { XCTFail("\(path): \(Self.fixtures.status(of: path).description)") }
        }
        // Every pinned file is a required preflight row.
        for path in ExternalFixtures.ownerPackDigests.keys {
            XCTAssertTrue(ExternalFixtures.required.contains(.file(path)), "required: \(path)")
        }
    }

    // MARK: - S/MIME: identities

    struct Identity {
        let privateKey: SecKey
        let certificate: X509Certificate
        let secCertificate: SecCertificate
        var operation: CMSPrivateKeyOperation { CMSSecKeyOperation.operation(privateKey: privateKey, certificate: certificate) }
    }

    /// PKCS#12 → identity, in process memory only (macOS 15 / iOS 18 `kSecImportToMemoryOnly`).
    static func importP12(_ data: Data, password: String) throws -> (status: OSStatus, identity: Identity?) {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, iOS 18.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw XCTSkip("kSecImportToMemoryOnly needs macOS 15 / iOS 18; not importing into a keychain")
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let anyIdentity = first[kSecImportItemIdentity as String] else { return (status, nil) }
        let identity = anyIdentity as! SecIdentity
        var key: SecKey?, cert: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return (status, nil) }
        let x509 = try X509Certificate(der: [UInt8](SecCertificateCopyData(cert) as Data))
        return (status, Identity(privateKey: key, certificate: x509, secCertificate: cert))
    }

    private func identity(_ name: String) throws -> Identity {
        let result = try Self.importP12(try data("owner-pack/smime/\(name).p12"), password: Self.p12Password)
        return try XCTUnwrap(result.identity, "\(name).p12 import status \(result.status)")
    }

    static func certificate(pem: Data) throws -> SecCertificate {
        let text = String(decoding: pem, as: UTF8.self)
        let body = text.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: body, options: .ignoreUnknownCharacters))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    func testR9_smime_p12IdentitiesImportWithThePassword_andChainToTheTestCA() throws {
        let alice = try identity("alice"), bob = try identity("bob")
        XCTAssertEqual(alice.certificate.commonName, "Alice Archivist (R9 RSA)")
        XCTAssertEqual(bob.certificate.commonName, "Bob Recipient (R9 EC P-256)")
        XCTAssertEqual(alice.certificate.issuerCommonName, "mailin R9 Test CA")
        XCTAssertEqual(bob.certificate.issuerCommonName, "mailin R9 Test CA")
        XCTAssertTrue(alice.certificate.emailAddresses.contains("alice@r9.mailin.example.invalid"), "\(alice.certificate.emailAddresses)")
        XCTAssertTrue(bob.certificate.emailAddresses.contains("bob@r9.mailin.example.invalid"), "\(bob.certificate.emailAddresses)")
        // The .pem files are the same certificates.
        XCTAssertEqual(alice.certificate, try X509Certificate(der: [UInt8](SecCertificateCopyData(try Self.certificate(pem: try data("owner-pack/smime/alice.pem"))) as Data)))
        XCTAssertEqual(bob.certificate, try X509Certificate(der: [UInt8](SecCertificateCopyData(try Self.certificate(pem: try data("owner-pack/smime/bob.pem"))) as Data)))

        // A wrong password does not open the file.
        let wrong = try Self.importP12(try data("owner-pack/smime/alice.p12"), password: "not-the-password")
        XCTAssertNil(wrong.identity)
        XCTAssertEqual(wrong.status, errSecAuthFailed)

        // Chain: the CA is the only anchor, no network fetch.
        let ca = try Self.certificate(pem: try data("owner-pack/smime/ca.pem"))
        for id in [alice, bob] {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates([id.secCertificate] as CFArray, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
            let t = try XCTUnwrap(trust)
            SecTrustSetAnchorCertificates(t, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(t, true)
            SecTrustSetNetworkFetchAllowed(t, false)
            var error: CFError?
            XCTAssertTrue(SecTrustEvaluateWithError(t, &error), "\(id.certificate.commonName ?? "?"): \(String(describing: error))")
        }
        // And not to anything else: without the CA anchor the leaf is not trusted.
        var bare: SecTrust?
        SecTrustCreateWithCertificates([alice.secCertificate] as CFArray, SecPolicyCreateBasicX509(), &bare)
        SecTrustSetAnchorCertificates(bare!, [] as CFArray)
        SecTrustSetAnchorCertificatesOnly(bare!, true)
        SecTrustSetNetworkFetchAllowed(bare!, false)
        XCTAssertFalse(SecTrustEvaluateWithError(bare!, nil))
    }

    // MARK: - S/MIME: the message files

    /// Header block and body of an RFC 5322 message (CRLF).
    static func split(_ raw: Data) -> (headers: [String: String], body: Data) {
        let bytes = [UInt8](raw)
        let sep: [UInt8] = [13, 10, 13, 10]
        let at = bytes.indices.first { bytes[$0..<min($0 + 4, bytes.count)].elementsEqual(sep) } ?? bytes.count
        let head = String(decoding: bytes[..<at], as: UTF8.self)
        var headers: [String: String] = [:]
        var last: String?
        for line in head.components(separatedBy: "\r\n") {
            if line.first == " " || line.first == "\t", let k = last { headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].lowercased()
            headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            last = k
        }
        return (headers, Data(bytes[min(at + 4, bytes.count)...]))
    }

    static func parameter(_ name: String, in value: String) -> String? {
        for piece in value.components(separatedBy: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == name { return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }

    /// application/pkcs7-mime → the DER CMS.
    static func pkcs7MIME(_ raw: Data) throws -> Data {
        let (h, body) = split(raw)
        let type = try XCTUnwrap(h["content-type"])
        XCTAssertTrue(type.lowercased().hasPrefix("application/pkcs7-mime") || type.lowercased().hasPrefix("application/x-pkcs7-mime"), type)
        return try XCTUnwrap(Data(base64Encoded: body, options: .ignoreUnknownCharacters))
    }

    /// multipart/signed → (the signed entity, byte for byte; the DER signature).
    static func multipartSigned(_ raw: Data) throws -> (entity: Data, signature: Data) {
        let (h, body) = split(raw)
        let type = try XCTUnwrap(h["content-type"])
        XCTAssertTrue(type.lowercased().hasPrefix("multipart/signed"), type)
        let boundary = try XCTUnwrap(parameter("boundary", in: type))
        let b = [UInt8](body), open = [UInt8]("--\(boundary)\r\n".utf8), delimiter = [UInt8]("\r\n--\(boundary)".utf8)
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard b.count >= needle.count else { return nil }
            return (from...(b.count - needle.count)).first { b[$0..<$0 + needle.count].elementsEqual(needle) }
        }
        let start = try XCTUnwrap(find(open, from: 0)) + open.count
        let end = try XCTUnwrap(find(delimiter, from: start))
        let entity = Data(b[start..<end])
        let sigStart = end + delimiter.count + 2   // past CRLF
        let sigEnd = try XCTUnwrap(find(delimiter, from: sigStart))
        let sigPart = Data(b[sigStart..<sigEnd])
        let (sh, sigBody) = split(sigPart)
        XCTAssertTrue((sh["content-type"] ?? "").lowercased().contains("pkcs7-signature"), sh["content-type"] ?? "")
        return (entity, try XCTUnwrap(Data(base64Encoded: sigBody, options: .ignoreUnknownCharacters)))
    }

    /// The opened entity carries the attachment `ledger.txt`, byte-identical.
    private func assertEntityCarriesTheLedger(_ entity: Data, _ label: String) throws {
        XCTAssertEqual(entity, try data("owner-pack/smime/entity.mime"), label)
        let ledger = try data("owner-pack/smime/ledger.txt")
        let parsed = MIMEParser.parseEmail(rawEmail: String(decoding: entity, as: UTF8.self))
        let names = parsed.parts.flatMap { Self.leaves($0) }.compactMap { $0.filename }
        XCTAssertEqual(names, ["ledger.txt"], label)
        let text = String(decoding: entity, as: UTF8.self)
        let b64 = text.components(separatedBy: "filename=\"ledger.txt\"\r\n\r\n")[1].components(separatedBy: "--R9-MIX--")[0]
        XCTAssertEqual(Self.sha256(try XCTUnwrap(Data(base64Encoded: b64, options: .ignoreUnknownCharacters))), Self.sha256(ledger), label)
        XCTAssertTrue(text.contains("The periwinkle ledger is sealed."), label)
    }

    static func leaves(_ part: MIMEPart) -> [MIMEPart] {
        part.subparts.isEmpty ? [part] : part.subparts.flatMap { leaves($0) }
    }

    func testR9_smime_signedOpaque_RSAandECDSA_verifyAndYieldTheEntity() throws {
        let alice = try identity("alice"), bob = try identity("bob")
        for (file, signer, digest) in [("signed-opaque-rsa.eml", alice, "SHA256"), ("signed-opaque-ec.eml", bob, "SHA256")] {
            let raw = try data("owner-pack/smime/\(file)")
            XCTAssertTrue(Self.split(raw).headers["message-id"]?.hasPrefix("<r9-smime-") == true, file)
            let cms = try Self.pkcs7MIME(raw)
            let verdicts = try CMSSignedData.verify(cms)
            XCTAssertEqual(verdicts.map(\.outcome), [.valid], file)
            XCTAssertEqual(verdicts.first?.signer, signer.certificate, file)
            XCTAssertNotNil(verdicts.first?.signingTime, file)
            XCTAssertEqual(verdicts.first?.digestAlgorithm?.uppercased().replacingOccurrences(of: "-", with: ""), digest, file)
            XCTAssertTrue(verdicts.first?.certificates.contains { $0.commonName == "mailin R9 Test CA" } == true, "CA certificate carried: \(file)")
            let content = try CMSPortable.content(of: cms) { _, _ in nil }
            try assertEntityCarriesTheLedger(content, file)
        }
        // The DER copy, too.
        let der = try data("owner-pack/smime/signed-opaque-rsa.p7m")
        XCTAssertEqual(try CMSSignedData.verify(der).map(\.outcome), [.valid])
        try assertEntityCarriesTheLedger(try XCTUnwrap(try CMSSignedData.content(der)), "p7m")
    }

    func testR9_smime_detachedSignature_verifies_tamperedTextAndSignatureFail() throws {
        let alice = try identity("alice")
        let (entity, signature) = try Self.multipartSigned(try data("owner-pack/smime/signed-detached-rsa.eml"))
        try assertEntityCarriesTheLedger(entity, "detached")
        let good = try CMSSignedData.verify(signature, detachedContent: entity)
        XCTAssertEqual(good.map(\.outcome), [.valid])
        XCTAssertEqual(good.first?.signer, alice.certificate)
        XCTAssertEqual(try CMSSignedData.verify(signature).map(\.outcome), [.contentMissing], "no content, no verdict of valid")

        // The tampered message on disk: text changed after signing.
        let (altered, sameSignature) = try Self.multipartSigned(try data("owner-pack/smime/signed-detached-tampered.eml"))
        XCTAssertNotEqual(altered, entity)
        XCTAssertTrue(String(decoding: altered, as: UTF8.self).contains("periwinkle LEDGER"))
        XCTAssertEqual(sameSignature, signature, "only the text was changed")
        XCTAssertEqual(try CMSSignedData.verify(sameSignature, detachedContent: altered).map(\.outcome), [.contentAltered])

        // One flipped byte in the signature value itself: a bad signature, not "altered".
        var sig = [UInt8](signature)
        sig[sig.count - 5] ^= 0x01
        XCTAssertEqual(try CMSSignedData.verify(Data(sig), detachedContent: entity).map(\.outcome), [.badSignature])
    }

    func testR9_smime_envelopedRSAandEC_openWithTheP12Key_otherIdentityAndTamperFail() throws {
        let alice = try identity("alice"), bob = try identity("bob")
        let rows: [(String, Identity, Identity, String, Bool)] = [
            ("enveloped-rsa.eml", alice, bob, "AES-256-CBC", true),
            ("enveloped-ec.eml", bob, alice, "AES-256-CBC", true),
            ("enveloped-rsa.p7m", alice, bob, "AES-256-CBC", false),
            ("enveloped-ec-gcm.p7m", bob, alice, "AES-128-GCM", false),
        ]
        for (file, recipient, other, algorithm, isMIME) in rows {
            let raw = try data("owner-pack/smime/\(file)")
            let cms = isMIME ? try Self.pkcs7MIME(raw) : raw
            let summary = try CMSEnvelope.summary(cms)
            XCTAssertEqual(summary.recipients.count, 1, file)
            XCTAssertTrue(summary.recipients.allSatisfy { $0.matches(recipient.certificate) }, file)
            let opened = try CMSEnvelope.decrypt(cms, keyOperation: recipient.operation)
            XCTAssertEqual(opened.contentAlgorithm, algorithm, file)
            XCTAssertEqual(opened.authenticated, algorithm.hasSuffix("GCM"), file)
            try assertEntityCarriesTheLedger(opened.content, file)
            XCTAssertEqual(try CMSPortable.content(of: cms, keyOperation: recipient.operation), opened.content, file)
            // The other identity is not a recipient: nothing is attempted, the recipient is named.
            XCTAssertThrowsError(try CMSEnvelope.decrypt(cms, keyOperation: other.operation), file) { error in
                guard case CMSError.noMatchingKey(let named) = error else { return XCTFail("\(file): \(error)") }
                XCTAssertTrue(named.allSatisfy { $0.matches(recipient.certificate) }, file)
            }
            // The other identity's key under the recipient's certificate: the key operation fails.
            let liar = CMSSecKeyOperation.operation(privateKey: other.privateKey, certificate: recipient.certificate)
            XCTAssertThrowsError(try CMSEnvelope.decrypt(cms, keyOperation: liar), file) { error in
                guard case CMSError.decryptionFailed = error else { return XCTFail("\(file): \(error)") }
            }
        }
        // AuthEnvelopedData with one byte of cipher text flipped: the tag catches it.
        var gcm = [UInt8](try data("owner-pack/smime/enveloped-ec-gcm.p7m"))
        let ct = try CMSEnvelope.Parsed(Data(gcm)).encryptedContent
        let at = try XCTUnwrap(gcm.indices.first { Array(gcm[$0..<min($0 + ct.count, gcm.count)]) == ct })
        gcm[at + 3] ^= 0x01
        XCTAssertThrowsError(try CMSEnvelope.decrypt(Data(gcm), keyOperation: bob.operation)) { XCTAssertEqual($0 as? CMSError, .authenticationFailed) }
    }

    func testR9_smime_signedThenEnveloped_opensForEitherRecipient_innerSignatureVerifies() throws {
        let alice = try identity("alice"), bob = try identity("bob")
        let cms = try Self.pkcs7MIME(try data("owner-pack/smime/signed-then-enveloped.eml"))
        let summary = try CMSEnvelope.summary(cms)
        XCTAssertEqual(summary.recipients.count, 2)
        XCTAssertTrue(summary.authenticated, "AES-256-GCM AuthEnvelopedData")
        var inner: Data?
        for who in [alice, bob] {
            let opened = try CMSEnvelope.decrypt(cms, keyOperation: who.operation)
            XCTAssertEqual(opened.contentAlgorithm, "AES-256-GCM")
            XCTAssertTrue(opened.recipient.matches(who.certificate))
            if let inner { XCTAssertEqual(opened.content, inner, "both recipients read the same bytes") }
            inner = opened.content
        }
        // The decrypted entity is the multipart/signed message by Alice.
        let (entity, signature) = try Self.multipartSigned(try XCTUnwrap(inner))
        let verdict = try CMSSignedData.verify(signature, detachedContent: entity)
        XCTAssertEqual(verdict.map(\.outcome), [.valid])
        XCTAssertEqual(verdict.first?.signer, alice.certificate)
        try assertEntityCarriesTheLedger(entity, "signed-then-enveloped")
        // And it is exactly the detached-signed message's signed entity and signature.
        let detached = try Self.multipartSigned(try data("owner-pack/smime/signed-detached-rsa.eml"))
        XCTAssertEqual(entity, detached.entity)
        XCTAssertEqual(signature, detached.signature)
    }

    // MARK: - Native: Apple-Mail-written mbox + the same messages as .eml

    struct InventoryAttachment: Decodable { let name: String; let mime: String; let bytes: Int; let sha256: String }
    struct InventoryMessage: Decodable { let messageID: String; let subject: String; let date: String; let attachments: [InventoryAttachment] }

    struct Imported: Equatable, CustomStringConvertible {
        let messageID: String; let subject: String; let attachments: [String]   // "name sha256", sorted
        var description: String { "\(messageID) | \(subject) | \(attachments)" }
    }

    private func importAll(_ url: URL) async throws -> [Imported] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("r9-native-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let store = SQLiteEmailStore(directory: work.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: work.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        _ = try await coordinator.runImport(urls: [url], options: options)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var out: [Imported] = []
        var cursor: EmailPageCursor?
        repeat {
            let page = try await archive.page(query: .all, cursor: cursor, limit: 100)
            let raws = try await store.emails(withIDs: page.summaries.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: raws.map { ($0.id, $0) })
            for s in page.summaries {
                let raw = try XCTUnwrap(byID[s.id])
                // The store keeps attachment metadata; the bytes are the stored raw MIME, decoded by
                // the production extractor. Names must agree between the two.
                XCTAssertFalse(raw.rawSource.isEmpty, "raw MIME kept for \(s.messageID ?? "?")")
                let decoded = try EmailBodyExtractor.extractContents(from: raw.rawSource).attachments
                XCTAssertEqual(decoded.map(\.filename).sorted(), raw.attachments.map(\.filename).sorted(), "stored names = decoded names")
                let atts = decoded.map { "\($0.filename) \(RealMailStoreFixtureTests.attachmentDigest($0) ?? "no-bytes")" }.sorted()
                out.append(Imported(messageID: (s.messageID ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), subject: s.subject, attachments: atts))
            }
            cursor = page.nextCursor
        } while cursor != nil
        return out.sorted { $0.messageID < $1.messageID }
    }

    func testR9_native_appleMailMBOXandDerivedEML_sameMessages_mailinImportsBothIdentically() async throws {
        let mboxPackage = try url("owner-pack/native/apple-mail-export/R9-native.mbox/mbox").deletingLastPathComponent()
        _ = try url("owner-pack/native/apple-mail-export/R9-native.mbox/table_of_contents")
        var emlFiles: [URL] = []
        for n in 1...6 { emlFiles.append(try url(String(format: "owner-pack/native/eml/r9-native-%02d.eml", n))) }
        let inventory = try JSONDecoder().decode([InventoryMessage].self, from: try data("owner-pack/native/source/source-inventory.json"))
        XCTAssertEqual(inventory.count, 6)

        // The mbox is Apple Mail's (its envelope lines carry Mail's own re-written dates).
        let mboxText = String(decoding: try data("owner-pack/native/apple-mail-export/R9-native.mbox/mbox"), as: UTF8.self)
        XCTAssertEqual(mboxText.components(separatedBy: "\n").filter { $0.hasPrefix("From ") }.count, 6, "six mbox records")

        let expected = inventory.map { m in
            Imported(messageID: m.messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), subject: m.subject,
                     attachments: m.attachments.map { "\($0.name) \($0.sha256)" }.sorted())
        }.sorted { $0.messageID < $1.messageID }

        let fromMBOX = try await importAll(mboxPackage)
        let emlDir = emlFiles[0].deletingLastPathComponent()
        let fromEML = try await importAll(emlDir)
        XCTAssertEqual(fromMBOX.count, 6, "\(fromMBOX)")
        XCTAssertEqual(fromEML.count, 6, "\(fromEML)")
        XCTAssertEqual(fromMBOX, expected, "Apple Mail mbox vs the source inventory")
        XCTAssertEqual(fromEML, expected, ".eml set vs the source inventory")
        XCTAssertEqual(fromMBOX, fromEML, "mailin reads the mbox and the .eml set as the same messages")
        XCTAssertEqual(fromMBOX.flatMap(\.attachments).count, 4, "four attachments: pdf, png, csv, UTF-8-named txt")
    }
}
