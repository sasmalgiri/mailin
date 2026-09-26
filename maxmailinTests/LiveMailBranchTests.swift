//
//  LiveMailBranchTests.swift
//  maxmailinTests
//
//  live-mail branch: L1 (the closed gate refuses every connection while the
//  page is off, and a fresh install has it closed), L2 (accounts never share
//  a Keychain key; removal deletes secrets), L3a (XOAUTH2 response shape).
//

import XCTest
@testable import maxmailin

@MainActor
final class NetworkBaselineTests: XCTestCase {

    func testFreshInstallHasLiveMailOffAndTheGateClosed() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modules-\(UUID().uuidString).json")
        let modules = ModuleRegistry(store: ModuleStateStore(url: url), excludedByBuild: [], trapsOnMisuse: false)
        LiveMailNetworkGate.shared.resetForTesting()
        LaunchJobs.run(modules: modules, storageActive: false, storageStateLabel: "test")
        XCTAssertFalse(modules.isEnabled(.liveMail))
        XCTAssertFalse(LiveMailNetworkGate.shared.isOpen, "no launch with the page off may open the gate")
        XCTAssertTrue(LiveMailNetworkGate.shared.permittedHosts.isEmpty)
    }

    func testClosedGateRefusesIMAPBeforeAnySocket() async {
        LiveMailNetworkGate.shared.resetForTesting()
        let client = IMAPClient()
        do {
            try await client.connect(config: IMAPConfig(server: "imap.example.invalid", port: 993, username: "u", password: "p"))
            XCTFail("a closed gate must refuse")
        } catch let error as LiveMailNetworkError {
            XCTAssertEqual(error.localizedDescription, LiveMailNetworkError.pageOff.localizedDescription)
        } catch {
            XCTFail("expected the gate's error, got \(error)")
        }
        XCTAssertEqual(LiveMailNetworkGate.shared.refusedAttempts, 1)
        XCTAssertTrue(LiveMailNetworkGate.shared.permittedHosts.isEmpty)
        XCTAssertEqual(client.connectionState, .disconnected, "the client must not have started connecting")
    }

    func testClosedGateRefusesSMTPBeforeAnySocket() async {
        LiveMailNetworkGate.shared.resetForTesting()
        let client = SMTPClient(config: SMTPConfig(server: "smtp.example.invalid", port: 587, username: "u", password: "p", useSSL: false))
        let email = OutgoingEmail(from: "a@example.com", to: ["b@example.com"], cc: [], bcc: [], subject: "x", body: "y",
                                  isHTML: false, attachments: [], inReplyTo: nil, references: nil)
        do {
            try await client.send(email)
            XCTFail("a closed gate must refuse")
        } catch is LiveMailNetworkError {
            // expected
        } catch {
            XCTFail("expected the gate's error, got \(error)")
        }
        XCTAssertEqual(LiveMailNetworkGate.shared.refusedAttempts, 1)
    }

    func testGateFollowsThePageSwitch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modules-\(UUID().uuidString).json")
        let modules = ModuleRegistry(store: ModuleStateStore(url: url), excludedByBuild: [], trapsOnMisuse: false)
        LiveMailNetworkGate.shared.resetForTesting()
        try modules.enable(.liveMail)
        XCTAssertTrue(LiveMailNetworkGate.shared.isOpen)
        modules.disable(.liveMail)
        XCTAssertFalse(LiveMailNetworkGate.shared.isOpen)
    }
}

@MainActor
final class AccountRegistryTests: XCTestCase {

    private func registry() -> AccountRegistry {
        AccountRegistry(url: FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString).json"))
    }

    func testTwoAccountsWithTheSameUsernameNeverShareAKeychainKey() {
        let registry = registry()
        let a = LiveMailAccount(kind: .imap, displayName: "A", emailAddress: "same@example.com", username: "same@example.com", imapServer: "imap.a.example")
        let b = LiveMailAccount(kind: .imap, displayName: "B", emailAddress: "same@example.com", username: "same@example.com", imapServer: "imap.b.example")
        registry.add(a, password: "password-a")
        registry.add(b, password: "password-b")
        defer { registry.remove(id: a.id); registry.remove(id: b.id) }
        XCTAssertNotEqual(a.passwordKey, b.passwordKey)
        XCTAssertEqual(registry.password(for: a), "password-a")
        XCTAssertEqual(registry.password(for: b), "password-b")
        XCTAssertEqual(registry.imapConfig(for: a).accountID, a.id)
        XCTAssertEqual(registry.imapConfig(for: b).password, "password-b")
    }

    func testRemovingAnAccountDeletesItsSecrets() {
        let registry = registry()
        let a = LiveMailAccount(kind: .imap, displayName: "A", emailAddress: "a@example.com", username: "a", imapServer: "imap.example")
        registry.add(a, password: "secret")
        XCTAssertEqual(registry.password(for: a), "secret")
        registry.remove(id: a.id)
        XCTAssertEqual(registry.password(for: a), "", "the Keychain item must go with the account")
        XCTAssertNil(registry.account(id: a.id))
    }

    func testSecretsAreNeverInTheJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString).json")
        let registry = AccountRegistry(url: url)
        let a = LiveMailAccount(kind: .imap, displayName: "A", emailAddress: "a@example.com", username: "a", imapServer: "imap.example")
        registry.add(a, password: "do-not-persist")
        defer { registry.remove(id: a.id); try? FileManager.default.removeItem(at: url) }
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("do-not-persist"))
    }

    func testXOAUTH2ResponseShape() {
        let response = IMAPConfig.xoauth2Response(user: "u@example.com", token: "tok")
        let decoded = String(data: Data(base64Encoded: response)!, encoding: .utf8)!
        XCTAssertEqual(decoded, "user=u@example.com\u{1}auth=Bearer tok\u{1}\u{1}")
    }
}
