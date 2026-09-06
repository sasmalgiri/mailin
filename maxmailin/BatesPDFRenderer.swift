import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Bates-stamped PDF renderer (V3 R1.2)
//
// Extracted from EmailDetailView so the stamping is TESTABLE: the gold case
// renders a document and reads the page text back with PDFKit, asserting the
// Bates number is actually drawn on every page header (not just intended).

enum BatesPDFRenderer {

    struct Metadata {
        var batesNumber: String
        var caseNumber: String = ""
        var examiner: String = ""
        var md5Hash: String? = nil
    }

    /// Renders `lines` into a Letter-size PDF at `url`, stamping the Bates
    /// number (+ page x of y) in every page header. Returns the page count.
    @discardableResult
    static func render(lines: [String], metadata: Metadata, to url: URL) -> Int {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 54
        let headerHeight: CGFloat = 60
        let footerHeight: CGFloat = 40
        let contentWidth = pageWidth - margin * 2
        let contentTop = pageHeight - margin - headerHeight
        let contentBottom = margin + footerHeight

        let bodyFont = PlatformFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let headerFont = PlatformFont.systemFont(ofSize: 8, weight: .medium)
        let batesFont = PlatformFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        #if os(macOS)
        let labelColor = PlatformColor.labelColor
        let secondaryLabelColor = PlatformColor.secondaryLabelColor
        let separatorColor = PlatformColor.separatorColor
        #else
        let labelColor = PlatformColor.label
        let secondaryLabelColor = PlatformColor.secondaryLabel
        let separatorColor = PlatformColor.separator
        #endif
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: labelColor]
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: secondaryLabelColor]
        let batesAttrs: [NSAttributedString.Key: Any] = [.font: batesFont, .foregroundColor: labelColor]

        let lineHeight: CGFloat = 14
        let usableHeight = contentTop - contentBottom
        let linesPerPage = Int(usableHeight / lineHeight)

        var pages: [[String]] = []
        var currentPage: [String] = []
        for line in lines {
            for w in wrapLine(line, maxWidth: contentWidth, font: bodyFont) {
                currentPage.append(w)
                if currentPage.count >= linesPerPage {
                    pages.append(currentPage)
                    currentPage = []
                }
            }
        }
        if !currentPage.isEmpty { pages.append(currentPage) }
        if pages.isEmpty { pages.append([]) }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return 0 }

        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)

        for (pageIndex, pageLines) in pages.enumerated() {
            context.beginPage(mediaBox: &mediaBox)

            #if os(macOS)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext
            #else
            UIGraphicsPushContext(context)
            #endif

            // Header: case info left, Bates number right.
            let headerY = pageHeight - margin - 12
            var headerLeft = "mailin Forensic Export"
            if !metadata.caseNumber.isEmpty { headerLeft = "Case: \(metadata.caseNumber)" }
            if !metadata.examiner.isEmpty { headerLeft += "  |  Examiner: \(metadata.examiner)" }
            (headerLeft as NSString).draw(at: CGPoint(x: margin, y: headerY), withAttributes: headerAttrs)

            let batesStr = "\(metadata.batesNumber) — Page \(pageIndex + 1) of \(pages.count)"
            let batesSize = (batesStr as NSString).size(withAttributes: batesAttrs)
            (batesStr as NSString).draw(at: CGPoint(x: pageWidth - margin - batesSize.width, y: headerY), withAttributes: batesAttrs)

            context.setStrokeColor(separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: headerY - 4))
            context.addLine(to: CGPoint(x: pageWidth - margin, y: headerY - 4))
            context.strokePath()

            for (lineIdx, line) in pageLines.enumerated() {
                let y = contentTop - CGFloat(lineIdx) * lineHeight - lineHeight
                (line as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bodyAttrs)
            }

            context.setStrokeColor(separatorColor.cgColor)
            context.move(to: CGPoint(x: margin, y: contentBottom + 8))
            context.addLine(to: CGPoint(x: pageWidth - margin, y: contentBottom + 8))
            context.strokePath()

            let footerY = margin + 10
            (dateStr as NSString).draw(at: CGPoint(x: margin, y: footerY), withAttributes: headerAttrs)
            if let hash = metadata.md5Hash {
                let hashStr = "MD5: \(hash)"
                let hashSize = (hashStr as NSString).size(withAttributes: headerAttrs)
                (hashStr as NSString).draw(at: CGPoint(x: pageWidth - margin - hashSize.width, y: footerY), withAttributes: headerAttrs)
            }

            #if os(macOS)
            NSGraphicsContext.current = nil
            #else
            UIGraphicsPopContext()
            #endif
            context.endPage()
        }

        context.closePDF()
        return pages.count
    }

    static func wrapLine(_ line: String, maxWidth: CGFloat, font: PlatformFont) -> [String] {
        if line.isEmpty { return [""] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (line as NSString).size(withAttributes: attrs)
        if size.width <= maxWidth { return [line] }

        var result: [String] = []
        var current = ""
        for char in line {
            let test = current + String(char)
            let testSize = (test as NSString).size(withAttributes: attrs)
            if testSize.width > maxWidth {
                result.append(current)
                current = String(char)
            } else {
                current = test
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
