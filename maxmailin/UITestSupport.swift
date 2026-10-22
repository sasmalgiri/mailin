@testable import ArchiveCore
//
//  UITestSupport.swift
//  maxmailin
//
//  Deterministic launch state for the XCUITest click-through suite
//  ("--uitest" launch argument): onboarding sheets suppressed, and the
//  bundled demo archive imported once so every surface has real data to
//  exercise. DEBUG-only guard rails aside, this is inert in normal launches
//  (the argument is never passed by the app itself).
//

import Foundation

@MainActor
enum UITestSupport {

    static func prepareForUITests() {
        let defaults = UserDefaults.standard
        // No first-run sheets over the UI while the test clicks through.
        defaults.set(true, forKey: "hasSeenGettingStarted")
        defaults.set(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                     forKey: "lastSeenVersion")
        defaults.set(true, forKey: "maxmailin.selfTestCompletedV1")
        // Fresh installs show the Terms/Privacy consent sheet, which blocks
        // every interaction — pre-accept for the automated click-through
        // (mirrors LegalComplianceManager.accept()).
        defaults.set(true, forKey: "hasAcceptedTerms")
        defaults.set(LegalComplianceManager.currentTermsVersion, forKey: "acceptedTermsVersion")
        // Also flip the LIVE instances — both gates were read into memory
        // before this hook runs on first launch.
        LegalComplianceManager.shared.hasAcceptedTerms = true
        LegalComplianceManager.shared.acceptedTermsVersion = LegalComplianceManager.currentTermsVersion
        defaults.set(true, forKey: "hasCompletedPersonaSelection")
        PersonaManager.shared.hasCompletedPersonaSelection = true

        Task { @MainActor in
            let count = (try? await SQLiteEmailStore.shared.totalCount()) ?? 0
            guard count == 0 else { return }
            guard let url = Bundle.main.url(forResource: "demo_emails", withExtension: "mbox") else { return }
            do {
                var emails = try MBOXParser.parse(fileURL: url, senderEmail: "")
                // `-mailinSeedRecovery`: add sample deleted-but-present mail so the
                // recovery screens can be reviewed and screenshotted (A7).
                if ProcessInfo.processInfo.arguments.contains("-mailinSeedRecovery") {
                    emails += try recoverySamples()
                }
                let result = try await SQLiteEmailStore.shared.insertBatch(
                    emails, sourceFileHash: nil, accountID: nil,
                    sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
                    batchSize: 200, progress: nil)
                try await FTSSearchIndex.shared.indexBatch(result.inserted(from: emails))
                NotificationCenter.default.post(name: .parsingFinished, object: nil)
            } catch {
                // Seeding is best-effort; the UI test asserts on visible state.
            }
        }
    }

    /// Twelve sample messages carrying the markers mail clients leave on
    /// deleted mail (Thunderbird's expunged flag, the mbox "D" status).
    static func recoverySamples() throws -> [MBOXParser.RawEmail] {
        let subjects = ["Revised supplier contract", "Re: Q3 invoice dispute", "Board minutes draft",
                        "Delete after reading", "Re: Settlement figures", "Travel claims March",
                        "Fwd: Warehouse access log", "Pricing call notes", "Re: Termination letter",
                        "Shared drive clean-up", "Audit follow-up", "Re: Lunch Friday"]
        // Marked whatever the switch says at launch: the sample is meant to show recovered mail.
        let was = RecoveryPolicy.isEnabled
        RecoveryPolicy.isEnabled = true
        defer { RecoveryPolicy.isEnabled = was }
        return try subjects.enumerated().map { i, subject in
            let marker = i % 2 == 0 ? "X-Status: D\n" : "X-Mozilla-Status: 0009\n"
            let raw = "Message-ID: <recovered-sample-\(i)@example.com>\nSubject: \(subject)\n"
                + "From: Dana Kim <dana.kim@example.com>\nTo: legal@example.com\n"
                + "Date: Tue, \(4 + i) Mar 2025 09:\(10 + i):00 +0000\n\(marker)\n"
                + "Sample message \(i + 1) for the recovery screens.\n"
            return try MBOXParser.processRawMessage(raw, senderEmail: "")
        }
    }
}
