//
//  ScriptEngine.swift
//  maxmailin
//
//  3.1 S5–S7 (switch: `v31Scripts`, preview, off) — mailin Scripts.
//
//  A script is JavaScript run by JavaScriptCore, on this device only. It
//  defines `function process(email)` and calls `mailin.tag(…)`,
//  `mailin.untag(…)`, `mailin.note(…)`, `mailin.column(key, value)`,
//  `mailin.exclude(reason)` and `mailin.report(line)`. There are no network
//  objects in JavaScriptCore (no fetch, XMLHttpRequest, WebSocket or timers),
//  and `eval` / `Function` are removed so code cannot be built at run time.
//
//  Watchdog: JavaScriptCore has no public time-limit API, so every loop in the
//  script is rewritten to call a guard that throws once one email has taken
//  more than `perEmailSeconds`; deep recursion ends in JavaScriptCore's own
//  stack-overflow error; the run stops if the app's memory passes
//  `memoryCeiling`. These limits are stated on the Scripts screen.
//
//  Writes are proposals: a dry run counts what would change; "Apply" runs the
//  same script again and writes, in batches. Every run is recorded in
//  `script_runs` with the script's SHA-256 and version, the email-set
//  fingerprint and a digest of the changes, so "Re-run and prove" can show
//  the same script on the same emails gives the same changes.
//

import Foundation
import JavaScriptCore
import CryptoKit
@testable import ArchiveCore

enum ScriptPolicy {
    /// Pushed by CapabilityWiring (`v31Scripts`).
    nonisolated(unsafe) static var isEnabled = false
    static let perEmailSeconds: Double = 5
    static let memoryCeiling: UInt64 = 2 * 1_073_741_824
    /// Largest array, string or buffer a script may build in one native call.
    static let maxElements = 50_000_000
    /// Largest tag, note or column value a script may write.
    static let maxValueBytes = 65_536
}

// MARK: - Model

struct MailinScript: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var version: String = "1"
    var summary: String = ""
    var source: String
    /// S5: also run on every newly imported email.
    var runsAtImport = false
    var builtIn = false

    var sha256: String { Data(SHA256.hash(data: Data(source.utf8))).hexString }
    var label: String { "\(name) v\(version)" }
}

struct ScriptChange: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case tag, untag, note, column, exclude }
    var emailID: UUID
    var kind: Kind
    var key: String
    var value: String
}

struct ScriptRunSummary: Equatable, Sendable {
    var runID = UUID().uuidString
    var processed = 0
    var total = 0
    var counts: [ScriptChange.Kind: Int] = [:]
    var emailsChanged = 0
    var report: [String] = []
    var errors: [String] = []
    var stoppedReason: String?
    var changesDigest = ""
    var fingerprint = ""

    var line: String {
        var parts = [String(localized: "\(processed) of \(total) emails read")]
        for k in [ScriptChange.Kind.tag, .untag, .note, .column, .exclude] where (counts[k] ?? 0) > 0 {
            parts.append(Self.phrase(k, counts[k] ?? 0))
        }
        if !errors.isEmpty { parts.append(String(localized: "\(errors.count) errors")) }
        if let stoppedReason { parts.append(String(localized: "stopped: \(stoppedReason)")) }
        return parts.joined(separator: " · ")
    }

    /// One change kind and its count, worded so no plural form is needed.
    static func phrase(_ kind: ScriptChange.Kind, _ n: Int) -> String {
        switch kind {
        case .tag: return String(localized: "tags added: \(n)")
        case .untag: return String(localized: "tags removed: \(n)")
        case .note: return String(localized: "notes: \(n)")
        case .column: return String(localized: "column values: \(n)")
        case .exclude: return String(localized: "set aside: \(n)")
        }
    }

    /// The Runs list line for a recorded run (`changesJSON` as the engine writes it).
    static func describe(changesJSON: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(changesJSON.utf8)) as? [String: Any] else { return "" }
        let applied = object["applied"] as? Bool ?? false
        let counts = object["counts"] as? [String: Int] ?? [:]
        var parts = [applied ? String(localized: "Applied") : String(localized: "Dry run")]
        for k in [ScriptChange.Kind.tag, .untag, .note, .column, .exclude] {
            if let n = counts[k.rawValue], n > 0 { parts.append(phrase(k, n)) }
        }
        return parts.joined(separator: " · ")
    }
}

enum ScriptError: LocalizedError, Equatable {
    case compile(String)
    case noProcessFunction
    case runtime(String)
    case watchdog(String)

    var errorDescription: String? {
        switch self {
        case .compile(let m): return String(localized: "The script has an error: \(m)")
        case .noProcessFunction: return String(localized: "The script must define function process(email).")
        case .runtime(let m): return String(localized: "The script failed: \(m)")
        case .watchdog(let m): return String(localized: "The script was stopped: \(m)")
        }
    }
}

// MARK: - Sandbox

enum ScriptSandbox {
    /// Rewrites `while (c)` → `while (__mailinTick() && (c))` and
    /// `for (a; b; c)` → `for (a; __mailinTick() && (b); c)`, skipping strings,
    /// template literals and comments. `do … while (c)` is covered by the
    /// `while` rewrite. `for…of` / `for…in` walk finite collections.
    static func instrument(_ src: String) -> String {
        let s = Array(src)
        var out = ""
        out.reserveCapacity(s.count + 64)
        var i = 0
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
        while i < s.count {
            let c = s[i]
            // Comments
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { out.append(s[i]); i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                out.append("/*"); i += 2
                while i < s.count, !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") { out.append(s[i]); i += 1 }
                if i < s.count { out.append("*/"); i += 2 }
                continue
            }
            // Regular-expression literals (a quote inside one must not
            // start a "string" that hides the code after it).
            if c == "/", let end = regexEnd(s, i) {
                out += String(s[i..<end]); i = end
                continue
            }
            // Strings and template literals
            if c == "\"" || c == "'" || c == "`" {
                out.append(c); i += 1
                while i < s.count, s[i] != c {
                    if s[i] == "\\", i + 1 < s.count { out.append(s[i]); i += 1 }
                    out.append(s[i]); i += 1
                }
                if i < s.count { out.append(s[i]); i += 1 }
                continue
            }
            // Keywords
            let prevIdent = i > 0 && isIdent(s[i - 1])
            if !prevIdent, let kw = ["while", "for"].first(where: { k in
                let k = Array(k)
                return i + k.count <= s.count && Array(s[i..<i + k.count]) == k
                    && (i + k.count == s.count || !isIdent(s[i + k.count]))
            }) {
                var j = i + kw.count
                while j < s.count, s[j].isWhitespace { j += 1 }
                if j < s.count, s[j] == "(", let close = matchParen(s, j) {
                    let inner = String(s[(j + 1)..<close])
                    out += kw + " ("
                    if kw == "while" {
                        out += "__mailinTick() && (\(inner.isEmpty ? "true" : inner))"
                    } else {
                        let parts = splitTopLevelSemicolons(inner)
                        if parts.count == 3 {
                            let cond = parts[1].trimmingCharacters(in: .whitespaces)
                            out += "\(parts[0]); __mailinTick() && (\(cond.isEmpty ? "true" : cond)); \(parts[2])"
                        } else {
                            out += inner   // for…of / for…in
                        }
                    }
                    out += ")"
                    i = close + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// If a regular-expression literal starts at `i` (a `/` where an
    /// expression may begin), the index just past its flags; else nil.
    static func regexEnd(_ s: [Character], _ i: Int) -> Int? {
        guard i < s.count, s[i] == "/", i + 1 < s.count, s[i + 1] != "/", s[i + 1] != "*" else { return nil }
        var p = i - 1
        while p >= 0, s[p].isWhitespace { p -= 1 }
        if p >= 0 {
            let prev = s[p]
            if prev.isLetter || prev.isNumber || prev == "_" || prev == "$" || prev == ")" || prev == "]" || prev == "}" {
                // After a value it is division — unless the word is a keyword.
                var w = p
                while w >= 0, s[w].isLetter { w -= 1 }
                let word = String(s[(w + 1)...p])
                guard ["return", "typeof", "case", "in", "of", "delete", "void", "throw", "new", "else", "do"].contains(word) else { return nil }
            }
        }
        var j = i + 1
        var inClass = false
        while j < s.count {
            let c = s[j]
            if c == "\n" { return nil }
            if c == "\\" { j += 2; continue }
            if c == "[" { inClass = true } else if c == "]" { inClass = false } else if c == "/", !inClass { break }
            j += 1
        }
        guard j < s.count else { return nil }
        j += 1
        while j < s.count, s[j].isLetter { j += 1 }
        return j
    }

    static func matchParen(_ s: [Character], _ open: Int) -> Int? {
        var depth = 0
        var i = open
        var quote: Character?
        while i < s.count {
            let c = s[i]
            if quote == nil, c == "/", let end = regexEnd(s, i) { i = end; continue }
            if let q = quote {
                if c == "\\" { i += 2; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    static func splitTopLevelSemicolons(_ str: String) -> [String] {
        let s = Array(str)
        var parts: [String] = []
        var start = 0
        var depth = 0
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "/", let end = regexEnd(s, i) { i = end; continue }
            switch c {
            case "\"", "'", "`":
                i += 1
                while i < s.count, s[i] != c { if s[i] == "\\" { i += 1 }; i += 1 }
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case ";" where depth == 0:
                parts.append(String(s[start..<i])); start = i + 1
            default: break
            }
            i += 1
        }
        parts.append(String(s[min(start, s.count)...]))
        return parts
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

// MARK: - Runtime (one script, used from one task at a time)

final class ScriptRuntime: @unchecked Sendable {
    private let context: JSContext
    private var pending: [ScriptChange] = []
    private var report: [String] = []
    private var currentID = UUID()
    private var deadline = Date.distantFuture
    let script: MailinScript

    init(_ script: MailinScript) throws {
        self.script = script
        guard let ctx = JSContext(virtualMachine: JSVirtualMachine()) else { throw ScriptError.runtime("no JavaScript context") }
        context = ctx
        ctx.name = script.label

        var ticks = 0
        let tick: @convention(block) () -> Bool = { [unowned self] in
            if Date() > self.deadline {
                self.context.exception = JSValue(newErrorFromMessage: "__mailin_watchdog__", in: self.context)
                return false
            }
            // Memory, checked every 1,024 loop turns (a loop that keeps doubling a string).
            ticks &+= 1
            if ticks & 1023 == 0, ScriptSandbox.footprint() > ScriptPolicy.memoryCeiling {
                self.context.exception = JSValue(newErrorFromMessage: "__mailin_memory__", in: self.context)
                return false
            }
            return true
        }
        ctx.setObject(tick, forKeyedSubscript: "__mailinTick" as NSString)

        let api = JSValue(newObjectIn: ctx)!
        func add(_ kind: ScriptChange.Kind) -> @convention(block) (JSValue, JSValue) -> Void {
            return { [unowned self] a, b in
                let key = a.isUndefined ? "" : a.toString() ?? ""
                let value = b.isUndefined ? "" : b.toString() ?? ""
                // Stated limit: tags, notes and column values up to 64 KB each.
                guard key.utf8.count <= ScriptPolicy.maxValueBytes, value.utf8.count <= ScriptPolicy.maxValueBytes else {
                    self.context.exception = JSValue(newErrorFromMessage: "__mailin_value__", in: self.context)
                    return
                }
                self.pending.append(ScriptChange(emailID: self.currentID, kind: kind, key: key, value: value))
            }
        }
        api.setObject(add(.tag), forKeyedSubscript: "tag" as NSString)
        api.setObject(add(.untag), forKeyedSubscript: "untag" as NSString)
        api.setObject(add(.note), forKeyedSubscript: "note" as NSString)
        api.setObject(add(.column), forKeyedSubscript: "column" as NSString)
        api.setObject(add(.exclude), forKeyedSubscript: "exclude" as NSString)
        let reportFn: @convention(block) (JSValue) -> Void = { [unowned self] v in
            if self.report.count < 10_000 { self.report.append(v.toString() ?? "") }
        }
        api.setObject(reportFn, forKeyedSubscript: "report" as NSString)
        api.setObject(reportFn, forKeyedSubscript: "log" as NSString)
        let sha: @convention(block) (JSValue, JSValue) -> String = { v, alg in
            let d = Data((v.toString() ?? "").utf8)
            switch alg.isUndefined ? "sha256" : (alg.toString() ?? "sha256").lowercased() {
            case "sha1": return Data(Insecure.SHA1.hash(data: d)).hexString
            case "sha512": return Data(SHA512.hash(data: d)).hexString
            default: return Data(SHA256.hash(data: d)).hexString
            }
        }
        api.setObject(sha, forKeyedSubscript: "hash" as NSString)
        ctx.setObject(api, forKeyedSubscript: "mailin" as NSString)

        // No run-time code construction.
        ctx.evaluateScript("""
            (function () {
              'use strict';
              // No run-time code construction, through any function kind.
              for (const f of [function(){}, async function(){}, function*(){}, async function*(){}]) {
                Object.defineProperty(Object.getPrototypeOf(f), 'constructor', { value: undefined });
              }
              delete globalThis.eval;
              globalThis.Function = undefined;
              // Allocation guards for the native calls a loop guard cannot see.
              const MAX = \(ScriptPolicy.maxElements);
              const limit = (n) => { if (typeof n === 'number' && n > MAX) throw new RangeError('__mailin_limit__'); };
              const wrap = (proto, name, size) => {
                const orig = proto[name];
                Object.defineProperty(proto, name, { value: function (...a) { limit(size(this, a)); return orig.apply(this, a); } });
              };
              wrap(Array.prototype, 'fill', (t) => t.length);
              wrap(Array.prototype, 'join', (t) => t.length);
              wrap(String.prototype, 'repeat', (t, a) => t.length * (Number(a[0]) || 0));
              wrap(String.prototype, 'padStart', (t, a) => Number(a[0]) || 0);
              wrap(String.prototype, 'padEnd', (t, a) => Number(a[0]) || 0);
              const from = Array.from;
              Array.from = function (src, ...a) { limit(src && src.length); return from.call(this, src, ...a); };
              for (const name of ['ArrayBuffer','SharedArrayBuffer','Int8Array','Uint8Array','Uint8ClampedArray','Int16Array','Uint16Array',
                                  'Int32Array','Uint32Array','Float32Array','Float64Array','BigInt64Array','BigUint64Array']) {
                const T = globalThis[name];
                if (!T) continue;
                globalThis[name] = new Proxy(T, { construct(target, args) { limit(args[0]); return Reflect.construct(target, args); } });
              }
              Object.freeze(globalThis.mailin);
            })();
            """)
        ctx.exception = nil
        // Top-level code is held to the same per-email time limit.
        deadline = Date().addingTimeInterval(ScriptPolicy.perEmailSeconds)
        ctx.evaluateScript(ScriptSandbox.instrument(script.source))
        if let e = ctx.exception {
            throw ScriptError.compile(e.toString() ?? "syntax error")
        }
        guard let fn = ctx.objectForKeyedSubscript("process"), fn.isObject else { throw ScriptError.noProcessFunction }
    }

    /// Runs `process(email)` for one email; returns its proposed changes and report lines.
    func run(_ e: MBOXParser.RawEmail, userTags: [String], ai: StoredAnalysis? = nil) throws -> (changes: [ScriptChange], report: [String]) {
        pending.removeAll(keepingCapacity: true)
        report.removeAll(keepingCapacity: true)
        currentID = e.id
        deadline = Date().addingTimeInterval(ScriptPolicy.perEmailSeconds)
        context.exception = nil
        let obj: [String: Any] = [
            "id": e.id.uuidString,
            "subject": e.headers["Subject"] ?? "",
            "from": e.headers["From"] ?? "",
            "to": e.headers["To"] ?? "",
            "cc": e.headers["Cc"] ?? "",
            "date": e.headers["Date"] ?? e.timestamp,
            "messageID": e.headers["Message-ID"] ?? "",
            "body": e.plainBody.isEmpty ? RedactionEngine.plainText(fromHTML: e.htmlBody) : e.plainBody,
            "headers": e.headers,
            "attachments": e.attachments.map { ["name": $0.filename, "type": $0.mimeType, "size": $0.size] },
            "tags": userTags,
            "size": e.rawSource.utf8.count,
            "recovered": e.recovery?.state.rawValue ?? "live",
            // What the archive's analysis stored for this email (empty when not analysed).
            "ai": ai?.dictionary ?? [:],
        ]
        let fn = context.objectForKeyedSubscript("process")
        _ = fn?.call(withArguments: [obj])
        if let ex = context.exception {
            let msg = ex.toString() ?? "error"
            context.exception = nil
            if msg.contains("__mailin_memory__") {
                throw ScriptError.watchdog(String(localized: "the app's memory passed \(ScriptPolicy.memoryCeiling / 1_073_741_824) GB"))
            }
            if msg.contains("__mailin_limit__") || msg.contains("Out of memory") || msg.contains("Invalid array length") || msg.contains("Invalid string length") {
                throw ScriptError.watchdog(String(localized: "the script tried to build a value larger than \(ScriptPolicy.maxElements) items"))
            }
            if msg.contains("__mailin_value__") {
                throw ScriptError.runtime(String(localized: "a tag, note or column value is larger than 64 KB"))
            }
            if msg.contains("Maximum call stack") {
                throw ScriptError.runtime(String(localized: "the script called itself too deeply"))
            }
            if msg.contains("__mailin_watchdog__") {
                throw ScriptError.watchdog(String(localized: "one email took longer than \(Int(ScriptPolicy.perEmailSeconds)) seconds"))
            }
            throw ScriptError.runtime(msg)
        }
        return (pending, report)
    }
}

// MARK: - Runs

@MainActor
enum ScriptEngine {
    /// Runs `script` over every email in `query`. `apply == false` is the dry
    /// run: nothing is written, the summary shows what would change.
    static func run(_ script: MailinScript, query: EmailQuery, apply: Bool,
                    startedBy: String = "user",
                    progress: @escaping (Int, Int) -> Void) async throws -> ScriptRunSummary {
        guard ScriptPolicy.isEnabled else { throw ScriptError.runtime(String(localized: "Scripts are off in Settings ▸ Modules.")) }
        guard TierAccess.allows(.scripts) else { throw ScriptError.runtime(String(localized: "mailin Scripts are part of Professional.")) }
        if apply, let why = OrgPolicy.denial(.review) { throw ScriptError.runtime(why) }
        let runtime = try ScriptRuntime(script)
        let store = ScopeJobEnvironment.store
        var summary = ScriptRunSummary()
        summary.total = try await ScopeJobEnvironment.archive.count(query: query)
        let started = Date()
        var fingerprint = EmailSetFingerprint()
        var digest = SHA256()
        var changedEmails = Set<UUID>()

        for try await batch in ScopeJobEnvironment.archive.streamFullEmails(query: query, batchSize: 200) {
            if Task.isCancelled { summary.stoppedReason = String(localized: "cancelled"); break }
            if ScriptSandbox.footprint() > ScriptPolicy.memoryCeiling {
                summary.stoppedReason = String(localized: "the app's memory passed \(ScriptPolicy.memoryCeiling / 1_073_741_824) GB"); break
            }
            let tags = (try? await store.userTags(ids: batch.map(\.id))) ?? [:]
            let analysis = (try? await store.storedAnalysis(for: batch.map(\.id))) ?? [:]
            var batchChanges: [ScriptChange] = []
            var stop = false
            for e in batch {
                do {
                    // JavaScriptCore objects are autoreleased; drain per email (async loops never drain).
                    let r = try autoreleasepool { try runtime.run(e, userTags: Array(tags[e.id] ?? []).sorted(), ai: analysis[e.id]) }
                    batchChanges += r.changes
                    if summary.report.count < 10_000 { summary.report += r.report }
                } catch let err as ScriptError {
                    if case .watchdog = err { summary.stoppedReason = err.localizedDescription; stop = true; break }
                    if summary.errors.count < 200 { summary.errors.append("\(e.id.uuidString.prefix(8)): \(err.localizedDescription)") }
                }
                fingerprint.add(e.id)
                summary.processed += 1
            }
            for c in batchChanges {
                summary.counts[c.kind, default: 0] += 1
                changedEmails.insert(c.emailID)
                digest.update(data: Data("\(c.emailID.uuidString)|\(c.kind.rawValue)|\(c.key)|\(c.value)\n".utf8))
            }
            if apply { try await ScriptApplier.apply(batchChanges, by: script) }
            progress(summary.processed, summary.total)
            if stop { break }
        }
        summary.emailsChanged = changedEmails.count
        summary.changesDigest = Data(digest.finalize()).hexString
        summary.fingerprint = fingerprint.hex

        let countsJSON = (try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: summary.counts.map { ($0.key.rawValue, $0.value) })))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try? await store.scriptRunRecord(.init(
            runID: summary.runID, name: script.name, sha256: script.sha256, version: script.version,
            scopeJSON: ScopeJob.json(query) ?? "", fingerprint: summary.fingerprint, processed: summary.processed,
            changesJSON: "{\"applied\":\(apply),\"digest\":\"\(summary.changesDigest)\",\"counts\":\(countsJSON)}",
            startedAt: started, finishedAt: Date(), startedBy: startedBy))
        if apply, summary.emailsChanged > 0 {
            ScopeJobEnvironment.logAction("Script applied",
                detail: "\(script.label) (SHA-256 \(script.sha256.prefix(16))…): \(summary.line) — scope: \(ScopeJob.describe(query))")
        }
        return summary
    }

    /// S7 "Re-run and prove": a dry run of the same script over the recorded
    /// scope; equal fingerprint and digest = same emails, same changes.
    static func prove(_ row: SQLiteEmailStore.ScriptRunRow, script: MailinScript) async throws -> String {
        guard script.sha256 == row.sha256 else {
            return String(localized: "The script has changed since that run (SHA-256 differs); the run cannot be reproduced with this version.")
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = row.scopeJSON.data(using: .utf8), let query = try? dec.decode(EmailQuery.self, from: data) else {
            return String(localized: "The run's scope could not be read.")
        }
        let again = try await run(script, query: query, apply: false, startedBy: "prove") { _, _ in }
        let recordedDigest = (row.changesJSON.range(of: "\"digest\":\"").map { r in
            String(row.changesJSON[r.upperBound...].prefix(64)) }) ?? ""
        let sameEmails = again.fingerprint == row.fingerprint
        let sameChanges = again.changesDigest == recordedDigest
        switch (sameEmails, sameChanges) {
        case (true, true): return String(localized: "Proved: the same \(again.processed) emails and the same changes.")
        case (true, false): return String(localized: "Same emails, different changes: the emails' tags or text changed since the run.")
        default: return String(localized: "The scope now holds a different set of emails (\(again.processed) now).")
        }
    }
}

/// Writes changes in batches; notes and columns name the script.
@MainActor
enum ScriptApplier {
    static func apply(_ changes: [ScriptChange], by script: MailinScript) async throws {
        guard !changes.isEmpty else { return }
        let store = ScopeJobEnvironment.store
        var tagAdds: [String: [UUID]] = [:], tagRemoves: [String: [UUID]] = [:]
        var columns: [UUID: [String: String]] = [:]
        var excluded: [UUID] = []
        for c in changes {
            switch c.kind {
            case .tag: tagAdds[c.key, default: []].append(c.emailID)
            case .untag: tagRemoves[c.key, default: []].append(c.emailID)
            case .column: columns[c.emailID, default: [:]][c.key] = c.value
            case .exclude: excluded.append(c.emailID)
            case .note:
                let existing = ForensicManager.shared.annotationFor(c.emailID)?.text ?? ""
                let line = "[\(script.label)] \(c.key)"
                if !existing.contains(line) {
                    ForensicManager.shared.applyMergedAnnotation(c.emailID, annotation: .init(
                        text: existing.isEmpty ? line : existing + "\n" + line, examiner: script.label, timestamp: Date()))
                }
            }
        }
        for (t, ids) in tagAdds where !t.isEmpty { try await store.userTagAdd(t, ids: ids) }
        for (t, ids) in tagRemoves where !t.isEmpty { try await store.userTagRemove(t, ids: ids) }
        if !columns.isEmpty { try await store.customValuesSet(columns, setBy: script.label) }
        // Set aside = Trash (reversible), never deleted.
        if !excluded.isEmpty { ReviewStateService.shared.moveToTrash(excluded) }
    }
}

// MARK: - Import-time runs (S5)

/// Runs every script marked "runs at import" on each committed import batch.
/// One `script_runs` row per script and source, updated as batches arrive.
@MainActor
final class ScriptImportRunner {
    static let shared = ScriptImportRunner()
    private var totals: [String: (summary: ScriptRunSummary, fp: EmailSetFingerprint, started: Date)] = [:]

    nonisolated static func install(_ on: Bool) {
        guard on else { ImportScriptHook.handler = nil; return }
        let hook: @Sendable ([MBOXParser.RawEmail], String) async -> [String: [String: Int]] = { emails, source in
            await ScriptImportRunner.shared.handle(emails, source: source)
        }
        ImportScriptHook.handler = hook
    }

    /// Returns what each script did to this batch (for the import receipt).
    func handle(_ emails: [MBOXParser.RawEmail], source: String) async -> [String: [String: Int]] {
        let scripts = ScriptLibraryStore.shared.scripts.filter(\.runsAtImport)
        guard ScriptPolicy.isEnabled, TierAccess.allows(.scripts), !scripts.isEmpty else { return [:] }
        var batchCounts: [String: [String: Int]] = [:]
        for script in scripts {
            guard let runtime = try? ScriptRuntime(script) else {
                batchCounts[script.label, default: [:]]["not run (script error)", default: 0] += emails.count
                continue
            }
            let key = script.id.uuidString + "|" + source
            var entry = totals[key] ?? (ScriptRunSummary(), EmailSetFingerprint(), Date())
            var changes: [ScriptChange] = []
            var failed = 0
            for e in emails {
                do { changes += try autoreleasepool { try runtime.run(e, userTags: e.tags).changes } } catch { failed += 1 }
                entry.fp.add(e.id)
                entry.summary.processed += 1
            }
            if failed > 0 { batchCounts[script.label, default: [:]]["errors", default: 0] += failed }
            entry.summary.total = entry.summary.processed
            // Counted only once written: a receipt never claims a change that did not happen.
            do {
                try await ScriptApplier.apply(changes, by: script)
                for c in changes {
                    entry.summary.counts[c.kind, default: 0] += 1
                    batchCounts[script.label, default: [:]][c.kind.rawValue, default: 0] += 1
                }
            } catch {
                batchCounts[script.label, default: [:]]["changes not written", default: 0] += changes.count
            }
            totals[key] = entry
            let counts = entry.summary.counts.map { "\"\($0.key.rawValue)\":\($0.value)" }.joined(separator: ",")
            try? await ScopeJobEnvironment.store.scriptRunRecord(.init(
                runID: "import-" + key, name: script.name, sha256: script.sha256, version: script.version,
                scopeJSON: "{\"import\":\"\(source.replacingOccurrences(of: "\"", with: "'"))\"}", fingerprint: entry.fp.hex,
                processed: entry.summary.processed, changesJSON: "{\"applied\":true,\"counts\":{\(counts)}}",
                startedAt: entry.started, finishedAt: Date(), startedBy: "import"))
            if let n = batchCounts[script.label]?[ScriptChange.Kind.exclude.rawValue], n > 0 {
                ScopeJobEnvironment.logAction("Import script set emails aside",
                                                 detail: "\(n) emails from \(source) moved to Trash by \(script.label)")
            }
        }
        return batchCounts
    }

    /// "12 set aside by Script X v3" lines for the import receipt.
    func receiptLines(for source: String) -> [String] {
        totals.filter { $0.key.hasSuffix("|" + source) }.compactMap { key, v in
            let name = ScriptLibraryStore.shared.scripts.first { key.hasPrefix($0.id.uuidString) }?.label ?? "script"
            let parts = v.summary.counts.map { "\($0.value) \($0.key.rawValue)" }.sorted().joined(separator: ", ")
            return parts.isEmpty ? nil : "\(name): \(parts)"
        }
    }
}
