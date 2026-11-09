//
//  MailAccountCredentialTests.swift
//  MailConnectivityTests
//
//  Plan v4 V4-02 acceptance rows T04–T07, T45, T46 with an in-memory
//  credential store, a fake Keychain and a fake token endpoint (no network).
//

import XCTest
import Foundation
import Security
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class MailAccountCredentialTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mail-conn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { a, _ in a })
    }

    func callback(state: String, _ extra: [String: String] = [:], base: String = "com.googleusercontent.apps.123-test:/oauth2redirect") -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = [URLQueryItem(name: "state", value: state)] + extra.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    // MARK: Form encoding, PKCE

    func testFormEncoding_isApplicationXWWWFormURLEncoded_notQueryAllowed() {
        let body = String(decoding: FormURLEncoding.encode([("code", "4/0A b+c&d=é~/"), ("redirect_uri", "app:/cb?x=1")]), as: UTF8.self)
        XCTAssertEqual(body, "code=4%2F0A+b%2Bc%26d%3D%C3%A9%7E%2F&redirect_uri=app%3A%2Fcb%3Fx%3D1")
        XCTAssertEqual(FormURLEncoding.contentType, "application/x-www-form-urlencoded")
    }

    func testPKCEAndState_freshPerAttempt_challengeIsS256OfTheVerifierSent() async throws {
        let endpoint = FakeTokenEndpoint()
        await endpoint.respond(to: "the-code", json: Fixtures.tokenJSON(access: "A1", refresh: "R1"))
        let session = OAuthSession(accountID: UUID(), configuration: Fixtures.google, transport: endpoint)
        let first = query(try await session.begin())
        let second = query(try await session.begin())
        XCTAssertNotEqual(first["state"], second["state"])
        XCTAssertNotEqual(first["code_challenge"], second["code_challenge"])
        XCTAssertEqual(second["code_challenge_method"], "S256")
        XCTAssertEqual(second["response_type"], "code")
        XCTAssertNil(second["client_secret"], "a native app is a public client")
        let tokens = try await session.complete(callback: callback(state: second["state"]!, ["code": "the-code"]))
        XCTAssertEqual(tokens.accessToken, "A1"); XCTAssertEqual(tokens.refreshToken, "R1")
        let requests = await endpoint.requests
        let sent = try XCTUnwrap(requests.first)
        let verifier = try XCTUnwrap(sent.form["code_verifier"])
        XCTAssertEqual(PKCE.challenge(for: verifier), second["code_challenge"])
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertEqual(sent.form["grant_type"], "authorization_code")
        XCTAssertNil(sent.form["client_secret"])
    }

    // MARK: T04 — denial, cancel, bad callback, revoked refresh

    func testT04_denial_cancel_stateMismatch_wrongRedirect_revokedRefresh_areExplicitAndNeverLoop() async throws {
        let endpoint = FakeTokenEndpoint()
        await endpoint.respond(to: "good", json: Fixtures.tokenJSON(access: "A", refresh: "R"))
        let session = OAuthSession(accountID: UUID(), configuration: Fixtures.google, transport: endpoint)

        // Denied by the user.
        var state = query(try await session.begin())["state"]!
        do { _ = try await session.complete(callback: callback(state: state, ["error": "access_denied"])); XCTFail() }
        catch OAuthError.denied(let code, _) { XCTAssertEqual(code, "access_denied") }
        var pending = await session.isPending
        XCTAssertFalse(pending)
        do { _ = try await session.complete(callback: callback(state: state, ["code": "good"])); XCTFail() }
        catch OAuthError.noPendingAuthorization {}

        // Cancelled window: a late callback is refused, nothing is exchanged.
        state = query(try await session.begin())["state"]!
        await session.cancel()
        do { _ = try await session.complete(callback: callback(state: state, ["code": "good"])); XCTFail() }
        catch OAuthError.noPendingAuthorization {}

        // Crossover: a callback carrying an OLDER attempt's state, a forged state, a wrong redirect, a wrong issuer.
        let old = query(try await session.begin())["state"]!
        state = query(try await session.begin())["state"]!
        do { _ = try await session.complete(callback: callback(state: old, ["code": "good"])); XCTFail() } catch OAuthError.stateMismatch {}
        do { _ = try await session.complete(callback: callback(state: "forged", ["code": "good"])); XCTFail() } catch OAuthError.stateMismatch {}
        do { _ = try await session.complete(callback: callback(state: state, ["code": "good"], base: "evil.app:/oauth2redirect")); XCTFail() }
        catch OAuthError.callbackMismatch {}
        do { _ = try await session.complete(callback: callback(state: state, ["code": "good", "iss": "https://evil.example"])); XCTFail() }
        catch OAuthError.callbackMismatch {}
        pending = await session.isPending
        XCTAssertTrue(pending, "a rejected forged response leaves the genuine attempt open")
        var exchanged = await endpoint.requestCount
        XCTAssertEqual(exchanged, 0, "no rejected callback reached the token endpoint")

        // Cancelled while the code exchange is in flight: the tokens are discarded.
        await endpoint.hold()
        let inFlight = Task { try await session.complete(callback: self.callback(state: state, ["code": "good"])) }
        while await endpoint.requestCount == 0 { await Task.yield() }
        await session.cancel()
        await endpoint.release()
        do { _ = try await inFlight.value; XCTFail() } catch OAuthError.cancelled {}

        // Revoked refresh token: reauthorisation needed, reported once, no retry loop.
        let account = UUID()
        let credentials = InMemoryCredentialStore()
        try credentials.write(try Fixtures.expiredSet(account, refresh: "revoked").encoded(), kind: .oauthTokenSet, account: account)
        await endpoint.respond(to: "revoked", status: 400, json: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        let notified = Counter()
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: endpoint,
                                                  onReauthorisationNeeded: { _ in await notified.increment() })
        await coordinator.register(account: account, configuration: Fixtures.google)
        exchanged = await endpoint.requestCount
        for _ in 0..<3 {
            do { _ = try await coordinator.accessToken(for: account, audience: Fixtures.google.audience); XCTFail() }
            catch OAuthError.reauthorisationNeeded(let id) { XCTAssertEqual(id, account) }
        }
        let refreshes = await coordinator.refreshCount(for: account)
        XCTAssertEqual(refreshes, 1, "one refused refresh, then no background loop")
        let after = await endpoint.requestCount
        XCTAssertEqual(after - exchanged, 1)
        let told = await notified.value
        XCTAssertEqual(told, 1)
        let flagged = await coordinator.requiresReauthorisation(account)
        XCTAssertTrue(flagged)
        // Signing in again clears it.
        try await coordinator.store(OAuthTokenSet(accountID: account, issuer: Fixtures.google.issuer, audience: Fixtures.google.audience,
                                                  accessToken: "fresh", refreshToken: "R2", expiresAt: Date(timeIntervalSinceNow: 3600),
                                                  scopes: Fixtures.google.scopes))
        let token = try await coordinator.accessToken(for: account, audience: Fixtures.google.audience)
        XCTAssertEqual(token, "fresh")
    }

    actor Counter { var value = 0; func increment() { value += 1 } }

    // MARK: T05 — single-flight refresh per account

    func testT05_concurrentRequests_oneRefreshPerAccount_rotatedTokenSaved_otherAccountUnaffected() async throws {
        let a = UUID(), b = UUID(), c = UUID()
        let credentials = InMemoryCredentialStore()
        try credentials.write(try Fixtures.expiredSet(a, refresh: "RA").encoded(), kind: .oauthTokenSet, account: a)
        try credentials.write(try Fixtures.expiredSet(b, refresh: "RB").encoded(), kind: .oauthTokenSet, account: b)
        let cValid = OAuthTokenSet(accountID: c, issuer: Fixtures.google.issuer, audience: Fixtures.google.audience, accessToken: "C-valid",
                                   refreshToken: "RC", expiresAt: Date(timeIntervalSinceNow: 3600), scopes: Fixtures.google.scopes)
        try credentials.write(try cValid.encoded(), kind: .oauthTokenSet, account: c)
        let endpoint = FakeTokenEndpoint()
        await endpoint.setDelay(30_000_000)
        await endpoint.respond(to: "RA", json: Fixtures.tokenJSON(access: "A-new", refresh: "RA-rotated"))
        await endpoint.respond(to: "RB", json: Fixtures.tokenJSON(access: "B-new"))   // no rotation
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: endpoint)
        for id in [a, b, c] { await coordinator.register(account: id, configuration: Fixtures.google) }

        let audience = Fixtures.google.audience
        let results = try await withThrowingTaskGroup(of: (UUID, String).self) { group in
            for _ in 0..<25 { group.addTask { (a, try await coordinator.accessToken(for: a, audience: audience)) } }
            for _ in 0..<10 { group.addTask { (b, try await coordinator.accessToken(for: b, audience: audience)) } }
            for _ in 0..<10 { group.addTask { (c, try await coordinator.accessToken(for: c, audience: audience)) } }
            var out: [(UUID, String)] = []
            for try await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.filter { $0.0 == a }.map(\.1), Array(repeating: "A-new", count: 25))
        XCTAssertEqual(results.filter { $0.0 == b }.map(\.1), Array(repeating: "B-new", count: 10))
        XCTAssertEqual(results.filter { $0.0 == c }.map(\.1), Array(repeating: "C-valid", count: 10))
        let ra = await coordinator.refreshCount(for: a), rb = await coordinator.refreshCount(for: b), rc = await coordinator.refreshCount(for: c)
        XCTAssertEqual([ra, rb, rc], [1, 1, 0], "one refresh per expiring account; a valid account never refreshes")
        let requests = await endpoint.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.form["client_id"] == Fixtures.google.clientID && $0.form["grant_type"] == "refresh_token" })

        // The rotated refresh token was saved (whole set, one write); B kept its own refresh token; C untouched.
        let savedA = try OAuthTokenSet.decode(try XCTUnwrap(credentials.read(.oauthTokenSet, account: a)))
        XCTAssertEqual(savedA.refreshToken, "RA-rotated"); XCTAssertEqual(savedA.accessToken, "A-new"); XCTAssertEqual(savedA.accountID, a)
        let savedB = try OAuthTokenSet.decode(try XCTUnwrap(credentials.read(.oauthTokenSet, account: b)))
        XCTAssertEqual(savedB.refreshToken, "RB"); XCTAssertEqual(savedB.accessToken, "B-new")
        let savedC = try OAuthTokenSet.decode(try XCTUnwrap(credentials.read(.oauthTokenSet, account: c)))
        XCTAssertEqual(savedC, cValid)
    }

    // MARK: T06 — write failure keeps the last working secret

    func testT06_keychainWriteFailure_surfacesStatus_keepsLastWorkingSecret_noFalselyConnectedAccount() async throws {
        // (a) The Keychain logic: update-then-add, never delete-then-add, every status surfaced.
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(api: keychain, useDataProtectionKeychain: false)
        let account = UUID()
        try store.write(Data("secret-1".utf8), kind: .password, account: account)
        XCTAssertEqual(keychain.calls, ["update", "add"], "first save: update finds nothing, then add")
        keychain.updateStatus = errSecInteractionNotAllowed   // device locked
        XCTAssertThrowsError(try store.write(Data("secret-2".utf8), kind: .password, account: account)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .keychain(operation: "saved", status: errSecInteractionNotAllowed))
        }
        keychain.updateStatus = nil
        XCTAssertEqual(try store.read(.password, account: account), Data("secret-1".utf8), "the last working secret is intact")
        XCTAssertFalse(keychain.calls.contains("delete"), "a write never deletes first")
        keychain.addStatus = errSecDiskFull
        let other = UUID()
        XCTAssertThrowsError(try store.write(Data("x".utf8), kind: .password, account: other)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .keychain(operation: "saved", status: errSecDiskFull))
        }
        XCTAssertNil(try store.read(.password, account: other))

        // (b) A refresh whose rotated set cannot be saved: error surfaced, old set kept, save retried before reuse.
        let credentials = InMemoryCredentialStore()
        let id = UUID()
        let original = Fixtures.expiredSet(id, refresh: "R-old")
        try credentials.write(try original.encoded(), kind: .oauthTokenSet, account: id)
        let endpoint = FakeTokenEndpoint()
        await endpoint.respond(to: "R-old", json: Fixtures.tokenJSON(access: "new-access", refresh: "R-new"))
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: endpoint)
        await coordinator.register(account: id, configuration: Fixtures.google)
        credentials.setWriteFailure(errSecInteractionNotAllowed)
        do { _ = try await coordinator.accessToken(for: id, audience: Fixtures.google.audience); XCTFail() }
        catch OAuthError.credentialSaveFailed(let why) { XCTAssertTrue(why.contains("\(errSecInteractionNotAllowed)"), why) }
        XCTAssertEqual(try OAuthTokenSet.decode(try XCTUnwrap(credentials.read(.oauthTokenSet, account: id))), original,
                       "the stored secret is the last working one, not erased")
        credentials.setWriteFailure(nil)
        let token = try await coordinator.accessToken(for: id, audience: Fixtures.google.audience)
        XCTAssertEqual(token, "new-access")
        let refreshes = await coordinator.refreshCount(for: id)
        XCTAssertEqual(refreshes, 1, "the rotation is saved, not re-requested")
        XCTAssertEqual(try OAuthTokenSet.decode(try XCTUnwrap(credentials.read(.oauthTokenSet, account: id))).refreshToken, "R-new")

        // (c) Account save: secret write fails → nothing saved; record save fails (disk full) → secret removed, error shown.
        let records = FakeRecordStore()
        let registry = MailAccountRegistry(records: records, credentials: credentials)
        let gmail = MailAccount(provider: .gmail, issuer: Fixtures.google.issuer, displayIdentity: "asha@gmail.com")
        credentials.setWriteFailure(errSecInteractionNotAllowed)
        do { try await registry.add(gmail, secret: Data("tokens".utf8), kind: .oauthTokenSet); XCTFail() }
        catch let error as CredentialStoreError { XCTAssertEqual(error, .keychain(operation: "saved", status: errSecInteractionNotAllowed)) }
        credentials.setWriteFailure(nil)
        await records.setFailure("disk full")
        do { try await registry.add(gmail, secret: Data("tokens".utf8), kind: .oauthTokenSet); XCTFail() }
        catch MailAccountError.saveFailed(let why) { XCTAssertTrue(why.contains("disk full"), why) }
        let listed = try await registry.accounts()
        XCTAssertTrue(listed.isEmpty, "no falsely authenticated account")
        XCTAssertNil(try credentials.read(.oauthTokenSet, account: gmail.id), "the half-added secret was removed")
    }

    // MARK: T07 — accounts at the same provider stay distinct

    func testT07_twoGmailAccounts_andTwoIMAPServersWithTheSameLogin_stayDistinctAcrossRestart() async throws {
        let credentials = InMemoryCredentialStore()
        let storeDir = dir.appendingPathComponent("store", isDirectory: true)
        var registry: MailAccountRegistry? = MailAccountRegistry(records: ConnectedArchiveSink(storeDirectory: storeDir), credentials: credentials)
        let g1 = MailAccount(provider: .gmail, issuer: Fixtures.google.issuer, displayIdentity: "asha@gmail.com", grantedScopes: Fixtures.google.scopes)
        let g2 = MailAccount(provider: .gmail, issuer: Fixtures.google.issuer, displayIdentity: "asha.work@gmail.com", grantedScopes: Fixtures.google.scopes)
        let i1 = MailAccount(provider: .imap, host: "imap.one.example", port: 993, loginName: "asha", displayIdentity: "asha@one.example")
        let i2 = MailAccount(provider: .imap, host: "imap.two.example", port: 993, loginName: "asha", displayIdentity: "asha@two.example")
        func set(_ id: UUID, _ name: String) throws -> Data {
            try OAuthTokenSet(accountID: id, issuer: Fixtures.google.issuer, audience: Fixtures.google.audience, accessToken: "access-\(name)",
                              refreshToken: "refresh-\(name)", expiresAt: Date(timeIntervalSinceNow: 3600), scopes: Fixtures.google.scopes).encoded()
        }
        try await registry!.add(g1, secret: try set(g1.id, "g1"), kind: .oauthTokenSet)
        try await registry!.add(g2, secret: try set(g2.id, "g2"), kind: .oauthTokenSet)
        try await registry!.add(i1, secret: Data("pw-one".utf8), kind: .password)
        try await registry!.add(i2, secret: Data("pw-two".utf8), kind: .password)
        registry = nil

        // Restart: a new archive connection and registry.
        let reopened = MailAccountRegistry(records: ConnectedArchiveSink(storeDirectory: storeDir), credentials: credentials)
        let accounts = try await reopened.accounts()
        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(Set(accounts.map(\.id)).count, 4)
        XCTAssertTrue(accounts.allSatisfy { $0.connectionState == .connected })
        XCTAssertEqual(Set(accounts.map(\.serverIdentity)), [Fixtures.google.issuer, "imap.one.example:993", "imap.two.example:993"])
        XCTAssertEqual(try credentials.read(.password, account: i1.id), Data("pw-one".utf8))
        XCTAssertEqual(try credentials.read(.password, account: i2.id), Data("pw-two".utf8), "same login, different server: separate secrets")
        XCTAssertNotEqual(KeychainCredentialStore.itemAccount(i1.id, .password), KeychainCredentialStore.itemAccount(i2.id, .password))
        XCTAssertFalse(KeychainCredentialStore.itemAccount(i1.id, .password).contains("asha"), "never keyed by user name")

        // Tokens never cross accounts or audiences.
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: FakeTokenEndpoint())
        for a in [g1, g2] { await coordinator.register(account: a.id, configuration: Fixtures.google) }
        let t1 = try await coordinator.accessToken(for: g1.id, audience: Fixtures.google.audience)
        let t2 = try await coordinator.accessToken(for: g2.id, audience: Fixtures.google.audience)
        XCTAssertEqual([t1, t2], ["access-g1", "access-g2"])
        do { _ = try await coordinator.accessToken(for: g1.id, audience: "https://outlook.office.com/IMAP"); XCTFail() }
        catch OAuthError.audienceMismatch {}
        // A set filed under the wrong account (damaged / injected) is refused, not used.
        let stray = UUID()
        try credentials.write(try set(g1.id, "g1"), kind: .oauthTokenSet, account: stray)
        await coordinator.register(account: stray, configuration: Fixtures.google)
        do { _ = try await coordinator.accessToken(for: stray, audience: Fixtures.google.audience); XCTFail() }
        catch OAuthError.wrongAccount(let expected, let found) { XCTAssertEqual(expected, stray); XCTAssertEqual(found, g1.id) }

        // Removing one account leaves the others and their secrets.
        try await reopened.remove(g1.id)
        XCTAssertNil(try credentials.read(.oauthTokenSet, account: g1.id))
        XCTAssertNotNil(try credentials.read(.oauthTokenSet, account: g2.id))
        let afterRemoval = try await reopened.accounts()
        XCTAssertEqual(afterRemoval.first { $0.id == g1.id }?.connectionState, .removed)
        XCTAssertEqual(afterRemoval.filter { $0.connectionState == .connected }.count, 3)
    }

    // MARK: T45 — backup / restore / export carry provenance, never credentials

    func testT45_backupRestoreAndExport_keepAccountProvenance_carryNoCredentials_restoredAccountNeedsReauthorisation() async throws {
        let secretAccess = "ya29.SECRET-ACCESS-\(UUID().uuidString)"
        let secretRefresh = "1//SECRET-REFRESH-\(UUID().uuidString)"
        let credentials = InMemoryCredentialStore()
        let storeDir = dir.appendingPathComponent("store", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let registry = MailAccountRegistry(records: sink, credentials: credentials)
        let account = MailAccount(provider: .gmail, issuer: Fixtures.google.issuer, displayIdentity: "asha@gmail.com",
                                  grantedScopes: Fixtures.google.scopes)
        try await registry.add(account, secret: try OAuthTokenSet(
            accountID: account.id, issuer: Fixtures.google.issuer, audience: Fixtures.google.audience, accessToken: secretAccess,
            refreshToken: secretRefresh, expiresAt: Date(timeIntervalSinceNow: 3600), scopes: Fixtures.google.scopes).encoded(),
            kind: .oauthTokenSet)
        // One captured message.
        let run = try await sink.beginRun(accountID: account.id, selection: "INBOX")
        let writer = try sink.makeStagingWriter()
        let bytes = Data("Message-ID: <t45@x>\r\nFrom: a@example.com\r\nSubject: T45\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\n\r\nHello\r\n".utf8)
        try writer.append(bytes)
        let outcome = try await sink.capture(CaptureItem(accountID: account.id, identity: .gmail(messageID: "18c0ffee"),
                                                         occurrences: [RemoteFolderOccurrence(serverID: "INBOX", displayPath: "Inbox", kind: .label)],
                                                         raw: try writer.finish(), metadata: ProviderMetadata(representation: .gmailRaw)),
                                             runID: run)
        let emailID = try XCTUnwrap(outcome.emailID)

        // Backup, then restore on a "different machine": clean store folder, empty Keychain.
        let backup = dir.appendingPathComponent("backup", isDirectory: true)
        _ = try await ArchiveBackup.create(store: sink.store, to: backup)
        try assertNoSecret(in: backup, secrets: [secretAccess, secretRefresh])
        let restoredDir = dir.appendingPathComponent("restored", isDirectory: true)
        try ArchiveBackup.restore(backup: backup, intoStoreDirectory: restoredDir, mode: .cleanProfile)
        let restoredSink = ConnectedArchiveSink(storeDirectory: restoredDir)
        let restoredRegistry = MailAccountRegistry(records: restoredSink, credentials: InMemoryCredentialStore())
        let restored = try await restoredRegistry.accounts()
        XCTAssertEqual(restored.map(\.id), [account.id])
        XCTAssertEqual(restored.first?.displayIdentity, "asha@gmail.com")
        XCTAssertEqual(restored.first?.connectionState, .needsReauthorisation, "a restored account asks to sign in again")
        let provenance = try await restoredSink.provenance(emailID: emailID)
        XCTAssertEqual(provenance?.accountID, account.id)
        XCTAssertEqual(provenance?.providerMessageID, "18c0ffee")
        XCTAssertEqual(provenance?.memberships, ["Inbox"])
        XCTAssertEqual(provenance?.sha256, outcome.sha256)
        let total = try await restoredSink.store.totalCount()
        XCTAssertEqual(total, 1, "the archive works without the credential")

        // Export from the restored archive: provenance sidecar, no secret anywhere.
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let out = dir.appendingPathComponent("export", isDirectory: true)
        let store = restoredSink.store
        _ = try await MainActor.run {
            ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
        }.exportEMLFiles(scope: .explicit([emailID]), to: out)
        let sidecar = try await restoredSink.writeProvenanceSidecar(exportFolder: out)
        XCTAssertNotNil(sidecar)
        try assertNoSecret(in: out, secrets: [secretAccess, secretRefresh])
        let text = try String(contentsOf: try XCTUnwrap(sidecar), encoding: .utf8)
        XCTAssertTrue(text.contains(account.id.uuidString) && text.contains("18c0ffee"))
    }

    func assertNoSecret(in folder: URL, secrets: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var scanned = 0
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = try Data(contentsOf: url)
            scanned += 1
            for secret in secrets {
                XCTAssertNil(data.range(of: Data(secret.utf8)), "\(url.lastPathComponent) contains a credential", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(scanned, 0, file: file, line: line)
    }

    // MARK: T46 — old global credentials are never auto-assigned

    func testT46_legacySingletonCredentials_areListedUnassigned_andOnlyAnExplicitConfirmedChoiceCopiesThem() async throws {
        let legacy = FakeLegacyKeychain(box: .init([
            "gmail_access_token": Data("legacy-access".utf8),
            "gmail_refresh_token": Data("legacy-refresh".utf8),
            "gmail_token_expiry": Data("1736137800".utf8),
            "imap_password": Data("legacy-imap".utf8),
        ]))
        let inventory = LegacyCredentialInventory(reader: legacy)
        let credentials = InMemoryCredentialStore()
        let records = FakeRecordStore()
        let registry = MailAccountRegistry(records: records, credentials: credentials)
        let first = MailAccount(provider: .gmail, issuer: Fixtures.google.issuer, displayIdentity: "first@gmail.com", connectionState: .connected)
        let second = MailAccount(provider: .gmail, issuer: Fixtures.google.issuer, displayIdentity: "second@gmail.com", connectionState: .connected)
        let imap = MailAccount(provider: .imap, host: "imap.example.com", loginName: "asha", displayIdentity: "asha@example.com", connectionState: .connected)
        for a in [first, second, imap] { try await registry.save(a) }

        // Nothing was assigned on upgrade: every account still needs a sign-in, the old items are listed.
        let accounts = try await registry.accounts()
        XCTAssertTrue(accounts.allSatisfy { $0.connectionState == .needsReauthorisation }, "\(accounts.map(\.connectionState))")
        XCTAssertTrue(credentials.allSecrets.isEmpty)
        let unassigned = try inventory.unassigned()
        XCTAssertEqual(Set(unassigned.map(\.key)), ["gmail_access_token", "gmail_refresh_token", "gmail_token_expiry", "imap_password"])
        let gmailItems = unassigned.filter { $0.purpose == .gmailSignIn }

        // Refused without a confirmation naming this account and exactly these keys; refused across providers.
        XCTAssertThrowsError(try inventory.assign(gmailItems, to: second, confirmation: .init(accountID: first.id, keys: Set(gmailItems.map(\.key))),
                                                  into: credentials, audience: Fixtures.google.audience)) {
            XCTAssertEqual($0 as? LegacyCredentialError, .notConfirmed)
        }
        XCTAssertThrowsError(try inventory.assign(gmailItems, to: second, confirmation: .init(accountID: second.id, keys: ["gmail_access_token"]),
                                                  into: credentials, audience: Fixtures.google.audience))
        XCTAssertThrowsError(try inventory.assign(gmailItems, to: imap, confirmation: .init(accountID: imap.id, keys: Set(gmailItems.map(\.key))),
                                                  into: credentials, audience: Fixtures.google.audience)) {
            XCTAssertEqual($0 as? LegacyCredentialError, .providerMismatch(key: gmailItems[0].key))
        }
        XCTAssertTrue(credentials.allSecrets.isEmpty)

        // The explicit choice: the SECOND account. Only it gets the token set, bound to it.
        try inventory.assign(gmailItems, to: second, confirmation: .init(accountID: second.id, keys: Set(gmailItems.map(\.key))),
                             into: credentials, audience: Fixtures.google.audience)
        XCTAssertNil(try credentials.read(.oauthTokenSet, account: first.id))
        let copied = try OAuthTokenSet.decode(try XCTUnwrap(credentials.read(.oauthTokenSet, account: second.id)))
        XCTAssertEqual(copied.accountID, second.id)
        XCTAssertEqual(copied.refreshToken, "legacy-refresh")
        XCTAssertEqual(copied.expiresAt, Date(timeIntervalSince1970: 1_736_137_800))
        let states = Dictionary(uniqueKeysWithValues: try await registry.accounts().map { ($0.id, $0.connectionState) })
        XCTAssertEqual(states[first.id], .needsReauthorisation)
        XCTAssertEqual(states[second.id], .connected)
        // The copy deletes nothing (rule 1); retiring is a separate explicit step.
        XCTAssertEqual(try inventory.unassigned().count, 4)
        try inventory.retire(gmailItems)
        XCTAssertEqual(try inventory.unassigned().map(\.key), ["imap_password"])
    }

    // MARK: The real Keychain, once

    func testKeychainCredentialStore_realKeychain_updateThenAdd_roundTrip() throws {
        let store = KeychainCredentialStore(useDataProtectionKeychain: false)
        let account = UUID()
        do { try store.write(Data("one".utf8), kind: .password, account: account) }
        catch CredentialStoreError.keychain(_, let status) { throw XCTSkip("Keychain unavailable to this test host (\(status))") }
        defer { try? store.delete(.password, account: account) }
        try store.write(Data("two".utf8), kind: .password, account: account)
        XCTAssertEqual(try store.read(.password, account: account), Data("two".utf8))
        XCTAssertNil(try store.read(.password, account: UUID()))
        try store.delete(.password, account: account)
        XCTAssertNil(try store.read(.password, account: account))
        try store.delete(.password, account: account)   // absent: not an error
    }
}
