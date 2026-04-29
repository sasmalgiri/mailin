import SwiftUI

struct AIAssistantView: View {
    let emails: [MBOXParser.RawEmail]

    @State private var prompt = ""
    @State private var isProcessing = false
    @State private var conversationHistory: [(query: String, answer: String)] = []
    @State private var useFoundationModel = true

    @Environment(\.dismiss) private var dismiss

    private var foundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelEngine.isAvailable
        }
        #endif
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            chatArea
            Divider()
            inputArea
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(AppColors.backgroundTertiary)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(
                        .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Email Assistant")
                        .font(Typography.headline)
                    Text(aiEngineLabel)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }

            Spacer()

            if foundationModelAvailable {
                Picker("", selection: $useFoundationModel) {
                    Text("Apple AI").tag(true)
                    Text("NLP").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Button {
                conversationHistory.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(Typography.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(conversationHistory.isEmpty)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.medium) {
                    if conversationHistory.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(Array(conversationHistory.enumerated()), id: \.offset) { index, item in
                            chatBubble(query: item.query, answer: item.answer)
                                .id(index)
                        }
                    }
                }
                .padding(Spacing.medium)
            }
            .onChange(of: conversationHistory.count) { _, _ in
                if let last = conversationHistory.indices.last {
                    withAnimation(AnimationTiming.normal) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.large) {
            Spacer(minLength: Spacing.xxLarge)

            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(
                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(spacing: Spacing.xSmall) {
                Text("Ask anything about your emails")
                    .font(Typography.title3)
                Text(useFoundationModel && foundationModelAvailable
                     ? "Powered by Apple Intelligence — 100% on-device"
                     : "Powered by on-device Natural Language Processing")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
            }

            VStack(spacing: Spacing.xSmall) {
                ForEach(sampleQuestions, id: \.self) { question in
                    Button {
                        prompt = question
                        askAI()
                    } label: {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "sparkle")
                                .font(Typography.caption1)
                                .foregroundStyle(.blue)
                            Text(question)
                                .font(Typography.callout)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(AppColors.primary.opacity(0.4))
                        }
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.medium)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(scale: 1.01)
                }
            }
            .frame(maxWidth: 420)

            Spacer(minLength: Spacing.xxLarge)
        }
    }

    private var sampleQuestions: [String] {
        [
            "What's the sentiment of my emails?",
            "What topics are discussed?",
            "Who are the key people mentioned?",
            "Give me a full summary",
            "How many emails did I send?",
            "Who did I email the most?",
            "What languages are used?",
            "Show me contact insights",
        ]
    }

    // MARK: - Chat Bubble

    private func chatBubble(query: String, answer: String) -> some View {
        VStack(spacing: Spacing.small) {
            // User message
            HStack {
                Spacer(minLength: Spacing.xxLarge)
                VStack(alignment: .trailing, spacing: Spacing.xxSmall) {
                    Text(query)
                        .font(Typography.body)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .foregroundColor(.white)
                        .background(
                            LinearGradient(colors: [.blue, .blue.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .cornerRadius(CornerRadius.large)
                }
            }

            // AI response
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    HStack(spacing: Spacing.xxSmall) {
                        Image(systemName: "brain.head.profile")
                            .font(Typography.caption1)
                            .foregroundStyle(.purple)
                        Text("AI")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                    Text(answer)
                        .font(Typography.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.large)
                }
                Spacer(minLength: Spacing.xxLarge)
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: Spacing.small) {
            TextField("Ask about your emails...", text: $prompt)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(.horizontal, Spacing.small)
                .padding(.vertical, Spacing.xSmall)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.medium)
                .onSubmit { askAI() }

            Button(action: askAI) {
                Group {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AppColors.primary : AppColors.secondary.opacity(0.5))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    // MARK: - AI Engine Label

    private var aiEngineLabel: String {
        let count = emails.count
        let suffix = count == 1 ? "" : "s"
        if useFoundationModel && foundationModelAvailable {
            return "Analyzing \(count) email\(suffix) with Apple Intelligence (on-device)"
        }
        return "Analyzing \(count) email\(suffix) with on-device NLP"
    }

    // MARK: - AI Logic

    private func askAI() {
        let query = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isProcessing = true
        let currentQuery = query
        prompt = ""

        if useFoundationModel && foundationModelAvailable && shouldUseFoundationModel(for: currentQuery) {
            Task {
                let answer = await askFoundationModel(currentQuery)
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer))
                }
                isProcessing = false
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = processQuery(currentQuery)
                DispatchQueue.main.async {
                    withAnimation(AnimationTiming.normal) {
                        conversationHistory.append((query: currentQuery, answer: answer))
                    }
                    isProcessing = false
                }
            }
        }
    }

    private func shouldUseFoundationModel(for query: String) -> Bool {
        let lower = query.lowercased()
        let dataOnlyKeywords = ["how many", "date range", "attachment count"]
        return !dataOnlyKeywords.contains(where: { lower.contains($0) })
    }

    private func askFoundationModel(_ query: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                return try await FoundationModelEngine.respond(to: query, emails: emails)
            } catch {
                return "Apple Intelligence error: \(error.localizedDescription)\n\nFalling back to NLP analysis:\n\n\(processQuery(query))"
            }
        }
        #endif
        return processQuery(query)
    }

    private func processQuery(_ query: String) -> String {
        let lower = query.lowercased()

        // MARK: NLP Queries

        if lower.contains("sentiment") || lower.contains("tone") || lower.contains("mood") || lower.contains("feeling") {
            let result = EmailNLPEngine.averageSentiment(of: emails)
            return """
            Sentiment Analysis (NLP)

            Overall tone: \(result.label)
            Score: \(String(format: "%.2f", result.average)) (range: -1.0 to +1.0)

            Positive: \(result.positive)
            Neutral: \(result.neutral)
            Negative: \(result.negative)
            """
        }

        if lower.contains("people") || lower.contains("person") || lower.contains("entities") || lower.contains("names") || (lower.contains("who") && lower.contains("mention")) {
            let entities = EmailNLPEngine.extractEntities(from: emails, limit: 10)
            if entities.isEmpty { return "No named entities found in email bodies." }
            var result = "Key Entities (NLP)\n\n"
            for (i, entity) in entities.enumerated() {
                let icon: String
                switch entity.type {
                case "Person": icon = "Person"
                case "Organization": icon = "Org"
                case "Place": icon = "Place"
                default: icon = entity.type
                }
                result += "\(i + 1). \(entity.name) [\(icon)] — \(entity.count) mention\(entity.count == 1 ? "" : "s")\n"
            }
            return result
        }

        if lower.contains("topic") || lower.contains("keyword") || lower.contains("discuss") || lower.contains("talk about") || lower.contains("about what") {
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 12)
            if topics.isEmpty { return "Not enough text content to extract topics." }
            var result = "Top Topics & Keywords (NLP)\n\n"
            for (i, topic) in topics.enumerated() {
                result += "\(i + 1). \(topic.word) — \(topic.count) occurrence\(topic.count == 1 ? "" : "s")\n"
            }
            return result
        }

        if lower.contains("language") || lower.contains("translate") || lower.contains("foreign") {
            let languages = EmailNLPEngine.detectLanguages(in: emails)
            if languages.isEmpty { return "Could not detect languages in emails." }
            var result = "Languages Detected (NLP)\n\n"
            for lang in languages {
                result += "\(lang.language): \(lang.count) email\(lang.count == 1 ? "" : "s") (\(String(format: "%.0f", lang.percentage))%)\n"
            }
            return result
        }

        if lower.contains("contact insight") || lower.contains("contact analysis") || (lower.contains("who") && lower.contains("positive")) || (lower.contains("who") && lower.contains("negative")) {
            let insights = EmailNLPEngine.contactInsights(from: emails, limit: 8)
            if insights.isEmpty { return "No contact data to analyze." }
            var result = "Contact Insights (NLP)\n\n"
            for (i, c) in insights.enumerated() {
                result += "\(i + 1). \(c.address)\n   \(c.emailCount) emails — Tone: \(c.sentimentLabel) (\(String(format: "%.2f", c.avgSentiment)))\n\n"
            }
            return result
        }

        // MARK: Data Queries

        if lower.contains("how many") && (lower.contains("sent") || lower.contains("send")) {
            let count = emails.filter { $0.messageType == "sent" }.count
            return "You sent \(count) email\(count == 1 ? "" : "s") out of \(emails.count) total."
        }

        if lower.contains("how many") && lower.contains("received") {
            let count = emails.filter { $0.messageType == "received" }.count
            return "You received \(count) email\(count == 1 ? "" : "s") out of \(emails.count) total."
        }

        if lower.contains("who") && (lower.contains("most") || lower.contains("frequent")) {
            let recipients = emails
                .filter { $0.messageType == "sent" }
                .compactMap { $0.headers["To"] }
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let counts = Dictionary(grouping: recipients, by: { $0 }).mapValues { $0.count }
            if let top = counts.max(by: { $0.value < $1.value }) {
                return "You emailed \(top.key) the most with \(top.value) email\(top.value == 1 ? "" : "s")."
            }
            return "No recipient data found."
        }

        if lower.contains("subject") && lower.contains("common") {
            let subjects = Dictionary(grouping: emails.compactMap { $0.headers["Subject"] }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .prefix(5)
            if subjects.isEmpty { return "No subject data found." }
            var result = "Top Subjects\n\n"
            for (i, subject) in subjects.enumerated() {
                result += "\(i + 1). \(subject.key) (\(subject.value))\n"
            }
            return result
        }

        if lower.contains("date") && (lower.contains("range") || lower.contains("when")) {
            let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .long
                return "Date range: \(formatter.string(from: first)) to \(formatter.string(from: last))"
            }
            return "No date information found."
        }

        if lower.contains("reply") || lower.contains("statistic") {
            let sent = emails.filter { $0.messageType == "sent" }.count
            let received = emails.filter { $0.messageType == "received" }.count
            let ratio = received > 0 ? Double(sent) / Double(received) : 0
            return "Reply Statistics\n\nSent: \(sent)\nReceived: \(received)\nRatio: \(String(format: "%.2f", ratio))"
        }

        if lower.contains("attachment") {
            let total = emails.reduce(0) { $0 + $1.attachments.count }
            let withAttachments = emails.filter { !$0.attachments.isEmpty }.count
            return "Attachments: \(total) total across \(withAttachments) email\(withAttachments == 1 ? "" : "s")."
        }

        if lower.contains("summary") || lower.contains("overview") || lower.contains("analyze") {
            let sent = emails.filter { $0.messageType == "sent" }.count
            let received = emails.filter { $0.messageType == "received" }.count
            let sentiment = EmailNLPEngine.averageSentiment(of: emails)
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 5)
            let languages = EmailNLPEngine.detectLanguages(in: emails)
            let topLang = languages.first?.language ?? "Unknown"

            var result = "Email Archive Summary (NLP)\n\n"
            result += "Total: \(emails.count) emails (\(sent) sent, \(received) received)\n"
            result += "Tone: \(sentiment.label) (score: \(String(format: "%.2f", sentiment.average)))\n"
            result += "Language: \(topLang)\n"
            if !topics.isEmpty {
                result += "Topics: \(topics.map(\.word).joined(separator: ", "))\n"
            }
            return result
        }

        return """
        I can help with these queries:

        Data Analysis:
        • How many emails did I send/receive?
        • Who did I email the most?
        • What are the most common subjects?
        • What's the date range?
        • Show me reply statistics

        NLP Analysis (on-device):
        • What's the sentiment of my emails?
        • What topics are discussed?
        • Who are the key people mentioned?
        • What languages are used?
        • Show me contact insights
        • Give me a summary
        """
    }
}

#Preview {
    AIAssistantView(emails: [])
}
