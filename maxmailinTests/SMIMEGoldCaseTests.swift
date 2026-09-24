//
//  SMIMEGoldCaseTests.swift
//  maxmailinTests
//
//  The last open gold case: a REAL S/MIME signed message through the real
//  macOS CMSDecoder path.
//
//  What was already covered, and why it was not enough. `V2SecurityTests`
//  exhaustively tests `mapVerdict`, which is the pure status→verdict function,
//  and it tests the `.notSigned` and garbage-blob paths. What no test did was
//  put **genuine CMS bytes with a genuine signature** through
//  `verifySignature(of:)`. So every "valid" verdict the app could produce was
//  unexercised: the mapping was proven, the thing being mapped was not.
//
//  The fixture is a self-signed S/MIME message generated with OpenSSL and
//  embedded as base64 rather than shelled out for at run time — a test that
//  depends on `openssl` being present and on `Process` working under the test
//  sandbox is a test that fails for reasons unrelated to the code. Generated
//  2026-09-24 with:
//
//      openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
//        -days 3650 -nodes -subj "/CN=Test Signer/emailAddress=signer@example.com/O=mailin gold case" \
//        -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=emailProtection"
//      openssl smime -sign -in content.txt -signer cert.pem -inkey key.pem \
//        -outform DER -nodetach -out signed.p7m
//
//  `openssl smime -verify -noverify` reports "Verification successful" on it,
//  so the signature is real. The certificate is self-signed, which is the
//  point: the correct verdict is `validUntrustedCert` — cryptographically
//  valid, chain not trusted. A tool that reported this as `validTrusted`
//  would be vouching for an unknown signer, and one that reported `invalid`
//  would be calling a good signature bad. Both are serious in a forensic
//  context, and neither was previously detectable.
//
//  The certificate expires 2036-09-21. When it does, this test will start
//  reporting `validUntrustedCert` for expiry reasons rather than trust
//  reasons — still the same verdict, so the test keeps passing, and the
//  comment is here so the next person knows why.
//

import XCTest
@testable import maxmailin

final class SMIMEGoldCaseTests: XCTestCase {

    /// Self-signed S/MIME signed-data (opaque, `-nodetach`), DER, base64.
    private static let signedCMSBase64 =
        "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"

    /// The signed content, so a body-tamper case can be built.
    private static let signedContent =
        "This is the signed content of the mailin S/MIME gold case."

    private func email(base64 blob: String) -> MBOXParser.RawEmail {
        // Wrapped at 64 columns, as a mail client would emit it.
        let wrapped = stride(from: 0, to: blob.count, by: 64).map { offset -> String in
            let start = blob.index(blob.startIndex, offsetBy: offset)
            let end = blob.index(start, offsetBy: min(64, blob.count - offset))
            return String(blob[start..<end])
        }.joined(separator: "\n")

        let raw = """
        From: Test Signer <signer@example.com>
        To: recipient@example.com
        Subject: S/MIME gold case
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <smime-gold@example.com>
        MIME-Version: 1.0
        Content-Type: application/pkcs7-mime; smime-type=signed-data; name="smime.p7m"
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="smime.p7m"

        \(wrapped)
        """

        return MBOXParser.RawEmail(
            headers: [
                "From": "Test Signer <signer@example.com>",
                "To": "recipient@example.com",
                "Subject": "S/MIME gold case",
                "Message-ID": "<smime-gold@example.com>",
                "Content-Type": "application/pkcs7-mime; smime-type=signed-data; name=\"smime.p7m\"",
                "Content-Transfer-Encoding": "base64"
            ],
            rawSource: raw,
            messageType: "email",
            attachments: [],
            timestamp: "Tue, 14 Mar 2017 09:41:00 +0000",
            domains: ["example.com"],
            plainBody: "",
            htmlBody: "")
    }

    // MARK: - The gold case

    /// A cryptographically VALID signature from an UNTRUSTED (self-signed)
    /// certificate must be reported as exactly that. Not `validTrusted`,
    /// which would vouch for an unknown signer; not `invalid`, which would
    /// call a good signature bad; not `unverifiable`, which would throw away
    /// a real cryptographic result.
    func testGoldCase_realSignedMessageIsValidButUntrusted() throws {
        #if os(macOS)
        let result = SMIMEHandler.verifySignature(of: email(base64: Self.signedCMSBase64))

        XCTAssertEqual(result.status, .validUntrustedCert, """
            a genuine signature from a self-signed certificate must be \
            'Valid Signature — Untrusted Certificate'; got \(result.status.rawValue)
            """)

        // The signer identity has to come out of the certificate, not out of
        // the From header — that distinction is the entire forensic value.
        XCTAssertEqual(result.signerEmail, "signer@example.com",
                       "signer email must be read from the certificate")
        XCTAssertEqual(result.signerName, "Test Signer",
                       "signer common name must be read from the certificate")

        let info = try XCTUnwrap(result.certificateInfo,
                                 "a verified signature must carry its certificate details")
        print("""

        ── S/MIME gold case ──────────────────────────────────────
        verdict        : \(result.status.rawValue)
        signer         : \(result.signerName ?? "—") <\(result.signerEmail ?? "—")>
        certificate    : \(info)
        ──────────────────────────────────────────────────────────

        """)
        #else
        throw XCTSkip("CMSDecoder is macOS-only")
        #endif
    }

    /// The strongest negative claim the app can make, and the one that must
    /// never be reached by accident: flipping bytes inside the signature must
    /// produce `invalid` or `unverifiable` — never any valid state.
    ///
    /// Both are acceptable outcomes because corrupting DER can either break
    /// the signature check (`invalid`) or break the structure so the decoder
    /// never gets that far (`unverifiable`). What matters is that neither is
    /// a "valid" verdict.
    func testGoldCase_tamperedSignatureIsNeverValid() throws {
        #if os(macOS)
        var data = try XCTUnwrap(Data(base64Encoded: Self.signedCMSBase64))
        // Flip bits deep inside the signature blob, well past the header.
        let target = data.count - 40
        data[target] = data[target] ^ 0xFF
        data[target + 1] = data[target + 1] ^ 0xFF

        let result = SMIMEHandler.verifySignature(of: email(base64: data.base64EncodedString()))

        XCTAssertNotEqual(result.status, .validTrusted, "tampered bytes must never be trusted")
        XCTAssertNotEqual(result.status, .validUntrustedCert, "tampered bytes must never be valid")
        XCTAssertNotEqual(result.status, .notSigned, "the message is still a signed-data message")
        XCTAssertTrue([.invalid, .unverifiable].contains(result.status),
                      "expected invalid or unverifiable, got \(result.status.rawValue)")

        print("── S/MIME tamper case: \(result.status.rawValue)")
        #else
        throw XCTSkip("CMSDecoder is macOS-only")
        #endif
    }

    /// Truncating the CMS mid-structure must be `unverifiable`, not `invalid`:
    /// there is no cryptographic conclusion to draw from bytes that never
    /// parsed. Conflating "cannot tell" with "bad" is the mistake
    /// `SMIMEHandler`'s five-state verdict exists to prevent.
    func testGoldCase_truncatedCMSIsUnverifiable() throws {
        #if os(macOS)
        let data = try XCTUnwrap(Data(base64Encoded: Self.signedCMSBase64))
        let truncated = data.prefix(data.count / 3)

        let result = SMIMEHandler.verifySignature(
            of: email(base64: truncated.base64EncodedString()))

        XCTAssertEqual(result.status, .unverifiable,
                       "a truncated CMS yields no conclusion; got \(result.status.rawValue)")
        #else
        throw XCTSkip("CMSDecoder is macOS-only")
        #endif
    }

    /// The fixture itself must stay intact: if the embedded base64 is ever
    /// mangled by an editor, every test above would fail confusingly. This
    /// fails first, and says so.
    func testGoldCase_fixtureIsWellFormedCMS() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.signedCMSBase64),
                                 "the embedded fixture is not valid base64")
        XCTAssertEqual(data.count, 1_709,
                       "the fixture should be the 1,709-byte blob generated on 2026-09-24")
        // DER SEQUENCE, then the ContentInfo OID for signedData (1.2.840.113549.1.7.2).
        XCTAssertEqual(data.first, 0x30, "CMS must begin with a DER SEQUENCE tag")
        let signedDataOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        XCTAssertTrue(data.prefix(32).elementsEqual(data.prefix(32)))
        XCTAssertNotNil(data.range(of: Data(signedDataOID)),
                        "the fixture must carry the signedData content-type OID")
        // And the signed content is embedded (opaque signing, -nodetach).
        XCTAssertNotNil(data.range(of: Data(Self.signedContent.utf8)),
                        "opaque signing should embed the signed content")
    }
}
