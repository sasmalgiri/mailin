//
//  AIProviderContracts.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-01 (§8.4, §12.2, §13.2–13.3): the provider, profile, request
//  and result contracts a FUTURE bring-your-own-key runtime will use.
//
//  This release ships scaffolding only. There is no network code anywhere in
//  this folder (no URL loading, no sockets): the one production transport,
//  `UnavailableAITransport`, refuses every request, and
//  `AIProductionTransport.liveInferenceShipped` is false. Nothing in the app's
//  primary journey calls the coordinator. A saved key is not an AI feature.
//
//  Design rules carried from §12.2 / §13:
//   - A request is an IMMUTABLE snapshot: provider, endpoint, model, the
//     credential reference, the exact payload (and its hash), the sources and
//     the cost estimate are frozen before consent is asked, so changing the
//     selected provider while a consent sheet is open cannot redirect a key
//     or a payload.
//   - A result always names the engine that ACTUALLY produced it (or none),
//     and is one of success / partial / error / cancelled — a stream cut short
//     is partial, never success.
//   - Models are profile data, never a hard-coded list: capability discovery
//     stays replaceable (§8.4 "do not promise a specific model").
//

import CryptoKit
import Foundation

// MARK: - Provider and endpoint

/// The provider family of an AI profile. A customer-managed endpoint is its
/// own family: an arbitrary URL is not automatically compatible (§13.2).
public enum AIProviderKind: String, Sendable, Codable, CaseIterable {
    case anthropic
    case openAI
    case customerManaged
}

/// Where a profile's requests go, and who operates it. One host per profile:
/// a redirect or a tool destination elsewhere is a different endpoint.
public struct AIEndpoint: Sendable, Hashable, Codable {
    public enum Ownership: String, Sendable, Codable, CaseIterable {
        /// The provider's own API host (the customer's account at that provider).
        case providerOperated
        /// An endpoint the customer runs or contracts for (advanced, §13.2).
        case customerManaged
    }

    /// Lower-cased, trailing dots removed.
    public let host: String
    public let ownership: Ownership

    public init(host: String, ownership: Ownership) {
        self.host = AIEndpoint.normalized(host)
        self.ownership = ownership
    }

    public static func normalized(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}

/// What a profile's credential is: never the secret itself. Codable so a
/// request record or ledger entry can name it; the Keychain item is found by
/// all three fields, so a reference to another provider or host finds nothing.
public struct AICredentialReference: Sendable, Hashable, Codable {
    public let profileID: UUID
    public let provider: AIProviderKind
    public let endpointHost: String

    public init(profileID: UUID, provider: AIProviderKind, endpointHost: String) {
        self.profileID = profileID
        self.provider = provider
        self.endpointHost = AIEndpoint.normalized(endpointHost)
    }

    /// The Keychain account attribute: `<profile UUID>/<provider>/<host>`.
    /// Account-less: no user name, no e-mail address.
    public var keychainAccount: String { "\(profileID.uuidString)/\(provider.rawValue)/\(endpointHost)" }
}

/// One configured provider: provider family, endpoint, model. No secret.
public struct AIProviderProfile: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var provider: AIProviderKind
    public var endpoint: AIEndpoint
    /// The model the customer chose, as the provider names it. Validated by a
    /// future runtime against the provider's own model list (§13.2).
    public var modelID: String
    public var label: String

    public init(id: UUID = UUID(), provider: AIProviderKind, endpoint: AIEndpoint, modelID: String, label: String = "") {
        self.id = id
        self.provider = provider
        self.endpoint = endpoint
        self.modelID = modelID
        self.label = label
    }

    public var credentialReference: AICredentialReference {
        AICredentialReference(profileID: id, provider: provider, endpointHost: endpoint.host)
    }
}

// MARK: - Secret

/// A key read from the Keychain for exactly one transport call. Not Codable;
/// every textual form is redacted, so it cannot reach a log, a preference,
/// an export or a diagnostic by being printed or encoded.
public struct AISecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let bytes: Data

    public init(_ bytes: Data) { self.bytes = bytes }

    public var description: String { "<redacted AI key>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// MARK: - Request

public enum AIPurpose: String, Sendable, Codable, CaseIterable {
    case question, summary, translation, classification, draft
}

/// Where a source item came from. Source policy (§13.8) decides per origin.
public enum AISourceOrigin: String, Sendable, Codable, CaseIterable {
    case fileImport, gmail, microsoftGraph, imap, unknown
}

public enum AIDataType: String, Sendable, Codable, CaseIterable {
    case headers, messageBody, attachmentText, attachmentImage
}

public struct AISourceItem: Sendable, Hashable, Codable {
    public let messageID: UUID
    public let origin: AISourceOrigin
    public init(messageID: UUID, origin: AISourceOrigin) {
        self.messageID = messageID
        self.origin = origin
    }
}

/// The exact selection a request covers.
public struct AISourceSelection: Sendable, Hashable, Codable {
    public let items: [AISourceItem]
    public let dataTypes: Set<AIDataType>

    public init(items: [AISourceItem], dataTypes: Set<AIDataType>) {
        self.items = items
        self.dataTypes = dataTypes
    }

    /// Order-independent fingerprint of the items and data types: a grant for
    /// one selection cannot cover another.
    public var fingerprint: String {
        let ids = items.map { "\($0.messageID.uuidString):\($0.origin.rawValue)" }.sorted()
        let types = dataTypes.map(\.rawValue).sorted()
        let text = (ids + ["|"] + types).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What started a request. Automation needs its own grant (B04).
public enum AITrigger: Sendable, Hashable, Codable {
    case userAction
    case automation(ruleID: UUID)
}

/// The immutable snapshot of one AI request. Every field is `let`: once built,
/// nothing — a settings change, a different selected profile, a new key — can
/// alter where it goes, what it sends or which credential it uses.
public struct AIRequest: Sendable, Equatable {
    public let runID: UUID
    public let profile: AIProviderProfile
    public let credential: AICredentialReference
    public let purpose: AIPurpose
    public let trigger: AITrigger
    public let sources: AISourceSelection
    /// The exact outgoing material, inspectable before consent (§13.4).
    public let payload: Data
    public let payloadSHA256: String
    public let promptVersion: String
    public let maxOutputTokens: Int
    public let estimate: AICostEstimate
    public let createdAt: Date

    public init(runID: UUID = UUID(), profile: AIProviderProfile, purpose: AIPurpose, trigger: AITrigger = .userAction,
                sources: AISourceSelection, payload: Data, promptVersion: String, maxOutputTokens: Int,
                price: AIPriceTable?, createdAt: Date = Date()) {
        self.runID = runID
        self.profile = profile
        self.credential = profile.credentialReference
        self.purpose = purpose
        self.trigger = trigger
        self.sources = sources
        self.payload = payload
        self.payloadSHA256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        self.promptVersion = promptVersion
        self.maxOutputTokens = maxOutputTokens
        self.estimate = AICostEstimator.estimate(inputTokens: AITokenEstimator.inputTokens(payload),
                                                 maxOutputTokens: maxOutputTokens, price: price)
        self.createdAt = createdAt
    }

    /// The record a future runtime keeps: everything but the payload bytes and
    /// the secret (which the request never holds).
    public var record: AIRequestRecord {
        AIRequestRecord(runID: runID, profileID: profile.id, provider: profile.provider,
                        endpointHost: profile.endpoint.host, modelID: profile.modelID, credential: credential,
                        purpose: purpose, trigger: trigger, sourceFingerprint: sources.fingerprint,
                        sourceCount: sources.items.count, payloadSHA256: payloadSHA256,
                        promptVersion: promptVersion, estimate: estimate, createdAt: createdAt)
    }
}

/// The persisted shape of a request (§13.3 "freeze a request record").
public struct AIRequestRecord: Sendable, Equatable, Codable {
    public let runID: UUID
    public let profileID: UUID
    public let provider: AIProviderKind
    public let endpointHost: String
    public let modelID: String
    public let credential: AICredentialReference
    public let purpose: AIPurpose
    public let trigger: AITrigger
    public let sourceFingerprint: String
    public let sourceCount: Int
    public let payloadSHA256: String
    public let promptVersion: String
    public let estimate: AICostEstimate
    public let createdAt: Date
}

// MARK: - Result

/// Which engine actually produced a result. Never the requested engine when
/// another one answered, and `.none` when nothing was produced.
public enum AIEngineIdentity: Sendable, Hashable, Codable {
    case none
    case onDevice(name: String)
    case cloud(provider: AIProviderKind, modelID: String, endpointHost: String)
}

/// Why a request did not complete. Every refusal before the transport means
/// zero bytes left the device.
public enum AIFailure: Error, Sendable, Hashable, Codable {
    /// This release has no live AI runtime (SCAF-01).
    case runtimeNotShipped
    /// The production transport refuses every request in this release.
    case transportUnavailable
    case aiDisabled
    case notEntitled
    case invalidEndpoint
    /// AI never uses a mail host (§13.1, SCAF-01).
    case mailHostRefused
    case credentialMismatch
    case sourceIneligible(origin: AISourceOrigin)
    case consentDenied
    case consentPending
    case consentCancelled
    case consentRevoked
    case consentDoesNotCover
    case noCredential
    case keychain(status: Int32)
    case priceUnknown
    case budgetExceeded
    case destinationMismatch
    case provider(message: String)
    case cancelled
}

public enum AIResultStatus: Sendable, Equatable {
    case success
    /// Some output, not final (stream cut short, no terminal event, limit hit).
    case partial(reason: String)
    case error(AIFailure)
    case cancelled
}

public struct AIResult: Sendable, Equatable {
    public let runID: UUID
    public let status: AIResultStatus
    /// Provisional unless `status == .success`.
    public let text: String
    public let actualEngine: AIEngineIdentity
    public let usage: AIUsage?
    /// How many transport calls this request made (0 for every refusal).
    public let transportCalls: Int

    public init(runID: UUID, status: AIResultStatus, text: String = "", actualEngine: AIEngineIdentity = .none,
                usage: AIUsage? = nil, transportCalls: Int = 0) {
        self.runID = runID
        self.status = status
        self.text = text
        self.actualEngine = actualEngine
        self.usage = usage
        self.transportCalls = transportCalls
    }

    public static func refused(_ runID: UUID, _ failure: AIFailure) -> AIResult {
        AIResult(runID: runID, status: failure == .cancelled ? .cancelled : .error(failure))
    }
}

// MARK: - Transport

/// One complete provider response, as a future adapter parses it.
public struct AITransportResponse: Sendable, Equatable {
    public var text: String
    /// The provider sent its terminal event (stream end / stop reason).
    public var finished: Bool
    public var partialReason: String?
    public var usage: AIUsage?
    /// The model the provider SAYS answered (may differ from the requested one).
    public var engine: AIEngineIdentity

    public init(text: String, finished: Bool, partialReason: String? = nil, usage: AIUsage?, engine: AIEngineIdentity) {
        self.text = text
        self.finished = finished
        self.partialReason = partialReason
        self.usage = usage
        self.engine = engine
    }
}

/// The only way a request could leave the device. Takes the frozen request
/// (whose endpoint is the only destination) and the secret for that request.
public protocol AITransport: Sendable {
    var isAvailable: Bool { get }
    func perform(_ request: AIRequest, secret: AISecret) async throws -> AITransportResponse
}

/// The production transport in this release: refuses everything, opens nothing.
public struct UnavailableAITransport: AITransport {
    public init() {}
    public var isAvailable: Bool { false }
    public func perform(_ request: AIRequest, secret: AISecret) async throws -> AITransportResponse {
        throw AIFailure.transportUnavailable
    }
}

public enum AIProductionTransport {
    /// False in this release: there is no live inference route (§0 item 4).
    public static let liveInferenceShipped = false
    /// What the app would use. Always unavailable in this release.
    public static var current: any AITransport { UnavailableAITransport() }
}

// MARK: - Provider adapter

/// A provider adapter turns a transport response into a truthful result.
/// Future adapters (Anthropic, OpenAI, customer endpoints) add request
/// encoding and stream parsing; the state mapping below is shared.
public protocol AIProvider: Sendable {
    func run(_ request: AIRequest, secret: AISecret, transport: any AITransport) async -> AIResult
}

public struct AIProviderAdapter: AIProvider {
    public init() {}

    public func run(_ request: AIRequest, secret: AISecret, transport: any AITransport) async -> AIResult {
        do {
            let response = try await transport.perform(request, secret: secret)
            if Task.isCancelled {
                return AIResult(runID: request.runID, status: .cancelled, text: response.text,
                                actualEngine: response.engine, usage: response.usage, transportCalls: 1)
            }
            let status: AIResultStatus = response.finished
                ? .success
                : .partial(reason: response.partialReason ?? "The provider did not finish the answer.")
            return AIResult(runID: request.runID, status: status, text: response.text,
                            actualEngine: response.engine, usage: response.usage, transportCalls: 1)
        } catch is CancellationError {
            return AIResult(runID: request.runID, status: .cancelled, transportCalls: 1)
        } catch let failure as AIFailure {
            return AIResult(runID: request.runID, status: failure == .cancelled ? .cancelled : .error(failure), transportCalls: 1)
        } catch {
            return AIResult(runID: request.runID, status: .error(.provider(message: String(describing: type(of: error)))),
                            transportCalls: 1)
        }
    }
}
