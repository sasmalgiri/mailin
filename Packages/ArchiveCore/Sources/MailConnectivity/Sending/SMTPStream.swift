//
//  SMTPStream.swift
//  MailConnectivity
//
//  Plan v4 V4-10 (§3 A11): the byte stream under SMTP. The old client
//  answered STARTTLS by opening a NEW TLS connection (so the server's
//  plaintext session and the TLS one were different sessions) and went on to
//  AUTH PLAIN in the clear when STARTTLS was missing. Here STARTTLS upgrades
//  the SAME TCP connection (`URLSessionStreamTask.startSecureConnection`),
//  with the system's certificate and host-name evaluation for the host the
//  stream was opened to — the session has no delegate, so there is no code
//  path that can accept an untrusted certificate.
//

import Foundation

public protocol SMTPByteStream: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// Some bytes; empty = the server closed the connection.
    func read() async throws -> Data
    /// Upgrades THIS connection to TLS (certificate and host name validated).
    func startTLS() async throws
    var isTLS: Bool { get }
    func close()
}

public protocol SMTPConnector: Sendable {
    /// Opens the TCP connection (TLS from the first byte when `implicitTLS`, port 465).
    func connect(host: String, port: Int, implicitTLS: Bool) async throws -> any SMTPByteStream
}

public enum SMTPStreamError: LocalizedError, Equatable {
    case closed
    case tlsHandshakeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "The mail server closed the connection."
        case .tlsHandshakeFailed(let why): return "A secure connection could not be established: \(why)."
        }
    }
}

public struct URLSessionSMTPConnector: SMTPConnector {
    public init() {}
    public func connect(host: String, port: Int, implicitTLS: Bool) async throws -> any SMTPByteStream {
        URLSessionSMTPStream(host: host, port: port, implicitTLS: implicitTLS)
    }
}

public final class URLSessionSMTPStream: SMTPByteStream, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let lock = NSLock()
    private var tls = false
    private var closed = false

    public init(host: String, port: Int, implicitTLS: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // Deadlines are the SMTP client's; the session must not cut a long DATA reply short.
        configuration.timeoutIntervalForRequest = 7 * 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: host, port: port)
        if implicitTLS {
            task.startSecureConnection()
            tls = true
        }
        task.resume()
    }

    public var isTLS: Bool { lock.withLock { tls } }

    public func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await task.write(data, timeout: 0)
        } onCancel: { [self] in close() }
    }

    public func read() async throws -> Data {
        try await withTaskCancellationHandler {
            let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: 0)
            if let data, !data.isEmpty { return data }
            if atEOF { return Data() }
            return Data()
        } onCancel: { [self] in close() }
    }

    public func startTLS() async throws {
        // Pending reads/writes complete first, then TLS is negotiated on this
        // socket. A failed handshake (untrusted or wrong-host certificate)
        // surfaces as an error on the next read or write.
        task.startSecureConnection()
        markTLS()
    }

    private func markTLS() { lock.withLock { tls = true } }

    public func close() {
        let first = lock.withLock { () -> Bool in
            let was = closed
            closed = true
            return !was
        }
        guard first else { return }
        task.cancel()
        session.invalidateAndCancel()
    }

    deinit { close() }
}

/// Races `body` against a deadline; on expiry `onTimeout` runs (it closes the
/// stream, which ends the blocked read) and `SMTPDeadlineExceeded` is thrown.
struct SMTPDeadlineExceeded: Error {}

func withSMTPDeadline<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void,
                                   _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw SMTPDeadlineExceeded() }
        guard let value = first else {
            onTimeout()
            throw SMTPDeadlineExceeded()
        }
        return value
    }
}
