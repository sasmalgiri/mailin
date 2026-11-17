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

    /// What the TIFF writer did with a page (1-based), in order — for tests.
    enum TIFFPageEvent: Equatable, Sendable { case rendered(Int), added(Int) }

    /// A multi-page TIFF (one image per page, LZW) at `scale` pixels per point.
    /// nil only if ImageIO cannot write TIFF.
    ///
    /// Streams: the page count comes from the layout first, the TIFF
    /// destination is created for that count, and each page is rendered,
    /// compressed to its own one-page LZW TIFF and added from that before the
    /// next page is drawn — the page bitmap (~7.7 MB at 2×) is released
    /// inside the page's autorelease pool. Adding the bitmap itself would not
    /// stream: ImageIO holds every added CGImage until Finalize (measured:
    /// 40 pages peak at ~300 MB that way, ~11 MB this way).
    static func tiff(_ text: String, layout: Layout = Layout(margin: 36, monospaced: true), scale: CGFloat = 2,
                     events: ((TIFFPageEvent) -> Void)? = nil) -> Data? {
        let width = Int((layout.pageSize.width * scale).rounded())
        let height = Int((layout.pageSize.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let content = attributed(text, layout: layout)
        let pages = forEachPage(content, layout: layout) { _ in }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.tiff.identifier as CFString,
                                                                 pages, nil) else { return nil }
        let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary   // LZW
        var added = 0
        var failed = false
        forEachPage(content, layout: layout) { frame in
            guard !failed else { return }
            autoreleasepool {
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { failed = true; return }
                context.scaleBy(x: scale, y: scale)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(origin: .zero, size: layout.pageSize))
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                guard let image = context.makeImage() else { failed = true; return }
                events?(.rendered(added + 1))
                guard let page = onePageTIFF(image, properties: properties),
                      let source = CGImageSourceCreateWithData(page as CFData, nil) else { failed = true; return }
                CGImageDestinationAddImageFromSource(destination, source, 0, properties)
                added += 1
                events?(.added(added))
            }
        }
        guard !failed, added == pages, CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// One page as its own LZW TIFF — a text page compresses to a small
    /// fraction of its bitmap, and only this is held until the file is finished.
    private static func onePageTIFF(_ image: CGImage, properties: CFDictionary) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
