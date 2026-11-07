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
//  next. A PDF page whose own text layer is real text is taken from that layer; a scanned page
//  is recognised — so a mixed document is read page by page.
//
//  Audit 2026-11-06 A06: recognition returns a structured `Outcome` — pages attempted, pages
//  recognised, pages taken from the text layer, pages that FAILED and why — so a Vision error, a
//  page that would not render or an image that would not decode is never read as "no text" and
//  never lets the attachment be recorded as completely read.
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

    /// What one recognition pass produced, page by page.
    struct Outcome: Sendable, Equatable {
        /// The text, in page order — recognised pages and text-layer pages alike; nil when none.
        var text: String?
        /// Pages (or the one image) the recogniser was asked to read.
        var attempted = 0
        /// Pages the recogniser returned words for.
        var recognised = 0
        /// PDF pages taken from their own text layer (no recognition needed).
        var layerPages = 0
        /// Pages that could not be read, with the reason for each.
        var failures: [String] = []
        var failed: Int { failures.count }
        var isComplete: Bool { failures.isEmpty }
    }

    /// FIND-02: the languages this device's text recogniser can read, as Vision
    /// reports them at run time (e.g. "en-US", "de-DE", "hi-IN"); empty when it cannot say.
    static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    /// The recogniser, replaceable by tests. The production one asks Vision.
    nonisolated(unsafe) static var recognizer: @Sendable (CGImage) -> Result<String?, Error> = visionRecognizer

    static func isImage(mimeType: String, filename: String) -> Bool {
        mimeType.lowercased().hasPrefix("image/") || imageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// A PDF needs OCR when its text layer holds fewer than 20 non-space characters per page —
    /// a scan, or a scan with a stray stamp or page number.
    static func pdfNeedsOCR(text: String?, pageCount: Int) -> Bool {
        guard pageCount > 0 else { return false }
        return nonSpaceCharacters(text) < 20 * pageCount
    }

    /// One page's own text layer is real text when it holds at least 20 non-space characters.
    static func pageHasTextLayer(_ text: String?) -> Bool { nonSpaceCharacters(text) >= 20 }

    /// Audit A06: a document needs OCR when ANY of its pages lacks a real
    /// text layer — a whole-document character count hid a scanned page
    /// bound in with text pages.
    static func pdfNeedsOCR(_ document: PDFDocument) -> Bool {
        guard document.pageCount > 0 else { return false }
        for index in 0..<document.pageCount where !pageHasTextLayer(document.page(at: index)?.string) { return true }
        return false
    }

    private static func nonSpaceCharacters(_ text: String?) -> Int {
        (text ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// Vision: the recognised lines in reading order; nil when none; the error when it failed.
    @Sendable static func visionRecognizer(_ image: CGImage) -> Result<String?, Error> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return .failure(error) }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return .success(lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }

    /// The recognised text of one image, lines in reading order; nil when none was found OR when
    /// recognition failed — callers that must tell the two apart use `outcome(…)`.
    static func recognize(_ image: CGImage) -> String? {
        (try? recognizer(image).get()) ?? nil
    }

    /// Text in an image file's bytes, decoded downsampled; nil when none or on failure.
    static func text(fromImageData data: Data) -> String? { outcome(fromImageData: data).text }

    /// Text of every page of a PDF; nil when none or on failure.
    static func text(fromPDF document: PDFDocument) -> String? { outcome(fromPDF: document).text }

    /// One image: decoded downsampled and recognised. A decode failure and a recognition
    /// failure are each a named failure, distinct from "no text in the picture".
    static func outcome(fromImageData data: Data) -> Outcome {
        var outcome = Outcome(attempted: 1)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            outcome.failures.append(String(localized: "the image could not be decoded"))
            return outcome
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            outcome.failures.append(String(localized: "the image could not be decoded"))
            return outcome
        }
        switch recognizer(image) {
        case .success(let text):
            if let text, !text.isEmpty { outcome.recognised = 1; outcome.text = text }
        case .failure(let error):
            outcome.failures.append(String(localized: "recognition failed: \(error.localizedDescription)"))
        }
        return outcome
    }

    /// Every page of a PDF, page by page: a page with a real text layer contributes that layer;
    /// a scanned page is rendered and recognised. Pages that will not render or whose
    /// recognition fails are named, with their page numbers.
    static func outcome(fromPDF document: PDFDocument) -> Outcome {
        var outcome = Outcome()
        var pages: [String] = []
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else {
                    outcome.failures.append(String(localized: "page \(index + 1) could not be opened"))
                    return
                }
                let layer = page.string
                if pageHasTextLayer(layer), let layer {
                    outcome.layerPages += 1
                    pages.append(layer)
                    return
                }
                outcome.attempted += 1
                guard let image = render(page) else {
                    outcome.failures.append(String(localized: "page \(index + 1) could not be rendered"))
                    return
                }
                switch recognizer(image) {
                case .success(let text):
                    if let text, !text.isEmpty { outcome.recognised += 1; pages.append(text) }
                case .failure(let error):
                    outcome.failures.append(String(localized: "page \(index + 1): recognition failed: \(error.localizedDescription)"))
                }
            }
        }
        outcome.text = pages.isEmpty ? nil : pages.joined(separator: "\n\n")
        return outcome
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
