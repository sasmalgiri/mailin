//
//  AccountLoginCheck.swift
//  MailConnectivity
//
//  Lifecycle audit 2026-11-14: an IMAP account is saved only after its
//  password worked. Adding an account (or replacing its password) first
//  opens ONE IMAP session — TLS, LOGIN / AUTHENTICATE, LIST, LOGOUT — and,
//  when an outgoing server is set, ONE SMTP session up to AUTH, then QUIT.
//  Nothing is read from or written to the archive or the Keychain: the
//  password being tested is held only in memory for the check.
//
//  Every connection asks the given network permission first, exactly like
//  capture and sending do.
//

import ArchiveCore
import Foundation

/// A password held in memory for one login check (never written anywhere).
public final class EphemeralPasswordStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let account: UUID
    private var password: Data?

    public init(account: UUID, password: String) {
        self.account = account
        self.password = Data(password.utf8)
    }

    public func read(_ kind: CredentialKind, account id: UUID) throws -> Data? {
        guard kind == .password, id == account else { return nil }
        return lock.withLock { password }
    }

    public func write(_ secret: Data, kind: CredentialKind, account id: UUID) throws {
        guard kind == .password, id == account else { return }
        lock.withLock { password = secret }
    }

    public func delete(_ kind: CredentialKind, account id: UUID) throws {
        guard kind == .password, id == account else { return }
        lock.withLock { password = nil }
    }
}

/// Why a login check failed, in a sentence for the person.
public enum AccountLoginCheckError: LocalizedError, Equatable {
    /// The incoming (IMAP) server did not accept the login.
    case incoming(String)
    /// The outgoing (SMTP) server did not accept the login.
    case outgoing(String)

    public var errorDescription: String? {
        switch self {
        case .incoming(let why): return "The incoming mail server did not accept the sign-in: \(why). Nothing was saved."
        case .outgoing(let why): return "The outgoing mail server did not accept the sign-in: \(why). Nothing was saved."
        }
    }
}

public enum IMAPLoginCheck {
    /// Opens one session for `account` with `password` and logs out again.
    /// Returns the folders the server listed (their special use names Trash).
    @discardableResult
    public static func verify(_ account: MailAccount, password: String, security: IMAPSecurity? = nil,
                              transportFactory: @escaping IMAPTransportFactory = IMAPTransports.system,
                              permission: NetworkPermission?) async throws -> [RemoteFolderOccurrence] {
        let adapter = try IMAPAdapter(account: account, security: security,
                                      credentials: EphemeralPasswordStore(account: account.id, password: password),
                                      transportFactory: transportFactory, permission: permission)
        do {
            let page = try await adapter.listFolders(pageToken: nil, context: ProviderRequestContext(accountID: account.id, accessToken: nil, attempt: 0))
            await adapter.disconnect()
            await adapter.close()
            return page.folders
        } catch {
            await adapter.disconnect()
            await adapter.close()
            throw AccountLoginCheckError.incoming(describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case MailProviderError.reauthorisationRequired, MailProviderError.unauthorized:
            return "the user name or password was refused"
        case MailProviderError.permanent(let why), MailProviderError.transient(let why):
            return why
        default:
            return error.localizedDescription
        }
    }
}

public enum SMTPLoginCheck {
    /// Greeting, EHLO, STARTTLS (port 587) or TLS from the first byte (465),
    /// EHLO again, AUTH with `username` / `password`, QUIT. No message is sent.
    /// The password is sent only over TLS.
    public static func verify(_ settings: SMTPServerSettings, username: String, password: String, accountID: UUID,
                              connector: any SMTPConnector = URLSessionSMTPConnector(),
                              permission: NetworkPermission) async throws {
        do {
            try permission(NetworkAsk(accountID: accountID, host: settings.host, destination: .mailServer, operation: .request))
        } catch {
            throw AccountLoginCheckError.outgoing("connecting to \(settings.host) is not permitted (\(error.localizedDescription))")
        }
        let stream: any SMTPByteStream
        do {
            let host = settings.host, port = settings.port, implicit = settings.security == .implicitTLS
            stream = try await withSMTPDeadline(settings.connectTimeout, onTimeout: {}) {
                try await connector.connect(host: host, port: port, implicitTLS: implicit)
            }
        } catch {
            throw AccountLoginCheckError.outgoing("could not connect to \(settings.host) (\(error.localizedDescription))")
        }
        defer { stream.close() }
        let wire = SMTPWire(stream)
        do {
            try await session(wire, settings: settings, username: username, password: password)
        } catch let refusal as AccountLoginCheckError {
            throw refusal
        } catch let failure as SMTPFailure {
            throw AccountLoginCheckError.outgoing(SMTPSubmitter.describe(failure))
        } catch {
            throw AccountLoginCheckError.outgoing(error.localizedDescription)
        }
    }

    private static func session(_ wire: SMTPWire, settings: SMTPServerSettings, username: String, password: String) async throws {
        let t = settings.commandTimeout
        let greeting = try await wire.reply(timeout: t, stage: "greeting")
        guard greeting.code == 220 else { throw AccountLoginCheckError.outgoing("the server refused the connection (\(greeting.summary))") }
        var caps = try await ehlo(wire, settings)
        if !wire.stream.isTLS {
            guard settings.security == .startTLS, caps.keys.contains("STARTTLS") else {
                await quit(wire)
                throw AccountLoginCheckError.outgoing("\(settings.host) did not offer a secure connection; your password was not sent")
            }
            try await wire.command("STARTTLS", timeout: t, stage: "STARTTLS")
            let ready = try await wire.reply(timeout: t, stage: "STARTTLS")
            guard ready.code == 220, wire.buffer.isEmpty else {
                throw AccountLoginCheckError.outgoing("\(settings.host) did not start a secure connection; your password was not sent")
            }
            do { try await wire.stream.startTLS() } catch {
                throw AccountLoginCheckError.outgoing("a secure connection to \(settings.host) could not be established (\(error.localizedDescription)); your password was not sent")
            }
            caps = try await ehlo(wire, settings)
        }
        guard wire.stream.isTLS else {
            throw AccountLoginCheckError.outgoing("the connection to \(settings.host) is not encrypted; your password was not sent")
        }
        let mechanisms = Set((caps["AUTH"] ?? "").uppercased().split(separator: " ").map(String.init))
        let reply: SMTPReply
        if mechanisms.contains("PLAIN") {
            let token = Data(("\0" + username + "\0" + password).utf8).base64EncodedString()
            try await wire.command("AUTH PLAIN \(token)", timeout: t, stage: "AUTH")
            reply = try await wire.reply(timeout: t, stage: "AUTH")
        } else if mechanisms.contains("LOGIN") {
            try await wire.command("AUTH LOGIN", timeout: t, stage: "AUTH")
            var step = try await wire.reply(timeout: t, stage: "AUTH")
            if step.code == 334 {
                try await wire.command(Data(username.utf8).base64EncodedString(), timeout: t, stage: "AUTH")
                step = try await wire.reply(timeout: t, stage: "AUTH")
            }
            if step.code == 334 {
                try await wire.command(Data(password.utf8).base64EncodedString(), timeout: t, stage: "AUTH")
                step = try await wire.reply(timeout: t, stage: "AUTH")
            }
            reply = step
        } else {
            await quit(wire)
            throw AccountLoginCheckError.outgoing("\(settings.host) offers no password sign-in method mailin supports (PLAIN, LOGIN)")
        }
        await quit(wire)
        guard reply.code == 235 else {
            throw AccountLoginCheckError.outgoing("the user name or password was refused (\(reply.summary))")
        }
    }

    private static func ehlo(_ wire: SMTPWire, _ settings: SMTPServerSettings) async throws -> [String: String] {
        try await wire.command("EHLO \(settings.clientName)", timeout: settings.commandTimeout, stage: "EHLO")
        let r = try await wire.reply(timeout: settings.commandTimeout, stage: "EHLO")
        guard r.code == 250 else { throw AccountLoginCheckError.outgoing("the server did not accept EHLO (\(r.summary))") }
        var caps: [String: String] = [:]
        for line in r.lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first?.uppercased(), !key.isEmpty else { continue }
            caps[key] = parts.count > 1 ? parts[1] : ""
        }
        return caps
    }

    private static func quit(_ wire: SMTPWire) async {
        try? await wire.command("QUIT", timeout: 5, stage: "QUIT")
        _ = try? await wire.reply(timeout: 5, stage: "QUIT")
    }
}
