import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Agentic Plan @Generable Types (v3.3.1)

@available(macOS 26, iOS 26, *)
@Generable
enum AgenticStepType: String {
    case searchEmails
    case filterByDate
    case analyzeSentiment
    case analyzeEntities
    case analyzeTopics
    case analyzeSecurity
    case summarize
    case draftResponse
    // v4.5.2: State-modifying NL actions
    case exportEmails
    case tagEmails
    case redactPII
    case createBatch
}

@available(macOS 26, iOS 26, *)
@Generable(description: "A single step in an agentic email analysis workflow")
struct AgenticStep {
    var stepType: AgenticStepType
    @Guide(description: "What this step accomplishes")
    var description: String
    @Guide(description: "Parameters: search terms, date range, focus area, etc.")
    var parameters: String
}

@available(macOS 26, iOS 26, *)
@Generable(description: "A multi-step plan for complex email analysis")
struct AgenticPlan {
    @Guide(description: "Is this query complex enough to need sequential steps?")
    var needsAgenticPlan: Bool
    @Guide(description: "Steps to execute in order, each builds on previous results", .maximumCount(6))
    var steps: [AgenticStep]
    @Guide(description: "The final goal to achieve")
    var goal: String
}

// MARK: - Step Execution Result

@available(macOS 26, iOS 26, *)
struct StepResult: Sendable {
    let stepIndex: Int
    let stepType: AgenticStepType
    let description: String
    let emailCount: Int
    let emailIDs: [UUID]
    let textOutput: String
    let metrics: [String: Int]
}

// MARK: - Agentic Planner

@available(macOS 26, iOS 26, *)
struct AgenticPlanner {

    private static let destructiveStepTypes: Set<AgenticStepType> = [.tagEmails, .createBatch, .redactPII, .exportEmails]

    private static func isDestructive(_ stepType: AgenticStepType) -> Bool {
        destructiveStepTypes.contains(stepType)
    }

    private static func confirmationDescription(for step: AgenticStep, emailCount: Int) -> String {
        switch step.stepType {
        case .tagEmails:
            return "Tag \(emailCount) email\(emailCount == 1 ? "" : "s") as \(step.parameters)"
        case .createBatch:
            return "Create review batches from \(emailCount) email\(emailCount == 1 ? "" : "s")"
        case .redactPII:
            return "Scan and preview PII redactions in \(emailCount) email\(emailCount == 1 ? "" : "s")"
        case .exportEmails:
            return "Prepare export of \(emailCount) email\(emailCount == 1 ? "" : "s")"
        default:
            return step.description
        }
    }

    // MARK: - Plan Generation

    static func generatePlan(
        query: String,
        emails: [MBOXParser.RawEmail],
        profile: String
    ) async -> AgenticPlan? {
        guard FoundationModelEngine.isAvailable else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
                You decompose complex email questions into sequential steps. \
                Each step builds on previous results. Use searchEmails first to find relevant emails, \
                then filter/analyze, then summarize or draftResponse. Max 6 steps. \
                Only set needsAgenticPlan=true for queries needing 3+ distinct sequential operations. \
                Simple questions like "summarize my emails" do NOT need agentic plans. \
                Action steps available: exportEmails (CSV/vCard/ICS), tagEmails (relevant/privileged/suspicious/flagged), \
                redactPII (scan and preview redactions), createBatch (group for review). \
                Use action steps when the user asks to export, tag, redact, or batch emails.
                """)

            let archiveSummary = String(profile.prefix(300))
            let prompt = """
                Archive: \(emails.count) emails. \(archiveSummary)

                Query: \(query)

                Create a plan ONLY if this needs multiple sequential steps (e.g., "find X, analyze Y, then draft Z"). \
                Set needsAgenticPlan=false for simple analytical questions.
                """

            let response = try await session.respond(to: prompt, generating: AgenticPlan.self)
            let plan = response.content

            guard plan.needsAgenticPlan, plan.steps.count >= 2 else { return nil }
            return plan
        } catch {
            return nil
        }
    }

    // MARK: - Plan Execution

    static func executePlan(
        plan: AgenticPlan,
        query: String,
        emails: [MBOXParser.RawEmail],
        profile: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void,
        onConfirmAction: (@MainActor @Sendable (String) async -> Bool)? = nil
    ) async throws -> String {
        let totalSteps = plan.steps.count
        var stepResults: [StepResult] = []
        var workingEmails = emails
        var progressLines = plan.steps.enumerated().map { (i, step) in
            "[ ] Step \(i + 1)/\(totalSteps): \(step.description)"
        }

        let header = "**Agentic Plan** — \(totalSteps) steps → *\(plan.goal)*\n\n"
        await onUpdate(header + progressLines.joined(separator: "\n") + "\n")

        for (i, step) in plan.steps.enumerated() {
            if isDestructive(step.stepType) {
                let desc = confirmationDescription(for: step, emailCount: workingEmails.count)
                if let confirm = onConfirmAction {
                    let approved = await confirm(desc)
                    if !approved {
                        let skipped = StepResult(
                            stepIndex: i, stepType: step.stepType, description: step.description,
                            emailCount: 0, emailIDs: [],
                            textOutput: "⏭ Skipped: \(step.description) — user declined.",
                            metrics: ["skipped": 1]
                        )
                        stepResults.append(skipped)
                        progressLines[i] = "[–] Step \(i + 1)/\(totalSteps): \(step.description) — skipped by user"
                        await onUpdate(header + progressLines.joined(separator: "\n") + "\n")
                        continue
                    }
                } else {
                    await onUpdate(header + progressLines.joined(separator: "\n") + "\n\n⚠️ **Confirmation needed**: \(desc)\n")
                }
            }

            let result = await executeStep(
                step: step,
                stepIndex: i,
                previousResults: stepResults,
                workingEmails: workingEmails,
                allEmails: emails,
                profile: profile
            )

            stepResults.append(result)

            if !result.emailIDs.isEmpty {
                let idSet = Set(result.emailIDs)
                let filtered = emails.filter { idSet.contains($0.id) }
                if !filtered.isEmpty {
                    workingEmails = filtered
                }
            }

            let metricsStr = result.metrics.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            progressLines[i] = "[x] Step \(i + 1)/\(totalSteps): \(step.description) — \(metricsStr.isEmpty ? "done" : metricsStr)"

            let progressText = header + progressLines.joined(separator: "\n") + "\n\n"
            let resultsPreview = stepResults.map { r in
                "**Step \(r.stepIndex + 1)** (\(r.stepType.rawValue)): \(String(r.textOutput.prefix(150)))"
            }.joined(separator: "\n")

            await onUpdate(progressText + resultsPreview + "\n")
        }

        await onUpdate(header + progressLines.joined(separator: "\n") + "\n\n*Synthesizing final answer...*\n")

        let answer = try await synthesizeAgenticResults(
            plan: plan,
            query: query,
            stepResults: stepResults,
            profile: profile,
            onUpdate: onUpdate
        )

        return answer
    }

    // MARK: - Step Dispatch

    private static func executeStep(
        step: AgenticStep,
        stepIndex: Int,
        previousResults: [StepResult],
        workingEmails: [MBOXParser.RawEmail],
        allEmails: [MBOXParser.RawEmail],
        profile: String
    ) async -> StepResult {
        switch step.stepType {
        case .searchEmails:
            return executeSearch(step: step, stepIndex: stepIndex, emails: allEmails)
        case .filterByDate:
            return executeFilterByDate(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .analyzeSentiment:
            return executeSentimentAnalysis(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .analyzeEntities:
            return executeEntityAnalysis(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .analyzeTopics:
            return executeTopicAnalysis(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .analyzeSecurity:
            return executeSecurityAnalysis(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .summarize:
            return await executeSummarize(step: step, stepIndex: stepIndex, emails: workingEmails, previousResults: previousResults, profile: profile)
        case .draftResponse:
            return await executeDraftResponse(step: step, stepIndex: stepIndex, emails: workingEmails, previousResults: previousResults, profile: profile)
        // v4.5.2: NL action steps
        case .exportEmails:
            return await executeExportEmails(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .tagEmails:
            return await executeTagEmails(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .redactPII:
            return executeRedactPII(step: step, stepIndex: stepIndex, emails: workingEmails)
        case .createBatch:
            return await executeCreateBatch(step: step, stepIndex: stepIndex, emails: workingEmails)
        }
    }

    // MARK: - Search Step

    private static func executeSearch(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        let terms = EmailNLPEngine.extractSearchTerms(from: step.parameters)
        var results: [MBOXParser.RawEmail] = []

        if !terms.isEmpty {
            let indexed = EmailSearchIndex.shared.hybridSearch(query: step.parameters, terms: terms, limit: 20)
            results = indexed.map(\.email)
        }

        if results.isEmpty {
            let nlpResults = EmailNLPEngine.searchEmails(
                terms: terms.isEmpty ? [step.parameters] : terms,
                in: emails, limit: 20
            )
            results = nlpResults.map(\.email)
        }

        let preview = results.prefix(5).compactMap { $0.headers["Subject"] }.joined(separator: "; ")

        return StepResult(
            stepIndex: stepIndex,
            stepType: .searchEmails,
            description: step.description,
            emailCount: results.count,
            emailIDs: results.map(\.id),
            textOutput: "Found \(results.count) emails matching \"\(step.parameters)\". Top: \(preview)",
            metrics: ["found": results.count]
        )
    }

    // MARK: - Filter by Date Step

    private static func executeFilterByDate(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        let params = step.parameters.lowercased()
        let calendar = Calendar.current
        let now = Date()

        var startDate: Date?
        var endDate: Date? = now

        if params.contains("last week") || params.contains("past week") {
            startDate = calendar.date(byAdding: .day, value: -7, to: now)
        } else if params.contains("last month") || params.contains("past month") {
            startDate = calendar.date(byAdding: .month, value: -1, to: now)
        } else if params.contains("last quarter") || params.contains("past quarter") || params.contains("past 3 months") {
            startDate = calendar.date(byAdding: .month, value: -3, to: now)
        } else if params.contains("last year") || params.contains("past year") {
            startDate = calendar.date(byAdding: .year, value: -1, to: now)
        } else if params.contains("this year") {
            startDate = calendar.date(from: calendar.dateComponents([.year], from: now))
        } else if params.contains("this month") {
            startDate = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        } else {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            let range = NSRange(params.startIndex..<params.endIndex, in: params)
            let matches = detector?.matches(in: params, range: range) ?? []
            if let first = matches.first?.date {
                startDate = first
                if matches.count > 1, let second = matches.last?.date {
                    endDate = second
                }
            }
        }

        let dateFormatters: [DateFormatter] = {
            let f1 = DateFormatter()
            f1.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            let f2 = DateFormatter()
            f2.dateFormat = "dd MMM yyyy HH:mm:ss Z"
            return [f1, f2]
        }()
        let isoFormatter = ISO8601DateFormatter()

        func parseEmailDate(_ str: String) -> Date? {
            let cleaned = str.trimmingCharacters(in: .whitespaces)
            for fmt in dateFormatters {
                if let d = fmt.date(from: cleaned) { return d }
            }
            return isoFormatter.date(from: cleaned)
        }

        let filtered: [MBOXParser.RawEmail]
        if let start = startDate {
            filtered = emails.filter { email in
                guard let dateStr = email.headers["Date"],
                      let emailDate = parseEmailDate(dateStr) else { return false }
                if let end = endDate {
                    return emailDate >= start && emailDate <= end
                }
                return emailDate >= start
            }
        } else {
            filtered = emails
        }

        return StepResult(
            stepIndex: stepIndex,
            stepType: .filterByDate,
            description: step.description,
            emailCount: filtered.count,
            emailIDs: filtered.map(\.id),
            textOutput: "Filtered \(emails.count) → \(filtered.count) emails for period: \(step.parameters)",
            metrics: ["before": emails.count, "after": filtered.count]
        )
    }

    // MARK: - Sentiment Analysis Step

    private static func executeSentimentAnalysis(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        let emailsToAnalyze = Array(emails.prefix(50))
        let sentiments = EmailNLPEngine.analyzeSentiment(of: emailsToAnalyze)

        let positive = sentiments.filter { $0.score > 0.2 }.count
        let negative = sentiments.filter { $0.score < -0.2 }.count
        let neutral = sentiments.count - positive - negative

        let avgScore = sentiments.isEmpty ? 0.0 : sentiments.reduce(0.0) { $0 + $1.score } / Double(sentiments.count)
        let avgLabel = avgScore > 0.2 ? "positive" : avgScore < -0.2 ? "negative" : "neutral"

        let mostPositive = sentiments.max(by: { $0.score < $1.score })
        let mostNegative = sentiments.min(by: { $0.score < $1.score })

        var output = "Sentiment of \(emailsToAnalyze.count) emails: \(positive) positive, \(neutral) neutral, \(negative) negative (avg: \(avgLabel), \(String(format: "%.2f", avgScore)))"
        if let mp = mostPositive {
            output += "\nMost positive: \"\(mp.email.headers["Subject"] ?? "?")\" (\(String(format: "%.2f", mp.score)))"
        }
        if let mn = mostNegative, mn.score < -0.1 {
            output += "\nMost negative: \"\(mn.email.headers["Subject"] ?? "?")\" (\(String(format: "%.2f", mn.score)))"
        }

        return StepResult(
            stepIndex: stepIndex,
            stepType: .analyzeSentiment,
            description: step.description,
            emailCount: emailsToAnalyze.count,
            emailIDs: emailsToAnalyze.map(\.id),
            textOutput: output,
            metrics: ["positive": positive, "neutral": neutral, "negative": negative]
        )
    }

    // MARK: - Entity Analysis Step

    private static func executeEntityAnalysis(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        let emailsToAnalyze = Array(emails.prefix(50))
        let entities = EmailNLPEngine.extractEntities(from: emailsToAnalyze)

        var grouped: [String: [(String, Int)]] = [:]
        for entity in entities.prefix(30) {
            grouped[entity.type, default: []].append((entity.name, entity.count))
        }

        var output = "Entities from \(emailsToAnalyze.count) emails:\n"
        for (type, items) in grouped.sorted(by: { $0.key < $1.key }) {
            let top = items.sorted(by: { $0.1 > $1.1 }).prefix(5)
            output += "  \(type): \(top.map { "\($0.0)(\($0.1))" }.joined(separator: ", "))\n"
        }

        return StepResult(
            stepIndex: stepIndex,
            stepType: .analyzeEntities,
            description: step.description,
            emailCount: emailsToAnalyze.count,
            emailIDs: emailsToAnalyze.map(\.id),
            textOutput: output,
            metrics: ["entities": entities.count, "emails": emailsToAnalyze.count]
        )
    }

    // MARK: - Topic Analysis Step

    private static func executeTopicAnalysis(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        let emailsToAnalyze = Array(emails.prefix(50))
        let topics = EmailNLPEngine.extractTopics(from: emailsToAnalyze)

        var output = "Topics from \(emailsToAnalyze.count) emails:\n"
        for topic in topics.prefix(10) {
            output += "  \u{2022} \(topic.word) (\(topic.count) mentions)\n"
        }

        return StepResult(
            stepIndex: stepIndex,
            stepType: .analyzeTopics,
            description: step.description,
            emailCount: emailsToAnalyze.count,
            emailIDs: emailsToAnalyze.map(\.id),
            textOutput: output,
            metrics: ["topics": topics.count, "emails": emailsToAnalyze.count]
        )
    }

    // MARK: - Security Analysis Step

    private static func executeSecurityAnalysis(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        let emailsToAnalyze = Array(emails.prefix(50))
        let phishingResults = EmailNLPEngine.detectPhishing(in: emailsToAnalyze)
        let piiResults = EmailNLPEngine.detectPII(in: emailsToAnalyze)

        let suspicious = phishingResults.filter { $0.riskLevel == .high || $0.riskLevel == .medium }

        var output = "Security scan of \(emailsToAnalyze.count) emails:\n"
        output += "  Phishing: \(suspicious.count) suspicious (\(phishingResults.count) scanned)\n"
        for item in suspicious.prefix(3) {
            output += "    \u{26A0} \"\(item.email.headers["Subject"] ?? "?")\" from \(item.email.headers["From"] ?? "?") — \(item.riskLevel.rawValue) risk\n"
        }

        let piiCount = piiResults.count
        if piiCount > 0 {
            let piiTypes = Set(piiResults.map { $0.type.rawValue })
            output += "  PII: \(piiCount) findings (\(piiTypes.joined(separator: ", ")))\n"
        }

        return StepResult(
            stepIndex: stepIndex,
            stepType: .analyzeSecurity,
            description: step.description,
            emailCount: emailsToAnalyze.count,
            emailIDs: emailsToAnalyze.map(\.id),
            textOutput: output,
            metrics: ["suspicious": suspicious.count, "pii": piiCount]
        )
    }

    // MARK: - Summarize Step (uses Apple AI)

    private static func executeSummarize(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail],
        previousResults: [StepResult],
        profile: String
    ) async -> StepResult {
        var context = "Previous step results:\n"
        for r in previousResults {
            context += "Step \(r.stepIndex + 1) (\(r.stepType.rawValue)): \(r.textOutput)\n\n"
        }

        context += "Relevant emails (\(emails.count)):\n"
        for email in emails.prefix(10) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let body = String(email.plainBody.prefix(150))
            context += "\u{2022} \(subj) from \(from): \(body)\n"
        }

        guard FoundationModelEngine.isAvailable else {
            let fallback = previousResults.map(\.textOutput).joined(separator: "\n")
            return StepResult(
                stepIndex: stepIndex, stepType: .summarize, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: "Summary: \(String(fallback.prefix(500)))", metrics: [:]
            )
        }

        do {
            let session = LanguageModelSession(instructions:
                "Summarize the analysis results concisely. Focus on: \(step.parameters). " +
                "Cite specific emails by subject and sender. Use bullet points."
            )
            let truncatedContext = String(context.prefix(3000))
            let response = try await session.respond(to: "Summarize these findings:\n\n\(truncatedContext)")
            return StepResult(
                stepIndex: stepIndex, stepType: .summarize, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: response.content, metrics: ["steps_summarized": previousResults.count]
            )
        } catch {
            let fallback = previousResults.map(\.textOutput).joined(separator: "\n")
            return StepResult(
                stepIndex: stepIndex, stepType: .summarize, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: String(fallback.prefix(500)), metrics: [:]
            )
        }
    }

    // MARK: - Draft Response Step (uses Apple AI)

    private static func executeDraftResponse(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail],
        previousResults: [StepResult],
        profile: String
    ) async -> StepResult {
        var context = "Analysis results:\n"
        for r in previousResults {
            context += "\(r.textOutput)\n\n"
        }

        if let target = emails.first {
            context += "Responding to: \"\(target.headers["Subject"] ?? "?")\" from \(target.headers["From"] ?? "?")\n"
            context += "Body: \(String(target.plainBody.prefix(500)))\n"
        }

        guard FoundationModelEngine.isAvailable else {
            return StepResult(
                stepIndex: stepIndex, stepType: .draftResponse, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: "[AI unavailable — draft response manually]", metrics: [:]
            )
        }

        do {
            let session = LanguageModelSession(instructions:
                "Draft a professional email response. Be concise and actionable. " +
                "Use the analysis results to inform the response. Focus: \(step.parameters)"
            )
            let truncatedContext = String(context.prefix(3000))
            let response = try await session.respond(to: "Draft a response based on:\n\n\(truncatedContext)")
            return StepResult(
                stepIndex: stepIndex, stepType: .draftResponse, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: response.content, metrics: ["drafts": 1]
            )
        } catch {
            return StepResult(
                stepIndex: stepIndex, stepType: .draftResponse, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: "[Draft generation failed — compose manually]", metrics: [:]
            )
        }
    }

    // MARK: - v4.5.2: NL Action Steps

    private static func executeExportEmails(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) async -> StepResult {
        guard !emails.isEmpty else {
            return StepResult(
                stepIndex: stepIndex, stepType: .exportEmails, description: step.description,
                emailCount: 0, emailIDs: [],
                textOutput: "No emails to export.", metrics: [:]
            )
        }

        let params = step.parameters.lowercased()
        let format: String
        if params.contains("csv") || params.contains("header") {
            let csv = ExportManager.exportHeadersOnlyCSV(from: emails)
            format = "CSV"
            let output = "Prepared \(format) export of \(emails.count) email headers.\n\n**Preview** (first 500 chars):\n```\n\(String(csv.prefix(500)))\n```\n\n⚠️ **Action required**: Use File > Export Headers Only (CSV) to save to disk."
            return StepResult(
                stepIndex: stepIndex, stepType: .exportEmails, description: step.description,
                emailCount: emails.count, emailIDs: emails.map(\.id),
                textOutput: output, metrics: ["exported": emails.count, "format_csv": 1]
            )
        } else if params.contains("contact") || params.contains("vcard") {
            if let vcardData = ExportManager.exportContacts(from: emails) {
                format = "vCard"
                let output = "Prepared \(format) contact export from \(emails.count) emails (\(vcardData.count) bytes).\n\n⚠️ **Action required**: Use File > Export Contacts (vCard) to save to disk."
                return StepResult(
                    stepIndex: stepIndex, stepType: .exportEmails, description: step.description,
                    emailCount: emails.count, emailIDs: emails.map(\.id),
                    textOutput: output, metrics: ["exported": emails.count, "format_vcard": 1]
                )
            }
        } else if params.contains("calendar") || params.contains("ics") || params.contains("event") {
            let ics = ExportManager.exportCalendarEvents(from: emails)
            format = "ICS"
            let eventCount = ics.components(separatedBy: "BEGIN:VEVENT").count - 1
            let output = "Extracted \(eventCount) calendar events from \(emails.count) emails.\n\n⚠️ **Action required**: Use File > Export Calendar Events (ICS) to save."
            return StepResult(
                stepIndex: stepIndex, stepType: .exportEmails, description: step.description,
                emailCount: emails.count, emailIDs: emails.map(\.id),
                textOutput: output, metrics: ["exported": emails.count, "events": eventCount]
            )
        }

        let output = "Ready to export \(emails.count) emails. Use the Export menu (File > Export) to choose format and save.\n\n**Available formats**: CSV headers, vCard contacts, ICS calendar, MSG, PST, Relativity load file."
        return StepResult(
            stepIndex: stepIndex, stepType: .exportEmails, description: step.description,
            emailCount: emails.count, emailIDs: emails.map(\.id),
            textOutput: output, metrics: ["ready_to_export": emails.count]
        )
    }

    private static func executeTagEmails(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) async -> StepResult {
        guard !emails.isEmpty else {
            return StepResult(
                stepIndex: stepIndex, stepType: .tagEmails, description: step.description,
                emailCount: 0, emailIDs: [],
                textOutput: "No emails to tag.", metrics: [:]
            )
        }

        let params = step.parameters.lowercased()
        let tag: ForensicManager.EvidenceTag
        if params.contains("relevant") { tag = .relevant }
        else if params.contains("privileged") { tag = .privileged }
        else if params.contains("irrelevant") { tag = .irrelevant }
        else if params.contains("suspicious") { tag = .suspicious }
        else if params.contains("flag") { tag = .flagged }
        else { tag = .flagged }

        let tagCount = emails.count
        await MainActor.run {
            for email in emails {
                ForensicManager.shared.tag(email.id, as: tag)
            }
        }

        let output = "✅ Tagged \(tagCount) email\(tagCount == 1 ? "" : "s") as **\(tag.rawValue)**.\n\nTagged subjects:\n" +
            emails.prefix(10).map { "• \($0.headers["Subject"] ?? "(No Subject)")" }.joined(separator: "\n") +
            (emails.count > 10 ? "\n• ... and \(emails.count - 10) more" : "")

        return StepResult(
            stepIndex: stepIndex, stepType: .tagEmails, description: step.description,
            emailCount: emails.count, emailIDs: emails.map(\.id),
            textOutput: output, metrics: ["tagged": tagCount, "tag_type": tag.rawValue.hashValue]
        )
    }

    private static func executeRedactPII(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) -> StepResult {
        guard !emails.isEmpty else {
            return StepResult(
                stepIndex: stepIndex, stepType: .redactPII, description: step.description,
                emailCount: 0, emailIDs: [],
                textOutput: "No emails to redact.", metrics: [:]
            )
        }

        let pii = EmailNLPEngine.piiSummary(in: emails)
        let piiTotal = pii.values.reduce(0, +)

        if piiTotal == 0 {
            return StepResult(
                stepIndex: stepIndex, stepType: .redactPII, description: step.description,
                emailCount: emails.count, emailIDs: [],
                textOutput: "No PII detected in \(emails.count) emails — no redaction needed.", metrics: ["pii_found": 0]
            )
        }

        let rules = RedactionEngine.defaultRules
        let redacted = RedactionEngine.redactBatch(emails: emails, rules: rules)
        let totalRedactions = redacted.reduce(0) { $0 + $1.redactionCount }

        let output = "⚠️ **PII Redaction Preview** (non-destructive):\n\n" +
            "Found **\(piiTotal)** PII instances across \(emails.count) emails.\n" +
            "Applied **\(totalRedactions)** redactions using \(rules.count) default rules.\n\n" +
            "PII types found: \(pii.filter { $0.value > 0 }.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", "))\n\n" +
            "⚠️ **Action required**: Use Forensic > PII Redaction to review and export redacted versions. " +
            "Original emails are NOT modified."

        return StepResult(
            stepIndex: stepIndex, stepType: .redactPII, description: step.description,
            emailCount: emails.count, emailIDs: emails.map(\.id),
            textOutput: output, metrics: ["pii_found": piiTotal, "redactions": totalRedactions]
        )
    }

    private static func executeCreateBatch(
        step: AgenticStep,
        stepIndex: Int,
        emails: [MBOXParser.RawEmail]
    ) async -> StepResult {
        guard !emails.isEmpty else {
            return StepResult(
                stepIndex: stepIndex, stepType: .createBatch, description: step.description,
                emailCount: 0, emailIDs: [],
                textOutput: "No emails to batch.", metrics: [:]
            )
        }

        let params = step.parameters.lowercased()
        let batchSize: Int
        if params.contains("small") || params.contains("10") { batchSize = 10 }
        else if params.contains("large") || params.contains("100") { batchSize = 100 }
        else { batchSize = 50 }

        let namePrefix = params.contains("review") ? "Review" : "Batch"

        let emailIDs = emails.map(\.id)
        let batchCount = max(1, (emailIDs.count + batchSize - 1) / batchSize)

        await MainActor.run {
            ReviewBatchManager.shared.createBatches(from: emailIDs, batchSize: batchSize, namePrefix: namePrefix)
        }

        let output = "✅ Created **\(batchCount)** review batch\(batchCount == 1 ? "" : "es") " +
            "(\(batchSize) emails each) from \(emails.count) emails.\n\n" +
            "Batch prefix: \"\(namePrefix)\"\n\n" +
            "Open **Forensic > Review Batches** to start reviewing."

        return StepResult(
            stepIndex: stepIndex, stepType: .createBatch, description: step.description,
            emailCount: emails.count, emailIDs: emailIDs,
            textOutput: output, metrics: ["batches": batchCount, "batch_size": batchSize]
        )
    }

    // MARK: - Final Synthesis

    private static func synthesizeAgenticResults(
        plan: AgenticPlan,
        query: String,
        stepResults: [StepResult],
        profile: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        var context = "Agentic workflow completed: \(plan.steps.count) steps\n"
        context += "Goal: \(plan.goal)\n\n"

        for result in stepResults {
            context += "--- Step \(result.stepIndex + 1): \(result.stepType.rawValue) ---\n"
            context += result.textOutput + "\n\n"
        }

        guard FoundationModelEngine.isAvailable else {
            return stepResults.map { "**Step \($0.stepIndex + 1)**: \($0.textOutput)" }.joined(separator: "\n\n")
        }

        let session = LanguageModelSession(instructions:
            "You completed a multi-step email analysis workflow. Synthesize all step results into a clear, structured answer. " +
            "Cite specific emails by **subject** and **sender**. Use markdown headings and bullet points. " +
            "Start with the key finding, then supporting details from each step."
        )

        let truncatedContext = String(context.prefix(3200))
        let prompt = "Original question: \(query)\n\nWorkflow results:\n\(truncatedContext)\n\nSynthesize a final answer."

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }

        return finalContent
    }

    // MARK: - Agentic Query Detection (NLP heuristic)

    static func isAgenticQuery(_ query: String) -> Bool {
        let qLower = query.lowercased()

        let sequentialIndicators = [
            "then", "after that", "next", "finally", "first",
            "and then", "followed by", "once you", "when done",
            "step by step", "one by one"
        ]
        var score = 0
        for indicator in sequentialIndicators {
            if qLower.contains(indicator) { score += 1 }
        }

        // v4.5.2: NL action verbs boost agentic detection
        let nlActionVerbs = ["export", "tag", "redact", "batch", "move", "remove", "delete", "flag"]
        let nlActionCount = nlActionVerbs.filter { qLower.contains($0) }.count
        if nlActionCount >= 1 { score += 1 }

        let actionVerbs = ["find", "search", "analyze", "summarize", "draft",
                           "compare", "filter", "check", "review", "create",
                           "list", "identify", "examine", "compose", "report"]
        let verbCount = actionVerbs.filter { qLower.contains($0) }.count
        if verbCount >= 3 { score += 2 }
        else if verbCount >= 2 { score += 1 }

        let multiClauseCount = qLower.components(separatedBy: ",").count - 1
            + qLower.components(separatedBy: " and ").count - 1
        if multiClauseCount >= 2 { score += 1 }

        return score >= 2
    }
}

#endif
