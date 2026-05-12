import Foundation
import CoreGraphics
import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Investigation Report Generator
// Generates a multi-page PDF forensic investigation report from parsed email data.
// Uses raw Core Graphics for drawing to maintain full control over layout.

struct InvestigationReportGenerator {

    // MARK: - Configuration Constants

    private static let pageWidth: CGFloat = 612   // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54
    private static let contentWidth: CGFloat = 612 - 54 * 2  // 504
    private static let lineSpacing: CGFloat = 4
    private static let sectionSpacing: CGFloat = 16
    private static let maxSampleEmails = 20

    // MARK: - Drawing State

    private class DrawingState {
        var currentY: CGFloat = 0
        var pageNumber: Int = 0
        var mediaBox: CGRect
        let context: CGContext
        let title: String
        let investigatorName: String

        init(context: CGContext, mediaBox: CGRect, title: String, investigatorName: String) {
            self.context = context
            self.mediaBox = mediaBox
            self.title = title
            self.investigatorName = investigatorName
        }
    }

    // MARK: - Font & Color Helpers

    private static var titleFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 24, weight: .bold)
    }

    private static var heading1Font: PlatformFont {
        PlatformFont.systemFont(ofSize: 16, weight: .bold)
    }

    private static var heading2Font: PlatformFont {
        PlatformFont.systemFont(ofSize: 13, weight: .semibold)
    }

    private static var bodyFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 10, weight: .regular)
    }

    private static var bodyBoldFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 10, weight: .bold)
    }

    private static var monoFont: PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    }

    private static var captionFont: PlatformFont {
        PlatformFont.systemFont(ofSize: 8, weight: .medium)
    }

    private static var labelColor: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    private static var secondaryColor: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    private static var separatorColor: PlatformColor {
        #if os(macOS)
        return .separatorColor
        #else
        return .separator
        #endif
    }

    private static var accentBlue: PlatformColor {
        #if os(macOS)
        return .systemBlue
        #else
        return .systemBlue
        #endif
    }

    private static var chartGreen: PlatformColor {
        #if os(macOS)
        return NSColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1.0)
        #else
        return UIColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1.0)
        #endif
    }

    private static var chartOrange: PlatformColor {
        #if os(macOS)
        return NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1.0)
        #else
        return UIColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1.0)
        #endif
    }

    private static var chartRed: PlatformColor {
        #if os(macOS)
        return NSColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 1.0)
        #else
        return UIColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 1.0)
        #endif
    }

    // Attribute dictionaries
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

    private static var monoAttrs: [NSAttributedString.Key: Any] {
        [.font: monoFont, .foregroundColor: labelColor]
    }

    private static var captionAttrs: [NSAttributedString.Key: Any] {
        [.font: captionFont, .foregroundColor: secondaryColor]
    }

    // MARK: - Report Configuration

    struct ReportConfig {
        var caseNumber: String
        var examinerName: String
        var title: String
        var includeTimeline: Bool
        var includeContacts: Bool
        var includeSentiment: Bool
        var includePhishing: Bool
        var includePII: Bool
    }

    static func generate(
        emails: [MBOXParser.RawEmail],
        config: ReportConfig,
        senderEmail: String
    ) -> Data? {
        let data = generateReport(emails: emails, title: config.title, investigatorName: config.examinerName)
        return data.isEmpty ? nil : data
    }

    // MARK: - Public API

    /// Generate a PDF report from the given emails and return raw PDF data.
    static func generateReport(
        emails: [MBOXParser.RawEmail],
        title: String,
        investigatorName: String
    ) -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let pdfData = NSMutableData()

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            // Fallback: return an empty PDF
            return createMinimalPDF()
        }

        let state = DrawingState(
            context: context,
            mediaBox: mediaBox,
            title: title,
            investigatorName: investigatorName
        )

        // Pre-compute analysis data
        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let sentimentResults = EmailNLPEngine.analyzeSentiment(of: emails)
        let classification = EmailNLPEngine.classifyAll(emails)
        let topSenders = computeTopSenders(emails: emails, limit: 15)
        let monthlyVolume = computeMonthlyVolume(emails: emails)
        let contactDomains = computeContactDomains(emails: emails, limit: 15)
        let evidenceTags = collectEvidenceTags(emails: emails)
        let flaggedEmails = collectFlaggedEmails(emails: emails, limit: maxSampleEmails)

        // === Title Page ===
        drawTitlePage(state: state, emails: emails, dates: dates)

        // === Executive Summary ===
        finishAndStartNewPage(state: state)
        drawExecutiveSummary(
            state: state,
            emails: emails,
            dates: dates,
            topSenders: topSenders,
            sentimentResults: sentimentResults,
            classification: classification
        )

        // === Timeline Section ===
        finishAndStartNewPage(state: state)
        drawTimelineSection(state: state, monthlyVolume: monthlyVolume)

        // === Top Contacts Table ===
        ensureSpace(state: state, needed: 200)
        drawTopContactsTable(state: state, contacts: contactDomains)

        // === Category Breakdown ===
        finishAndStartNewPage(state: state)
        drawCategoryBreakdown(state: state, classification: classification, totalEmails: emails.count)

        // === Evidence Tags Summary ===
        ensureSpace(state: state, needed: 200)
        drawEvidenceTagsSummary(state: state, tags: evidenceTags)

        // === Flagged / Important Emails ===
        finishAndStartNewPage(state: state)
        drawFlaggedEmails(state: state, flaggedEmails: flaggedEmails)

        // Close the final page
        popGraphicsContext()
        drawPageFooter(state: state)
        context.endPage()
        context.closePDF()

        return pdfData as Data
    }

    /// Generate a PDF report, save it to a temp file, and return the file URL.
    static func generateAndSave(
        emails: [MBOXParser.RawEmail],
        title: String,
        investigatorName: String
    ) -> URL? {
        let data = generateReport(emails: emails, title: title, investigatorName: investigatorName)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let sanitizedTitle = title
            .replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            .prefix(40)
        let filename = "Investigation_\(sanitizedTitle)_\(timestamp).pdf"

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
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

    // MARK: - Drawing Primitives

    @discardableResult
    private static func drawText(
        _ text: String,
        attrs: [NSAttributedString.Key: Any],
        state: DrawingState,
        x: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        alignment: NSTextAlignment = .left
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

        var drawRect = CGRect(x: drawX, y: state.currentY - height, width: drawWidth, height: height)

        if alignment == .center {
            let textWidth = ceil(boundingRect.width)
            drawRect.origin.x = drawX + (drawWidth - textWidth) / 2
            drawRect.size.width = textWidth
        } else if alignment == .right {
            let textWidth = ceil(boundingRect.width)
            drawRect.origin.x = drawX + drawWidth - textWidth
            drawRect.size.width = textWidth
        }

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

    private static func drawHorizontalLine(
        state: DrawingState,
        fromX: CGFloat,
        toX: CGFloat,
        y: CGFloat,
        color: PlatformColor,
        lineWidth: CGFloat = 0.5
    ) {
        state.context.setStrokeColor(color.cgColor)
        state.context.setLineWidth(lineWidth)
        state.context.move(to: CGPoint(x: fromX, y: y))
        state.context.addLine(to: CGPoint(x: toX, y: y))
        state.context.strokePath()
    }

    private static func drawFilledRect(
        state: DrawingState,
        rect: CGRect,
        color: PlatformColor
    ) {
        state.context.setFillColor(color.cgColor)
        state.context.fill(rect)
    }

    private static func drawSectionHeader(_ title: String, state: DrawingState) {
        state.currentY -= sectionSpacing
        ensureSpace(state: state, needed: 30)

        // Draw a colored accent bar
        let barRect = CGRect(x: margin, y: state.currentY - 2, width: 4, height: 18)
        drawFilledRect(state: state, rect: barRect, color: accentBlue)

        drawText(title, attrs: h1Attrs, state: state, x: margin + 10)
        state.currentY -= 4
        drawSeparator(state: state, color: accentBlue, lineWidth: 1.0)
    }

    private static func drawPageFooter(state: DrawingState) {
        pushGraphicsContext(state.context)

        let footerY: CGFloat = margin - 22

        drawHorizontalLine(
            state: state,
            fromX: margin,
            toX: pageWidth - margin,
            y: footerY + 14,
            color: separatorColor,
            lineWidth: 0.5
        )

        let leftText = "mailin Investigation Report"
        (leftText as NSString).draw(
            at: CGPoint(x: margin, y: footerY),
            withAttributes: captionAttrs
        )

        let centerText = state.investigatorName.isEmpty ? "" : "Investigator: \(state.investigatorName)"
        if !centerText.isEmpty {
            let centerSize = (centerText as NSString).size(withAttributes: captionAttrs)
            (centerText as NSString).draw(
                at: CGPoint(x: (pageWidth - centerSize.width) / 2, y: footerY),
                withAttributes: captionAttrs
            )
        }

        let rightText = "Page \(state.pageNumber)"
        let rightSize = (rightText as NSString).size(withAttributes: captionAttrs)
        (rightText as NSString).draw(
            at: CGPoint(x: pageWidth - margin - rightSize.width, y: footerY),
            withAttributes: captionAttrs
        )

        popGraphicsContext()
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

    // MARK: - Title Page

    private static func drawTitlePage(
        state: DrawingState,
        emails: [MBOXParser.RawEmail],
        dates: [Date]
    ) {
        startNewPage(state: state)

        // Push title down for visual centering
        state.currentY = pageHeight - margin - 120

        // Report title
        let titleSize = (state.title as NSString).size(withAttributes: titleAttrs)
        let titleX = (pageWidth - titleSize.width) / 2
        (state.title as NSString).draw(
            at: CGPoint(x: max(margin, titleX), y: state.currentY),
            withAttributes: titleAttrs
        )
        state.currentY -= titleSize.height + 12

        // Subtitle
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: heading2Font,
            .foregroundColor: secondaryColor
        ]
        let subtitle = "Email Forensic Investigation Report"
        let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttrs)
        (subtitle as NSString).draw(
            at: CGPoint(x: (pageWidth - subtitleSize.width) / 2, y: state.currentY),
            withAttributes: subtitleAttrs
        )
        state.currentY -= subtitleSize.height + 40

        // Decorative line
        drawSeparator(state: state, color: accentBlue, lineWidth: 2.0)
        state.currentY -= 20

        // Report metadata
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        let dateRange: String
        if let first = dates.first, let last = dates.last {
            let rangeFormatter = DateFormatter()
            rangeFormatter.dateStyle = .medium
            dateRange = "\(rangeFormatter.string(from: first)) -- \(rangeFormatter.string(from: last))"
        } else {
            dateRange = "N/A"
        }

        let sentCount = emails.filter { $0.messageType == "sent" }.count
        let receivedCount = emails.filter { $0.messageType == "received" }.count
        let uniqueDomains = Set(emails.flatMap { $0.domains }).count

        let metaItems: [(String, String)] = [
            ("Investigator", state.investigatorName.isEmpty ? "N/A" : state.investigatorName),
            ("Report Generated", dateFormatter.string(from: Date())),
            ("", ""),  // spacer
            ("Total Emails Analyzed", "\(emails.count)"),
            ("Sent / Received", "\(sentCount) / \(receivedCount)"),
            ("Date Range of Emails", dateRange),
            ("Unique Domains", "\(uniqueDomains)"),
        ]

        for (label, value) in metaItems {
            if label.isEmpty {
                state.currentY -= 8
                continue
            }
            let line = "\(label):  \(value)"
            drawText(line, attrs: bodyAttrs, state: state, x: margin + 40)
        }

        state.currentY -= 40

        // Disclaimer
        let disclaimer = "CONFIDENTIAL -- This report was generated by mailin, a privacy-first email forensics tool. All analysis was performed entirely on-device. No email data was transmitted to external servers."
        drawText(disclaimer, attrs: captionAttrs, state: state, x: margin + 20, maxWidth: contentWidth - 40)

        state.currentY -= 12
        let generatedNote = "Generated on \(dateFormatter.string(from: Date())) using mailin Investigation Report Generator."
        drawText(generatedNote, attrs: captionAttrs, state: state, x: margin + 20, maxWidth: contentWidth - 40)
    }

    // MARK: - Executive Summary

    private static func drawExecutiveSummary(
        state: DrawingState,
        emails: [MBOXParser.RawEmail],
        dates: [Date],
        topSenders: [(address: String, count: Int)],
        sentimentResults: [EmailNLPEngine.SentimentResult],
        classification: [EmailNLPEngine.EmailCategory: Int]
    ) {
        drawSectionHeader("Executive Summary", state: state)

        // Date range
        let rangeFormatter = DateFormatter()
        rangeFormatter.dateStyle = .medium
        let dateRange: String
        if let first = dates.first, let last = dates.last {
            dateRange = "\(rangeFormatter.string(from: first)) to \(rangeFormatter.string(from: last))"
        } else {
            dateRange = "N/A"
        }

        let sentCount = emails.filter { $0.messageType == "sent" }.count
        let receivedCount = emails.filter { $0.messageType == "received" }.count

        drawText("Date Range: \(dateRange)", attrs: bodyAttrs, state: state)
        drawText("Total Emails: \(emails.count) (Sent: \(sentCount), Received: \(receivedCount))", attrs: bodyAttrs, state: state)
        state.currentY -= 8

        // Top Senders
        drawText("Top Senders:", attrs: bodyBoldAttrs, state: state)
        for (index, sender) in topSenders.prefix(5).enumerated() {
            let truncated = String(sender.address.prefix(50))
            drawText("  \(index + 1). \(truncated) (\(sender.count) emails)", attrs: bodyAttrs, state: state)
        }
        state.currentY -= 8

        // Sentiment Breakdown
        drawText("Sentiment Breakdown:", attrs: bodyBoldAttrs, state: state)
        if sentimentResults.isEmpty {
            drawText("  No sentiment data available.", attrs: bodyAttrs, state: state)
        } else {
            let avgScore = sentimentResults.map(\.score).reduce(0, +) / Double(sentimentResults.count)
            let positiveCount = sentimentResults.filter { $0.score > 0.4 }.count
            let negativeCount = sentimentResults.filter { $0.score < -0.4 }.count
            let neutralCount = sentimentResults.count - positiveCount - negativeCount
            let overallLabel: String
            if avgScore > 0.4 { overallLabel = "Positive" }
            else if avgScore < -0.4 { overallLabel = "Negative" }
            else { overallLabel = "Neutral" }

            drawText("  Overall: \(overallLabel) (avg score: \(String(format: "%.3f", avgScore)))", attrs: bodyAttrs, state: state)
            drawText("  Positive: \(positiveCount)  |  Neutral: \(neutralCount)  |  Negative: \(negativeCount)", attrs: bodyAttrs, state: state)

            // Draw a simple sentiment bar
            state.currentY -= 4
            let barY = state.currentY
            let barHeight: CGFloat = 12
            let barWidth: CGFloat = contentWidth - 40
            let barX = margin + 20
            let total = max(1.0, Double(sentimentResults.count))

            // Background
            let bgRect = CGRect(x: barX, y: barY - barHeight, width: barWidth, height: barHeight)
            drawFilledRect(state: state, rect: bgRect, color: separatorColor)

            // Positive (green)
            if positiveCount > 0 {
                let posWidth = CGFloat(Double(positiveCount) / total) * barWidth
                drawFilledRect(state: state, rect: CGRect(x: barX, y: barY - barHeight, width: posWidth, height: barHeight), color: chartGreen)
            }

            // Negative (red) from right
            if negativeCount > 0 {
                let negWidth = CGFloat(Double(negativeCount) / total) * barWidth
                drawFilledRect(state: state, rect: CGRect(x: barX + barWidth - negWidth, y: barY - barHeight, width: negWidth, height: barHeight), color: chartRed)
            }

            state.currentY -= (barHeight + 8)

            // Legend
            drawText("  [Green = Positive]  [Gray = Neutral]  [Red = Negative]", attrs: captionAttrs, state: state)
        }

        state.currentY -= 8

        // Category summary (brief)
        drawText("Email Categories:", attrs: bodyBoldAttrs, state: state)
        let sortedCats = classification.sorted { $0.value > $1.value }
        let catLine = sortedCats.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: "  |  ")
        drawText("  \(catLine)", attrs: bodyAttrs, state: state)
    }

    // MARK: - Timeline Section (Bar Chart)

    private static func drawTimelineSection(
        state: DrawingState,
        monthlyVolume: [(month: String, count: Int)]
    ) {
        drawSectionHeader("Email Timeline", state: state)

        if monthlyVolume.isEmpty {
            drawText("No dated emails available for timeline analysis.", attrs: bodyAttrs, state: state)
            return
        }

        drawText("Monthly email volume distribution:", attrs: bodyAttrs, state: state)
        state.currentY -= 8

        // Determine chart dimensions
        let chartX = margin + 60
        let chartWidth = contentWidth - 80
        let maxCount = monthlyVolume.map(\.count).max() ?? 1
        let barHeight: CGFloat = 14
        let barSpacing: CGFloat = 3
        let totalChartHeight = CGFloat(monthlyVolume.count) * (barHeight + barSpacing) + 30

        ensureSpace(state: state, needed: totalChartHeight)

        // Draw axis
        let axisX = chartX - 2
        let axisTopY = state.currentY
        let axisBottomY = state.currentY - CGFloat(monthlyVolume.count) * (barHeight + barSpacing)

        state.context.setStrokeColor(labelColor.cgColor)
        state.context.setLineWidth(0.5)
        state.context.move(to: CGPoint(x: axisX, y: axisTopY))
        state.context.addLine(to: CGPoint(x: axisX, y: axisBottomY))
        state.context.strokePath()

        // Draw bars
        for (index, entry) in monthlyVolume.enumerated() {
            let barY = state.currentY - CGFloat(index) * (barHeight + barSpacing) - barHeight

            // Month label
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: captionFont,
                .foregroundColor: labelColor
            ]
            let labelRect = CGRect(x: margin, y: barY, width: 56, height: barHeight)
            (entry.month as NSString).draw(in: labelRect, withAttributes: labelAttrs)

            // Bar
            let normalizedWidth = maxCount > 0
                ? CGFloat(entry.count) / CGFloat(maxCount) * chartWidth
                : 0
            let barRect = CGRect(x: chartX, y: barY + 1, width: max(normalizedWidth, 2), height: barHeight - 2)

            // Color based on relative volume
            let ratio = Double(entry.count) / Double(max(maxCount, 1))
            let barColor: PlatformColor
            if ratio > 0.75 { barColor = accentBlue }
            else if ratio > 0.4 { barColor = chartGreen }
            else { barColor = chartOrange }

            drawFilledRect(state: state, rect: barRect, color: barColor)

            // Count label
            let countText = "\(entry.count)"
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: captionFont,
                .foregroundColor: secondaryColor
            ]
            let countX = chartX + normalizedWidth + 4
            (countText as NSString).draw(
                at: CGPoint(x: countX, y: barY + 1),
                withAttributes: countAttrs
            )
        }

        state.currentY -= CGFloat(monthlyVolume.count) * (barHeight + barSpacing) + 16

        // Scale annotation
        drawText("Scale: longest bar = \(maxCount) emails", attrs: captionAttrs, state: state)
    }

    // MARK: - Top Contacts Table

    private static func drawTopContactsTable(
        state: DrawingState,
        contacts: [(name: String, count: Int, domains: [String])]
    ) {
        drawSectionHeader("Top Contacts", state: state)

        if contacts.isEmpty {
            drawText("No contact data available.", attrs: bodyAttrs, state: state)
            return
        }

        // Table header
        let col1X = margin
        let col2X = margin + 240
        let col3X = margin + 320
        let col1W: CGFloat = 235
        let col2W: CGFloat = 75
        let col3W: CGFloat = contentWidth - 320

        let headerRow = [
            (text: "Contact", x: col1X, w: col1W),
            (text: "Count", x: col2X, w: col2W),
            (text: "Domains", x: col3X, w: col3W),
        ]

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyBoldFont,
            .foregroundColor: labelColor
        ]

        ensureSpace(state: state, needed: 20)
        for col in headerRow {
            let rect = CGRect(x: col.x, y: state.currentY - 14, width: col.w, height: 14)
            (col.text as NSString).draw(in: rect, withAttributes: headerAttrs)
        }
        state.currentY -= 18
        drawSeparator(state: state)

        // Table rows
        for contact in contacts {
            ensureSpace(state: state, needed: 18)

            let name = String(contact.name.prefix(40))
            let countStr = "\(contact.count)"
            let domainStr = String(contact.domains.joined(separator: ", ").prefix(40))

            let rowY = state.currentY - 12

            (name as NSString).draw(
                in: CGRect(x: col1X, y: rowY, width: col1W, height: 12),
                withAttributes: monoAttrs
            )
            (countStr as NSString).draw(
                in: CGRect(x: col2X, y: rowY, width: col2W, height: 12),
                withAttributes: monoAttrs
            )
            (domainStr as NSString).draw(
                in: CGRect(x: col3X, y: rowY, width: col3W, height: 12),
                withAttributes: monoAttrs
            )

            state.currentY -= 16
        }
    }

    // MARK: - Category Breakdown

    private static func drawCategoryBreakdown(
        state: DrawingState,
        classification: [EmailNLPEngine.EmailCategory: Int],
        totalEmails: Int
    ) {
        drawSectionHeader("Category Breakdown", state: state)

        if classification.isEmpty || totalEmails == 0 {
            drawText("No classification data available.", attrs: bodyAttrs, state: state)
            return
        }

        let sorted = classification.sorted { $0.value > $1.value }

        // Text summary
        for entry in sorted {
            let pct = totalEmails > 0 ? Double(entry.value) / Double(totalEmails) * 100.0 : 0
            drawText(
                "\(entry.key.rawValue): \(entry.value) emails (\(String(format: "%.1f", pct))%)",
                attrs: bodyAttrs,
                state: state
            )
        }

        state.currentY -= 12

        // Simple horizontal bar chart
        drawText("Distribution:", attrs: bodyBoldAttrs, state: state)
        state.currentY -= 4

        let barMaxWidth: CGFloat = contentWidth - 140
        let barHeight: CGFloat = 16
        let maxVal = sorted.first?.value ?? 1

        let categoryColors: [EmailNLPEngine.EmailCategory: PlatformColor] = [
            .personal: accentBlue,
            .transactional: chartGreen,
            .newsletter: chartOrange,
            .promotional: chartRed,
            .automated: secondaryColor,
            .unknown: separatorColor,
        ]

        for entry in sorted {
            ensureSpace(state: state, needed: barHeight + 6)

            let labelText = entry.key.rawValue
            let labelWidth: CGFloat = 100
            let labelRect = CGRect(x: margin, y: state.currentY - barHeight + 2, width: labelWidth, height: barHeight)
            (labelText as NSString).draw(in: labelRect, withAttributes: captionAttrs)

            let barX = margin + labelWidth + 8
            let normalizedWidth = maxVal > 0
                ? CGFloat(entry.value) / CGFloat(maxVal) * barMaxWidth
                : 0
            let barRect = CGRect(x: barX, y: state.currentY - barHeight + 3, width: max(normalizedWidth, 2), height: barHeight - 4)
            let color = categoryColors[entry.key] ?? separatorColor
            drawFilledRect(state: state, rect: barRect, color: color)

            let countText = "\(entry.value)"
            let countX = barX + normalizedWidth + 4
            (countText as NSString).draw(
                at: CGPoint(x: countX, y: state.currentY - barHeight + 3),
                withAttributes: captionAttrs
            )

            state.currentY -= (barHeight + 4)
        }
    }

    // MARK: - Evidence Tags Summary

    private static func drawEvidenceTagsSummary(
        state: DrawingState,
        tags: [(tag: String, count: Int, emailIDs: [UUID])]
    ) {
        drawSectionHeader("Evidence Tags Summary", state: state)

        if tags.isEmpty {
            drawText("No evidence tags have been assigned.", attrs: bodyAttrs, state: state)
            drawText(
                "Evidence tags can be assigned through the forensic review interface to classify emails as Relevant, Privileged, Irrelevant, Flagged, or Suspicious.",
                attrs: captionAttrs,
                state: state
            )
            return
        }

        drawText(
            "Summary of evidence tags assigned via ForensicManager:",
            attrs: bodyAttrs,
            state: state
        )
        state.currentY -= 4

        for entry in tags {
            ensureSpace(state: state, needed: 18)
            drawText(
                "\(entry.tag): \(entry.count) email\(entry.count == 1 ? "" : "s")",
                attrs: bodyAttrs,
                state: state
            )
        }

        let totalTagged = tags.reduce(0) { $0 + $1.count }
        state.currentY -= 8
        drawText("Total tagged emails: \(totalTagged)", attrs: bodyBoldAttrs, state: state)
    }

    // MARK: - Flagged / Important Emails

    private static func drawFlaggedEmails(
        state: DrawingState,
        flaggedEmails: [FlaggedEmail]
    ) {
        drawSectionHeader("Flagged & Important Emails", state: state)

        if flaggedEmails.isEmpty {
            drawText("No flagged or high-priority emails identified.", attrs: bodyAttrs, state: state)
            return
        }

        drawText(
            "The following \(flaggedEmails.count) email(s) were identified as flagged, suspicious, or otherwise notable (sorted by priority):",
            attrs: bodyAttrs,
            state: state
        )
        state.currentY -= 8

        for (index, flagged) in flaggedEmails.enumerated() {
            ensureSpace(state: state, needed: 70)

            // Index and priority indicator
            let priorityLabel: String
            switch flagged.priority {
            case .high: priorityLabel = "[HIGH]"
            case .medium: priorityLabel = "[MED]"
            case .low: priorityLabel = "[LOW]"
            }

            drawText(
                "\(index + 1). \(priorityLabel) \(flagged.reason)",
                attrs: h2Attrs,
                state: state
            )

            let from = String((flagged.email.headers["From"] ?? "Unknown").prefix(60))
            let subject = String((flagged.email.headers["Subject"] ?? "(No Subject)").prefix(70))
            let date = String((flagged.email.headers["Date"] ?? "N/A").prefix(30))

            drawText("  From: \(from)", attrs: monoAttrs, state: state)
            drawText("  Subject: \(subject)", attrs: monoAttrs, state: state)
            drawText("  Date: \(date)", attrs: monoAttrs, state: state)

            if !flagged.email.anomalies.isEmpty {
                drawText(
                    "  Anomalies: \(flagged.email.anomalies.joined(separator: ", "))",
                    attrs: captionAttrs,
                    state: state
                )
            }

            state.currentY -= 6
        }
    }

    // MARK: - Data Computation Helpers

    private struct FlaggedEmail {
        let email: MBOXParser.RawEmail
        let priority: Priority
        let reason: String

        enum Priority: Int, Comparable {
            case high = 0
            case medium = 1
            case low = 2

            static func < (lhs: Priority, rhs: Priority) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }
    }

    private static func computeTopSenders(
        emails: [MBOXParser.RawEmail],
        limit: Int
    ) -> [(address: String, count: Int)] {
        var senderCounts: [String: Int] = [:]
        for email in emails {
            let from = (email.headers["From"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { continue }
            senderCounts[from, default: 0] += 1
        }
        return senderCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (address: $0.key, count: $0.value) }
    }

    private static func computeMonthlyVolume(
        emails: [MBOXParser.RawEmail]
    ) -> [(month: String, count: Int)] {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"

        var grouped: [String: Int] = [:]
        for email in emails {
            if let date = MBOXParser.parseDate(email.headers["Date"]) {
                let key = monthFormatter.string(from: date)
                grouped[key, default: 0] += 1
            }
        }

        return grouped
            .sorted { $0.key < $1.key }
            .map { (month: $0.key, count: $0.value) }
    }

    private static func computeContactDomains(
        emails: [MBOXParser.RawEmail],
        limit: Int
    ) -> [(name: String, count: Int, domains: [String])] {
        var contactInfo: [String: (count: Int, domains: Set<String>)] = [:]

        for email in emails {
            // Collect From, To, Cc addresses
            let addressFields = ["From", "To", "Cc"]
            for field in addressFields {
                guard let value = email.headers[field] else { continue }
                let addresses = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                for addr in addresses where !addr.isEmpty {
                    let normalized = addr.lowercased()
                    let entry = contactInfo[normalized] ?? (count: 0, domains: Set<String>())
                    var domains = entry.domains
                    // Extract domain
                    if let atIndex = addr.lastIndex(of: "@") {
                        let domainPart = addr[addr.index(after: atIndex)...]
                            .trimmingCharacters(in: CharacterSet(charactersIn: "> \t\r\n"))
                            .lowercased()
                        if domainPart.contains(".") {
                            domains.insert(domainPart)
                        }
                    }
                    contactInfo[normalized] = (count: entry.count + 1, domains: domains)
                }
            }
        }

        return contactInfo
            .sorted { $0.value.count > $1.value.count }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value.count, domains: Array($0.value.domains)) }
    }

    @MainActor
    private static func collectEvidenceTagsFromManager(
        emails: [MBOXParser.RawEmail]
    ) -> [(tag: String, count: Int, emailIDs: [UUID])] {
        let manager = ForensicManager.shared
        var tagGroups: [String: [UUID]] = [:]

        for email in emails {
            let tag = manager.tagForEmail(email.id)
            if tag != .none {
                tagGroups[tag.rawValue, default: []].append(email.id)
            }
        }

        return tagGroups
            .sorted { $0.value.count > $1.value.count }
            .map { (tag: $0.key, count: $0.value.count, emailIDs: $0.value) }
    }

    private static func collectEvidenceTags(
        emails: [MBOXParser.RawEmail]
    ) -> [(tag: String, count: Int, emailIDs: [UUID])] {
        // Since ForensicManager is @MainActor, we collect tags by checking
        // email-level data that is accessible without the actor.
        // We look at email.tags and anomalies as a proxy when off-main-thread.
        var tagGroups: [String: [UUID]] = [:]

        for email in emails {
            // Use the email's own tags array as evidence markers
            for tag in email.tags where !tag.isEmpty {
                tagGroups[tag, default: []].append(email.id)
            }
            // Flag anomalies as evidence
            if !email.anomalies.isEmpty {
                tagGroups["Anomaly Detected", default: []].append(email.id)
            }
        }

        // If no tags found at all, try to see if there is anything from
        // the forensic data accessible through the email data itself
        if tagGroups.isEmpty {
            return []
        }

        return tagGroups
            .sorted { $0.value.count > $1.value.count }
            .map { (tag: $0.key, count: $0.value.count, emailIDs: $0.value) }
    }

    private static func collectFlaggedEmails(
        emails: [MBOXParser.RawEmail],
        limit: Int
    ) -> [FlaggedEmail] {
        var flagged: [FlaggedEmail] = []

        for email in emails {
            // High priority: anomalies detected
            if !email.anomalies.isEmpty {
                flagged.append(FlaggedEmail(
                    email: email,
                    priority: .high,
                    reason: "Anomalies: \(email.anomalies.joined(separator: ", "))"
                ))
                continue
            }

            // Medium priority: suspicious tags or certain message characteristics
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let body = email.plainBody.lowercased()

            let urgencyPhrases = [
                "urgent", "immediately", "verify your account",
                "suspended", "act now", "click here", "confirm your identity"
            ]
            let matchedPhrases = urgencyPhrases.filter { subject.contains($0) || body.contains($0) }
            if !matchedPhrases.isEmpty {
                flagged.append(FlaggedEmail(
                    email: email,
                    priority: .medium,
                    reason: "Suspicious language: \(matchedPhrases.joined(separator: ", "))"
                ))
                continue
            }

            // Low priority: emails with many attachments or from unusual domains
            if email.attachments.count > 5 {
                flagged.append(FlaggedEmail(
                    email: email,
                    priority: .low,
                    reason: "High attachment count (\(email.attachments.count))"
                ))
            }
        }

        return flagged
            .sorted { $0.priority < $1.priority }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Minimal PDF Fallback

    private static func createMinimalPDF() -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            // Absolute fallback: return a hand-crafted minimal valid PDF
            let minimalPDF = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n178\n%%EOF"
            return minimalPDF.data(using: .ascii) ?? Data()
        }

        ctx.beginPage(mediaBox: &mediaBox)
        ctx.endPage()
        ctx.closePDF()

        return pdfData as Data
    }
}
