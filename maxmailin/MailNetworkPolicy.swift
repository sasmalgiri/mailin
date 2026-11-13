//
//  MailNetworkPolicy.swift
//  maxmailin
//
//  V4-01 (plan §3 A01/A02, §7 "Network policy"): the one runtime gate every
//  connected-mail transport must ask before it touches the network — before an
//  OAuth refresh, before following a redirect, before a retry, before a
//  download and before creating a socket. Ported from the idea of the
//  live-mail branch's `LiveMailNetworkGate`, extended with per-account
//  permission modes, a cancellation registry and refusal counts.
//
//  Two layers, both required:
//   1. Compile time. Mail transports are compiled only under
//      `MAILIN_CONNECTED_MAIL`, cloud AI only under `MAILIN_CLOUD_AI`, and
//      `NO_NETWORK_BUILD` keeps both out. The shipping offline build defines
//      neither, so it contains no transport at all (`ConnectedBuildFeatures`).
//      Connecting mail never compiles cloud AI: the conditions are independent.
//   2. Run time (this type). Mail is off until the `connectedMail` capability is
//      on (its page, Live Mail, is off on a fresh install); each account is off
//      and holds no permission mode until granted. Switching Mail or an
//      account off cancels that work and refuses anything new.
//
//  The policy never permits an AI destination or remote content, whatever the
//  caller claims the destination is: it is a MAIL policy.
//
//  Thread-safe (transports run off the main actor); the lock is never held
//  while a cancellation handler runs.
//

import Foundation
import os

// MARK: - Compile-time facts

/// What this binary was compiled with. Read by Health and by the tests that
/// prove the offline build contains no transport.
enum ConnectedBuildFeatures {
    #if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
    static let mailTransportsCompiled = true
    #else
    static let mailTransportsCompiled = false
    #endif

    #if MAILIN_CLOUD_AI && !NO_NETWORK_BUILD
    static let cloudAICompiled = true
    #else
    static let cloudAICompiled = false
    #endif
}

// MARK: - Vocabulary

/// What an account is allowed to do. All three are off for a new account.
enum MailAccountMode: String, CaseIterable, Codable, Sendable {
    /// Read mail from the server and keep a copy in the archive (read-only capture).
    case preserveMail
    /// Submit outgoing mail.
    case sendMail
    /// Change mail on the server: flags, moves, labels, deletion.
    case changeServerMail

    var displayName: String {
        switch self {
        case .preserveMail: return String(localized: "Preserve mail")
        case .sendMail: return String(localized: "Send mail")
        case .changeServerMail: return String(localized: "Change server mail")
        }
    }
}

/// The kind of network step a transport is about to take. Every one of them
/// asks the policy, so a refusal stops a retry or redirect as well as a first
/// connection.
enum MailNetworkOperation: String, CaseIterable, Sendable {
    case socket
    case oauthRefresh
    case redirect
    case retry
    case download
    case request
}

/// Who is on the other end, as the caller understands it. The policy checks
/// the host independently, so mislabelling an AI host as a mail server does
/// not get it through.
enum MailNetworkDestination: String, CaseIterable, Sendable {
    /// The account's mail server or provider mail API.
    case mailServer
    /// The account's sign-in / token endpoint.
    case authorization
    /// A cloud AI service. Never permitted by this policy.
    case aiService
    /// Content referenced by a message (images, fonts, tracking pixels). Never
    /// permitted by this policy; a user-requested load is a separate action.
    case remoteContent
}

struct MailNetworkRequest: Sendable, Equatable {
    var accountID: UUID?
    var host: String
    var destination: MailNetworkDestination
    var operation: MailNetworkOperation
    /// The permission mode this step serves.
    var purpose: MailAccountMode
}

/// A LocalizedError, so wherever a refusal surfaces it reads as its
/// translated explanation (never "MailNetworkRefusal error 3").
enum MailNetworkRefusal: String, LocalizedError, CaseIterable, Sendable {
    var errorDescription: String? { explanation }

    case notCompiled
    case mailOff
    case noAccount
    case accountOff
    case modeNotGranted
    case hostNotAuthorized
    case aiDestination
    case remoteContent

    var explanation: String {
        switch self {
        case .notCompiled: return String(localized: "This edition has no mail connection code.")
        case .mailOff: return String(localized: "Mail is switched off.")
        case .noAccount: return String(localized: "The account is not known to mailin.")
        case .accountOff: return String(localized: "The account is switched off.")
        case .modeNotGranted: return String(localized: "The account has not been allowed to do this.")
        case .hostNotAuthorized: return String(localized: "The server is not one this account uses.")
        case .aiDestination: return String(localized: "Mail never connects to an AI service.")
        case .remoteContent: return String(localized: "Mail never loads remote content.")
        }
    }
}

/// The policy's view of one account. Off, with no modes, until granted.
struct MailAccountNetworkPolicy: Sendable, Equatable, Identifiable {
    let id: UUID
    var isEnabled: Bool = false
    var modes: Set<MailAccountMode> = []
    /// Mail servers / provider API hosts this account talks to (user-configured
    /// for IMAP/SMTP). A redirect or pagination link to any other host is refused.
    var mailHosts: Set<String> = []
    /// Sign-in / token hosts for this account's provider.
    var authorizationHosts: Set<String> = []
}

// MARK: - Policy

final class MailNetworkPolicy: @unchecked Sendable {
    static let shared = MailNetworkPolicy()

    /// Posted (on whatever thread changed it) whenever state or counts change.
    static let didChange = Notification.Name("MailNetworkPolicy.didChange")

    /// Hosts of cloud AI services. Refused even when a caller labels them as a
    /// mail server; matched on the host and every parent domain.
    static let aiHostSuffixes: Set<String> = [
        "openai.com", "anthropic.com", "claude.ai", "generativelanguage.googleapis.com",
        "aiplatform.googleapis.com", "openai.azure.com", "cognitiveservices.azure.com",
        "mistral.ai", "cohere.ai", "cohere.com", "groq.com", "perplexity.ai",
        "x.ai", "deepseek.com", "openrouter.ai", "together.xyz", "huggingface.co",
    ]

    struct Snapshot: Sendable, Equatable {
        var transportsCompiled: Bool
        var cloudAICompiled: Bool
        var isMailEnabled: Bool
        var accounts: [MailAccountNetworkPolicy]
        var permittedAttempts: Int
        var refusedAttempts: Int
        var refusalsByReason: [MailNetworkRefusal: Int]
        var activeTasks: Int
        var cancelledTasks: Int
    }

    struct TaskToken: Hashable, Sendable {
        let id: UUID
    }

    private struct RegisteredTask {
        let accountID: UUID?
        let label: String
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "MailNetworkPolicy")
    private let transportsCompiled: Bool

    private var mailEnabled = false
    private var accounts: [UUID: MailAccountNetworkPolicy] = [:]
    private var tasks: [TaskToken: RegisteredTask] = [:]
    private var permitted = 0
    private var refused = 0
    private var refusals: [MailNetworkRefusal: Int] = [:]
    private var cancelled = 0

    /// `transportsCompiled` is injectable so the policy's rules can be tested in
    /// the offline test build, where the real answer is always "not compiled".
    init(transportsCompiled: Bool = ConnectedBuildFeatures.mailTransportsCompiled) {
        self.transportsCompiled = transportsCompiled
    }

    // MARK: Switching

    var isMailEnabled: Bool { lock.withLock { mailEnabled } }

    /// Driven by `CapabilityWiring` from the resolved `connectedMail` state.
    /// Off cancels every registered task.
    func setMailEnabled(_ enabled: Bool) {
        let doomed: [RegisteredTask] = lock.withLock {
            mailEnabled = enabled
            guard !enabled else { return [] }
            let all = Array(tasks.values)
            tasks.removeAll()
            cancelled += all.count
            return all
        }
        runCancellations(doomed, reason: "Mail switched off")
        notify()
    }

    /// Adds or replaces an account's policy. Disabling it (or removing modes)
    /// cancels that account's registered tasks.
    func setAccount(_ policy: MailAccountNetworkPolicy) {
        let doomed: [RegisteredTask] = lock.withLock {
            let previous = accounts[policy.id]
            accounts[policy.id] = policy
            let narrowed = !policy.isEnabled
                || !(previous?.modes ?? []).isSubset(of: policy.modes)
                || !(previous?.mailHosts ?? []).isSubset(of: policy.mailHosts)
                || !(previous?.authorizationHosts ?? []).isSubset(of: policy.authorizationHosts)
            return narrowed ? takeTasks(for: policy.id) : []
        }
        runCancellations(doomed, reason: "account changed")
        notify()
    }

    func removeAccount(_ id: UUID) {
        let doomed: [RegisteredTask] = lock.withLock {
            accounts[id] = nil
            return takeTasks(for: id)
        }
        runCancellations(doomed, reason: "account removed")
        notify()
    }

    func account(_ id: UUID) -> MailAccountNetworkPolicy? {
        lock.withLock { accounts[id] }
    }

    // MARK: Asking

    /// Ask before every network step. Throws the reason when refused; the
    /// attempt is counted either way.
    func permit(_ request: MailNetworkRequest) throws {
        let refusal: MailNetworkRefusal? = lock.withLock {
            let reason = evaluate(request)
            if let reason {
                refused += 1
                refusals[reason, default: 0] += 1
            } else {
                permitted += 1
            }
            return reason
        }
        notify()
        if let refusal {
            log.notice("""
                refused \(request.operation.rawValue, privacy: .public) to \
                \(request.host, privacy: .public): \(refusal.rawValue, privacy: .public)
                """)
            throw refusal
        }
    }

    /// The decision without counting it, for UI that wants to say why a button
    /// would not work.
    func wouldPermit(_ request: MailNetworkRequest) -> MailNetworkRefusal? {
        lock.withLock { evaluate(request) }
    }

    private func evaluate(_ request: MailNetworkRequest) -> MailNetworkRefusal? {
        // AI and remote content first: refused even in a build without transports,
        // so the answer to "may mail reach an AI service?" is always the same.
        if request.destination == .aiService || Self.isAIHost(request.host) { return .aiDestination }
        if request.destination == .remoteContent { return .remoteContent }
        guard transportsCompiled else { return .notCompiled }
        guard mailEnabled else { return .mailOff }
        guard let id = request.accountID, let account = accounts[id] else { return .noAccount }
        guard account.isEnabled else { return .accountOff }
        guard account.modes.contains(request.purpose) else { return .modeNotGranted }
        let host = Self.normalized(request.host)
        let allowed = request.destination == .authorization ? account.authorizationHosts : account.mailHosts
        guard !host.isEmpty, allowed.contains(where: { Self.normalized($0) == host }) else {
            return .hostNotAuthorized
        }
        return nil
    }

    static func normalized(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func isAIHost(_ host: String) -> Bool {
        let h = normalized(host)
        return aiHostSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: Cancellation registry

    /// Registers in-flight work so switching Mail or the account off can stop
    /// it. Refused (returns nil, cancels nothing) when the work could not run
    /// anyway — the caller must not start it.
    func register(accountID: UUID?, label: String,
                  cancel: @escaping @Sendable () -> Void) -> TaskToken? {
        let token = TaskToken(id: UUID())
        let accepted: Bool = lock.withLock {
            guard transportsCompiled, mailEnabled else { return false }
            if let accountID {
                guard accounts[accountID]?.isEnabled == true else { return false }
            }
            tasks[token] = RegisteredTask(accountID: accountID, label: label, cancel: cancel)
            return true
        }
        notify()
        return accepted ? token : nil
    }

    /// Convenience for a Swift task: cancelling the registration cancels the task.
    func register<Success, Failure>(_ task: Task<Success, Failure>, accountID: UUID?,
                                    label: String) -> TaskToken? {
        register(accountID: accountID, label: label) { task.cancel() }
    }

    /// Called by the work itself when it ends normally.
    func finish(_ token: TaskToken) {
        _ = lock.withLock { tasks.removeValue(forKey: token) }
        notify()
    }

    private func takeTasks(for accountID: UUID) -> [RegisteredTask] {
        let keys = tasks.filter { $0.value.accountID == accountID }.map(\.key)
        let doomed = keys.compactMap { tasks.removeValue(forKey: $0) }
        cancelled += doomed.count
        return doomed
    }

    private func runCancellations(_ doomed: [RegisteredTask], reason: String) {
        guard !doomed.isEmpty else { return }
        for task in doomed { task.cancel() }
        log.notice("cancelled \(doomed.count) mail task(s): \(reason, privacy: .public)")
    }

    // MARK: Reading

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(transportsCompiled: transportsCompiled,
                     cloudAICompiled: ConnectedBuildFeatures.cloudAICompiled,
                     isMailEnabled: mailEnabled,
                     accounts: accounts.values.sorted { $0.id.uuidString < $1.id.uuidString },
                     permittedAttempts: permitted,
                     refusedAttempts: refused,
                     refusalsByReason: refusals,
                     activeTasks: tasks.count,
                     cancelledTasks: cancelled)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Test hook: back to the fresh-install state.
    func resetForTesting() {
        lock.withLock {
            mailEnabled = false
            accounts = [:]
            tasks = [:]
            permitted = 0
            refused = 0
            refusals = [:]
            cancelled = 0
        }
    }
}
