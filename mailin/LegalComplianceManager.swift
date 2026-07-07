import SwiftUI

@MainActor
class LegalComplianceManager: ObservableObject {
    static let shared = LegalComplianceManager()

    private static let currentTermsVersion = "1.1"
    private static let currentPrivacyVersion = "1.0"

    @AppStorage("hasAcceptedTerms") var hasAcceptedTerms = false
    @AppStorage("acceptedTermsVersion") var acceptedTermsVersion = ""
    @AppStorage("termsAcceptedDate") var termsAcceptedDateString = ""
    @AppStorage("dataRetentionDays") var dataRetentionDays = 0

    var needsTermsAcceptance: Bool {
        !hasAcceptedTerms || acceptedTermsVersion != Self.currentTermsVersion
    }

    func acceptTerms() {
        hasAcceptedTerms = true
        acceptedTermsVersion = Self.currentTermsVersion
        termsAcceptedDateString = ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - GDPR Right to Deletion

    func deleteAllUserData() {
        EmailPersistence.clear()
        ForensicManager.shared.clearAllForensicData()
        CustodianManager.shared.clearAll()
        PredictiveCodingEngine.shared.clearAll()
        ReviewBatchManager.shared.clearAll()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mailin", isDirectory: true)
        if FileManager.default.fileExists(atPath: tempDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.synchronize()

        let keychainKeys = [
            "apiKey",
            "forensicHMACKey",
            "gmail_access_token", "gmail_refresh_token", "gmail_token_expiry",
            "outlookAccessToken", "outlookRefreshToken", "outlookTokenExpiry",
            "settings_imapPassword", "imap_password",
            "settings_smtpPassword",
            "cloudAI_openAI_apiKey", "cloudAI_anthropic_apiKey"
        ]
        for key in keychainKeys {
            KeychainHelper.delete(key: key)
        }

        let kvStore = NSUbiquitousKeyValueStore.default
        for key in ["sync_caseNumber", "sync_examinerName", "sync_organization"] {
            kvStore.removeObject(forKey: key)
        }
        kvStore.synchronize()
    }

    // MARK: - Data Retention

    func checkDataRetention() {
        guard dataRetentionDays > 0 else { return }
        let retentionDate = Calendar.current.date(byAdding: .day, value: -dataRetentionDays, to: Date()) ?? Date()

        if let meta = try? Data(contentsOf: EmailPersistence.metaURLForRetentionCheck),
           let session = try? JSONDecoder().decode(EmailPersistence.SessionMeta.self, from: meta),
           session.savedAt < retentionDate {
            EmailPersistence.clear()
        }
    }

    // MARK: - Privacy Policy Text

    static let privacyPolicySummary = """
    PRIVACY POLICY SUMMARY

    Data Collection: mailin collects NO personal data. Zero analytics, zero tracking, zero telemetry.

    On-Device Processing: All email parsing, NLP analysis, search indexing, and AI features run entirely on your device. Your email data never leaves your device — period.

    Data Storage: Parsed emails and settings are stored locally using Apple's standard frameworks (UserDefaults, file system). No server-side storage. If you enable iCloud Sync, review metadata (tags, annotations, case info) syncs via Apple's iCloud Drive — your email content is never uploaded.

    Third-Party Services: Apple App Store for purchases. Optional features (Cloud AI, IMAP/SMTP, Gmail/Outlook Connect) may transmit data to external services only when explicitly enabled by you. No advertising SDKs, no analytics frameworks, no tracking.

    Data Deletion: You can delete all data at any time via Settings > Data & Privacy > Delete All Data.

    Children: mailin is not directed at children under 13 and does not knowingly collect data from children.

    Contact: sasmalgiri@gmail.com

    Full policy: https://sasmalgiri.github.io/mailin/privacy
    """

    // MARK: - Terms of Use Text

    static let termsOfUseSummary = """
    TERMS OF USE

    1. ACCEPTANCE: By using mailin, you agree to these terms. If you do not agree, do not use the app.

    2. LICENSE: mailin grants you a personal, non-transferable license to use the app on your Apple devices.

    3. PURCHASES: Premium features (mailin Personal and mailin Professional) are available via auto-renewable subscriptions (monthly or yearly) or a one-time lifetime purchase through the App Store. Payment will be charged to your Apple ID account at confirmation of purchase. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current billing period. You can manage or cancel subscriptions in System Settings > Apple ID > Subscriptions (Mac) or Settings > [your name] > Subscriptions (iPhone/iPad). Lifetime purchases are permanent and do not auto-renew.

    3a. REFUNDS: All purchases are processed by Apple under Apple's standard payment terms. The developer of mailin cannot issue refunds directly. To request a refund, visit https://reportaproblem.apple.com, sign in with the Apple ID used for the purchase, choose the purchase, and follow Apple's refund request process. Apple decides whether to grant the refund according to its policies and applicable consumer protection laws in your region (including the EU "right of withdrawal" where applicable). Cancellation of a subscription stops future renewals but does not retroactively refund prior periods unless Apple separately approves a refund.

    4. PERMITTED USE: You may use mailin for lawful purposes including personal email management, professional email analysis, legal document review, forensic investigation, and journalism research.

    5. PROHIBITED USE: You may not reverse-engineer, redistribute, or use mailin to violate any law, infringe on privacy rights, or engage in unauthorized surveillance.

    6. FORENSIC DISCLAIMER: mailin's forensic features (hash verification, audit logging, Bates stamping, chain of custody) are provided as analytical tools. They have NOT been independently validated for court admissibility. Users relying on mailin for legal proceedings should independently verify all forensic outputs. mailin makes no representations about the legal admissibility of its outputs in any jurisdiction.

    7. AI AND SOFTWARE LIMITATIONS: All software, including artificial intelligence (AI) features, can produce inaccurate, incomplete, or misleading results. AI-powered features in mailin (including but not limited to sentiment analysis, topic extraction, anomaly detection, smart filters, AI digest, predictive coding, AI assistant, and visualizations) use statistical and probabilistic models that may make mistakes, hallucinate information, or fail to detect relevant content. NLP, search, parsing, and analytical outputs may also contain errors. You must independently verify any output before relying on it for any legal, forensic, investigative, business, or personal decision. The developer disclaims all responsibility for decisions or actions taken based on the app's output.

    8. NO WARRANTY: mailin is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement.

    9. LIMITATION OF LIABILITY: In no event shall mailin or its developer be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, profits, or business opportunities arising from use of the app.

    10. DATA RESPONSIBILITY: You are solely responsible for the data you import into mailin. The developer assumes no liability for the content, legality, or sensitivity of imported email archives.

    11. INDEMNIFICATION: You agree to indemnify and hold harmless the developer from any claims arising from your use of the app.

    12. GOVERNING LAW: These terms are governed by the laws of India. Any disputes shall be subject to the jurisdiction of Indian courts.

    13. CHANGES: We may update these terms. Continued use after changes constitutes acceptance.

    Contact: sasmalgiri@gmail.com
    Full terms: https://sasmalgiri.github.io/mailin/terms
    """

    // MARK: - Forensic Disclaimer

    static let forensicDisclaimer = """
    IMPORTANT: mailin's forensic features are analytical tools provided for informational purposes. Hash verification, audit logging, Bates stamping, and chain of custody tracking have NOT been independently validated or certified for court admissibility. Users must independently verify all forensic outputs before relying on them in legal proceedings. mailin makes no representations regarding legal admissibility in any jurisdiction.
    """

    // MARK: - Open Source Licenses

    static let thirdPartyNotices = """
    THIRD-PARTY NOTICES

    mailin is built entirely with Apple's native frameworks:
    • SwiftUI — User interface
    • NaturalLanguage — On-device NLP
    • CryptoKit — Hash verification
    • PDFKit — PDF generation and rendering
    • StoreKit 2 — In-app purchases
    • Vision — OCR text recognition
    • Charts — Data visualization

    No third-party open source libraries are used. All code is original.

    Apple frameworks are provided under Apple's Software License Agreement.
    """
}

// MARK: - AI Disclaimer Banner

/// Compact, always-visible banner shown above AI-powered features.
/// Reminds users that AI/software output can be inaccurate and must be
/// verified — a standard liability mitigation pattern.
struct AIDisclaimerBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("AI and software can make mistakes. Verify important results before relying on them.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI disclaimer: AI and software can make mistakes. Verify important results before relying on them.")
    }
}

// MARK: - Terms Acceptance View

struct TermsAcceptanceView: View {
    @ObservedObject private var compliance = LegalComplianceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var termsRead = false
    @State private var privacyRead = false
    @State private var activeTab = 0

    private var canAccept: Bool { termsRead && privacyRead }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.small) {
                Image(systemName: "doc.text.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .indigo],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))

                Text("Terms & Privacy")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)

                Text("Please review before continuing")
                    .font(Typography.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, Spacing.large)
            .padding(.bottom, Spacing.small)
            .adaptiveHeroBackground(colors: [.blue, .indigo, .purple, .blue])

            Picker("", selection: $activeTab) {
                Text("Terms of Use").tag(0)
                Text("Privacy Policy").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, Spacing.small)

            Divider()

            ScrollView {
                Text(activeTab == 0
                     ? LegalComplianceManager.termsOfUseSummary
                     : LegalComplianceManager.privacyPolicySummary)
                    .font(.system(.caption, design: .monospaced))
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColors.backgroundSecondary)

            Divider()

            VStack(spacing: Spacing.small) {
                HStack(spacing: Spacing.medium) {
                    if let termsURL = URL(string: "https://sasmalgiri.github.io/mailin/terms") {
                        Link("Full Terms", destination: termsURL)
                            .font(Typography.caption1)
                    }
                    if let privacyURL = URL(string: "https://sasmalgiri.github.io/mailin/privacy") {
                        Link("Full Privacy Policy", destination: privacyURL)
                            .font(Typography.caption1)
                    }
                }

                checkboxRow("I have read the Terms of Use", isOn: $termsRead)
                    .padding(.horizontal, Spacing.medium)

                checkboxRow("I have read the Privacy Policy", isOn: $privacyRead)
                    .padding(.horizontal, Spacing.medium)

                Button {
                    compliance.acceptTerms()
                    dismiss()
                } label: {
                    Text("I Agree to the Terms of Use and Privacy Policy")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.small)
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.medium)
                                .fill(canAccept ? Color.blue : Color.gray)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAccept)
                .padding(.horizontal, Spacing.medium)
            }
            .padding(.vertical, Spacing.medium)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 720, minHeight: 500, idealHeight: 600, maxHeight: .infinity)
        #endif
    }

    private func checkboxRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundColor(isOn.wrappedValue ? .blue : .secondary)
                Text(title)
                    .font(Typography.caption1)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
