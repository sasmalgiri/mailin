//
//  IMAPTransport.swift
//  MailConnectivity
//
//  Plan v4 V4-07: the byte transport under an IMAP session — injectable.
//
//   • Implicit TLS (port 993): `NWConnection` with TLS 1.2+ and system trust
//     evaluation for the configured host name.
//   • STARTTLS (port 143): the SAME TCP connection is upgraded in place.
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
    func send(_ data: Data) async throws
    /// In-place TLS upgrade of this connection (STARTTLS).
    func upgradeToTLS() async throws
    /// True once the channel is TLS-protected.
    var isEncrypted: Bool { get }
    func close()
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

    private init(connection: NWConnection, tls: Bool, timeout: TimeInterval) {
        self.connection = connection; self.tls = tls; self.timeout = timeout
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
        let transport = NWIMAPTransport(connection: connection, tls: tls, timeout: endpoint.timeout)
        try await transport.start()
        return transport
    }

    private func start() async throws {
        let once = OnceFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        if once.fire() { cont.resume() }
                    case .failed(let error):
                        if once.fire() { cont.resume(throwing: IMAPTransportError.connectionFailed(error.localizedDescription)) }
                    case .waiting(let error):
                        // No route / refused: fail instead of waiting silently.
                        if once.fire() {
                            connection.cancel()
                            cont.resume(throwing: IMAPTransportError.connectionFailed(error.localizedDescription))
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

    func receive() async throws -> Data? {
        let once = OnceFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    guard once.fire() else { return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if let error { cont.resume(throwing: IMAPTransportError.connectionFailed(error.localizedDescription)); return }
                    if isComplete { cont.resume(returning: nil); return }
                    cont.resume(returning: Data())
                }
                queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                    if once.fire() { connection.cancel(); cont.resume(throwing: IMAPTransportError.timedOut) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: IMAPTransportError.connectionFailed(error.localizedDescription)) } else { cont.resume() }
            })
        }
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
    private let lock = NSLock()
    private var secured = false

    private init(session: URLSession, task: URLSessionStreamTask, timeout: TimeInterval) {
        self.session = session; self.task = task; self.timeout = timeout
    }

    static func connect(_ endpoint: IMAPEndpoint) async throws -> StreamTaskIMAPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        let task = session.streamTask(withHostName: endpoint.host, port: Int(endpoint.port))
        task.resume()
        return StreamTaskIMAPTransport(session: session, task: task, timeout: endpoint.timeout)
    }

    var isEncrypted: Bool { lock.withLock { secured } }

    func receive() async throws -> Data? {
        do {
            let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: timeout)
            if let data, !data.isEmpty { return data }
            return atEOF ? nil : Data()
        } catch let error as URLError where error.code == .timedOut {
            throw IMAPTransportError.timedOut
        } catch {
            throw IMAPTransportError.connectionFailed(error.localizedDescription)
        }
    }

    func send(_ data: Data) async throws {
        do { try await task.write(data, timeout: timeout) } catch {
            throw IMAPTransportError.connectionFailed(error.localizedDescription)
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
