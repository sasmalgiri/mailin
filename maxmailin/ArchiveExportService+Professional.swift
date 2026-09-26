//
//  ArchiveExportService+Professional.swift
//  maxmailin
//
//  Phase C-1 boundary: the Professional-owned exports (forensic CSV,
//  Concordance DAT, hash manifest, Relativity CSV) and the integrity
//  verification pass depend on `ForensicManager`, which belongs to Page 3.
//  They live here, outside the ArchiveCore file set, as an extension over
//  the same streaming pipeline — nothing about how they write changed.
//

import Foundation
import CryptoKit

extension ArchiveExportService {

    /// Called when Professional Workflows is enabled (and at launch when it
    /// already is): the detailed CSV's Risk Score column gets its scorer.
    /// Removed again when the page is disabled, so a Page-1-only install
    /// never runs forensic code through an export.
    @MainActor
    static func installProfessionalHooks(enabled: Bool) {
        if enabled {
            let scorer: @Sendable (MBOXParser.RawEmail) -> Int = { email in
                ForensicManager.assessRisk(for: email).score
            }
            riskScoreProvider = scorer
        } else {
            riskScoreProvider = nil
        }
    }

    /// Forensic CSV — signed (Ed25519 over the streamed SHA-256).
    @discardableResult
    func exportForensicCSV(scope: ArchiveSelectionScope, to url: URL,
                           batesPrefix: String = "MAIL",
                           limit: Int? = nil,
                           onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let forensic = ForensicManager.shared
        return try await exportTextDocument(
            scope: scope, to: url, limit: limit, signed: true,
            header: { _ in ForensicManager.forensicCSVHeader },
            onProgress: onProgress
        ) { email, index in
            forensic.forensicCSVRow(email, bates: ForensicManager.batesNumber(prefix: batesPrefix, index: index + 1))
        }
    }

    /// Concordance .dat load file — signed.
    @discardableResult
    func exportConcordanceDAT(scope: ArchiveSelectionScope, to url: URL,
                              batesPrefix: String = "MAIL",
                              onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let forensic = ForensicManager.shared
        return try await exportTextDocument(
            scope: scope, to: url, signed: true,
            header: { _ in ForensicManager.concordanceDATHeader },
            onProgress: onProgress
        ) { email, index in
            forensic.concordanceDATRow(email, bates: ForensicManager.batesNumber(prefix: batesPrefix, index: index + 1))
        }
    }

    /// Hash manifest CSV — signed.
    @discardableResult
    func exportHashManifest(scope: ArchiveSelectionScope, to url: URL,
                            onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        let forensic = ForensicManager.shared
        return try await exportTextDocument(
            scope: scope, to: url, signed: true,
            header: { _ in ForensicManager.hashManifestHeader },
            onProgress: onProgress
        ) { email, _ in
            forensic.hashManifestRow(email)
        }
    }

    /// Relativity load file — signed.
    @discardableResult
    func exportRelativityCSV(scope: ArchiveSelectionScope, to url: URL,
                             batesPrefix: String = "MAIL",
                             custodianName: String = "", caseNumber: String = "",
                             onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        try await exportTextDocument(
            scope: scope, to: url, signed: true,
            header: { _ in ExportManager.relativityLoadFileHeader + "\r\n" },
            onProgress: onProgress
        ) { email, index in
            ExportManager.relativityRow(email: email, index: index, batesPrefix: batesPrefix,
                                        custodianName: custodianName, caseNumber: caseNumber) + "\r\n"
        }
    }

    /// Streaming integrity verification — same math as
    /// `ForensicManager.batchVerifyAllEmails`, but over a bounded stream.
    func verifyIntegrity(scope: ArchiveSelectionScope,
                         onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> (passed: Int, failed: Int, unverified: Int) {
        let forensic = ForensicManager.shared
        var passed = 0, failed = 0, unverified = 0, done = 0
        let total = try await archive.count(scope: scope)
        for try await batch in archive.streamSelected(scope: scope) {
            try Task.checkCancellation()
            for email in batch {
                let result = forensic.verifyEmailIntegrity(email)
                if forensic.perEmailHashes[email.id] == nil { unverified += 1 }
                else if result.passed { passed += 1 }
                else { failed += 1 }
            }
            done += batch.count
            onProgress?(done, total)
        }
        forensic.logAction("Batch Verification", detail: "\(passed) passed, \(failed) failed, \(unverified) unverified")
        return (passed, failed, unverified)
    }
}
