import Foundation
import Network
import SwiftUI
import os.log

private let imapLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "IMAP")

// MARK: - Configuration
struct IMAPConfig: Codable, Sendable {
    let server: String
    let port: UInt16
    let username: String
    let password: String

    static let gmailDefaults = IMAPConfig(server: "imap.gmail.com", port: 993, username: "", password: "")
    static let outlookDefaults = IMAPConfig(server: "outlook.office365.com", port: 993, username: "", password: "")
}

// MARK: - Errors
enum IMAPError: LocalizedError {
    case connectionFailed(String)
    case tlsHandshakeFailed
    case authenticationFailed(String)
    case commandFailed(command: String, response: String)
    case unexpectedResponse(String)
    case timeout
    case notConnected
    case folderNotFound(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): return "IMAP connection failed: \(detail)"
        case .tlsHandshakeFailed: return "TLS handshake failed. Check server and port."
        case .authenticationFailed(let detail): return "Authentication failed: \(detail)"
        case .commandFailed(let cmd, let resp): return "IMAP \(cmd) failed: \(resp)"
        case .unexpectedResponse(let resp): return "Unexpected server response: \(resp)"
        case .timeout: return "Connection timed out."
        case .notConnected: return "Not connected to IMAP server."
        case .folderNotFound(let name): return "Folder not found: \(name)"
        case .parseError(let detail): return "Failed to parse IMAP response: \(detail)"
        }
    }
}

// MARK: - Connection State
enum IMAPConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case authenticated
    case error(String)
}

// MARK: - Folder Info
struct IMAPFolder: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let delimiter: String
    let flags: [String]
    var messageCount: Int?
}

// MARK: - IMAP Client
@MainActor
final class IMAPClient: ObservableObject {

    @Published var connectionState: IMAPConnectionState = .disconnected
    @Published var currentFolder: String?
    @Published var folders: [IMAPFolder] = []
    @Published var fetchedEmails: [MBOXParser.RawEmail] = []
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""

    private var connection: NWConnection?
    private var config: IMAPConfig?
    private var tagCounter: Int = 0
    private var responseBuffer: String = ""

    private let readTimeout: TimeInterval = 30
    private let connectTimeout: TimeInterval = 15

    func connect(config: IMAPConfig) async throws {
        self.config = config
        connectionState = .connecting
        statusMessage = "Connecting to \(config.server):\(config.port)..."
        imapLog.info("Connecting to \(config.server):\(config.port)")

        let tlsParams = NWProtocolTLS.Options()
        let tcpParams = NWProtocolTCP.Options()
        tcpParams.connectionTimeout = Int(connectTimeout)

        let params = NWParameters(tls: tlsParams, tcp: tcpParams)
        let host = NWEndpoint.Host(config.server)
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            throw IMAPError.connectionFailed("Invalid port number: \(config.port)")
        }

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        conn.stateUpdateHandler = nil
                        cont.resume()
                    case .failed(let err):
                        conn.stateUpdateHandler = nil
                        self?.connectionState = .error(err.localizedDescription)
                        cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                    case .waiting(let err):
                        conn.stateUpdateHandler = nil
                        self?.connectionState = .error(err.localizedDescription)
                        cont.resume(throwing: IMAPError.connectionFailed("Waiting: \(err.localizedDescription)"))
                    default:
                        break
                    }
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Read server greeting
        let greeting = try await readResponse()
        guard greeting.contains("OK") else {
            throw IMAPError.unexpectedResponse(greeting)
        }
        imapLog.info("Server greeting received")

        connectionState = .connected
        statusMessage = "Connected. Authenticating..."

        // Authenticate
        let loginResp = try await sendCommand("LOGIN \"\(config.username)\" \"\(config.password)\"")
        guard loginResp.contains("OK") else {
            connectionState = .error("Authentication failed")
            throw IMAPError.authenticationFailed(loginResp)
        }

        connectionState = .authenticated
        statusMessage = "Authenticated as \(config.username)"
        imapLog.info("Authenticated successfully")
    }

    func disconnect() async {
        if connectionState == .disconnected { return }
        _ = try? await sendCommand("LOGOUT")
        connection?.cancel()
        connection = nil
        connectionState = .disconnected
        currentFolder = nil
        statusMessage = "Disconnected"
        imapLog.info("Disconnected from server")
    }

    func listFolders() async throws -> [IMAPFolder] {
        guard case .authenticated = connectionState else { throw IMAPError.notConnected }
        statusMessage = "Listing folders..."

        let response = try await sendCommand("LIST \"\" \"*\"")
        var parsed: [IMAPFolder] = []

        for line in response.components(separatedBy: "\r\n") {
            guard line.contains("* LIST") else { continue }
            if let folder = parseListResponse(line) {
                parsed.append(folder)
            }
        }

        folders = parsed
        statusMessage = "Found \(parsed.count) folders"
        imapLog.info("Listed \(parsed.count) folders")
        return parsed
    }

    func selectFolder(_ name: String) async throws -> Int {
        guard case .authenticated = connectionState else { throw IMAPError.notConnected }
        statusMessage = "Selecting folder: \(name)..."

        let response = try await sendCommand("SELECT \"\(name)\"")
        guard response.contains("OK") else {
            throw IMAPError.folderNotFound(name)
        }

        currentFolder = name
        let count = parseMessageCount(from: response)
        statusMessage = "Selected \(name) (\(count) messages)"
        imapLog.info("Selected folder \(name) with \(count) messages")
        return count
    }

    func fetchAllMessages(
        folder: String,
        limit: Int = 100,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [MBOXParser.RawEmail] {
        let totalCount = try await selectFolder(folder)
        guard totalCount > 0 else {
            statusMessage = "Folder is empty"
            return []
        }

        let effectiveLimit = min(limit, totalCount)
        let startUID = max(1, totalCount - effectiveLimit + 1)
        let range = "\(startUID):\(totalCount)"

        statusMessage = "Fetching \(effectiveLimit) messages..."
        imapLog.info("Fetching messages \(range) from \(folder)")

        let response = try await sendCommand(
            "FETCH \(range) (FLAGS BODY[])",
            longRunning: true
        )

        let rawMessages = extractFetchBodies(from: response)
        var emails: [MBOXParser.RawEmail] = []
        let total = Double(rawMessages.count)

        for (idx, raw) in rawMessages.enumerated() {
            do {
                let email = try MBOXParser.processRawMessage(raw, senderEmail: config?.username ?? "")
                emails.append(email)
            } catch {
                imapLog.warning("Failed to parse message \(idx + 1): \(error.localizedDescription)")
            }

            let prog = Double(idx + 1) / max(total, 1)
            progress = prog
            onProgress?(prog)

            if idx % 10 == 0 {
                statusMessage = "Parsed \(idx + 1)/\(rawMessages.count) messages..."
            }
        }

        fetchedEmails = emails
        progress = 1.0
        statusMessage = "Fetched \(emails.count) messages from \(folder)"
        imapLog.info("Fetched \(emails.count) messages successfully")
        return emails
    }

    func searchMessages(query: String) async throws -> [MBOXParser.RawEmail] {
        guard case .authenticated = connectionState else { throw IMAPError.notConnected }
        guard currentFolder != nil else {
            throw IMAPError.commandFailed(command: "SEARCH", response: "No folder selected")
        }

        statusMessage = "Searching for: \(query)..."
        imapLog.info("Searching: \(query)")

        // Use IMAP SEARCH with OR across common fields
        let sanitized = query.replacingOccurrences(of: "\"", with: "\\\"")
        let searchCmd = "SEARCH OR OR SUBJECT \"\(sanitized)\" FROM \"\(sanitized)\" BODY \"\(sanitized)\""
        let response = try await sendCommand(searchCmd)

        let uids = parseSearchResponse(response)
        guard !uids.isEmpty else {
            statusMessage = "No results for: \(query)"
            return []
        }

        imapLog.info("Search returned \(uids.count) results")
        let uidList = uids.prefix(200).map(String.init).joined(separator: ",")

        let fetchResp = try await sendCommand(
            "FETCH \(uidList) (FLAGS BODY[])",
            longRunning: true
        )

        let rawMessages = extractFetchBodies(from: fetchResp)
        var emails: [MBOXParser.RawEmail] = []

        for raw in rawMessages {
            do {
                let email = try MBOXParser.processRawMessage(raw, senderEmail: config?.username ?? "")
                emails.append(email)
            } catch {
                imapLog.warning("Failed to parse search result: \(error.localizedDescription)")
            }
        }

        fetchedEmails = emails
        statusMessage = "Found \(emails.count) messages for: \(query)"
        return emails
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    private func sendCommand(_ command: String, longRunning: Bool = false) async throws -> String {
        guard let connection = connection else { throw IMAPError.notConnected }

        let tag = nextTag()
        let fullCommand = "\(tag) \(command)\r\n"

        // Mask password in logs
        let safeLog = command.contains("LOGIN") ? "\(tag) LOGIN ***" : "\(tag) \(command)"
        imapLog.debug(">>> \(safeLog)")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: fullCommand.data(using: .utf8),
                completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                    } else {
                        cont.resume()
                    }
                }
            )
        }

        // Read until we see our tagged response
        let timeout = longRunning ? readTimeout * 10 : readTimeout
        return try await readTaggedResponse(tag: tag, timeout: timeout)
    }

    private func readTaggedResponse(tag: String, timeout: TimeInterval) async throws -> String {
        var accumulated = ""
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let chunk = try await readChunk()
            accumulated += chunk

            // Check if we received the tagged completion line
            let lines = accumulated.components(separatedBy: "\r\n")
            for line in lines {
                if line.hasPrefix(tag) {
                    imapLog.debug("<<< Response complete (\(accumulated.count) bytes)")
                    return accumulated
                }
            }
        }

        throw IMAPError.timeout
    }

    private func readResponse() async throws -> String {
        return try await readChunk()
    }

    private func readChunk() async throws -> String {
        guard let connection = connection else { throw IMAPError.notConnected }

        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                    return
                }
                guard let data = data, !data.isEmpty else {
                    cont.resume(throwing: IMAPError.unexpectedResponse("Empty response from server"))
                    return
                }
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                cont.resume(returning: text)
            }
        }
    }

    private func parseListResponse(_ line: String) -> IMAPFolder? {
        guard line.contains("* LIST") else { return nil }

        var flags: [String] = []
        if let flagStart = line.firstIndex(of: "("),
           let flagEnd = line.firstIndex(of: ")") {
            let flagStr = String(line[line.index(after: flagStart)..<flagEnd])
            flags = flagStr.components(separatedBy: " ").filter { !$0.isEmpty }
        }

        // Extract delimiter and folder name after the flags
        let afterFlags: String
        if let closeParen = line.firstIndex(of: ")") {
            afterFlags = String(line[line.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        // Parse: "delimiter" "name" or "delimiter" name
        let parts = afterFlags.components(separatedBy: " ")
        let delimiter = parts.first?.replacingOccurrences(of: "\"", with: "") ?? "/"

        // Folder name is everything after the delimiter token
        let nameStart = afterFlags.range(of: " ", range: afterFlags.startIndex..<afterFlags.endIndex)
        let rawName: String
        if let start = nameStart {
            rawName = String(afterFlags[start.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            rawName = "INBOX"
        }
        let name = rawName.replacingOccurrences(of: "\"", with: "")

        return IMAPFolder(name: name, delimiter: delimiter, flags: flags)
    }

    private func parseMessageCount(from response: String) -> Int {
        // Look for "* N EXISTS"
        for line in response.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("EXISTS"), trimmed.hasPrefix("*") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 3, let count = Int(parts[1]) {
                    return count
                }
            }
        }
        return 0
    }

    private func parseSearchResponse(_ response: String) -> [Int] {
        // Format: * SEARCH 1 2 3 4 ...
        for line in response.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("* SEARCH") {
                let tokens = trimmed.components(separatedBy: " ").dropFirst(2)
                return tokens.compactMap { Int($0) }
            }
        }
        return []
    }

    private func extractFetchBodies(from response: String) -> [String] {
        // IMAP FETCH responses contain literal data in the form:
        // * N FETCH (... BODY[] {SIZE}\r\n<raw message>\r\n)
        var messages: [String] = []
        let lines = response.components(separatedBy: "\r\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Look for FETCH lines with literal size indicator: {NNN}
            if line.contains("FETCH") && line.contains("BODY[]") {
                if let braceStart = line.lastIndex(of: "{"),
                   let braceEnd = line.lastIndex(of: "}"),
                   braceStart < braceEnd {
                    let sizeStr = String(line[line.index(after: braceStart)..<braceEnd])
                    if let size = Int(sizeStr) {
                        // Collect lines until we reach the byte count
                        var body = ""
                        var bytesRead = 0
                        i += 1
                        while i < lines.count && bytesRead < size {
                            let bodyLine = lines[i]
                            if !body.isEmpty { body += "\r\n" }
                            body += bodyLine
                            bytesRead += bodyLine.utf8.count + 2 // +2 for \r\n
                            i += 1
                        }
                        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            messages.append(body)
                        }
                        continue
                    }
                }
            }
            i += 1
        }

        // Fallback: if literal parsing found nothing, try splitting on FETCH boundaries
        if messages.isEmpty {
            let fetchPattern = #"\* \d+ FETCH"#
            let parts = response.components(separatedBy: "\r\n")
            var currentBody: [String] = []
            var inBody = false

            for part in parts {
                if part.range(of: fetchPattern, options: .regularExpression) != nil {
                    if inBody && !currentBody.isEmpty {
                        messages.append(currentBody.joined(separator: "\r\n"))
                        currentBody = []
                    }
                    inBody = true
                } else if inBody {
                    // Skip closing paren and tagged responses
                    if part == ")" || part.range(of: #"^A\d{4} "#, options: .regularExpression) != nil {
                        if !currentBody.isEmpty {
                            messages.append(currentBody.joined(separator: "\r\n"))
                            currentBody = []
                        }
                        inBody = false
                    } else {
                        currentBody.append(part)
                    }
                }
            }
            if !currentBody.isEmpty {
                messages.append(currentBody.joined(separator: "\r\n"))
            }
        }

        imapLog.info("Extracted \(messages.count) message bodies from FETCH response")
        return messages
    }
}
