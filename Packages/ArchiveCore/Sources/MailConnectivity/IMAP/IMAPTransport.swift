//
//  IMAPTransport.swift
//  MailConnectivity
//
//  Plan v4 V4-07: the byte transport under an IMAP session — injectable.
//
//   • Implicit TLS (port 993): `NWConnection` with TLS 1.2+ and system trust
//     evaluation for the configured host name.
//     A TLS failure is an `IMAPTLSError` (certificate refused = permanent).
//   • STARTTLS (port 143, or another port whose server answered a TLS
//     handshake in plaintext — `IMAPAccountConfiguration.startTLSFallback`):
//     the SAME TCP connection is upgraded in place.
//     Network.framework cannot add TLS to an established `NWConnection`, so
//     this mode runs over `URLSessionStreamTask`, whose
//     `startSecureConnection()` is Apple's in-place STARTTLS upgrade.
//   • Plain TCP exists only for a loopback test server (127.0.0.1 / ::1 /
//     localhost) and only when the configuration says so explicitly; a
//     session never sends credentials over it unless that same explicit
//     loopback allowance is set (see `IMAPSecurity`).
//
//  The transport never retries, never redirects and never resolves another
//  host: reconnect pacing is the adapter's, request retries the engine's.
//

import Foundation
import Network

public protocol IMAPByteTransport: AnyObject, Sendable {
    /// Bytes as they arrive; nil = the server closed the connection.
    func receive() async throws -> Data?
    /// As `receive()`, waiting at most `timeout` seconds (nil = the
    /// transport's own command timeout). IDLE waits longer than a command.
    func receive(timeout: TimeInterval?) async throws -> Data?
    func send(_ data: Data) async throws
    /// In-place TLS upgrade of this connection (STARTTLS).
    func upgradeToTLS() async throws
    /// True once the channel is TLS-protected.
    var isEncrypted: Bool { get }
    func close()
}

extension IMAPByteTransport {
    /// Transports without their own per-read deadline (test doubles) wait as `receive()`.
    public func receive(timeout: TimeInterval?) async throws -> Data? { try await receive() }
}

// MARK: - TLS failures

/// The TLS handshake with `host` failed. A certificate failure (untrusted,
/// expired, wrong host name) is permanent: retrying cannot fix it.
public struct IMAPTLSError: Error, Sendable, Equatable, LocalizedError {
    public var host: String
    /// The Security status (errSSL… / errSec…), when one was reported.
    public var status: Int32?
    public var isCertificateFailure: Bool
    public var detail: String

    public init(host: String, status: Int32?, isCertificateFailure: Bool, detail: String) {
        self.host = host; self.status = status; self.isCertificateFailure = isCertificateFailure; self.detail = detail
    }

    /// `IMAPErrorCode.certificateNotTrusted` or `.tlsHandshakeFailed`.
    public var code: String { isCertificateFailure ? IMAPErrorCode.certificateNotTrusted : IMAPErrorCode.tlsHandshakeFailed }

    public var errorDescription: String? {
        isCertificateFailure ? "The certificate of \(host) is not trusted (\(detail))."
                             : "A secure connection to \(host) could not be established (\(detail))."
    }

    /// The coded error the engine sees (permanent).
    public var providerError: MailProviderError {
        .permanent(IMAPErrorCode.coded(code, isCertificateFailure
            ? "the certificate of \(host) is not trusted (\(detail)); mailin did not connect"
            : "a secure connection to \(host) could not be established (\(detail)); mailin did not connect"))
    }
}

/// Recognises a TLS failure in Network.framework / URLSession / Security errors.
enum MailTLSFailure {
    struct Classified: Equatable { var status: Int32?; var certificate: Bool }

    /// errSSL… statuses that are about the peer's certificate, and the
    /// trust-evaluation statuses (errSecNotTrusted, …Expired, …NotValidYet,
    /// …HostNameMismatch, …Revoked).
    static let certificateStatuses: Set<Int32> = [-9807, -9808, -9812, -9813, -9814, -9815, -9825, -9826, -9827, -9828,
                                                  -9829, -9831, -9843, -67843, -67818, -67819, -67602, -67820]
    /// A connection closed or blocked mid-handshake: an ordinary connection failure.
    static let notTLSFailures: Set<Int32> = [-9803, -9805, -9806, -9816]

    static func classify(status: Int32) -> Classified? {
        if certificateStatuses.contains(status) { return Classified(status: status, certificate: true) }
        if (-9899 ... -9800).contains(status), !notTLSFailures.contains(status) { return Classified(status: status, certificate: false) }
        return nil
    }

    static func classify(_ error: Error) -> Classified? {
        if let nw = error as? NWError {
            if case .tls(let status) = nw { return classify(status: status) }
            return nil
        }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, let c = classify(underlying) { return c }
        switch ns.domain {
        case NSURLErrorDomain:
            if let s = ns.userInfo["_kCFStreamErrorCodeKey"] as? Int, let c = classify(status: Int32(truncatingIfNeeded: s)) { return c }
            switch ns.code {
            case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                return Classified(status: nil, certificate: true)
            case NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return Classified(status: nil, certificate: false)
            default: return nil
            }
        case NSOSStatusErrorDomain, "kCFStreamErrorDomainSSL", "kNWErrorDomainTLS":
            return classify(status: Int32(truncatingIfNeeded: ns.code))
        default:
            return nil
        }
    }
}

public enum IMAPSecurity: Sendable, Equatable, Codable {
    /// TLS from the first byte (port 993). The default.
    case implicitTLS
    /// Plain connect, then STARTTLS on the same connection before anything else.
    case startTLS
    /// Loopback only (an in-process test server or a local bridge on this Mac).
    /// Refused for any host that is not 127.0.0.1, ::1 or localhost.
    case plaintextLoopbackOnly
}

public struct IMAPEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var security: IMAPSecurity
    public var timeout: TimeInterval

    public init(host: String, port: UInt16, security: IMAPSecurity, timeout: TimeInterval = 60) {
        self.host = host; self.port = port; self.security = security; self.timeout = timeout
    }

    public var isLoopback: Bool { Self.isLoopback(host) }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "::1" || h == "127.0.0.1" || h.hasPrefix("127.")
    }
}

public enum IMAPTransportError: Error, Sendable, Equatable, LocalizedError {
    case connectionFailed(String)
    case closed
    case timedOut
    case plaintextRefused(String)
    case tlsUpgradeUnavailable

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let why): return "The mail server could not be reached: \(why)."
        case .closed: return "The mail server closed the connection."
        case .timedOut: return "The mail server did not answer in time."
        case .plaintextRefused(let host): return "mailin does not connect to \(host) without encryption."
        case .tlsUpgradeUnavailable: return "This connection cannot be upgraded to TLS."
        }
    }
}

/// Opens a transport for an endpoint. Tests inject their own.
public typealias IMAPTransportFactory = @Sendable (IMAPEndpoint) async throws -> any IMAPByteTransport

public enum IMAPTransports {
    /// The production factory.
    public static let system: IMAPTransportFactory = { endpoint in
        switch endpoint.security {
        case .implicitTLS:
            return try await NWIMAPTransport.connect(endpoint, tls: true)
        case .startTLS:
            return try await StreamTaskIMAPTransport.connect(endpoint)
        case .plaintextLoopbackOnly:
            guard endpoint.isLoopback else { throw IMAPTransportError.plaintextRefused(endpoint.host) }
            return try await NWIMAPTransport.connect(endpoint, tls: false)
        }
    }
}

// MARK: - Network.framework

final class NWIMAPTransport: IMAPByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mailin.imap.nw")
    private let tls: Bool
    private let timeout: TimeInterval
    private let host: String

    private init(connection: NWConnection, tls: Bool, timeout: TimeInterval, host: String) {
        self.connection = connection; self.tls = tls; self.timeout = timeout; self.host = host
    }

    /// A TLS failure is named as such (certificate or handshake); anything
    /// else is a connection failure.
    static func failure(_ error: NWError, host: String) -> Error {
        if let c = MailTLSFailure.classify(error) {
            return IMAPTLSError(host: host, status: c.status, isCertificateFailure: c.certificate, detail: error.localizedDescription)
        }
        return IMAPTransportError.connectionFailed(error.localizedDescription)
    }

    var isEncrypted: Bool { tls }

    static func connect(_ endpoint: IMAPEndpoint, tls: Bool) async throws -> NWIMAPTransport {
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, endpoint.host)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            parameters.requiredInterfaceType = .loopback
        }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw IMAPTransportError.connectionFailed("port \(endpoint.port) is not valid")
        }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        let transport = NWIMAPTransport(connection: connection, tls: tls, timeout: endpoint.timeout, host: endpoint.host)
        try await transport.start()
        return transport
    }

    private func start() async throws {
        let once = OnceFlag()
        let host = self.host
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        if once.fire() { cont.resume() }
                    case .failed(let error):
                        if once.fire() { cont.resume(throwing: Self.failure(error, host: host)) }
                    case .waiting(let error):
                        // No route / refused / certificate refused: fail instead of waiting silently.
                        if once.fire() {
                            connection.cancel()
                            cont.resume(throwing: Self.failure(error, host: host))
                        }
                    case .cancelled:
                        if once.fire() { cont.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                    if once.fire() { connection.cancel(); cont.resume(throwing: IMAPTransportError.timedOut) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    func receive() async throws -> Data? { try await receive(timeout: nil) }

    func receive(timeout: TimeInterval?) async throws -> Data? {
        let once = OnceFlag()
        let host = self.host
        let wait = timeout ?? self.timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    guard once.fire() else { return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if let error { cont.resume(throwing: Self.failure(error, host: host)); return }
                    if isComplete { cont.resume(returning: nil); return }
                    cont.resume(returning: Data())
                }
                queue.asyncAfter(deadline: .now() + wait) { [connection] in
                    if once.fire() { connection.cancel(); cont.resume(throwing: IMAPTransportError.timedOut) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    /// Bounded like a read: a server that stops reading (full socket
    /// buffers) ends the send with `.timedOut`; cancelling the task closes
    /// the connection, which completes the pending send.
    func send(_ data: Data) async throws {
        let once = OnceFlag()
        let host = self.host
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    guard once.fire() else { return }
                    if let error { cont.resume(throwing: Self.failure(error, host: host)) } else { cont.resume() }
                })
                queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                    if once.fire() { connection.cancel(); cont.resume(throwing: IMAPTransportError.timedOut) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    func upgradeToTLS() async throws { throw IMAPTransportError.tlsUpgradeUnavailable }

    func close() { connection.cancel() }
}

/// Resumes a continuation exactly once across racing callbacks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { if fired { return false }; fired = true; return true } }
}

// MARK: - STARTTLS over URLSessionStreamTask

final class StreamTaskIMAPTransport: IMAPByteTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let timeout: TimeInterval
    private let host: String
    private let lock = NSLock()
    private var secured = false

    private init(session: URLSession, task: URLSessionStreamTask, timeout: TimeInterval, host: String) {
        self.session = session; self.task = task; self.timeout = timeout; self.host = host
    }

    /// After STARTTLS a refused certificate surfaces on the next read or write.
    static func failure(_ error: Error, host: String) -> Error {
        if let c = MailTLSFailure.classify(error) {
            return IMAPTLSError(host: host, status: c.status, isCertificateFailure: c.certificate, detail: error.localizedDescription)
        }
        if let e = error as? URLError, e.code == .timedOut { return IMAPTransportError.timedOut }
        return IMAPTransportError.connectionFailed(error.localizedDescription)
    }

    static func connect(_ endpoint: IMAPEndpoint) async throws -> StreamTaskIMAPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        let task = session.streamTask(withHostName: endpoint.host, port: Int(endpoint.port))
        task.resume()
        return StreamTaskIMAPTransport(session: session, task: task, timeout: endpoint.timeout, host: endpoint.host)
    }

    var isEncrypted: Bool { lock.withLock { secured } }

    func receive() async throws -> Data? { try await receive(timeout: nil) }

    func receive(timeout: TimeInterval?) async throws -> Data? {
        do {
            let (data, atEOF) = try await withTaskCancellationHandler {
                try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: timeout ?? self.timeout)
            } onCancel: { [task] in task.cancel() }
            if let data, !data.isEmpty { return data }
            return atEOF ? nil : Data()
        } catch {
            throw Self.failure(error, host: host)
        }
    }

    func send(_ data: Data) async throws {
        do {
            try await withTaskCancellationHandler {
                try await task.write(data, timeout: timeout)
            } onCancel: { [task] in task.cancel() }
        } catch {
            throw Self.failure(error, host: host)
        }
    }

    func upgradeToTLS() async throws {
        // Only called after the server's tagged OK to STARTTLS; no bytes are
        // pending in either direction at that point (RFC 9051 §6.2.1).
        task.startSecureConnection()
        lock.withLock { secured = true }
    }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }
}
