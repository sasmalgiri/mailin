@testable import ArchiveCore
//
//  FidelityBackfillJob.swift
//  maxmailin
//
//  Repairs archives imported by pre-full-fidelity builds. Their SQLite rows
//  carry message_type = '' and no attachments/tags/domains side-table rows,
//  because those fields were only persisted from schema v2 onward — which is
//  why the folder tree (Inbox/Sent/Labels/Has Attachments) and the type/
//  attachment filters look empty on an older archive.
//
//  The raw MIME of every email IS in email_bodies, so this job re-runs the
//  production message extractor over legacy rows in bounded pages and writes
//  the structured metadata back — no re-import needed. Work-list-driven and
//  idempotent: rows leave the list by getting a real type (or an honest
//  "unknown" when the raw source is unrecoverable), so a finished archive
//  costs one O(1) indexed probe per launch.
//
//  Sent/received classification uses the CURRENT sender address, matching
//  v1 semantics (v1 also classified at import time with the then-current
//  address). CPU-heavy MIME parsing runs off the main actor.
//

import Foundation
import os.log

extension Notification.Name {
    /// Posted after a backfill pass repaired at least one row — folder tree /
    /// filter facets should reload their working sets.
    static let fidelityBackfillCompleted = Notification.Name("mailin.fidelityBackfillCompleted")
}

@MainActor
final class FidelityBackfillJob {

    static let shared = FidelityBackfillJob()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "FidelityBackfill")

    /// Test seams. App-hosted tests share the app's REAL UserDefaults, so
    /// every defaults write goes through this handle — a test that forgets
    /// the override can pollute the user's actual sender address (it did).
    static var testStoreOverride: SQLiteEmailStore?
    static var testDefaultsOverride: UserDefaults?
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }
    private var defaults: UserDefaults { Self.testDefaultsOverride ?? .standard }

    private var task: Task<Void, Never>?
    /// M3: a finished/cancelled run may only clear ITS OWN handle — otherwise
    /// a stale completion erases a newer job's handle and lets a third run
    /// start concurrently.
    private var runGeneration = 0

    /// Settings ▸ Modules "Running now". The job owns its own row (owner's
    /// review 2026-09-29): registered when a run starts, cleared on EVERY
    /// exit — finished, nothing to do, cancelled, failed. Before this the row
    /// was cleared by a notification that fired only when a row was repaired,
    /// so a clean archive spun forever and a long run vanished at its first
    /// progress post.
    static let jobID = "fidelity.backfill"
    static let jobLabel = "Repair pre-full-fidelity rows"
    private weak var registry: JobRegistry?

    /// Test seam: the current run, if any.
    var currentRun: Task<Void, Never>? { task }

    /// M1: the sender address the last classification used. When it changes,
    /// sent/received reclassifies in one SQL pass (from_addr is stored).
    private static let senderUsedKey = "mailin.fidelity.senderUsed"

    /// One-shot header-recovery sweep marker (bump to re-run for all users).
    static let headerPassKey = "mailin.fidelity.headerPassVersion"
    static let headerPassVersion = 1

    /// How many repaired pages pass between progress notifications (v2.1
    /// backlog #12). Five pages of 200 = a refresh every ~1,000 rows.
    static let notifyEveryPages = 5

    struct Outcome: Sendable, Equatable {
        var repaired = 0
        var unrecoverable = 0
        var failed = 0
    }

    /// Fire-and-forget launch hook. A no-op (one indexed COUNT probe) when
    /// nothing is pending; one job at a time.
    func kickIfNeeded(senderEmail: String, registry: JobRegistry? = nil) {
        guard task == nil else { return }
        if let registry { self.registry = registry }
        runGeneration += 1
        let generation = runGeneration
        self.registry?.register(id: Self.jobID, module: .archive, label: Self.jobLabel) { [weak self] in self?.cancel() }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reclassifyIfSenderChanged(senderEmail)
            _ = await self.run(senderEmail: senderEmail)
            // Only this run's own completion clears its handle and its row;
            // a cancel already did both and may have started a newer run.
            if self.runGeneration == generation {
                self.task = nil
                self.registry?.finish(id: Self.jobID)
            }
        }
    }

    private func report(_ outcome: Outcome) {
        var parts: [String] = []
        if outcome.repaired > 0 { parts.append("\(outcome.repaired.formatted()) repaired") }
        if outcome.unrecoverable > 0 { parts.append("\(outcome.unrecoverable.formatted()) unrecoverable") }
        if outcome.failed > 0 { parts.append("\(outcome.failed.formatted()) failed") }
        registry?.update(id: Self.jobID, detail: parts.isEmpty ? "checking…" : parts.joined(separator: ", "))
    }

    /// M1: a changed sender address reclassifies every already-classified row
    /// (pure SQL over from_addr — no re-parse); pending rows classify with
    /// the new address during the normal backfill.
    private func reclassifyIfSenderChanged(_ senderEmail: String) async {
        let sender = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let recorded = defaults.string(forKey: Self.senderUsedKey) ?? ""
        guard !sender.isEmpty, sender.caseInsensitiveCompare(recorded) != .orderedSame else { return }
        do {
            try await store.reclassifyMessageTypes(senderEmail: sender)
            defaults.set(sender, forKey: Self.senderUsedKey)
            NotificationCenter.default.post(name: .fidelityBackfillCompleted, object: nil)
            Self.logger.info("message types reclassified for updated sender address")
        } catch {
            Self.logger.error("sender reclassification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel() {
        runGeneration += 1
        task?.cancel()
        task = nil
        registry?.finish(id: Self.jobID)
    }

    /// Awaitable core (used by tests and the launch hook).
    @discardableResult
    func run(senderEmail: String, batchSize: Int = 200) async -> Outcome {
        var outcome = Outcome()
        do {
            let pending = try await store.fidelityPendingCount()
            let participantsPending = try await store.participantsBackfillCandidates(limit: 1)
            let headerPassNeeded = defaults.integer(forKey: Self.headerPassKey) < Self.headerPassVersion
            guard pending > 0 || !participantsPending.candidates.isEmpty || !participantsPending.rawless.isEmpty
                    || headerPassNeeded else {
                return outcome
            }
            Self.logger.info("fidelity backfill starting: \(pending) legacy row(s)")
            report(outcome)

            // v1 parity: an EMPTY sender address auto-detects from the archive
            // (v1's annotate() used the most common From; v2 prefers the
            // most-frequent participant — the owner is on nearly every email).
            var sender = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoDetected = sender.isEmpty
            if autoDetected, let detected = try await store.detectOwnerAddress(), !detected.isEmpty {
                sender = detected
                defaults.set(sender, forKey: "defaultSenderEmail")
                Self.logger.info("sender auto-detected from archive")
            }

            // v2.1 backlog #12: a long repair used to post ONE notification at
            // the very end, so the folder tree showed stale counts for the
            // whole run. Post after every few pages instead; the final post
            // below still covers the tail.
            var pagesSinceNotify = 0
            var repairedAtLastNotify = 0
            while true {
                if Task.isCancelled { break }
                let page = try await store.fidelityBackfillCandidates(limit: batchSize)
                // Rows without raw source exit the work list honestly, and
                // are COUNTED (they were previously marked out of sight).
                if !page.rawless.isEmpty {
                    try await store.markFidelityUnknown(ids: page.rawless)
                    outcome.unrecoverable += page.rawless.count
                }
                let candidates = page.candidates
                if candidates.isEmpty {
                    if page.rawless.isEmpty { break }
                    continue   // page was all raw-less; more may remain
                }

                // CPU-heavy MIME extraction off the main actor, one bounded
                // batch resident at a time.
                let batchSender = sender
                let parsed: [(UUID, MBOXParser.RawEmail?)] = await Task.detached(priority: .utility) {
                    candidates.map { candidate in
                        (candidate.id, try? MBOXParser.processRawMessage(candidate.raw, senderEmail: batchSender))
                    }
                }.value

                var unparseable: [UUID] = []
                var pageProgress = 0
                for (id, email) in parsed {
                    if Task.isCancelled { break }
                    if let email {
                        do {
                            try await store.applyFidelity(id: id, from: email)
                            outcome.repaired += 1
                            pageProgress += 1
                        } catch {
                            outcome.failed += 1
                            Self.logger.error("fidelity apply failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            // Leave the row pending: a transient store error
                            // must not mark evidence 'unknown'.
                        }
                    } else {
                        unparseable.append(id)
                    }
                }
                if !unparseable.isEmpty {
                    try await store.markFidelityUnknown(ids: unparseable)
                    outcome.unrecoverable += unparseable.count
                    pageProgress += unparseable.count
                }
                // Repaired/unknown rows leave the work list, so the loop
                // converges; a page with ZERO forward progress (every apply
                // failed) must stop instead of spinning on the same rows.
                if pageProgress == 0 { break }
                report(outcome)
                pagesSinceNotify += 1
                if pagesSinceNotify >= Self.notifyEveryPages, outcome.repaired > repairedAtLastNotify {
                    NotificationCenter.default.post(name: .fidelityBackfillCompleted, object: nil)
                    pagesSinceNotify = 0
                    repairedAtLastNotify = outcome.repaired
                }
            }

            // Second pass: rows that already HAVE a type but no participants
            // (older-build backfills and SQL reclassification skip extraction).
            // Same convergence rules: sentinel rows mark unparseable emails.
            while true {
                if Task.isCancelled { break }
                let page = try await store.participantsBackfillCandidates(limit: batchSize)
                if !page.rawless.isEmpty {
                    try await store.markParticipantsNone(ids: page.rawless)
                }
                if page.candidates.isEmpty {
                    if page.rawless.isEmpty { break }
                    continue
                }
                let batchSender = sender
                let parsed: [(UUID, MBOXParser.RawEmail?)] = await Task.detached(priority: .utility) {
                    page.candidates.map { candidate in
                        (candidate.id, try? MBOXParser.processRawMessage(candidate.raw, senderEmail: batchSender))
                    }
                }.value
                var pageProgress = page.rawless.count
                var unparseable: [UUID] = []
                for (id, email) in parsed {
                    if Task.isCancelled { break }
                    if let email {
                        do {
                            try await store.applyFidelity(id: id, from: email)
                            outcome.repaired += 1
                            pageProgress += 1
                        } catch {
                            outcome.failed += 1
                            Self.logger.error("participants backfill failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    } else {
                        unparseable.append(id)
                    }
                }
                if !unparseable.isEmpty {
                    try await store.markParticipantsNone(ids: unparseable)
                    pageProgress += unparseable.count
                }
                if pageProgress == 0 { break }
                report(outcome)
            }

            // Third pass — header recovery for rows with NO raw MIME (pre-v2
            // migrated archives): the parse passes above can't touch them, but
            // the persisted headers still carry the Gmail labels, the
            // multipart/mixed attachment signal, and the source filename.
            // One converging keyset sweep per version flag; every write is
            // additive + idempotent, so an interrupted sweep just redoes work.
            if headerPassNeeded && !Task.isCancelled {
                var cursor: String? = nil
                var sweepFailed = false
                while true {
                    if Task.isCancelled { sweepFailed = true; break }
                    let page = try await store.headerFidelityCandidates(afterID: cursor, limit: batchSize)
                    guard let last = page.last else { break }
                    cursor = last.id.uuidString
                    let updates: [SQLiteEmailStore.HeaderFidelityUpdate] = await Task.detached(priority: .utility) {
                        page.compactMap { candidate in
                            guard let data = candidate.headersJSON.data(using: .utf8),
                                  let headers = try? JSONDecoder().decode([String: String].self, from: data)
                            else { return nil }
                            // Identical label split to the production parser.
                            var tags: [String] = []
                            if let labels = headers["X-Gmail-Labels"] ?? headers["X-gmail-labels"] {
                                tags = labels.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                            let contentType = (headers["Content-Type"] ?? "").lowercased()
                            let hasAttachment = contentType.contains("multipart/mixed")
                            let sourceFile = headers["sourceFile"] ?? headers["X-Source-File"]
                            guard !tags.isEmpty || hasAttachment || !(sourceFile ?? "").isEmpty else { return nil }
                            return SQLiteEmailStore.HeaderFidelityUpdate(
                                id: candidate.id, tags: tags,
                                hasAttachment: hasAttachment, sourceFilename: sourceFile)
                        }
                    }.value
                    if !updates.isEmpty {
                        do {
                            try await store.applyHeaderFidelity(updates)
                            outcome.repaired += updates.count
                        } catch {
                            sweepFailed = true
                            outcome.failed += updates.count
                            Self.logger.error("header fidelity apply failed: \(error.localizedDescription, privacy: .public)")
                            break
                        }
                    }
                }
                if !sweepFailed {
                    defaults.set(Self.headerPassVersion, forKey: Self.headerPassKey)
                    Self.logger.info("header fidelity sweep complete")
                }
            }

            Self.logger.info("fidelity backfill done: \(outcome.repaired) repaired, \(outcome.unrecoverable) unknown, \(outcome.failed) failed")

            // Self-correct an auto-detected sender: the participants tables now
            // exist, so the owner heuristic is reliable — if it disagrees with
            // the pre-backfill guess, reclassify in one SQL pass.
            if autoDetected, outcome.repaired > 0,
               let better = try await store.detectOwnerAddress(), !better.isEmpty,
               better.caseInsensitiveCompare(sender) != .orderedSame {
                try await store.reclassifyMessageTypes(senderEmail: better)
                defaults.set(better, forKey: "defaultSenderEmail")
                defaults.set(better, forKey: Self.senderUsedKey)
                Self.logger.info("sender re-detected after backfill; message types reclassified")
            } else if !sender.isEmpty {
                defaults.set(sender, forKey: Self.senderUsedKey)
            }
        } catch {
            Self.logger.error("fidelity backfill aborted: \(error.localizedDescription, privacy: .public)")
        }
        // M7: repaired rows must reach the UI even when a LATER batch failed.
        if outcome.repaired > 0 {
            NotificationCenter.default.post(name: .fidelityBackfillCompleted, object: nil)
        }
        return outcome
    }
}
