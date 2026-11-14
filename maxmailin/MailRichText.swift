import MailConnectivity
//
//  MailRichText.swift
//  maxmailin
//
//  The composer's formatted text (owner 2026-11-15: "combine Thunderbird and
//  Apple Mail"): bold, italic, underline, strikethrough, size, colour and
//  links, typed in the system's rich text editor (macOS 26 / iOS 26) and sent
//  as the HTML part next to the plain text. A draft keeps its HTML, so
//  reopening it brings the formatting back. Lists are text ("• ", "1. ") so
//  they read the same in the plain part.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
private typealias RichFont = NSFont
private typealias RichColor = NSColor
#else
import UIKit
private typealias RichFont = UIFont
private typealias RichColor = UIColor
#endif

enum MailRichText {
    /// The formatting a run carries, as the HTML writer reads it.
    struct Style: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        /// nil = the body size.
        var pointSize: Double?
        /// "#rrggbb"; nil = the reader's text colour.
        var color: String?
        var link: URL?

        var isPlain: Bool { self == Style() }
    }

    /// HTML for the message, or nil when nothing is formatted (then only the
    /// plain part is sent, as before).
    static func html(_ runs: [(text: String, style: Style)]) -> String? {
        guard runs.contains(where: { !$0.style.isPlain }) else { return nil }
        var out = ""
        for (text, style) in runs {
            var piece = escape(text).replacingOccurrences(of: "\n", with: "<br>")
            if style.bold { piece = "<b>\(piece)</b>" }
            if style.italic { piece = "<i>\(piece)</i>" }
            if style.underline { piece = "<u>\(piece)</u>" }
            if style.strikethrough { piece = "<s>\(piece)</s>" }
            var css: [String] = []
            if let size = style.pointSize { css.append("font-size:\(Int(size.rounded()))px") }
            if let color = style.color { css.append("color:\(color)") }
            if !css.isEmpty { piece = "<span style=\"\(css.joined(separator: ";"))\">\(piece)</span>" }
            if let link = style.link { piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>" }
            out += piece
        }
        return "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif\">\(out)</div>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func hex(red: Double, green: Double, blue: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(red), c(green), c(blue))
    }

    /// The character offsets where the lines touched by `lower..<upper` begin.
    static func lineStarts(in plain: String, lower: Int, upper: Int) -> [Int] {
        let chars = Array(plain)
        var start = min(lower, chars.count)
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var starts = [start]
        var i = start
        while i < min(upper, chars.count) {
            // A newline inside the selection: the next line is touched too.
            if chars[i] == "\n", i + 1 < upper { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    /// The list marker a line starts with ("• " or "12. "), if any.
    static func listMarker(of line: Substring, numbered: Bool) -> String? {
        if numbered {
            guard let r = line.range(of: #"^\d+\. "#, options: .regularExpression) else { return nil }
            return String(line[r])
        }
        return line.hasPrefix("• ") ? "• " : nil
    }

    /// The lines' markers to remove (all lines have one) or to add, as
    /// (offset, marker, insert) edits from the last line to the first.
    static func listEdits(_ plain: String, lower: Int, upper: Int, numbered: Bool) -> [(offset: Int, marker: String, insert: Bool)] {
        let starts = lineStarts(in: plain, lower: lower, upper: upper)
        let chars = Array(plain)
        func line(_ start: Int) -> Substring {
            let end = chars[start...].firstIndex(of: "\n") ?? chars.count
            return Substring(String(chars[start..<end]))
        }
        let markers = starts.map { listMarker(of: line($0), numbered: numbered) }
        let remove = markers.allSatisfy { $0 != nil }
        return zip(starts, markers).enumerated().reversed().map { i, pair in
            remove ? (pair.0, pair.1 ?? "", false) : (pair.0, numbered ? "\(i + 1). " : "• ", true)
        }
    }

    // MARK: Reopening a draft

    /// The draft's HTML back as styled runs (bold, italic, underline,
    /// strikethrough, size, colour, links). Plain text when it cannot be read.
    @MainActor
    static func runs(fromHTML html: String, bodySize: Double) -> [(text: String, style: Style)]? {
        guard let data = html.data(using: .utf8),
              let ns = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                      .characterEncoding: String.Encoding.utf8.rawValue],
                                               documentAttributes: nil) else { return nil }
        var out: [(String, Style)] = []
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            var style = Style()
            if let font = attrs[.font] as? RichFont {
                #if canImport(AppKit)
                let traits = font.fontDescriptor.symbolicTraits
                style.bold = traits.contains(.bold); style.italic = traits.contains(.italic)
                #else
                let traits = font.fontDescriptor.symbolicTraits
                style.bold = traits.contains(.traitBold); style.italic = traits.contains(.traitItalic)
                #endif
                // HTML's default (12 px ≈ the body size) is not a chosen size.
                if abs(Double(font.pointSize) - 12) > 0.5, abs(Double(font.pointSize) - bodySize) > 0.5 { style.pointSize = Double(font.pointSize) }
            }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { style.underline = true }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { style.strikethrough = true }
            if let color = attrs[.foregroundColor] as? RichColor {
                #if canImport(AppKit)
                let rgb = color.usingColorSpace(.sRGB)
                let (r, g, b) = (Double(rgb?.redComponent ?? 0), Double(rgb?.greenComponent ?? 0), Double(rgb?.blueComponent ?? 0))
                #else
                var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
                color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
                let (r, g, b) = (Double(cr), Double(cg), Double(cb))
                #endif
                // HTML's default black is the reader's text colour, not a chosen one.
                if max(r, g, b) > 0.05 { style.color = hex(red: r, green: g, blue: b) }
            }
            if let link = attrs[.link] as? URL { style.link = link } else if let s = attrs[.link] as? String { style.link = URL(string: s) }
            var text = (ns.string as NSString).substring(with: range)
            text = text.replacingOccurrences(of: "\u{2028}", with: "\n")
            out.append((text, style))
        }
        // NSAttributedString adds a trailing newline after the last block.
        if var last = out.popLast() {
            if last.0.hasSuffix("\n") { last.0.removeLast() }
            if !last.0.isEmpty { out.append(last) }
        }
        return out
    }
}

// MARK: - The editor (macOS 26 / iOS 26)

@available(macOS 26.0, iOS 26.0, *)
struct MailRichBodyEditor: View {
    /// The draft's plain text and HTML; set on every edit.
    let initialPlain: String
    let initialHTML: String?
    let onChange: (_ plain: String, _ html: String?) -> Void

    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var loaded = false
    @State private var linking = false
    @State private var linkText = ""
    @Environment(\.fontResolutionContext) private var fontContext

    private var bodySize: Double { Double(Font.body.resolve(in: fontContext).pointSize) }

    var body: some View {
        VStack(spacing: 0) {
            formatBar
            Divider()
            TextEditor(text: $text, selection: $selection)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("Message text"))
        }
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in
            guard loaded else { return }
            onChange(String(text.characters), MailRichText.html(runs()))
        }
        .alert(String(localized: "Add Link"), isPresented: $linking) {
            TextField("https://", text: $linkText)
            Button(String(localized: "Add")) {
                let url = URL(string: linkText.contains("://") ? linkText : "https://" + linkText)
                text.transformAttributes(in: &selection) { $0.link = url }
                linkText = ""
            }
            Button(String(localized: "Cancel"), role: .cancel) { linkText = "" }
        }
    }

    private func load() {
        guard !loaded else { return }
        if let html = initialHTML, let runs = MailRichText.runs(fromHTML: html, bodySize: bodySize) {
            var built = AttributedString()
            for (piece, style) in runs { built += attributed(piece, style) }
            text = built
        } else {
            text = AttributedString(initialPlain)
        }
        loaded = true
    }

    private func attributed(_ piece: String, _ style: MailRichText.Style) -> AttributedString {
        var a = AttributedString(piece)
        var font = Font.body
        if let size = style.pointSize { font = font.pointSize(size) }
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        if font != .body { a.font = font }
        if style.underline { a.underlineStyle = .single }
        if style.strikethrough { a.strikethroughStyle = .single }
        if let hex = style.color, let color = Self.color(hex) { a.foregroundColor = color }
        if let link = style.link { a.link = link }
        return a
    }

    private static func color(_ hex: String) -> Color? {
        guard hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    /// The text as styled runs, for the HTML part.
    private func runs() -> [(text: String, style: MailRichText.Style)] {
        text.runs.map { run in
            var style = MailRichText.Style()
            if let font = run.font {
                let resolved = font.resolve(in: fontContext)
                style.bold = resolved.isBold
                style.italic = resolved.isItalic
                let size = Double(resolved.pointSize)
                if abs(size - bodySize) > 0.5 { style.pointSize = size }
            }
            style.underline = run.underlineStyle != nil
            style.strikethrough = run.strikethroughStyle != nil
            if let color = run.foregroundColor {
                let c = color.resolve(in: EnvironmentValues())
                style.color = MailRichText.hex(red: Double(c.red), green: Double(c.green), blue: Double(c.blue))
            }
            style.link = run.link
            return (String(text[run.range].characters), style)
        }
    }

    // MARK: Format bar (Thunderbird)

    private var typing: Font { selection.typingAttributes(in: text).font ?? .body }
    private var isBold: Bool { typing.resolve(in: fontContext).isBold }
    private var isItalic: Bool { typing.resolve(in: fontContext).isItalic }
    private var isUnderlined: Bool { selection.typingAttributes(in: text).underlineStyle != nil }
    private var isStruck: Bool { selection.typingAttributes(in: text).strikethroughStyle != nil }

    private var formatBar: some View {
        HStack(spacing: 2) {
            toggle("bold", String(localized: "Bold"), isBold) { on in text.transformAttributes(in: &selection) { $0.font = ($0.font ?? .body).bold(on) } }
                .keyboardShortcut("b", modifiers: .command)
            toggle("italic", String(localized: "Italic"), isItalic) { on in text.transformAttributes(in: &selection) { $0.font = ($0.font ?? .body).italic(on) } }
                .keyboardShortcut("i", modifiers: .command)
            toggle("underline", String(localized: "Underline"), isUnderlined) { on in text.transformAttributes(in: &selection) { $0.underlineStyle = on ? .single : nil } }
                .keyboardShortcut("u", modifiers: .command)
            toggle("strikethrough", String(localized: "Strikethrough"), isStruck) { on in text.transformAttributes(in: &selection) { $0.strikethroughStyle = on ? .single : nil } }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("textformat.size.smaller", String(localized: "Smaller")) {
                text.transformAttributes(in: &selection) { $0.font = ($0.font ?? .body).scaled(by: 1 / 1.15) }
            }
            button("textformat.size.larger", String(localized: "Bigger")) {
                text.transformAttributes(in: &selection) { $0.font = ($0.font ?? .body).scaled(by: 1.15) }
            }
            Menu {
                Button(String(localized: "Automatic")) { text.transformAttributes(in: &selection) { $0.foregroundColor = nil } }
                ForEach(MailTagPalette.colors.indices, id: \.self) { i in
                    Button(MailTagPalette.colors[i].name) {
                        let color = MailTagPalette.colors[i].color
                        text.transformAttributes(in: &selection) { $0.foregroundColor = color }
                    }
                }
            } label: { Image(systemName: "paintpalette") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(String(localized: "Text Colour"))
            .accessibilityLabel(Text("Text Colour"))
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("list.bullet", String(localized: "Bulleted List")) { list(numbered: false) }
            button("list.number", String(localized: "Numbered List")) { list(numbered: true) }
            button("link", String(localized: "Add Link…")) { linking = true }
                .keyboardShortcut("k", modifiers: .command)
            button("textformat", String(localized: "Clear Formatting")) {
                text.transformAttributes(in: &selection) {
                    $0.font = nil; $0.underlineStyle = nil; $0.strikethroughStyle = nil; $0.foregroundColor = nil; $0.link = nil
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func toggle(_ symbol: String, _ title: String, _ on: Bool, _ apply: @escaping (Bool) -> Void) -> some View {
        Button { apply(!on) } label: {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.2) : .clear))
        }
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func button(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .help(title)
            .accessibilityLabel(Text(title))
    }

    /// Lists are text, so the plain part reads the same; formatting elsewhere is kept.
    private func list(numbered: Bool) {
        let chars = text.characters
        func offset(_ i: AttributedString.Index) -> Int { chars.distance(from: chars.startIndex, to: i) }
        var lower = chars.count, upper = chars.count
        switch selection.indices(in: text) {
        case .insertionPoint(let i): lower = offset(i); upper = lower
        case .ranges(let set):
            if let first = set.ranges.first, let last = set.ranges.last { lower = offset(first.lowerBound); upper = offset(last.upperBound) }
        @unknown default: break
        }
        for edit in MailRichText.listEdits(String(chars), lower: lower, upper: upper, numbered: numbered) {
            let at = text.characters.index(text.startIndex, offsetBy: edit.offset)
            if edit.insert {
                text.insert(AttributedString(edit.marker), at: at)
            } else {
                let end = text.characters.index(at, offsetBy: edit.marker.count)
                text.removeSubrange(at..<end)
            }
        }
        selection = AttributedTextSelection()
    }
}
