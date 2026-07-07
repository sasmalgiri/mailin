//
//  BackgroundAnalysisManager.swift
//  mailin
//
//  Schedules and runs periodic background analysis using NSBackgroundActivityScheduler (macOS)
//  and BGProcessingTaskRequest (iOS). Re-runs anomalies, sentiment trends, knowledge graph
//  updates, and phishing pattern detection on a daily cadence.
//

import Foundation
import os
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
final class BackgroundAnalysisManager: ObservableObject {
    static let shared = BackgroundAnalysisManager()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "BackgroundAnalysis")

    static let taskIdentifier = "com.ecosanskriti.mailin.backgroundAnalysis"

    @Published var lastRunDate: Date? {
        didSet {
            if let date = lastRunDate {
                UserDefaults.standard.set(date, forKey: "backgroundAnalysis_lastRun")
            }
        }
    }
    @Published var lastRunFindings: [BackgroundFinding] = []
    @Published var isRunning = false

    struct BackgroundFinding: Identifiable, Sendable {
        let id = UUID()
        let category: String
        let title: String
        let detail: String
        let severity: Double
        let timestamp: Date
    }

    #if os(macOS)
    private var scheduler: NSBackgroundActivityScheduler?
    #endif

    private init() {
        lastRunDate = UserDefaults.standard.object(forKey: "backgroundAnalysis_lastRun") as? Date
        loadCachedFindings()
    }

    // MARK: - Schedule

    func scheduleBackgroundAnalysis() {
        #if os(macOS)
        scheduleMacOS()
        #elseif os(iOS)
        scheduleiOS()
        #endif
    }

    #if os(macOS)
    private func scheduleMacOS() {
        let activity = NSBackgroundActivityScheduler(identifier: Self.taskIdentifier)
        activity.repeats = true
        activity.interval = 24 * 60 * 60 // daily
        activity.qualityOfService = .utility
        activity.tolerance = 4 * 60 * 60 // 4 hour tolerance

        activity.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            Task { @MainActor in
                await self.runAnalysis()
                completion(.finished)
            }
        }
        scheduler = activity
        logger.info("Scheduled daily background analysis (macOS)")
    }
    #endif

    #if os(iOS)
    private func scheduleiOS() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled daily background analysis (iOS)")
        } catch {
            logger.error("Failed to schedule background task: \(error.localizedDescription)")
        }
    }

    func registerBGTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: true)
                return
            }
            Task { @MainActor in
                await self.handleBGTask(processingTask)
            }
        }
    }

    private func handleBGTask(_ task: BGProcessingTask) async {
        task.expirationHandler = { [weak self] in
            self?.isRunning = false
        }
        await runAnalysis()
        task.setTaskCompleted(success: true)
        scheduleiOS()
    }
    #endif

    // MARK: - Run Analysis

    func runAnalysis() async {
        let emails = currentArchiveEmails()
        guard !emails.isEmpty else {
            logger.info("No emails loaded — skipping background analysis")
            return
        }

        isRunning = true
        logger.info("Starting background analysis on \(emails.count) emails")

        var findings: [BackgroundFinding] = []
        let timestamp = Date()

        // 1. Anomaly detection
        let anomalies = AnomalyDetectionEngine.detectAnomalies(in: emails)
        for anomaly in anomalies where anomaly.severity >= 0.5 {
            findings.append(BackgroundFinding(
                category: "anomaly",
                title: anomaly.title,
                detail: anomaly.detail,
                severity: anomaly.severity,
                timestamp: timestamp
            ))
        }

        // 2. Phishing re-scan
        let phishing = EmailNLPEngine.detectPhishing(in: emails)
        let highRiskPhishing = phishing.filter { $0.riskLevel == .high }
        if !highRiskPhishing.isEmpty {
            findings.append(BackgroundFinding(
                category: "phishing",
                title: "\(highRiskPhishing.count) High-Risk Phishing Email\(highRiskPhishing.count == 1 ? "" : "s")",
                detail: "Subjects: " + highRiskPhishing.prefix(3).compactMap { $0.email.headers["Subject"] }.joined(separator: ", "),
                severity: 0.9,
                timestamp: timestamp
            ))
        }

        // 3. PII exposure check
        let pii = EmailNLPEngine.piiSummary(in: emails)
        let piiTotal = pii.values.reduce(0, +)
        if piiTotal > 0 {
            let types = pii.filter { $0.value > 0 }.keys.map(\.rawValue).joined(separator: ", ")
            findings.append(BackgroundFinding(
                category: "pii",
                title: "\(piiTotal) PII Exposure\(piiTotal == 1 ? "" : "s")",
                detail: "Types: \(types)",
                severity: piiTotal >= 5 ? 0.8 : 0.5,
                timestamp: timestamp
            ))
        }

        // 4. Sentiment trend analysis
        let sentiments = EmailNLPEngine.analyzeSentiment(of: emails)
        if sentiments.count >= 20 {
            let midpoint = sentiments.count / 2
            let firstHalf = sentiments.prefix(midpoint)
            let secondHalf = sentiments.suffix(sentiments.count - midpoint)
            let avgFirst = firstHalf.map(\.score).reduce(0, +) / Double(firstHalf.count)
            let avgSecond = secondHalf.map(\.score).reduce(0, +) / Double(secondHalf.count)
            let shift = avgSecond - avgFirst
            if abs(shift) > 0.3 {
                let direction = shift > 0 ? "positive" : "negative"
                findings.append(BackgroundFinding(
                    category: "sentiment",
                    title: "Sentiment Shift Detected",
                    detail: "Overall tone shifted \(direction) by \(String(format: "%.1f", abs(shift) * 100))%",
                    severity: min(abs(shift), 1.0),
                    timestamp: timestamp
                ))
            }
        }

        // 5. Knowledge graph update
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            await updateKnowledgeGraph(emails: emails)
        }
        #endif

        // 6. New domain burst detection
        var domainFirstSeen: [String: Int] = [:]
        for email in emails {
            if let from = email.headers["From"],
               let domain = from.components(separatedBy: "@").last?.lowercased().trimmingCharacters(in: .punctuationCharacters) {
                domainFirstSeen[domain, default: 0] += 1
            }
        }
        let burstDomains = domainFirstSeen.filter { $0.value >= 10 }.sorted { $0.value > $1.value }
        if burstDomains.count > 3 {
            findings.append(BackgroundFinding(
                category: "domains",
                title: "\(burstDomains.count) High-Volume External Domains",
                detail: burstDomains.prefix(5).map { "\($0.key) (\($0.value))" }.joined(separator: ", "),
                severity: 0.4,
                timestamp: timestamp
            ))
        }

        // Sort by severity
        findings.sort { $0.severity > $1.severity }

        lastRunFindings = findings
        lastRunDate = timestamp
        isRunning = false

        cacheFindings(findings)

        // Send notifications for high-severity findings
        let notificationManager = SmartNotificationManager()
        for finding in findings where finding.severity >= 0.6 {
            let alert = SmartAlert(
                type: alertType(for: finding.category),
                severity: finding.severity >= 0.8 ? .high : .medium,
                title: finding.title,
                message: finding.detail
            )
            notificationManager.sendLocalNotification(for: alert)
        }

        logger.info("Background analysis complete: \(findings.count) findings")
    }

    private func alertType(for category: String) -> SmartAlertType {
        switch category {
        case "phishing": return .phishingDetected
        case "pii": return .piiExposure
        case "sentiment": return .sentimentShift
        case "domains": return .newSenderBurst
        default: return .unusualVolume
        }
    }

    // MARK: - Knowledge Graph Update

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private func updateKnowledgeGraph(emails: [MBOXParser.RawEmail]) async {
        let kg = KnowledgeGraph.load()
        KnowledgeGraphBuilder.build(from: emails, into: kg)
        kg.save()
        FoundationModelEngine.setKnowledgeGraph(kg)
        logger.info("Knowledge graph updated: \(kg.allNodes.count) nodes, \(kg.allEdges.count) edges")
    }
    #endif

    // MARK: - Email Access

    private func currentArchiveEmails() -> [MBOXParser.RawEmail] {
        EmailPersistence.load().emails
    }

    // MARK: - Persistence

    nonisolated private static var cacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("background_findings.json")
    }

    private struct CachedFindings: Codable {
        let findings: [CachedFinding]
        let lastRun: Date
    }

    private struct CachedFinding: Codable {
        let category: String
        let title: String
        let detail: String
        let severity: Double
        let timestamp: Date
    }

    private func cacheFindings(_ findings: [BackgroundFinding]) {
        let cached = CachedFindings(
            findings: findings.map { CachedFinding(category: $0.category, title: $0.title, detail: $0.detail, severity: $0.severity, timestamp: $0.timestamp) },
            lastRun: Date()
        )
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    private func loadCachedFindings() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode(CachedFindings.self, from: data) else { return }
        lastRunFindings = cached.findings.map {
            BackgroundFinding(category: $0.category, title: $0.title, detail: $0.detail, severity: $0.severity, timestamp: $0.timestamp)
        }
    }

    // MARK: - For AI Digest Integration

    nonisolated static func cachedFindingsForDigest() -> [(category: String, title: String, detail: String, severity: Double)] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedFindings.self, from: data) else { return [] }
        return cached.findings.filter { $0.severity >= 0.4 }.map {
            (category: $0.category, title: $0.title, detail: $0.detail, severity: $0.severity)
        }
    }
}
