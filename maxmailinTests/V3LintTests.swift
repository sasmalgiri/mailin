//
//  V3LintTests.swift
//  maxmailinTests
//
//  §3-F9 / R2: the audit's lessons as checks that fail the suite (and so
//  block every commit, rule 11). The rules match `Scripts/lint_v3.py`, which
//  reports the same violations from the command line and writes the
//  old-file baseline.
//
//  • New files (not in the tree at 21679da, before the 3.0 engines pass)
//    must have zero violations.
//  • Old files may not exceed their baseline count per rule (a ceiling that
//    only goes down; allow-listed until R1).
//  • A line holding `lint:allow` is skipped — the reason is written there.
//

import Foundation
import Testing

@Suite("3.0 audit-lesson lints")
struct V3LintTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // maxmailinTests
        .deletingLastPathComponent()   // repo root

    private static let directories = ["maxmailin", "Packages/ArchiveCore/Sources/ArchiveCore"]

    /// rule → pattern (one line).
    private static let lineRules: [(String, String)] = [
        ("discardedSaveOutcome", #"_\s*=\s*(?:await\s+)?(?:PlatformFileSaver|PlatformExport)\."#),
        ("workingSetCap", #"workingSet\(query:[^)]*cap:"#),
        ("countBreakCap", #"count\s*>=?\s*[0-9][0-9_]*\s*\{\s*break"#),
        ("forceCast", #"\bas!\s"#),
        ("forceTry", #"\btry!\s"#),
        ("silentUserWrite", #"try\?\s+[^\n]*\.write\(to:\s*url\b"#),
        // A save panel that skips the organisation's export policy (use ManagedSavePanel).
        ("unmanagedSavePanel", #"\bNSSavePanel\(\)"#),
    ]
    /// rule → (first, second within `span` lines after it).
    private static let pairRules: [(String, String, String, Int)] = [
        ("documentBeforeSave", #"DocumentRegistry\.(?:capture|post)"#, #"PlatformExport\.save|PlatformFileSaver\."#, 30),
    ]
    /// rule → (a, b within `span` lines either side).
    private static let nearRules: [(String, String, String, Int)] = [
        ("allNextToCap", #"(?:Text\(|String\(localized:\s*)"All\b"#, #"\.prefix\(\s*[0-9]{2,}"#, 15),
    ]

    private struct Baseline: Decodable {
        let oldFiles: [String]
        let ceilings: [String: [String: Int]]
    }

    private static func regex(_ p: String) throws -> NSRegularExpression { try NSRegularExpression(pattern: p) }

    private static func matches(_ rx: NSRegularExpression, _ line: String) -> Bool {
        rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Lines with comments and `lint:allow` lines blanked (positions kept).
    static func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") || line.contains("lint:allow") { return "" }
            return line
        }
    }

    static func lint(_ text: String) throws -> [String: Int] {
        let lines = codeLines(text)
        var counts: [String: Int] = [:]
        for (rule, pattern) in lineRules {
            let rx = try regex(pattern)
            let n = lines.filter { matches(rx, $0) }.count
            if n > 0 { counts[rule] = n }
        }
        for (rule, a, b, span) in pairRules {
            let ra = try regex(a), rb = try regex(b)
            var n = 0
            for (i, line) in lines.enumerated() where matches(ra, line) {
                let after = lines[min(i + 1, lines.count)..<min(i + 1 + span, lines.count)]
                if after.contains(where: { matches(rb, $0) }) { n += 1 }
            }
            if n > 0 { counts[rule] = n }
        }
        for (rule, a, b, span) in nearRules {
            let ra = try regex(a), rb = try regex(b)
            var n = 0
            for (i, line) in lines.enumerated() where matches(ra, line) {
                let around = lines[max(0, i - span)..<min(i + span + 1, lines.count)]
                if around.contains(where: { matches(rb, $0) }) { n += 1 }
            }
            if n > 0 { counts[rule] = n }
        }
        let empty = taskOnEmptyGroupCount(lines)
        if empty > 0 { counts["taskOnEmptyGroup"] = empty }
        return counts
    }

    /// `Group { if … { … } }.task { … }` with no `else`: a Group hands its
    /// modifiers to its children, so while the condition is false there is
    /// nothing to run the task — content the task loads can never appear
    /// (the recovery and search-coverage badges, found 2026-10-14).
    static func taskOnEmptyGroupCount(_ lines: [String]) -> Int {
        func indent(_ l: String) -> Int { l.prefix { $0 == " " }.count }
        var n = 0
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "Group {" {
            guard let first = lines[(i + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  first.trimmingCharacters(in: .whitespaces).hasPrefix("if ") else { continue }
            let level = indent(line)
            guard let close = lines.indices.dropFirst(i + 1).first(where: {
                indent(lines[$0]) == level && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("}")
            }) else { continue }
            let body = lines[(i + 1)..<close]
            if body.contains(where: { indent($0) == level + 4 && $0.trimmingCharacters(in: .whitespaces).hasPrefix("} else") }) { continue }
            guard close + 1 < lines.count else { continue }
            let next = lines[close + 1].trimmingCharacters(in: .whitespaces)
            if next.hasPrefix(".task") || next.hasPrefix(".onAppear") { n += 1 }
        }
        return n
    }

    @Test("New 3.0 code has no audit-lesson violations; old files do not get worse")
    func noNewViolations() throws {
        let baselineURL = Self.repoRoot.appendingPathComponent("Scripts/lint_v3_baseline.json")
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baselineURL))
        let old = Set(baseline.oldFiles)
        var problems: [String] = []
        var scanned = 0
        for dir in Self.directories {
            let base = Self.repoRoot.appendingPathComponent(dir, isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".swift") }.sorted()
            for name in names {
                let rel = "\(dir)/\(name)"
                let text = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
                scanned += 1
                for (rule, n) in try Self.lint(text) {
                    let allowed = old.contains(rel) ? (baseline.ceilings[rel]?[rule] ?? 0) : 0
                    if n > allowed { problems.append("\(rel): \(rule) \(n) (allowed \(allowed))") }
                }
            }
        }
        #expect(scanned > 300, "the source tree was found (\(scanned) files)")
        #expect(problems.isEmpty, "audit-lesson violations:\n\(problems.joined(separator: "\n"))")
    }

    /// Each rule catches what it is for and ignores comments and allowed lines.
    @Test("Each rule fires on its pattern and not on comments or allowed lines")
    func rulesFire() throws {
        let samples: [(String, String)] = [
            ("discardedSaveOutcome", "_ = await PlatformExport.save(data, name: n)"),
            ("workingSetCap", "let set = workingSet(query: q, cap: 2000)"),
            ("countBreakCap", "if acc.count >= 2_000 { break }"),
            ("forceCast", "let v = x as! String"),
            ("forceTry", "let r = try! NSRegularExpression(pattern: p)"),
            ("silentUserWrite", "try? data.write(to: url)"),
            ("unmanagedSavePanel", "let panel = NSSavePanel()"),
        ]
        for (rule, line) in samples {
            #expect(try Self.lint(line)[rule] == 1, "\(rule) fires")
            #expect(try Self.lint("// " + line)[rule] == nil, "\(rule) ignores comments")
            #expect(try Self.lint(line + "   // lint:allow reason")[rule] == nil, "\(rule) honours lint:allow")
        }
        let pair = "DocumentRegistry.capture(.report)\nlet x = 1\nlet r = await PlatformExport.save(d)"
        #expect(try Self.lint(pair)["documentBeforeSave"] == 1)
        let near = "let shown = rows.prefix(50)\nText(\"All emails\")"
        #expect(try Self.lint(near)["allNextToCap"] == 1)
        let group = "        Group {\n            if let info {\n                Text(info)\n            }\n        }\n        .task { info = await load() }"
        #expect(try Self.lint(group)["taskOnEmptyGroup"] == 1)
        let withElse = group.replacingOccurrences(of: "            }\n        }", with: "            } else {\n                Color.clear\n            }\n        }")
        #expect(try Self.lint(withElse)["taskOnEmptyGroup"] == nil, "an else branch keeps a view there")
    }
}
