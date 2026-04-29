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

// MARK: - ChunkedEmail
struct ChunkedEmail: Identifiable, Codable {
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

        let paragraphs = cleanedBody
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") && !$0.lowercased().hasPrefix("content-") }

        let sentences: [String] = paragraphs.flatMap { splitIntoSentences($0) }

        // Extract headers
        let subject = email.headers["Subject"] ?? "(No Subject)"
        let from = email.headers["From"] ?? "(Unknown Sender)"
        let to = email.headers["To"]
        let cc = email.headers["Cc"]
        let date = email.headers["Date"] ?? "(Unknown Date)"
        let emailID = email.headers["Message-ID"]
        let threadID = email.headers["References"] ?? emailID
        let isReply = detectIsReply(email)

        // Inline attachment validation (no need for global func)
        let attachments = (email.attachments ?? []).compactMap { attachment -> String? in
            let valid = !attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        attachment.size > 0 &&
                        (attachment.base64 != nil || attachment.fileURL != nil)
            if valid {
                return attachment.filename
            } else {
                print("⚠️ Skipped invalid attachment: \(attachment.filename)")
                return nil
            }
        }

        var chunks: [ChunkedEmail] = []
        let builder = ChunkBuilder(maxTokens: maxTokensPerChunk)
        var chunkIndex = 0

        for sentence in sentences {
            if !builder.add(sentence) {
                let chunk = builder.flush()
                if !chunk.isEmpty {
                    chunks.append(
                        ChunkedEmail(
                            chunkIndex: chunkIndex,
                            emailIndex: emailIndex,
                            emailID: emailID,
                            subject: subject,
                            from: from,
                            to: to,
                            cc: cc,
                            date: date,
                            threadID: threadID,
                            bodyChunk: chunk,
                            attachmentFilenames: attachments,
                            isRelevant: isRelevantChunk(chunk),
                            isReply: isReply
                        )
                    )
                    chunkIndex += 1
                }
                _ = builder.add(sentence)
            }
        }

        let finalChunk = builder.flush()
        if !finalChunk.isEmpty {
            chunks.append(
                ChunkedEmail(
                    chunkIndex: chunkIndex,
                    emailIndex: emailIndex,
                    emailID: emailID,
                    subject: subject,
                    from: from,
                    to: to,
                    cc: cc,
                    date: date,
                    threadID: threadID,
                    bodyChunk: finalChunk,
                    attachmentFilenames: attachments,
                    isRelevant: isRelevantChunk(finalChunk),
                    isReply: isReply
                )
            )
        }

        return chunks
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
        return lower.contains("due") ||
               lower.contains("payment") ||
               lower.contains("schedule") ||
               lower.contains("invoice") ||
               lower.rangeOfCharacter(from: .decimalDigits) != nil
    }
}
