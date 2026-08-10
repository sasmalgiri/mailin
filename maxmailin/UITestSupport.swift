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
                let emails = try MBOXParser.parse(fileURL: url, senderEmail: "")
                _ = try await SQLiteEmailStore.shared.insertBatch(
                    emails, sourceFileHash: nil, accountID: nil,
                    sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
                    batchSize: 200, progress: nil)
                try await FTSSearchIndex.shared.indexBatch(emails)
                NotificationCenter.default.post(name: .parsingFinished, object: nil)
            } catch {
                // Seeding is best-effort; the UI test asserts on visible state.
            }
        }
    }
}
