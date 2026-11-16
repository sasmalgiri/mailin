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

/// The accurate → fast fallback of one session (see `AttachmentOCR.recognizeRetryingOnce`),
/// thread-safe: OCR runs on the indexing job's background threads.
final class OCRFallbackState: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var consecutiveAccurateFailures = 0
        var skippedSinceProbe = 0
        var fastReads = 0
        var lastAccurateError: String?
        var skippingAccurate: Bool { consecutiveAccurateFailures >= AttachmentOCR.accurateFailuresBeforeSkipping }
    }
    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot { lock.withLock { state } }

    /// False while the accurate recogniser is known to fail, except every probe-interval-th image.
    func shouldTryAccurate() -> Bool {
        lock.withLock {
            guard state.skippingAccurate else { return true }
            state.skippedSinceProbe += 1
            if state.skippedSinceProbe >= AttachmentOCR.accurateProbeInterval {
                state.skippedSinceProbe = 0
                return true
            }
            return false
        }
    }

    func accurateSucceeded() {
        lock.withLock { state.consecutiveAccurateFailures = 0; state.skippedSinceProbe = 0 }
    }

    /// The image went to the fast level: `accurateError` is set when accurate was tried (twice) and failed.
    func readFast(accurateError: Error?, succeeded: Bool) {
        lock.withLock {
            if let accurateError {
                state.consecutiveAccurateFailures += 1
                state.lastAccurateError = accurateError.localizedDescription
            }
            if succeeded { state.fastReads += 1 }
        }
    }

    func reset() { lock.withLock { state = Snapshot() } }
}

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
        /// Pages (or the one image) read at the fast level because the accurate recogniser failed.
        var fastPages = 0
        var failed: Int { failures.count }
        var isComplete: Bool { failures.isEmpty }
    }

    /// FIND-02: the languages this device's text recogniser can read, as Vision
    /// reports them at run time (e.g. "en-US", "de-DE", "hi-IN"); empty when it cannot say.
    static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    /// A whole-recognition override, replaceable by tests (nil in the app): it is
    /// tried twice like the accurate level, and what it reads counts as accurate.
    nonisolated(unsafe) static var recognizer: (@Sendable (CGImage) -> Result<String?, Error>)?

    /// One recognition and the level that produced it.
    struct Recognition: Sendable {
        var result: Result<String?, Error>
        var level: Level
    }

    /// One recognition, each level tried a second time when Vision returns an error: under
    /// load Vision can fail once on a page it reads the next time (CLOSE-06 Release run,
    /// 2026-11-15), and a failed row is only re-read when the reader changes — so one
    /// transient error would leave the attachment unsearchable.
    ///
    /// 2026-11-16 (macOS 27.0.1, 26A434): the accurate recogniser can fail every image after
    /// the first with an E5 runtime error (code 13, "Must re-compile the E5") while the fast
    /// one keeps reading. So: accurate, accurate again, then fast (twice at most). The
    /// downgrade is recorded (`Outcome.fastPages`, the row's note, Health). After
    /// `accurateFailuresBeforeSkipping` images in a row fail accurate twice, images go
    /// straight to fast, and every `accurateProbeInterval`-th image asks accurate again — a
    /// recovered recogniser is used again, one transient error never downgrades the session.
    static func recognizeRetryingOnce(_ image: CGImage) -> Recognition {
        if let recognizer {
            let first = recognizer(image)
            if case .failure = first { return Recognition(result: recognizer(image), level: .accurate) }
            return Recognition(result: first, level: .accurate)
        }
        var accurateError: Error?
        if fallback.shouldTryAccurate() {
            for _ in 0..<2 {
                let r = levelRecognizer(image, .accurate)
                if case .failure(let error) = r { accurateError = error; continue }
                fallback.accurateSucceeded()
                return Recognition(result: r, level: .accurate)
            }
        }
        let first = levelRecognizer(image, .fast)
        let fast: Result<String?, Error>
        if case .failure = first { fast = levelRecognizer(image, .fast) } else { fast = first }
        fallback.readFast(accurateError: accurateError, succeeded: (try? fast.get()) != nil)
        return Recognition(result: fast, level: .fast)
    }

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

    enum Level: String, Sendable { case accurate, fast }

    /// One Vision recognition at one level: the recognised lines in reading order; nil when
    /// none; the error when it failed. Replaceable by tests (a fake recogniser, no Vision).
    nonisolated(unsafe) static var levelRecognizer: @Sendable (CGImage, Level) -> Result<String?, Error> = { image, level in
        recognize(image, level: level == .accurate ? .accurate : .fast)
    }

    /// Images in a row whose accurate recognition failed twice before images go straight to fast.
    static let accurateFailuresBeforeSkipping = 2
    /// While skipping, every this-many-th image asks the accurate recogniser again.
    static let accurateProbeInterval = 25

    /// The session's accurate → fast fallback (OCR runs on the indexing job's threads).
    static let fallback = OCRFallbackState()

    static func resetFallback() { fallback.reset() }

    /// Health: the downgrade this session, stated; nil when the accurate recogniser was never replaced.
    static func downgradeSummary() -> String? {
        let s = fallback.snapshot
        guard s.fastReads > 0 else { return nil }
        let reason = s.lastAccurateError ?? String(localized: "unknown error")
        return s.skippingAccurate
            ? String(localized: "Text recognition read \(s.fastReads) images at the fast level this session; the accurate level keeps failing (\(reason)) and is tried again every \(accurateProbeInterval) images.")
            : String(localized: "Text recognition read \(s.fastReads) images at the fast level this session after the accurate level failed (\(reason)).")
    }

    private static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> Result<String?, Error> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        if level == .accurate { request.automaticallyDetectsLanguage = true }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return .failure(error) }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return .success(lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }

    /// The recognised text of one image, lines in reading order; nil when none was found OR when
    /// recognition failed — callers that must tell the two apart use `outcome(…)`.
    static func recognize(_ image: CGImage) -> String? {
        (try? recognizeRetryingOnce(image).result.get()) ?? nil
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
        let recognition = recognizeRetryingOnce(image)
        if recognition.level == .fast { outcome.fastPages = 1 }
        switch recognition.result {
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
                let recognition = recognizeRetryingOnce(image)
                if recognition.level == .fast { outcome.fastPages += 1 }
                switch recognition.result {
                case .success(let text):
                    if let text, !text.isEmpty { outcome.recognised += 1; pages.append(text) }
                case .failure(let error):
                    outcome.failures.append(String(localized: "page \(index + 1): recognition failed: \(error.localizedDescription)"))
                }
            }
        }
        // FIND-08: pages are joined with the section boundary (U+001E, ArchiveCore
        // `SectionBoundary`) so a phrase never runs from one page onto the next.
        outcome.text = pages.isEmpty ? nil : pages.joined(separator: "\n\n\u{1E}")
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
