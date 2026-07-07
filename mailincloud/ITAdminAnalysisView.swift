import SwiftUI

struct ITAdminAnalysisView: View {
    let emails: [MBOXParser.RawEmail]

    // MARK: - State

    @State private var selectedEmailID: UUID?
    @State private var activeTab: AnalysisTab = .headers
    @State private var filterSearchText = ""
    @State private var showBatchReport = false
    @State private var sortByAuth = false
    @State private var showExportSheet = false
    @State private var threatScores: [UUID: Int] = [:]
    @State private var hasComputedThreats = false

    // v3: KG + NLP + Anomaly
    @State private var graph = KnowledgeGraph()
    @State private var kgLoaded = false
    @State private var phishingFlags: [EmailNLPEngine.PhishingFlag] = []
    @State private var anomalies: [AnomalyDetectionEngine.Anomaly] = []
    @State private var entities: [EmailNLPEngine.EntityResult] = []
    @State private var hasV3Analysis = false
    @State private var isV3Loading = false

    // v4: AI + Background
    @State private var aiSecurityBrief = ""
    @State private var isGeneratingBrief = false
    @State private var includeAIInExport = false
    @ObservedObject private var backgroundManager = BackgroundAnalysisManager.shared

    // v5: SecurityAnalysisFeatures
    @State private var threatCorrelations: [SecurityAnalysisFeatures.ThreatCorrelation] = []
    @State private var domainReputations: [SecurityAnalysisFeatures.DomainReputation] = []
    @State private var compromiseIndicators: [SecurityAnalysisFeatures.CompromiseIndicator] = []
    @State private var securityTimeline: [SecurityAnalysisFeatures.SecurityEvent] = []
    @State private var authHealth: [SecurityAnalysisFeatures.AuthenticationHealth] = []
    @StateObject private var coordinator = AnalysisCoordinator()
    @State private var showTutorial = false

    enum AnalysisTab: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case auth = "Authentication"
        case routing = "Routing"
        case mime = "MIME"
        case domains = "Domains"
        case anomalies = "Anomalies"
        case batch = "Batch Analysis"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .headers: return "doc.text"
            case .auth: return "checkmark.shield"
            case .routing: return "arrow.triangle.branch"
            case .mime: return "doc.richtext"
            case .domains: return "globe"
            case .anomalies: return "exclamationmark.triangle"
            case .batch: return "chart.bar"
            }
        }
    }

    private var selectedEmail: MBOXParser.RawEmail? {
        guard let id = selectedEmailID else { return nil }
        return emails.first { $0.id == id }
    }

    private var filteredEmails: [MBOXParser.RawEmail] {
        guard !filterSearchText.isEmpty else { return emails }
        let q = filterSearchText.lowercased()
        return emails.filter {
            ($0.headers["From"] ?? "").lowercased().contains(q) ||
            ($0.headers["Subject"] ?? "").lowercased().contains(q) ||
            ($0.headers["To"] ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            threatAlertBanner
            Divider()
            #if os(macOS)
            HSplitView {
                emailListPane
                    .frame(minWidth: 300, idealWidth: 350)
                analysisPane
                    .frame(minWidth: 500)
            }
            #else
            if selectedEmail != nil {
                analysisPane
                    .overlay(alignment: .topLeading) {
                        Button { selectedEmailID = nil } label: {
                            Label("Back to List", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
            } else {
                emailListPane
            }
            #endif
        }
        .overlay { if AnalysisCoordinator.isEnabled { AnalysisProgressOverlay(coordinator: coordinator) } }
        .featureTutorial(.itAdmin, key: "it_admin_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showExportSheet) { exportReportSheet }
        .onAppear { if !hasComputedThreats { computeAllThreatScores() } }
        .task { await loadV3Data() }
    }

    private func loadV3Data() async {
        let loaded = KnowledgeGraph.load()
        if loaded.nodeCount > 0 { graph = loaded; kgLoaded = true }

        guard !hasV3Analysis else { return }
        isV3Loading = true
        let emailsCopy = emails

        guard AnalysisCoordinator.isEnabled else {
            let flags = EmailNLPEngine.detectPhishing(in: emailsCopy)
            let anom = AnomalyDetectionEngine.detectAnomalies(in: emailsCopy)
            let ents = EmailNLPEngine.extractEntities(from: emailsCopy, limit: 20)
            phishingFlags = flags; anomalies = anom; entities = ents; enhanceThreatScoresWithNLP()
            let pc = phishingFlags; let ac = anomalies
            threatCorrelations = SecurityAnalysisFeatures.correlateThreatSignals(emails: emailsCopy, phishingFlags: pc, anomalies: ac)
            domainReputations = SecurityAnalysisFeatures.scoreDomainReputations(emails: emailsCopy, phishingFlags: pc)
            compromiseIndicators = SecurityAnalysisFeatures.detectCompromisedAccounts(emails: emailsCopy, anomalies: ac)
            securityTimeline = SecurityAnalysisFeatures.buildSecurityTimeline(emails: emailsCopy, threats: threatCorrelations, phishingFlags: pc, anomalies: ac)
            authHealth = SecurityAnalysisFeatures.analyzeAuthenticationHealth(emails: emailsCopy)
            hasV3Analysis = true; isV3Loading = false; return
        }

        coordinator.begin(steps: 8, color: .teal)

        coordinator.advance(step: 1, label: "Detecting phishing patterns...")
        guard let flags = await coordinator.runDetached({ EmailNLPEngine.detectPhishing(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 2, label: "Running anomaly detection...")
        guard let anom = await coordinator.runDetached({ AnomalyDetectionEngine.detectAnomalies(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 3, label: "Extracting entities...")
        guard let ents = await coordinator.runDetached({ EmailNLPEngine.extractEntities(from: emailsCopy, limit: 20) }) else { coordinator.finish(); return }

        phishingFlags = flags; anomalies = anom; entities = ents
        enhanceThreatScoresWithNLP()
        let phishCopy = phishingFlags; let anomCopy = anomalies

        coordinator.advance(step: 4, label: "Correlating threat signals...")
        guard let threats = await coordinator.runDetached({ SecurityAnalysisFeatures.correlateThreatSignals(emails: emailsCopy, phishingFlags: phishCopy, anomalies: anomCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 5, label: "Scoring domain reputations...")
        guard let domReps = await coordinator.runDetached({ SecurityAnalysisFeatures.scoreDomainReputations(emails: emailsCopy, phishingFlags: phishCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 6, label: "Detecting compromised accounts...")
        guard let compromised = await coordinator.runDetached({ SecurityAnalysisFeatures.detectCompromisedAccounts(emails: emailsCopy, anomalies: anomCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 7, label: "Building security timeline...")
        guard let timeline = await coordinator.runDetached({ SecurityAnalysisFeatures.buildSecurityTimeline(emails: emailsCopy, threats: threats, phishingFlags: phishCopy, anomalies: anomCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 8, label: "Analyzing authentication health...")
        guard let auth = await coordinator.runDetached({ SecurityAnalysisFeatures.analyzeAuthenticationHealth(emails: emailsCopy) }) else { coordinator.finish(); return }

        threatCorrelations = threats; domainReputations = domReps
        compromiseIndicators = compromised; securityTimeline = timeline; authHealth = auth
        hasV3Analysis = true; isV3Loading = false
        coordinator.finish()
    }

    private func enhanceThreatScoresWithNLP() {
        let phishingByID: [UUID: EmailNLPEngine.PhishingFlag] = Dictionary(
            phishingFlags.map { ($0.email.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let anomalyByEmail: [UUID: Double] = {
            var result: [UUID: Double] = [:]
            for anomaly in anomalies {
                for emailID in anomaly.affectedEmails {
                    result[emailID] = max(result[emailID] ?? 0, anomaly.severity)
                }
            }
            return result
        }()

        for email in emails {
            var score = threatScores[email.id] ?? computeThreatScore(email)
            if let flag = phishingByID[email.id] {
                switch flag.riskLevel {
                case .high: score += 4
                case .medium: score += 2
                case .low: score += 1
                }
            }
            if let anomSev = anomalyByEmail[email.id] {
                if anomSev > 0.7 { score += 3 }
                else if anomSev > 0.4 { score += 2 }
                else { score += 1 }
            }
            threatScores[email.id] = min(score, 10)
        }
        hasComputedThreats = true
    }

    // MARK: - Toolbar

    private var toolBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 12)).foregroundColor(.teal)
            Text("IT Admin Analysis").font(.system(size: 12, weight: .semibold)).foregroundColor(.teal)

            Divider().frame(height: 14)

            ForEach(AnalysisTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 9))
                        Text(tab.rawValue).font(.system(size: 9, weight: activeTab == tab ? .bold : .medium))
                    }
                    .foregroundColor(activeTab == tab ? .teal : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(activeTab == tab ? Color.teal.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            TextField("Search emails...", text: $filterSearchText)
                .font(.system(size: 10))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Button { computeAllThreatScores() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "shield.checkered").font(.system(size: 9))
                    Text("Threat Scan").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(hasComputedThreats ? .green : .orange)
            }
            .buttonStyle(.plain)

            Button { showExportSheet = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 9))
                    Text("Export").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            TutorialHelpButton(showTutorial: $showTutorial)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppColors.backgroundSecondary.opacity(0.5))
    }

    // MARK: - Email List Pane

    private var emailListPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("EMAILS").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(filteredEmails.count)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.teal)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(AppColors.backgroundSecondary.opacity(0.6))

            List(filteredEmails, id: \.id, selection: $selectedEmailID) { email in
                emailListRow(email)
                    .tag(email.id)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 36)
        }
    }

    private func emailListRow(_ email: MBOXParser.RawEmail) -> some View {
        let authStatus = parseAuthStatus(email)
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
        let threat = threatScores[email.id] ?? 0

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                authStatusIcon(authStatus)
                Text(from).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer()
                if threat > 0 {
                    Text("Threat: \(threat)/10")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(threat >= 7 ? .red : threat >= 4 ? .orange : .yellow)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill((threat >= 7 ? Color.red : threat >= 4 ? .orange : .yellow).opacity(0.12)))
                        .help("Composite threat score based on phishing signals, authentication failures, and anomaly detection")
                }
            }
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Analysis Pane

    @ViewBuilder
    private var analysisPane: some View {
        if let email = selectedEmail {
            switch activeTab {
            case .headers:
                headerAnalysis(email)
            case .auth:
                authenticationAnalysis(email)
            case .routing:
                routingAnalysis(email)
            case .mime:
                mimeAnalysis(email)
            case .domains:
                domainAnalysis(email)
            case .anomalies:
                anomaliesView
            case .batch:
                batchAnalysisView
            }
        } else if activeTab == .batch {
            batchAnalysisView
        } else if activeTab == .anomalies {
            anomaliesView
        } else {
            VStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 36))
                    .foregroundColor(.teal.opacity(0.3))
                Text("Select an email to analyze")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("What you can do:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    itGuideRow(icon: "envelope.badge.shield.half.filled", text: "Click an email to inspect its security headers and routing")
                    itGuideRow(icon: "shield.checkered", text: "View authentication results (SPF, DKIM, DMARC)")
                    itGuideRow(icon: "exclamationmark.triangle", text: "Check phishing risk scores and threat indicators")
                    itGuideRow(icon: "chart.bar.xaxis", text: "Switch to Batch Analysis for aggregate security overview")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.05)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header Analysis

    private func headerAnalysis(_ email: MBOXParser.RawEmail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Full Header Analysis", icon: "doc.text", color: .teal, tip: "Email headers contain technical routing info — who sent it, which servers handled it, and security verification results")

                let importantHeaders = ["From", "To", "Cc", "Bcc", "Date", "Subject", "Message-ID", "Message-Id",
                                        "In-Reply-To", "References", "Return-Path", "Reply-To",
                                        "Content-Type", "MIME-Version", "X-Mailer", "User-Agent"]
                let sorted = email.headers.sorted { a, b in
                    let aIdx = importantHeaders.firstIndex(of: a.key) ?? importantHeaders.count
                    let bIdx = importantHeaders.firstIndex(of: b.key) ?? importantHeaders.count
                    return aIdx < bIdx
                }

                ForEach(sorted, id: \.key) { key, value in
                    headerRow(key: key, value: value, isImportant: importantHeaders.contains(key))
                }

                if !email.rawSource.isEmpty {
                    Divider()
                    sectionTitle("Raw Source (first 2000 chars)", icon: "doc.plaintext", color: .gray)
                    Text(String(email.rawSource.prefix(2000)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(AppColors.backgroundSecondary.opacity(0.3))
                        .cornerRadius(4)
                }
            }
            .padding(12)
        }
    }

    private func headerRow(key: String, value: String, isImportant: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: isImportant ? .semibold : .regular, design: .monospaced))
                .foregroundColor(isImportant ? .teal : .secondary)
                .frame(width: 140, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Authentication Analysis

    private func authenticationAnalysis(_ email: MBOXParser.RawEmail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Email Authentication", icon: "checkmark.shield", color: .teal)

                let authResults = email.headers["Authentication-Results"] ?? email.headers["authentication-results"] ?? ""
                let spf = parseAuthField(authResults, protocol: "spf")
                let dkim = parseAuthField(authResults, protocol: "dkim")
                let dmarc = parseAuthField(authResults, protocol: "dmarc")

                authCard("SPF (Sender Policy Framework)", result: spf.result, detail: spf.detail, icon: "envelope.badge.shield.half.filled")
                    .help("Sender Policy Framework: verifies the sender's IP is authorized to send on behalf of the domain")
                authCard("DKIM (DomainKeys Identified Mail)", result: dkim.result, detail: dkim.detail, icon: "signature")
                    .help("DomainKeys Identified Mail: verifies the message wasn't altered in transit using cryptographic signatures")
                authCard("DMARC (Domain-based Message Authentication)", result: dmarc.result, detail: dmarc.detail, icon: "shield.checkered")
                    .help("Domain-based Message Authentication: policy for handling emails that fail SPF or DKIM checks")

                Divider()

                sectionTitle("Raw Authentication-Results", icon: "text.alignleft", color: .gray)
                if authResults.isEmpty {
                    Text("No Authentication-Results header found")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Text(authResults)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(AppColors.backgroundSecondary.opacity(0.3))
                        .cornerRadius(4)
                }

                if let arcResults = email.headers["ARC-Authentication-Results"] {
                    Divider()
                    sectionTitle("ARC Authentication", icon: "arrow.triangle.2.circlepath", color: .orange)
                    Text(arcResults)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(AppColors.backgroundSecondary.opacity(0.3))
                        .cornerRadius(4)
                }

                Divider()
                tlsSection(email)

                if !authHealth.isEmpty {
                    Divider()
                    authHealthSection
                }
            }
            .padding(12)
        }
    }

    private func authCard(_ title: String, result: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(authColor(result).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(authColor(result))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                HStack(spacing: 4) {
                    Text(result.isEmpty ? "Not Found" : result.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(authColor(result))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: authIcon(result))
                .font(.system(size: 18))
                .foregroundColor(authColor(result))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(authColor(result).opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(authColor(result).opacity(0.15), lineWidth: 1))
        )
    }

    private func tlsSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("TLS Encryption", icon: "lock", color: .green)
            let receivedHeaders = email.headers.filter { $0.key.lowercased().hasPrefix("received") }
            let hasTLS = receivedHeaders.values.contains { $0.lowercased().contains("tls") || $0.lowercased().contains("ssl") || $0.lowercased().contains("esmtps") }

            HStack(spacing: 8) {
                Image(systemName: hasTLS ? "lock.fill" : "lock.open")
                    .font(.system(size: 14))
                    .foregroundColor(hasTLS ? .green : .red)
                Text(hasTLS ? "TLS encryption detected in transit" : "No TLS encryption detected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(hasTLS ? .green : .red)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((hasTLS ? Color.green : Color.red).opacity(0.05))
            )
        }
    }

    // MARK: - Routing Analysis

    private func routingAnalysis(_ email: MBOXParser.RawEmail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Mail Routing Path", icon: "arrow.triangle.branch", color: .teal, tip: "Shows every server this email passed through from sender to recipient — helps verify the email wasn't intercepted or rerouted")

                let hops = extractRoutingHops(email)
                if hops.isEmpty {
                    Text("No Received headers found").font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    ForEach(Array(hops.enumerated()), id: \.offset) { index, hop in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 0) {
                                ZStack {
                                    Circle()
                                        .fill(index == 0 ? Color.green : (index == hops.count - 1 ? Color.teal : Color.gray))
                                        .frame(width: 24, height: 24)
                                    Text("\(hops.count - index)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                if index < hops.count - 1 {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 2, height: 30)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                if let from = hop.from {
                                    Text("From: \(from)")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                }
                                if let by = hop.by {
                                    Text("By: \(by)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.teal)
                                }
                                if let proto = hop.proto {
                                    HStack(spacing: 4) {
                                        Text("Protocol:").font(.system(size: 9)).foregroundColor(.secondary)
                                        Text(proto).font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(proto.lowercased().contains("tls") || proto.lowercased().contains("esmtps") ? .green : .orange)
                                    }
                                }
                                if let timestamp = hop.timestamp {
                                    Text(timestamp)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.backgroundSecondary.opacity(0.3))
                            .cornerRadius(6)
                        }
                    }
                }

                Divider()
                sectionTitle("Return Path", icon: "arrow.uturn.backward", color: .orange)
                Text(email.headers["Return-Path"] ?? "Not present")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)

                if let xOrigIP = email.headers["X-Originating-IP"] {
                    Divider()
                    sectionTitle("Originating IP", icon: "network", color: .red)
                    Text(xOrigIP)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }

    // MARK: - MIME Analysis

    private func mimeAnalysis(_ email: MBOXParser.RawEmail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Email Structure (MIME)", icon: "doc.richtext", color: .teal, tip: "MIME defines how email content is formatted — text, HTML, attachments. Unusual structures can indicate manipulation or malware.")

                let contentType = email.headers["Content-Type"] ?? "text/plain"
                let mimeVersion = email.headers["MIME-Version"] ?? "Not specified"
                let encoding = email.headers["Content-Transfer-Encoding"] ?? "Not specified"

                HStack(spacing: 16) {
                    mimeInfoCard("MIME Version", value: mimeVersion, icon: "doc.badge.gearshape")
                    mimeInfoCard("Content Type", value: contentType.components(separatedBy: ";").first ?? contentType, icon: "doc.text")
                    mimeInfoCard("Encoding", value: encoding, icon: "arrow.left.arrow.right")
                }

                Divider()

                sectionTitle("Message Parts", icon: "square.stack.3d.up", color: .blue)

                HStack(spacing: 12) {
                    mimePartCard("Plain Text", available: !email.plainBody.isEmpty,
                                 size: email.plainBody.count, icon: "doc.text")
                    mimePartCard("HTML", available: !email.htmlBody.isEmpty,
                                 size: email.htmlBody.count, icon: "chevron.left.forwardslash.chevron.right")
                }

                if !email.attachments.isEmpty {
                    Divider()
                    sectionTitle("Attachments (\(email.attachments.count))", icon: "paperclip", color: .brown)
                    ForEach(email.attachments, id: \.filename) { attachment in
                        HStack(spacing: 8) {
                            Image(systemName: attachmentIcon(for: attachment.mimeType))
                                .font(.system(size: 14))
                                .foregroundColor(.brown)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.filename)
                                    .font(.system(size: 11, weight: .medium))
                                HStack(spacing: 8) {
                                    Text(attachment.mimeType)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(formatBytes(attachment.size))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.teal)
                                }
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(AppColors.backgroundSecondary.opacity(0.3))
                        .cornerRadius(4)
                    }
                }

                Divider()
                sectionTitle("Full Content-Type Header", icon: "text.alignleft", color: .gray)
                Text(contentType)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .padding(12)
        }
    }

    private func mimeInfoCard(_ title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(.teal)
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9, design: .monospaced)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(AppColors.backgroundSecondary.opacity(0.3))
        .cornerRadius(6)
    }

    private func mimePartCard(_ title: String, available: Bool, size: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(available ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(available ? formatBytes(size) : "Not available")
                    .font(.system(size: 9)).foregroundColor(available ? .teal : .secondary)
            }
            Spacer()
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(available ? .green : .secondary.opacity(0.5))
        }
        .padding(8)
        .background(AppColors.backgroundSecondary.opacity(0.3))
        .cornerRadius(6)
    }

    // MARK: - Domain Analysis

    private func domainAnalysis(_ email: MBOXParser.RawEmail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Domain & Sender Analysis", icon: "globe", color: .teal)

                let fromDomain = extractDomain(from: email.headers["From"] ?? "")
                let returnDomain = extractDomain(from: email.headers["Return-Path"] ?? "")
                let replyDomain = extractDomain(from: email.headers["Reply-To"] ?? "")

                domainCard("From Domain", domain: fromDomain, icon: "envelope")
                domainCard("Return-Path Domain", domain: returnDomain, icon: "arrow.uturn.backward")

                if !replyDomain.isEmpty && replyDomain != fromDomain {
                    domainCard("Reply-To Domain (MISMATCH)", domain: replyDomain, icon: "exclamationmark.triangle")
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red, lineWidth: 1))
                } else if !replyDomain.isEmpty {
                    domainCard("Reply-To Domain", domain: replyDomain, icon: "arrowshape.turn.up.left")
                }

                if returnDomain != fromDomain && !returnDomain.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Return-Path domain (\(returnDomain)) differs from From domain (\(fromDomain))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }

                Divider()

                sectionTitle("Custom Headers (X-Headers)", icon: "xmark.circle", color: .gray, tip: "Non-standard headers added by mail servers or apps — can reveal the email client used, spam scores, or internal routing info")
                let xHeaders = email.headers.filter { $0.key.lowercased().hasPrefix("x-") }.sorted { $0.key < $1.key }
                if xHeaders.isEmpty {
                    Text("No X-Headers found").font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    ForEach(xHeaders, id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 8) {
                            Text(key)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.teal)
                                .frame(width: 180, alignment: .trailing)
                            Text(value)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }

                if let mailer = email.headers["X-Mailer"] ?? email.headers["User-Agent"] {
                    Divider()
                    sectionTitle("Mail Client", icon: "envelope.badge.person.crop", color: .blue)
                    Text(mailer)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }

                if kgLoaded {
                    Divider()
                    kgDomainIntelligence(for: email)
                }

                if !domainReputations.isEmpty {
                    Divider()
                    domainReputationSection
                }
            }
            .padding(12)
        }
    }

    // MARK: - KG Domain Intelligence (v3)

    private func kgDomainIntelligence(for email: MBOXParser.RawEmail) -> some View {
        let fromDomain = extractDomain(from: email.headers["From"] ?? "")
        let domainNodeID = "domain:\(fromDomain)"
        let neighbors = graph.neighbors(of: domainNodeID)
        let topDomains = graph.topNodes(by: .domain, limit: 10)

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Domain Intelligence", icon: "point.3.connected.trianglepath.dotted", color: .cyan, tip: "Maps all email domains and the people connected to them — helps identify organizational relationships and unusual domain activity")

            if !fromDomain.isEmpty && !neighbors.isEmpty {
                Text("People associated with \(fromDomain):")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.cyan)
                ForEach(neighbors.filter({ $0.type == .person }).prefix(8), id: \.id) { person in
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle").font(.system(size: 9)).foregroundColor(.blue)
                        Text(person.label).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        Text("\(Int(person.weight)) emails")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                    }
                }
            } else if !fromDomain.isEmpty {
                Text("No KG data for \(fromDomain)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            if !topDomains.isEmpty {
                Divider()
                Text("Top Domains in Archive").font(.system(size: 10, weight: .semibold)).foregroundColor(.cyan)
                ForEach(topDomains.prefix(8), id: \.id) { domain in
                    HStack {
                        Text(domain.label).font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text("\(Int(domain.weight)) emails")
                            .font(.system(size: 9)).foregroundColor(.teal)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(8)
    }

    private func domainCard(_ title: String, domain: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.teal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Text(domain.isEmpty ? "Not available" : domain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(domain.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(AppColors.backgroundSecondary.opacity(0.3))
        .cornerRadius(8)
    }

    // MARK: - Threat Alert Banner (v4)

    private var threatAlertBanner: some View {
        let securityFindings = backgroundManager.lastRunFindings.filter {
            $0.category == "security" || $0.category == "phishing" || $0.category == "anomaly"
        }.sorted { $0.severity > $1.severity }

        return Group {
            if !securityFindings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "shield.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 11)).foregroundColor(.red)
                    Text("\(securityFindings.count) security findings detected")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.red)
                    Spacer()
                    Text(securityFindings.first?.title ?? "")
                        .font(.system(size: 9)).foregroundColor(.red.opacity(0.8)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.red.opacity(0.08))
            }
        }
    }

    // MARK: - AI Security Brief (v4)

    private func generateSecurityBrief() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard aiSecurityBrief.isEmpty else { return }
            isGeneratingBrief = true
            Task {
                let result = try? await FoundationModelEngine.securityBrief(emails) { text in
                    aiSecurityBrief = text
                }
                aiSecurityBrief = result ?? "Security brief unavailable."
                isGeneratingBrief = false
            }
        }
        #endif
    }

    // MARK: - Anomalies View (v3)

    private var anomaliesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Security Anomalies", icon: "exclamationmark.triangle", color: .orange)

                if isV3Loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing anomalies...").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                } else if anomalies.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill").foregroundColor(.green).font(.system(size: 16))
                        Text("No anomalies detected in your email archive.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(12)
                } else {
                    let grouped = Dictionary(grouping: anomalies, by: \.type)
                    let highCount = anomalies.filter { $0.severity > 0.7 }.count
                    let medCount = anomalies.filter { $0.severity > 0.4 && $0.severity <= 0.7 }.count

                    HStack(spacing: 12) {
                        anomalySummaryCard("Total", value: "\(anomalies.count)", color: .orange)
                        anomalySummaryCard("High", value: "\(highCount)", color: .red)
                        anomalySummaryCard("Medium", value: "\(medCount)", color: .yellow)
                        anomalySummaryCard("Types", value: "\(grouped.count)", color: .teal)
                    }

                    ForEach(Array(grouped.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                        let items = grouped[type] ?? []
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: type.icon).font(.system(size: 11)).foregroundColor(.orange)
                                Text(type.rawValue).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(items.count)").font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
                            }
                            Text(type.description).font(.system(size: 9)).foregroundColor(.secondary)

                            ForEach(items.sorted(by: { $0.severity > $1.severity }).prefix(5)) { anomaly in
                                anomalyRow(anomaly)
                            }
                            if items.count > 5 {
                                Text("... and \(items.count - 5) more")
                                    .font(.system(size: 9)).foregroundColor(.secondary).padding(.leading, 8)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.03))
                        .cornerRadius(8)
                    }

                    if !phishingFlags.isEmpty {
                        Divider()
                        sectionTitle("Phishing Detections", icon: "shield.slash", color: .red)
                        let highRisk = phishingFlags.filter { $0.riskLevel == .high }
                        let medRisk = phishingFlags.filter { $0.riskLevel == .medium }

                        HStack(spacing: 12) {
                            anomalySummaryCard("High Risk", value: "\(highRisk.count)", color: .red)
                            anomalySummaryCard("Medium Risk", value: "\(medRisk.count)", color: .orange)
                            anomalySummaryCard("Total Flagged", value: "\(phishingFlags.count)", color: .yellow)
                        }

                        ForEach(highRisk.prefix(5), id: \.email.id) { flag in
                            phishingRow(flag)
                        }
                    }
                }

                if !entities.isEmpty {
                    Divider()
                    sectionTitle("Detected Entities", icon: "person.text.rectangle", color: .blue)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(entities.prefix(12), id: \.name) { entity in
                            HStack(spacing: 4) {
                                Text(entity.type).font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(entityColor(entity.type))
                                    .cornerRadius(3)
                                Text(entity.name).font(.system(size: 10)).lineLimit(1)
                                Spacer()
                                Text("×\(entity.count)").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                            }
                            .padding(5)
                            .background(AppColors.backgroundSecondary.opacity(0.2))
                            .cornerRadius(4)
                        }
                    }
                }

                if !threatCorrelations.isEmpty {
                    Divider()
                    threatCorrelationSection
                }

                if !compromiseIndicators.isEmpty {
                    Divider()
                    compromisedAccountsSection
                }
            }
            .padding(12)
        }
    }

    private func anomalySummaryCard(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(color.opacity(0.06))
        .cornerRadius(6)
    }

    private func anomalyRow(_ anomaly: AnomalyDetectionEngine.Anomaly) -> some View {
        let sevColor: Color = anomaly.severity > 0.7 ? .red : anomaly.severity > 0.4 ? .orange : .yellow
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(sevColor).frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(anomaly.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(anomaly.detail).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.0f%%", anomaly.severity * 100))
                .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(sevColor)
                .help("Severity score from 0-100%. Above 70% = Critical, 40-70% = Medium, below 40% = Low")
            Text("\(anomaly.affectedEmails.count)")
                .font(.system(size: 8)).foregroundColor(.secondary)
            Image(systemName: "envelope").font(.system(size: 8)).foregroundColor(.secondary)
        }
        .padding(5)
        .background(sevColor.opacity(0.04))
        .cornerRadius(4)
    }

    private func phishingRow(_ flag: EmailNLPEngine.PhishingFlag) -> some View {
        let color: Color = flag.riskLevel == .high ? .red : flag.riskLevel == .medium ? .orange : .yellow
        return HStack(spacing: 6) {
            Image(systemName: "shield.slash.fill").font(.system(size: 10)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(flag.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(flag.reasons.prefix(2).joined(separator: " · "))
                    .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text(flag.riskLevel.rawValue).font(.system(size: 9, weight: .bold)).foregroundColor(color)
        }
        .padding(6)
        .background(color.opacity(0.04))
        .cornerRadius(4)
    }

    private func entityColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "personalname": return .blue
        case "placename": return .green
        case "organizationname": return .orange
        default: return .gray
        }
    }

    // MARK: - Batch Analysis

    private var batchAnalysisView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Batch Email Analysis (\(emails.count) emails)", icon: "chart.bar", color: .teal)

                let authStats = computeAuthStats()
                let domainStats = computeDomainStats()
                let clientStats = computeClientStats()
                let tlsCount = computeTLSCount()

                HStack(spacing: 12) {
                    batchStatCard("SPF Pass", value: "\(authStats.spfPass)", total: emails.count, color: .green)
                    batchStatCard("DKIM Pass", value: "\(authStats.dkimPass)", total: emails.count, color: .green)
                    batchStatCard("DMARC Pass", value: "\(authStats.dmarcPass)", total: emails.count, color: .green)
                    batchStatCard("TLS Encrypted", value: "\(tlsCount)", total: emails.count, color: .blue)
                }

                Divider()

                sectionTitle("Top Sending Domains", icon: "globe", color: .blue)
                ForEach(Array(domainStats.prefix(15)), id: \.0) { domain, count in
                    HStack {
                        Text(domain).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        ProgressView(value: Double(count), total: Double(emails.count))
                            .frame(width: 100)
                            .tint(.teal)
                        Text("\(count)").font(.system(size: 11, weight: .bold, design: .monospaced)).frame(width: 40, alignment: .trailing)
                    }
                }

                Divider()

                sectionTitle("Mail Clients", icon: "envelope.badge.person.crop", color: .purple)
                ForEach(Array(clientStats.prefix(10)), id: \.0) { client, count in
                    HStack {
                        Text(client).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text("\(count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.purple)
                    }
                }

                Divider()

                let attachmentEmails = emails.filter { !$0.attachments.isEmpty }
                let totalAttachments = emails.flatMap { $0.attachments }.count
                sectionTitle("Attachment Summary", icon: "paperclip", color: .brown)
                HStack(spacing: 20) {
                    VStack {
                        Text("\(attachmentEmails.count)").font(.system(size: 18, weight: .bold)).foregroundColor(.brown)
                        Text("Emails with\nattachments").font(.system(size: 9)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    VStack {
                        Text("\(totalAttachments)").font(.system(size: 18, weight: .bold)).foregroundColor(.brown)
                        Text("Total\nattachments").font(.system(size: 9)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                }

                if hasComputedThreats {
                    Divider()
                    threatSummarySection
                }

                if !securityTimeline.isEmpty {
                    Divider()
                    securityTimelineSection
                }

                Divider()
                aiSecurityBriefSection
            }
            .padding(12)
        }
    }

    // MARK: - AI Security Brief Section (v4)

    private var aiSecurityBriefSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.purple)
                Text("AI Security Brief").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isGeneratingBrief {
                    ProgressView().controlSize(.small)
                } else if aiSecurityBrief.isEmpty {
                    Button("Generate") { generateSecurityBrief() }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.purple)
                        .buttonStyle(.plain)
                }
            }
            if !aiSecurityBrief.isEmpty {
                Text(aiSecurityBrief)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } else if !isGeneratingBrief {
                Text("Generate an AI-powered security analysis of your email archive.")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.04))
        .cornerRadius(8)
    }

    private var threatSummarySection: some View {
        let high = threatScores.values.filter { $0 >= 7 }.count
        let medium = threatScores.values.filter { $0 >= 4 && $0 < 7 }.count
        let low = threatScores.values.filter { $0 > 0 && $0 < 4 }.count
        let clean = threatScores.values.filter { $0 == 0 }.count

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Threat Assessment", icon: "shield.checkered", color: .red)

            HStack(spacing: 12) {
                batchStatCard("High Risk", value: "\(high)", total: emails.count, color: .red)
                batchStatCard("Medium Risk", value: "\(medium)", total: emails.count, color: .orange)
                batchStatCard("Low Risk", value: "\(low)", total: emails.count, color: .yellow)
                batchStatCard("Clean", value: "\(clean)", total: emails.count, color: .green)
            }

            if high > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("High-Risk Emails").font(.system(size: 11, weight: .semibold)).foregroundColor(.red)
                    let highRiskEmails = emails.filter { (threatScores[$0.id] ?? 0) >= 7 }
                    ForEach(highRiskEmails.prefix(10), id: \.id) { email in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(.red)
                            Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                                .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Text(email.headers["Subject"] ?? "").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            Text("Score: \(threatScores[email.id] ?? 0)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.red)
                        }
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.05)).cornerRadius(6)
            }
        }
    }

    private func batchStatCard(_ title: String, value: String, total: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(color)
            Text("of \(total)").font(.system(size: 9)).foregroundColor(.secondary)
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Threat Correlation Section (v5)

    private var threatCorrelationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Threat Correlation", icon: "shield.lefthalf.filled.trianglebadge.exclamationmark", color: .red)

            let grouped = Dictionary(grouping: threatCorrelations, by: \.threatLevel)
            let levelOrder: [SecurityAnalysisFeatures.ThreatCorrelation.ThreatLevel] = [.critical, .high, .medium, .low]

            HStack(spacing: 12) {
                anomalySummaryCard("Critical", value: "\(grouped[.critical]?.count ?? 0)", color: .red)
                anomalySummaryCard("High", value: "\(grouped[.high]?.count ?? 0)", color: .orange)
                anomalySummaryCard("Medium", value: "\(grouped[.medium]?.count ?? 0)", color: .yellow)
                anomalySummaryCard("Low", value: "\(grouped[.low]?.count ?? 0)", color: .green)
            }

            ForEach(levelOrder, id: \.self) { level in
                if let items = grouped[level], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(level.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(threatLevelColor(level))

                        ForEach(items.prefix(8)) { threat in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(threatLevelColor(threat.threatLevel))
                                    .frame(width: 3, height: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(threat.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        Text(String(format: "%.0f%%", threat.compositeScore * 100))
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(threatLevelColor(threat.threatLevel))
                                            .help("Severity score from 0-100%. Above 70% = Critical, 40-70% = Medium, below 40% = Low")
                                        if let vector = threat.attackVector {
                                            Text(vector.rawValue)
                                                .font(.system(size: 7, weight: .bold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Capsule().fill(attackVectorColor(vector)))
                                        }
                                    }
                                    Text(threat.signals.prefix(2).map(\.detail).joined(separator: " | "))
                                        .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .padding(5)
                            .background(threatLevelColor(threat.threatLevel).opacity(0.04))
                            .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Domain Reputation Section (v5)

    private var domainReputationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Domain Reputation Scores", icon: "globe.badge.chevron.backward", color: .purple)

            ForEach(domainReputations.prefix(20)) { rep in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(domainCategoryColor(rep.category))
                        .frame(width: 3, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(rep.domain)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Spacer()
                            Text(rep.category.rawValue)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(domainCategoryColor(rep.category)))
                            Text(String(format: "%.0f", rep.score * 100))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(domainCategoryColor(rep.category))
                        }
                        HStack(spacing: 8) {
                            Text("\(rep.emailCount) emails")
                                .font(.system(size: 8)).foregroundColor(.secondary)
                            Text("Auth: \(Int(rep.authenticationRate * 100))%")
                                .font(.system(size: 8)).foregroundColor(rep.authenticationRate > 0.7 ? .green : .orange)
                                .help("Percentage of emails from this domain that pass authentication checks")
                            if rep.phishingRate > 0 {
                                Text("Phish: \(Int(rep.phishingRate * 100))%")
                                    .font(.system(size: 8)).foregroundColor(.red)
                            }
                        }
                        if !rep.riskFactors.isEmpty {
                            Text(rep.riskFactors.joined(separator: " | "))
                                .font(.system(size: 7)).foregroundColor(.orange).lineLimit(1)
                        }
                    }
                }
                .padding(6)
                .background(domainCategoryColor(rep.category).opacity(0.04))
                .cornerRadius(4)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Compromised Accounts Section (v5)

    private var compromisedAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Compromised Account Indicators", icon: "person.badge.shield.checkmark.fill", color: .red)

            ForEach(compromiseIndicators) { indicator in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 14)).foregroundColor(.red)
                        Text(indicator.accountEmail)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text(String(format: "%.0f%% confidence", indicator.confidence * 100))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(indicator.confidence > 0.7 ? .red : .orange)
                    }

                    ForEach(indicator.indicators, id: \.self) { evidence in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 7)).foregroundColor(.orange)
                            Text(evidence)
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("\(indicator.affectedEmails.count) affected emails")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                        if let window = indicator.timeWindow {
                            let formatter = DateFormatter()
                            let _ = formatter.dateStyle = .short
                            Text("\(formatter.string(from: window.first)) - \(formatter.string(from: window.last))")
                                .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.04))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.15), lineWidth: 1))
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.02))
        .cornerRadius(8)
    }

    // MARK: - Security Timeline Section (v5)

    private var securityTimelineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Security Event Timeline", icon: "clock.badge.exclamationmark", color: .indigo)

            ForEach(securityTimeline.prefix(25)) { event in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(securityEventColor(event.eventType))
                                .frame(width: 24, height: 24)
                            Image(systemName: securityEventIcon(event.eventType))
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                        }
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 2, height: 20)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(event.eventType.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(securityEventColor(event.eventType))
                            Spacer()
                            Text(String(format: "Severity: %.0f%%", event.severity * 100))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(event.severity > 0.7 ? .red : event.severity > 0.4 ? .orange : .yellow)
                                .help("Severity score from 0-100%. Above 70% = Critical, 40-70% = Medium, below 40% = Low")
                            let formatter = DateFormatter()
                            let _ = formatter.dateStyle = .short
                            let _ = formatter.timeStyle = .short
                            Text(formatter.string(from: event.timestamp))
                                .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Text(event.summary)
                            .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                        if !event.affectedEmails.isEmpty {
                            Text("\(event.affectedEmails.count) affected email(s)")
                                .font(.system(size: 8)).foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(securityEventColor(event.eventType).opacity(0.04))
                    .cornerRadius(6)
                }
            }
        }
        .padding(10)
        .background(Color.indigo.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Authentication Health Section (v5)

    private var authHealthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Per-Domain Authentication Health", icon: "stethoscope", color: .mint)

            ForEach(authHealth.prefix(20), id: \.domain) { health in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(health.domain)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Spacer()
                        Text(String(format: "%.0f%%", health.overallScore * 100))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(health.overallScore > 0.7 ? .green : health.overallScore > 0.4 ? .orange : .red)
                            .help("Percentage of emails from this domain that pass authentication checks")
                        Text("\(health.totalEmails) emails")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        authHealthBar(label: "SPF", pass: health.spfPass, fail: health.spfFail)
                            .help("Sender Policy Framework: verifies the sender's IP is authorized to send on behalf of the domain")
                        authHealthBar(label: "DKIM", pass: health.dkimPass, fail: health.dkimFail)
                            .help("DomainKeys Identified Mail: verifies the message wasn't altered in transit using cryptographic signatures")
                        authHealthBar(label: "DMARC", pass: health.dmarcPass, fail: health.dmarcFail)
                            .help("Domain-based Message Authentication: policy for handling emails that fail SPF or DKIM checks")
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((health.overallScore > 0.7 ? Color.green : health.overallScore > 0.4 ? Color.orange : Color.red).opacity(0.04))
                )
            }
        }
        .padding(10)
        .background(Color.mint.opacity(0.03))
        .cornerRadius(8)
    }

    private func authHealthBar(label: String, pass: Int, fail: Int) -> some View {
        let total = pass + fail
        let rate = total > 0 ? Double(pass) / Double(total) : 0
        return VStack(spacing: 2) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
            HStack(spacing: 2) {
                if total > 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green)
                        .frame(width: max(1, CGFloat(rate) * 40), height: 6)
                    if fail > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.red)
                            .frame(width: max(1, CGFloat(1.0 - rate) * 40), height: 6)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 6)
                }
            }
            Text("\(pass)/\(total)")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - v5 Color Helpers

    private func threatLevelColor(_ level: SecurityAnalysisFeatures.ThreatCorrelation.ThreatLevel) -> Color {
        switch level {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .green
        case .clean: return .gray
        }
    }

    private func attackVectorColor(_ vector: SecurityAnalysisFeatures.ThreatCorrelation.AttackVector) -> Color {
        switch vector {
        case .phishing: return .orange
        case .spearPhishing: return .red
        case .businessEmailCompromise: return .red
        case .malwareDelivery: return .purple
        case .credentialHarvesting: return .pink
        case .socialEngineering: return .orange
        case .spoofing: return .indigo
        }
    }

    private func domainCategoryColor(_ category: SecurityAnalysisFeatures.DomainReputation.DomainCategory) -> Color {
        switch category {
        case .trusted: return .green
        case .known: return .blue
        case .suspicious: return .orange
        case .malicious: return .red
        case .newUnverified: return .gray
        }
    }

    private func securityEventColor(_ type: SecurityAnalysisFeatures.SecurityEvent.SecurityEventType) -> Color {
        switch type {
        case .phishingCampaign: return .red
        case .authFailure: return .orange
        case .newThreatDomain: return .purple
        case .accountAnomaly: return .yellow
        case .dataExfiltration: return .red
        case .spoofingAttempt: return .indigo
        case .bulkSuspicious: return .orange
        }
    }

    private func securityEventIcon(_ type: SecurityAnalysisFeatures.SecurityEvent.SecurityEventType) -> String {
        switch type {
        case .phishingCampaign: return "hook"
        case .authFailure: return "xmark.shield"
        case .newThreatDomain: return "globe.badge.chevron.backward"
        case .accountAnomaly: return "person.badge.clock"
        case .dataExfiltration: return "arrow.up.doc"
        case .spoofingAttempt: return "theatermask.and.paintbrush"
        case .bulkSuspicious: return "tray.full"
        }
    }

    // MARK: - Common UI

    private func sectionTitle(_ title: String, icon: String, color: Color, tip: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
            Text(title).font(.system(size: 13, weight: .semibold))
            if tip != nil {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .help(tip ?? "")
    }

    private func itGuideRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.teal)
            Text(text).font(.system(size: 10)).foregroundColor(.primary.opacity(0.7))
        }
    }

    private func authStatusIcon(_ status: AuthStatus) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(status.spf == "pass" ? Color.green : (status.spf.isEmpty ? Color.gray : Color.red))
                .frame(width: 6, height: 6)
            Circle()
                .fill(status.dkim == "pass" ? Color.green : (status.dkim.isEmpty ? Color.gray : Color.red))
                .frame(width: 6, height: 6)
            Circle()
                .fill(status.dmarc == "pass" ? Color.green : (status.dmarc.isEmpty ? Color.gray : Color.red))
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - Parsing Helpers

    struct AuthStatus {
        var spf: String = ""
        var dkim: String = ""
        var dmarc: String = ""
    }

    struct AuthField {
        var result: String
        var detail: String
    }

    struct RoutingHop {
        var from: String?
        var by: String?
        var proto: String?
        var timestamp: String?
    }

    private func parseAuthStatus(_ email: MBOXParser.RawEmail) -> AuthStatus {
        let header = email.headers["Authentication-Results"] ?? email.headers["authentication-results"] ?? ""
        var status = AuthStatus()
        let lower = header.lowercased()
        if lower.contains("spf=pass") { status.spf = "pass" }
        else if lower.contains("spf=fail") || lower.contains("spf=softfail") { status.spf = "fail" }
        if lower.contains("dkim=pass") { status.dkim = "pass" }
        else if lower.contains("dkim=fail") { status.dkim = "fail" }
        if lower.contains("dmarc=pass") { status.dmarc = "pass" }
        else if lower.contains("dmarc=fail") { status.dmarc = "fail" }
        return status
    }

    private func parseAuthField(_ header: String, protocol proto: String) -> AuthField {
        let lower = header.lowercased()
        guard let range = lower.range(of: "\(proto)=") else { return AuthField(result: "", detail: "") }
        let after = String(lower[range.upperBound...])
        let result = after.components(separatedBy: CharacterSet.alphanumerics.inverted).first ?? ""
        let detail = String(after.prefix(80)).components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return AuthField(result: result, detail: detail)
    }

    private func extractRoutingHops(_ email: MBOXParser.RawEmail) -> [RoutingHop] {
        let receivedHeaders = email.headers.filter { $0.key.lowercased() == "received" || $0.key.lowercased().hasPrefix("received") }
            .sorted { $0.key < $1.key }

        return receivedHeaders.map { _, value in
            var hop = RoutingHop()
            let lower = value.lowercased()
            if let fromRange = lower.range(of: "from ") {
                let after = String(value[fromRange.upperBound...])
                hop.from = String(after.prefix(80)).components(separatedBy: " by ").first?.trimmingCharacters(in: .whitespaces)
            }
            if let byRange = lower.range(of: " by ") {
                let after = String(value[byRange.upperBound...])
                hop.by = String(after.prefix(80)).components(separatedBy: " with ").first?
                    .components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            }
            if let withRange = lower.range(of: " with ") {
                let after = String(value[withRange.upperBound...])
                hop.proto = String(after.prefix(40)).components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.init(charactersIn: "/"))).first
            }
            if let semiRange = value.range(of: ";") {
                hop.timestamp = String(value[semiRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return hop
        }
    }

    private func extractDomain(from address: String) -> String {
        let cleaned = address.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        guard let atIndex = cleaned.lastIndex(of: "@") else { return "" }
        return String(cleaned[cleaned.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authColor(_ result: String) -> Color {
        switch result.lowercased() {
        case "pass": return .green
        case "fail", "softfail": return .red
        case "neutral", "none": return .orange
        default: return .gray
        }
    }

    private func authIcon(_ result: String) -> String {
        switch result.lowercased() {
        case "pass": return "checkmark.circle.fill"
        case "fail", "softfail": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private func attachmentIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.contains("pdf") { return "doc.text" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "archivebox" }
        if mimeType.contains("spreadsheet") || mimeType.contains("csv") { return "tablecells" }
        return "doc"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Batch Computations

    struct BatchAuthStats {
        var spfPass = 0
        var dkimPass = 0
        var dmarcPass = 0
    }

    private func computeAuthStats() -> BatchAuthStats {
        var stats = BatchAuthStats()
        for email in emails {
            let auth = parseAuthStatus(email)
            if auth.spf == "pass" { stats.spfPass += 1 }
            if auth.dkim == "pass" { stats.dkimPass += 1 }
            if auth.dmarc == "pass" { stats.dmarcPass += 1 }
        }
        return stats
    }

    private func computeDomainStats() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for email in emails {
            let domain = extractDomain(from: email.headers["From"] ?? "")
            if !domain.isEmpty { counts[domain, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }
    }

    private func computeClientStats() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for email in emails {
            if let client = email.headers["X-Mailer"] ?? email.headers["User-Agent"] {
                counts[client, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
    }

    private func computeTLSCount() -> Int {
        emails.filter { email in
            email.headers.contains { k, v in
                k.lowercased().hasPrefix("received") &&
                (v.lowercased().contains("tls") || v.lowercased().contains("esmtps"))
            }
        }.count
    }

    // MARK: - Threat Scoring

    private func computeAllThreatScores() {
        var scores: [UUID: Int] = [:]
        for email in emails {
            scores[email.id] = computeThreatScore(email)
        }
        threatScores = scores
        hasComputedThreats = true
    }

    private func computeThreatScore(_ email: MBOXParser.RawEmail) -> Int {
        var score = 0
        let auth = parseAuthStatus(email)

        if auth.spf == "fail" { score += 3 }
        else if auth.spf.isEmpty { score += 1 }
        if auth.dkim == "fail" { score += 3 }
        else if auth.dkim.isEmpty { score += 1 }
        if auth.dmarc == "fail" { score += 2 }

        let fromDomain = extractDomain(from: email.headers["From"] ?? "")
        let returnDomain = extractDomain(from: email.headers["Return-Path"] ?? "")
        let replyDomain = extractDomain(from: email.headers["Reply-To"] ?? "")

        if !returnDomain.isEmpty && returnDomain != fromDomain { score += 2 }
        if !replyDomain.isEmpty && replyDomain != fromDomain { score += 2 }

        let hasTLS = email.headers.contains { k, v in
            k.lowercased().hasPrefix("received") &&
            (v.lowercased().contains("tls") || v.lowercased().contains("esmtps"))
        }
        if !hasTLS { score += 1 }

        let riskyTLDs = [".xyz", ".top", ".click", ".buzz", ".tk", ".ml", ".ga", ".cf"]
        if riskyTLDs.contains(where: { fromDomain.hasSuffix($0) }) { score += 2 }

        return min(score, 10)
    }

    // MARK: - Export Report Sheet

    private var exportReportSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("IT Security Report").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Export CSV") { exportCSV() }
                    .buttonStyle(.borderedProminent).tint(.teal)
                Button("Done") { showExportSheet = false }
            }

            let authStats = computeAuthStats()
            let tlsCount = computeTLSCount()
            let highRisk = threatScores.values.filter { $0 >= 7 }.count

            VStack(alignment: .leading, spacing: 8) {
                Text("Summary").font(.headline)
                Text("Total emails: \(emails.count)")
                Text("SPF pass rate: \(emails.count > 0 ? Int(Double(authStats.spfPass) / Double(emails.count) * 100) : 0)%")
                Text("DKIM pass rate: \(emails.count > 0 ? Int(Double(authStats.dkimPass) / Double(emails.count) * 100) : 0)%")
                Text("DMARC pass rate: \(emails.count > 0 ? Int(Double(authStats.dmarcPass) / Double(emails.count) * 100) : 0)%")
                Text("TLS encrypted: \(tlsCount)/\(emails.count)")
                Text("High-risk emails: \(highRisk)").foregroundColor(highRisk > 0 ? .red : .green)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }

    private func exportCSV() {
        var csv = "From,Subject,Date,SPF,DKIM,DMARC,TLS,Threat Score,From Domain,Return-Path Domain\n"
        for email in emails {
            let auth = parseAuthStatus(email)
            let from = (email.headers["From"] ?? "").replacingOccurrences(of: ",", with: ";")
            let subject = (email.headers["Subject"] ?? "").replacingOccurrences(of: ",", with: ";")
            let date = email.headers["Date"] ?? ""
            let hasTLS = email.headers.contains { k, v in
                k.lowercased().hasPrefix("received") && (v.lowercased().contains("tls") || v.lowercased().contains("esmtps"))
            }
            let fromDomain = extractDomain(from: email.headers["From"] ?? "")
            let returnDomain = extractDomain(from: email.headers["Return-Path"] ?? "")
            let threat = threatScores[email.id] ?? 0
            csv += "\(from),\(subject),\(date),\(auth.spf),\(auth.dkim),\(auth.dmarc),\(hasTLS ? "Yes" : "No"),\(threat),\(fromDomain),\(returnDomain)\n"
        }
        #if os(macOS)
        _ = PlatformFileSaver.saveText(csv, suggestedName: "it_security_report.csv")
        #endif
    }
}
