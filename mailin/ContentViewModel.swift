import Foundation
import SwiftUI
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject {
    @Published var senderEmail: String = ""
    @Published var selectedFiles: [URL] = []
    @Published var statusMessage = "No file selected."
    @Published var statusColor: Color = .gray
    @Published var aiPrompt: String = ""
    @Published var aiResponse: String = ""
    @Published var isParsed: Bool = false
    @Published var subjectList: [String] = []
    @Published var detectedDateRange: (Date?, Date?) = (nil, nil)

    // --- For loading spinner/progress UI ---
    @Published var loadingProgress: Double = 0.0  // 0.0...1.0
    @Published var loadingText: String = ""

    private(set) var parsedEmails: [MBOXParser.RawEmail] = []
    private(set) var metadata: [String: Any] = [:]

    init() {
        statusMessage = "Please enter your sender email to begin."
    }

    // MARK: - MBOX Parsing with fine-grained progress
    func parseSelectedFiles(_ urls: [URL]) {
        guard !senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async {
                self.statusMessage = "Please enter your email address before selecting files."
                self.statusColor = .red
            }
            return
        }

        DispatchQueue.main.async {
            self.statusMessage = "Parsing files..."
            self.statusColor = .blue
            self.isParsed = false
            self.selectedFiles = urls
            self.loadingProgress = 0.0
            self.loadingText = "Initializing..."
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var allEmails: [MBOXParser.RawEmail] = []
            let totalFiles = Double(urls.count)
            for (idx, fileURL) in urls.enumerated() {
                do {
                    // --- PER-EMAIL PROGRESS BLOCK (the magic!) ---
                    let emails = try MBOXParser.parse(
                        fileURL: fileURL,
                        senderEmail: self.senderEmail,
                        onProgress: { prog in
                            DispatchQueue.main.async {
                                // Nested progress: current file index + email progress
                                self.loadingProgress = (Double(idx) + prog) / totalFiles
                                self.loadingText = "Parsing \(fileURL.lastPathComponent): \(Int(prog * 100))%"
                            }
                        }
                    )
                    let withSource = emails.map { email -> MBOXParser.RawEmail in
                        var copy = email
                        copy.headers["sourceFile"] = fileURL.lastPathComponent
                        return copy
                    }
                    allEmails.append(contentsOf: withSource)
                } catch {
                    print("Error parsing \(fileURL.lastPathComponent): \(error)")
                }
                // Ensure we show 100% for each file after done
                DispatchQueue.main.async {
                    self.loadingText = "Parsed \(idx+1) of \(urls.count) file(s)..."
                    self.loadingProgress = min(1.0, Double(idx + 1) / totalFiles)
                }
            }

            DispatchQueue.main.async {
                guard !allEmails.isEmpty else {
                    self.statusMessage = "No emails found. Make sure your file is a valid .mbox (from Gmail Takeout, Thunderbird, etc.) or .eml file."
                    self.statusColor = .orange
                    self.isParsed = false
                    self.loadingProgress = 0.0
                    self.loadingText = ""
                    return
                }

                self.parsedEmails = self.annotate(allEmails)
                self.isParsed = true
                self.updateMetadataDisplay()
                self.statusMessage = "Parsed \(self.parsedEmails.count) emails from \(urls.count) file(s)."
                self.statusColor = .green
                self.loadingProgress = 1.0
                self.loadingText = "Done!"

                NotificationCenter.default.post(name: .parsingFinished, object: nil)
            }
        }
    }

    // ... (rest of your code is unchanged and correct) ...
    // MARK: - Metadata/AI
    func autoDetectMetadata() {
        guard isParsed else {
            statusMessage = "Parse a file first."
            statusColor = .orange
            return
        }
        let replyCounts = replyFrequency(for: senderEmail)
        let sortedSubjects = Dictionary(grouping: parsedEmails, by: { $0.headers["Subject"] ?? "(No Subject)" })
            .mapValues { $0.count }
            .sorted { replyCounts[$0.key, default: 0] < replyCounts[$1.key, default: 0] }

        subjectList = sortedSubjects.map { $0.key }
        let dates = parsedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }
        detectedDateRange = (dates.min(), dates.max())
        statusMessage = "Metadata detected: \(subjectList.count) subjects."
        statusColor = .blue
    }

    func runAIQuery() {
        guard isParsed else {
            aiResponse = "Please parse a file first."
            return
        }
        let lower = aiPrompt.lowercased()
        if lower.contains("how many") && lower.contains("sent") {
            let count = parsedEmails.filter { $0.messageType == "sent" }.count
            aiResponse = "Total sent emails: \(count)"
        } else if lower.contains("how many") && lower.contains("received") {
            let count = parsedEmails.filter { $0.messageType == "received" }.count
            aiResponse = "Total received emails: \(count)"
        } else if lower.contains("top subject") {
            let freq = Dictionary(grouping: parsedEmails.map { $0.headers["Subject"] ?? "(No Subject)" }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
            aiResponse = "Top Subjects:\n" + freq.prefix(5).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        } else if lower.contains("reply frequency") {
            let freq = replyFrequency(for: senderEmail)
            let summary = freq.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            aiResponse = "Top Reply Recipients:\n" + summary
        } else {
            aiResponse = "Sorry, I didn't understand that. Try asking about 'sent emails', 'received emails', 'top subjects', or 'reply frequency'."
        }
    }

    // MARK: - Annotate parsed emails (sent/received/normalize)
    private func annotate(_ emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        var annotated = emails
        let normalizedSender = senderEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedSender.isEmpty {
            let froms = emails.compactMap { $0.headers["From"] }
            senderEmail = mostCommon(in: froms)
        }

        for i in 0..<annotated.count {
            let from = annotated[i].headers["From"]?.lowercased() ?? ""
            if from == normalizedSender || from.contains(normalizedSender) {
                annotated[i].messageType = "sent"
            } else {
                annotated[i].messageType = "received"
            }
        }
        return annotated
    }

    private func mostCommon(in array: [String]) -> String {
        let counts = Dictionary(grouping: array, by: { $0 }).mapValues { $0.count }
        return counts.max(by: { $0.value < $1.value })?.key ?? ""
    }

    private func updateMetadataDisplay() {
        autoDetectMetadata()
    }

    // MARK: - Reply Frequency (threading)
    func replyFrequency(for userEmail: String) -> [String: Int] {
        let replies = parsedEmails.filter {
            $0.headers["From"]?.lowercased().contains(userEmail.lowercased()) == true
        }

        var counts: [String: Int] = [:]
        for email in replies {
            if let toField = email.headers["To"] {
                let recipients = toField.components(separatedBy: ",")
                for recipient in recipients {
                    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        counts[trimmed, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    // MARK: - Restore persisted emails
    func restoreEmails(_ emails: [MBOXParser.RawEmail]) {
        self.parsedEmails = emails
        self.isParsed = !emails.isEmpty
        if isParsed {
            updateMetadataDisplay()
            statusMessage = "Restored \(emails.count) emails from previous session."
            statusColor = .green
            NotificationCenter.default.post(name: .parsingFinished, object: nil)
        }
    }

    // MARK: - Export as EML (raw string)
    func exportEmailAsEML(_ email: MBOXParser.RawEmail) -> String {
        var result = ""
        for (key, value) in email.headers {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"
        result += email.plainBody
        return result
    }

    // MARK: - FileUtils EML Export (atomic & auditable!)
    func exportFilteredEmailsAsEML(to folder: URL, emails: [MBOXParser.RawEmail]) {
        for (index, email) in emails.enumerated() {
            let rawSubject = email.headers["Subject"] ?? "(no-subject)"
            let safeSubject = rawSubject
                .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: [.regularExpression])
                .prefix(30)
            let filename = "\(index + 1)_\(safeSubject).eml"
            let fileURL = folder.appendingPathComponent(filename)
            let emlContent = exportEmailAsEML(email)
            do {
                try FileUtils.writeData(Data(emlContent.utf8), to: fileURL.path)
            } catch {
                print("Failed to write \(filename): \(error)")
                // Optionally log error here with FileUtilsAudit or similar
            }
        }
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let parsingFinished = Notification.Name("parsingFinished")
}
