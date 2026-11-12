//
//  AIPolicy.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-01 (§13.3 "independent build/runtime controls for Mail, cloud
//  AI …"): the AI policy. It is deliberately independent of the app's
//  `MailNetworkPolicy`: it takes no input from it, and nothing about a mail
//  account — being connected, its hosts, its tokens — can switch AI on, lend
//  it a host or lend it a credential (AI keys live under their own Keychain
//  service, `AIKeyProfileStore.service`).
//
//  Off on a fresh install; and in this release the runtime is not shipped, so
//  every request is refused before anything else is considered.
//

import Foundation

public final class AIPolicy: @unchecked Sendable {
    public static let shared = AIPolicy()

    /// Mail-service hosts AI never uses, matched on the host and every parent
    /// domain, plus the mail-protocol prefixes. "AI never borrows mail hosts".
    public static let mailHostSuffixes: Set<String> = [
        "gmail.googleapis.com", "gmail.com", "googlemail.com", "accounts.google.com", "oauth2.googleapis.com",
        "graph.microsoft.com", "outlook.office365.com", "outlook.office.com", "outlook.com",
        "login.microsoftonline.com", "login.live.com", "office365.com",
    ]
    public static let mailHostPrefixes: [String] = ["imap.", "smtp.", "pop.", "pop3.", "mail."]

    public struct TaskToken: Hashable, Sendable { let id: UUID }

    private let lock = NSLock()
    private let runtimeShipped: Bool
    private var enabled = false
    private var tasks: [TaskToken: @Sendable () -> Void] = [:]
    private var cancelledCount = 0

    /// `runtimeShipped` is injectable so the rules behind it can be tested;
    /// the app always uses the real (false) value.
    public init(runtimeShipped: Bool = AIProductionTransport.liveInferenceShipped) {
        self.runtimeShipped = runtimeShipped
    }

    public var isRuntimeShipped: Bool { runtimeShipped }
    public var isCloudAIEnabled: Bool { lock.withLock { enabled } }
    public var cancelledTasks: Int { lock.withLock { cancelledCount } }

    /// Off cancels every registered AI task; Mail is unaffected.
    public func setCloudAIEnabled(_ on: Bool) {
        let doomed: [@Sendable () -> Void] = lock.withLock {
            enabled = on
            guard !on else { return [] }
            let all = Array(tasks.values)
            cancelledCount += all.count
            tasks.removeAll()
            return all
        }
        for cancel in doomed { cancel() }
    }

    /// Registers in-flight AI work; nil (nothing registered) when it could not run.
    public func register(cancel: @escaping @Sendable () -> Void) -> TaskToken? {
        lock.withLock {
            guard runtimeShipped, enabled else { return nil }
            let token = TaskToken(id: UUID())
            tasks[token] = cancel
            return token
        }
    }

    public func finish(_ token: TaskToken) { _ = lock.withLock { tasks.removeValue(forKey: token) } }

    /// nil = may proceed to the next check. Pure policy: no I/O.
    public func refusal(for request: AIRequest) -> AIFailure? {
        guard runtimeShipped else { return .runtimeNotShipped }
        guard lock.withLock({ enabled }) else { return .aiDisabled }
        return Self.destinationRefusal(request)
    }

    /// The destination rules, separately testable.
    public static func destinationRefusal(_ request: AIRequest) -> AIFailure? {
        let host = request.profile.endpoint.host
        guard isPlausibleHost(host) else { return .invalidEndpoint }
        if isMailHost(host) { return .mailHostRefused }
        guard request.credential == request.profile.credentialReference else { return .credentialMismatch }
        return nil
    }

    public static func isMailHost(_ host: String) -> Bool {
        let h = AIEndpoint.normalized(host)
        if mailHostPrefixes.contains(where: { h.hasPrefix($0) }) { return true }
        return mailHostSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// A bare DNS name: no scheme, path, port, user-info or whitespace; not
    /// loopback or a link-local literal (a key is never sent to a local service).
    public static func isPlausibleHost(_ host: String) -> Bool {
        let h = AIEndpoint.normalized(host)
        guard !h.isEmpty, h.contains("."), h.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard h.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return false }
        if h.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }  // IPv4 literal
        return true
    }

    /// Test hook: back to the fresh-install state.
    public func resetForTesting() {
        lock.withLock {
            enabled = false
            tasks = [:]
            cancelledCount = 0
        }
    }
}

// MARK: - Counters

/// Process-wide counts of AI requests. B01 reads them after exercising the
/// archive, recipe, search and capture paths: every coordinator adds to them,
/// so any AI request from any path shows up here.
public final class AIScaffoldCounters: @unchecked Sendable {
    public static let shared = AIScaffoldCounters()

    public struct Snapshot: Sendable, Equatable {
        public var submitted = 0
        public var consentPrompts = 0
        public var transportInvocations = 0
        public var refusals: [AIFailure: Int] = [:]
    }

    private let lock = NSLock()
    private var state = Snapshot()

    public init() {}

    public func snapshot() -> Snapshot { lock.withLock { state } }
    func submitted() { lock.withLock { state.submitted += 1 } }
    func prompted() { lock.withLock { state.consentPrompts += 1 } }
    func transported() { lock.withLock { state.transportInvocations += 1 } }
    func refused(_ f: AIFailure) { lock.withLock { state.refusals[f, default: 0] += 1 } }
    public func resetForTesting() { lock.withLock { state = Snapshot() } }
}
