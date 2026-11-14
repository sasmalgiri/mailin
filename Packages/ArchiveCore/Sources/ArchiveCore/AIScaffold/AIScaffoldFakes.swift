//
//  AIScaffoldFakes.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-01/03: test doubles for the AI contracts. None of them opens
//  a connection: the "transport" returns a scripted answer from memory. They
//  are compiled into the module so both the package tests and the app tests
//  can use them; no production code path constructs one (asserted by
//  `AIScaffoldTests` in the app test target).
//

import Foundation
import Security

/// A scripted transport: success, partial, error, cancellation or a hang
/// until cancelled. Records every call — the request it was given and the
/// secret's bytes — so a test can prove which key went with which payload.
public final class MockAITransport: AITransport, @unchecked Sendable {
    public enum Script: Sendable {
        case success(text: String, usage: AIUsage?)
        case partial(text: String, reason: String, usage: AIUsage?)
        case failure(AIFailure)
        case cancelled
        /// Waits until the calling task is cancelled.
        case hang
        /// Answers as a different model than requested (actual-engine reporting).
        case answeredBy(modelID: String, text: String)
    }

    public struct Call: Sendable, Equatable {
        public let request: AIRequest
        public let secret: Data
    }

    private let lock = NSLock()
    private var script: Script
    private var recorded: [Call] = []

    public init(_ script: Script) { self.script = script }

    public var isAvailable: Bool { true }
    public var calls: [Call] { lock.withLock { recorded } }
    public func setScript(_ s: Script) { lock.withLock { script = s } }

    public func perform(_ request: AIRequest, secret: AISecret) async throws -> AITransportResponse {
        let current: Script = lock.withLock {
            recorded.append(Call(request: request, secret: secret.bytes))
            return script
        }
        let engine = AIEngineIdentity.cloud(provider: request.profile.provider, modelID: request.profile.modelID,
                                            endpointHost: request.profile.endpoint.host)
        switch current {
        case let .success(text, usage):
            return AITransportResponse(text: text, finished: true, usage: usage, engine: engine)
        case let .partial(text, reason, usage):
            return AITransportResponse(text: text, finished: false, partialReason: reason, usage: usage, engine: engine)
        case .failure(let f):
            throw f
        case .cancelled:
            throw CancellationError()
        case .hang:
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        case let .answeredBy(modelID, text):
            return AITransportResponse(text: text, finished: true, usage: nil,
                                       engine: .cloud(provider: request.profile.provider, modelID: modelID,
                                                      endpointHost: request.profile.endpoint.host))
        }
    }
}

/// Returns a fixed decision, optionally running `beforeAnswer` first (to
/// simulate the customer switching provider while the sheet is open).
public final class ScriptedConsentBroker: AIConsentBroker, @unchecked Sendable {
    public enum Answer: Sendable {
        case grantExactly
        case grant(AIConsentGrant)
        case deny
        case pending
        case cancel
    }

    private let lock = NSLock()
    private let answer: Answer
    private let beforeAnswer: (@Sendable (AIRequest) async -> Void)?
    private var seen: [AIRequest] = []

    public init(_ answer: Answer, beforeAnswer: (@Sendable (AIRequest) async -> Void)? = nil) {
        self.answer = answer
        self.beforeAnswer = beforeAnswer
    }

    public var askedRequests: [AIRequest] { lock.withLock { seen } }

    public func decide(_ request: AIRequest) async -> AIConsentDecision {
        lock.withLock { seen.append(request) }
        await beforeAnswer?(request)
        switch answer {
        case .grantExactly: return .granted(AIConsentGrant(approving: request))
        case .grant(let g): return .granted(g)
        case .deny: return .denied
        case .pending: return .pending
        case .cancel: return .cancelled
        }
    }
}

public struct FixedAIEntitlement: AIEntitlementGate {
    public let allowsAIWork: Bool
    public init(_ allows: Bool) { allowsAIWork = allows }
}

/// An in-memory Keychain with per-operation status injection. Records each
/// query's service so a test can prove AI keys never touch a mail service.
public final class InMemoryAISecretKeychain: AISecretKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var services: [String] = []
    public var addStatus: OSStatus?
    public var updateStatus: OSStatus?
    public var deleteStatus: OSStatus?
    public var readStatus: OSStatus?

    public init() {}

    private func key(_ q: [String: Any]) -> String {
        (q[kSecAttrService as String] as? String ?? "") + "|" + (q[kSecAttrAccount as String] as? String ?? "")
    }
    private func note(_ q: [String: Any]) { services.append(q[kSecAttrService as String] as? String ?? "") }

    public var storedSecrets: [Data] { lock.withLock { Array(items.values) } }
    public var queriedServices: [String] { lock.withLock { services } }
    public var itemKeys: [String] { lock.withLock { Array(items.keys) } }

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            note(query)
            if let readStatus { return (readStatus, nil) }
            guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }
    public func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            note(attributes)
            if let addStatus { return addStatus }
            if items[key(attributes)] != nil { return errSecDuplicateItem }
            items[key(attributes)] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    public func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        lock.withLock {
            note(query)
            if let updateStatus { return updateStatus }
            guard items[key(query)] != nil else { return errSecItemNotFound }
            items[key(query)] = changes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    public func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            note(query)
            if let deleteStatus { return deleteStatus }
            return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
