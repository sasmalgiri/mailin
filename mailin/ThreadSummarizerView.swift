//
//  ThreadSummarizerView.swift
//  mailin
//
//  Thread summarization engine and UI: extracts participants, key topics,
//  decision points, action items, sentiment arc, and a TL;DR summary.
//

import SwiftUI
import NaturalLanguage

// MARK: - Thread Summary Model

struct ThreadSummary {
    let participants: [Participant]
    let dateRange: (start: Date?, end: Date?)
    let messageCount: Int
    let keyTopics: [String]
    let sentimentArc: [SentimentPoint]
    let decisionPoints: [String]
    let actionItems: [String]
    let tldr: String

    struct Participant: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        let messageCount: Int
    }

    struct SentimentPoint: Identifiable {
        let id = UUID()
        let index: Int
        let score: Double
        let date: Date?
    }
}

// MARK: - Thread Summarizer Engine

struct ThreadSummarizer {

    /// Summarize a thread of emails, expected to be pre-sorted or from the same thread.
    static func summarizeThread(emails: [MBOXParser.RawEmail]) -> ThreadSummary {
        let sorted = emails.sorted { lhs, rhs in
            let lhsDate = MBOXParser.parseDate(lhs.headers["Date"])
            let rhsDate = MBOXParser.parseDate(rhs.headers["Date"])
            return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
        }

        let participants = extractParticipants(from: sorted)
        let dateRange = extractDateRange(from: sorted)
        let keyTopics = extractKeyTopics(from: sorted)
        let sentimentArc = computeSentimentArc(from: sorted)
        let decisionPoints = extractDecisionPoints(from: sorted)
        let actionItems = extractActionItems(from: sorted)
        let tldr = generateTLDR(from: sorted, topics: keyTopics)

        return ThreadSummary(
            participants: participants,
            dateRange: dateRange,
            messageCount: sorted.count,
            keyTopics: keyTopics,
            sentimentArc: sentimentArc,
            decisionPoints: decisionPoints,
            actionItems: actionItems,
            tldr: tldr
        )
    }

    // MARK: - Participants

    private static func extractParticipants(from emails: [MBOXParser.RawEmail]) -> [ThreadSummary.Participant] {
        var participantCounts: [String: (name: String, count: Int)] = [:]

        for email in emails {
            let from = email.headers["From"] ?? ""
            let (name, address) = parseContact(from)
            let key = address.lowercased()
            if !key.isEmpty {
                if let existing = participantCounts[key] {
                    participantCounts[key] = (name: existing.name.isEmpty ? name : existing.name,
                                              count: existing.count + 1)
                } else {
                    participantCounts[key] = (name: name, count: 1)
                }
            }
        }

        return participantCounts
            .map { ThreadSummary.Participant(name: $0.value.name, address: $0.key, messageCount: $0.value.count) }
            .sorted { $0.messageCount > $1.messageCount }
    }

    private static func parseContact(_ raw: String) -> (name: String, address: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let angleBracketStart = trimmed.firstIndex(of: "<"),
           let angleBracketEnd = trimmed.firstIndex(of: ">") {
            let address = String(trimmed[trimmed.index(after: angleBracketStart)..<angleBracketEnd])
            let name = String(trimmed[trimmed.startIndex..<angleBracketStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (name, address)
        }
        if trimmed.contains("@") {
            return ("", trimmed)
        }
        return (trimmed, "")
    }

    // MARK: - Date Range

    private static func extractDateRange(from emails: [MBOXParser.RawEmail]) -> (start: Date?, end: Date?) {
        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        return (dates.first, dates.last)
    }

    // MARK: - Key Topics

    private static func extractKeyTopics(from emails: [MBOXParser.RawEmail]) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        var wordCounts: [String: Int] = [:]
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "was", "are", "were", "be", "been",
            "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "to", "of", "in", "for",
            "on", "with", "at", "by", "from", "as", "this", "that",
            "it", "its", "not", "but", "and", "or", "if", "so",
            "all", "just", "than", "then", "can", "no", "yes",
            "we", "you", "i", "me", "my", "our", "your", "he",
            "she", "they", "them", "their", "his", "her", "who",
            "what", "which", "how", "when", "where", "why",
            "re", "fw", "fwd", "sent", "wrote", "thanks", "thank",
            "regards", "hello", "hi", "hey", "please", "let",
            "know", "get", "got", "like", "also", "still", "now",
        ]

        // Combine subjects and body text
        for email in emails {
            let subject = email.headers["Subject"] ?? ""
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let cleanBody = body.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
            let text = "\(subject) \(String(cleanBody.prefix(1500)))"

            tagger.string = text
            let range = text.startIndex..<text.endIndex
            tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass,
                                 options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
                guard let tag = tag, tag == .noun || tag == .adjective else { return true }
                let word = String(text[tokenRange]).lowercased()
                if word.count >= 3 && !stopWords.contains(word)
                    && word.range(of: #"^\d+$"#, options: .regularExpression) == nil {
                    wordCounts[word, default: 0] += 1
                }
                return true
            }
        }

        return wordCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    // MARK: - Sentiment Arc

    private static func computeSentimentArc(from emails: [MBOXParser.RawEmail]) -> [ThreadSummary.SentimentPoint] {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var points: [ThreadSummary.SentimentPoint] = []

        for (index, email) in emails.enumerated() {
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            guard !body.isEmpty else {
                points.append(ThreadSummary.SentimentPoint(index: index, score: 0,
                                                            date: MBOXParser.parseDate(email.headers["Date"])))
                continue
            }
            tagger.string = body
            let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
            let score = Double(tag?.rawValue ?? "0") ?? 0
            points.append(ThreadSummary.SentimentPoint(index: index, score: score,
                                                        date: MBOXParser.parseDate(email.headers["Date"])))
        }
        return points
    }

    // MARK: - Decision Points

    private static func extractDecisionPoints(from emails: [MBOXParser.RawEmail]) -> [String] {
        let decisionKeywords = [
            "decided", "agreed", "approved", "confirmed",
            "resolved", "concluded", "finalized", "committed",
            "accepted", "signed off", "go ahead", "green light",
            "we will", "we'll proceed", "decision is", "voted"
        ]

        var decisions: [String] = []

        for email in emails {
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let sentences = body.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 10 && !$0.hasPrefix(">") }

            for sentence in sentences {
                let lower = sentence.lowercased()
                if decisionKeywords.contains(where: { lower.contains($0) }) {
                    let cleaned = sentence.count > 200 ? String(sentence.prefix(200)) + "..." : sentence
                    decisions.append(cleaned)
                }
            }
        }

        // Deduplicate similar decisions
        var unique: [String] = []
        for decision in decisions {
            let isDuplicate = unique.contains { existing in
                existing.lowercased().hasPrefix(String(decision.lowercased().prefix(40)))
            }
            if !isDuplicate {
                unique.append(decision)
            }
        }

        return Array(unique.prefix(15))
    }

    // MARK: - Action Items

    private static func extractActionItems(from emails: [MBOXParser.RawEmail]) -> [String] {
        let actionKeywords = [
            "please", "need to", "action required", "todo", "to do",
            "follow up", "deadline", "by end of", "asap", "urgent",
            "assign", "responsible", "must", "should", "make sure",
            "don't forget", "remember to", "ensure", "complete by",
            "deliver", "submit", "send", "prepare", "schedule",
            "action item"
        ]

        var items: [String] = []

        for email in emails {
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let sentences = body.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 8 && !$0.hasPrefix(">") }

            for sentence in sentences {
                let lower = sentence.lowercased()
                if actionKeywords.contains(where: { lower.contains($0) }) {
                    let cleaned = sentence.count > 200 ? String(sentence.prefix(200)) + "..." : sentence
                    items.append(cleaned)
                }
            }
        }

        // Deduplicate similar items
        var unique: [String] = []
        for item in items {
            let isDuplicate = unique.contains { existing in
                existing.lowercased().hasPrefix(String(item.lowercased().prefix(40)))
            }
            if !isDuplicate {
                unique.append(item)
            }
        }

        return Array(unique.prefix(20))
    }

    // MARK: - TL;DR Generation

    private static func generateTLDR(from emails: [MBOXParser.RawEmail], topics: [String]) -> String {
        guard let first = emails.first, let last = emails.last else { return "No emails in this thread." }
        let firstSubject = first.headers["Subject"] ?? "(No Subject)"
        let firstFrom = first.headers["From"]?.components(separatedBy: "<").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "Unknown"
        let lastFrom = last.headers["From"]?.components(separatedBy: "<").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "Unknown"

        var tldr = "Thread \"\(firstSubject)\" started by \(firstFrom)"
        if emails.count > 1 {
            tldr += " with \(emails.count) messages"
            let uniqueParticipants = Set(emails.compactMap { $0.headers["From"]?.lowercased() }).count
            if uniqueParticipants > 1 {
                tldr += " from \(uniqueParticipants) participants"
            }
        }
        tldr += "."

        if !topics.isEmpty {
            let topicList = Array(topics.prefix(4)).joined(separator: ", ")
            tldr += " Key topics: \(topicList)."
        }

        if emails.count > 1 {
            let lastBody = last.plainBody.isEmpty ? last.htmlBody : last.plainBody
            let lastSentence = lastBody.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 15 && !$0.hasPrefix(">") }
                .first

            if let closing = lastSentence, closing.count <= 150 {
                tldr += " Most recent from \(lastFrom): \"\(closing).\""
            }
        }

        return tldr
    }
}

// MARK: - Thread Summarizer View

struct ThreadSummarizerView: View {
    let threadEmails: [MBOXParser.RawEmail]

    @Environment(\.dismiss) private var dismiss
    @State private var summary: ThreadSummary?
    @State private var isComputing = false
    @State private var checkedActionItems: Set<Int> = []
    @State private var isEmailListExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isComputing {
                LoadingView(message: "Analyzing thread...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = summary {
                summaryContent(summary)
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "Thread Summary",
                    message: "Analyze \(threadEmails.count) email\(threadEmails.count == 1 ? "" : "s") in this thread to extract key insights.",
                    actionTitle: "Summarize Thread"
                ) {
                    computeSummary()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppColors.backgroundPrimary)
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 640, maxWidth: 800,
               minHeight: 480, idealHeight: 680, maxHeight: 900)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("Thread Summary", systemImage: "text.bubble")
                    .font(Typography.title2)
                Text("\(threadEmails.count) message\(threadEmails.count == 1 ? "" : "s") in thread")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Thread Summary, \(threadEmails.count) messages")

            Spacer()

            if summary != nil {
                Button {
                    computeSummary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recompute summary")
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close thread summary")
        }
        .padding(Spacing.medium)
    }

    // MARK: - Summary Content

    private func summaryContent(_ summary: ThreadSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                participantsSection(summary.participants)
                dateRangeSection(summary)
                tldrSection(summary.tldr)
                keyTopicsSection(summary.keyTopics)
                sentimentArcSection(summary.sentimentArc)
                decisionPointsSection(summary.decisionPoints)
                actionItemsSection(summary.actionItems)
                emailListSection
            }
            .padding(Spacing.medium)
        }
    }

    // MARK: - Participants

    private func participantsSection(_ participants: [ThreadSummary.Participant]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Participants")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(participants) { participant in
                HStack(spacing: Spacing.xSmall) {
                    ContactAvatar(
                        name: participant.name.isEmpty ? participant.address : participant.name,
                        size: 28
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(participant.name.isEmpty ? participant.address : participant.name)
                            .font(Typography.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if !participant.name.isEmpty {
                            Text(participant.address)
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(participant.messageCount) msg\(participant.messageCount == 1 ? "" : "s")")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(participant.name.isEmpty ? participant.address : participant.name), \(participant.messageCount) messages")
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Date Range

    private func dateRangeSection(_ summary: ThreadSummary) -> some View {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        return HStack(spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("Date Range")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                if let start = summary.dateRange.start, let end = summary.dateRange.end {
                    Text("\(formatter.string(from: start)) - \(formatter.string(from: end))")
                        .font(Typography.callout)
                } else {
                    Text("Unknown")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Spacing.xxxSmall) {
                Text("Messages")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Text("\(summary.messageCount)")
                    .font(Typography.title3)
                    .fontWeight(.semibold)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
        .accessibilityElement(children: .combine)
    }

    // MARK: - TL;DR

    private func tldrSection(_ tldr: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Label("TL;DR", systemImage: "text.quote")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            Text(tldr)
                .font(Typography.body)
                .foregroundColor(.primary)
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Key Topics

    private func keyTopicsSection(_ topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Key Topics")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            if topics.isEmpty {
                Text("No significant topics extracted.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                FlowLayout(spacing: Spacing.xSmall) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(Typography.caption1)
                            .fontWeight(.medium)
                            .padding(.horizontal, Spacing.small)
                            .padding(.vertical, Spacing.xxSmall)
                            .background(AppColors.primary.opacity(0.12))
                            .foregroundColor(AppColors.primary)
                            .clipShape(Capsule())
                            .accessibilityLabel("Topic: \(topic)")
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Sentiment Arc (mini line chart using SwiftUI shapes)

    private func sentimentArcSection(_ points: [ThreadSummary.SentimentPoint]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Sentiment Arc")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            if points.isEmpty || points.count < 2 {
                Text("Not enough messages to show a sentiment arc.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                SentimentArcChart(points: points)
                    .frame(height: 100)
                    .accessibilityLabel("Sentiment arc chart showing \(points.count) data points")

                HStack {
                    HStack(spacing: Spacing.xxSmall) {
                        Circle().fill(AppColors.success).frame(width: 8, height: 8)
                        Text("Positive").font(Typography.caption2)
                    }
                    HStack(spacing: Spacing.xxSmall) {
                        Circle().fill(AppColors.secondary).frame(width: 8, height: 8)
                        Text("Neutral").font(Typography.caption2)
                    }
                    HStack(spacing: Spacing.xxSmall) {
                        Circle().fill(AppColors.error).frame(width: 8, height: 8)
                        Text("Negative").font(Typography.caption2)
                    }
                }
                .foregroundColor(AppColors.secondary)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Decision Points

    private func decisionPointsSection(_ decisions: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Label("Decision Points", systemImage: "checkmark.seal")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            if decisions.isEmpty {
                Text("No decision points identified in this thread.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                ForEach(Array(decisions.enumerated()), id: \.offset) { index, decision in
                    HStack(alignment: .top, spacing: Spacing.xSmall) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(AppColors.info)
                            .font(.caption)
                            .padding(.top, 3)
                        Text(decision)
                            .font(Typography.callout)
                            .foregroundColor(.primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Decision \(index + 1): \(decision)")
                }
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Action Items

    private func actionItemsSection(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Label("Action Items", systemImage: "checklist")
                    .font(Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !items.isEmpty {
                    Text("\(checkedActionItems.count)/\(items.count)")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }

            if items.isEmpty {
                Text("No action items identified in this thread.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let isChecked = checkedActionItems.contains(index)

                    Button {
                        withAnimation(AnimationTiming.fast) {
                            if isChecked {
                                checkedActionItems.remove(index)
                            } else {
                                checkedActionItems.insert(index)
                            }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.xSmall) {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .foregroundColor(isChecked ? AppColors.success : AppColors.secondary)
                                .padding(.top, 2)
                            Text(item)
                                .font(Typography.callout)
                                .foregroundColor(isChecked ? AppColors.secondary : .primary)
                                .strikethrough(isChecked)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item), \(isChecked ? "completed" : "not completed")")
                    .accessibilityHint("Toggle completion")
                }
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Expandable Email List

    private var emailListSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Button {
                withAnimation(AnimationTiming.normal) {
                    isEmailListExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Full Email List", systemImage: "envelope.open")
                        .font(Typography.headline)
                    Spacer()
                    Image(systemName: isEmailListExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.small)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Full email list, \(isEmailListExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Toggle to \(isEmailListExpanded ? "collapse" : "expand") the list")

            if isEmailListExpanded {
                let sorted = threadEmails.sorted { lhs, rhs in
                    let lhsDate = MBOXParser.parseDate(lhs.headers["Date"])
                    let rhsDate = MBOXParser.parseDate(rhs.headers["Date"])
                    return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
                }

                ForEach(sorted) { email in
                    emailRow(email)
                }
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private func emailRow(_ email: MBOXParser.RawEmail) -> some View {
        let from = email.headers["From"] ?? "Unknown"
        let subject = email.headers["Subject"] ?? "(No Subject)"
        let dateStr = email.headers["Date"] ?? ""
        let isSent = email.messageType == "sent"

        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                Circle()
                    .fill(isSent ? AppColors.sentEmail : AppColors.receivedEmail)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(from)
                    .font(Typography.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(dateStr)
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
            }
            Text(subject)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, Spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isSent ? "Sent" : "Received") from \(from), subject: \(subject)")
    }

    // MARK: - Compute

    private func computeSummary() {
        isComputing = true
        checkedActionItems = []

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ThreadSummarizer.summarizeThread(emails: threadEmails)
            DispatchQueue.main.async {
                withAnimation(AnimationTiming.normal) {
                    summary = result
                    isComputing = false
                }
            }
        }
    }
}

// MARK: - Sentiment Arc Chart (SwiftUI Shapes)

private struct SentimentArcChart: View {
    let points: [ThreadSummary.SentimentPoint]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let midY = height / 2.0

            // Draw zero line
            Path { path in
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: width, y: midY))
            }
            .stroke(AppColors.separatorLight, lineWidth: 1)

            // Draw sentiment line
            if points.count >= 2 {
                let stepX = width / CGFloat(max(points.count - 1, 1))

                // Gradient fill below / above the line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: yPosition(for: points[0].score, midY: midY, halfHeight: midY * 0.85)))
                    for i in 1..<points.count {
                        let x = CGFloat(i) * stepX
                        let y = yPosition(for: points[i].score, midY: midY, halfHeight: midY * 0.85)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: CGFloat(points.count - 1) * stepX, y: midY))
                    path.addLine(to: CGPoint(x: 0, y: midY))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [AppColors.success.opacity(0.2), AppColors.error.opacity(0.2)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Main line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: yPosition(for: points[0].score, midY: midY, halfHeight: midY * 0.85)))
                    for i in 1..<points.count {
                        let x = CGFloat(i) * stepX
                        let y = yPosition(for: points[i].score, midY: midY, halfHeight: midY * 0.85)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(AppColors.primary, lineWidth: 2)

                // Data point dots
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let x = CGFloat(index) * stepX
                    let y = yPosition(for: point.score, midY: midY, halfHeight: midY * 0.85)

                    Circle()
                        .fill(colorForScore(point.score))
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }
            }
        }
    }

    private func yPosition(for score: Double, midY: CGFloat, halfHeight: CGFloat) -> CGFloat {
        // Score is -1 to +1; positive goes up (lower y), negative goes down (higher y)
        midY - CGFloat(score) * halfHeight
    }

    private func colorForScore(_ score: Double) -> Color {
        if score > 0.3 { return AppColors.success }
        if score < -0.3 { return AppColors.error }
        return AppColors.secondary
    }
}

// MARK: - Flow Layout (for topic tags)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? .infinity, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
