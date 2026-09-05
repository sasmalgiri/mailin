#if !OFFLINE_MODE
import Foundation
import os

enum CloudAIProviderType: String, CaseIterable, Codable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"

    var displayName: String { rawValue }

    var defaultModels: [String] {
        switch self {
        case .openAI: return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o4-mini"]
        case .anthropic: return ["claude-sonnet-4-5-20250514", "claude-haiku-4-5-20251001", "claude-opus-4-5-20250514"]
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-5-20250514"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        }
    }
}

@MainActor
final class CloudAIManager: ObservableObject {
    static let shared = CloudAIManager()

    @Published var selectedProvider: CloudAIProviderType {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "cloudAIProvider") }
    }
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "cloudAIModel") }
    }
    @Published var isEnabled: Bool {
        didSet {
            // E1 hard gate: a managed "disableCloudAI" policy wins over any
            // UI toggle — the org's off is not user-overridable.
            if isEnabled && ManagedConfig.disableCloudAI {
                isEnabled = false
                return
            }
            UserDefaults.standard.set(isEnabled, forKey: "cloudAIEnabled")
        }
    }

    /// True when MDM policy forbids cloud AI (used by Settings to explain
    /// why the toggle is disabled).
    var isDisabledByPolicy: Bool { ManagedConfig.disableCloudAI }
    @Published var preferCloudAI: Bool {
        didSet { UserDefaults.standard.set(preferCloudAI, forKey: "cloudAIPreferred") }
    }

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "CloudAI")

    private init() {
        let providerRaw = UserDefaults.standard.string(forKey: "cloudAIProvider") ?? CloudAIProviderType.openAI.rawValue
        self.selectedProvider = CloudAIProviderType(rawValue: providerRaw) ?? .openAI
        self.selectedModel = UserDefaults.standard.string(forKey: "cloudAIModel") ?? CloudAIProviderType.openAI.defaultModel
        // E1 hard gate: managed installs with disableCloudAI start (and stay) off.
        self.isEnabled = ManagedConfig.disableCloudAI
            ? false
            : UserDefaults.standard.bool(forKey: "cloudAIEnabled")
        self.preferCloudAI = UserDefaults.standard.bool(forKey: "cloudAIPreferred")
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    var apiKey: String {
        get { KeychainHelper.load(key: keychainKey) }
        set { KeychainHelper.save(key: keychainKey, value: newValue) }
    }

    private var keychainKey: String {
        "cloudAI_\(selectedProvider.rawValue)_apiKey"
    }

    func apiKeyFor(_ provider: CloudAIProviderType) -> String {
        KeychainHelper.load(key: "cloudAI_\(provider.rawValue)_apiKey")
    }

    func setAPIKey(_ key: String, for provider: CloudAIProviderType) {
        KeychainHelper.save(key: "cloudAI_\(provider.rawValue)_apiKey", value: key)
        if provider == selectedProvider {
            objectWillChange.send()
        }
    }

    func clearAPIKey(for provider: CloudAIProviderType) {
        KeychainHelper.delete(key: "cloudAI_\(provider.rawValue)_apiKey")
        objectWillChange.send()
    }

    var isReady: Bool {
        !ManagedConfig.disableCloudAI && isEnabled && hasAPIKey
    }

    // MARK: - Chat Completion

    func sendMessage(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int = 2048
    ) async throws -> String {
        guard isReady else { throw CloudAIError.notConfigured }

        let key = apiKey
        guard !key.isEmpty else { throw CloudAIError.noAPIKey }

        switch selectedProvider {
        case .openAI:
            return try await sendOpenAI(systemPrompt: systemPrompt, userMessage: userMessage, apiKey: key, maxTokens: maxTokens)
        case .anthropic:
            return try await sendAnthropic(systemPrompt: systemPrompt, userMessage: userMessage, apiKey: key, maxTokens: maxTokens)
        }
    }

    func sendMessageStreaming(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int = 2048,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        guard isReady else { throw CloudAIError.notConfigured }

        let key = apiKey
        guard !key.isEmpty else { throw CloudAIError.noAPIKey }

        switch selectedProvider {
        case .openAI:
            return try await streamOpenAI(systemPrompt: systemPrompt, userMessage: userMessage, apiKey: key, maxTokens: maxTokens, onUpdate: onUpdate)
        case .anthropic:
            return try await streamAnthropic(systemPrompt: systemPrompt, userMessage: userMessage, apiKey: key, maxTokens: maxTokens, onUpdate: onUpdate)
        }
    }

    // MARK: - OpenAI

    private func sendOpenAI(systemPrompt: String, userMessage: String, apiKey: String, maxTokens: Int) async throws -> String {
        let url = URL(string: CloudAIProviderType.openAI.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.7
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CloudAIError.invalidResponse
        }
        return content
    }

    private func streamOpenAI(systemPrompt: String, userMessage: String, apiKey: String, maxTokens: Int, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let url = URL(string: CloudAIProviderType.openAI.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.7,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw CloudAIError.httpError(httpResponse.statusCode)
        }

        var accumulated = ""
        for try await line in stream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr == "[DONE]" { break }
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            accumulated += content
            onUpdate(accumulated)
        }
        return accumulated
    }

    // MARK: - Anthropic

    private func sendAnthropic(systemPrompt: String, userMessage: String, apiKey: String, maxTokens: Int) async throws -> String {
        let url = URL(string: CloudAIProviderType.anthropic.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": selectedModel,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw CloudAIError.invalidResponse
        }
        return text
    }

    private func streamAnthropic(systemPrompt: String, userMessage: String, apiKey: String, maxTokens: Int, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let url = URL(string: CloudAIProviderType.anthropic.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": selectedModel,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "stream": true,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw CloudAIError.httpError(httpResponse.statusCode)
        }

        var accumulated = ""
        for try await line in stream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let eventType = json["type"] as? String ?? ""
            if eventType == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                accumulated += text
                onUpdate(accumulated)
            } else if eventType == "message_stop" {
                break
            }
        }
        return accumulated
    }

    // MARK: - Helpers

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw CloudAIError.authenticationFailed
        case 429:
            throw CloudAIError.rateLimited
        case 400...499:
            // W2: never log the response body — provider error bodies can echo
            // the request prompt (email evidence content) back verbatim.
            logger.error("API error \(httpResponse.statusCode): response body \(data.count) bytes (content redacted)")
            throw CloudAIError.httpError(httpResponse.statusCode)
        default:
            throw CloudAIError.httpError(httpResponse.statusCode)
        }
    }
}

enum CloudAIError: LocalizedError {
    case notConfigured
    case noAPIKey
    case authenticationFailed
    case rateLimited
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud AI is not configured. Add an API key in Settings."
        case .noAPIKey: return "No API key found. Add your API key in Settings > AI."
        case .authenticationFailed: return "API key is invalid. Check your key in Settings > AI."
        case .rateLimited: return "Rate limit exceeded. Please wait a moment and try again."
        case .invalidResponse: return "Unexpected response from the AI provider."
        case .httpError(let code): return "API error (HTTP \(code)). Please try again."
        }
    }
}

// MARK: - Email-Specific Cloud AI Helpers

extension CloudAIManager {

    private static let emailSystemPrompt = """
    You are an intelligent email analysis assistant integrated into a professional email forensics and management app called mailin. \
    You help users understand, search, triage, and analyze their email archives. \
    Be concise, accurate, and helpful. Use markdown formatting for readability. \
    When analyzing emails, cite specific subjects, senders, and dates as evidence.
    """

    func analyzeEmails(query: String, emailContext: String, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let userMessage = """
        Here are the relevant emails from my archive:

        \(emailContext)

        My question: \(query)
        """
        return try await sendMessageStreaming(
            systemPrompt: Self.emailSystemPrompt,
            userMessage: userMessage,
            onUpdate: onUpdate
        )
    }

    func triageEmails(emailContext: String, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let userMessage = """
        Here are emails to triage:

        \(emailContext)

        Please prioritize these emails by urgency. For each, provide:
        1. Subject and sender
        2. Why it's important
        3. Recommended action
        4. Urgency level (Act Now / Today / This Week)
        """
        return try await sendMessageStreaming(
            systemPrompt: Self.emailSystemPrompt,
            userMessage: userMessage,
            onUpdate: onUpdate
        )
    }

    func generateInsights(emailContext: String, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let userMessage = """
        Here are emails from an archive:

        \(emailContext)

        Analyze these emails and provide:
        1. Key patterns or trends
        2. Anomalies or unusual items
        3. Action items that may need attention
        4. Overall health assessment of this email activity
        """
        return try await sendMessageStreaming(
            systemPrompt: Self.emailSystemPrompt,
            userMessage: userMessage,
            onUpdate: onUpdate
        )
    }

    func securityBrief(emailContext: String, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let userMessage = """
        Here are emails to analyze for security:

        \(emailContext)

        Provide a security brief:
        1. Flag any phishing or scam indicators
        2. Identify suspicious senders or patterns
        3. Note any PII exposure risks
        4. Rate overall security posture (Safe / Caution / At Risk)
        """
        return try await sendMessageStreaming(
            systemPrompt: Self.emailSystemPrompt,
            userMessage: userMessage,
            onUpdate: onUpdate
        )
    }

    func suggestReply(emailContext: String, tone: String, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let userMessage = """
        Here is an email I need to reply to:

        \(emailContext)

        Please draft a \(tone) reply. Keep it concise and professional.
        """
        return try await sendMessageStreaming(
            systemPrompt: Self.emailSystemPrompt,
            userMessage: userMessage,
            onUpdate: onUpdate
        )
    }

    func summarizeEmails(emailContext: String) async throws -> String {
        let userMessage = """
        Summarize the following emails concisely:

        \(emailContext)

        Provide a brief digest with key takeaways, action items, and notable communications.
        """
        return try await sendMessage(
            systemPrompt: Self.emailSystemPrompt,
            userMessage: userMessage
        )
    }

    nonisolated static func buildEmailContext(from emails: [MBOXParser.RawEmail], maxEmails: Int = 20) -> String {
        emails.prefix(maxEmails).enumerated().map { index, email in
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let date = email.headers["Date"] ?? ""
            let body = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
            return "[\(index + 1)] Subject: \(subj)\nFrom: \(from)\nDate: \(date)\nBody: \(body)"
        }.joined(separator: "\n\n---\n\n")
    }
}

// MARK: - MoE Expert Methods (Cloud-Powered)

extension CloudAIManager {

    enum CloudExpertRole: String, CaseIterable, Sendable {
        case sentiment = "Sentiment & Emotional Intelligence"
        case entity = "People & Relationship Analysis"
        case topic = "Content & Topic Analysis"
        case timeline = "Temporal Pattern Analysis"
        case security = "Cybersecurity & Data Protection"
        case worldKnowledge = "World Knowledge & Context"
    }

    func runExpert(
        role: CloudExpertRole,
        query: String,
        emailContext: String,
        nlpData: String
    ) async throws -> CloudExpertFinding {
        guard isReady else { throw CloudAIError.notConfigured }

        let systemPrompt: String
        switch role {
        case .sentiment:
            systemPrompt = """
                You are a senior sentiment and emotional intelligence expert in an email forensics application. \
                Go beyond basic positive/negative classification. Analyze: \
                1) Emotional trajectory across threads — trace escalation from professional to heated, or de-escalation after intervention. \
                2) Micro-expressions in text — passive aggression ("per my last email"), veiled threats ("I'll have to escalate"), and strategic politeness masking frustration. \
                3) Relationship dynamics — power imbalances revealed through deference patterns, tone asymmetry between sender pairs, and emotional labor distribution. \
                4) Anomaly detection — flag when a normally calm sender becomes emotional, or when emotional language appears in typically formal channels. \
                5) Sentiment context — distinguish legitimate urgency from manufactured urgency, and professional directness from hostility. \
                Rate each finding [HIGH/MEDIUM/LOW] with evidence. Focus on patterns that reveal intent, not just surface emotion.
                """
        case .entity:
            systemPrompt = """
                You are a senior organizational intelligence analyst specializing in communication network forensics. \
                Go beyond contact listing. Analyze: \
                1) Organizational hierarchy — infer reporting structures from CC/TO patterns, reply chains, and approval flows. Identify decision-makers vs. executors. \
                2) Influence mapping — who triggers action (emails that lead to replies within minutes), who is a gatekeeper (always CC'd on approvals), who is an information broker (bridges between groups). \
                3) Network evolution — detect relationship changes over time: new alliances, broken connections, shifting loyalties, or organizational restructuring signals. \
                4) Hidden networks — BCC patterns, forwarding chains, and parallel communication channels that suggest shadow decision-making. \
                5) External entity analysis — use your world knowledge to identify known organizations, public figures, or entities referenced in emails. Assess vendor/client/competitor relationships. \
                Rate each finding [HIGH/MEDIUM/LOW] with evidence.
                """
        case .topic:
            systemPrompt = """
                You are a senior content intelligence analyst specializing in thematic analysis of email communications. \
                Go beyond keyword extraction. Analyze: \
                1) Strategic topic mapping — build a hierarchical topic taxonomy showing major initiatives, sub-projects, and cross-cutting concerns. Identify how topics relate to each other. \
                2) Topic lifecycle analysis — track each topic from emergence through peak activity to resolution or abandonment. Flag topics that were discussed but never resolved. \
                3) Decision archaeology — identify emails where decisions were made, commitments given, or directions changed. Note who drove each decision. \
                4) Information flow — trace how ideas propagate: who introduces topics, who amplifies them, who blocks or redirects them. \
                5) Gap analysis — identify questions asked but never answered, action items assigned but never followed up, and topics that disappeared without resolution. \
                6) Industry context — use your world knowledge to identify references to industry trends, regulatory changes, competitive events, or market conditions. \
                Rate each finding [HIGH/MEDIUM/LOW] with evidence.
                """
        case .timeline:
            systemPrompt = """
                You are a senior temporal intelligence analyst specializing in chronological pattern analysis of email communications. \
                Go beyond simple timeline listing. Analyze: \
                1) Behavioral baselines — establish normal communication patterns per sender (active hours, typical volume, response latency) and flag deviations. \
                2) Crisis detection — identify burst patterns (rapid exchanges) that indicate real-time incidents, escalations, or urgent collaboration. \
                3) Response priority mapping — measure who gets fast replies vs. slow replies from each sender, revealing true priorities vs. stated priorities. \
                4) Cadence disruption — detect when regular communication patterns break (weekly reports that stop, daily standups that become sporadic). \
                5) Correlation analysis — link timing anomalies to content: do late-night emails correlate with specific topics? Do volume spikes precede deadlines or follow external events? \
                6) Absence intelligence — identify gaps in communication and what happened before/after them (vacations, conflicts, project transitions). \
                Rate each finding [HIGH/MEDIUM/LOW] with evidence.
                """
        case .security:
            systemPrompt = """
                You are a senior cybersecurity threat analyst with expertise in email-based attacks, social engineering, and data protection compliance. \
                Leverage your world knowledge of known threat actors, attack campaigns, and indicators of compromise. Analyze: \
                1) Phishing and impersonation — detect display name spoofing, typosquatting domains (e.g., rnicrosoft.com), conversation hijacking, and business email compromise (BEC) patterns. Use your knowledge of known phishing campaigns and tactics. \
                2) Social engineering — identify pretexting (fake scenarios), authority impersonation, artificial urgency, unusual financial requests, and trust exploitation sequences across multiple emails. \
                3) Data exfiltration — flag sensitive data in transit: PII (SSN, passport, credit card patterns), credentials, API keys, source code, or proprietary information sent to external or personal domains. \
                4) Insider threat indicators — detect unusual forwarding to personal accounts, large attachment transfers, access to data outside normal scope, or communication with competitors. \
                5) Compliance violations — identify GDPR-regulated personal data, HIPAA health information, SOX financial data, or PCI cardholder data transmitted without appropriate safeguards. \
                6) Domain and sender intelligence — use your knowledge of known malicious domains, disposable email services, and suspicious TLDs to assess sender credibility. \
                Rate each finding as Critical/High/Medium/Low with specific remediation steps.
                """
        case .worldKnowledge:
            systemPrompt = """
                You are a senior contextual intelligence analyst. Your unique value is providing context that no on-device model can: \
                real-world knowledge about people, organizations, events, and industries referenced in emails. Analyze: \
                1) Entity identification — identify public figures, executives, politicians, or notable individuals mentioned. Provide relevant background (role, organization, public profile). \
                2) Organization intelligence — identify companies, agencies, NGOs, or institutions referenced. Note their industry, size, reputation, and any relevant news (mergers, lawsuits, regulatory actions). \
                3) Event correlation — connect email discussions to known public events: news stories, regulatory changes, market events, product launches, industry conferences, or legal proceedings. \
                4) Regulatory context — identify references to laws, regulations, or compliance frameworks (GDPR, HIPAA, SOX, CCPA) and note their implications for the email content. \
                5) Industry analysis — place email discussions in their industry context: competitive landscape, market trends, standard practices, or emerging disruptions. \
                6) Cultural and geographic context — note cultural norms, regional business practices, or geopolitical factors that affect interpretation of the communications. \
                Rate each finding [HIGH/MEDIUM/LOW] with evidence. Focus on insights that add depth impossible to derive from the email text alone.
                """
        }

        let userMessage = """
            NLP Pre-Analysis:
            \(nlpData)

            Emails:
            \(emailContext)

            User question: \(query)

            Produce 3-5 structured findings. Each finding must be one specific, evidence-backed sentence. \
            Rate each as HIGH, MEDIUM, or LOW relevance. Format:
            [HIGH/MEDIUM/LOW] Finding text — Evidence: (email subject or sender)
            End with CONFIDENCE: 1-5 and a one-line SUMMARY.
            """

        let response = try await sendMessage(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxTokens: 1024
        )

        return CloudExpertFinding(role: role, rawResponse: response)
    }

    func synthesizeWithCloud(
        query: String,
        nlpBaseline: String,
        expertFindings: String,
        ragAnalysis: String,
        emailContext: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        guard isReady else { throw CloudAIError.notConfigured }

        let systemPrompt = """
            You are the synthesis brain of mailin, a privacy-first email forensics app. \
            A multi-layer hybrid AI pipeline has produced multiple analyses: \
            an NLP baseline (deterministic, verified), agentic RAG retrieval, and parallel expert findings. \
            Your job: synthesize ALL sources into one coherent, evidence-rich answer that IMPROVES on each individual source. \
            Rules: \
            - Reference emails by **Subject** and **sender** in bold \
            - Every claim must trace to an email or finding \
            - Use NLP baseline numbers as ground truth (they're deterministic) \
            - Add expert insights that go beyond what NLP found \
            - Be conversational, like a colleague who analyzed everything thoroughly \
            - Structure with bullet points or numbered lists for complex answers
            """

        let userMessage = """
            User question: \(query)

            NLP BASELINE (deterministic, verified):
            \(String(nlpBaseline.prefix(800)))

            RAG ANALYSIS:
            \(String(ragAnalysis.prefix(800)))

            EXPERT FINDINGS:
            \(String(expertFindings.prefix(2000)))

            EMAILS:
            \(String(emailContext.prefix(2000)))
            """

        return try await sendMessageStreaming(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxTokens: 2048,
            onUpdate: onUpdate
        )
    }

    func crossValidate(
        answer: String,
        query: String,
        emailContext: String
    ) async throws -> CloudValidationResult {
        guard isReady else { throw CloudAIError.notConfigured }

        let systemPrompt = """
            You are a quality-assurance reviewer for an AI email analysis system. \
            Given an answer produced by on-device AI, verify its accuracy and completeness. \
            Check: Are claims supported by the emails? Are there factual errors? What's missing? \
            Be brief and specific.
            """

        let userMessage = """
            Question: \(query)

            Answer to verify:
            \(String(answer.prefix(1500)))

            Source emails:
            \(String(emailContext.prefix(2000)))

            Respond with:
            ACCURATE: YES/PARTIAL/NO
            ISSUES: (list any factual errors or unsupported claims, or "none")
            MISSING: (key information the answer missed, or "none")
            CONFIDENCE: 1-5
            """

        let response = try await sendMessage(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxTokens: 512
        )

        return CloudValidationResult(rawResponse: response)
    }
}

// MARK: - Cloud Expert Data Types

struct CloudExpertFinding: Sendable {
    let role: CloudAIManager.CloudExpertRole
    let rawResponse: String

    var findings: [(relevance: String, finding: String, evidence: String)] {
        rawResponse.components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") }
            .compactMap { line in
                guard let closeBracket = line.firstIndex(of: "]") else { return nil }
                let relevance = String(line[line.index(after: line.startIndex)..<closeBracket])
                let rest = String(line[line.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
                let parts = rest.components(separatedBy: " — Evidence: ")
                let finding = parts.first ?? rest
                let evidence = parts.count > 1 ? parts[1] : ""
                return (relevance, finding, evidence)
            }
    }

    var confidence: Int {
        if let range = rawResponse.range(of: #"CONFIDENCE:\s*(\d)"#, options: .regularExpression) {
            let match = rawResponse[range]
            let digit = match.filter(\.isNumber)
            return Int(digit) ?? 3
        }
        return 3
    }

    var summary: String {
        if let range = rawResponse.range(of: #"SUMMARY:.*"#, options: .regularExpression) {
            return String(rawResponse[range]).replacingOccurrences(of: "SUMMARY:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    func asFormattedText() -> String {
        var text = "**\(role.rawValue)** (confidence: \(confidence)/5):\n"
        for f in findings {
            let icon = f.relevance == "HIGH" ? "▲" : f.relevance == "MEDIUM" ? "●" : "▽"
            text += "\(icon) \(f.finding)"
            if !f.evidence.isEmpty { text += " — \(f.evidence)" }
            text += "\n"
        }
        if !summary.isEmpty { text += "_\(summary)_\n" }
        return text
    }
}

struct CloudValidationResult: Sendable {
    let rawResponse: String

    var isAccurate: Bool {
        rawResponse.contains("ACCURATE: YES")
    }

    var isPartial: Bool {
        rawResponse.contains("ACCURATE: PARTIAL")
    }

    var issues: String {
        extractField("ISSUES")
    }

    var missing: String {
        extractField("MISSING")
    }

    var confidence: Int {
        if let range = rawResponse.range(of: #"CONFIDENCE:\s*(\d)"#, options: .regularExpression) {
            let digit = rawResponse[range].filter(\.isNumber)
            return Int(digit) ?? 3
        }
        return 3
    }

    private func extractField(_ name: String) -> String {
        if let range = rawResponse.range(of: "\(name):.*", options: .regularExpression) {
            return String(rawResponse[range])
                .replacingOccurrences(of: "\(name):", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}

#endif
