@testable import ArchiveCore
//
//  FeatureIndex.swift
//  maxmailin
//
//  §3-F6 (switch: `v3FeatureIndex`) and §3-F5 (switch: `v3Fingerprints`).
//
//  Every email is analysed ONCE and the results are stored per email, so the
//  analysis tools answer from the index for the whole archive instead of
//  re-scanning a loaded subset. The backfill is incremental (only missing or
//  older-version rows), resumable by construction (the work list is "rows
//  without a current feature row"), runs at background priority, and pauses
//  on low battery, Low Power Mode, heat, Safe Mode, or locked protected data.
//
//  The detectors are the existing ones (PII, privilege, IOC, authentication),
//  so the index gives the same answers the tools gave on a loaded subset —
//  the golden tests (§3-F8) compare the two.
//

import Foundation
import CryptoKit
import NaturalLanguage
import os
#if os(iOS)
import UIKit
#endif

private let featureLog = Logger(subsystem: "com.ecosanskriti.maxmailin", category: "FeatureIndex")

// MARK: - Extraction (pure)

enum FeatureExtractor {
    /// Bump when any detector changes; rows below are recomputed.
    /// 2: named entities (§3-F6).
    static let version = 2

    /// PII bit per type, stable across versions (stored in the database).
    static func piiBit(_ type: EmailNLPEngine.PIIType) -> Int {
        switch type {
        case .emailAddress: return 1 << 0
        case .phoneNumber: return 1 << 1
        case .ssnPattern: return 1 << 2
        case .creditCard: return 1 << 3
        case .ipAddress: return 1 << 4
        case .passportNumber: return 1 << 5
        case .dateOfBirth: return 1 << 6
        case .driversLicense: return 1 << 7
        case .iban: return 1 << 8
        }
    }

    static func piiTypes(in flags: Int) -> [EmailNLPEngine.PIIType] {
        EmailNLPEngine.PIIType.allCases.filter { flags & piiBit($0) != 0 }
    }

    /// Privilege levels stored per email.
    enum PrivilegeLevel: Int { case none = 0, needsReview = 1, privileged = 2 }

    static func features(for email: MBOXParser.RawEmail) -> SQLiteEmailStore.FeatureRecord {
        var r = SQLiteEmailStore.FeatureRecord(emailID: email.id, version: version)

        for finding in EmailNLPEngine.detectPII(in: [email]) { r.piiFlags |= piiBit(finding.type) }

        if let p = LegalAnalysisFeatures.classifyPrivilege(emails: [email]).first {
            switch p.classification {
            case .notPrivileged: r.privilege = PrivilegeLevel.none.rawValue
            case .needsReview: r.privilege = PrivilegeLevel.needsReview.rawValue
            default: r.privilege = PrivilegeLevel.privileged.rawValue
            }
        }

        let auth = EmailNLPEngine.parseAuthenticationResults(email.headers)
        r.spf = auth.spfResult == .none ? nil : auth.spfResult.rawValue
        r.dkim = auth.dkimResult == .none ? nil : auth.dkimResult.rawValue
        r.dmarc = auth.dmarcResult == .none ? nil : auth.dmarcResult.rawValue
        r.threatScore = Double(ThreatScoring.score(email))

        // Indicators: same extractor as the IOC tool; one row per distinct value.
        var seen = Set<String>()
        for ioc in IOCExtractor.extract(from: [email]) {
            let key = ioc.type.rawValue + "\u{1F}" + ioc.value
            if seen.insert(key).inserted { r.iocs.append((kind: ioc.type.rawValue, value: ioc.value)) }
        }

        let text = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
        r.language = language(of: text)
        r.mih = messageIdentificationHash(email, bodyText: text)
        r.minhashBands = MinHash.bands(of: text)
        r.entities = entities(in: text)
        return r
    }

    /// People, organisations and places named in the text (NaturalLanguage
    /// name tagger, on device), each value once per email.
    static func entities(in text: String) -> [(kind: String, value: String)] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var seen = Set<String>()
        var out: [(kind: String, value: String)] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let kind: String
            switch tag {
            case .personalName?: kind = "person"
            case .organizationName?: kind = "organization"
            case .placeName?: kind = "place"
            default: return true
            }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, seen.insert(kind + "\u{1F}" + value).inserted { out.append((kind: kind, value: value)) }
            return true
        }
        return out
    }

    static func language(of text: String) -> String? {
        let sample = String(text.prefix(2_000))
        guard sample.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    /// EDRM Message Identification Hash, v1 field set: SHA-256 over the
    /// normalised From, To, Cc, Bcc, Date sent, Subject and body text, so the
    /// same message from different sources (PST vs MBOX vs EML) gets the same
    /// value. Normalisation: lower-cased addresses sorted, whitespace
    /// collapsed, date in UTC ISO-8601 seconds, subject trimmed.
    static func messageIdentificationHash(_ email: MBOXParser.RawEmail, bodyText: String) -> String {
        func addresses(_ header: String?) -> String {
            guard let header, !header.isEmpty else { return "" }
            let pattern = #"[A-Za-z0-9._%+\-']+@[A-Za-z0-9.\-]+"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return header.lowercased() }
            let ns = header as NSString
            return re.matches(in: header, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range).lowercased() }
                .sorted().joined(separator: ";")
        }
        func collapse(_ s: String) -> String {
            s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let date = MBOXParser.parseDate(email.headers["Date"]).map {
            let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: $0)
        } ?? ""
        let fields = [
            addresses(email.headers["From"]),
            addresses(email.headers["To"]),
            addresses(email.headers["Cc"] ?? email.headers["CC"]),
            addresses(email.headers["Bcc"] ?? email.headers["BCC"]),
            date,
            collapse(email.headers["Subject"] ?? ""),
            collapse(bodyText),
        ]
        let joined = fields.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Same rule as IT Admin's threat score (ITAdminAnalysisView.computeThreatScore),
/// as a pure function so it can be stored per email. Kept identical; the
/// golden test (§3-F8) compares the two.
enum ThreatScoring {
    static func score(_ email: MBOXParser.RawEmail) -> Int {
        var score = 0
        let header = (email.headers["Authentication-Results"] ?? email.headers["authentication-results"] ?? "").lowercased()
        let spf = header.contains("spf=pass") ? "pass" : (header.contains("spf=fail") || header.contains("spf=softfail")) ? "fail" : ""
        let dkim = header.contains("dkim=pass") ? "pass" : header.contains("dkim=fail") ? "fail" : ""
        let dmarc = header.contains("dmarc=pass") ? "pass" : header.contains("dmarc=fail") ? "fail" : ""
        if spf == "fail" { score += 3 } else if spf.isEmpty { score += 1 }
        if dkim == "fail" { score += 3 } else if dkim.isEmpty { score += 1 }
        if dmarc == "fail" { score += 2 }

        let fromDomain = domain(email.headers["From"] ?? "")
        let returnDomain = domain(email.headers["Return-Path"] ?? "")
        let replyDomain = domain(email.headers["Reply-To"] ?? "")
        if !returnDomain.isEmpty && returnDomain != fromDomain { score += 2 }
        if !replyDomain.isEmpty && replyDomain != fromDomain { score += 2 }

        let hasTLS = email.headers.contains { k, v in
            k.lowercased().hasPrefix("received") && (v.lowercased().contains("tls") || v.lowercased().contains("esmtps"))
        }
        if !hasTLS { score += 1 }
        let riskyTLDs = [".xyz", ".top", ".click", ".buzz", ".tk", ".ml", ".ga", ".cf"]
        if riskyTLDs.contains(where: { fromDomain.hasSuffix($0) }) { score += 2 }
        return min(score, 10)
    }

    private static func domain(_ address: String) -> String {
        let cleaned = address.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        guard let at = cleaned.lastIndex(of: "@") else { return "" }
        return String(cleaned[cleaned.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// MinHash signatures over word 5-shingles, folded into LSH bands. With 16
/// bands × 4 rows, pairs with Jaccard ≥ ~0.7 collide in some band with high
/// probability; every candidate is then verified with exact Jaccard (A4), so
/// the bands only choose what to compare and never decide a result.
enum MinHash {
    static let shingleSize = 5
    static let bandsCount = 16
    static let rowsPerBand = 4
    static var hashes: Int { bandsCount * rowsPerBand }

    static func shingles(of text: String) -> Set<UInt64> {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= shingleSize else {
            return words.isEmpty ? [] : [DistinctCounter.fnv1a(words.joined(separator: " "))]
        }
        var out = Set<UInt64>()
        for i in 0...(words.count - shingleSize) {
            out.insert(DistinctCounter.fnv1a(words[i..<(i + shingleSize)].joined(separator: " ")))
        }
        return out
    }

    /// Seeded mix (splitmix64) — deterministic across launches and devices.
    private static func mix(_ x: UInt64, _ seed: UInt64) -> UInt64 {
        var z = x &+ seed &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func signature(_ shingles: Set<UInt64>) -> [UInt64] {
        guard !shingles.isEmpty else { return [] }
        var sig = [UInt64](repeating: .max, count: hashes)
        for s in shingles {
            for i in 0..<hashes {
                let h = mix(s, UInt64(i + 1))
                if h < sig[i] { sig[i] = h }
            }
        }
        return sig
    }

    /// One Int64 per band (empty text → no bands, never a false match).
    static func bands(of text: String) -> [Int64] {
        let sig = signature(shingles(of: text))
        guard !sig.isEmpty else { return [] }
        return (0..<bandsCount).map { b in
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for r in 0..<rowsPerBand { h = mix(h ^ sig[b * rowsPerBand + r], UInt64(b)) }
            return Int64(bitPattern: h)
        }
    }

    static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let inter = a.intersection(b).count
        return Double(inter) / Double(a.count + b.count - inter)
    }
}

// MARK: - Background backfill

/// Whether background index work should pause right now.
@MainActor
enum BackgroundBudget {
    static var shouldPause: Bool {
        if !SafeMode.shared.allowsBackgroundWork { return true }
        if !BackgroundExecution.isProtectedDataAvailable { return true }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        if info.thermalState == .serious || info.thermalState == .critical { return true }
        #if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.2 { return true }
        #endif
        return false
    }
}

@MainActor
@Observable
final class FeatureIndexJob {
    static let shared = FeatureIndexJob()

    private(set) var isRunning = false
    private(set) var lastCoverage: (indexed: Int, total: Int) = (0, 0)
    private var task: Task<Void, Never>?

    /// Starts the backfill if the engine is on and it is not already running.
    func kickIfNeeded(registry: ModuleRegistry) {
        guard registry.isOn(.v3FeatureIndex), task == nil else { return }
        let jobs = registry.jobs
        task = Task(priority: .background) { [weak self] in
            await self?.run()
            self?.task = nil
            jobs.finish(id: "v3.featureIndex")
        }
        jobs.register(id: "v3.featureIndex", module: .archive,
                      label: String(localized: "Build the analysis index"),
                      cancel: { [weak self] in self?.stop() })
    }

    func stop() { task?.cancel() }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        let store = ScopeJobEnvironment.store
        let data = ScopeJobEnvironment.archive
        while !Task.isCancelled {
            if BackgroundBudget.shouldPause {
                try? await Task.sleep(for: .seconds(60))
                continue
            }
            let ids: [UUID]
            do { ids = try await store.featureStaleIDs(version: FeatureExtractor.version, limit: 100) } catch {
                featureLog.error("feature work list failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if ids.isEmpty { break }
            let token = EngineGuard.begin(.v3FeatureIndex)
            let emails = (try? await data.fullEmails(ids: ids)) ?? []
            // Extraction is pure CPU: off the main actor.
            let records = await Task.detached(priority: .background) {
                emails.map { FeatureExtractor.features(for: $0) }
            }.value
            // Emails that could not be read get an empty current-version row,
            // so the work list always shrinks (they are counted, not retried
            // forever); a later version bump retries them.
            let readable = Set(records.map(\.emailID))
            let unreadable = ids.filter { !readable.contains($0) }
                .map { SQLiteEmailStore.FeatureRecord(emailID: $0, version: FeatureExtractor.version) }
            do { try await store.featuresUpsert(records + unreadable) } catch {
                EngineGuard.end(token)
                featureLog.error("feature write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            EngineGuard.end(token)
            lastCoverage = (try? await store.featureCoverage(version: FeatureExtractor.version)) ?? lastCoverage
            await Task.yield()
        }
        lastCoverage = (try? await store.featureCoverage(version: FeatureExtractor.version)) ?? lastCoverage
    }
}

// MARK: - Fingerprint tree (F5)

@MainActor
@Observable
final class FingerprintJob {
    static let shared = FingerprintJob()

    private(set) var isRunning = false
    private(set) var root: String?
    private var task: Task<Void, Never>?

    /// Builds leaves for new emails and refreshes bucket roots (incremental).
    func kickIfNeeded(registry: ModuleRegistry) {
        guard registry.isOn(.v3Fingerprints), task == nil else { return }
        let jobs = registry.jobs
        task = Task(priority: .background) { [weak self] in
            await self?.build()
            self?.task = nil
            jobs.finish(id: "v3.fingerprints")
        }
        jobs.register(id: "v3.fingerprints", module: .archive,
                      label: String(localized: "Build the archive fingerprint tree"),
                      cancel: { [weak self] in self?.task?.cancel() })
    }

    private func build() async {
        isRunning = true
        defer { isRunning = false }
        let store = ScopeJobEnvironment.store
        let token = EngineGuard.begin(.v3Fingerprints)
        defer { EngineGuard.end(token) }
        do {
            while !Task.isCancelled {
                if BackgroundBudget.shouldPause { try? await Task.sleep(for: .seconds(60)); continue }
                let n = try await store.fingerprintBuildMissing(limit: 1_000)
                if n == 0 { break }
                await Task.yield()
            }
            try await store.fingerprintRefreshBuckets()
            root = try await store.fingerprintTree().root
        } catch {
            featureLog.error("fingerprint build failed: \(error.localizedDescription, privacy: .public)")
            EngineGuard.recordFallback(.v3Fingerprints, error: error)
        }
    }

    struct VerifyState: Codable, Sendable {
        var changed: [UUID] = []
        var unreadable: [UUID] = []
    }

    /// Verifies every email in `query` against its leaf (F5 pinpoint) as a
    /// resumable scope job; returns the changed and unreadable emails, the
    /// archive root, and the receipt.
    func verify(query: EmailQuery = .all) async throws -> (state: VerifyState, root: String, receipt: ScopeJobReceipt) {
        let store = ScopeJobEnvironment.store
        // Leaves first, so a new email is a new baseline, not a failure.
        while try await store.fingerprintBuildMissing(limit: 1_000) > 0 {}
        try await store.fingerprintRefreshBuckets()
        let result = try await ScopeJob.runIDs(
            key: "fingerprint-verify", title: String(localized: "Verify archive fingerprints"),
            capability: .v3Fingerprints, query: query, batchSize: 500, initialState: VerifyState()
        ) { state, page in
            for m in try await store.fingerprintVerify(ids: page.map(\.id)) {
                switch m {
                case .changed(let id): state.changed.append(id)
                case .unreadable(let id): state.unreadable.append(id)
                }
            }
        }
        let tree = try await store.fingerprintTree()
        root = tree.root
        return (result.state, tree.root, result.receipt)
    }
}
