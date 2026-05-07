import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ExportManager {

    // MARK: - vCard Export (6D)

    static func exportContacts(from emails: [MBOXParser.RawEmail]) -> String {
        var contacts: [String: (name: String, email: String)] = [:]

        for email in emails {
            for key in ["From", "To", "Cc"] {
                guard let field = email.headers[key] else { continue }
                for part in field.split(separator: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (name, addr) = parseEmailAddress(trimmed)
                    if !addr.isEmpty {
                        contacts[addr.lowercased()] = (name: name, email: addr)
                    }
                }
            }
        }

        var vcards = ""
        for (_, contact) in contacts.sorted(by: { $0.key < $1.key }) {
            vcards += "BEGIN:VCARD\r\n"
            vcards += "VERSION:3.0\r\n"
            vcards += "FN:\(contact.name.isEmpty ? contact.email : contact.name)\r\n"
            if !contact.name.isEmpty {
                let parts = contact.name.split(separator: " ", maxSplits: 1)
                let first = parts.first.map(String.init) ?? ""
                let last = parts.count > 1 ? String(parts[1]) : ""
                vcards += "N:\(last);\(first);;;\r\n"
            }
            vcards += "EMAIL;TYPE=INTERNET:\(contact.email)\r\n"
            vcards += "END:VCARD\r\n"
        }
        return vcards
    }

    // MARK: - ICS Calendar Export (6E)

    static func exportCalendarEvents(from emails: [MBOXParser.RawEmail]) -> String {
        var events: [String] = []

        for email in emails {
            for att in email.attachments {
                if att.mimeType.lowercased().contains("calendar") || att.filename.lowercased().hasSuffix(".ics") {
                    if let b64 = att.base64, let data = Data(base64Encoded: b64),
                       let content = String(data: data, encoding: .utf8) {
                        let eventParts = content.components(separatedBy: "BEGIN:VEVENT")
                        for part in eventParts.dropFirst() {
                            if let eventBody = part.components(separatedBy: "END:VCALENDAR").first {
                                events.append("BEGIN:VEVENT" + eventBody)
                            }
                        }
                    }
                }
            }
        }

        guard !events.isEmpty else { return "" }

        var ics = "BEGIN:VCALENDAR\r\n"
        ics += "VERSION:2.0\r\n"
        ics += "PRODID:-//mailin//EN\r\n"
        for event in events {
            ics += event
        }
        ics += "END:VCALENDAR\r\n"
        return ics
    }

    // MARK: - TIFF Export (6C)

    static func exportAsTIFF(email: MBOXParser.RawEmail) -> Data? {
        #if os(macOS)
        let text = formatEmailForPrint(email)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.textColor
        ])

        let size = NSSize(width: 612, height: 792)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let rect = NSRect(x: 36, y: 36, width: size.width - 72, height: size.height - 72)
        attributed.draw(in: rect)
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation else { return nil }
        return tiffData
        #else
        let text = formatEmailForPrint(email)
        let size = CGSize(width: 612, height: 792)
        let renderer = UIGraphicsImageRenderer(size: size)
        let data = renderer.pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ]
            (text as NSString).draw(in: CGRect(x: 36, y: 36, width: 540, height: 720), withAttributes: attrs)
        }
        return data
        #endif
    }

    // MARK: - Concordance Load File (6F)

    static func generateConcordanceLoadFile(from emails: [MBOXParser.RawEmail], batesPrefix: String = "MAIL") -> String {
        var lines = ["\u{14}DOCID\u{14}\u{14}BEGBATES\u{14}\u{14}ENDBATES\u{14}\u{14}FROM\u{14}\u{14}TO\u{14}\u{14}CC\u{14}\u{14}SUBJECT\u{14}\u{14}DATE\u{14}\u{14}ATTACHMENTS\u{14}"]

        for (idx, email) in emails.enumerated() {
            let bates = String(format: "%@%06d", batesPrefix, idx + 1)
            let from = (email.headers["From"] ?? "").replacingOccurrences(of: "\u{14}", with: "")
            let to = (email.headers["To"] ?? "").replacingOccurrences(of: "\u{14}", with: "")
            let cc = (email.headers["Cc"] ?? "").replacingOccurrences(of: "\u{14}", with: "")
            let subject = (email.headers["Subject"] ?? "").replacingOccurrences(of: "\u{14}", with: "")
            let date = email.timestamp
            let attachCount = "\(email.attachments.count)"
            lines.append("\u{14}\(email.id)\u{14}\u{14}\(bates)\u{14}\u{14}\(bates)\u{14}\u{14}\(from)\u{14}\u{14}\(to)\u{14}\u{14}\(cc)\u{14}\u{14}\(subject)\u{14}\u{14}\(date)\u{14}\u{14}\(attachCount)\u{14}")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Relativity Load File (6F+)

    static func generateRelativityLoadFile(
        from emails: [MBOXParser.RawEmail],
        batesPrefix: String = "MAIL",
        custodianName: String = "",
        caseNumber: String = ""
    ) -> String {
        var lines = ["Control Number,Custodian,Date Sent,Date Received,From,To,CC,BCC,Subject,Email Message ID,Conversation Index,Attachment Count,Has Attachments,File Size,MD5 Hash,Native File Path"]

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MM/dd/yyyy"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "hh:mm:ss a"

        for (idx, email) in emails.enumerated() {
            let controlNum = String(format: "%@%07d", batesPrefix, idx + 1)
            let from = csvEscape(email.headers["From"] ?? "")
            let to = csvEscape(email.headers["To"] ?? "")
            let cc = csvEscape(email.headers["Cc"] ?? "")
            let bcc = csvEscape(email.headers["Bcc"] ?? "")
            let subject = csvEscape(email.headers["Subject"] ?? "")
            let messageID = csvEscape(email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? "")
            let conversationIdx = csvEscape(email.headers["Thread-Index"] ?? "")
            let attachCount = email.attachments.count
            let hasAttach = attachCount > 0 ? "Y" : "N"
            let fileSize = email.rawSource.utf8.count
            let nativePath = csvEscape("\(caseNumber)/\(controlNum).eml")

            let parsedDate = MBOXParser.parseDate(email.headers["Date"])
            let dateSent = parsedDate.map { dateFormatter.string(from: $0) } ?? ""

            var md5 = ""
            if let data = email.rawSource.data(using: .utf8) {
                let digest = CryptoKit.Insecure.MD5.hash(data: data)
                md5 = digest.map { String(format: "%02x", $0) }.joined()
            }

            lines.append("\(controlNum),\(csvEscape(custodianName)),\(dateSent),,\(from),\(to),\(cc),\(bcc),\(subject),\(messageID),\(conversationIdx),\(attachCount),\(hasAttach),\(fileSize),\(md5),\(nativePath)")
        }

        return lines.joined(separator: "\r\n")
    }

    private static func csvEscape(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        if cleaned.contains(",") || cleaned.contains("\"") || cleaned.contains("\r") {
            return "\"\(cleaned.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return cleaned
    }

    // MARK: - Batch Print (6G)

    static func batchPrintText(emails: [MBOXParser.RawEmail]) -> String {
        emails.enumerated().map { idx, email in
            let separator = String(repeating: "=", count: 72)
            return """
            \(separator)
            Email \(idx + 1) of \(emails.count)
            \(separator)
            \(formatEmailForPrint(email))

            """
        }.joined(separator: "\n\n")
    }

    // MARK: - Review State Export/Import (Async Collaboration)

    struct ReviewStatePackage: Codable {
        let version: Int
        let exportDate: Date
        let exportedBy: String
        let caseNumber: String

        var evidenceTags: [String: String]
        var annotations: [String: AnnotationExport]
        var custodians: [String: String]
        var legalHolds: [String]
        var reviewBatches: [ReviewBatchExport]
        var currentBatchIndex: Int
        var predictiveRelevantIDs: [String]
        var predictiveIrrelevantIDs: [String]
        var savedSearches: [SavedSearchExport]

        struct AnnotationExport: Codable {
            let text: String
            let examiner: String
            let timestamp: Date
        }

        struct ReviewBatchExport: Codable {
            let id: String
            let name: String
            let emailIDs: [String]
            var reviewedIDs: [String]
            var skippedIDs: [String]
        }

        struct SavedSearchExport: Codable {
            let name: String
            let query: String
        }
    }

    @MainActor
    static func exportReviewState() -> Data? {
        let forensic = ForensicManager.shared
        let custodianMgr = CustodianManager.shared
        let batchMgr = ReviewBatchManager.shared
        let predictive = PredictiveCodingEngine.shared

        let tags = forensic.evidenceTags.reduce(into: [String: String]()) {
            $0[$1.key.uuidString] = $1.value.rawValue
        }

        let annots = forensic.annotations.reduce(into: [String: ReviewStatePackage.AnnotationExport]()) {
            $0[$1.key.uuidString] = .init(text: $1.value.text, examiner: $1.value.examiner, timestamp: $1.value.timestamp)
        }

        let custs = custodianMgr.custodians.reduce(into: [String: String]()) {
            $0[$1.key.uuidString] = $1.value
        }

        let holds = custodianMgr.legalHolds.map(\.uuidString)

        let batches = batchMgr.batches.map { batch in
            ReviewStatePackage.ReviewBatchExport(
                id: batch.id.uuidString,
                name: batch.name,
                emailIDs: batch.emailIDs.map(\.uuidString),
                reviewedIDs: batch.reviewedIDs.map(\.uuidString),
                skippedIDs: batch.skippedIDs.map(\.uuidString)
            )
        }

        let savedSearches: [ReviewStatePackage.SavedSearchExport] = []

        let package = ReviewStatePackage(
            version: 1,
            exportDate: Date(),
            exportedBy: forensic.examinerName,
            caseNumber: forensic.caseNumber,
            evidenceTags: tags,
            annotations: annots,
            custodians: custs,
            legalHolds: holds,
            reviewBatches: batches,
            currentBatchIndex: batchMgr.currentBatchIndex,
            predictiveRelevantIDs: predictive.relevantIDs.map(\.uuidString),
            predictiveIrrelevantIDs: predictive.irrelevantIDs.map(\.uuidString),
            savedSearches: savedSearches
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(package)
    }

    enum MergeStrategy {
        case keepLocal
        case keepImported
        case merge
    }

    @MainActor
    static func importReviewState(from data: Data, strategy: MergeStrategy = .merge) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(ReviewStatePackage.self, from: data)

        var result = ImportResult()

        let forensic = ForensicManager.shared
        let custodianMgr = CustodianManager.shared
        let batchMgr = ReviewBatchManager.shared
        let predictive = PredictiveCodingEngine.shared

        for (idStr, tagStr) in package.evidenceTags {
            guard let uuid = UUID(uuidString: idStr),
                  let tag = ForensicManager.EvidenceTag(rawValue: tagStr) else { continue }
            let existing = forensic.evidenceTags[uuid]
            switch strategy {
            case .keepLocal where existing != nil:
                continue
            case .keepImported, .keepLocal, .merge:
                if existing == nil || strategy == .keepImported || (strategy == .merge && existing == ForensicManager.EvidenceTag.none) {
                    forensic.evidenceTags[uuid] = tag
                    forensic.tagTimestamps[uuid] = Date()
                    result.tagsImported += 1
                }
            }
        }

        for (idStr, annot) in package.annotations {
            guard let uuid = UUID(uuidString: idStr) else { continue }
            let existing = forensic.annotations[uuid]
            switch strategy {
            case .keepLocal where existing != nil:
                continue
            case .keepImported:
                forensic.annotations[uuid] = ForensicManager.Annotation(text: annot.text, examiner: annot.examiner, timestamp: annot.timestamp)
                result.annotationsImported += 1
            case .merge, .keepLocal:
                if let ex = existing {
                    if annot.timestamp > ex.timestamp {
                        forensic.annotations[uuid] = ForensicManager.Annotation(text: annot.text, examiner: annot.examiner, timestamp: annot.timestamp)
                        result.annotationsImported += 1
                    }
                } else {
                    forensic.annotations[uuid] = ForensicManager.Annotation(text: annot.text, examiner: annot.examiner, timestamp: annot.timestamp)
                    result.annotationsImported += 1
                }
            }
        }

        for (idStr, name) in package.custodians {
            guard let uuid = UUID(uuidString: idStr) else { continue }
            if strategy == .keepLocal && custodianMgr.custodians[uuid] != nil { continue }
            custodianMgr.custodians[uuid] = name
            result.custodiansImported += 1
        }

        for idStr in package.legalHolds {
            guard let uuid = UUID(uuidString: idStr) else { continue }
            if !custodianMgr.legalHolds.contains(uuid) {
                custodianMgr.legalHolds.insert(uuid)
                result.legalHoldsImported += 1
            }
        }

        if strategy != .keepLocal || batchMgr.batches.isEmpty {
            let importedBatches = package.reviewBatches.compactMap { exp -> ReviewBatchManager.ReviewBatch? in
                guard let id = UUID(uuidString: exp.id) else { return nil }
                return rebuildBatch(id: id, name: exp.name, emailIDs: exp.emailIDs, reviewedIDs: exp.reviewedIDs, skippedIDs: exp.skippedIDs)
            }
            if strategy == .merge && !batchMgr.batches.isEmpty {
                let existingNames = Set(batchMgr.batches.map(\.name))
                for batch in importedBatches where !existingNames.contains(batch.name) {
                    batchMgr.batches.append(batch)
                    result.batchesImported += 1
                }
            } else if !importedBatches.isEmpty {
                batchMgr.batches = importedBatches
                batchMgr.currentBatchIndex = min(package.currentBatchIndex, importedBatches.count - 1)
                result.batchesImported = importedBatches.count
            }
        }

        for idStr in package.predictiveRelevantIDs {
            guard let uuid = UUID(uuidString: idStr) else { continue }
            if !predictive.relevantIDs.contains(uuid) {
                predictive.relevantIDs.insert(uuid)
                result.predictiveTagsImported += 1
            }
        }
        for idStr in package.predictiveIrrelevantIDs {
            guard let uuid = UUID(uuidString: idStr) else { continue }
            if !predictive.irrelevantIDs.contains(uuid) {
                predictive.irrelevantIDs.insert(uuid)
                result.predictiveTagsImported += 1
            }
        }

        forensic.logAction("Review State Imported", detail: "From \(package.exportedBy.isEmpty ? "unknown" : package.exportedBy), \(result.summary)")

        return result
    }

    private static func rebuildBatch(id: UUID, name: String, emailIDs: [String], reviewedIDs: [String], skippedIDs: [String]) -> ReviewBatchManager.ReviewBatch {
        var batch = ReviewBatchManager.ReviewBatch(name: name, emailIDs: emailIDs.compactMap { UUID(uuidString: $0) })
        for idStr in reviewedIDs {
            if let uuid = UUID(uuidString: idStr) { batch.reviewedIDs.insert(uuid) }
        }
        for idStr in skippedIDs {
            if let uuid = UUID(uuidString: idStr) { batch.skippedIDs.insert(uuid) }
        }
        return batch
    }

    struct ImportResult {
        var tagsImported = 0
        var annotationsImported = 0
        var custodiansImported = 0
        var legalHoldsImported = 0
        var batchesImported = 0
        var predictiveTagsImported = 0

        var total: Int { tagsImported + annotationsImported + custodiansImported + legalHoldsImported + batchesImported + predictiveTagsImported }

        var summary: String {
            var parts: [String] = []
            if tagsImported > 0 { parts.append("\(tagsImported) tags") }
            if annotationsImported > 0 { parts.append("\(annotationsImported) annotations") }
            if custodiansImported > 0 { parts.append("\(custodiansImported) custodians") }
            if legalHoldsImported > 0 { parts.append("\(legalHoldsImported) legal holds") }
            if batchesImported > 0 { parts.append("\(batchesImported) review batches") }
            if predictiveTagsImported > 0 { parts.append("\(predictiveTagsImported) predictive tags") }
            return parts.isEmpty ? "No new data imported" : parts.joined(separator: ", ")
        }
    }

    // MARK: - Helpers

    private static func formatEmailForPrint(_ email: MBOXParser.RawEmail) -> String {
        var text = ""
        text += "From: \(email.headers["From"] ?? "")\n"
        text += "To: \(email.headers["To"] ?? "")\n"
        if let cc = email.headers["Cc"], !cc.isEmpty { text += "Cc: \(cc)\n" }
        text += "Subject: \(email.headers["Subject"] ?? "")\n"
        text += "Date: \(email.headers["Date"] ?? email.timestamp)\n"
        if !email.attachments.isEmpty {
            text += "Attachments: \(email.attachments.map(\.filename).joined(separator: ", "))\n"
        }
        text += "\n"
        text += email.plainBody.isEmpty ? email.htmlBody.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : email.plainBody
        return text
    }

    private static func parseEmailAddress(_ raw: String) -> (name: String, email: String) {
        if let angleStart = raw.firstIndex(of: "<"), let angleEnd = raw.firstIndex(of: ">") {
            let email = String(raw[raw.index(after: angleStart)..<angleEnd]).trimmingCharacters(in: .whitespaces)
            let name = String(raw[raw.startIndex..<angleStart]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (name, email)
        }
        if raw.contains("@") {
            return ("", raw.trimmingCharacters(in: .whitespaces))
        }
        return (raw, "")
    }
}
