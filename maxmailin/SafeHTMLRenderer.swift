@testable import ArchiveCore
//
//  SafeHTMLRenderer.swift
//  maxmailin
//
//  §3-S8 (switch: `v3SafeHTML`). Email HTML is hostile input. The previous
//  renderer used the synchronous in-process `NSAttributedString` HTML importer,
//  which Apple discourages and whose default loader fetches remote resources —
//  on iPhone/iPad (no network sandbox) opening a message could load tracking
//  pixels (telling a sender, possibly a phishing sender under investigation,
//  that it was opened) and could block the main thread on a large message.
//
//  This renderer:
//   1. sanitizes off the main thread: removes scripts, frames, objects, forms,
//      <link>/<base>/<meta refresh>, event handlers, and every remote
//      reference (src/srcset/background/poster/… and CSS url()/@import to
//      http(s) or protocol-relative URLs). Only cid:/data: content remains.
//   2. converts with WebKit's out-of-process `loadFromHTML` (Apple's
//      recommended API: security, stability, isolation), with a timeout.
//   3. reports how many remote items were blocked, for the "remote content
//      blocked" note.
//  If conversion fails, the caller shows the message as plain text — never the
//  old importer — so the safe path cannot leak by falling back.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif

enum SafeHTMLPolicy {
    /// Pushed by CapabilityWiring (`Capability.v3SafeHTML`).
    nonisolated(unsafe) static var isEnabled = false
}

struct SanitizedHTML: Sendable {
    let html: String
    let blockedRemoteItems: Int
}

enum SafeHTMLRenderer {
    enum RenderError: LocalizedError {
        case conversionFailed(String)
        var errorDescription: String? {
            switch self { case .conversionFailed(let why): return "The message could not be displayed safely: \(why)" }
        }
    }

    // MARK: Sanitizer (pure, nonisolated)

    private static let removeWholeElements = ["script", "iframe", "frame", "frameset", "object", "embed",
                                              "applet", "form", "noscript", "template", "svg", "math"]
    private static let removeTags = ["link", "base", "meta", "input", "button", "textarea", "select", "portal"]

    nonisolated static func sanitize(_ html: String) -> SanitizedHTML {
        var s = html
        var blocked = 0

        func replace(_ pattern: String, with template: String, countHits: Bool) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            let range = NSRange(s.startIndex..., in: s)
            if countHits { blocked += re.numberOfMatches(in: s, range: range) }
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
        }

        // Whole elements with their content.
        for tag in removeWholeElements {
            replace("<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "", countHits: false)
            replace("<\(tag)\\b[^>]*/?>", with: "", countHits: false)   // unclosed / self-closing
        }
        // Single tags.
        for tag in removeTags {
            replace("<\(tag)\\b[^>]*>", with: "", countHits: false)
        }
        // Event handlers and javascript: URLs.
        replace("\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", countHits: false)
        replace("(href|src|action|formaction|xlink:href)\\s*=\\s*([\"']?)\\s*(javascript|vbscript|livescript):[^\"'>\\s]*\\2", with: "", countHits: false)

        // Remote resource attributes (auto-loaded by a renderer). Links (href)
        // are kept: they load nothing until the user clicks.
        let remote = "(?:https?:|ftp:)?//"
        // (`[\s/]`: `<img/src=…>` is an attribute too.)
        replace("[\\s/](src|srcset|background|poster|lowsrc|dynsrc|data-src|cite|longdesc|ping|archive|codebase|profile)\\s*=\\s*([\"'])\\s*\(remote)[^\"']*\\2",
                with: "", countHits: true)
        replace("[\\s/](src|background|poster)\\s*=\\s*\(remote)[^\\s>]+", with: "", countHits: true)
        // CSS: url(remote) and @import.
        replace("url\\(\\s*([\"']?)\\s*\(remote)[^)]*\\1\\s*\\)", with: "none", countHits: true)
        replace("@import\\s+[^;]+;", with: "", countHits: true)
        // CSS expressions / behaviours (legacy engines) — inert but removed.
        replace("expression\\s*\\(", with: "(", countHits: false)

        // T02: what the patterns above cannot see — a remote URL that is
        // entity-encoded (`&#104;ttps:`, `url(&quot;https:…&quot;)`), CSS-escaped
        // (`https\3a //`), a later srcset candidate, or `image-set('https:…')`.
        // The synchronous importer (print / PDF / preview) has no CSP backstop,
        // so the decoded value decides: such an attribute is removed, and a
        // <style> block that still names a remote URL is removed whole.
        s = removeDecodedRemoteReferences(s, blocked: &blocked)

        return SanitizedHTML(html: s, blockedRemoteItems: blocked)
    }

    /// Attributes that never load anything by themselves.
    private static let inertAttributes: Set<String> = ["href", "alt", "title", "name", "id", "class", "lang", "dir"]

    nonisolated private static func removeDecodedRemoteReferences(_ html: String, blocked: inout Int) -> String {
        var s = html
        // <style> blocks (raw text: CSS escapes apply, entities do not).
        if let styleRE = try? NSRegularExpression(pattern: "<style\\b[^>]*>(.*?)</style\\s*>",
                                                  options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = s as NSString
            var out = ""
            var cursor = 0
            for m in styleRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if namesRemoteURL(decodeCSSEscapes(ns.substring(with: m.range(at: 1)))) {
                    blocked += 1
                } else {
                    out += ns.substring(with: m.range)
                }
                cursor = m.range.location + m.range.length
            }
            out += ns.substring(from: cursor)
            s = out
        }
        // Attributes of every tag (quote-aware, so `>` inside a value does not end the tag).
        guard let tagRE = try? NSRegularExpression(pattern: "<[a-zA-Z][^\\s/>]*(?:\"[^\"]*\"|'[^']*'|[^'\">])*>"),
              let attrRE = try? NSRegularExpression(pattern: "([\\s/]+)([^\\s/>=\"']+)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>\"']+)")
        else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for tag in tagRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: tag.range.location - cursor))
            cursor = tag.range.location + tag.range.length
            let text = ns.substring(with: tag.range)
            guard text.contains("=") else { out += text; continue }
            let t = text as NSString
            var kept = ""
            var at = 0
            for a in attrRE.matches(in: text, range: NSRange(location: 0, length: t.length)) {
                kept += t.substring(with: NSRange(location: at, length: a.range.location - at))
                at = a.range.location + a.range.length
                let name = t.substring(with: a.range(at: 2)).lowercased()
                var value = t.substring(with: a.range(at: 3))
                if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
                var decoded = decodeEntities(value)
                if name == "style" { decoded = decodeCSSEscapes(decoded) }
                let compact = String(decoded.unicodeScalars.filter { $0.value > 0x20 }.map(Character.init)).lowercased()
                let remote = !inertAttributes.contains(name) && !name.hasPrefix("on")
                    && !(name != "style" && (compact.hasPrefix("data:") || compact.hasPrefix("cid:")))
                    && namesRemoteURL(compact)
                if remote {
                    blocked += 1
                    kept += t.substring(with: a.range(at: 1)).contains("/") ? "/" : " "
                } else {
                    kept += t.substring(with: a.range)
                }
            }
            kept += t.substring(from: at)
            out += kept
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// True when (already decoded) text references a network URL.
    nonisolated private static func namesRemoteURL(_ text: String) -> Bool {
        let compact = String(text.unicodeScalars.filter { $0.value > 0x20 }.map(Character.init)).lowercased()
        return compact.contains("//") || compact.contains("http:") || compact.contains("https:") || compact.contains("ftp:")
    }

    /// `&#104;`, `&#x2F;`, and the named entities a URL can be spelled with.
    nonisolated private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["quot": "\"", "apos": "'", "amp": "&", "lt": "<", "gt": ">", "colon": ":",
                                       "sol": "/", "solidus": "/", "period": ".", "lpar": "(", "rpar": ")",
                                       "tab": "\t", "newline": "\n", "nbsp": " "]
        guard let re = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);?") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let body = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body.lowercased()]
            }
            out += replacement ?? ns.substring(with: m.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// CSS escapes: `\3a ` → `:`, `\/` → `/`.
    nonisolated private static func decodeCSSEscapes(_ text: String) -> String {
        guard text.contains("\\"), let re = try? NSRegularExpression(pattern: "\\\\([0-9a-fA-F]{1,6})\\s?|\\\\(.)") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            if m.range(at: 1).location != NSNotFound {
                let hex = ns.substring(with: m.range(at: 1))
                out += UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            } else {
                out += ns.substring(with: m.range(at: 2))
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: Rendering

    /// Sanitizes off the main actor, then converts out of process.
    @MainActor
    static func render(_ html: String) async throws -> (NSAttributedString, Int) {
        let sanitized = await Task.detached(priority: .userInitiated) { sanitize(html) }.value
        let attributed = try await convert(sanitized.html)
        return (attributed, sanitized.blockedRemoteItems)
    }

    @MainActor
    private static func convert(_ html: String) async throws -> NSAttributedString {
        #if canImport(WebKit)
        // A CSP that forbids every fetch is the backstop behind the sanitizer:
        // even something the regexes missed cannot load.
        let guarded = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:\">" + html
        // `.timeout` is an AppKit option; on iPhone/iPad the same 10 s limit is
        // enforced here, so a pathological message can never hang the view.
        #if os(macOS)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] =
            [.timeout: 10.0, .characterEncoding: String.Encoding.utf8.rawValue]
        #else
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] =
            [.characterEncoding: String.Encoding.utf8.rawValue]
        #endif
        let gate = RenderResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            NSAttributedString.loadFromHTML(string: guarded, options: options) { attributed, _, error in
                guard gate.claim() else { return }
                if let attributed {
                    continuation.resume(returning: attributed)
                } else {
                    continuation.resume(throwing: RenderError.conversionFailed(error?.localizedDescription ?? "no output"))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                if gate.claim() { continuation.resume(throwing: RenderError.conversionFailed("timed out after 10 s")) }
            }
        }
        #else
        throw RenderError.conversionFailed("WebKit is not available")
        #endif
    }

    /// For the remaining synchronous import sites (print, PDF export, inline
    /// preview): with the switch on, their HTML is sanitized first so the
    /// importer has nothing remote to fetch. With it off, unchanged.
    nonisolated static func sanitizedIfEnabled(_ html: String) -> String {
        SafeHTMLPolicy.isEnabled ? sanitize(html).html : html
    }

    /// Plain-text rendering used when safe conversion fails — never the old,
    /// network-capable importer.
    nonisolated static func plainTextFallback(_ html: String) -> NSAttributedString {
        NSAttributedString(string: FTSSearchIndex.stripHTMLText(html))
    }
}

/// Lets exactly one of the conversion and its deadline resume the call.
private final class RenderResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
