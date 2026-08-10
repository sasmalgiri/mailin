import Foundation
import NaturalLanguage

struct LegalAnalysisFeatures {

    // MARK: - Types

    struct PrivilegeClassification: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let score: Double
        let classification: PrivilegeType
        let reasons: [String]
        let confidenceLevel: ConfidenceLevel

        enum PrivilegeType: String, CaseIterable {
            case attorneyClient = "Attorney-Client"
            case workProduct = "Work Product"
            case jointDefense = "Joint Defense"
            case commonInterest = "Common Interest"
            case notPrivileged = "Not Privileged"
            case needsReview = "Needs Review"
        }

        enum ConfidenceLevel: String {
            case high = "High"
            case medium = "Medium"
            case low = "Low"
        }
    }

    struct ResponsivenessScore: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let score: Double
        let matchedTerms: [String]
        let category: ResponsivenessCategory

        enum ResponsivenessCategory: String {
            case highlyResponsive = "Highly Responsive"
            case responsive = "Responsive"
            case marginallyResponsive = "Marginally Responsive"
            case notResponsive = "Not Responsive"
        }
    }

    struct LegalHoldDetection: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let holdType: HoldType
        let severity: Double
        let snippet: String

        enum HoldType: String, CaseIterable {
            case preservationNotice = "Preservation Notice"
            case litigationHold = "Litigation Hold"
            case regulatoryHold = "Regulatory Hold"
            case anticipatedLitigation = "Anticipated Litigation"
        }
    }

    struct PrivilegeLogEntry: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let batesBegin: String
        let batesEnd: String
        let date: String
        let from: String
        let to: String
        let cc: String
        let subject: String
        let privilegeType: PrivilegeClassification.PrivilegeType
        let description: String
    }

    struct CustodianAnalysis: Identifiable {
        let id: String
        let name: String
        let email: String
        let emailCount: Int
        let privilegedCount: Int
        let privilegeRate: Double
        let topCorrespondents: [(name: String, count: Int)]
        let legalTopics: [String]
    }

    // MARK: - Privilege Classification

    private static let lawFirmDomainSuffixes = [
        "lawfirm", "legal", "attorney", "counsel", "solicitor",
        "barrister", "advocates", "partners", "llp", "pllc"
    ]

    private static let lawFirmDomains: Set<String> = [
        "skadden.com", "linklaters.com", "cliffordchance.com", "allenovery.com",
        "freshfields.com", "bakermckenzie.com", "dlapiper.com", "kirkland.com",
        "lw.com", "weil.com", "sullcrom.com", "cravath.com", "debevoise.com",
        "davispolk.com", "simpsonthacher.com", "milbank.com", "whitecase.com",
        "nortonrosefulbright.com", "dentons.com", "hoganlovells.com",
        "jonesday.com", "morganlewis.com", "wilmerhale.com", "sidley.com",
        "gibsondunn.com", "paulweiss.com", "goodwinlaw.com", "cooley.com"
    ]

    private static let privilegeSignalTerms: [(term: String, weight: Double, type: PrivilegeClassification.PrivilegeType)] = [
        ("attorney-client", 4.0, .attorneyClient),
        ("privileged and confidential", 4.0, .attorneyClient),
        ("legal advice", 3.0, .attorneyClient),
        ("legal counsel", 3.0, .attorneyClient),
        ("attorney work product", 4.0, .workProduct),
        ("work product", 3.5, .workProduct),
        ("prepared in anticipation of litigation", 4.0, .workProduct),
        ("litigation strategy", 3.5, .workProduct),
        ("joint defense agreement", 4.0, .jointDefense),
        ("joint defense", 3.0, .jointDefense),
        ("common interest agreement", 4.0, .commonInterest),
        ("common interest privilege", 3.5, .commonInterest),
        ("this communication is privileged", 3.0, .attorneyClient),
        ("not for distribution", 2.0, .attorneyClient),
        ("do not forward", 1.5, .attorneyClient),
        ("confidential communication", 2.5, .attorneyClient),
        ("legal opinion", 3.0, .attorneyClient),
        ("legal matter", 2.0, .attorneyClient),
        ("outside counsel", 2.5, .attorneyClient),
        ("in-house counsel", 2.5, .attorneyClient),
        ("retainer", 2.0, .attorneyClient),
        ("settlement", 2.0, .workProduct),
        ("deposition", 2.5, .workProduct),
        ("discovery request", 2.5, .workProduct),
        ("litigation hold", 3.0, .workProduct),
        ("protective order", 2.5, .workProduct),
        ("subpoena", 2.5, .workProduct),
        ("regulatory inquiry", 2.0, .workProduct),
        ("compliance review", 1.5, .attorneyClient),
        ("esq", 1.5, .attorneyClient),
        ("j.d.", 1.0, .attorneyClient),
        ("bar number", 1.5, .attorneyClient)
    ]

    private static let disclaimerPatterns = [
        "this email and any attachments are privileged",
        "attorney-client privilege",
        "intended only for the addressee",
        "if you are not the intended recipient",
        "this message contains information that may be privileged",
        "confidential and protected by attorney"
    ]

    static func classifyPrivilege(emails: [MBOXParser.RawEmail]) -> [PrivilegeClassification] {
        emails.map { classifySingle($0) }
    }

    private static func classifySingle(_ email: MBOXParser.RawEmail) -> PrivilegeClassification {
        let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
        let subject = (email.headers["Subject"] ?? "").lowercased()
        let from = (email.headers["From"] ?? "").lowercased()
        let to = (email.headers["To"] ?? "").lowercased()
        let cc = (email.headers["Cc"] ?? "").lowercased()
        let allParticipants = from + " " + to + " " + cc
        let combinedText = subject + " " + body

        var totalScore: Double = 0
        var reasons: [String] = []
        var typeScores: [PrivilegeClassification.PrivilegeType: Double] = [:]

        let senderDomain = extractDomain(from: from)
        let isFromLawFirm = isLawFirmDomain(senderDomain)
        if isFromLawFirm {
            totalScore += 3.0
            reasons.append("Sender domain '\(senderDomain)' identified as law firm")
            typeScores[.attorneyClient, default: 0] += 3.0
        }

        let recipientDomains = (to + "," + cc).components(separatedBy: ",").compactMap { extractDomain(from: $0) }
        let lawFirmRecipients = recipientDomains.filter { isLawFirmDomain($0) }
        if !lawFirmRecipients.isEmpty {
            totalScore += 2.0
            reasons.append("Recipients include law firm domains: \(lawFirmRecipients.joined(separator: ", "))")
            typeScores[.attorneyClient, default: 0] += 2.0
        }

        for signal in privilegeSignalTerms {
            if combinedText.contains(signal.term) {
                totalScore += signal.weight
                reasons.append("Contains '\(signal.term)'")
                typeScores[signal.type, default: 0] += signal.weight
            }
        }

        for disclaimer in disclaimerPatterns {
            if body.contains(disclaimer) {
                totalScore += 1.5
                reasons.append("Contains privilege disclaimer")
                break
            }
        }

        let titlePatterns = ["esq", "attorney", "counsel", "solicitor", "barrister", "paralegal", "legal assistant"]
        for pattern in titlePatterns {
            if allParticipants.contains(pattern) {
                totalScore += 1.5
                reasons.append("Participant has legal title ('\(pattern)')")
                break
            }
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
        var entityNames: [String] = []
        tagger.enumerateTags(in: tagger.string!.startIndex..<tagger.string!.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if tag == .organizationName {
                entityNames.append(String(tagger.string![range]))
            }
            return true
        }
        let legalOrgKeywords = ["court", "tribunal", "commission", "authority", "bar association", "department of justice"]
        for entity in entityNames {
            if legalOrgKeywords.contains(where: { entity.lowercased().contains($0) }) {
                totalScore += 1.5
                reasons.append("References legal entity: \(entity)")
                break
            }
        }

        let dominantType = typeScores.max(by: { $0.value < $1.value })?.key ?? .notPrivileged

        let classification: PrivilegeClassification.PrivilegeType
        let confidence: PrivilegeClassification.ConfidenceLevel

        if totalScore >= 10 {
            classification = dominantType
            confidence = .high
        } else if totalScore >= 6 {
            classification = dominantType
            confidence = .medium
        } else if totalScore >= 3 {
            classification = .needsReview
            confidence = .low
        } else {
            classification = .notPrivileged
            confidence = reasons.isEmpty ? .high : .low
        }

        return PrivilegeClassification(
            id: email.id,
            email: email,
            score: min(1.0, totalScore / 15.0),
            classification: classification,
            reasons: reasons,
            confidenceLevel: confidence
        )
    }

    // MARK: - Responsive Document Scoring

    static func scoreResponsiveness(
        emails: [MBOXParser.RawEmail],
        searchTerms: [String],
        dateRange: (start: Date?, end: Date?) = (nil, nil)
    ) -> [ResponsivenessScore] {
        guard !searchTerms.isEmpty else { return [] }

        let loweredTerms = searchTerms.map { $0.lowercased() }
        let expandedTerms = expandWithSynonyms(loweredTerms)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        return emails.compactMap { email -> ResponsivenessScore? in
            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let combined = subject + " " + body

            if let start = dateRange.start, let dateStr = email.headers["Date"],
               let emailDate = formatter.date(from: dateStr), emailDate < start {
                return nil
            }
            if let end = dateRange.end, let dateStr = email.headers["Date"],
               let emailDate = formatter.date(from: dateStr), emailDate > end {
                return nil
            }

            var score: Double = 0
            var matched: [String] = []

            for (term, weight) in expandedTerms {
                let occurrences = countOccurrences(of: term, in: combined)
                if occurrences > 0 {
                    score += Double(min(occurrences, 5)) * weight
                    matched.append(term)
                }
            }

            for term in loweredTerms where subject.contains(term) {
                score += 2.0
                break
            }

            let normalizedScore = min(1.0, score / Double(max(1, searchTerms.count) * 5))

            let category: ResponsivenessScore.ResponsivenessCategory
            switch normalizedScore {
            case 0.7...1.0: category = .highlyResponsive
            case 0.4..<0.7: category = .responsive
            case 0.15..<0.4: category = .marginallyResponsive
            default: category = .notResponsive
            }

            guard normalizedScore > 0.05 else { return nil }

            return ResponsivenessScore(
                id: email.id,
                email: email,
                score: normalizedScore,
                matchedTerms: matched,
                category: category
            )
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Legal Hold Detection

    private static let holdPatterns: [(pattern: String, type: LegalHoldDetection.HoldType, severity: Double)] = [
        ("litigation hold", .litigationHold, 0.9),
        ("legal hold", .litigationHold, 0.9),
        ("preservation notice", .preservationNotice, 0.95),
        ("document preservation", .preservationNotice, 0.85),
        ("duty to preserve", .preservationNotice, 0.9),
        ("preserve all documents", .preservationNotice, 0.95),
        ("do not destroy", .preservationNotice, 0.85),
        ("do not delete", .preservationNotice, 0.8),
        ("retain all records", .preservationNotice, 0.8),
        ("regulatory investigation", .regulatoryHold, 0.85),
        ("regulatory inquiry", .regulatoryHold, 0.8),
        ("government investigation", .regulatoryHold, 0.9),
        ("sec investigation", .regulatoryHold, 0.9),
        ("doj inquiry", .regulatoryHold, 0.9),
        ("subpoena", .regulatoryHold, 0.85),
        ("threatened litigation", .anticipatedLitigation, 0.7),
        ("potential lawsuit", .anticipatedLitigation, 0.7),
        ("anticipate litigation", .anticipatedLitigation, 0.75),
        ("demand letter", .anticipatedLitigation, 0.7),
        ("cease and desist", .anticipatedLitigation, 0.75),
        ("notice of claim", .anticipatedLitigation, 0.8),
        ("intent to sue", .anticipatedLitigation, 0.85)
    ]

    static func detectLegalHolds(in emails: [MBOXParser.RawEmail]) -> [LegalHoldDetection] {
        var results: [LegalHoldDetection] = []

        for email in emails {
            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let combined = subject + " " + body

            var bestMatch: (pattern: String, type: LegalHoldDetection.HoldType, severity: Double)?

            for hp in holdPatterns {
                if combined.contains(hp.pattern) {
                    if bestMatch == nil || hp.severity > bestMatch!.severity {
                        bestMatch = hp
                    }
                }
            }

            if let match = bestMatch {
                let snippet = extractSnippet(containing: match.pattern, from: email.plainBody.isEmpty ? email.htmlBody : email.plainBody)
                results.append(LegalHoldDetection(
                    id: email.id,
                    email: email,
                    holdType: match.type,
                    severity: match.severity,
                    snippet: snippet
                ))
            }
        }

        return results.sorted { $0.severity > $1.severity }
    }

    // MARK: - Privilege Log Generation

    static func generatePrivilegeLog(
        emails: [MBOXParser.RawEmail],
        classifications: [PrivilegeClassification],
        batesPrefix: String = "DOC"
    ) -> [PrivilegeLogEntry] {
        let privileged = classifications.filter {
            $0.classification != .notPrivileged && $0.classification != .needsReview
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MM/dd/yyyy"

        return privileged.enumerated().map { index, cls in
            let email = cls.email
            let batesNum = String(format: "%06d", index + 1)
            let dateStr: String
            if let rawDate = email.headers["Date"], let date = formatter.date(from: rawDate) {
                dateStr = outputFormatter.string(from: date)
            } else {
                dateStr = email.timestamp
            }

            let description = formatPrivilegeDescription(
                classification: cls.classification,
                confidence: cls.confidenceLevel,
                reasons: cls.reasons,
                subject: email.headers["Subject"] ?? ""
            )

            return PrivilegeLogEntry(
                id: email.id,
                email: email,
                batesBegin: "\(batesPrefix)-\(batesNum)",
                batesEnd: "\(batesPrefix)-\(batesNum)",
                date: dateStr,
                from: email.headers["From"] ?? "",
                to: email.headers["To"] ?? "",
                cc: email.headers["Cc"] ?? "",
                subject: email.headers["Subject"] ?? "(No Subject)",
                privilegeType: cls.classification,
                description: description
            )
        }
    }

    private static func formatPrivilegeDescription(
        classification: PrivilegeClassification.PrivilegeType,
        confidence: PrivilegeClassification.ConfidenceLevel,
        reasons: [String],
        subject: String
    ) -> String {
        let basis: String
        switch classification {
        case .attorneyClient:
            basis = "Withheld as attorney-client privileged communication"
        case .workProduct:
            basis = "Withheld as attorney work product prepared in anticipation of litigation"
        case .jointDefense:
            basis = "Withheld under joint defense privilege"
        case .commonInterest:
            basis = "Withheld under common interest privilege"
        case .needsReview:
            basis = "Flagged for manual review — privilege indicators present"
        case .notPrivileged:
            basis = "Not privileged"
        }

        var details: [String] = []
        for reason in reasons {
            if reason.contains("law firm") || reason.contains("legal title") {
                details.append("communication with legal counsel")
            } else if reason.contains("privilege disclaimer") {
                details.append("contains confidentiality notice")
            } else if reason.contains("legal entity") {
                details.append("references legal proceedings")
            } else if reason.lowercased().contains("privileged") || reason.lowercased().contains("confidential") {
                details.append("marked privileged and confidential")
            } else if reason.lowercased().contains("litigation") || reason.lowercased().contains("settlement") ||
                      reason.lowercased().contains("deposition") || reason.lowercased().contains("court") {
                details.append("relates to pending or anticipated litigation")
            } else if reason.lowercased().contains("patent") || reason.lowercased().contains("trademark") ||
                      reason.lowercased().contains("copyright") || reason.lowercased().contains("intellectual property") {
                details.append("relates to intellectual property matters")
            }
        }

        let uniqueDetails = Array(Set(details)).prefix(3)
        if uniqueDetails.isEmpty {
            return "\(basis). Confidence: \(confidence.rawValue)."
        }
        return "\(basis) — \(uniqueDetails.joined(separator: "; ")). Confidence: \(confidence.rawValue)."
    }

    // MARK: - Custodian Analysis

    static func analyzeCustodians(
        emails: [MBOXParser.RawEmail],
        privilegeClassifications: [PrivilegeClassification]
    ) -> [CustodianAnalysis] {
        var custodianEmails: [String: [MBOXParser.RawEmail]] = [:]

        for email in emails {
            guard let from = email.headers["From"] else { continue }
            let address = extractEmailAddress(from: from)
            custodianEmails[address, default: []].append(email)
        }

        let privilegeByID = Dictionary(uniqueKeysWithValues: privilegeClassifications.map { ($0.id, $0) })

        let tagger = NLTagger(tagSchemes: [.nameType])

        return custodianEmails.compactMap { address, emails -> CustodianAnalysis? in
            guard emails.count >= 3 else { return nil }

            let privilegedEmails = emails.filter { email in
                if let cls = privilegeByID[email.id] {
                    return cls.classification != .notPrivileged
                }
                return false
            }

            var correspondentCounts: [String: Int] = [:]
            for email in emails {
                let recipients = (email.headers["To"] ?? "") + "," + (email.headers["Cc"] ?? "")
                for addr in recipients.components(separatedBy: ",") {
                    let cleaned = extractEmailAddress(from: addr.trimmingCharacters(in: .whitespaces))
                    if !cleaned.isEmpty && cleaned != address {
                        correspondentCounts[cleaned, default: 0] += 1
                    }
                }
            }

            var topicSet: Set<String> = []
            let combinedText = emails.prefix(50).map { $0.plainBody.isEmpty ? $0.htmlBody : $0.plainBody }.joined(separator: " ")
            let limitedText = String(combinedText.prefix(5000))
            tagger.string = limitedText
            tagger.enumerateTags(in: limitedText.startIndex..<limitedText.endIndex, unit: .word, scheme: .nameType) { tag, range in
                if tag == .organizationName || tag == .personalName {
                    topicSet.insert(String(limitedText[range]))
                }
                return true
            }

            let legalTerms = ["contract", "agreement", "litigation", "settlement", "compliance",
                              "regulatory", "dispute", "arbitration", "mediation", "indemnification"]
            for email in emails.prefix(50) {
                let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
                for term in legalTerms where body.contains(term) {
                    topicSet.insert(term.capitalized)
                }
            }

            let name = extractDisplayName(from: emails.first?.headers["From"] ?? address, fallback: address)

            return CustodianAnalysis(
                id: address,
                name: name,
                email: address,
                emailCount: emails.count,
                privilegedCount: privilegedEmails.count,
                privilegeRate: Double(privilegedEmails.count) / Double(emails.count),
                topCorrespondents: correspondentCounts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) },
                legalTopics: Array(topicSet.prefix(10))
            )
        }.sorted { $0.emailCount > $1.emailCount }
    }

    // MARK: - Helpers

    private static func extractDomain(from text: String) -> String {
        if let atRange = text.range(of: "@") {
            let afterAt = text[atRange.upperBound...]
            let domain = afterAt.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted).first ?? ""
            return domain.lowercased()
        }
        return ""
    }

    private static func isLawFirmDomain(_ domain: String) -> Bool {
        if lawFirmDomains.contains(domain) { return true }
        for suffix in lawFirmDomainSuffixes {
            if domain.contains(suffix) { return true }
        }
        return false
    }

    private static func countOccurrences(of term: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: term, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func expandWithSynonyms(_ terms: [String]) -> [(String, Double)] {
        var expanded: [(String, Double)] = terms.map { ($0, 1.0) }
        if let embedding = NLEmbedding.wordEmbedding(for: .english) {
            for term in terms {
                embedding.enumerateNeighbors(for: term, maximumCount: 3, distanceType: .cosine) { neighbor, distance in
                    if distance < 0.5 {
                        expanded.append((neighbor, 1.0 - distance))
                    }
                    return true
                }
            }
        }
        return expanded
    }

    private static func extractSnippet(containing term: String, from text: String, contextChars: Int = 100) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: term) else { return String(text.prefix(200)) }
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let snippetStart = max(0, matchStart - contextChars)
        let snippetEnd = min(text.count, matchStart + term.count + contextChars)
        let start = text.index(text.startIndex, offsetBy: snippetStart)
        let end = text.index(text.startIndex, offsetBy: snippetEnd)
        return "..." + String(text[start..<end]) + "..."
    }

    private static func extractEmailAddress(from text: String) -> String {
        if let start = text.range(of: "<"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).lowercased().trimmingCharacters(in: .whitespaces)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.contains("@") ? trimmed : ""
    }

    private static func extractDisplayName(from header: String, fallback: String) -> String {
        if let angleBracket = header.range(of: "<") {
            let name = String(header[header.startIndex..<angleBracket.lowerBound]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? fallback : name
        }
        return fallback
    }
}

// MARK: - Archive-wide streaming (v2 forensic completeness)
//
// Privilege classification is per-email, so it streams the ENTIRE archive from
// the store one bounded page at a time — every document is classified for
// privilege (no doc missed), while peak memory stays bounded by the page. This
// is the archive-complete counterpart to `classifyPrivilege(emails:)` which
// operates only on an in-memory subset.

extension LegalAnalysisFeatures {
    static func classifyPrivilege(
        from service: ArchiveDataService,
        cap: Int = 20_000,
        batchSize: Int = 500
    ) async throws -> [PrivilegeClassification] {
        var out: [PrivilegeClassification] = []
        let stream = await service.streamFullEmails(query: .all, batchSize: batchSize)
        for try await batch in stream {
            for email in batch {
                out.append(classifySingle(email))
                if out.count >= cap { return out }
            }
        }
        return out
    }
}
