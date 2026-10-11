@testable import ArchiveCore
//
//  V3GoldenTests.swift
//  maxmailinTests
//
//  §3-F8: the golden archive — a fixed corpus whose answers are known BY
//  CONSTRUCTION (each email is generated from a spec that says what was
//  planted in it), and one parameterized test per 3.0 tool that checks the
//  tool's answer against the spec. The filler text carries no digits, no
//  addresses and no legal words, so nothing is found that was not planted.
//
//  Runs on a disposable archive bound through `ScopeJobEnvironment`.
//

import Foundation
import Testing
@testable import maxmailin

/// What one golden email carries.
struct GoldenSpec: Sendable {
    let index: Int
    let from: String
    var ssn = false
    var confidentialKeyword = false
    var privileged = false
    var url: String? = nil
    var ip: String? = nil
    var hash: String? = nil
    var spf = false, dkim = false, dmarc = false
    /// Same From/Subject/Date/body as this index (a content duplicate).
    var duplicateOf: Int? = nil
}

enum GoldenArchive {
    static let north = "alice@north.example"
    static let south = "bob@south.example"
    static let baseEpoch: TimeInterval = 1_704_067_200   // 2024-01-01 UTC

    /// 40 emails over ~4 months with planted facts.
    static let specs: [GoldenSpec] = {
        var out: [GoldenSpec] = []
        for i in 0..<40 {
            var s = GoldenSpec(index: i, from: i % 4 == 0 ? north : south)
            s.ssn = [1, 5, 9, 13, 17].contains(i)
            s.confidentialKeyword = i % 5 == 2
            s.privileged = [3, 11, 19, 27].contains(i)
            if [4, 8, 12].contains(i) { s.url = "https://evil-\(i).example/login" }
            if [6, 10].contains(i) { s.ip = "203.0.113.\(i)" }
            if i == 14 { s.hash = String(repeating: "ab12", count: 16) }
            s.spf = i % 2 == 0
            s.dkim = i % 2 == 0
            s.dmarc = i % 4 == 0
            if i == 38 || i == 39 { s.duplicateOf = 36 }
            out.append(s)
        }
        return out
    }()

    private static let words = ["weekly", "notes", "for", "the", "team", "about", "planning", "and", "review", "of", "the", "garden", "project"]

    static func email(_ spec: GoldenSpec) -> MBOXParser.RawEmail {
        let source = spec.duplicateOf.map { specs[$0] } ?? spec
        let date = Date(timeIntervalSince1970: baseEpoch + Double(source.index) * 3 * 86_400)
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = TimeZone(identifier: "UTC")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var body = (0..<12).map { words[($0 + source.index) % words.count] }.joined(separator: " ") + "."
        if source.ssn { body += " Reference 078-05-1120 on file." }
        if source.confidentialKeyword { body += " The confidential figures follow." }
        if source.privileged { body += " This note is attorney-client privileged." }
        if let url = source.url { body += " Visit \(url) now." }
        if let ip = source.ip { body += " Host \(ip) responded." }
        if let hash = source.hash { body += " Sample \(hash) seen." }
        var auth: [String] = []
        if source.spf { auth.append("spf=pass") }
        if source.dkim { auth.append("dkim=pass") }
        if source.dmarc { auth.append("dmarc=pass") }
        let subject = "Golden note " + String(UnicodeScalar(UInt8(65 + source.index % 26)))
        var headers = ["Message-ID": "<golden-\(spec.index)@test>", "Subject": subject, "From": source.from,
                       "To": "team@east.example", "Date": rfc.string(from: date)]
        if !auth.isEmpty { headers["Authentication-Results"] = "mx.east.example; " + auth.joined(separator: " ") }
        return MBOXParser.RawEmail(
            headers: headers,
            rawSource: headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n" + body,
            messageType: "email", attachments: [],
            timestamp: ISO8601DateFormatter().string(from: date),
            domains: [String(source.from.split(separator: "@").last ?? "")],
            plainBody: body, htmlBody: "")
    }

    static var emails: [MBOXParser.RawEmail] { specs.map(email) }

    static func count(_ predicate: (GoldenSpec) -> Bool) -> Int {
        specs.filter { predicate($0.duplicateOf.map { specs[$0] } ?? $0) }.count
    }
}

enum GoldenTool: String, CaseIterable, Sendable {
    case search, exclusions, pii, keywords, privilege, indicators, itAdmin, duplicates, bates, fingerprint, shadow
    case identify, classify, reviewPlan, verify, productionFiles, custodians, batchTag, automation
    case investigationReport, personalCleanup, predictive, nearDuplicates, aggregates, topics, aiTools
}

@MainActor
@Suite("Golden archive: every 3.0 tool's answer matches what was planted", .serialized)
struct V3GoldenTests {

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let archive: ArchiveDataService
        /// Legal files of this archive only (never the app's).
        let custodians: CustodianManager
        let legal: LegalStateMirror
        var job: ScopeJobEnvironment {
            ScopeJobEnvironment(archive: archive, store: store, root: root, custodian: custodians, legal: legal)
        }
    }

    private static func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let emails = GoldenArchive.emails
        try await store.insertBatch(emails, batchSize: 100)
        try await fts.indexBatch(emails)
        let custodians = CustodianManager(directory: root.appendingPathComponent("legal", isDirectory: true))
        let legal = LegalStateMirror(manager: custodians)
        legal.enabledOverride = false
        return Env(root: root, store: store,
                   archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)),
                   custodians: custodians, legal: legal)
    }

    @Test("Tool answer equals the planted facts", arguments: GoldenTool.allCases)
    func toolMatchesGolden(_ tool: GoldenTool) async throws {
        let env = try await Self.makeEnv()
        // Evidence hashes and audit rows go to this archive, never the app's.
        ForensicManager.testStoreOverride = env.store
        defer {
            ForensicManager.testStoreOverride = nil
            try? FileManager.default.removeItem(at: env.root)
        }
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            try await check(tool, env)
        }
    }

    private func check(_ tool: GoldenTool, _ env: Env) async throws {
        let total = GoldenArchive.specs.count
        switch tool {
        case .search:
            #expect(try await env.archive.count(query: .all) == total, "every golden email stored")
            var q = EmailQuery(); q.sender = "alice"
            #expect(try await env.archive.count(query: q) == GoldenArchive.count { $0.from == GoldenArchive.north })

        case .exclusions:
            let q = ArchiveQueryCompiler.compile("-from:alice", exclusions: true)
            #expect(try await env.archive.count(query: q) == GoldenArchive.count { $0.from != GoldenArchive.north })

        case .pii:
            let r = try await PIIEngine.scan(scope: .wholeArchive)
            #expect(r.counts[.ssnPattern] == GoldenArchive.count(\.ssn))
            #expect(r.counts[.ipAddress] == GoldenArchive.count { $0.ip != nil })
            // The detector also reads headers (risk context "header"): every
            // email's From and To address is a finding, so every email has
            // personal data — and nothing beyond what was planted is found.
            #expect(r.counts[.emailAddress] == 2 * total, "From + To of every email: \(r.counts)")
            #expect(Set(r.counts.keys) == [.ssnPattern, .ipAddress, .emailAddress], "nothing that was not planted: \(r.counts)")
            #expect(r.emailsWithPII == total)

        case .keywords:
            let (matches, receipt) = try await KeywordMonitorEngine.scan(
                scope: .wholeArchive, keywords: [.init(keyword: "confidential")])
            #expect(Set(matches.map(\.email.id)).count == GoldenArchive.count(\.confidentialKeyword))
            #expect(receipt.processed == total)

        case .privilege:
            let forensic = ForensicManager.shared
            let saved = forensic.privilegeFlags
            defer { forensic.privilegeFlags = saved }
            forensic.privilegeFlags = [:]
            let (flagged, _) = try await PrivilegeScanEngine.scan(query: .all)
            #expect(flagged == GoldenArchive.count(\.privileged))

        case .indicators:
            let (entries, _) = try await IOCEngine.extract(scope: .wholeArchive)
            let byType = Dictionary(grouping: entries, by: \.type).mapValues(\.count)
            #expect(byType[.url] == GoldenArchive.count { $0.url != nil })
            #expect(byType[.ipv4] == GoldenArchive.count { $0.ip != nil })
            #expect(byType[.fileHash] == GoldenArchive.count { $0.hash != nil })

        case .itAdmin:
            let (stats, _) = try await ITAdminStatsEngine.compute()
            #expect(stats.total == total)
            #expect(stats.spfPass == GoldenArchive.count(\.spf))
            #expect(stats.dkimPass == GoldenArchive.count(\.dkim))
            #expect(stats.dmarcPass == GoldenArchive.count(\.dmarc))
            #expect(stats.domains.first { $0.0 == "south.example" }?.1 == GoldenArchive.count { $0.from == GoldenArchive.south })

        case .duplicates:
            let (groups, _) = try await DuplicatesEngine.exactGroups()
            let copies = GoldenArchive.specs.filter { $0.duplicateOf != nil }
            #expect(groups.count == Set(copies.compactMap(\.duplicateOf)).count)
            #expect(groups.reduce(0) { $0 + $1.count } == copies.count + Set(copies.compactMap(\.duplicateOf)).count)

        case .bates:
            let r = try await BatesEngine.number(query: .all, prefix: "G", start: 1) { "G" + String(format: "%03d", $0) }
            #expect(r.state.assigned == total)
            #expect(r.state.first == "G001")
            #expect(r.state.last == String(format: "G%03d", total))

        case .fingerprint:
            while try await env.store.fingerprintBuildMissing(limit: 16) > 0 {}
            try await env.store.fingerprintRefreshBuckets()
            let tree = try await env.store.fingerprintTree()
            #expect(tree.leaves == total)
            #expect(tree.buckets.count >= 4, "four months of mail")

        case .shadow:
            let reports = try await ShadowComparison.run(subset: total)
            for name in [String(localized: "PII report"), String(localized: "Keyword sweep"), String(localized: "NLP classification")] {
                let r = try #require(reports.first { $0.tool == name })
                #expect(r.matches, "\(name): \(r.differences)")
            }

        case .identify:
            let all = try await EDiscoveryEngine.identify(scope: .wholeArchive, custodians: [], start: nil, end: nil)
            #expect(all.matching == total && all.total == total)
            let alice = try await EDiscoveryEngine.identify(scope: .wholeArchive, custodians: ["alice"], start: nil, end: nil)
            #expect(alice.matching == GoldenArchive.count { $0.from == GoldenArchive.north })
            // Dates: the first ten emails (3 days apart from the base date).
            let end = Date(timeIntervalSince1970: GoldenArchive.baseEpoch + 9 * 3 * 86_400)
            let early = try await EDiscoveryEngine.identify(scope: .wholeArchive, custodians: [], start: nil, end: end)
            #expect(early.matching == GoldenArchive.specs.filter { ($0.duplicateOf ?? $0.index) <= 9 }.count)

        case .classify:
            let (categories, receipt) = try await EDiscoveryEngine.classify(scope: .wholeArchive)
            #expect(categories.reduce(0) { $0 + $1.count } == total, "every email in exactly one category")
            #expect(receipt.processed == total)

        case .reviewPlan:
            let plan = try await EDiscoveryEngine.planReviewBatches(scope: .wholeArchive)
            #expect(plan.ordered.count == total && Set(plan.ordered).count == total, "every email once")
            #expect(plan.flags.count == GoldenArchive.count(\.privileged))
            let privileged = Set(plan.flags.keys)
            #expect(Set(plan.ordered.prefix(privileged.count)) == privileged, "privilege-flagged first")

        case .verify:
            let (first, _) = try await EDiscoveryEngine.verifyCollection(scope: .wholeArchive)
            #expect(first.newlySealed == total && first.passed == 0 && first.failed == 0, "first run: baselines")
            let (second, _) = try await EDiscoveryEngine.verifyCollection(scope: .wholeArchive)
            #expect(second.passed == total && second.failed == 0 && second.newlySealed == 0, "second run: all verify")

        case .productionFiles:
            let exporter = ArchiveExportService(archive: env.archive)
            let dat = env.root.appendingPathComponent("load.dat"), csv = env.root.appendingPathComponent("prod.csv")
            let d = try await exporter.exportConcordanceDAT(scope: .query(.all, exclusions: []), to: dat)
            #expect(d.recordsWritten == total)
            let datRows = try String(contentsOf: dat, encoding: .utf8).split(separator: "\n").count
            #expect(datRows == total + 1, "header + one row per email")
            let c = try await exporter.exportForensicCSV(scope: .query(.all, exclusions: []), to: csv)
            #expect(c.recordsWritten == total)

        case .custodians:
            #expect(await CustodianEngine.unassignedCount() == total)
            #expect(try await CustodianEngine.assign("Alice", group: nil) == total)
            #expect(await CustodianEngine.unassignedCount() == 0)
            #expect(try await CustodianEngine.ids(for: "Alice").count == total)
            let report = try await CustodianEngine.report()
            #expect(report.contains("Alice"))

        case .batchTag:
            let (added, _) = try await BatchOperationsEngine.apply(.add("golden"), scope: .wholeArchive, loaded: [])
            #expect(added == total)
            var tagged = EmailQuery(); tagged.userTag = "golden"
            #expect(try await env.archive.count(query: tagged) == total)
            var north = EmailQuery(); north.sender = "alice"
            let (removed, _) = try await BatchOperationsEngine.apply(.remove("golden"), scope: ArchiveScope(query: north, total: nil, loaded: nil), loaded: [])
            #expect(removed == GoldenArchive.count { $0.from == GoldenArchive.north })
            #expect(try await env.archive.count(query: tagged) == GoldenArchive.count { $0.from == GoldenArchive.south }, "only the scope lost the tag")

        case .automation:
            let rules = AutomationRulesEngine(rules: [AutomationRule(
                name: "Golden", conditions: [.senderContains("alice")], actions: [.flagForReview])])
            let r = try await AutomationRulesRunEngine.run(scope: .wholeArchive, engine: rules)
            #expect(r.results.count == GoldenArchive.count { $0.from == GoldenArchive.north })
            #expect(r.matched.count == r.results.count)
            #expect(r.receipt.processed == total)

        case .investigationReport:
            let (pdf, receipt) = try await InvestigationReportEngine.build(scope: .wholeArchive, title: "Golden", investigator: "Test")
            #expect(pdf.starts(with: Data("%PDF".utf8)))
            #expect(receipt.processed == total)

        case .personalCleanup:
            let (stats, _) = try await PersonalCleanupEngine.compute()
            #expect(stats.emails == total)
            #expect(stats.attachmentEmails == 0)
            #expect(stats.noSubject == 0)
            #expect(stats.duplicates == GoldenArchive.specs.filter { $0.duplicateOf != nil }.count)

        case .predictive:
            let r = try await PredictiveInsightsEngine.analyze()
            #expect(r.scanned == total)

        case .nearDuplicates:
            let records = GoldenArchive.emails.map(FeatureExtractor.features(for:))
            // The store assigns its own ids; key the features by the stored ids.
            var stored: [UUID] = []
            for try await page in env.archive.streamSummaries(query: .all, batchSize: 100) { stored += page.map(\.id) }
            #expect(stored.count == records.count)
            let full = try await env.archive.fullEmails(ids: stored)
            try await env.store.featuresUpsert(full.map(FeatureExtractor.features(for:)))
            let r = try await NearDuplicatesEngine.run(threshold: 0.9)
            #expect(r.indexed == total && r.total == total)
            // 36, 38 and 39 are the same message: at least one group holding
            // their two verified pairs.
            #expect(r.groups >= 1 && r.verifiedPairs >= 2, "\(r.groups) groups, \(r.verifiedPairs) pairs")

        case .aggregates:
            // §3-F3: batch-merged aggregates equal the in-memory answer.
            let emails = GoldenArchive.emails
            var merged = KeyCounter(), distinct = DistinctCounter(), stat = RunningStat()
            var months = TimeHistogram(.month)
            for chunk in stride(from: 0, to: emails.count, by: 7).map({ Array(emails[$0..<min($0 + 7, emails.count)]) }) {
                var k = KeyCounter(), d = DistinctCounter(), st = RunningStat(), h = TimeHistogram(.month)
                for e in chunk {
                    k.add(e.headers["From"] ?? "")
                    d.add(e.headers["Subject"] ?? "")
                    st.add(Double(e.plainBody.count))
                    if let date = MBOXParser.parseDate(e.headers["Date"]) { h.add(date, calendar: Calendar(identifier: .gregorian)) }
                }
                merged.merge(k); distinct.merge(d); stat.merge(st); months.merge(h)
            }
            let fromCounts = Dictionary(grouping: emails, by: { $0.headers["From"] ?? "" }).mapValues(\.count)
            #expect(merged.counts == fromCounts)
            #expect(merged.ranked().first?.count == fromCounts.values.max())
            #expect(distinct.count == Set(emails.map { $0.headers["Subject"] ?? "" }).count)
            #expect(stat.count == total && stat.sum == Double(emails.reduce(0) { $0 + $1.plainBody.count }))
            #expect(months.total == total)

        case .topics:
            // §3-A5: clusters are built on a stated sample; EVERY email is
            // then assigned to a topic or counted as unassigned.
            let r = try await TopicClustersEngine.run()
            #expect(r.sampled > 0 && r.sampled <= total)
            #expect(r.assigned + r.unassigned == total, "\(r.assigned) + \(r.unassigned) of \(total)")
            #expect(r.receipt.processed == total)

        case .aiTools:
            // §3-I1: the model asks, our code counts — the tool's sentence
            // carries the exact SQL count over the whole archive.
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let north = GoldenArchive.count { $0.from == GoldenArchive.north }
                let answer = try await CountEmailsTool().call(arguments: .init(
                    words: "", sender: "alice", recipient: "", from: "", to: ""))
                #expect(answer.hasPrefix("\(north) of \(total) emails"), "\(answer)")
                let words = try await CountEmailsTool().call(arguments: .init(
                    words: "confidential", sender: "", recipient: "", from: "", to: ""))
                #expect(words.hasPrefix("\(GoldenArchive.count(\.confidentialKeyword)) of \(total)"), "\(words)")
            }
            #endif
        }
    }
}
