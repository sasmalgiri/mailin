//
//  AIAssistantView.swift
//  mailin
//
//  AI Assistant for email analysis
//

import SwiftUI

struct AIAssistantView: View {
    let emails: [MBOXParser.RawEmail]
    
    @State private var prompt = ""
    @State private var response = ""
    @State private var isProcessing = false
    @State private var conversationHistory: [(query: String, answer: String)] = []
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Conversation History
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if conversationHistory.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(Array(conversationHistory.enumerated()), id: \.offset) { index, item in
                                conversationBubble(query: item.query, answer: item.answer, index: index)
                            }
                        }
                    }
                    .padding()
                    .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: conversationHistory.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            
            Divider()
            
            // Input Area
            inputArea
        }
        .frame(minWidth: 600, minHeight: 500)
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("🤖 AI Email Assistant")
                    .font(.title2)
                    .bold()
                
                Text("Analyzing \(emails.count) email\(emails.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Clear History") {
                conversationHistory.removeAll()
                response = ""
            }
            .buttonStyle(.bordered)
            .disabled(conversationHistory.isEmpty)
            
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text("Ask me anything about your emails")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Try asking:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                ForEach(sampleQuestions, id: \.self) { question in
                    Button(action: {
                        prompt = question
                        askAI()
                    }) {
                        HStack {
                            Image(systemName: "lightbulb")
                                .foregroundColor(.blue)
                            Text(question)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 400)
        }
        .frame(maxHeight: .infinity)
    }
    
    private var sampleQuestions: [String] {
        [
            "How many emails did I send?",
            "Who did I email the most?",
            "What's the sentiment of my emails?",
            "What topics are discussed?",
            "Who are the key people mentioned?",
            "What languages are used?",
            "Show me contact insights",
            "What's the date range of these emails?"
        ]
    }
    
    // MARK: - Conversation Bubble
    
    private func conversationBubble(query: String, answer: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // User Query
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(query)
                        .padding(10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .frame(maxWidth: 400, alignment: .trailing)
                    
                    Text("You")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            // AI Response
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(answer)
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                        .frame(maxWidth: 400, alignment: .leading)
                    
                    Text("AI Assistant")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
    
    // MARK: - Input Area
    
    private var inputArea: some View {
        HStack(spacing: 12) {
            TextField("Ask a question about your emails...", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    askAI()
                }
            
            Button(action: askAI) {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - AI Logic
    
    private func askAI() {
        let query = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        isProcessing = true
        let currentQuery = query
        prompt = ""
        
        // Simulate processing delay
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = processQuery(currentQuery)
            
            DispatchQueue.main.async {
                conversationHistory.append((query: currentQuery, answer: answer))
                isProcessing = false
            }
        }
    }
    
    private func processQuery(_ query: String) -> String {
        let lower = query.lowercased()

        // MARK: - NLP-Powered Queries

        // Sentiment analysis
        if lower.contains("sentiment") || lower.contains("tone") || lower.contains("mood") || lower.contains("feeling") {
            let result = EmailNLPEngine.averageSentiment(of: emails)
            return """
            🧠 **Sentiment Analysis** (NLP)

            Overall tone: \(result.label)
            Average score: \(String(format: "%.2f", result.average)) (-1.0 negative to +1.0 positive)

            ✅ Positive emails: \(result.positive)
            😐 Neutral emails: \(result.neutral)
            ❌ Negative emails: \(result.negative)
            """
        }

        // Named entity recognition
        if lower.contains("people") || lower.contains("person") || lower.contains("entities") || lower.contains("names") || (lower.contains("who") && lower.contains("mention")) {
            let entities = EmailNLPEngine.extractEntities(from: emails, limit: 10)
            if entities.isEmpty { return "❓ No named entities found in email bodies." }
            var result = "🏷 **Key Entities Mentioned** (NLP)\n\n"
            for (i, entity) in entities.enumerated() {
                let icon: String
                switch entity.type {
                case "Person": icon = "👤"
                case "Organization": icon = "🏢"
                case "Place": icon = "📍"
                default: icon = "•"
                }
                result += "\(i + 1). \(icon) \(entity.name) (\(entity.type)) — \(entity.count) mention\(entity.count == 1 ? "" : "s")\n"
            }
            return result
        }

        // Topic extraction
        if lower.contains("topic") || lower.contains("keyword") || lower.contains("discuss") || lower.contains("talk about") || lower.contains("about what") {
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 12)
            if topics.isEmpty { return "❓ Not enough text content to extract topics." }
            var result = "📝 **Top Topics & Keywords** (NLP)\n\n"
            for (i, topic) in topics.enumerated() {
                result += "\(i + 1). \(topic.word) — \(topic.count) occurrence\(topic.count == 1 ? "" : "s")\n"
            }
            return result
        }

        // Language detection
        if lower.contains("language") || lower.contains("translate") || lower.contains("foreign") {
            let languages = EmailNLPEngine.detectLanguages(in: emails)
            if languages.isEmpty { return "❓ Could not detect languages in emails." }
            var result = "🌍 **Languages Detected** (NLP)\n\n"
            for lang in languages {
                result += "• \(lang.language): \(lang.count) email\(lang.count == 1 ? "" : "s") (\(String(format: "%.0f", lang.percentage))%)\n"
            }
            return result
        }

        // Contact insights (volume + sentiment)
        if lower.contains("contact insight") || lower.contains("contact analysis") || (lower.contains("who") && lower.contains("positive")) || (lower.contains("who") && lower.contains("negative")) {
            let insights = EmailNLPEngine.contactInsights(from: emails, limit: 8)
            if insights.isEmpty { return "❓ No contact data to analyze." }
            var result = "👥 **Contact Insights** (NLP)\n\n"
            for (i, c) in insights.enumerated() {
                let emoji: String
                switch c.sentimentLabel {
                case "Positive": emoji = "😊"
                case "Negative": emoji = "😟"
                default: emoji = "😐"
                }
                result += "\(i + 1). \(c.address)\n   \(c.emailCount) emails • Tone: \(emoji) \(c.sentimentLabel) (\(String(format: "%.2f", c.avgSentiment)))\n\n"
            }
            return result
        }

        // MARK: - Data Queries

        // Sent emails count
        if lower.contains("how many") && (lower.contains("sent") || lower.contains("send")) {
            let count = emails.filter { $0.messageType == "sent" }.count
            return "📤 You sent \(count) email\(count == 1 ? "" : "s") out of \(emails.count) total."
        }

        // Received emails count
        if lower.contains("how many") && lower.contains("received") {
            let count = emails.filter { $0.messageType == "received" }.count
            return "📥 You received \(count) email\(count == 1 ? "" : "s") out of \(emails.count) total."
        }

        // Most emailed person
        if lower.contains("who") && (lower.contains("most") || lower.contains("frequent")) {
            let recipients = emails
                .filter { $0.messageType == "sent" }
                .compactMap { $0.headers["To"] }
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let counts = Dictionary(grouping: recipients, by: { $0 }).mapValues { $0.count }
            if let top = counts.max(by: { $0.value < $1.value }) {
                return "📧 You emailed \(top.key) the most with \(top.value) email\(top.value == 1 ? "" : "s")."
            }
            return "❓ No recipient data found in your emails."
        }

        // Common subjects
        if lower.contains("subject") && lower.contains("common") {
            let subjects = Dictionary(grouping: emails.compactMap { $0.headers["Subject"] }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .prefix(5)
            if subjects.isEmpty { return "❓ No subject data found." }
            var result = "🏷 **Top subjects:**\n\n"
            for (index, subject) in subjects.enumerated() {
                result += "\(index + 1). \(subject.key) (\(subject.value) email\(subject.value == 1 ? "" : "s"))\n"
            }
            return result
        }

        // Date range
        if lower.contains("date") && (lower.contains("range") || lower.contains("when")) {
            let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .long
                return "📅 Date range: \(formatter.string(from: first)) to \(formatter.string(from: last))"
            }
            return "❓ No date information found."
        }

        // Reply statistics
        if lower.contains("reply") || lower.contains("statistic") {
            let sent = emails.filter { $0.messageType == "sent" }.count
            let received = emails.filter { $0.messageType == "received" }.count
            let ratio = received > 0 ? Double(sent) / Double(received) : 0
            return "📊 **Reply Statistics:**\n\nSent: \(sent)\nReceived: \(received)\nReply Ratio: \(String(format: "%.2f", ratio))"
        }

        // Attachment count
        if lower.contains("attachment") {
            let total = emails.reduce(0) { $0 + $1.attachments.count }
            let withAttachments = emails.filter { !$0.attachments.isEmpty }.count
            return "📎 **Attachments:** \(total) total across \(withAttachments) email\(withAttachments == 1 ? "" : "s")."
        }

        // Summary / overview
        if lower.contains("summary") || lower.contains("overview") || lower.contains("analyze") {
            let sent = emails.filter { $0.messageType == "sent" }.count
            let received = emails.filter { $0.messageType == "received" }.count
            let sentiment = EmailNLPEngine.averageSentiment(of: emails)
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 5)
            let languages = EmailNLPEngine.detectLanguages(in: emails)
            let topLang = languages.first?.language ?? "Unknown"

            var result = "📊 **Email Archive Summary** (NLP)\n\n"
            result += "Total: \(emails.count) emails (\(sent) sent, \(received) received)\n"
            result += "Tone: \(sentiment.label) (score: \(String(format: "%.2f", sentiment.average)))\n"
            result += "Primary language: \(topLang)\n\n"
            if !topics.isEmpty {
                result += "Top topics: \(topics.map(\.word).joined(separator: ", "))\n"
            }
            return result
        }

        // Default response
        return """
        🤔 I can help with these queries:

        📊 **Data Analysis:**
        • "How many emails did I send/receive?"
        • "Who did I email the most?"
        • "What are the most common subjects?"
        • "What's the date range?"
        • "Show me reply statistics"

        🧠 **NLP Analysis (on-device AI):**
        • "What's the sentiment of my emails?"
        • "What topics are discussed?"
        • "Who are the key people mentioned?"
        • "What languages are used?"
        • "Show me contact insights"
        • "Give me a summary"
        """
    }
}

// MARK: - Preview

#Preview {
    AIAssistantView(emails: [])
}
