//
//  ArchiveDerivedAnalysis.swift
//  maxmailin
//
//  Part I (v2-core-cutover): the AI/NLP filter attributes (sentiment,
//  classification, phishing flag, priority score) are computed ONCE per email
//  by a bounded background job, persisted via ArchiveDerivedStateStore, and
//  read back cheaply — never recomputed archive-wide when a sheet opens.
//
//  Incremental by construction: the job's work list is
//  `derivedStaleIDs(below: revision, minAnalysisVersion:)`, so already-computed
//  emails are skipped unless the corpus revision moves or `analysisVersion`
//  (the feature/model version constant below) is bumped. Bump the constant
//  whenever the tagging/scoring logic changes and the job re-derives.
//

import Foundation

enum DerivedAIAnalysis {

    /// Feature/model version for the Part I producers. Bump when the
    /// sentiment/classification/phishing/priority logic changes — persisted
    /// records at a lower version become stale and are recomputed.
    static let analysisVersion = 1

    /// Compute the per-email derived filter attributes for ONE bounded batch,
    /// merging into `existing` records so fields owned by other producers
    /// (topic, thread id, predictive score) are preserved.
    ///
    /// Mirrors the legacy `computeAIFilterData` logic exactly: Apple
    /// FoundationModels tagging/phishing when available, with the on-device
    /// NLP engine as the fallback for missed emails / older OSes.
    static func computeRecords(
        for emails: [MBOXParser.RawEmail],
        existing: [EmailID: DerivedRecord],
        senderCounts: [String: Int],
        revision: Int
    ) async -> [DerivedRecord] {
        guard !emails.isEmpty else { return [] }

        var sentMap: [UUID: Double] = [:]
        var classMap: [UUID: EmailNLPEngine.EmailCategory] = [:]
        var phishIDs = Set<UUID>()

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), FoundationModelEngine.isAvailable {
            let tagResults = await FoundationModelEngine.tagEmails(emails) { _, _ in }
            for (id, result) in tagResults {
                switch result.sentiment {
                case "positive": sentMap[id] = 0.8
                case "negative": sentMap[id] = -0.8
                default: sentMap[id] = 0.0
                }
                switch result.category {
                case "personal": classMap[id] = .personal
                case "transactional": classMap[id] = .transactional
                case "newsletter": classMap[id] = .newsletter
                case "promotional": classMap[id] = .promotional
                case "automated": classMap[id] = .automated
                default: break
                }
            }
            phishIDs = await FoundationModelEngine.classifyPhishing(emails) { _, _ in }
        }
        #endif

        // NLP engine for whatever the model didn't cover (or everything, when
        // FoundationModels is unavailable). CPU-bound — run off the caller's
        // actor so a MainActor job runner never blocks the UI.
        let needSentiment = emails.filter { sentMap[$0.id] == nil }
        let needClass = emails.filter { classMap[$0.id] == nil }
        let ranModelPhishing = !phishIDs.isEmpty || { () -> Bool in
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) { return FoundationModelEngine.isAvailable }
            #endif
            return false
        }()
        let fallback = await Task.detached(priority: .utility) { () -> (sent: [UUID: Double], cls: [UUID: EmailNLPEngine.EmailCategory], phish: Set<UUID>, prio: [UUID: Int]) in
            var sent: [UUID: Double] = [:]
            for r in EmailNLPEngine.analyzeSentiment(of: needSentiment) { sent[r.email.id] = r.score }
            var cls: [UUID: EmailNLPEngine.EmailCategory] = [:]
            for email in needClass { cls[email.id] = EmailNLPEngine.classify(email) }
            var phish = Set<UUID>()
            if !ranModelPhishing {
                phish = Set(EmailNLPEngine.detectPhishing(in: emails)
                    .filter { $0.riskLevel == .high }
                    .map(\.email.id))
            }
            var prio: [UUID: Int] = [:]
            for email in emails {
                prio[email.id] = EmailNLPEngine.scorePriority(email, replyCountPerSender: senderCounts).score
            }
            return (sent, cls, phish, prio)
        }.value

        for (id, s) in fallback.sent { sentMap[id] = s }
        for (id, c) in fallback.cls { classMap[id] = c }
        phishIDs.formUnion(fallback.phish)

        let now = Int(Date().timeIntervalSince1970)
        return emails.map { email in
            var record = existing[email.id] ?? DerivedRecord(emailID: email.id)
            record.corpusRevision = revision
            record.analysisVersion = analysisVersion
            record.sentiment = sentMap[email.id].map { String(format: "%.4f", $0) }
            record.classification = classMap[email.id]?.rawValue
            record.phishing = phishIDs.contains(email.id)
            record.priority = fallback.prio[email.id]
            record.updatedAt = now
            return record
        }
    }

    /// Parse a persisted sentiment value back to the numeric score the filter
    /// UI thresholds (±0.4) operate on.
    static func sentimentScore(from record: DerivedRecord) -> Double? {
        record.sentiment.flatMap(Double.init)
    }

    static func classification(from record: DerivedRecord) -> EmailNLPEngine.EmailCategory? {
        record.classification.flatMap(EmailNLPEngine.EmailCategory.init(rawValue:))
    }
}

// MARK: - Archive-wide background job

/// Owns the incremental archive-wide Part I job: streams stale emails in
/// bounded batches via `ArchiveBackgroundJobRunner`, computes compact derived
/// records, persists, releases the batch. A no-op when everything is already
/// computed at the current revision/version, so kicking it is cheap.
@MainActor
final class DerivedAIAnalysisJob: ObservableObject {
    static let shared = DerivedAIAnalysisJob()

    let runner: ArchiveBackgroundJobRunner
    private let store: SQLiteEmailStore
    private var jobTask: Task<Void, Never>?

    init(store: SQLiteEmailStore = .shared) {
        self.store = store
        self.runner = ArchiveBackgroundJobRunner(store: store)
    }

    /// Start (or restart after completion) the incremental job. Safe to call on
    /// every import/list load — a running job is left alone, and a finished job
    /// re-runs only if new/stale work exists (the runner's work list is empty
    /// otherwise, so it completes immediately).
    func kickIfNeeded() {
        guard UserDefaults.standard.object(forKey: "enableAIFeatures") as? Bool ?? true else { return }
        guard jobTask == nil else { return }   // one in-flight job at a time
        jobTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runOnce()
            self.jobTask = nil
        }
    }

    func runOnce() async {
        // Detect imports that didn't bump the revision explicitly (bulk import
        // writes straight to the store) before computing the work list.
        _ = try? await store.reconcileCorpusRevisionWithCount()
        // Bounded DB-side sender frequency map, mirroring the legacy
        // replyCountPerSender (count of emails per raw From header). Only
        // senders with count >= 3 affect the score; the top-20k rollup covers
        // them for any realistic archive (documented bound).
        let rollups = (try? await store.senderRollups(limit: 20_000)) ?? []
        var senderCounts: [String: Int] = [:]
        for rollup in rollups {
            let key = rollup.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { senderCounts[key] = rollup.count }
        }
        let counts = senderCounts
        // Incremental: already-computed EmailIDs are SKIPPED unless the
        // analysis version bumps (per-email attributes don't change when other
        // emails are imported), so re-kicks after an import only process the
        // new emails.
        await runner.run(batchSize: 300,
                         minAnalysisVersion: DerivedAIAnalysis.analysisVersion,
                         staleBelowRevision: false) { emails, existing, rev in
            await DerivedAIAnalysis.computeRecords(
                for: emails, existing: existing, senderCounts: counts, revision: rev
            )
        }
    }

    func cancel() {
        jobTask?.cancel()
        jobTask = nil
        runner.cancel()
    }
}
