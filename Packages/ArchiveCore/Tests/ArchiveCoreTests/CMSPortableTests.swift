//
//  CMSPortableTests.swift
//  ArchiveCoreTests
//
//  R6 (S/MIME on iPhone and iPad): the portable CMS reader, against
//  throwaway identities made in the test — RSA keys from the Security
//  framework, EC keys from CryptoKit and the Security framework, self-signed
//  certificates written by CMSBuilder. Nothing is stored in a keychain.
//  Round trips in pure Swift always run; the OpenSSL interop rows run when an
//  `openssl` with `cms` is on the Mac (Homebrew's), and are skipped otherwise.
//

import XCTest
import CryptoKit
import Security
@testable import ArchiveCore

final class CMSPortableTests: XCTestCase {

    // MARK: Throwaway identities

    struct Identity {
        let privateKey: SecKey
        let certificate: X509Certificate
        let privateKeyPEM: String
        var operation: CMSPrivateKeyOperation { CMSSecKeyOperation.operation(privateKey: privateKey, certificate: certificate) }
        var certificatePEM: String { Self.pem("CERTIFICATE", certificate.der) }
        static func pem(_ label: String, _ der: [UInt8]) -> String {
            "-----BEGIN \(label)-----\n" + Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END \(label)-----\n"
        }
    }

    static func rsaIdentity(_ cn: String = "R6 RSA test", ski: [UInt8]? = Array(repeating: 0x5A, count: 20)) throws -> Identity {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let pub = SecKeyCopyPublicKey(key) else {
            throw XCTSkip("RSA key generation unavailable: \(String(describing: error?.takeRetainedValue()))")
        }
        let der = try CMSBuilder.selfSignedCertificate(commonName: cn, email: "r6-rsa@example.invalid",
                                                       subjectPublicKeyInfo: try CMSBuilder.subjectPublicKeyInfo(pub),
                                                       serial: CMSBuilder.random(9), subjectKeyIdentifier: ski, ec: false) { tbs in
            [UInt8](SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, nil)! as Data)
        }
        let pkcs1 = SecKeyCopyExternalRepresentation(key, nil)! as Data
        return Identity(privateKey: key, certificate: try X509Certificate(der: der), privateKeyPEM: Identity.pem("RSA PRIVATE KEY", [UInt8](pkcs1)))
    }

    /// An EC P-256 identity whose private key is a Security-framework key made from a CryptoKit key (so OpenSSL can have its PEM).
    static func ecIdentity(_ cn: String = "R6 EC test") throws -> Identity {
        let ka = P256.KeyAgreement.PrivateKey()
        let signer = try P256.Signing.PrivateKey(rawRepresentation: ka.rawRepresentation)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256]
        guard let key = SecKeyCreateWithData(ka.x963Representation as CFData, attributes as CFDictionary, nil) else { throw XCTSkip("EC key import unavailable") }
        let der = try CMSBuilder.selfSignedCertificate(commonName: cn, email: "r6-ec@example.invalid",
                                                       subjectPublicKeyInfo: try CMSBuilder.ecSubjectPublicKeyInfo(point: [UInt8](ka.publicKey.x963Representation)),
                                                       serial: [0x01, 0x23, 0x45], subjectKeyIdentifier: Array(repeating: 0xEC, count: 20), ec: true) { tbs in
            [UInt8](try signer.signature(for: Data(tbs)).derRepresentation)
        }
        return Identity(privateKey: key, certificate: try X509Certificate(der: der), privateKeyPEM: ka.pemRepresentation)
    }

    let message = Data("Content-Type: text/plain\r\n\r\nThe periwinkle ledger is sealed.\r\n".utf8)

    // MARK: Certificates

    func testR6_selfSignedCertificate_parsesAndIsAcceptedBySecurity() throws {
        let id = try Self.rsaIdentity()
        XCTAssertEqual(id.certificate.commonName, "R6 RSA test")
        XCTAssertEqual(id.certificate.issuerDER, id.certificate.subjectDER)
        XCTAssertEqual(id.certificate.subjectKeyIdentifier, Array(repeating: 0x5A, count: 20))
        XCTAssertEqual(id.certificate.emailAddresses, ["r6-rsa@example.invalid"])
        XCTAssertNotNil(id.certificate.publicKey(), "Security reads the certificate's key")
        XCTAssertTrue(id.certificate.issuerAndSerial.matches(id.certificate))
        XCTAssertTrue(CMSRecipientIdentifier.subjectKeyIdentifier(Array(repeating: 0x5A, count: 20)).matches(id.certificate))
        XCTAssertFalse(CMSRecipientIdentifier.subjectKeyIdentifier([1, 2, 3]).matches(id.certificate))
    }

    // MARK: Envelopes, pure Swift

    func testR6_rsaEnvelopes_everyCipherAndPadding_decryptThroughTheKeyOperation() throws {
        let id = try Self.rsaIdentity()
        let pub = SecKeyCopyPublicKey(id.privateKey)!
        let cases: [(CMSBuilder.Cipher, CMSHash?, CMSRecipientIdentifier, String)] = [
            (.aesCBC(bits: 256), nil, id.certificate.issuerAndSerial, "AES-256-CBC"),
            (.aesCBC(bits: 128), .sha256, id.certificate.issuerAndSerial, "AES-128-CBC"),
            (.aesCBC(bits: 192), .sha1, .subjectKeyIdentifier(id.certificate.subjectKeyIdentifier!), "AES-192-CBC"),
            (.des3CBC, .sha512, id.certificate.issuerAndSerial, "3DES-CBC"),
            (.aesGCM(bits: 256), nil, id.certificate.issuerAndSerial, "AES-256-GCM"),
            (.aesGCM(bits: 128), .sha384, .subjectKeyIdentifier(id.certificate.subjectKeyIdentifier!), "AES-128-GCM"),
        ]
        for (cipher, oaep, rid, name) in cases {
            let env = try CMSBuilder.envelope(message, to: [.rsa(rid, publicKey: pub, oaep: oaep)], cipher: cipher)
            let opened = try CMSEnvelope.decrypt(env, keyOperation: id.operation)
            XCTAssertEqual(opened.content, message, name)
            XCTAssertEqual(opened.contentAlgorithm, name)
            XCTAssertEqual(opened.recipient, rid)
            XCTAssertEqual(opened.authenticated, name.hasSuffix("GCM"))
            XCTAssertEqual(try CMSPortable.content(of: env, keyOperation: id.operation), message)
        }
    }

    func testR6_ecdhEnvelopes_P256P384P521_SecKeyAndCryptoKit_decrypt() throws {
        // Security-framework key (what a keychain identity gives the app).
        let id = try Self.ecIdentity()
        let point = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(id.privateKey)!, nil)! as Data
        for kdf in CMSHash.allCases {
            for cipher in [CMSBuilder.Cipher.aesCBC(bits: 128), .aesCBC(bits: 256), .aesGCM(bits: 256)] {
                let env = try CMSBuilder.envelope(message, to: [.ecdh(id.certificate.issuerAndSerial, publicKey: point, kdf: kdf)], cipher: cipher)
                XCTAssertEqual(try CMSEnvelope.decrypt(env, keyOperation: id.operation).content, message, "\(kdf) \(cipher)")
            }
        }
        // P-384 and P-521 through CryptoKit, recipient named by subject key identifier.
        let p384 = P384.KeyAgreement.PrivateKey(), p521 = P521.KeyAgreement.PrivateKey()
        let ski: CMSRecipientIdentifier = .subjectKeyIdentifier([9, 9, 9])
        for (pub, agree) in [(p384.publicKey.x963Representation, { (e: Data) in try p384.sharedSecretFromKeyAgreement(with: .init(x963Representation: e)) }),
                             (p521.publicKey.x963Representation, { (e: Data) in try p521.sharedSecretFromKeyAgreement(with: .init(x963Representation: e)) })] {
            let env = try CMSBuilder.envelope(message, to: [.ecdh(ski, publicKey: pub, kdf: .sha384)], cipher: .aesGCM(bits: 256))
            let opened = try CMSEnvelope.decrypt(env) { rid, request in
                guard rid == ski, case .ecdh(_, let e) = request else { return nil }
                return try agree(e).withUnsafeBytes { Data($0) }
            }
            XCTAssertEqual(opened.content, message)
        }
    }

    func testR6_wrongKey_noKey_tamperedTag_areLockedWithAReason() throws {
        let id = try Self.rsaIdentity(), other = try Self.rsaIdentity("someone else")
        let pub = SecKeyCopyPublicKey(id.privateKey)!
        let env = try CMSBuilder.envelope(message, to: [.rsa(id.certificate.issuerAndSerial, publicKey: pub, oaep: nil)])

        // No identity names the recipient: nothing is attempted, the recipients are named.
        XCTAssertThrowsError(try CMSEnvelope.decrypt(env, keyOperation: other.operation)) { error in
            guard case CMSError.noMatchingKey(let recipients) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(recipients, [id.certificate.issuerAndSerial])
            XCTAssertTrue("\(error)".contains("R6 RSA test"), "\(error)")
        }
        // A key that claims the recipient but is the wrong key: the key operation fails, said so.
        let liar = CMSSecKeyOperation.operation(privateKey: other.privateKey, certificate: id.certificate)
        XCTAssertThrowsError(try CMSEnvelope.decrypt(env, keyOperation: liar)) { error in
            guard case CMSError.decryptionFailed = error else { return XCTFail("\(error)") }
        }
        // EC wrong key: the AES key wrap does not open.
        let ec = try Self.ecIdentity(), ecOther = try Self.ecIdentity("other")
        let point = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(ec.privateKey)!, nil)! as Data
        let ecEnv = try CMSBuilder.envelope(message, to: [.ecdh(ec.certificate.issuerAndSerial, publicKey: point, kdf: .sha256)])
        XCTAssertThrowsError(try CMSEnvelope.decrypt(ecEnv, keyOperation: CMSSecKeyOperation.operation(privateKey: ecOther.privateKey, certificate: ec.certificate))) { error in
            guard case CMSError.decryptionFailed(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("key wrap"), why)
        }
        // AuthEnvelopedData with one byte of cipher text flipped: the tag catches it.
        var gcm = [UInt8](try CMSBuilder.envelope(message, to: [.rsa(id.certificate.issuerAndSerial, publicKey: pub, oaep: nil)], cipher: .aesGCM(bits: 256)))
        let parsed = try CMSEnvelope.Parsed(Data(gcm))
        let ct = parsed.encryptedContent
        let at = try XCTUnwrap(gcm.indices.first { Array(gcm[$0..<min($0 + ct.count, gcm.count)]) == ct })
        gcm[at] ^= 0x01
        XCTAssertThrowsError(try CMSEnvelope.decrypt(Data(gcm), keyOperation: id.operation)) { XCTAssertEqual($0 as? CMSError, .authenticationFailed) }
        // Not CMS, and CMS of another kind.
        XCTAssertThrowsError(try CMSEnvelope.decrypt(Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09]), keyOperation: id.operation)) { error in
            guard case CMSError.malformed = error else { return XCTFail("\(error)") }
        }
        let signed = try CMSBuilder.signed(message, detached: false, certificate: id.certificate, signatureAlgorithmOID: CMSOID.sha256WithRSA) {
            [UInt8](SecKeyCreateSignature(id.privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data($0) as CFData, nil)! as Data)
        }
        XCTAssertThrowsError(try CMSEnvelope.decrypt(signed, keyOperation: id.operation)) { XCTAssertEqual($0 as? CMSError, .unexpectedContentType(CMSOID.signedData)) }
        XCTAssertEqual(try CMSPortable.content(of: signed, keyOperation: id.operation), message, "signed data yields its content")
    }

    func testR6_hostileLengthsAndNesting_areMalformedNotACrash() {
        let cases: [[UInt8]] = [
            [], [0x30], [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF], [0x30, 0x80, 0x30, 0x80],
            Array(repeating: 0x30, count: 200) + Array(repeating: 0x80, count: 1),
            Array(repeating: [0x30, 0x80], count: 100).flatMap { $0 },
        ]
        for bytes in cases {
            XCTAssertThrowsError(try CMSEnvelope.decrypt(Data(bytes)) { _, _ in nil })
            XCTAssertThrowsError(try CMSSignedData.verify(Data(bytes)))
        }
    }

    // MARK: Signatures, pure Swift

    func testR6_signedData_opaqueAndDetached_RSAandECDSA_verify_tamperIsCaught() throws {
        let rsa = try Self.rsaIdentity(), ec = try Self.ecIdentity()
        let signers: [(Identity, String, SecKeyAlgorithm, CMSHash)] = [
            (rsa, CMSOID.sha256WithRSA, .rsaSignatureMessagePKCS1v15SHA256, .sha256),
            (rsa, CMSOID.rsaEncryption, .rsaSignatureMessagePKCS1v15SHA512, .sha512),
            (ec, CMSOID.ecdsaSHA256, .ecdsaSignatureMessageX962SHA256, .sha256),
            (ec, CMSOID.ecdsaSHA384, .ecdsaSignatureMessageX962SHA384, .sha384),
        ]
        for (id, sigOID, alg, hash) in signers {
            for detached in [false, true] {
                for bySKI in [false, true] {
                    let sig = try CMSBuilder.signed(message, detached: detached, certificate: id.certificate, bySubjectKeyIdentifier: bySKI,
                                                    hash: hash, signatureAlgorithmOID: sigOID) {
                        [UInt8](SecKeyCreateSignature(id.privateKey, alg, Data($0) as CFData, nil)! as Data)
                    }
                    let label = "\(sigOID) detached=\(detached) ski=\(bySKI)"
                    let good = try CMSSignedData.verify(sig, detachedContent: detached ? message : nil)
                    XCTAssertEqual(good.map(\.outcome), [.valid], label)
                    XCTAssertEqual(good.first?.signer, id.certificate, label)
                    XCTAssertNotNil(good.first?.signingTime, label)
                    var altered = message; altered[altered.count - 3] ^= 0x20
                    if detached {
                        XCTAssertEqual(try CMSSignedData.verify(sig, detachedContent: altered).map(\.outcome), [.contentAltered], label)
                        XCTAssertEqual(try CMSSignedData.verify(sig).map(\.outcome), [.contentMissing], label)
                    } else {
                        var bytes = [UInt8](sig)
                        let at = try XCTUnwrap(bytes.indices.first { Array(bytes[$0..<min($0 + message.count, bytes.count)]) == [UInt8](message) })
                        bytes[at + message.count - 3] ^= 0x20
                        XCTAssertEqual(try CMSSignedData.verify(Data(bytes)).map(\.outcome), [.contentAltered], label)
                    }
                }
            }
        }
        // A signature by another key over the same attributes is bad, not "altered".
        let other = try Self.rsaIdentity("impostor")
        let forged = try CMSBuilder.signed(message, detached: false, certificate: rsa.certificate, signatureAlgorithmOID: CMSOID.sha256WithRSA) {
            [UInt8](SecKeyCreateSignature(other.privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data($0) as CFData, nil)! as Data)
        }
        XCTAssertEqual(try CMSSignedData.verify(forged).map(\.outcome), [.badSignature])
        XCTAssertThrowsError(try CMSSignedData.verify(try CMSBuilder.envelope(message, to: [])))
    }

    // MARK: OpenSSL interop (skipped without an openssl that has `cms`)

    static func openssl() -> String? {
        for path in ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["cms", "-help"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return path }
        }
        return nil
    }

    @discardableResult
    func run(_ tool: String, _ args: [String], in dir: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        let err = Pipe()
        p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("openssl \(args.joined(separator: " ")) → \(p.terminationStatus): \(text)")
        }
        return p.terminationStatus
    }

    func workDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cms-r6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testR6_openSSLEnvelopes_RSAandECDH_everyCipher_BERStreaming_decryptHere() throws {
        guard let openssl = Self.openssl() else { throw XCTSkip("no openssl with cms on this Mac") }
        let dir = try workDir()
        let rsa = try Self.rsaIdentity(), ec = try Self.ecIdentity()
        try message.write(to: dir.appendingPathComponent("m.txt"))
        try rsa.certificatePEM.write(to: dir.appendingPathComponent("rsa.pem"), atomically: true, encoding: .utf8)
        try ec.certificatePEM.write(to: dir.appendingPathComponent("ec.pem"), atomically: true, encoding: .utf8)
        let rows: [(String, [String], Identity)] = [
            ("rsa-aes256", ["-aes256"], rsa),
            ("rsa-aes128-oaep256", ["-aes128", "-keyopt", "rsa_padding_mode:oaep", "-keyopt", "rsa_oaep_md:sha256"], rsa),
            ("rsa-oaep-sha1", ["-aes192", "-keyopt", "rsa_padding_mode:oaep"], rsa),
            ("rsa-des3", ["-des3"], rsa),
            ("rsa-gcm", ["-aes-256-gcm"], rsa),
            ("rsa-keyid", ["-aes256", "-keyid"], rsa),
            ("rsa-stream-ber", ["-aes256", "-stream"], rsa),
            ("ec-default", ["-aes256"], ec),
            ("ec-sha256kdf", ["-aes128", "-keyopt", "ecdh_kdf_md:sha256"], ec),
            ("ec-sha384kdf-gcm", ["-aes-256-gcm", "-keyopt", "ecdh_kdf_md:sha384"], ec),
            ("ec-keyid", ["-aes256", "-keyid"], ec),
        ]
        for (name, options, id) in rows {
            let cert = id.certificate == rsa.certificate ? "rsa.pem" : "ec.pem"
            // -keyopt applies to the -recip before it.
            let cipherFlags = options.prefix { $0 != "-keyopt" }, keyopts = options.drop { $0 != "-keyopt" }
            try run(openssl, ["cms", "-encrypt", "-binary", "-in", "m.txt", "-outform", "DER", "-out", "\(name).der"] + cipherFlags + ["-recip", cert] + keyopts, in: dir)
            let env = try Data(contentsOf: dir.appendingPathComponent("\(name).der"))
            if name.hasSuffix("ber") { XCTAssertTrue(env.prefix(2) == Data([0x30, 0x80]), "streaming output is BER indefinite length") }
            do {
                let opened = try CMSEnvelope.decrypt(env, keyOperation: id.operation)
                XCTAssertEqual(opened.content, message, name)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
    }

    func testR6_envelopesWrittenHere_openInOpenSSL() throws {
        guard let openssl = Self.openssl() else { throw XCTSkip("no openssl with cms on this Mac") }
        let dir = try workDir()
        let rsa = try Self.rsaIdentity(), ec = try Self.ecIdentity()
        try rsa.certificatePEM.write(to: dir.appendingPathComponent("rsa.pem"), atomically: true, encoding: .utf8)
        try rsa.privateKeyPEM.write(to: dir.appendingPathComponent("rsa.key"), atomically: true, encoding: .utf8)
        try ec.certificatePEM.write(to: dir.appendingPathComponent("ec.pem"), atomically: true, encoding: .utf8)
        try ec.privateKeyPEM.write(to: dir.appendingPathComponent("ec.key"), atomically: true, encoding: .utf8)
        let rsaPub = SecKeyCopyPublicKey(rsa.privateKey)!
        let ecPoint = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(ec.privateKey)!, nil)! as Data
        let rows: [(String, CMSBuilder.Recipient, CMSBuilder.Cipher, String)] = [
            ("h-rsa", .rsa(rsa.certificate.issuerAndSerial, publicKey: rsaPub, oaep: nil), .aesCBC(bits: 256), "rsa"),
            ("h-oaep", .rsa(rsa.certificate.issuerAndSerial, publicKey: rsaPub, oaep: .sha256), .des3CBC, "rsa"),
            ("h-gcm", .rsa(rsa.certificate.issuerAndSerial, publicKey: rsaPub, oaep: nil), .aesGCM(bits: 128), "rsa"),
            ("h-ec", .ecdh(ec.certificate.issuerAndSerial, publicKey: ecPoint, kdf: .sha1), .aesCBC(bits: 128), "ec"),
            ("h-ec256", .ecdh(ec.certificate.issuerAndSerial, publicKey: ecPoint, kdf: .sha256), .aesGCM(bits: 256), "ec"),
        ]
        for (name, recipient, cipher, who) in rows {
            try CMSBuilder.envelope(message, to: [recipient], cipher: cipher).write(to: dir.appendingPathComponent("\(name).der"))
            try run(openssl, ["cms", "-decrypt", "-binary", "-inform", "DER", "-in", "\(name).der", "-recip", "\(who).pem", "-inkey", "\(who).key", "-out", "\(name).out"], in: dir)
            XCTAssertEqual(try? Data(contentsOf: dir.appendingPathComponent("\(name).out")), message, name)
        }
    }

    func testR6_openSSLSignatures_verifyHere_andOursVerifyInOpenSSL() throws {
        guard let openssl = Self.openssl() else { throw XCTSkip("no openssl with cms on this Mac") }
        let dir = try workDir()
        let rsa = try Self.rsaIdentity(), ec = try Self.ecIdentity()
        try message.write(to: dir.appendingPathComponent("m.txt"))
        for (who, id) in [("rsa", rsa), ("ec", ec)] {
            try id.certificatePEM.write(to: dir.appendingPathComponent("\(who).pem"), atomically: true, encoding: .utf8)
            try id.privateKeyPEM.write(to: dir.appendingPathComponent("\(who).key"), atomically: true, encoding: .utf8)
        }
        let rows: [(String, [String], String)] = [
            ("s-rsa", ["-nodetach"], "rsa"),
            ("s-rsa-384", ["-nodetach", "-md", "sha384"], "rsa"),
            ("s-rsa-pss", ["-nodetach", "-keyopt", "rsa_padding_mode:pss"], "rsa"),
            ("s-rsa-keyid", ["-nodetach", "-keyid"], "rsa"),
            ("s-ec", ["-nodetach"], "ec"),
            ("s-ec-detached", [], "ec"),
            ("s-rsa-stream", ["-nodetach", "-stream"], "rsa"),
        ]
        for (name, options, who) in rows {
            try run(openssl, ["cms", "-sign", "-binary", "-in", "m.txt", "-signer", "\(who).pem", "-inkey", "\(who).key", "-outform", "DER", "-out", "\(name).der"] + options, in: dir)
            let sig = try Data(contentsOf: dir.appendingPathComponent("\(name).der"))
            let detached = !options.contains("-nodetach")
            do {
                let verdict = try CMSSignedData.verify(sig, detachedContent: detached ? message : nil)
                XCTAssertEqual(verdict.map(\.outcome), [.valid], name)
                var altered = message; altered[5] ^= 0x01
                if detached { XCTAssertEqual(try CMSSignedData.verify(sig, detachedContent: altered).map(\.outcome), [.contentAltered], name) }
                if !detached { XCTAssertEqual(try CMSSignedData.content(sig), message, name) }
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        // Ours, checked by OpenSSL (signature only: the certificates are self-signed).
        for (who, id, oid, alg) in [("rsa", rsa, CMSOID.sha256WithRSA, SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256),
                                    ("ec", ec, CMSOID.ecdsaSHA256, SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256)] {
            try CMSBuilder.signed(message, detached: false, certificate: id.certificate, signatureAlgorithmOID: oid) {
                [UInt8](SecKeyCreateSignature(id.privateKey, alg, Data($0) as CFData, nil)! as Data)
            }.write(to: dir.appendingPathComponent("ours-\(who).der"))
            try run(openssl, ["cms", "-verify", "-binary", "-noverify", "-inform", "DER", "-in", "ours-\(who).der", "-out", "ours-\(who).out"], in: dir)
            XCTAssertEqual(try? Data(contentsOf: dir.appendingPathComponent("ours-\(who).out")), message, who)
        }
    }
}
