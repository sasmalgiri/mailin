//
//  DraftComposeTests.swift
//  MailConnectivityTests
//
//  Plan v4 V4-09 acceptance rows T31–T34: durable multi-draft storage with
//  kill-at-boundary recovery, the RFC 5322 address parser and reply rules,
//  forward with ordinary / inline (CID) / nested-message attachments
//  re-parsed by the archive's MIMEParser, and sender authorisation before
//  composition. No network.
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class DraftComposeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    func account(_ address: String, modes: Set<MailAccount.Mode> = [.capture, .send]) -> MailAccount {
        MailAccount(provider: .imap, host: "mail.example.com", port: 993, loginName: address, displayIdentity: address,
                    enabledModes: modes, connectionState: .connected)
    }

    func identity(_ text: String, account: MailAccount, permission: SendingIdentity.Permission = .verified) throws -> SendingIdentity {
        SendingIdentity(accountID: account.id, address: try MailAddress(parsing: text), permission: permission)
    }

    func randomData(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func leftovers(_ root: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).map(\.lastPathComponent).filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".partial") }
    }

    func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Every leaf part of a parsed message, depth first (message/rfc822 parts are leaves).
    func leaves(_ parts: [MIMEPart]) -> [MIMEPart] {
        parts.flatMap { p -> [MIMEPart] in p.mimeType.lowercased().hasPrefix("multipart/") ? leaves(p.subparts) : [p] }
    }

    // MARK: T31 — two drafts, two accounts, killed saves

    func testT31_twoDraftsOnTwoAccounts_survivesKillsAtEveryBoundary_withSenderReferencesAndAttachmentBytes() async throws {
        let a = account("me@alpha.example"), b = account("me@beta.example")
        let idA = try identity("Me <me@alpha.example>", account: a), idB = try identity("me@beta.example", account: b)
        var store = try DraftStore(storeDirectory: dir)

        // Draft 1 (account A): recipients, thread references, a 2.5 MiB copied file, a referenced file.
        var d1 = Draft(accountID: a.id, senderIdentityID: idA.id, kind: .reply,
                       to: try MailAddressParser.parseList(#""Doe, Jane" <jane@example.com>"#),
                       inReplyTo: "<orig@example.com>", references: ["<root@example.com>", "<orig@example.com>"],
                       subject: "Re: plans", plainBody: "first words")
        d1 = try await store.save(d1)
        XCTAssertEqual(d1.revision, 1)
        let bigBytes = randomData(2 * (1 << 20) + 500_000)
        let bigFile = dir.appendingPathComponent("report.pdf")
        try bigBytes.write(to: bigFile)
        d1 = try await store.addAttachment(copying: bigFile, to: d1)
        let refBytes = Data("referenced, not copied".utf8)
        let refFile = dir.appendingPathComponent("notes.txt")
        try refBytes.write(to: refFile)
        d1 = try await store.addReference(to: refFile, in: d1)
        XCTAssertEqual(d1.revision, 3)

        // Draft 2 (account B), created with a starting attachment (a forward's original).
        let fwdBytes = randomData(70_000)
        var d2 = try await store.create(DraftSeed(draft: Draft(accountID: b.id, senderIdentityID: idB.id, kind: .forward,
                                                               references: ["<thread@beta.example>"], subject: "Fwd: invoice"),
                                                  attachments: [DraftAttachmentPayload(filename: "invoice.png", mimeType: "image/png", data: fwdBytes)]))
        XCTAssertEqual(d2.revision, 1)

        // Kill 1: autosave of draft 1 killed after its new draft.json was written but before the rename.
        var edited = d1
        edited.subject = "Re: plans (edited, never published)"
        await store.injectFault(.draftWrittenNotPublished)
        await assertThrowsInterruption { _ = try await store.save(edited) }
        // Kill 2: half of a new draft.json written.
        await store.injectFault(.draftPartiallyWritten)
        await assertThrowsInterruption { _ = try await store.save(edited) }
        // Kill 3: a second copy into draft 1 killed half way through the bytes.
        await store.injectFault(.attachmentPartiallyWritten)
        await assertThrowsInterruption { _ = try await store.addAttachment(copying: bigFile, to: d1) }
        // Kill 4: an attachment copied and published, the draft naming it never saved.
        await store.injectFault(.attachmentPublishedDraftNotSaved)
        await assertThrowsInterruption { _ = try await store.addAttachment(DraftAttachmentPayload(filename: "late.bin", mimeType: "application/octet-stream", data: randomData(10)), to: d2) }
        // Kill 5: a whole new draft killed before its first save.
        await store.injectFault(.attachmentWrittenNotPublished)
        await assertThrowsInterruption {
            _ = try await store.create(DraftSeed(draft: Draft(accountID: a.id), attachments: [DraftAttachmentPayload(filename: "x", mimeType: "application/octet-stream", data: Data([1]))]))
        }

        // "Relaunch": a new store on the same folder.
        store = try DraftStore(storeDirectory: dir)
        XCTAssertEqual(leftovers(store.root), [], "temporary files from killed saves are swept on open")
        let listing = await store.drafts()
        XCTAssertEqual(listing.drafts.count, 2)
        XCTAssertTrue(listing.unreadable.isEmpty)
        XCTAssertEqual(listing.unrecordedAttachmentFiles, 1, "the published-but-unrecorded copy is reported, not deleted or attached")

        let r1 = try XCTUnwrap(listing.drafts.first { $0.id == d1.id })
        XCTAssertEqual(r1, d1, "the last durable revision, exactly")
        XCTAssertEqual(r1.accountID, a.id); XCTAssertEqual(r1.senderIdentityID, idA.id)
        XCTAssertEqual(r1.to.first?.displayName, "Doe, Jane"); XCTAssertEqual(r1.to.count, 1)
        XCTAssertEqual(r1.inReplyTo, "<orig@example.com>"); XCTAssertEqual(r1.references, ["<root@example.com>", "<orig@example.com>"])
        XCTAssertEqual(r1.attachments.count, 2)
        let copied = try await store.bytes(of: r1.attachments[0], in: r1.id)
        XCTAssertEqual(copied, bigBytes); XCTAssertEqual(r1.attachments[0].sha256, sha(bigBytes))
        let referenced = try await store.bytes(of: r1.attachments[1], in: r1.id)
        XCTAssertEqual(referenced, refBytes)

        let r2 = try XCTUnwrap(listing.drafts.first { $0.id == d2.id })
        XCTAssertEqual(r2.accountID, b.id); XCTAssertEqual(r2.senderIdentityID, idB.id)
        XCTAssertEqual(r2.references, ["<thread@beta.example>"])
        XCTAssertEqual(r2.attachments.count, 1)
        let fwd = try await store.bytes(of: r2.attachments[0], in: r2.id)
        XCTAssertEqual(fwd, fwdBytes)

        // Protected storage: owner-only folders and files.
        XCTAssertEqual(try permissions(store.root), 0o700)
        XCTAssertEqual(try permissions(store.root.appendingPathComponent(d1.id.uuidString)), 0o700)
        XCTAssertEqual(try permissions(store.root.appendingPathComponent(d1.id.uuidString).appendingPathComponent("draft.json")), 0o600)
        XCTAssertEqual(try permissions(store.root.appendingPathComponent(d1.id.uuidString).appendingPathComponent("attachments")
            .appendingPathComponent(r1.attachments[0].id.uuidString)), 0o600)

        // A stale autosave is refused, the newer revision kept.
        var stale = r2
        stale.subject = "older edit"
        d2 = try await store.save(r2)
        do { _ = try await store.save(stale); XCTFail("stale save accepted") } catch DraftStoreError.staleRevision(_, let saved, let given) {
            XCTAssertEqual(saved, 2); XCTAssertEqual(given, 1)
        }

        // A referenced file that changes or disappears is reported unavailable — never silently dropped.
        try Data("changed".utf8).write(to: refFile)
        let changed = await store.availability(of: r1.attachments[1], in: r1.id)
        guard case .unavailable(.changedSinceAttached) = changed else { return XCTFail("\(changed)") }
        try FileManager.default.removeItem(at: refFile)
        let missing = await store.availability(of: r1.attachments[1], in: r1.id)
        XCTAssertEqual(missing, .unavailable(.missing))
        do { _ = try await store.compose(r1.id, account: a, identities: [idA], date: Date()); XCTFail("composed without the file") }
        catch DraftStoreError.attachmentUnavailable(let name, .missing) { XCTAssertEqual(name, "notes.txt") }
        let kept = try await store.draft(r1.id)
        XCTAssertEqual(kept.attachments.count, 2, "the unavailable attachment stays listed")

        // Switching a draft's account clears its sender: the identity cannot drift across accounts.
        var moved = r1
        moved.switchAccount(to: b.id)
        XCTAssertNil(moved.senderIdentityID)
    }

    func assertThrowsInterruption(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected a simulated kill", file: file, line: line) } catch DraftStoreError.simulatedInterruption {
        } catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    // MARK: T32 — parser, Reply-To, aliases, Unicode, injection

    func testT32_addressParser_quotedCommasCommentsGroupsUnicodeAndInjection() throws {
        let list = try MailAddressParser.parseList(
            #""Doe, Jane" <jane@example.com>, john@example.com (John Smith), Team: a@x.org, "b c"@y.org;, <@relay.example:z@z.org>, "Q \"Quote\" R" <q@r.example>"#)
        XCTAssertEqual(list.map(\.addrSpec), ["jane@example.com", "john@example.com", "a@x.org", "\"b c\"@y.org", "z@z.org", "q@r.example"])
        XCTAssertEqual(list[0].displayName, "Doe, Jane")
        XCTAssertEqual(list[1].displayName, "John Smith")
        XCTAssertEqual(list[3].localPart, "b c")
        XCTAssertEqual(list[5].displayName, #"Q "Quote" R"#)
        XCTAssertEqual(try MailAddressParser.parseEntries("Team: a@x.org, b@y.org;").first, .group(name: "Team", members: [
            MailAddress(localPart: "a", domain: "x.org"), MailAddress(localPart: "b", domain: "y.org")]))
        XCTAssertEqual(try MailAddressParser.parseList("undisclosed-recipients:;", kind: .header), [])
        XCTAssertEqual(try MailAddress(parsing: "John Q. Public <jqp@example.com>").displayName, "John Q. Public")
        XCTAssertEqual(try MailAddress(parsing: "=?UTF-8?B?w4lsb2RpZQ==?= <e@x.com>").displayName, "Élodie")

        // IDN domain → A-label; EAI local part → needs SMTPUTF8.
        let idn = try MailAddress(parsing: "Jörg <joerg@bücher.example>")
        XCTAssertEqual(try idn.asciiAddrSpec(), "joerg@xn--bcher-kva.example")
        XCTAssertFalse(idn.requiresSMTPUTF8)
        XCTAssertEqual(try MailAddressParser.asciiDomain("例え.テスト"), "xn--r8jz45g.xn--zckzah")
        let eai = try MailAddress(parsing: "用户@例子.example")
        XCTAssertTrue(eai.requiresSMTPUTF8)
        XCTAssertEqual(MailAddress(localPart: "joerg", domain: "BÜCHER.example").normalizedKey, idn.normalizedKey)

        // Malformed and injected input refused.
        for bad in ["john", "a@", "@b.com", "a@@b.com", "<a@b.com", "\"unterminated <a@b.com>", "a@b..com", "Team: a@b.com"] {
            XCTAssertThrowsError(try MailAddressParser.parseList(bad), bad)
        }
        for injected in ["a@x.com\r\nBcc: evil@x.com", "a@x.com\nBcc: evil@x.com", "\"Eve\u{0}\" <e@x.com>", "e@x.com\u{2028}"] {
            XCTAssertThrowsError(try MailAddressParser.parseList(injected)) { XCTAssertEqual($0 as? MailAddressError, .controlCharacter(field: "address")) }
        }
        var draft = Draft(accountID: UUID(), to: [MailAddress(localPart: "a", domain: "x.com")], subject: "Hi\r\nBcc: evil@x.com")
        XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? MailAddressError, .controlCharacter(field: "subject")) }
        draft.subject = "Hi"
        draft.to = [MailAddress(displayName: "Eve\r\nBcc: evil@x.com", localPart: "a", domain: "x.com")]
        XCTAssertThrowsError(try draft.validate())
        draft.to = [MailAddress(localPart: "a", domain: "x.com")]
        draft.references = ["<a@b> <c@d>"]
        XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? DraftError, .invalidMessageID("<a@b> <c@d>")) }

        // De-duplication by mailbox, first spelling kept.
        XCTAssertEqual(MailAddressParser.deduplicated(try MailAddressParser.parseList("Ann <Ann@Example.com>, ann@example.COM, b@x.org")).map(\.addrSpec),
                       ["Ann@Example.com", "b@x.org"])
    }

    static let replyOriginal = """
    From: Bob <bob@example.org>\r
    Reply-To: "Project list, team" <list@example.org>\r
    To: "Me (work)" <me@alpha.example>, Carol <carol@example.net>, LIST@example.org\r
    Cc: ME@ALPHA-ALIAS.example, "Doe, Jane" <jane@example.com>, old-me@archive.example, carol@example.net\r
    Subject: =?UTF-8?B?UGzDpG5l?=\r
    Date: Mon, 2 Nov 2026 10:00:00 +0000\r
    Message-ID: <orig@example.org>\r
    References: <root@example.org> <mid@example.org>\r
    In-Reply-To: <mid@example.org>\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    Line one\r
    Line two\r

    """

    func testT32_replyUsesReplyTo_replyAllExcludesEverySelfAlias_dedupes_andComposesWithoutBcc() async throws {
        let acct = account("me@alpha.example")
        let main = try identity("Me <me@alpha.example>", account: acct)
        let alias = try identity("me@alpha-alias.example", account: acct)
        let other = try identity("other@beta.example", account: account("other@beta.example"))
        let source = ArchivedMessageSource(raw: Data(Self.replyOriginal.utf8))
        XCTAssertEqual(source.replyTo.first?.displayName, "Project list, team")
        XCTAssertEqual(source.subject, "Pläne")

        let reply = try ReplyBuilder.reply(to: source, mode: .reply, accountID: acct.id, identities: [main, alias, other])
        XCTAssertEqual(reply.draft.to.map(\.addrSpec), ["list@example.org"], "Reply-To is preferred over From")
        XCTAssertEqual(reply.draft.cc, [])
        XCTAssertEqual(reply.draft.subject, "Re: Pläne")
        XCTAssertEqual(reply.draft.inReplyTo, "<orig@example.org>")
        XCTAssertEqual(reply.draft.references, ["<root@example.org>", "<mid@example.org>", "<orig@example.org>"])
        XCTAssertNil(reply.draft.senderIdentityID, "addressed to two of my identities: the user chooses")

        let all = try ReplyBuilder.reply(to: source, mode: .replyAll, accountID: acct.id, identities: [main, alias, other],
                                         formerSelfAddresses: [try MailAddress(parsing: "old-me@archive.example")], identityID: alias.id)
        XCTAssertEqual(all.draft.to.map(\.addrSpec), ["list@example.org", "carol@example.net"], "LIST@ de-duplicated; me@ excluded")
        XCTAssertEqual(all.draft.cc.map(\.addrSpec), ["jane@example.com"], "alias, former address and repeated Carol excluded")
        XCTAssertEqual(all.draft.cc.first?.displayName, "Doe, Jane")
        XCTAssertEqual(all.draft.senderIdentityID, alias.id)

        // Compose: Bcc travels only in the envelope; Unicode names round-trip through MIMEParser.
        var draft = all.draft
        draft.bcc = [try MailAddress(parsing: "hidden@secret.example")]
        draft.to.append(try MailAddress(parsing: "Jörg Müller <joerg@bücher.example>"))
        let store = try DraftStore(storeDirectory: dir)
        let saved = try await store.save(draft)
        let composed = try await store.compose(saved.id, account: acct, identities: [main, alias], date: Date(timeIntervalSince1970: 1_800_000_000))
        let text = String(decoding: composed.bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("hidden@secret.example")); XCTAssertFalse(text.lowercased().contains("\nbcc:"))
        XCTAssertTrue(composed.envelopeRecipients.contains("hidden@secret.example"))
        XCTAssertTrue(composed.envelopeRecipients.contains("joerg@xn--bcher-kva.example"))
        XCTAssertFalse(composed.requiresSMTPUTF8)
        let parsed = MIMEParser.parseEmail(rawEmail: text)
        let reTo = try MailAddressParser.parseList(try XCTUnwrap(parsed.headers["To"]), kind: .header)
        XCTAssertEqual(reTo.map(\.displayName), ["Project list, team", "Carol", "Jörg Müller"])
        XCTAssertEqual(EncodedWord.decode(try XCTUnwrap(parsed.headers["Subject"])), "Re: Pläne")
        XCTAssertEqual(try MailAddress(parsing: try XCTUnwrap(parsed.headers["From"])).addrSpec, "me@alpha-alias.example")
        XCTAssertEqual(parsed.headers["In-Reply-To"], "<orig@example.org>")
        XCTAssertTrue(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })

        // EAI recipient → SMTPUTF8 message with a UTF-8 header.
        var eai = saved
        eai.to = [try MailAddress(parsing: "用户@例子.example")]
        let eaiSaved = try await store.save(eai)
        let eaiComposed = try await store.compose(eaiSaved.id, account: acct, identities: [alias], date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(eaiComposed.requiresSMTPUTF8)
        XCTAssertTrue(String(decoding: eaiComposed.bytes, as: UTF8.self).contains("用户@xn--fsqu00a.example"))
    }

    // MARK: T33 — forward with ordinary, inline (CID) and nested-message attachments

    static let pdfBytes: Data = { var g = SystemRandomNumberGenerator(); return Data((0..<9_000).map { _ in UInt8.random(in: 0...255, using: &g) }) }()
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<3_000).map { UInt8($0 % 251) })
    static let nestedEML = "From: Dave <dave@example.com>\r\nTo: bob@example.org\r\nSubject: Inner\r\nMessage-ID: <inner@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nInner body line 1\r\nInner body line 2"

    static func forwardOriginal() -> Data {
        let pdf = pdfBytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let png = pngBytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data("""
        From: Bob <bob@example.org>\r
        To: me@alpha.example\r
        Bcc: secret-watcher@hidden.example\r
        Subject: Quarterly pack\r
        Date: Tue, 3 Nov 2026 09:00:00 +0000\r
        Message-ID: <pack@example.org>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="OUTER"\r
        \r
        --OUTER\r
        Content-Type: multipart/related; boundary="REL"\r
        \r
        --REL\r
        Content-Type: multipart/alternative; boundary="ALT"\r
        \r
        --ALT\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        See the logo and the report.\r
        --ALT\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>See <img src="cid:logo@example.org"> and the report.</p>\r
        --ALT--\r
        --REL\r
        Content-Type: image/png; name="logo.png"\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: inline; filename="logo.png"\r
        Content-ID: <logo@example.org>\r
        \r
        \(png)\r
        --REL--\r
        --OUTER\r
        Content-Type: application/pdf; name="Q3 report, final.pdf"\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: attachment; filename="Q3 report, final.pdf"\r
        \r
        \(pdf)\r
        --OUTER\r
        Content-Type: message/rfc822; name="inner.eml"\r
        Content-Disposition: attachment; filename="inner.eml"\r
        \r
        \(nestedEML)\r
        --OUTER--\r

        """.utf8)
    }

    func testT33_forward_keepsOrdinaryInlineCIDAndNestedMessageBytes_forwardAsEMLDropsBcc_protectedNotSilent() async throws {
        let acct = account("me@alpha.example")
        let me = try identity("me@alpha.example", account: acct)
        let raw = Self.forwardOriginal()
        let source = ArchivedMessageSource(raw: raw)
        XCTAssertEqual(source.attachments.map(\.filename), ["logo.png", "Q3 report, final.pdf", "inner.eml"])
        XCTAssertEqual(source.attachments[0].contentID, "logo@example.org")
        XCTAssertEqual(source.attachments[0].data, Self.pngBytes)
        XCTAssertEqual(source.attachments[1].data, Self.pdfBytes)

        let seed = try ReplyBuilder.forward(source, accountID: acct.id, identities: [me])
        XCTAssertEqual(seed.draft.senderIdentityID, me.id, "addressed to exactly one verified identity of this account")
        XCTAssertFalse((seed.draft.quotedPlain ?? "").contains("secret-watcher"), "the original Bcc is never quoted")
        let store = try DraftStore(storeDirectory: dir)
        var draft = try await store.create(seed)
        draft.to = [try MailAddress(parsing: "Erin <erin@example.net>")]
        draft.htmlBody = "<p>FYI</p>"
        draft.plainBody = "FYI"
        draft = try await store.save(draft)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let composed = try await store.compose(draft.id, account: acct, identities: [me], date: date)
        let again = try await store.compose(draft.id, account: acct, identities: [me], date: date)
        XCTAssertEqual(again, composed, "deterministic")
        XCTAssertEqual(composed.messageID, "<\(draft.messageIDToken.uuidString.lowercased())@alpha.example>")

        let text = String(decoding: composed.bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("secret-watcher"))
        let parsed = MIMEParser.parseEmail(rawEmail: text)
        XCTAssertTrue(parsed.headers["Content-Type"]?.hasPrefix("multipart/mixed") ?? false)
        let parts = leaves(parsed.parts)
        let logo = try XCTUnwrap(parts.first { $0.filename == "logo.png" })
        XCTAssertEqual(sha(ArchivedMessageSource.decodedBytes(logo)), sha(Self.pngBytes))
        XCTAssertEqual(logo.headers["Content-ID"], "<logo@example.org>")
        XCTAssertTrue(logo.contentDisposition.hasPrefix("inline"))
        // The inline part sits in multipart/related next to the HTML that references it.
        let alt = try XCTUnwrap(parsed.parts.first { $0.mimeType.hasPrefix("multipart/alternative") })
        XCTAssertTrue(alt.subparts.contains { $0.mimeType.hasPrefix("multipart/related") && $0.subparts.contains { $0.filename == "logo.png" } })
        let pdf = try XCTUnwrap(parts.first { $0.filename == "Q3 report, final.pdf" })
        XCTAssertEqual(sha(ArchivedMessageSource.decodedBytes(pdf)), sha(Self.pdfBytes))
        let inner = try XCTUnwrap(parts.first { $0.filename == "inner.eml" })
        XCTAssertTrue(inner.mimeType.hasPrefix("message/rfc822"))
        XCTAssertEqual(sha(ArchivedMessageSource.decodedBytes(inner)), sha(Data(Self.nestedEML.utf8)))
        XCTAssertNotNil(composed.bytes.range(of: Data((Self.nestedEML + "\r\n--").utf8)), "the nested message travels byte for byte")
        XCTAssertEqual(inner.subparts.first?.body.trimmingCharacters(in: .whitespacesAndNewlines), "Inner body line 1\r\nInner body line 2")

        // Forward as .eml: the original's bytes, minus its Bcc header.
        let emlSeed = ReplyBuilder.forwardAsAttachment(source, accountID: acct.id, identities: [me])
        let expectedEML = ReplyBuilder.removingBcc(raw)
        XCTAssertEqual(expectedEML.count, raw.count - "Bcc: secret-watcher@hidden.example\r\n".utf8.count)
        XCTAssertEqual(emlSeed.attachments.first?.data, expectedEML)
        var emlDraft = try await store.create(emlSeed)
        emlDraft.to = [try MailAddress(parsing: "erin@example.net")]
        emlDraft = try await store.save(emlDraft)
        let emlComposed = try await store.compose(emlDraft.id, account: acct, identities: [me], date: date)
        XCTAssertFalse(String(decoding: emlComposed.bytes, as: UTF8.self).contains("secret-watcher"))
        XCTAssertNotNil(emlComposed.bytes.range(of: expectedEML), "the .eml is carried unchanged")
        let emlPart = try XCTUnwrap(leaves(MIMEParser.parseEmail(rawEmail: String(decoding: emlComposed.bytes, as: UTF8.self)).parts)
            .first { $0.filename == "Quarterly pack.eml" })
        XCTAssertTrue(emlPart.mimeType.hasPrefix("message/rfc822"))

        // A decrypted original: content is left out unless the user explicitly includes it; either way it is flagged.
        let wrapper = Data("From: Bob <bob@example.org>\r\nTo: me@alpha.example\r\nSubject: Secret\r\nMessage-ID: <enc@example.org>\r\nContent-Type: application/pkcs7-mime; smime-type=enveloped-data\r\nContent-Transfer-Encoding: base64\r\n\r\nMIAGCSqGSIb3DQEHA6CAMIACAQAxggE=\r\n".utf8)
        let protected = ArchivedMessageSource(raw: wrapper, decrypted: raw)
        XCTAssertEqual(protected.protection, .decrypted)
        let silent = try ReplyBuilder.forward(protected, accountID: acct.id, identities: [me])
        XCTAssertEqual(silent.draft.protectedContent, .omitted)
        XCTAssertTrue(silent.attachments.isEmpty); XCTAssertNil(silent.draft.quotedPlain)
        let chosen = try ReplyBuilder.forward(protected, accountID: acct.id, identities: [me], includeProtectedContent: true)
        XCTAssertEqual(chosen.draft.protectedContent, .includedByUserChoice)
        XCTAssertEqual(chosen.attachments.count, 3)
        let encryptedReply = try ReplyBuilder.reply(to: protected, mode: .reply, accountID: acct.id, identities: [me])
        XCTAssertEqual(encryptedReply.draft.securityNotice, .originalEncryptedReplyNotEncrypted)
        XCTAssertEqual(encryptedReply.draft.protectedContent, .omitted)
        XCTAssertFalse((encryptedReply.draft.quotedPlain ?? "").contains("See the logo"))
    }

    func testMIMEComposer_nonASCIIFilenameAndQuotedPrintableBody_roundTripThroughMIMEParser() async throws {
        let acct = account("me@alpha.example")
        let me = try identity("Zoë <me@alpha.example>", account: acct)
        let store = try DraftStore(storeDirectory: dir)
        var draft = Draft(accountID: acct.id, senderIdentityID: me.id, to: [try MailAddress(parsing: "x@example.net")],
                          subject: "Zażółć gęślą jaźń — a long subject line that must be folded across several header lines safely",
                          plainBody: "Grüße\nline two with a very long tail " + String(repeating: "é", count: 200),
                          signature: DraftSignature(plain: "Zoë"))
        draft = try await store.save(draft)
        let bytes = Data("zawartość".utf8)
        draft = try await store.addAttachment(DraftAttachmentPayload(filename: "zażółć.txt", mimeType: "text/plain", data: bytes), to: draft)
        let composed = try await store.compose(draft.id, account: acct, identities: [me], date: Date(timeIntervalSince1970: 0))
        let text = String(decoding: composed.bytes, as: UTF8.self)
        XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII), "7-bit clean: encoded words, quoted-printable, base64")
        XCTAssertTrue(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 78 || !$0.contains(" ") })
        let parsed = MIMEParser.parseEmail(rawEmail: text)
        XCTAssertEqual(EncodedWord.decode(parsed.headers["Subject"] ?? ""), draft.subject)
        XCTAssertEqual(try MailAddress(parsing: try XCTUnwrap(parsed.headers["From"])).displayName, "Zoë")
        let parts = leaves(parsed.parts)
        XCTAssertTrue(parts[0].body.hasPrefix("Grüße\r\nline two"))
        XCTAssertTrue(parts[0].body.contains("-- \r\nZoë"))
        let att = try XCTUnwrap(parts.first { $0.filename == "zażółć.txt" })
        XCTAssertEqual(ArchivedMessageSource.decodedBytes(att), bytes)
    }

    // MARK: T34 — sender identity must belong to the draft's account

    func testT34_foreignOrUnpermittedSender_refusedBeforeComposition() async throws {
        let a = account("me@alpha.example"), b = account("me@beta.example")
        let captureOnly = account("me@gamma.example", modes: [.capture])
        let idA = try identity("me@alpha.example", account: a)
        let idB = try identity("me@beta.example", account: b)
        let unverified = try identity("alias@alpha.example", account: a, permission: .unverified)
        let revoked = try identity("gone@alpha.example", account: a, permission: .revoked)
        let to = [try MailAddress(parsing: "x@example.net")]

        // An identity from account B on a draft of account A.
        var d = Draft(accountID: a.id, senderIdentityID: idB.id, to: to, subject: "s")
        XCTAssertThrowsError(try SenderAuthorisation.authorise(d, account: a, identities: [idA, idB])) {
            guard case SenderAuthorisationError.identityBelongsToAnotherAccount = $0 else { return XCTFail("\($0)") }
        }
        // The draft composed through account B's transport instead.
        d.senderIdentityID = idA.id
        XCTAssertThrowsError(try SenderAuthorisation.authorise(d, account: b, identities: [idA, idB])) {
            XCTAssertEqual($0 as? SenderAuthorisationError, .accountMismatch(draftAccount: a.id, givenAccount: b.id))
        }
        d.senderIdentityID = unverified.id
        XCTAssertThrowsError(try SenderAuthorisation.authorise(d, account: a, identities: [idA, unverified])) {
            XCTAssertEqual($0 as? SenderAuthorisationError, .identityNotPermitted(address: "alias@alpha.example", permission: .unverified))
        }
        d.senderIdentityID = revoked.id
        XCTAssertThrowsError(try SenderAuthorisation.authorise(d, account: a, identities: [idA, revoked]))
        d.senderIdentityID = UUID()
        XCTAssertThrowsError(try SenderAuthorisation.authorise(d, account: a, identities: [idA])) {
            guard case SenderAuthorisationError.unknownIdentity = $0 else { return XCTFail("\($0)") }
        }
        let g = Draft(accountID: captureOnly.id, senderIdentityID: nil, to: to)
        XCTAssertThrowsError(try SenderAuthorisation.authorise(g, account: captureOnly, identities: [])) {
            guard case SenderAuthorisationError.accountCannotSend = $0 else { return XCTFail("\($0)") }
        }

        // A reply to an old archive addressed to its former owner: no identity is preset, and composition is refused.
        let old = ArchivedMessageSource(raw: Data("From: a@old.example\r\nTo: former-owner@old.example\r\nSubject: hi\r\nMessage-ID: <o@old.example>\r\n\r\nbody\r\n".utf8))
        let seed = try ReplyBuilder.reply(to: old, mode: .reply, accountID: a.id, identities: [idA])
        XCTAssertNil(seed.draft.senderIdentityID)
        let store = try DraftStore(storeDirectory: dir)
        let saved = try await store.save(seed.draft)
        do { _ = try await store.compose(saved.id, account: a, identities: [idA], date: Date()); XCTFail("composed without a chosen sender") }
        catch { XCTAssertEqual(error as? SenderAuthorisationError, .noIdentityChosen) }

        // An authorisation is for one draft revision: reusing it for another draft or a later revision is refused
        // before any attachment byte is read.
        var good = Draft(accountID: a.id, senderIdentityID: idA.id, to: to, subject: "s")
        good = try await store.save(good)
        let sender = try SenderAuthorisation.authorise(good, account: a, identities: [idA])
        var reads = 0
        var other = Draft(accountID: a.id, senderIdentityID: idA.id, to: to, subject: "other")
        other = try await store.save(other)
        XCTAssertThrowsError(try MIMEComposer.compose(other, sender: sender, date: Date()) { _ in reads += 1; return Data() }) {
            XCTAssertEqual($0 as? MIMEComposerError, .senderNotAuthorisedForDraft)
        }
        let later = try await store.save(good)
        XCTAssertThrowsError(try MIMEComposer.compose(later, sender: sender, date: Date()) { _ in reads += 1; return Data() }) {
            XCTAssertEqual($0 as? MIMEComposerError, .senderNotAuthorisedForDraft)
        }
        var switched = good
        switched.switchAccount(to: b.id)
        XCTAssertThrowsError(try MIMEComposer.compose(switched, sender: sender, date: Date()) { _ in reads += 1; return Data() })
        XCTAssertEqual(reads, 0)
        XCTAssertNoThrow(try MIMEComposer.compose(good, sender: sender, date: Date()) { _ in Data() })
    }
}
