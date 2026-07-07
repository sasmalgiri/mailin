//
//  RawEmail.swift
//  mailin
//
//  Created by administrator on 19/07/2025.
//

import Foundation
import NaturalLanguage
import CryptoKit

// MARK: - RawEmail
struct RawEmail: Codable {
    var headers: [String: String]
    var plainBody: String?
    var htmlBody: String?
    var attachments: [AttachmentMetadata]?
}

// MARK: - ChunkType
enum ChunkType: String, Codable, CaseIterable {
    case header
    case body
    case signature
    case quotedReply
    case attachment
}

// MARK: - ChunkedEmail
struct ChunkedEmail: Identifiable, Codable, @unchecked Sendable {
    var id = UUID()
    var chunkIndex: Int
    var emailIndex: Int
    var emailID: String?
    var subject: String
    var from: String
    var to: String?
    var cc: String?
    var date: String
    var threadID: String?
    var bodyChunk: String
    var chunkType: ChunkType = .body
    var attachmentFilenames: [String] = []
    var embedding: [Float]? = nil
    var isRelevant: Bool = true
    var isReply: Bool = false

    var fullTextForLLM: String {
        """
        Subject: \(subject)
        From: \(from)
        To: \(to ?? "")
        CC: \(cc ?? "")
        Date: \(date)

        \(bodyChunk)

        Attachments: \(attachmentFilenames.joined(separator: ", "))
        """
    }
}

// MARK: - ChunkBuilder
class ChunkBuilder {
    let maxTokens: Int
    private(set) var currentChunk: String = ""
    private(set) var currentTokenCount: Int = 0

    init(maxTokens: Int) {
        self.maxTokens = maxTokens
    }

    func add(_ sentence: String) -> Bool {
        let tokenEstimate = max(sentence.count / 4, 1)
        if currentTokenCount + tokenEstimate > maxTokens {
            return false
        }
        currentChunk += sentence + " "
        currentTokenCount += tokenEstimate
        return true
    }

    func flush() -> String {
        defer {
            currentChunk = ""
            currentTokenCount = 0
        }
        return currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - EmailChunker
struct EmailChunker {
    static func chunkAll(_ emails: [RawEmail], maxTokensPerChunk: Int = 150) -> [ChunkedEmail] {
        emails.enumerated().flatMap { (emailIndex, email) in
            chunkEmail(email, emailIndex: emailIndex, maxTokensPerChunk: maxTokensPerChunk)
        }
    }

    static func chunkEmail(_ email: RawEmail, emailIndex: Int, maxTokensPerChunk: Int) -> [ChunkedEmail] {
        let body = email.plainBody ?? email.htmlBody ?? ""
        let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        let subject = email.headers["Subject"] ?? "(No Subject)"
        let from = email.headers["From"] ?? "(Unknown Sender)"
        let to = email.headers["To"]
        let cc = email.headers["Cc"]
        let date = email.headers["Date"] ?? "(Unknown Date)"
        let emailID = email.headers["Message-ID"]
        let threadID = email.headers["References"] ?? emailID
        let isReply = detectIsReply(email)

        let attachments = (email.attachments ?? []).compactMap { attachment -> String? in
            let valid = !attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        attachment.size > 0 &&
                        (attachment.base64 != nil || attachment.fileURL != nil)
            return valid ? attachment.filename : nil
        }

        var chunks: [ChunkedEmail] = []
        var chunkIndex = 0

        func makeChunk(_ text: String, type: ChunkType) -> ChunkedEmail {
            let c = ChunkedEmail(
                chunkIndex: chunkIndex,
                emailIndex: emailIndex,
                emailID: emailID,
                subject: subject,
                from: from,
                to: to,
                cc: cc,
                date: date,
                threadID: threadID,
                bodyChunk: text,
                chunkType: type,
                attachmentFilenames: attachments,
                isRelevant: type == .header || type == .attachment || isRelevantChunk(text),
                isReply: isReply
            )
            chunkIndex += 1
            return c
        }

        // 1. Header chunk — routing info, authentication, metadata
        let headerChunk = buildHeaderChunk(email)
        if !headerChunk.isEmpty {
            chunks.append(makeChunk(headerChunk, type: .header))
        }

        // 2. Body and quoted-reply chunks
        let lines = cleanedBody.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("content-type:") &&
                      !$0.lowercased().hasPrefix("content-transfer-encoding:") &&
                      !$0.lowercased().hasPrefix("content-disposition:") }

        var bodyLines: [String] = []
        var quotedLines: [String] = []
        var signatureLines: [String] = []
        var inSignature = false

        for line in lines {
            if !inSignature && isSignatureMarker(line) {
                inSignature = true
                signatureLines.append(line)
            } else if inSignature {
                signatureLines.append(line)
            } else if line.hasPrefix(">") {
                quotedLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                bodyLines.append(line)
            }
        }

        // Build body chunks
        let bodySentences = bodyLines.flatMap { splitIntoSentences($0) }
        let bodyBuilder = ChunkBuilder(maxTokens: maxTokensPerChunk)
        for sentence in bodySentences {
            if !bodyBuilder.add(sentence) {
                let chunk = bodyBuilder.flush()
                if !chunk.isEmpty { chunks.append(makeChunk(chunk, type: .body)) }
                if !bodyBuilder.add(sentence) {
                    let truncated = String(sentence.prefix(maxTokensPerChunk * 4))
                    chunks.append(makeChunk(truncated, type: .body))
                }
            }
        }
        let finalBody = bodyBuilder.flush()
        if !finalBody.isEmpty { chunks.append(makeChunk(finalBody, type: .body)) }

        // Build quoted-reply chunks (if substantial)
        if quotedLines.count >= 2 {
            let quotedText = quotedLines.joined(separator: " ")
            if quotedText.count > 20 {
                let capped = String(quotedText.prefix(maxTokensPerChunk * 4))
                chunks.append(makeChunk(capped, type: .quotedReply))
            }
        }

        // Build signature chunk (if present)
        if !signatureLines.isEmpty {
            let sigText = signatureLines.joined(separator: "\n")
            if sigText.count > 5 {
                let capped = String(sigText.prefix(maxTokensPerChunk * 4))
                chunks.append(makeChunk(capped, type: .signature))
            }
        }

        // 3. Attachment metadata chunk
        if !attachments.isEmpty {
            let attachText = "Attachments: " + attachments.joined(separator: ", ")
            chunks.append(makeChunk(attachText, type: .attachment))
        }

        return chunks
    }

    private static func buildHeaderChunk(_ email: RawEmail) -> String {
        var parts: [String] = []
        let headerKeys = [
            "From", "To", "Cc", "Bcc", "Date", "Subject", "Message-ID",
            "In-Reply-To", "References", "Reply-To",
            "Authentication-Results", "Received-SPF", "DKIM-Signature",
            "X-Originating-IP", "X-Mailer", "User-Agent",
            "List-Unsubscribe", "List-Id", "Precedence",
            "Return-Path", "X-Spam-Status", "X-Spam-Score"
        ]
        for key in headerKeys {
            if let value = email.headers[key], !value.isEmpty {
                parts.append("\(key): \(value)")
            }
        }
        let received = email.headers.filter { $0.key.lowercased() == "received" || $0.key.lowercased().hasPrefix("received") }
        for (key, value) in received.prefix(3) {
            parts.append("\(key): \(value)")
        }
        return parts.joined(separator: "\n")
    }

    private static func isSignatureMarker(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "--" || lower == "-- " { return true }
        if lower.hasPrefix("sent from my") { return true }
        if lower.hasPrefix("get outlook for") { return true }
        let signoffs = ["regards,", "best regards,", "sincerely,", "thanks,", "thank you,",
                        "cheers,", "best,", "warm regards,", "kind regards,", "yours truly,"]
        return signoffs.contains(where: { lower.hasPrefix($0) })
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
    }

    private static func detectIsReply(_ email: RawEmail) -> Bool {
        let subject = email.headers["Subject"]?.lowercased() ?? ""
        let hasReplyHeader = email.headers["In-Reply-To"] != nil || email.headers["References"] != nil
        return subject.hasPrefix("re:") || hasReplyHeader
    }

    private static func isRelevantChunk(_ text: String) -> Bool {
        let lower = text.lowercased()
        let actionWords: Set<String> = [
            "due", "payment", "schedule", "invoice", "deadline", "meeting",
            "confirm", "approve", "review", "update", "decision", "budget",
            "proposal", "contract", "agreement", "urgent", "important",
            "action", "plan", "deliver", "complete", "assign", "request",
        ]
        if actionWords.contains(where: { lower.contains($0) }) { return true }
        if lower.rangeOfCharacter(from: .decimalDigits) != nil &&
            (lower.contains("$") || lower.contains("%") || lower.contains("#") || lower.contains("date")) {
            return true
        }
        let questionCount = lower.filter { $0 == "?" }.count
        if questionCount >= 1 { return true }
        return false
    }
}
