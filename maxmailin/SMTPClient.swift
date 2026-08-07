#if !OFFLINE_MODE
import Foundation
import Network
import os

private final class OnceFlag: @unchecked Sendable {
    private var _done = false
    private let lock = NSLock()
    var done: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _done }
        set { lock.lock(); defer { lock.unlock() }; _done = newValue }
    }
}

struct SMTPConfig: Codable, Sendable {
    let server: String
    let port: UInt16
    let username: String
    let password: String
    let useSSL: Bool

    static let gmailDefaults = SMTPConfig(server: "smtp.gmail.com", port: 587, username: "", password: "", useSSL: false)
    static let outlookDefaults = SMTPConfig(server: "smtp.office365.com", port: 587, username: "", password: "", useSSL: false)
    static let yahooDefaults = SMTPConfig(server: "smtp.mail.yahoo.com", port: 587, username: "", password: "", useSSL: false)
}

struct EmailAttachmentData: Sendable {
    let filename: String
    let mimeType: String
    let data: Data
}

struct OutgoingEmail: Sendable {
    let from: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let isHTML: Bool
    let attachments: [EmailAttachmentData]
    let inReplyTo: String?
    let references: String?
    var includeXMailer: Bool = true
}

actor SMTPClient {
    private let config: SMTPConfig
    private var connection: NWConnection?
    private let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "SMTP")

    enum SMTPError: LocalizedError {
        case connectionFailed(String)
        case authenticationFailed
        case sendFailed(String)
        case tlsFailed
        case timeout
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let msg): return "Connection failed: \(msg)"
            case .authenticationFailed: return "Authentication failed. Check your credentials."
            case .sendFailed(let msg): return "Failed to send: \(msg)"
            case .tlsFailed: return "TLS handshake failed"
            case .timeout: return "Connection timed out"
            case .invalidResponse(let msg): return "Invalid server response: \(msg)"
            }
        }
    }

    init(config: SMTPConfig) {
        self.config = config
    }

    func send(_ email: OutgoingEmail) async throws {
        try await connect()
        defer { disconnect() }

        try await readGreeting()

        let capabilities = try await sendEHLO()

        if !config.useSSL && capabilities.contains(where: { $0.contains("STARTTLS") }) {
            try await startTLS()
            _ = try await sendEHLO()
        }

        try await authenticate()
        try await sendMailFrom(email.from)

        let allRecipients = email.to + email.cc + email.bcc
        for recipient in allRecipients {
            try await sendRcptTo(recipient)
        }

        try await sendData(buildMIMEMessage(email))
        try await sendQuit()
    }

    // MARK: - Connection

    private func connect() async throws {
        let params: NWParameters
        if config.useSSL {
            params = .tls
        } else {
            params = .tcp
        }

        let host = NWEndpoint.Host(config.server)
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            throw SMTPError.connectionFailed("Invalid port: \(config.port)")
        }
        let conn = NWConnection(host: host, port: port, using: params)

        connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let flag = OnceFlag()
            conn.stateUpdateHandler = { state in
                guard !flag.done else { return }
                switch state {
                case .ready:
                    flag.done = true
                    continuation.resume()
                case .failed(let error):
                    flag.done = true
                    continuation.resume(throwing: SMTPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    flag.done = true
                    continuation.resume(throwing: SMTPError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        logger.info("Connected to \(self.config.server):\(self.config.port)")
    }

    private func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - SMTP Commands

    private func readGreeting() async throws {
        let response = try await readResponse()
        guard response.hasPrefix("220") else {
            throw SMTPError.invalidResponse(response)
        }
    }

    private func sendEHLO() async throws -> [String] {
        let hostname = ProcessInfo.processInfo.hostName.isEmpty ? "mailin.local" : ProcessInfo.processInfo.hostName
        try await sendCommand("EHLO \(hostname)")
        let response = try await readMultilineResponse()
        guard response.first?.hasPrefix("250") == true else {
            throw SMTPError.invalidResponse(response.joined(separator: "\n"))
        }
        return response
    }

    private func startTLS() async throws {
        try await sendCommand("STARTTLS")
        let response = try await readResponse()
        guard response.hasPrefix("220") else {
            throw SMTPError.tlsFailed
        }

        guard let conn = connection else { throw SMTPError.tlsFailed }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        guard let tlsPort = NWEndpoint.Port(rawValue: config.port) else {
            throw SMTPError.connectionFailed("Invalid port: \(config.port)")
        }
        let newConn = NWConnection(host: NWEndpoint.Host(config.server),
                                    port: tlsPort,
                                    using: params)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let flag = OnceFlag()
            newConn.stateUpdateHandler = { state in
                guard !flag.done else { return }
                switch state {
                case .ready:
                    flag.done = true
                    continuation.resume()
                case .failed(let error):
                    flag.done = true
                    continuation.resume(throwing: SMTPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    flag.done = true
                    continuation.resume(throwing: SMTPError.connectionFailed("TLS connection cancelled"))
                default:
                    break
                }
            }
            newConn.start(queue: .global(qos: .userInitiated))
        }

        conn.cancel()
        connection = newConn
        logger.info("TLS upgrade complete")
    }

    private func authenticate() async throws {
        let credentials = "\0\(config.username)\0\(config.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()

        try await sendCommand("AUTH PLAIN \(encoded)")
        let response = try await readResponse()
        guard response.hasPrefix("235") else {
            throw SMTPError.authenticationFailed
        }
        logger.info("Authenticated as \(self.config.username)")
    }

    private func sendMailFrom(_ address: String) async throws {
        let cleanAddress = extractEmail(address)
        try await sendCommand("MAIL FROM:<\(cleanAddress)>")
        let response = try await readResponse()
        guard response.hasPrefix("250") else {
            throw SMTPError.sendFailed("MAIL FROM rejected: \(response)")
        }
    }

    private func sendRcptTo(_ address: String) async throws {
        let cleanAddress = extractEmail(address)
        try await sendCommand("RCPT TO:<\(cleanAddress)>")
        let response = try await readResponse()
        guard response.hasPrefix("250") || response.hasPrefix("251") else {
            throw SMTPError.sendFailed("RCPT TO rejected for \(cleanAddress): \(response)")
        }
    }

    private func sendData(_ message: String) async throws {
        try await sendCommand("DATA")
        let response = try await readResponse()
        guard response.hasPrefix("354") else {
            throw SMTPError.sendFailed("DATA command rejected: \(response)")
        }

        try await sendRaw(message + "\r\n.\r\n")
        let finalResponse = try await readResponse()
        guard finalResponse.hasPrefix("250") else {
            throw SMTPError.sendFailed("Message rejected: \(finalResponse)")
        }
        logger.info("Message sent successfully")
    }

    private func sendQuit() async throws {
        try await sendCommand("QUIT")
        _ = try? await readResponse()
    }

    // MARK: - MIME Message Building

    private func buildMIMEMessage(_ email: OutgoingEmail) -> String {
        let boundary = "mailin-\(UUID().uuidString)"
        let date = RFC2822DateFormatter.string(from: Date())
        let messageID = "<\(UUID().uuidString)@mailin.local>"

        var headers = [String]()
        headers.append("From: \(email.from)")
        headers.append("To: \(email.to.joined(separator: ", "))")
        if !email.cc.isEmpty {
            headers.append("Cc: \(email.cc.joined(separator: ", "))")
        }
        headers.append("Subject: \(encodeMIMEHeader(email.subject))")
        headers.append("Date: \(date)")
        headers.append("Message-ID: \(messageID)")
        headers.append("MIME-Version: 1.0")
        if email.includeXMailer {
            headers.append("X-Mailer: mailin/1.0")
        }

        if let inReplyTo = email.inReplyTo {
            headers.append("In-Reply-To: \(inReplyTo)")
        }
        if let references = email.references {
            headers.append("References: \(references)")
        }

        if email.attachments.isEmpty {
            headers.append("Content-Type: text/\(email.isHTML ? "html" : "plain"); charset=utf-8")
            headers.append("Content-Transfer-Encoding: quoted-printable")
            return headers.joined(separator: "\r\n") + "\r\n\r\n" + quotedPrintableEncode(email.body)
        } else {
            headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            var message = headers.joined(separator: "\r\n") + "\r\n\r\n"

            message += "--\(boundary)\r\n"
            message += "Content-Type: text/\(email.isHTML ? "html" : "plain"); charset=utf-8\r\n"
            message += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
            message += quotedPrintableEncode(email.body) + "\r\n"

            for attachment in email.attachments {
                message += "--\(boundary)\r\n"
                message += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
                message += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
                message += "Content-Transfer-Encoding: base64\r\n\r\n"
                message += attachment.data.base64EncodedString(options: .lineLength76Characters) + "\r\n"
            }

            message += "--\(boundary)--\r\n"
            return message
        }
    }

    private func encodeMIMEHeader(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII }) { return text }
        let encoded = Data(text.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    private func quotedPrintableEncode(_ text: String) -> String {
        var result = ""
        var lineLength = 0
        for char in text {
            let s = String(char)
            if char == "\n" {
                result += "\r\n"
                lineLength = 0
            } else if char == "\r" {
                continue
            } else if char.isASCII && char != "=", let ascii = char.asciiValue, ascii >= 32 && ascii <= 126 {
                if lineLength >= 75 {
                    result += "=\r\n"
                    lineLength = 0
                }
                result += s
                lineLength += 1
            } else {
                for byte in s.utf8 {
                    if lineLength >= 73 {
                        result += "=\r\n"
                        lineLength = 0
                    }
                    result += String(format: "=%02X", byte)
                    lineLength += 3
                }
            }
        }
        return result
    }

    // MARK: - Network I/O

    private func sendCommand(_ command: String) async throws {
        try await sendRaw(command + "\r\n")
    }

    private func sendRaw(_ text: String) async throws {
        guard let conn = connection else {
            throw SMTPError.connectionFailed("No connection")
        }
        let data = Data(text.utf8)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readResponse() async throws -> String {
        guard let conn = connection else {
            throw SMTPError.connectionFailed("No connection")
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data = content, let response = String(data: data, encoding: .utf8) {
                            continuation.resume(returning: response.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            continuation.resume(throwing: SMTPError.timeout)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw SMTPError.timeout
            }
            guard let result = try await group.next() else { throw SMTPError.timeout }
            group.cancelAll()
            return result
        }
    }

    private func readMultilineResponse() async throws -> [String] {
        var lines = [String]()
        var done = false

        while !done {
            let response = try await readResponse()
            let responseLines = response.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            for line in responseLines {
                lines.append(line)
                if line.count >= 4 && line[line.index(line.startIndex, offsetBy: 3)] == " " {
                    done = true
                }
            }
        }
        return lines
    }

    // MARK: - Helpers

    private func extractEmail(_ address: String) -> String {
        if let start = address.firstIndex(of: "<"),
           let end = address.firstIndex(of: ">") {
            return String(address[address.index(after: start)..<end])
        }
        return address.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - RFC 2822 Date Formatter

private enum RFC2822DateFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

#endif
