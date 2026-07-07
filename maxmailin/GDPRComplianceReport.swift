//
//  GDPRComplianceReport.swift
//  mailin
//
//  GDPR/privacy compliance report generator.
//  Produces a PDF Data Protection Impact Assessment for a specified data subject.
//

import Foundation
import CoreGraphics
import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - GDPRComplianceReport

struct GDPRComplianceReport {

    // MARK: - Page Constants

    private static let pageWidth: CGFloat = 612   // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54
    private static let contentWidth: CGFloat = 612 - 54 * 2  // 504
    private static let lineSpacing: CGFloat = 4
    private static let sectionSpacing: CGFloat = 16

    // MARK: - Drawing State

    private class DrawingState {
        var currentY: CGFloat = 0
        var pageNumber: Int = 0
        var mediaBox: CGRect
        let context: CGContext

        init(context: CGContext, mediaBox: CGRect) {
            self.context = context
            self.mediaBox = mediaBox
        }
    }

    // MARK: - Font Helpers

    private static var titleFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 22, weight: .bold)
    }

    private static var heading1Font: PlatformFont {
        PlatformFont.systemFont(ofSize: 15, weight: .bold)
    }

    private static var heading2Font: PlatformFont {
        PlatformFont.systemFont(ofSize: 12, weight: .semibold)
    }

    private static var bodyFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 10, weight: .regular)
    }

    private static var bodyBoldFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 10, weight: .bold)
    }

    private static var captionFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 8, weight: .medium)
    }

    private static var monoFont: PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    }

    // MARK: - Color Helpers

    private static var labelColor: PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.1, alpha: 1.0)
        #else
        return UIColor(white: 0.1, alpha: 1.0)
        #endif
    }

    private static var secondaryColor: PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.4, alpha: 1.0)
        #else
        return UIColor(white: 0.4, alpha: 1.0)
        #endif
    }

    private static var separatorColor: PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.8, alpha: 1.0)
        #else
        return UIColor(white: 0.8, alpha: 1.0)
        #endif
    }

    private static var accentColor: PlatformColor {
        #if os(macOS)
        return .systemBlue
        #else
        return .systemBlue
        #endif
    }

    private static var warningColor: PlatformColor {
        #if os(macOS)
        return .systemOrange
        #else
        return .systemOrange
        #endif
    }

    private static var errorColor: PlatformColor {
        #if os(macOS)
        return .systemRed
        #else
        return .systemRed
        #endif
    }

    // MARK: - Attribute Dictionaries

    private static var titleAttrs: [NSAttributedString.Key: Any] {
        [.font: titleFont, .foregroundColor: labelColor]
    }

    private static var h1Attrs: [NSAttributedString.Key: Any] {
        [.font: heading1Font, .foregroundColor: labelColor]
    }

    private static var h2Attrs: [NSAttributedString.Key: Any] {
        [.font: heading2Font, .foregroundColor: labelColor]
    }

    private static var bodyAttrs: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: labelColor]
    }

    private static var bodyBoldAttrs: [NSAttributedString.Key: Any] {
        [.font: bodyBoldFont, .foregroundColor: labelColor]
    }

    private static var captionAttrs: [NSAttributedString.Key: Any] {
        [.font: captionFont, .foregroundColor: secondaryColor]
    }

    private static var monoAttrs: [NSAttributedString.Key: Any] {
        [.font: monoFont, .foregroundColor: labelColor]
    }

    // MARK: - Public API

    /// Generate a GDPR Data Protection Impact Assessment PDF for the given data subject.
    static func generate(emails: [MBOXParser.RawEmail], dataSubject: String) async -> Data {
        var aiInsights: String?
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let subjectLower = dataSubject.lowercased()
            let subjectEmails = emails.filter { email in
                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                return from.contains(subjectLower) || to.contains(subjectLower)
            }
            if !subjectEmails.isEmpty {
                aiInsights = await FoundationModelEngine.enhanceWithAI(
                    scope: .security,
                    emails: subjectEmails,
                    context: "GDPR compliance analysis for data subject: \(dataSubject). Focus on PII exposure, data flow risks, and retention concerns."
                )
            }
        }
        #endif
        return generateSync(emails: emails, dataSubject: dataSubject, aiInsights: aiInsights)
    }

    static func generateSync(emails: [MBOXParser.RawEmail], dataSubject: String, aiInsights: String? = nil) -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let pdfData = NSMutableData()

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return createMinimalPDF()
        }

        let state = DrawingState(context: context, mediaBox: mediaBox)

        // Filter emails involving the data subject
        let subjectLower = dataSubject.lowercased()
        let subjectEmails = emails.filter { email in
            let from = (email.headers["From"] ?? "").lowercased()
            let to = (email.headers["To"] ?? "").lowercased()
            let cc = (email.headers["Cc"] ?? email.headers["CC"] ?? "").lowercased()
            let bcc = (email.headers["Bcc"] ?? email.headers["BCC"] ?? "").lowercased()
            let body = email.plainBody.lowercased()
            return from.contains(subjectLower) ||
                   to.contains(subjectLower) ||
                   cc.contains(subjectLower) ||
                   bcc.contains(subjectLower) ||
                   body.contains(subjectLower)
        }

        // Run analyses
        let piiFindings = EmailNLPEngine.detectPII(in: subjectEmails)
        let phishingFlags = EmailNLPEngine.detectPhishing(in: subjectEmails)
        let piiSummary = EmailNLPEngine.piiSummary(in: subjectEmails)
        let dates = subjectEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let recipients = collectRecipients(from: subjectEmails)

        // === Cover Page ===
        drawCoverPage(state: state, dataSubject: dataSubject, emailCount: subjectEmails.count, totalEmails: emails.count)

        // === Data Subject Identification ===
        finishAndStartNewPage(state: state)
        drawDataSubjectSection(state: state, dataSubject: dataSubject, subjectEmails: subjectEmails, dates: dates)

        // === Data Inventory ===
        ensureSpace(state: state, needed: 100)
        drawDataInventory(state: state, piiSummary: piiSummary, piiFindings: piiFindings)

        // === Data Flow ===
        finishAndStartNewPage(state: state)
        drawDataFlowSection(state: state, recipients: recipients, dataSubject: dataSubject)

        // === Retention Analysis ===
        ensureSpace(state: state, needed: 120)
        drawRetentionAnalysis(state: state, dates: dates, emailCount: subjectEmails.count)

        // === Risk Assessment ===
        finishAndStartNewPage(state: state)
        drawRiskAssessment(state: state, phishingFlags: phishingFlags, subjectEmails: subjectEmails, piiFindings: piiFindings)

        // === Recommendations ===
        ensureSpace(state: state, needed: 160)
        drawRecommendations(state: state, piiSummary: piiSummary, phishingFlags: phishingFlags, subjectEmails: subjectEmails)

        // === AI-Enhanced Analysis (optional) ===
        if let aiInsights, !aiInsights.isEmpty {
            finishAndStartNewPage(state: state)
            drawAIInsightsSection(state: state, insights: aiInsights)
        }

        // === Right to Erasure ===
        finishAndStartNewPage(state: state)
        drawRightToErasure(state: state, subjectEmails: subjectEmails, dataSubject: dataSubject)

        // Close final page
        popGraphicsContext()
        drawPageFooter(state: state)
        context.endPage()
        context.closePDF()

        return pdfData as Data
    }

    // MARK: - Page Management

    private static func startNewPage(state: DrawingState) {
        state.pageNumber += 1
        state.context.beginPage(mediaBox: &state.mediaBox)
        pushGraphicsContext(state.context)
        state.currentY = pageHeight - margin
    }

    private static func finishAndStartNewPage(state: DrawingState) {
        if state.pageNumber > 0 {
            popGraphicsContext()
            drawPageFooter(state: state)
            state.context.endPage()
        }
        startNewPage(state: state)
    }

    private static func ensureSpace(state: DrawingState, needed: CGFloat) {
        if state.currentY - needed < margin + 40 {
            finishAndStartNewPage(state: state)
        }
    }

    // MARK: - Graphics Context Helpers

    private static func pushGraphicsContext(_ context: CGContext) {
        #if os(macOS)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        #else
        UIGraphicsPushContext(context)
        #endif
    }

    private static func popGraphicsContext() {
        #if os(macOS)
        NSGraphicsContext.current = nil
        #else
        UIGraphicsPopContext()
        #endif
    }

    // MARK: - Drawing Primitives

    @discardableResult
    private static func drawText(
        _ text: String,
        attrs: [NSAttributedString.Key: Any],
        state: DrawingState,
        x: CGFloat? = nil,
        maxWidth: CGFloat? = nil
    ) -> CGFloat {
        let drawX = x ?? margin
        let drawWidth = maxWidth ?? (pageWidth - margin - drawX)
        let nsText = text as NSString
        let constrainedSize = CGSize(width: drawWidth, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = nsText.boundingRect(
            with: constrainedSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        let height = ceil(boundingRect.height)
        ensureSpace(state: state, needed: height + lineSpacing)

        let drawRect = CGRect(x: drawX, y: state.currentY - height, width: drawWidth, height: height)
        nsText.draw(in: drawRect, withAttributes: attrs)
        state.currentY -= (height + lineSpacing)
        return height
    }

    private static func drawSeparator(state: DrawingState, color: PlatformColor? = nil, lineWidth: CGFloat = 0.5) {
        ensureSpace(state: state, needed: 12)
        let drawColor = color ?? separatorColor
        state.context.setStrokeColor(drawColor.cgColor)
        state.context.setLineWidth(lineWidth)
        state.context.move(to: CGPoint(x: margin, y: state.currentY))
        state.context.addLine(to: CGPoint(x: pageWidth - margin, y: state.currentY))
        state.context.strokePath()
        state.currentY -= 10
    }

    private static func drawFilledRect(state: DrawingState, rect: CGRect, color: PlatformColor) {
        state.context.setFillColor(color.cgColor)
        state.context.fill(rect)
    }

    private static func drawSectionHeader(_ title: String, state: DrawingState) {
        state.currentY -= sectionSpacing
        ensureSpace(state: state, needed: 30)

        let barRect = CGRect(x: margin, y: state.currentY - 2, width: 4, height: 18)
        drawFilledRect(state: state, rect: barRect, color: accentColor)

        drawText(title, attrs: h1Attrs, state: state, x: margin + 10)
        state.currentY -= 4
        drawSeparator(state: state, color: accentColor, lineWidth: 1.0)
    }

    private static func drawPageFooter(state: DrawingState) {
        pushGraphicsContext(state.context)

        let footerY: CGFloat = margin - 22

        state.context.setStrokeColor(separatorColor.cgColor)
        state.context.setLineWidth(0.5)
        state.context.move(to: CGPoint(x: margin, y: footerY + 14))
        state.context.addLine(to: CGPoint(x: pageWidth - margin, y: footerY + 14))
        state.context.strokePath()

        let leftText = "GDPR Data Protection Impact Assessment"
        (leftText as NSString).draw(at: CGPoint(x: margin, y: footerY), withAttributes: captionAttrs)

        let rightText = "Page \(state.pageNumber)"
        let rightSize = (rightText as NSString).size(withAttributes: captionAttrs)
        (rightText as NSString).draw(
            at: CGPoint(x: pageWidth - margin - rightSize.width, y: footerY),
            withAttributes: captionAttrs
        )

        let centerText = "CONFIDENTIAL"
        let centerSize = (centerText as NSString).size(withAttributes: captionAttrs)
        (centerText as NSString).draw(
            at: CGPoint(x: (pageWidth - centerSize.width) / 2, y: footerY),
            withAttributes: captionAttrs
        )

        popGraphicsContext()
    }

    // MARK: - Cover Page

    private static func drawCoverPage(state: DrawingState, dataSubject: String, emailCount: Int, totalEmails: Int) {
        startNewPage(state: state)

        state.currentY = pageHeight - margin - 100

        let title = "Data Protection Impact Assessment"
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let titleX = max(margin, (pageWidth - titleSize.width) / 2)
        (title as NSString).draw(at: CGPoint(x: titleX, y: state.currentY), withAttributes: titleAttrs)
        state.currentY -= titleSize.height + 8

        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: heading2Font,
            .foregroundColor: secondaryColor
        ]
        let subtitle = "GDPR Compliance Report"
        let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttrs)
        (subtitle as NSString).draw(
            at: CGPoint(x: (pageWidth - subtitleSize.width) / 2, y: state.currentY),
            withAttributes: subtitleAttrs
        )
        state.currentY -= subtitleSize.height + 30

        drawSeparator(state: state, color: accentColor, lineWidth: 2.0)
        state.currentY -= 20

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        let metaItems: [(String, String)] = [
            ("Data Subject", dataSubject),
            ("Report Generated", dateFormatter.string(from: Date())),
            ("", ""),
            ("Emails Involving Subject", "\(emailCount) of \(totalEmails) total"),
            ("Analysis Scope", "PII detection, phishing assessment, data flow mapping"),
            ("Processing Basis", "On-device analysis only -- no data transmitted externally"),
        ]

        for (label, value) in metaItems {
            if label.isEmpty {
                state.currentY -= 8
                continue
            }
            drawText("\(label):  \(value)", attrs: bodyAttrs, state: state, x: margin + 40)
        }

        state.currentY -= 40

        let disclaimer = "CONFIDENTIAL -- This report is generated for GDPR compliance purposes. All analysis is performed entirely on-device using Apple NaturalLanguage framework. No personal data is transmitted to external servers during report generation."
        drawText(disclaimer, attrs: captionAttrs, state: state, x: margin + 20, maxWidth: contentWidth - 40)
    }

    // MARK: - Data Subject Identification

    private static func drawDataSubjectSection(
        state: DrawingState,
        dataSubject: String,
        subjectEmails: [MBOXParser.RawEmail],
        dates: [Date]
    ) {
        drawSectionHeader("1. Data Subject Identification", state: state)

        drawText("Data Subject: \(dataSubject)", attrs: bodyBoldAttrs, state: state)
        drawText("Total emails involving this data subject: \(subjectEmails.count)", attrs: bodyAttrs, state: state)
        state.currentY -= 4

        let sentBySubject = subjectEmails.filter { ($0.headers["From"] ?? "").lowercased().contains(dataSubject.lowercased()) }
        let receivedBySubject = subjectEmails.filter { email in
            let to = (email.headers["To"] ?? "").lowercased()
            let cc = (email.headers["Cc"] ?? email.headers["CC"] ?? "").lowercased()
            return to.contains(dataSubject.lowercased()) || cc.contains(dataSubject.lowercased())
        }
        let mentionedInBody = subjectEmails.filter { $0.plainBody.lowercased().contains(dataSubject.lowercased()) }

        drawText("Emails sent by subject: \(sentBySubject.count)", attrs: bodyAttrs, state: state)
        drawText("Emails received by subject: \(receivedBySubject.count)", attrs: bodyAttrs, state: state)
        drawText("Emails mentioning subject in body: \(mentionedInBody.count)", attrs: bodyAttrs, state: state)
        state.currentY -= 4

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        if let earliest = dates.first, let latest = dates.last {
            drawText("Earliest record: \(dateFormatter.string(from: earliest))", attrs: bodyAttrs, state: state)
            drawText("Latest record: \(dateFormatter.string(from: latest))", attrs: bodyAttrs, state: state)
        } else {
            drawText("Date range: Unable to determine", attrs: bodyAttrs, state: state)
        }
    }

    // MARK: - Data Inventory

    private static func drawDataInventory(
        state: DrawingState,
        piiSummary: [EmailNLPEngine.PIIType: Int],
        piiFindings: [EmailNLPEngine.PIIFinding]
    ) {
        drawSectionHeader("2. Personal Data Inventory", state: state)

        drawText("The following categories of personal data were detected using on-device NLP analysis:", attrs: bodyAttrs, state: state)
        state.currentY -= 4

        if piiSummary.isEmpty {
            drawText("No PII detected in the emails involving this data subject.", attrs: bodyAttrs, state: state)
        } else {
            let sortedPII = piiSummary.sorted { $0.value > $1.value }
            for (type, count) in sortedPII {
                let riskIndicator: String
                switch type {
                case .ssnPattern, .creditCard:
                    riskIndicator = "[HIGH RISK]"
                case .phoneNumber, .emailAddress:
                    riskIndicator = "[MEDIUM RISK]"
                default:
                    riskIndicator = "[LOW RISK]"
                }
                drawText("  \(type.rawValue): \(count) instance(s) \(riskIndicator)", attrs: bodyAttrs, state: state)
            }

            let totalPII = piiSummary.values.reduce(0, +)
            state.currentY -= 4
            drawText("Total PII instances detected: \(totalPII)", attrs: bodyBoldAttrs, state: state)
        }
    }

    // MARK: - Data Flow

    private static func drawDataFlowSection(
        state: DrawingState,
        recipients: [(address: String, count: Int)],
        dataSubject: String
    ) {
        drawSectionHeader("3. Data Flow Analysis", state: state)

        drawText("This section identifies all parties with whom the data subject's information has been shared.", attrs: bodyAttrs, state: state)
        state.currentY -= 4

        if recipients.isEmpty {
            drawText("No external recipients identified.", attrs: bodyAttrs, state: state)
        } else {
            drawText("Recipients (sorted by frequency):", attrs: bodyBoldAttrs, state: state)
            state.currentY -= 2

            for (index, recipient) in recipients.prefix(30).enumerated() {
                ensureSpace(state: state, needed: 14)
                let truncated = String(recipient.address.prefix(60))
                drawText("  \(index + 1). \(truncated) (\(recipient.count) emails)", attrs: monoAttrs, state: state)
            }

            if recipients.count > 30 {
                drawText("  ... and \(recipients.count - 30) more recipients", attrs: captionAttrs, state: state)
            }

            // Extract unique domains
            let domains = Set(recipients.compactMap { addr -> String? in
                guard let atIndex = addr.address.lastIndex(of: "@") else { return nil }
                return String(addr.address[addr.address.index(after: atIndex)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "> \t\r\n"))
                    .lowercased()
            })

            state.currentY -= 8
            drawText("Unique domains data was shared with: \(domains.count)", attrs: bodyBoldAttrs, state: state)
            for domain in domains.sorted().prefix(20) {
                drawText("  - \(domain)", attrs: bodyAttrs, state: state)
            }
        }
    }

    // MARK: - Retention Analysis

    private static func drawRetentionAnalysis(state: DrawingState, dates: [Date], emailCount: Int) {
        drawSectionHeader("4. Retention Analysis", state: state)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long

        if let earliest = dates.first, let latest = dates.last {
            let daySpan = Calendar.current.dateComponents([.day], from: earliest, to: latest).day ?? 0
            let yearSpan = Calendar.current.dateComponents([.year], from: earliest, to: latest).year ?? 0

            drawText("Data retention period:", attrs: bodyBoldAttrs, state: state)
            drawText("  Earliest record: \(dateFormatter.string(from: earliest))", attrs: bodyAttrs, state: state)
            drawText("  Latest record: \(dateFormatter.string(from: latest))", attrs: bodyAttrs, state: state)
            drawText("  Span: \(daySpan) days (~\(yearSpan) years)", attrs: bodyAttrs, state: state)
            drawText("  Total records: \(emailCount)", attrs: bodyAttrs, state: state)
            state.currentY -= 4

            // Age assessment
            let ageInDays = Calendar.current.dateComponents([.day], from: earliest, to: Date()).day ?? 0
            if ageInDays > 2190 { // > 6 years
                drawText("WARNING: Data older than 6 years detected. Review retention necessity under GDPR Article 5(1)(e) -- storage limitation principle.", attrs: bodyBoldAttrs, state: state)
            } else if ageInDays > 1095 { // > 3 years
                drawText("NOTE: Data spans more than 3 years. Consider whether continued retention is justified under your lawful basis.", attrs: bodyAttrs, state: state)
            }
        } else {
            drawText("Unable to determine retention period -- no valid dates found.", attrs: bodyAttrs, state: state)
        }
    }

    // MARK: - Risk Assessment

    private static func drawRiskAssessment(
        state: DrawingState,
        phishingFlags: [EmailNLPEngine.PhishingFlag],
        subjectEmails: [MBOXParser.RawEmail],
        piiFindings: [EmailNLPEngine.PIIFinding]
    ) {
        drawSectionHeader("5. Risk Assessment", state: state)

        // Phishing risks
        drawText("5.1 Phishing & Social Engineering Risks", attrs: h2Attrs, state: state)
        state.currentY -= 2

        if phishingFlags.isEmpty {
            drawText("No phishing indicators detected in emails involving the data subject.", attrs: bodyAttrs, state: state)
        } else {
            let highRisk = phishingFlags.filter { $0.riskLevel == .high }
            let mediumRisk = phishingFlags.filter { $0.riskLevel == .medium }
            let lowRisk = phishingFlags.filter { $0.riskLevel == .low }

            drawText("Phishing flags detected: \(phishingFlags.count) total", attrs: bodyBoldAttrs, state: state)
            drawText("  High risk: \(highRisk.count)", attrs: bodyAttrs, state: state)
            drawText("  Medium risk: \(mediumRisk.count)", attrs: bodyAttrs, state: state)
            drawText("  Low risk: \(lowRisk.count)", attrs: bodyAttrs, state: state)
        }

        state.currentY -= 8

        // Anomalies
        drawText("5.2 Data Anomalies", attrs: h2Attrs, state: state)
        state.currentY -= 2

        let emailsWithAnomalies = subjectEmails.filter { !$0.anomalies.isEmpty }
        if emailsWithAnomalies.isEmpty {
            drawText("No structural anomalies detected.", attrs: bodyAttrs, state: state)
        } else {
            drawText("Emails with anomalies: \(emailsWithAnomalies.count)", attrs: bodyAttrs, state: state)
            var anomalyCounts: [String: Int] = [:]
            for email in emailsWithAnomalies {
                for anomaly in email.anomalies {
                    anomalyCounts[anomaly, default: 0] += 1
                }
            }
            for (anomaly, count) in anomalyCounts.sorted(by: { $0.value > $1.value }) {
                drawText("  - \(anomaly): \(count) occurrence(s)", attrs: bodyAttrs, state: state)
            }
        }

        state.currentY -= 8

        // PII Exposure
        drawText("5.3 PII Exposure Risk", attrs: h2Attrs, state: state)
        state.currentY -= 2

        if piiFindings.isEmpty {
            drawText("No PII exposure detected.", attrs: bodyAttrs, state: state)
        } else {
            let ssnCount = piiFindings.filter { $0.type == .ssnPattern }.count
            let ccCount = piiFindings.filter { $0.type == .creditCard }.count

            drawText("Total PII instances found: \(piiFindings.count)", attrs: bodyBoldAttrs, state: state)

            if ssnCount > 0 || ccCount > 0 {
                drawText("CRITICAL: Highly sensitive PII detected (SSN: \(ssnCount), Credit Card: \(ccCount)). Immediate review recommended.", attrs: bodyBoldAttrs, state: state)
            }
        }
    }

    // MARK: - Recommendations

    private static func drawRecommendations(
        state: DrawingState,
        piiSummary: [EmailNLPEngine.PIIType: Int],
        phishingFlags: [EmailNLPEngine.PhishingFlag],
        subjectEmails: [MBOXParser.RawEmail]
    ) {
        drawSectionHeader("6. Recommendations", state: state)

        var recommendations: [(priority: String, text: String)] = []

        // PII-based recommendations
        let hasSensitivePII = piiSummary.keys.contains(where: { $0 == .ssnPattern || $0 == .creditCard })
        if hasSensitivePII {
            recommendations.append((
                "CRITICAL",
                "Highly sensitive PII (SSN/Credit Card) detected. Apply redaction before any data export or sharing. Consider whether retention of this data is necessary."
            ))
        }

        if !piiSummary.isEmpty {
            recommendations.append((
                "HIGH",
                "Personal data detected across \(piiSummary.count) categories. Ensure a documented lawful basis exists under GDPR Article 6 for processing this data."
            ))
        }

        // Phishing recommendations
        if !phishingFlags.isEmpty {
            recommendations.append((
                "HIGH",
                "Phishing indicators detected in \(phishingFlags.count) email(s). Investigate potential data breach under GDPR Article 33 (72-hour notification requirement)."
            ))
        }

        // Retention recommendations
        let dates = subjectEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        if let oldest = dates.first {
            let ageInDays = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
            if ageInDays > 2190 {
                recommendations.append((
                    "MEDIUM",
                    "Data older than 6 years. Review under storage limitation principle (Article 5(1)(e)). Delete data no longer necessary for the original purpose."
                ))
            }
        }

        // General recommendations
        recommendations.append((
            "STANDARD",
            "Document the lawful basis for processing this data subject's information in your Record of Processing Activities (ROPA)."
        ))
        recommendations.append((
            "STANDARD",
            "Ensure data subject access request (DSAR) procedures are in place to respond within the 30-day GDPR deadline."
        ))
        recommendations.append((
            "STANDARD",
            "Consider implementing automated PII redaction (available in mailin) before exporting or sharing email archives containing personal data."
        ))

        for (index, rec) in recommendations.enumerated() {
            ensureSpace(state: state, needed: 30)
            drawText("\(index + 1). [\(rec.priority)] \(rec.text)", attrs: bodyAttrs, state: state)
            state.currentY -= 2
        }
    }

    // MARK: - Right to Erasure

    private static func drawAIInsightsSection(state: DrawingState, insights: String) {
        drawSectionHeader("AI-Enhanced Analysis", state: state)

        let disclaimer = "Note: The following analysis was generated by on-device Apple AI and is non-deterministic. It supplements but does not replace the deterministic NLP analysis in preceding sections."
        drawText(disclaimer, attrs: captionAttrs, state: state, maxWidth: contentWidth)
        state.currentY -= 8

        let paragraphs = insights.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for paragraph in paragraphs {
            ensureSpace(state: state, needed: 20)
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") || trimmed.hasPrefix("**") || trimmed.hasSuffix(":") {
                let clean = trimmed
                    .replacingOccurrences(of: "##", with: "")
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespaces)
                drawText(clean, attrs: h2Attrs, state: state)
            } else {
                drawText(trimmed, attrs: bodyAttrs, state: state, maxWidth: contentWidth)
            }
            state.currentY -= 2
        }
        state.currentY -= sectionSpacing
    }

    private static func drawRightToErasure(
        state: DrawingState,
        subjectEmails: [MBOXParser.RawEmail],
        dataSubject: String
    ) {
        drawSectionHeader("7. Right to Erasure (Article 17)", state: state)

        drawText(
            "Under GDPR Article 17, the data subject has the right to request erasure of their personal data. Below is a complete inventory of emails that would need to be addressed in an erasure request.",
            attrs: bodyAttrs,
            state: state
        )
        state.currentY -= 4

        drawText("Total emails containing data subject information: \(subjectEmails.count)", attrs: bodyBoldAttrs, state: state)
        state.currentY -= 4

        if subjectEmails.isEmpty {
            drawText("No emails found involving this data subject.", attrs: bodyAttrs, state: state)
        } else {
            // List emails (limited to first 50 for PDF size)
            let displayLimit = min(subjectEmails.count, 50)
            for (index, email) in subjectEmails.prefix(displayLimit).enumerated() {
                ensureSpace(state: state, needed: 40)

                let subject = String((email.headers["Subject"] ?? "(No Subject)").prefix(60))
                let from = String((email.headers["From"] ?? "Unknown").prefix(50))
                let date = String((email.headers["Date"] ?? "N/A").prefix(30))
                let messageID = String((email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? "N/A").prefix(50))

                drawText("\(index + 1). \(subject)", attrs: h2Attrs, state: state)
                drawText("   From: \(from)  |  Date: \(date)", attrs: monoAttrs, state: state)
                drawText("   Message-ID: \(messageID)", attrs: captionAttrs, state: state)
                state.currentY -= 2
            }

            if subjectEmails.count > displayLimit {
                state.currentY -= 4
                drawText("... and \(subjectEmails.count - displayLimit) additional emails (see full export for complete list).", attrs: captionAttrs, state: state)
            }
        }

        state.currentY -= sectionSpacing

        // Disclaimer
        drawSeparator(state: state)
        drawText(
            "DISCLAIMER: This report is an analytical tool generated by mailin for informational purposes. It does not constitute legal advice. Organizations must independently verify compliance requirements and consult qualified legal counsel for GDPR obligations. All analysis was performed on-device with no external data transmission.",
            attrs: captionAttrs,
            state: state,
            x: margin + 10,
            maxWidth: contentWidth - 20
        )
    }

    // MARK: - Helpers

    private static func collectRecipients(from emails: [MBOXParser.RawEmail]) -> [(address: String, count: Int)] {
        var recipientCounts: [String: Int] = [:]

        for email in emails {
            let fields = ["To", "Cc", "CC", "Bcc", "BCC"]
            for field in fields {
                guard let value = email.headers[field] else { continue }
                let addresses = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                for addr in addresses where !addr.isEmpty {
                    recipientCounts[addr, default: 0] += 1
                }
            }
        }

        return recipientCounts
            .sorted { $0.value > $1.value }
            .map { (address: $0.key, count: $0.value) }
    }

    private static func createMinimalPDF() -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            let minimalPDF = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n178\n%%EOF"
            return minimalPDF.data(using: .ascii) ?? Data()
        }

        ctx.beginPage(mediaBox: &mediaBox)
        ctx.endPage()
        ctx.closePDF()

        return pdfData as Data
    }
}
