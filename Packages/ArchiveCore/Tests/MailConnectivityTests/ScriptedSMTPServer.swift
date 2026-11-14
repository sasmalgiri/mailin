//
//  ScriptedSMTPServer.swift
//  MailConnectivityTests
//
//  An in-process SMTP server on 127.0.0.1 (POSIX sockets, one thread),
//  scripted per connection, recording every byte the client sent. Plus a
//  connector whose STARTTLS is simulated on the same connection (the server
//  cannot present a trusted certificate in-process), so the same-connection
//  upgrade and a refused certificate can be driven; one test also runs the
//  REAL URLSession stream into a real failed TLS handshake. No external network.
//

import Foundation
@testable import MailConnectivity

/// How the standard scripted server behaves.
struct SMTPServerBehavior {
    enum AfterDot { case reply(String), stall(TimeInterval), close }
    enum OnQuit { case reply, close, garbage }
    var greeting = "220 mail.test ESMTP ready"
    var offerSTARTTLS = true
    /// Send the EHLO reply in fragments, breaking inside lines.
    var splitEHLO = false
    var extensions = ["8BITMIME", "SMTPUTF8", "SIZE 50000000", "AUTH PLAIN LOGIN XOAUTH2"]
    var mailReply = "250 2.1.0 Sender OK"
    var rcptReply: (String) -> String = { _ in "250 2.1.5 Recipient OK" }
    var stallOnRCPT: TimeInterval? = nil
    var afterDot: AfterDot = .reply("250 2.0.0 OK queued as Q1")
    var onQuit: OnQuit = .reply
    /// Answer STARTTLS with 220, then send non-TLS junk (a real handshake must fail).
    var junkAfterSTARTTLS = false
}

final class ScriptedSMTPServer: @unchecked Sendable {
    final class Connection {
        let fd: Int32
        let index: Int
        unowned let server: ScriptedSMTPServer
        var buffer = Data()

        init(fd: Int32, index: Int, server: ScriptedSMTPServer) { self.fd = fd; self.index = index; self.server = server }

        func send(_ text: String) { send(Data(text.utf8)) }
        func send(_ data: Data) {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
        func reply(_ line: String) { send(line + "\r\n") }

        /// Raw bytes as they arrive (recorded); nil = closed / timed out.
        func receive() -> Data? {
            var bytes = [UInt8](repeating: 0, count: 65536)
            let n = recv(fd, &bytes, bytes.count, 0)
            guard n > 0 else { return nil }
            let d = Data(bytes[0..<n])
            server.record(raw: d, connection: index)
            return d
        }

        func readLine() -> String? {
            while true {
                if let r = buffer.range(of: Data("\r\n".utf8)) {
                    let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                    buffer = Data(buffer[r.upperBound...])
                    server.record(line: line, connection: index)
                    return line
                }
                guard let more = receive() else { return nil }
                buffer.append(more)
            }
        }

        /// DATA content up to the lone "." line, dot-unstuffed (RFC 5321 §4.5.2).
        func readMessage() -> (message: Data, wire: Data)? {
            var message = Data()
            var wire = Data()
            let crlf = Data("\r\n".utf8)
            while true {
                while buffer.range(of: crlf) == nil {
                    guard let more = receive() else { return nil }
                    buffer.append(more)
                }
                let r = buffer.range(of: crlf)!
                let line = Data(buffer[buffer.startIndex..<r.lowerBound])
                buffer = Data(buffer[r.upperBound...])
                wire.append(line); wire.append(crlf)
                if line == Data(".".utf8) { return (message, wire) }
                message.append(line.first == 0x2E ? Data(line.dropFirst()) : line)
                message.append(crlf)
            }
        }

        func close() { Darwin.close(fd) }
    }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private let script: (Connection) -> Void
    private var _connections = 0
    private var _lines: [Int: [String]] = [:]
    private var _raw: [Int: Data] = [:]
    private var _messages: [Data] = []
    private var _wireMessages: [Data] = []
    private let done = DispatchSemaphore(value: 0)

    var connections: Int { lock.withLock { _connections } }
    func lines(_ connection: Int) -> [String] { lock.withLock { _lines[connection] ?? [] } }
    var allLines: [String] { lock.withLock { _lines.keys.sorted().flatMap { _lines[$0]! } } }
    var allRaw: Data { lock.withLock { _raw.keys.sorted().reduce(into: Data()) { $0.append(_raw[$1]!) } } }
    var messages: [Data] { lock.withLock { _messages } }
    var wireMessages: [Data] { lock.withLock { _wireMessages } }

    func record(line: String, connection: Int) { lock.withLock { _lines[connection, default: []].append(line) } }
    func record(raw: Data, connection: Int) { lock.withLock { _raw[connection, default: Data()].append(raw) } }
    func record(message: Data, wire: Data) { lock.withLock { _messages.append(message); _wireMessages.append(wire) } }

    /// `behavior(n)` is used for the n-th connection (0-based).
    convenience init(_ behavior: @escaping (Int) -> SMTPServerBehavior) throws {
        try self.init(script: { conn in ScriptedSMTPServer.standard(conn, behavior(conn.index)) })
    }

    convenience init(behavior: SMTPServerBehavior = SMTPServerBehavior()) throws {
        try self.init({ _ in behavior })
    }

    init(script: @escaping (Connection) -> Void) throws {
        self.script = script
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "ScriptedSMTPServer", code: 1) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw NSError(domain: "ScriptedSMTPServer", code: 2) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        listenFD = fd
        let thread = Thread { [unowned self] in self.acceptLoop() }
        thread.start()
    }

    private func acceptLoop() {
        defer { done.signal() }
        var index = 0
        while !lock.withLock({ stopped }) {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            var tv = timeval(tv_sec: 8, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { _connections += 1 }
            let conn = Connection(fd: client, index: index, server: self)
            index += 1
            script(conn)
            conn.close()
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        done.wait()
        Darwin.close(listenFD)
    }

    // MARK: The standard script

    static func standard(_ c: Connection, _ b: SMTPServerBehavior) {
        c.reply(b.greeting)
        var secured = false
        while let line = c.readLine() {
            let upper = line.uppercased()
            if upper.hasPrefix("EHLO") {
                var caps = ["mail.test greets you"]
                if b.offerSTARTTLS && !secured { caps.append("STARTTLS") }
                caps += b.extensions
                let text = caps.enumerated().map { i, cap in (i == caps.count - 1 ? "250 " : "250-") + cap + "\r\n" }.joined()
                if b.splitEHLO {
                    // Fragments that break inside a line and inside the CRLF.
                    var rest = Substring(text)
                    for size in [7, 3, 11, 1, 5] where !rest.isEmpty {
                        let piece = rest.prefix(size); rest = rest.dropFirst(piece.count)
                        c.send(String(piece)); usleep(30_000)
                    }
                    if !rest.isEmpty { c.send(String(rest)) }
                } else {
                    c.send(text)
                }
            } else if upper == "STARTTLS" {
                c.reply("220 2.0.0 Ready to start TLS")
                if b.junkAfterSTARTTLS {
                    _ = c.receive()            // the client's TLS ClientHello
                    c.send("this is not a TLS server\r\n")
                    return
                }
                secured = true                 // simulated: the connector's TLS is a pass-through
            } else if upper.hasPrefix("AUTH LOGIN") {
                c.reply("334 VXNlcm5hbWU6")
                guard c.readLine() != nil else { return }
                c.reply("334 UGFzc3dvcmQ6")
                guard c.readLine() != nil else { return }
                c.reply("235 2.7.0 Authentication successful")
            } else if upper.hasPrefix("AUTH") {
                c.reply("235 2.7.0 Authentication successful")
            } else if upper.hasPrefix("MAIL FROM:") {
                c.reply(b.mailReply)
            } else if upper.hasPrefix("RCPT TO:") {
                if let stall = b.stallOnRCPT { Thread.sleep(forTimeInterval: stall); return }
                let addr = String(line.dropFirst("RCPT TO:<".count).dropLast())
                c.reply(b.rcptReply(addr))
            } else if upper == "DATA" {
                c.reply("354 Start mail input; end with <CRLF>.<CRLF>")
                guard let (message, wire) = c.readMessage() else { return }
                c.server.record(message: message, wire: wire)
                switch b.afterDot {
                case .reply(let r): c.reply(r)
                case .stall(let t): Thread.sleep(forTimeInterval: t); return
                case .close: return
                }
            } else if upper == "QUIT" {
                switch b.onQuit {
                case .reply: c.reply("221 2.0.0 Bye")
                case .close: break
                case .garbage: c.send("\u{1}\u{2}garbage")
                }
                return
            } else if upper == "RSET" {
                c.reply("250 2.0.0 OK")
            } else {
                c.reply("500 5.5.2 Unrecognised command")
            }
        }
    }
}

/// Real TCP via URLSession; STARTTLS simulated on the SAME stream object.
final class SimulatedTLSConnector: SMTPConnector, @unchecked Sendable {
    final class Stream: SMTPByteStream, @unchecked Sendable {
        let inner: any SMTPByteStream
        let failure: Error?
        private let lock = NSLock()
        private var secured = false
        private(set) var startTLSCalls = 0
        init(inner: any SMTPByteStream, failure: Error?) { self.inner = inner; self.failure = failure }
        func write(_ data: Data) async throws { try await inner.write(data) }
        func read() async throws -> Data { try await inner.read() }
        func startTLS() async throws {
            lock.withLock { startTLSCalls += 1 }
            if let failure { throw failure }
            lock.withLock { secured = true }
        }
        var isTLS: Bool { lock.withLock { secured } }
        func close() { inner.close() }
    }

    let certificateFailure: Error?
    private let lock = NSLock()
    private var _streams: [Stream] = []
    var streams: [Stream] { lock.withLock { _streams } }

    init(certificateFailure: Error? = nil) { self.certificateFailure = certificateFailure }

    func connect(host: String, port: Int, implicitTLS: Bool) async throws -> any SMTPByteStream {
        let s = Stream(inner: URLSessionSMTPStream(host: host, port: port, implicitTLS: false), failure: certificateFailure)
        lock.withLock { _streams.append(s) }
        return s
    }
}
