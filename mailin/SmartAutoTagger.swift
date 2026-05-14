//
//  SmartAutoTagger.swift
//  mailin
//
//  Apple AI tag engine with NLP fallback for email classification.
//

import Foundation
import NaturalLanguage

@MainActor
class SmartAutoTagger: ObservableObject {
    static let shared = SmartAutoTagger()

    @Published var suggestedTags: [UUID: [TagSuggestion]] = [:]
    @Published var isProcessing = false
    @Published var processedCount = 0
    @Published var totalCount = 0

    struct TagSuggestion: Identifiable, Hashable {
        let id: UUID
        let tag: String
        let confidence: Double
        let reason: String

        init(tag: String, confidence: Double, reason: String) {
            self.id = UUID()
            self.tag = tag
            self.confidence = confidence
            self.reason = reason
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: TagSuggestion, rhs: TagSuggestion) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Batch Processing

    func generateTags(for emails: [MBOXParser.RawEmail]) async {
        await MainActor.run {
            isProcessing = true
            processedCount = 0
            totalCount = emails.count
            suggestedTags = [:]
        }

        // Step 1: Try Apple AI batch tagging
        var aiTags: [UUID: EmailTagResult] = [:]
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            aiTags = await FoundationModelEngine.tagEmails(emails) { done, total in
                self.processedCount = done
            }
        }
        #endif

        // Step 2: Build tags — Apple AI results + NLP for everything else
        let batchSize: Int
        switch emails.count {
        case 0...500: batchSize = 50
        case 501...5000: batchSize = 100
        case 5001...20000: batchSize = 200
        default: batchSize = 500
        }
        for startIndex in stride(from: 0, to: emails.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, emails.count)
            let batch = Array(emails[startIndex..<endIndex])

            var batchResults: [(UUID, [TagSuggestion])] = batch.map { email in
                var tags = Self.generateNLPTags(email)
                if let aiResult = aiTags[email.id] {
                    tags = Self.mergeAITags(aiResult, into: tags)
                }
                return (email.id, tags)
            }

            // Step 3: Apple AI entity enrichment — refine NLP entity tags
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                batchResults = await Self.enrichEntityTags(in: batchResults)
            }
            #endif

            await MainActor.run {
                for (emailID, tags) in batchResults {
                    suggestedTags[emailID] = tags
                }
                processedCount = min(endIndex, emails.count)
            }
        }

        await MainActor.run {
            isProcessing = false
        }
    }

    private static func mergeAITags(_ ai: EmailTagResult, into nlpTags: [TagSuggestion]) -> [TagSuggestion] {
        var merged: [TagSuggestion] = []
        let nlpCategoryNames: Set<String> = ["personal", "transactional", "newsletter", "promotional", "automated", "unknown", "informational"]

        // Replace NLP category with Apple AI category
        merged.append(TagSuggestion(
            tag: ai.category,
            confidence: 0.95,
            reason: "Classified by Apple AI"
        ))

        // Add AI sentiment if present (replaces NLP sentiment)
        if let sentiment = ai.sentiment {
            merged.append(TagSuggestion(
                tag: sentiment,
                confidence: 0.9,
                reason: "Sentiment by Apple AI"
            ))
        }

        // Add AI priority if present
        if let priority = ai.priority {
            merged.append(TagSuggestion(
                tag: priority,
                confidence: 0.9,
                reason: "Priority by Apple AI"
            ))
        }

        // Keep NLP tags that aren't category/sentiment/priority (entities, topics, attachments, time)
        let aiReplacedTags: Set<String> = nlpCategoryNames
            .union(["positive", "negative", "action required", "high priority", "medium priority", "alert priority"])
        for tag in nlpTags {
            if !aiReplacedTags.contains(tag.tag.lowercased()) {
                merged.append(tag)
            }
        }

        return merged
    }

    // MARK: - Apple AI Entity Enrichment

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func enrichEntityTags(in batchResults: [(UUID, [TagSuggestion])]) async -> [(UUID, [TagSuggestion])] {
        // Collect all entity tags across the batch
        var entityInputs: [(batchIdx: Int, tagIdx: Int, name: String, type: String)] = []
        for (batchIdx, (_, tags)) in batchResults.enumerated() {
            for (tagIdx, tag) in tags.enumerated() {
                // Entity tags have format "Person: Name", "Org: Name", "Place: Name"
                for prefix in ["Person: ", "Org: ", "Place: "] {
                    if tag.tag.hasPrefix(prefix) {
                        let name = String(tag.tag.dropFirst(prefix.count))
                        let type = String(prefix.dropLast(2))
                        entityInputs.append((batchIdx: batchIdx, tagIdx: tagIdx, name: name, type: type))
                        break
                    }
                }
            }
        }

        guard !entityInputs.isEmpty else { return batchResults }

        let inputs = entityInputs.map {
            FoundationModelEngine.EntityInput(name: $0.name, type: $0.type)
        }
        let enriched = await FoundationModelEngine.enrichEntities(inputs)

        var updated = batchResults
        for (i, enrichedEntity) in enriched.enumerated() {
            guard i < entityInputs.count else { break }
            let ref = entityInputs[i]
            guard ref.batchIdx < updated.count else { continue }
            var tags = updated[ref.batchIdx].1
            guard ref.tagIdx < tags.count else { continue }

            let contextSuffix = enrichedEntity.contextLabel.isEmpty ? "" : " (\(enrichedEntity.contextLabel))"
            let typePrefix: String
            switch enrichedEntity.type {
            case "Organization": typePrefix = "Org"
            default: typePrefix = enrichedEntity.type
            }
            tags[ref.tagIdx] = TagSuggestion(
                tag: "\(typePrefix): \(enrichedEntity.name)\(contextSuffix)",
                confidence: min(1.0, tags[ref.tagIdx].confidence + 0.1),
                reason: "Entity refined by Apple AI"
            )
            updated[ref.batchIdx] = (updated[ref.batchIdx].0, tags)
        }
        return updated
    }
    #endif

    // MARK: - Single Email Tagging

    func generateTagsForSingle(_ email: MBOXParser.RawEmail) -> [TagSuggestion] {
        Self.generateNLPTags(email)
    }

    private static func generateNLPTags(_ email: MBOXParser.RawEmail) -> [TagSuggestion] {
        var suggestions: [TagSuggestion] = []

        // 1. Entity-based tags (Person, Org, Place)
        suggestions.append(contentsOf: entityTags(for: email))

        // 2. Topic tags
        suggestions.append(contentsOf: topicTags(for: email))

        // 3. Sentiment tag
        if let sentimentTag = sentimentTag(for: email) {
            suggestions.append(sentimentTag)
        }

        // 4. Category tag
        suggestions.append(categoryTag(for: email))

        // 5. Attachment tags
        suggestions.append(contentsOf: attachmentTags(for: email))

        // 6. Time tag
        if let timeTag = timeTag(for: email) {
            suggestions.append(timeTag)
        }

        // 7. Priority tag
        if let priorityTag = priorityTag(for: email) {
            suggestions.append(priorityTag)
        }

        // Deduplicate and sort by confidence
        var seen = Set<String>()
        var unique: [TagSuggestion] = []
        for tag in suggestions.sorted(by: { $0.confidence > $1.confidence }) {
            let normalized = tag.tag.lowercased()
            if !seen.contains(normalized) {
                seen.insert(normalized)
                unique.append(tag)
            }
        }

        return unique
    }

    // MARK: - 1. Entity Tags

    private static func entityTags(for email: MBOXParser.RawEmail) -> [TagSuggestion] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        let body = bodyText(for: email)
        guard !body.isEmpty else { return [] }

        let text = String(body.prefix(3000))
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)

        var entities: [String: (type: String, count: Int)] = [:]
        let noiseNames: Set<String> = ["re", "fw", "fwd", "http", "https", "www", "com", "org", "net"]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, tokenRange in
            guard let tag = tag else { return true }
            let typeName: String
            switch tag {
            case .personalName: typeName = "Person"
            case .organizationName: typeName = "Org"
            case .placeName: typeName = "Place"
            default: return true
            }
            let entity = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if entity.count >= 2 && !noiseNames.contains(entity.lowercased()) {
                entities[entity, default: (type: typeName, count: 0)].count += 1
            }
            return true
        }

        return entities
            .sorted { $0.value.count > $1.value.count }
            .prefix(3)
            .map { entity in
                let confidence = min(1.0, Double(entity.value.count) / 5.0 + 0.3)
                return TagSuggestion(
                    tag: "\(entity.value.type): \(entity.key)",
                    confidence: confidence,
                    reason: "Named entity (\(entity.value.type.lowercased())) found \(entity.value.count) time(s)"
                )
            }
    }

    // MARK: - 2. Topic Tags

    private static func topicTags(for email: MBOXParser.RawEmail) -> [TagSuggestion] {
        let topics = EmailNLPEngine.extractTopics(from: [email], limit: 3)
        return topics.map { topic in
            let confidence = min(1.0, Double(topic.count) / 5.0 + 0.2)
            return TagSuggestion(
                tag: topic.word.capitalized,
                confidence: confidence,
                reason: "Top topic keyword (\(topic.count) occurrences)"
            )
        }
    }

    // MARK: - 3. Sentiment Tag

    private static func sentimentTag(for email: MBOXParser.RawEmail) -> TagSuggestion? {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        let body = bodyText(for: email)
        guard !body.isEmpty else { return nil }

        let text = String(body.prefix(2000))
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let score = Double(tag?.rawValue ?? "0") ?? 0

        if score > 0.5 {
            return TagSuggestion(
                tag: "Positive",
                confidence: min(1.0, score),
                reason: "Strong positive sentiment (score: \(String(format: "%.2f", score)))"
            )
        } else if score < -0.5 {
            return TagSuggestion(
                tag: "Negative",
                confidence: min(1.0, abs(score)),
                reason: "Strong negative sentiment (score: \(String(format: "%.2f", score)))"
            )
        }
        return nil
    }

    // MARK: - 4. Category Tag

    private static func categoryTag(for email: MBOXParser.RawEmail) -> TagSuggestion {
        let category = EmailNLPEngine.classify(email)
        let confidence: Double
        switch category {
        case .personal: confidence = 0.6
        case .newsletter: confidence = 0.8
        case .transactional: confidence = 0.8
        case .promotional: confidence = 0.75
        case .automated: confidence = 0.85
        case .unknown: confidence = 0.3
        }
        return TagSuggestion(
            tag: category.rawValue,
            confidence: confidence,
            reason: "Email classified as \(category.rawValue.lowercased())"
        )
    }

    // MARK: - 5. Attachment Tags

    private static func attachmentTags(for email: MBOXParser.RawEmail) -> [TagSuggestion] {
        guard !email.attachments.isEmpty else { return [] }

        var tags: [TagSuggestion] = [
            TagSuggestion(
                tag: "Has Attachments",
                confidence: 0.95,
                reason: "\(email.attachments.count) attachment(s) found"
            )
        ]

        // Detect specific types
        var typeSet = Set<String>()
        for attachment in email.attachments {
            let mime = attachment.mimeType.lowercased()
            let filename = attachment.filename.lowercased()
            if mime.contains("pdf") || filename.hasSuffix(".pdf") {
                typeSet.insert("PDF")
            } else if mime.hasPrefix("image/") || filename.hasSuffix(".png") || filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") || filename.hasSuffix(".gif") {
                typeSet.insert("Images")
            } else if mime.contains("spreadsheet") || filename.hasSuffix(".xlsx") || filename.hasSuffix(".csv") || filename.hasSuffix(".xls") {
                typeSet.insert("Spreadsheet")
            } else if mime.contains("document") || filename.hasSuffix(".docx") || filename.hasSuffix(".doc") {
                typeSet.insert("Document")
            } else if mime.contains("zip") || mime.contains("compressed") || filename.hasSuffix(".zip") || filename.hasSuffix(".gz") {
                typeSet.insert("Archive")
            }
        }

        for fileType in typeSet {
            tags.append(TagSuggestion(
                tag: fileType,
                confidence: 0.9,
                reason: "\(fileType) attachment detected"
            ))
        }

        return tags
    }

    // MARK: - 6. Time Tag

    private static func timeTag(for email: MBOXParser.RawEmail) -> TagSuggestion? {
        guard let dateStr = email.headers["Date"],
              let date = MBOXParser.parseDate(dateStr) else { return nil }

        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)
        if hour < 8 || hour >= 18 {
            return TagSuggestion(
                tag: "After Hours",
                confidence: 0.7,
                reason: "Sent at \(String(format: "%02d:%02d", hour, minute)) — outside typical business hours"
            )
        }
        return nil
    }

    // MARK: - 7. Priority Tag

    private static func priorityTag(for email: MBOXParser.RawEmail) -> TagSuggestion? {
        let subject = (email.headers["Subject"] ?? "").lowercased()
        let urgentKeywords = ["urgent", "asap", "action required", "immediate", "critical", "deadline", "time-sensitive", "important"]

        let matchedKeywords = urgentKeywords.filter { subject.contains($0) }
        if !matchedKeywords.isEmpty {
            let confidence = min(1.0, Double(matchedKeywords.count) * 0.4 + 0.4)
            return TagSuggestion(
                tag: "Action Required",
                confidence: confidence,
                reason: "Subject contains urgent keyword(s): \(matchedKeywords.joined(separator: ", "))"
            )
        }
        return nil
    }

    // MARK: - Helpers

    private static func bodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
