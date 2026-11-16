//
//  PaginatedTextRenderer.swift
//  maxmailin
//
//  B11 (review 2026-11-16): the iPhone/iPad per-message PDF drew the whole
//  message into ONE 692-pt rectangle (everything past the first page was
//  clipped), and the iPhone/iPad "TIFF" wrote PNG bytes under a .tiff name.
//  This renderer lays text out with Core Text a page at a time — as many
//  pages as the text needs, no cap — and encodes real multi-page TIFF with
//  ImageIO. Platform-neutral (Core Graphics / Core Text / ImageIO only), so
//  the same code is tested on the Mac.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PaginatedTextRenderer {
    struct Layout: Sendable {
        var pageSize = CGSize(width: 612, height: 792)   // US Letter, points
        var margin: CGFloat = 50
        var fontSize: CGFloat = 10
        var monospaced = false

        var textRect: CGRect {
            CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        }
    }

    /// Black text in the system (or fixed-pitch) font.
    static func attributed(_ text: String, layout: Layout) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(layout.monospaced ? .userFixedPitch : .system, layout.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, layout.fontSize, nil)
        let black = CGColor(gray: 0, alpha: 1)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
        ])
    }

    /// Calls `drawPage` once per page with the Core Text frame for that page,
    /// until every character is placed. Returns the page count. A page that
    /// cannot place a single character (nothing fits the text rectangle) ends
    /// the run instead of looping.
    @discardableResult
    static func forEachPage(_ text: NSAttributedString, layout: Layout, drawPage: (CTFrame) -> Void) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: layout.textRect, transform: nil)
        var location = 0
        var pages = 0
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            drawPage(frame)
            pages += 1
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            location += visible.length
        } while location < text.length
        return pages
    }

    /// The pages `text` needs at `layout` (at least one).
    static func pageCount(_ text: String, layout: Layout = Layout()) -> Int {
        forEachPage(attributed(text, layout: layout), layout: layout) { _ in }
    }

    /// A PDF with as many pages as the text needs.
    static func pdf(_ text: String, layout: Layout = Layout()) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        forEachPage(attributed(text, layout: layout), layout: layout) { frame in
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)   // PDF space is bottom-left origin, as Core Text expects
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A multi-page TIFF (one image per page, LZW) at `scale` pixels per point.
    /// nil only if ImageIO cannot write TIFF.
    static func tiff(_ text: String, layout: Layout = Layout(margin: 36, monospaced: true), scale: CGFloat = 2) -> Data? {
        let width = Int((layout.pageSize.width * scale).rounded())
        let height = Int((layout.pageSize.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var images: [CGImage] = []
        forEachPage(attributed(text, layout: layout), layout: layout) { frame in
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: layout.pageSize))
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            if let image = context.makeImage() { images.append(image) }
        }
        return encodeTIFF(images)
    }

    /// Real TIFF bytes (`II*\0` / `MM\0*`), one page per image.
    static func encodeTIFF(_ images: [CGImage]) -> Data? {
        guard !images.isEmpty else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.tiff.identifier as CFString,
                                                                 images.count, nil) else { return nil }
        let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary   // LZW
        for image in images { CGImageDestinationAddImage(destination, image, properties) }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
