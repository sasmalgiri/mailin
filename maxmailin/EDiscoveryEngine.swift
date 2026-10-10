@testable import ArchiveCore
//
//  EDiscoveryEngine.swift
//  maxmailin
//
//  §3-L1…L5 (switch: `v3EDiscovery`). The E-Discovery actions over the
//  WHOLE scope the tool was opened on, through the scope engine — the same
//  rules as the previous engine (identical filters, seals, classification,
//  privilege detection and file formats), applied batch by batch instead of
//  to the newest 2,000 emails. Each returns the job receipt (§3-E1).
//

import Foundation
import CryptoKit

@MainActor
enum EDiscoveryEngine {

    // MARK: L1 — Identification search

    struct IdentificationState: Codable, Sendable {
        var matching = 0
        var domains = KeyCounter()
    }

    /// Same filter as the previous engine: custodian (From/To contains, any
    /// of), date range (emails with no parseable date pass), domain counts.
    static func identify(scope: ArchiveScope, custodians: [String], start: Date?, end: Date?)
        async throws -> (matching: Int, total: Int, topDomains: [(String, Int)], receipt: ScopeJobReceipt) {
        let lowered = custodians.map { $0.lowercased() }
        let result = try await ScopeJob.run(
            key: "ediscovery.identify", title: String(localized: "E-Discovery search"),
            capability: .v3EDiscovery, query: scope.query, initialState: IdentificationState()
        ) { state, batch in
            for email in batch {
                if !lowered.isEmpty {
                    let from = (email.headers["From"] ?? "").lowercased()
                    let to = (email.headers["To"] ?? "").lowercased()
                    guard lowered.contains(where: { from.contains($0) || to.contains($0) }) else { continue }
                }
                if let date = MBOXParser.parseDate(email.headers["Date"]) {
                    if let start, date < start { continue }
                    if let end, date > end { continue }
                }
                state.matching += 1
                for domain in email.domains { state.domains.add(domain) }
            }
        }
        let top = result.state.domains.ranked().map { ($0.key, $0.count) }
        return (result.state.matching, result.receipt.totalInScope, top, result.receipt)
    }

    // MARK: L2 — Legal hold

    struct HoldState: Codable, Sendable { var held = 0; var sealed = 0 }

    /// Places holds with set-once seals on every email in scope and stores
    /// their forensic hashes. With the legal-data engine active, holds and
    /// seals go to the database per batch and are mirrored into the files
    /// once at the end; otherwise each batch is applied in one assignment.
    static func applyHold(scope: ArchiveScope) async throws -> (held: Int, sealed: Int, receipt: ScopeJobReceipt) {
        let custodian = CustodianManager.shared
        let forensic = ForensicManager.shared
        let store = ScopeJobEnvironment.store
        let viaDatabase = LegalStateMirror.isEnabled && LegalStateMirror.shared.isActive
        let result = try await ScopeJob.run(
            key: "ediscovery.hold", title: String(localized: "Apply legal hold"),
            capability: .v3EDiscovery, query: scope.query, batchSize: viaDatabase ? 500 : 2_000,
            initialState: HoldState()
        ) { state, batch in
            await forensic.prefetchForensicWindow(ids: batch.map(\.id))
            forensic.storeEmailHashes(batch)
            if viaDatabase {
                let existing = try await store.seals(for: batch.map(\.id))
                var seals: [UUID: String] = [:]
                for email in batch where existing[email.id] == nil { seals[email.id] = CustodianManager.sealHash(email) }
                state.held += try await store.legalHoldsAdd(batch.map(\.id))
                state.sealed += try await store.sealsSetOnce(seals)
            } else {
                let before = custodian.evidenceSeals.count
                let heldBefore = custodian.legalHolds.count
                custodian.placeLegalHoldBatched(batch)
                state.held += custodian.legalHolds.count - heldBefore
                state.sealed += custodian.evidenceSeals.count - before
            }
        }
        if viaDatabase {
            custodian.absorbFromDatabase(holds: try await store.legalHoldIDs(), seals: try await store.allSeals(), custodians: nil)
        }
        forensic.logAction("Legal Hold Placed",
                           detail: "\(result.state.held) emails newly held, \(result.state.sealed) sealed — scope: \(result.receipt.scope); \(result.receipt.coverageLine)")
        return (result.state.held, result.state.sealed, result.receipt)
    }

    struct ReleaseState: Codable, Sendable { var released = 0 }

    static func releaseHold(scope: ArchiveScope) async throws -> (released: Int, receipt: ScopeJobReceipt) {
        let custodian = CustodianManager.shared
        let result = try await ScopeJob.runIDs(
            key: "ediscovery.release", title: String(localized: "Release legal hold"),
            capability: .v3EDiscovery, query: scope.query, batchSize: 5_000, initialState: ReleaseState()
        ) { state, page in
            state.released += custodian.releaseLegalHoldBatched(page.map(\.id))
        }
        ScopeJobEnvironment.logAction("Legal Hold Removed",
                                         detail: "\(result.state.released) emails released — scope: \(result.receipt.scope)")
        return (result.state.released, result.receipt)
    }

    /// Exact number of held emails in scope (no loading).
    static func heldCount(scope: ArchiveScope) async -> Int {
        if LegalStateMirror.isEnabled, LegalStateMirror.shared.isActive {
            var n = 0
            do {
                for try await page in ScopeJobEnvironment.archive.streamSummaries(query: scope.query, batchSize: 5_000) {
                    n += try await ScopeJobEnvironment.store.legalHeldAmong(page.map(\.id)).count
                }
            } catch { return n }
            return n
        }
        let holds = CustodianManager.shared.legalHolds
        guard !holds.isEmpty else { return 0 }
        var n = 0
        do {
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: scope.query, batchSize: 5_000) {
                n += page.reduce(0) { $0 + (holds.contains($1.id) ? 1 : 0) }
            }
        } catch { return n }
        return n
    }

    // MARK: L3 — Verify & seal collection

    struct VerifyState: Codable, Sendable {
        var passed = 0, failed = 0, newlySealed = 0
        var failedIDs: [UUID] = []
    }

    /// Verifies every email in scope against its ORIGINAL stored seal; emails
    /// with no seal get their first baseline (same rule as before).
    static func verifyCollection(scope: ArchiveScope, capability: Capability = .v3EDiscovery) async throws -> (VerifyState, ScopeJobReceipt) {
        let forensic = ForensicManager.shared
        let result = try await ScopeJob.run(
            key: "verify.\(capability.rawValue)", title: String(localized: "Verify & seal collection"),
            capability: capability, query: scope.query, initialState: VerifyState()
        ) { state, batch in
            await forensic.prefetchForensicWindow(ids: batch.map(\.id))
            var unsealed: [MBOXParser.RawEmail] = []
            for email in batch {
                if forensic.perEmailHashes[email.id] == nil { unsealed.append(email); continue }
                if forensic.verifyEmailIntegrity(email).passed { state.passed += 1 }
                else { state.failed += 1; state.failedIDs.append(email.id) }
            }
            if !unsealed.isEmpty {
                forensic.storeEmailHashes(unsealed)
                state.newlySealed += unsealed.count
            }
        }
        forensic.logAction("E-Discovery: Collection Verified",
                           detail: "\(result.state.passed) verified, \(result.state.failed) failed, \(result.state.newlySealed) newly sealed — \(result.receipt.coverageLine)")
        return (result.state, result.receipt)
    }

    // MARK: L4 — NLP analysis and review batches

    struct CategoryState: Codable, Sendable { var counts = KeyCounter() }

    static func classify(scope: ArchiveScope) async throws -> ([(category: EmailNLPEngine.EmailCategory, count: Int)], ScopeJobReceipt) {
        let result = try await ScopeJob.run(
            key: "ediscovery.nlp", title: String(localized: "NLP analysis"),
            capability: .v3EDiscovery, query: scope.query, initialState: CategoryState()
        ) { state, batch in
            let counts = await Task.detached(priority: .userInitiated) { EmailNLPEngine.classifyAll(batch) }.value
            for (category, n) in counts { state.counts.add(category.rawValue, by: n) }
        }
        let sorted = result.state.counts.ranked().compactMap { entry in
            EmailNLPEngine.EmailCategory(rawValue: entry.key).map { (category: $0, count: entry.count) }
        }
        return (sorted, result.receipt)
    }

    struct BatchPlan: Codable, Sendable { var seen = 0 }

    /// Every email in scope, privilege-flagged first, then by category size —
    /// the previous ordering — as real review batches. Privilege flags are
    /// collected across the whole scope and published once.
    static func createReviewBatches(scope: ArchiveScope) async throws
        -> (batches: Int, privileged: Int, categories: [(category: String, count: Int)], receipt: ScopeJobReceipt) {
        var categoryOf: [UUID: String] = [:]
        var flags: [UUID: [String]] = [:]
        var order: [UUID] = []
        var counts = KeyCounter()
        let result = try await ScopeJob.run(
            key: "ediscovery.batches", title: String(localized: "Create review batches"),
            capability: .v3EDiscovery, query: scope.query, resumable: false, initialState: BatchPlan()
        ) { state, batch in
            let classified = await Task.detached(priority: .userInitiated) {
                batch.map { ($0.id, EmailNLPEngine.classify($0).rawValue) }
            }.value
            for (id, category) in classified {
                categoryOf[id] = category
                counts.add(category)
                order.append(id)
            }
            for email in batch {
                let privilege = ForensicManager.detectPrivilege(for: email)
                if privilege.isLikelyPrivileged { flags[email.id] = privilege.indicators }
            }
            state.seen += batch.count
        }
        let forensic = ForensicManager.shared
        forensic.privilegeFlags = flags
        let rank = Dictionary(uniqueKeysWithValues: counts.ranked().enumerated().map { ($1.key, $0) })
        let ordered = order.sorted { a, b in
            let pa = flags[a] != nil, pb = flags[b] != nil
            if pa != pb { return pa }
            return (categoryOf[a].flatMap { rank[$0] } ?? 0) < (categoryOf[b].flatMap { rank[$0] } ?? 0)
        }
        let batchManager = ReviewBatchManager.shared
        batchManager.createBatches(from: ordered, batchSize: 50, namePrefix: "Review")
        forensic.logAction("E-Discovery: Review Batches Created",
                           detail: "\(batchManager.batches.count) batches of up to 50 from \(ordered.count) emails (privilege-flagged first, then by category). \(flags.count) privilege-flagged. \(result.receipt.coverageLine)")
        return (batchManager.batches.count, flags.count, counts.ranked().map { (category: $0.key, count: $0.count) }, result.receipt)
    }

    // MARK: L5 — Production files (streamed, verified)

    static func exportLoadFile(scope: ArchiveScope) async -> (ExportOutcome, ArchiveExportResult?) {
        await PlatformExport.saveStreamed(suggestedName: "production_loadfile.dat") { url in
            try await ArchiveExportService.shared.exportConcordanceDAT(scope: .query(scope.query, exclusions: []), to: url)
        }
    }

    /// §3-Q3: the same Concordance load file with an EDRM Message
    /// Identification Hash column (MIH — same message from any source gets
    /// the same value, so the receiving party can de-duplicate across
    /// productions). Rows, order and Bates numbers are those of the
    /// standard file; only the extra trailing field differs.
    static func exportLoadFileWithMIH(scope: ArchiveScope, batesPrefix: String = "MAIL") async -> (ExportOutcome, ArchiveExportResult?) {
        let forensic = ForensicManager.shared
        let sep = "\u{14}", quote = "\u{FE}"
        return await PlatformExport.saveStreamed(suggestedName: "production_loadfile.dat") { url in
            try await StreamedTextFile.write(to: url) { emit in
                var header = ForensicManager.concordanceDATHeader
                if header.hasSuffix("\n") { header.removeLast() }
                try emit(header + "\(sep)\(quote)MIH\(quote)\n")
                var index = 0
                for try await batch in ScopeJobEnvironment.archive.streamFullEmails(query: scope.query, batchSize: 200) {
                    var chunk = ""
                    for email in batch {
                        index += 1
                        var row = forensic.concordanceDATRow(email, bates: ForensicManager.batesNumber(prefix: batesPrefix, index: index))
                        if row.hasSuffix("\n") { row.removeLast() }
                        let body = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
                        row += "\(sep)\(quote)\(FeatureExtractor.messageIdentificationHash(email, bodyText: body))\(quote)\n"
                        chunk += row
                    }
                    try emit(chunk)
                }
            }
        }
    }

    static func exportProductionCSV(scope: ArchiveScope) async -> (ExportOutcome, ArchiveExportResult?) {
        await PlatformExport.saveStreamed(suggestedName: "production_export.csv") { url in
            try await ArchiveExportService.shared.exportForensicCSV(scope: .query(scope.query, exclusions: []), to: url)
        }
    }

    /// Privilege log over every email in scope tagged Privileged — found by
    /// the database tag index, not by scanning a loaded list. Same layout.
    static func exportPrivilegeLog(scope: ArchiveScope) async -> (ExportOutcome, Int) {
        var query = scope.query
        query.evidenceTag = ForensicManager.EvidenceTag.privileged.rawValue
        query.sort = .dateAsc
        let total = (try? await ScopeJobEnvironment.archive.count(query: query)) ?? 0
        guard total > 0 else { return (.failed(String(localized: "no emails in scope are tagged Privileged")), 0) }
        let forensic = ForensicManager.shared
        let (outcome, _) = await PlatformExport.saveStreamed(suggestedName: "privilege_log.csv") { url in
            try await StreamedTextFile.write(to: url) { emit in
                let display = DateFormatter()
                display.dateFormat = "yyyy-MM-dd HH:mm:ss"
                var head = "PRIVILEGE LOG\n" + String(repeating: "=", count: 76) + "\n"
                head += "Case Number: \(forensic.caseNumber.isEmpty ? "N/A" : forensic.caseNumber)\n"
                head += "Prepared by: \(forensic.examinerName.isEmpty ? "N/A" : forensic.examinerName)\n"
                head += "Date: \(display.string(from: Date()))\n"
                head += "Total Privileged Documents: \(total)\n\n"
                // Columns padded in Swift: `String(format:)` with `%s` and a
                // Swift String reads a C pointer (the previous log's bug).
                head += pad("No.", 8) + " " + pad("Date", 12) + " " + pad("From", 30) + " " + pad("To", 30) + " Subject\n"
                head += String(repeating: "-", count: 120) + "\n"
                try emit(head)
                var i = 0
                for try await batch in ScopeJobEnvironment.archive.streamFullEmails(query: query, batchSize: 200) {
                    var chunk = ""
                    for email in batch {
                        i += 1
                        let date = email.headers["Date"] ?? "N/A"
                        let from = String((email.headers["From"] ?? "N/A").prefix(28))
                        let to = String((email.headers["To"] ?? "N/A").prefix(28))
                        let subject = String((email.headers["Subject"] ?? "N/A").prefix(50))
                        chunk += pad(String(i), 8) + " " + pad(date, 12) + " " + pad(from, 30) + " " + pad(to, 30) + " " + subject + "\n"
                        if let annotation = forensic.annotations[email.id] {
                            chunk += "         Basis: \(annotation.text)\n"
                        }
                    }
                    try emit(chunk)
                }
                try emit("\n" + String(repeating: "=", count: 76) + "\nEND OF PRIVILEGE LOG\n\n")
            }
        }
        return (outcome, total)
    }

    /// Left-aligned, space-padded column (never truncates — same as `%-Ns`).
    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}

/// Writes a text file incrementally and returns an export result with its
/// SHA-256 computed while writing (for read-back verification).
enum StreamedTextFile {
    @MainActor
    static func write(to url: URL, _ body: (_ emit: (String) throws -> Void) async throws -> Void) async throws -> ArchiveExportResult {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        var hasher = SHA256Stream()
        var bytes = 0
        try await body { text in
            let data = Data(text.utf8)
            try handle.write(contentsOf: data)
            hasher.update(data)
            bytes += data.count
        }
        try handle.synchronize()
        return ArchiveExportResult(recordsWritten: 0, bytesWritten: bytes, completed: true, cancelled: false,
                                   sha256Hex: hasher.finalizeHex())
    }
}

struct SHA256Stream {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalizeHex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
