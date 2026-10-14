//
//  AttachmentOCR.swift
//  maxmailin
//
//  E1 (FINAL_TODO_3_0_MAJOR.md Phase E): the text in scanned PDFs and photos attached to emails,
//  read on this device by Apple Vision (VNRecognizeTextRequest — no network), so `in:attachments`
//  finds it. Used by AttachmentTextIndexJob while capability `.attachmentOCR` is on.
//
//  Bounded: an image is decoded downsampled (longest side ≤ maxPixels); a PDF is read one page
//  at a time, each page rendered at most maxPixels on its longest side and released before the
//  next. A PDF whose own text layer is real text is not OCR'd.
//

import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AttachmentOCR {
    /// Capability `.attachmentOCR`, pushed by CapabilityWiring.
    nonisolated(unsafe) static var isEnabled = false

    /// Longest side, in pixels, an image or PDF page is read at: enough for body text in an A4
    /// scan at about 250 dpi, and a fixed memory bound per page.
    static let maxPixels: CGFloat = 3_000

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp"]

    static func isImage(mimeType: String, filename: String) -> Bool {
        mimeType.lowercased().hasPrefix("image/") || imageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// A PDF needs OCR when its text layer holds fewer than 20 non-space characters per page —
    /// a scan, or a scan with a stray stamp or page number.
    static func pdfNeedsOCR(text: String?, pageCount: Int) -> Bool {
        guard pageCount > 0 else { return false }
        let characters = (text ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return characters < 20 * pageCount
    }

    /// The recognised text of one image, lines in reading order; nil when none was found.
    static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Text in an image file's bytes, decoded downsampled.
    static func text(fromImageData data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return recognize(image)
    }

    /// Text of every page of a scanned PDF, page by page, separated by blank lines.
    static func text(fromPDF document: PDFDocument) -> String? {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index), let image = render(page) else { return }
                if let text = recognize(image) { pages.append(text) }
            }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    /// One PDF page as an image, longest side `maxPixels`.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxPixels / max(bounds.width, bounds.height)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        return thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return thumbnail.cgImage
        #endif
    }
}
