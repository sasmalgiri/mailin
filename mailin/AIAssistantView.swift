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
            "What are the most common subjects?",
            "Show me reply statistics",
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
        
        // Sent emails count
        if lower.contains("how many") && (lower.contains("sent") || lower.contains("send")) {
            let count = emails.filter { $0.messageType == "sent" }.count
            return "📤 You sent **\(count)** email\(count == 1 ? "" : "s") out of \(emails.count) total."
        }
        
        // Received emails count
        if lower.contains("how many") && lower.contains("received") {
            let count = emails.filter { $0.messageType == "received" }.count
            return "📥 You received **\(count)** email\(count == 1 ? "" : "s") out of \(emails.count) total."
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
                return "📧 You emailed **\(top.key)** the most with **\(top.value)** email\(top.value == 1 ? "" : "s")."
            }
            return "❓ No recipient data found in your emails."
        }
        
        // Common subjects
        if lower.contains("subject") && lower.contains("common") {
            let subjects = Dictionary(grouping: emails.compactMap { $0.headers["Subject"] }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .prefix(5)
            
            if subjects.isEmpty {
                return "❓ No subject data found."
            }
            
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
                return "📅 Date range: **\(formatter.string(from: first))** to **\(formatter.string(from: last))**"
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
        
        // Default response
        return """
        🤔 I'm not sure how to answer that. Try asking:
        
        • "How many emails did I send?"
        • "Who did I email the most?"
        • "What are the most common subjects?"
        • "What's the date range?"
        • "Show me reply statistics"
        """
    }
}

// MARK: - Preview

#Preview {
    AIAssistantView(emails: [])
}
