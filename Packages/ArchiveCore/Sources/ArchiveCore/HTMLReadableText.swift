//
//  HTMLReadableText.swift
//  ArchiveCore
//
//  EXP-01 (deep dive 2026-11-20): text for a PERSON to read, made from an HTML
//  body — Bates productions, per-message PDF / TIFF exports. The search index
//  keeps its own `FTSSearchIndex.stripHTMLText` (it must match what was
//  indexed); that one leaves <style>/<script> contents and most entities in
//  place, which printed CSS and "&#39;" into evidence documents.
//
//  • <head>, <style>, <script>, <noscript>, <template> and comments are removed
//    with their contents;
//  • block ends (<br>, </p>, </div>, </tr>, </li>, headings) become line breaks;
//  • every other tag is removed;
//  • named entities in common use and every numeric entity are decoded;
//  • runs of spaces collapse, at most one blank line in a row.
//

import Foundation

public enum HTMLReadableText {
    public static func readable(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html
        func replace(_ pattern: String, with template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        replace("<!--.*?-->", with: "")
        for element in ["head", "style", "script", "noscript", "template"] {
            replace("<\(element)\\b[^>]*>.*?</\(element)\\s*>", with: "")
        }
        replace("<br\\s*/?>", with: "\n")
        replace("</(p|div|tr|li|h[1-6]|blockquote|table|section|article)\\s*>", with: "\n")
        replace("<[^>]+>", with: "")
        text = decodeEntities(text)
        replace("[ \\t\\u00A0]+", with: " ")
        replace(" *\\n *", with: "\n")
        replace("\\n{3,}", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
            "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "bull": "•", "middot": "·",
        ]
        var out = ""
        out.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            guard ch == "&", let semicolon = input[index...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                index = input.index(after: index)
                continue
            }
            let body = input[input.index(after: index)..<semicolon]
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X"), let value = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
                decoded = String(Character(scalar))
            } else if body.hasPrefix("#"), let value = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(value) {
                decoded = String(Character(scalar))
            } else {
                decoded = named[String(body).lowercased()]
            }
            if let decoded {
                out += decoded
                index = input.index(after: semicolon)
            } else {
                out.append(ch)
                index = input.index(after: index)
            }
        }
        return out
    }
}
