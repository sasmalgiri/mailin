import Foundation
import CryptoKit
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ExportManager {

    // MARK: - vCard Export (6D)

    static func exportContacts(from emails: [MBOXParser.RawEmail]) -> Data? {
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

        guard !contacts.isEmpty else { return nil }

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
        return vcards.data(using: .utf8)
    }

    static func exportContactsToFile(from emails: [MBOXParser.RawEmail]) -> URL? {
        guard let data = exportContacts(from: emails) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contacts_\(UUID().uuidString).vcf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
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
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)

        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 36
        let contentWidth = pageWidth - margin * 2
        let contentHeight = pageHeight - margin * 2

        let textBounds = attributed.boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let totalTextHeight = ceil(textBounds.height)
        let pageCount = max(1, Int(ceil(totalTextHeight / contentHeight)))

        var imageReps: [NSBitmapImageRep] = []

        for page in 0..<pageCount {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pageWidth * 2),
                pixelsHigh: Int(pageHeight * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = NSSize(width: pageWidth, height: pageHeight)

            NSGraphicsContext.saveGraphicsState()
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
                NSGraphicsContext.restoreGraphicsState()
                continue
            }
            NSGraphicsContext.current = context

            let cgCtx = context.cgContext
            cgCtx.translateBy(x: 0, y: pageHeight)
            cgCtx.scaleBy(x: 1, y: -1)

            cgCtx.setFillColor(NSColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight)))

            cgCtx.saveGState()
            cgCtx.clip(to: CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight))

            let yOffset = CGFloat(page) * contentHeight
            let drawRect = NSRect(x: margin, y: margin - yOffset, width: contentWidth, height: totalTextHeight)
            attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

            cgCtx.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            imageReps.append(rep)
        }

        guard !imageReps.isEmpty else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.tiff" as CFString, imageReps.count, nil) else { return nil }
        for rep in imageReps {
            guard let cgImage = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, cgImage, [kCGImagePropertyTIFFCompression: 5] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
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
        var v = value
        if let first = v.first, "=+@-\t\r".contains(first) {
            v = "'" + v
        }
        if v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r") {
            let escaped = v
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return "\"\(escaped)\""
        }
        return v
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

    // MARK: - Portable HTML Export

    static func exportPortableHTML(emails: [MBOXParser.RawEmail], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        struct EmailEntry: Encodable {
            let id: String
            let date: String
            let from: String
            let to: String
            let cc: String
            let subject: String
            let preview: String
            let body: String
        }

        let entries = emails.map { email -> EmailEntry in
            let plainBody = email.plainBody.isEmpty
                ? email.htmlBody.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                : email.plainBody
            let preview = String(plainBody.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            return EmailEntry(
                id: email.id.uuidString,
                date: email.headers["Date"] ?? email.timestamp,
                from: email.headers["From"] ?? "",
                to: email.headers["To"] ?? "",
                cc: email.headers["Cc"] ?? "",
                subject: email.headers["Subject"] ?? "(No Subject)",
                preview: preview,
                body: email.htmlBody.isEmpty ? plainBody : email.htmlBody
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(entries)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "ExportManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode email data as JSON."])
        }

        let html = portableHTMLTemplate(emailJSON: jsonString, emailCount: emails.count)
        let indexURL = folder.appendingPathComponent("index.html")
        try html.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private static func portableHTMLTemplate(emailJSON: String, emailCount: Int) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>mailin Export (\(emailCount) emails)</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#f5f5f7;color:#1d1d1f;display:flex;flex-direction:column;height:100vh}
        header{background:#fff;border-bottom:1px solid #d2d2d7;padding:12px 20px;display:flex;align-items:center;gap:16px;flex-shrink:0}
        header h1{font-size:18px;font-weight:600;white-space:nowrap}
        #search{flex:1;max-width:420px;padding:8px 12px;border:1px solid #d2d2d7;border-radius:8px;font-size:14px;outline:none}
        #search:focus{border-color:#0071e3;box-shadow:0 0 0 3px rgba(0,113,227,.15)}
        #count{font-size:13px;color:#86868b;white-space:nowrap}
        .main{display:flex;flex:1;overflow:hidden}
        .list{width:380px;min-width:260px;overflow-y:auto;border-right:1px solid #d2d2d7;background:#fff;flex-shrink:0}
        .item{padding:12px 16px;border-bottom:1px solid #f0f0f0;cursor:pointer;transition:background .15s}
        .item:hover{background:#f0f0f5}
        .item.active{background:#e8f0fe;border-left:3px solid #0071e3;padding-left:13px}
        .item .subject{font-weight:600;font-size:14px;margin-bottom:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .item .meta{font-size:12px;color:#86868b;margin-bottom:3px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .item .preview{font-size:12px;color:#6e6e73;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .detail{flex:1;overflow-y:auto;padding:24px 32px;background:#fff}
        .detail-empty{display:flex;align-items:center;justify-content:center;color:#86868b;font-size:15px;height:100%}
        .detail h2{font-size:20px;margin-bottom:12px}
        .detail .hdr{font-size:13px;color:#6e6e73;margin-bottom:4px}
        .detail .hdr b{color:#1d1d1f}
        .detail hr{border:none;border-top:1px solid #e5e5ea;margin:16px 0}
        .detail .body{font-size:14px;line-height:1.6;word-wrap:break-word;overflow-wrap:break-word}
        .detail .body img{max-width:100%}
        .no-results{padding:32px;text-align:center;color:#86868b;font-size:14px}
        </style>
        </head>
        <body>
        <header>
        <h1>mailin Export</h1>
        <input type="text" id="search" placeholder="Search emails by subject, sender, or content..." autocomplete="off">
        <span id="count"></span>
        </header>
        <div class="main">
        <div class="list" id="list"></div>
        <div class="detail" id="detail"><div class="detail-empty">Select an email to view</div></div>
        </div>
        <script>
        var DATA=\(emailJSON.replacingOccurrences(of: "</script>", with: "<\\/script>"));
        var listEl=document.getElementById("list"),detailEl=document.getElementById("detail"),searchEl=document.getElementById("search"),countEl=document.getElementById("count");
        var filtered=DATA.slice(),activeId=null;
        function esc(s){var d=document.createElement("div");d.textContent=s;return d.innerHTML}
        function render(){
            listEl.innerHTML="";
            if(filtered.length===0){listEl.innerHTML='<div class="no-results">No emails match your search.</div>';countEl.textContent="0 / "+DATA.length;return}
            countEl.textContent=filtered.length===DATA.length?DATA.length+" emails":filtered.length+" / "+DATA.length;
            filtered.forEach(function(e){
                var d=document.createElement("div");d.className="item"+(e.id===activeId?" active":"");
                d.innerHTML='<div class="subject">'+esc(e.subject)+'</div><div class="meta">'+esc(e.from)+' &mdash; '+esc(e.date)+'</div><div class="preview">'+esc(e.preview)+'</div>';
                d.onclick=function(){activeId=e.id;showDetail(e);render()};
                listEl.appendChild(d)
            })
        }
        function sanitizeHTML(s){return s.replace(/<script[^>]*>[\\s\\S]*?<\\/script>/gi,"").replace(/<iframe[^>]*>[\\s\\S]*?<\\/iframe>/gi,"").replace(/<embed[^>]*>/gi,"").replace(/<object[^>]*>[\\s\\S]*?<\\/object>/gi,"").replace(/<form[^>]*>[\\s\\S]*?<\\/form>/gi,"").replace(/\\son\\w+\\s*=/gi," data-removed=")}
        function showDetail(e){
            var isHTML=e.body.indexOf("<")!==-1&&e.body.indexOf(">")!==-1;
            var bodyContent=isHTML?sanitizeHTML(e.body):'<pre style="white-space:pre-wrap;font-family:inherit">'+esc(e.body)+'</pre>';
            detailEl.innerHTML='<h2>'+esc(e.subject)+'</h2>'
                +'<div class="hdr"><b>From:</b> '+esc(e.from)+'</div>'
                +'<div class="hdr"><b>To:</b> '+esc(e.to)+'</div>'
                +(e.cc?'<div class="hdr"><b>Cc:</b> '+esc(e.cc)+'</div>':'')
                +'<div class="hdr"><b>Date:</b> '+esc(e.date)+'</div>'
                +'<hr><div class="body">'+bodyContent+'</div>'
        }
        searchEl.addEventListener("input",function(){
            var q=searchEl.value.toLowerCase();
            if(!q){filtered=DATA.slice()}else{filtered=DATA.filter(function(e){return e.subject.toLowerCase().indexOf(q)!==-1||e.from.toLowerCase().indexOf(q)!==-1||e.body.toLowerCase().indexOf(q)!==-1})}
            render()
        });
        render();
        if(DATA.length>0){activeId=DATA[0].id;showDetail(DATA[0]);render()}
        </script>
        </body>
        </html>
        """
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

    // MARK: - Per-Email PDF Export

    static func exportIndividualPDFs(
        emails: [MBOXParser.RawEmail],
        to folder: URL,
        onProgress: ((Double) -> Void)? = nil
    ) -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        let total = Double(emails.count)
        var usedNames = Set<String>()

        for (index, email) in emails.enumerated() {
            let rawSubject = email.headers["Subject"] ?? "(No Subject)"
            let safeSubject = rawSubject
                .replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .prefix(50)
            var filename = "\(index + 1)_\(safeSubject).pdf"
            var counter = 1
            while usedNames.contains(filename) {
                filename = "\(index + 1)_\(safeSubject)_\(counter).pdf"
                counter += 1
            }
            usedNames.insert(filename)

            let pdfData = generateSinglePDF(email: email)
            let fileURL = folder.appendingPathComponent(filename)
            do {
                try pdfData.write(to: fileURL, options: .atomic)
                succeeded += 1
            } catch {
                failed += 1
            }
            onProgress?((Double(index + 1)) / total)
        }
        return (succeeded, failed)
    }

    private static func generateSinglePDF(email: MBOXParser.RawEmail) -> Data {
        #if os(macOS)
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let contentWidth = pageWidth - margin * 2

        let mutableData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: mutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let headerText = "From: \(email.headers["From"] ?? "")\nTo: \(email.headers["To"] ?? "")\nDate: \(email.headers["Date"] ?? "")\nSubject: \(email.headers["Subject"] ?? "")\n"
        let body = email.plainBody.isEmpty ? email.htmlBody.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : email.plainBody

        let fullText = headerText + "\n" + body
        let attributed = NSAttributedString(string: fullText, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.black
        ])

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var textRange = CFRange(location: 0, length: 0)
        let totalLength = attributed.length

        while textRange.location < totalLength {
            context.beginPage(mediaBox: &mediaBox)
            context.textMatrix = .identity
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)

            let framePath = CGPath(rect: CGRect(x: margin, y: margin, width: contentWidth, height: pageHeight - margin * 2), transform: nil)
            let ctFrame = CTFramesetterCreateFrame(framesetter, textRange, framePath, nil)

            context.saveGState()
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)
            CTFrameDraw(ctFrame, context)
            context.restoreGState()

            let visibleRange = CTFrameGetVisibleStringRange(ctFrame)
            textRange.location += visibleRange.length
            if visibleRange.length == 0 { break }

            context.endPage()
        }

        context.closePDF()
        return mutableData as Data
        #else
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let text = "From: \(email.headers["From"] ?? "")\nTo: \(email.headers["To"] ?? "")\nSubject: \(email.headers["Subject"] ?? "")\n\n\(body)"
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            (text as NSString).draw(in: CGRect(x: 50, y: 50, width: 512, height: 692), withAttributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .paragraphStyle: paragraphStyle
            ])
        }
        #endif
    }

    // MARK: - Privilege Log Generation

    static func generatePrivilegeLog(
        emails: [MBOXParser.RawEmail],
        batesPrefix: String = "PRIV",
        privilegeBasis: [UUID: String] = [:]
    ) -> String {
        var csv = "Bates Start,Bates End,Date,From,To,Cc,Subject,Privilege Basis,Document Type\n"

        for (index, email) in emails.enumerated() {
            let batesNum = String(format: "%@-%06d", batesPrefix, index + 1)
            let date = email.headers["Date"] ?? ""
            let from = escapeCSV(email.headers["From"] ?? "")
            let to = escapeCSV(email.headers["To"] ?? "")
            let cc = escapeCSV(email.headers["Cc"] ?? "")
            let subject = escapeCSV(email.headers["Subject"] ?? "")
            let basis = escapeCSV(privilegeBasis[email.id] ?? "Attorney-Client Communication")
            let docType = email.attachments.isEmpty ? "Email" : "Email with Attachments"
            csv += "\(batesNum),\(batesNum),\"\(date)\",\"\(from)\",\"\(to)\",\"\(cc)\",\"\(subject)\",\"\(basis)\",\(docType)\n"
        }
        return csv
    }

    // MARK: - Header-Only CSV Export

    static func exportHeadersOnlyCSV(
        from emails: [MBOXParser.RawEmail],
        fields: [String] = ["Date", "From", "To", "Subject", "Cc", "Return-Path", "Received-SPF", "DKIM-Signature", "X-Originating-IP", "Message-ID"]
    ) -> String {
        var csv = fields.map { escapeCSV($0) }.joined(separator: ",") + "\n"
        for email in emails {
            let row = fields.map { field -> String in
                escapeCSV(email.headers[field] ?? "")
            }
            csv += row.joined(separator: ",") + "\n"
        }
        return csv
    }

    private static func escapeCSV(_ text: String) -> String {
        var val = text.replacingOccurrences(of: "\"", with: "\"\"")
        if let first = val.first, "=+@-\t\r".contains(first) {
            val = "'" + val
        }
        if val.contains(",") || val.contains("\"") || val.contains("\n") || val.contains("'") {
            return "\"\(val)\""
        }
        return val
    }

    private static func parseEmailAddress(_ raw: String) -> (name: String, email: String) {
        if let angleStart = raw.firstIndex(of: "<"), let angleEnd = raw.firstIndex(of: ">"), angleStart < angleEnd {
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
