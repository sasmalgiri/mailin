//
//  ScriptLibrary.swift
//  maxmailin
//
//  3.1 S8–S11: the bundled script library, the user's own scripts, no-code
//  recipes that generate scripts, the on-device script assistant and
//  `.mailinscript` files.
//
//  The bundled scripts are written for mailin. The ideas of several (hash-list
//  exclusion, IP / type / size / date / domain filters, hash columns, IP
//  extraction) follow Vound's MIT-licensed Intella crawler-script samples;
//  see THIRD_PARTY_NOTICES.md.
//

import Foundation
import Observation
import CryptoKit
import FoundationModels

// MARK: - Store

@MainActor
@Observable
final class ScriptLibraryStore {
    static let shared = ScriptLibraryStore()

    private(set) var userScripts: [MailinScript] = []
    /// Built-ins marked to run at import (their sources never change).
    private(set) var importEnabledBuiltIns: Set<UUID> = []

    var scripts: [MailinScript] {
        BundledScripts.all.map { s in var s = s; s.runsAtImport = importEnabledBuiltIns.contains(s.id); return s } + userScripts
    }

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scripts.json")
    }

    private struct Saved: Codable { var scripts: [MailinScript]; var importBuiltIns: [UUID] }

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            userScripts = saved.scripts
            importEnabledBuiltIns = Set(saved.importBuiltIns)
        }
    }

    /// Set when the library could not be written; shown on the Scripts screen.
    private(set) var saveError: String?

    private func save() {
        let saved = Saved(scripts: userScripts, importBuiltIns: Array(importEnabledBuiltIns))
        do {
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = String(localized: "Your scripts could not be saved: \(error.localizedDescription)")
        }
    }

    func upsert(_ s: MailinScript) {
        var s = s
        s.builtIn = false
        if let i = userScripts.firstIndex(where: { $0.id == s.id }) {
            // A changed source is a new version (so runs stay provable).
            if userScripts[i].source != s.source, userScripts[i].version == s.version {
                s.version = String((Int(s.version) ?? 1) + 1)
            }
            userScripts[i] = s
        } else {
            userScripts.append(s)
        }
        save()
    }

    func delete(_ id: UUID) {
        userScripts.removeAll { $0.id == id }
        save()
    }

    func setRunsAtImport(_ id: UUID, _ on: Bool) {
        if BundledScripts.all.contains(where: { $0.id == id }) {
            if on { importEnabledBuiltIns.insert(id) } else { importEnabledBuiltIns.remove(id) }
        } else if let i = userScripts.firstIndex(where: { $0.id == id }) {
            userScripts[i].runsAtImport = on
        }
        save()
    }
}

// MARK: - Bundled library (S8)

enum BundledScripts {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "6D41494C-494E-5343-5249-%012d", n))! }

    static let all: [MailinScript] = [
        MailinScript(id: id(1), name: "Hash columns", summary: "Adds SHA-1, SHA-256 and SHA-512 of the body as columns.", source: """
            function process(email) {
              mailin.column("sha1", mailin.hash(email.body, "sha1"));
              mailin.column("sha256", mailin.hash(email.body, "sha256"));
              mailin.column("sha512", mailin.hash(email.body, "sha512"));
            }
            """, builtIn: true),
        MailinScript(id: id(2), name: "IP addresses", summary: "Lists every IPv4 address in the Received headers as a column and tags mail with private-range hops.", source: """
            function process(email) {
              var received = "";
              for (var k in email.headers) { if (k.toLowerCase() === "received") received += email.headers[k] + "\\n"; }
              var ips = received.match(/\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b/g) || [];
              var unique = ips.filter(function (v, i) { return ips.indexOf(v) === i; });
              if (unique.length) mailin.column("received_ips", unique.join(" "));
              if (unique.some(function (ip) { return /^(10\\.|192\\.168\\.|172\\.(1[6-9]|2\\d|3[01])\\.)/.test(ip); })) mailin.tag("private-hop");
            }
            """, builtIn: true),
        MailinScript(id: id(3), name: "Domain filter", summary: "Tags mail from the domains listed at the top of the script.", source: """
            var DOMAINS = ["example.com"];
            function process(email) {
              var m = (email.from.match(/@([^>\\s]+)/) || [])[1];
              if (m && DOMAINS.indexOf(m.toLowerCase()) >= 0) mailin.tag("domain:" + m.toLowerCase());
            }
            """, builtIn: true),
        MailinScript(id: id(4), name: "Date filter", summary: "Sets aside (Trash) mail dated outside the window at the top of the script.", source: """
            var FROM = new Date("2000-01-01"), TO = new Date("2100-01-01");
            function process(email) {
              var d = new Date(email.date);
              if (!isNaN(d) && (d < FROM || d > TO)) mailin.exclude("outside date window");
            }
            """, builtIn: true),
        MailinScript(id: id(5), name: "Size and type filter", summary: "Tags mail with attachments over a size or of risky types.", source: """
            var MAX_BYTES = 25 * 1024 * 1024;
            var RISKY = ["exe", "js", "vbs", "scr", "bat", "cmd", "ps1", "jar", "iso", "docm", "xlsm"];
            function process(email) {
              email.attachments.forEach(function (a) {
                var ext = (a.name.split(".").pop() || "").toLowerCase();
                if (a.size > MAX_BYTES) mailin.tag("large-attachment");
                if (RISKY.indexOf(ext) >= 0) mailin.tag("risky-attachment");
              });
            }
            """, builtIn: true),
        MailinScript(id: id(6), name: "Hash list exclude", summary: "Sets aside mail whose body SHA-256 is in the list at the top of the script (known-irrelevant mail).", source: """
            var KNOWN = [];
            function process(email) {
              if (KNOWN.indexOf(mailin.hash(email.body)) >= 0) mailin.exclude("known hash");
            }
            """, builtIn: true),
        MailinScript(id: id(7), name: "Attachment risk score", summary: "Scores attachments 0–100 (type, double extension, macro formats, size) as a column.", source: """
            function process(email) {
              var score = 0;
              email.attachments.forEach(function (a) {
                var n = a.name.toLowerCase();
                if (/\\.(exe|scr|js|vbs|bat|cmd|ps1|jar)$/.test(n)) score += 60;
                if (/\\.[a-z0-9]{2,4}\\.(exe|scr|js|vbs)$/.test(n)) score += 30;
                if (/\\.(docm|xlsm|pptm)$/.test(n)) score += 30;
                if (/\\.(zip|rar|7z|iso|img)$/.test(n)) score += 15;
              });
              if (email.attachments.length) mailin.column("attachment_risk", String(Math.min(100, score)));
              if (score >= 60) mailin.tag("attachment-risk");
            }
            """, builtIn: true),
        MailinScript(id: id(8), name: "Keyword proximity", summary: "Tags mail where two words appear within N words of each other.", source: """
            var A = "contract", B = "terminate", WITHIN = 10;
            function process(email) {
              var words = email.body.toLowerCase().split(/\\W+/);
              var ia = [], ib = [];
              words.forEach(function (w, i) { if (w === A) ia.push(i); if (w === B) ib.push(i); });
              var near = ia.some(function (i) { return ib.some(function (j) { return Math.abs(i - j) <= WITHIN; }); });
              if (near) { mailin.tag("near:" + A + "+" + B); mailin.report(email.subject); }
            }
            """, builtIn: true),
        MailinScript(id: id(9), name: "Privilege screen", summary: "Tags mail that names counsel or carries privilege wording, for a privilege pass.", source: """
            var WORDS = ["attorney-client", "privileged", "legal advice", "work product", "counsel"];
            function process(email) {
              var t = (email.subject + " " + email.body).toLowerCase();
              if (WORDS.some(function (w) { return t.indexOf(w) >= 0; })) mailin.tag("privilege-screen");
            }
            """, builtIn: true),
        MailinScript(id: id(10), name: "Integrity check", summary: "Flags mail with no Message-ID, no Date, or a Date far from the first Received hop.", source: """
            function process(email) {
              if (!email.messageID) mailin.tag("no-message-id");
              var d = new Date(email.date);
              if (isNaN(d)) { mailin.tag("no-date"); return; }
              var r = email.headers["Received"] || "";
              var rd = new Date((r.split(";").pop() || "").trim());
              if (!isNaN(rd) && Math.abs(rd - d) > 48 * 3600 * 1000) mailin.tag("date-mismatch");
            }
            """, builtIn: true),
        MailinScript(id: id(11), name: "Entity catalogue", summary: "Lists email addresses, phone numbers and URLs in the body as columns.", source: """
            function uniq(a) { return a.filter(function (v, i) { return a.indexOf(v) === i; }); }
            function process(email) {
              var b = email.body;
              var mails = uniq(b.match(/[\\w.+-]+@[\\w-]+\\.[\\w.-]+/g) || []);
              var phones = uniq(b.match(/\\+?\\d[\\d ()-]{7,}\\d/g) || []);
              var urls = uniq(b.match(/https?:\\/\\/[^\\s<>"]+/g) || []);
              if (mails.length) mailin.column("emails_in_body", mails.join(" "));
              if (phones.length) mailin.column("phones", phones.join(" | "));
              if (urls.length) mailin.column("urls", urls.join(" "));
            }
            """, builtIn: true),
        MailinScript(id: id(12), name: "PII flag", summary: "Tags mail that appears to hold card numbers, IBANs or national ID numbers.", source: """
            function luhn(s) { var sum = 0, alt = false; for (var i = s.length - 1; i >= 0; i--) { var n = +s[i]; if (alt) { n *= 2; if (n > 9) n -= 9; } sum += n; alt = !alt; } return sum % 10 === 0; }
            function process(email) {
              var cards = (email.body.match(/\\b(?:\\d[ -]?){13,19}\\b/g) || []).map(function (c) { return c.replace(/\\D/g, ""); });
              if (cards.some(luhn)) mailin.tag("pii:card");
              if (/\\b[A-Z]{2}\\d{2}[A-Z0-9]{11,30}\\b/.test(email.body)) mailin.tag("pii:iban");
              if (/\\b\\d{3}-\\d{2}-\\d{4}\\b/.test(email.body)) mailin.tag("pii:ssn");
            }
            """, builtIn: true),
    ]
}

// MARK: - No-code recipes (S9)

struct ScriptRecipe: Codable, Equatable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable { case from, to, subject, body, attachmentName, attachmentCount, size, date }
    enum Op: String, Codable, CaseIterable, Sendable { case contains, notContains, equals, greaterThan, lessThan, matches }
    enum ActionKind: String, Codable, CaseIterable, Sendable { case tag, note, column, exclude }

    struct Condition: Codable, Equatable, Sendable, Identifiable { var id = UUID(); var field: Field; var op: Op; var value: String }
    struct Action: Codable, Equatable, Sendable, Identifiable { var id = UUID(); var kind: ActionKind; var value: String; var value2 = "" }

    var name = "New recipe"
    var matchAll = true
    var conditions: [Condition] = []
    var actions: [Action] = []

    /// The generated JavaScript (shown to the user before it is saved).
    var source: String {
        func js(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
            return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        func subject(_ f: Field) -> String {
            switch f {
            case .from: return "email.from"
            case .to: return "(email.to + ' ' + email.cc)"
            case .subject: return "email.subject"
            case .body: return "email.body"
            case .attachmentName: return "email.attachments.map(function (a) { return a.name; }).join(' ')"
            case .attachmentCount: return "email.attachments.length"
            case .size: return "email.size"
            case .date: return "new Date(email.date).getTime()"
            }
        }
        let tests: [String] = conditions.map { c in
            let s = subject(c.field)
            let v = c.field == .date ? "new Date(\(js(c.value))).getTime()" : (Double(c.value) != nil && [.attachmentCount, .size].contains(c.field) ? c.value : js(c.value))
            switch c.op {
            case .contains: return "String(\(s)).toLowerCase().indexOf(\(js(c.value.lowercased()))) >= 0"
            case .notContains: return "String(\(s)).toLowerCase().indexOf(\(js(c.value.lowercased()))) < 0"
            case .equals: return "String(\(s)).toLowerCase() === \(js(c.value.lowercased()))"
            case .greaterThan: return "(\(s)) > \(v)"
            case .lessThan: return "(\(s)) < \(v)"
            case .matches: return "new RegExp(\(js(c.value)), 'i').test(String(\(s)))"
            }
        }
        let cond = tests.isEmpty ? "true" : tests.map { "(\($0))" }.joined(separator: matchAll ? " && " : " || ")
        let acts = actions.map { a -> String in
            switch a.kind {
            case .tag: return "    mailin.tag(\(js(a.value)));"
            case .note: return "    mailin.note(\(js(a.value)));"
            case .column: return "    mailin.column(\(js(a.value)), \(js(a.value2)));"
            case .exclude: return "    mailin.exclude(\(js(a.value)));"
            }
        }.joined(separator: "\n")
        return """
            // Generated by the mailin recipe builder: \(name)
            function process(email) {
              if (\(cond)) {
            \(acts)
              }
            }
            """
    }
}

// MARK: - .mailinscript files (S11)

enum ScriptFile {
    static let fileExtension = "mailinscript"

    private struct Envelope: Codable { var format = "mailin.script"; var version = 1; var script: MailinScript; var sha256: String }

    static func export(_ s: MailinScript) throws -> Data {
        var copy = s
        copy.builtIn = false
        copy.runsAtImport = false
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Envelope(script: copy, sha256: copy.sha256))
    }

    /// Refuses a file whose source no longer matches its recorded SHA-256.
    static func importScript(_ data: Data) throws -> MailinScript {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.format == "mailin.script" else {
            throw ScriptError.compile(String(localized: "this is not a mailin script file"))
        }
        guard env.script.sha256 == env.sha256 else {
            throw ScriptError.compile(String(localized: "the script was changed after it was exported (SHA-256 mismatch)"))
        }
        var s = env.script
        s.id = UUID()
        s.runsAtImport = false
        return s
    }
}

// MARK: - On-device assistant (S10)

@available(macOS 26.0, iOS 26.0, *)
enum ScriptAssistant {
    static var isAvailable: Bool { FoundationModelEngine.isAvailable }

    /// Drafts a script from a sentence. The draft is shown for review and is
    /// never run unseen; it must compile before it can be saved.
    static func draft(_ request: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You write small JavaScript functions for the mailin email archive. \
            Reply with JavaScript only, no explanation, no markdown fences. \
            Define exactly: function process(email) { ... } \
            email has: subject, from, to, cc, date (string), body (plain text), messageID, headers (object), \
            attachments (array of {name, type, size}), tags (array), size (bytes). \
            Available calls: mailin.tag(name), mailin.untag(name), mailin.note(text), mailin.column(key, value), \
            mailin.exclude(reason), mailin.report(line), mailin.hash(text, "sha256"|"sha1"|"sha512"). \
            No network, no timers, no eval, no require, no import.
            """)
        let reply = try await session.respond(to: request).content
        return reply
            .replacingOccurrences(of: "```javascript", with: "")
            .replacingOccurrences(of: "```js", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
