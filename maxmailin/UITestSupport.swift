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

    static func prepareForUITests(modules: ModuleRegistry? = nil) {
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

        // Live Gmail check (MailinClickThroughUITests.testConnectedGmail_liveSignIn_preserveAndVerify):
        // only on a fresh, isolated archive AND with the explicit environment
        // switch, turn on the Live Mail page and Connected mail exactly as
        // Settings ▸ Modules and the Mail page's "Turn on Connected mail" do.
        if UITestStorageRoot.override != nil,
           ProcessInfo.processInfo.environment[connectedMailEnvironmentKey] == "1" {
            enableConnectedMail(modules ?? ModuleRegistry.live)
        }

        // CLOSE-06: a fresh-archive run (MAILIN_UITEST_FRESH_ARCHIVE) starts
        // empty — the test imports its own fixture, so no demo seed.
        guard UITestStorageRoot.override == nil else { return }
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

    static let connectedMailEnvironmentKey = "MAILIN_UITEST_ENABLE_CONNECTED_MAIL"

    /// The registry path the Settings switches use: `enable(.liveMail)` (no
    /// activation sheet — that sheet is only shown for a tab clicked while its
    /// page is off) and then the `connectedMail` capability, whose wiring sets
    /// MailNetworkPolicy and starts the connected-mail runtime. Compiled only
    /// into a build with the mail transports; elsewhere it does nothing (the
    /// page is excluded there and `enable` would refuse anyway).
    private static func enableConnectedMail(_ modules: ModuleRegistry?) {
        #if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
        guard let modules else { return }
        do {
            try modules.enable(.liveMail)
        } catch {
            return
        }
        modules.set(.connectedMail, enabled: true)
        #endif
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
