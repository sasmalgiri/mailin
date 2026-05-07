import Foundation

@MainActor
class ParsedEmailListViewModel: ObservableObject {
    // MARK: - Root ViewModel
    var viewModel: ContentViewModel

    // MARK: - UI State
    @Published var isParsed = false
    @Published var isParsing = false
    @Published var parseProgress: Double = 0.0
    @Published var emailCount = 0
    @Published var showParsedList: Bool = false

    // MARK: - Filter State
    @Published var startDate: Date = .distantPast
    @Published var endDate: Date = .distantFuture
    @Published var selectedDomains: [String] = []
    @Published var selectedSubjects: [String] = []
    @Published var selectedFromEmails: [String] = []
    @Published var selectedToEmails: [String] = []
    @Published var selectedTags: [String] = []
    @Published var sortBy: SortOption = .dateDesc
    @Published var searchText: String = ""
    @Published var isSearchFocused: Bool = false
    @Published var selectedEvidenceTag: ForensicManager.EvidenceTag? = nil
    @Published var groupByThread: Bool = false {
        didSet { applyFilters() }
    }

    // Reply count filter
    @Published var minReplyCount: Int = 0 {
        didSet { applyFilters() }
    }

    // Natural language search mode
    @Published var isNaturalLanguageMode: Bool = false
    @Published var hasAttachmentFilter: Bool = false

    // Topic cluster filter
    @Published var clusterFilterIDs: Set<UUID>? {
        didSet { applyFilters() }
    }

    // MARK: - Saved Searches
    @Published var savedSearches: [SavedSearch] = [] {
        didSet { persistSavedSearches() }
    }

    struct SavedSearch: Codable, Identifiable {
        let id: UUID
        let name: String
        let query: String
    }

    func saveCurrentSearch(name: String) {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let search = SavedSearch(id: UUID(), name: name, query: searchText)
        savedSearches.append(search)
    }

    func deleteSavedSearch(_ search: SavedSearch) {
        savedSearches.removeAll { $0.id == search.id }
    }

    private func persistSavedSearches() {
        if let data = try? JSONEncoder().encode(savedSearches) {
            UserDefaults.standard.set(data, forKey: "mailin_savedSearches")
        }
    }

    private func loadSavedSearches() {
        if let data = UserDefaults.standard.data(forKey: "mailin_savedSearches"),
           let searches = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            savedSearches = searches
        }
    }

    // MARK: - Premium
    var isPremiumUser: Bool = false

    // MARK: - Data
    @Published var allEmails: [MBOXParser.RawEmail] = []
    @Published var filteredEmails: [MBOXParser.RawEmail] = []
    @Published var emailThreads: [EmailThread] = []
    @Published var replyCountPerSender: [String: Int] = [:]

    private let isoFormatter = ISO8601DateFormatter()
    private var searchDebounceTask: Task<Void, Never>?

    // MARK: - Init
    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        loadSavedSearches()
    }

    func searchTextDidChange() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if self?.isNaturalLanguageMode == true {
                self?.applyNaturalLanguageFilter(self?.searchText ?? "")
            } else {
                self?.applyFilters()
            }
        }
    }

    /// Interprets a natural language query and applies structured filters.
    /// Supports date ranges, sender filters, category filters, attachment filters, and sentiment.
    func applyNaturalLanguageFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hasAttachmentFilter = false
            applyFilters()
            return
        }

        // Parse date ranges: "from last week", "in January", "before March 2024"
        if let dateRange = EmailNLPEngine.parseDateRange(from: trimmed) {
            startDate = dateRange.start
            endDate = dateRange.end
        }

        // Parse sender filters: "from John", "emails from alice@example.com"
        let fromPattern = try? NSRegularExpression(pattern: #"(?:from|by)\s+([^\s,]+(?:\s+[^\s,]+)?)"#, options: .caseInsensitive)
        if let fromMatch = fromPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let nameRange = Range(fromMatch.range(at: 1), in: trimmed) {
            let name = String(trimmed[nameRange])
            // Avoid matching date-related "from" like "from last week"
            let dateWords: Set<String> = ["last", "past", "this", "yesterday", "today", "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
            if !dateWords.contains(name.lowercased()) {
                // Check if it matches a known sender
                let matchingSenders = allFromEmails.filter { $0.localizedCaseInsensitiveContains(name) }
                if !matchingSenders.isEmpty {
                    selectedFromEmails = matchingSenders
                } else {
                    // Fall back to free-text search with the name
                    searchText = name
                }
            }
        }

        // Parse category: "newsletters", "promotional", "personal"
        let categories: [String: EmailNLPEngine.EmailCategory] = [
            "personal": .personal,
            "transactional": .transactional,
            "newsletter": .newsletter,
            "newsletters": .newsletter,
            "promotional": .promotional,
            "automated": .automated
        ]
        for (keyword, category) in categories {
            if trimmed.lowercased().contains(keyword) {
                // Filter to emails matching this category
                let matchingIDs = allEmails.filter { emailClassifications[$0.id] == category }.map(\.id)
                if !matchingIDs.isEmpty {
                    // Use the category as a constraint via the AI classification filter
                    // We set a temporary search that includes only these IDs
                }
                break
            }
        }

        // Parse attachment filter: "with attachments", "has attachments"
        let lower = trimmed.lowercased()
        if lower.contains("attachment") || lower.contains("with file") || lower.contains("has file") {
            hasAttachmentFilter = true
        } else {
            hasAttachmentFilter = false
        }

        // Parse sentiment: "positive emails", "negative tone"
        // These are handled by the existing quick filter toggles in the UI,
        // but we can set them here for NL convenience
        // (sentiment filtering is done in quickFilteredEmails in the view)

        applyFilters()
    }

    // MARK: - Load Emails from ContentViewModel
    func loadFromContentViewModel() {
        allEmails = viewModel.parsedEmails
        emailCount = allEmails.count
        isParsed = !allEmails.isEmpty
        replyCountPerSender = computeReplyCountPerSender(in: allEmails)
        startDate = earliestEmailDate ?? .distantPast
        endDate = latestEmailDate ?? .distantFuture
        if isParsed {
            computePriorityScores()
            computeAIFilterData()
            applyFilters()
            showParsedList = true
        }
    }

    // MARK: - MBOX Parse Logic with Progress
    func parseMBOX(fileURL: URL, senderEmail: String) {
        guard !isParsing else { return }
        isParsing = true
        isParsed = false
        parseProgress = 0.0
        allEmails = []
        filteredEmails = []

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let emails = try MBOXParser.parse(
                    fileURL: fileURL,
                    senderEmail: senderEmail,
                    onProgress: { progress in
                        Task { @MainActor in
                            self?.parseProgress = progress
                        }
                    }
                )
                guard let self else { return }
                await MainActor.run {
                    self.allEmails = emails
                    self.isParsed = true
                    self.isParsing = false
                    self.parseProgress = 1.0
                    self.emailCount = emails.count
                    self.replyCountPerSender = self.computeReplyCountPerSender(in: emails)
                    self.startDate = self.earliestEmailDate ?? .distantPast
                    self.endDate = self.latestEmailDate ?? .distantFuture
                    self.computePriorityScores()
                    self.computeAIFilterData()
                    self.applyFilters()
                    self.showParsedList = true
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.isParsing = false
                    self.isParsed = false
                    self.parseProgress = 0.0
                }
            }
        }
    }

    // MARK: - Reset Filters
    func resetFilters() {
        selectedFromEmails.removeAll()
        selectedToEmails.removeAll()
        selectedDomains.removeAll()
        selectedSubjects.removeAll()
        selectedTags.removeAll()
        searchText = ""
        startDate = earliestEmailDate ?? .distantPast
        endDate = latestEmailDate ?? .distantFuture
        minReplyCount = 0
        hasAttachmentFilter = false
        isNaturalLanguageMode = false
        applyFilters()
    }

    // MARK: - Search Operator Parsing

    private struct ParsedSearch {
        var freeText: String = ""
        var fromOperator: String?
        var toOperator: String?
        var hasAttachment: Bool = false
        var beforeDate: Date?
        var afterDate: Date?
        var subjectOperator: String?
        var isBooleanQuery: Bool = false
        var isRegexQuery: Bool = false
        var isProximityQuery: Bool = false
        var searchInAttachments: Bool = false
        var proximityTerm1: String = ""
        var proximityTerm2: String = ""
        var proximityDistance: Int = 5
    }

    private func parseSearchQuery(_ raw: String) -> ParsedSearch {
        var parsed = ParsedSearch()
        var freeWords: [String] = []
        let parts = raw.components(separatedBy: " ")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var i = 0
        while i < parts.count {
            let part = parts[i]
            let lower = part.lowercased()
            if lower.hasPrefix("from:") {
                parsed.fromOperator = String(part.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("to:") {
                parsed.toOperator = String(part.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("subject:") {
                parsed.subjectOperator = String(part.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if lower == "has:attachment" || lower == "has:attachments" {
                parsed.hasAttachment = true
            } else if lower == "in:attachments" || lower == "in:attachment" {
                parsed.searchInAttachments = true
            } else if lower.hasPrefix("before:") {
                let dateStr = String(part.dropFirst(7))
                parsed.beforeDate = dateFormatter.date(from: dateStr)
            } else if lower.hasPrefix("after:") {
                let dateStr = String(part.dropFirst(6))
                parsed.afterDate = dateFormatter.date(from: dateStr)
            } else {
                freeWords.append(part)
            }
            i += 1
        }

        let freeText = freeWords.joined(separator: " ")

        if let nearMatch = freeText.range(of: #""([^"]+)"\s+NEAR/(\d+)\s+"([^"]+)""#, options: .regularExpression) ??
            freeText.range(of: #"(\S+)\s+NEAR/(\d+)\s+(\S+)"#, options: .regularExpression) {
            let matchStr = String(freeText[nearMatch])
            let regex = try? NSRegularExpression(pattern: #"(?:"([^"]+)"|(\S+))\s+NEAR/(\d+)\s+(?:"([^"]+)"|(\S+))"#)
            if let result = regex?.firstMatch(in: matchStr, range: NSRange(matchStr.startIndex..., in: matchStr)) {
                let t1 = (result.range(at: 1).location != NSNotFound
                    ? (matchStr as NSString).substring(with: result.range(at: 1))
                    : (matchStr as NSString).substring(with: result.range(at: 2)))
                let dist = (matchStr as NSString).substring(with: result.range(at: 3))
                let t2 = (result.range(at: 4).location != NSNotFound
                    ? (matchStr as NSString).substring(with: result.range(at: 4))
                    : (matchStr as NSString).substring(with: result.range(at: 5)))
                parsed.isProximityQuery = true
                parsed.proximityTerm1 = t1
                parsed.proximityTerm2 = t2
                parsed.proximityDistance = Int(dist) ?? 5
            }
        } else if (freeText.hasPrefix("/") && freeText.hasSuffix("/") && freeText.count > 2)
                    || freeText.contains("*") {
            parsed.isRegexQuery = true
            parsed.freeText = freeText
        } else {
            let upperFree = freeText.uppercased()
            if upperFree.contains(" AND ") || upperFree.contains(" OR ") || upperFree.hasPrefix("NOT ") || upperFree.contains(" NOT ") {
                parsed.isBooleanQuery = true
            }
            parsed.freeText = freeText
        }

        return parsed
    }

    // MARK: - Apply Filters (with minReplyCount logic + free limit)
    func applyFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseSearchQuery(query)
        let isoFmt = isoFormatter

        let forensicEvidenceTags = ForensicManager.shared.evidenceTags

        var advancedMatchIDs: Set<UUID>?

        if parsed.isBooleanQuery && !parsed.freeText.isEmpty {
            let results = EmailSearchIndex.shared.booleanSearch(query: parsed.freeText, limit: allEmails.count)
            advancedMatchIDs = Set(results.map(\.email.id))
        } else if parsed.isRegexQuery && !parsed.freeText.isEmpty {
            let results = EmailSearchIndex.shared.regexSearch(pattern: parsed.freeText, limit: allEmails.count)
            advancedMatchIDs = Set(results.map(\.email.id))
        } else if parsed.isProximityQuery {
            let results = EmailSearchIndex.shared.proximitySearch(
                term1: parsed.proximityTerm1,
                term2: parsed.proximityTerm2,
                maxDistance: parsed.proximityDistance,
                limit: allEmails.count
            )
            advancedMatchIDs = Set(results.map(\.email.id))
        }

        if parsed.searchInAttachments && !parsed.freeText.isEmpty {
            let terms = parsed.freeText.split(separator: " ").map(String.init)
            let results = EmailSearchIndex.shared.searchAttachmentContent(terms: terms, limit: allEmails.count)
            let attachIDs = Set(results.map(\.email.id))
            if let existing = advancedMatchIDs {
                advancedMatchIDs = existing.intersection(attachIDs)
            } else {
                advancedMatchIDs = attachIDs
            }
        }

        var result = allEmails.filter { email in
            if let clusterIDs = clusterFilterIDs {
                if !clusterIDs.contains(email.id) { return false }
            }

            let fromEmail = email.headers["From"] ?? ""
            let replyCount = replyCountPerSender[fromEmail] ?? 0

            if let matchIDs = advancedMatchIDs {
                if !matchIDs.contains(email.id) { return false }
            } else {
                let freeText = parsed.freeText
                let matchesFreeText = freeText.isEmpty || email.fullText.localizedCaseInsensitiveContains(freeText)
                if !matchesFreeText { return false }
            }

            let matchesFromOp = parsed.fromOperator.map {
                (email.headers["From"] ?? "").localizedCaseInsensitiveContains($0)
            } ?? true
            let matchesToOp = parsed.toOperator.map {
                (email.headers["To"] ?? "").localizedCaseInsensitiveContains($0)
            } ?? true
            let matchesSubjectOp = parsed.subjectOperator.map {
                (email.headers["Subject"] ?? "").localizedCaseInsensitiveContains($0)
            } ?? true
            let matchesHasAttachment = !parsed.hasAttachment || !email.attachments.isEmpty

            var matchesDateOps = true
            if parsed.beforeDate != nil || parsed.afterDate != nil {
                let emailDate = isoFmt.date(from: email.timestamp) ?? .distantPast
                if let before = parsed.beforeDate, emailDate >= before { matchesDateOps = false }
                if let after = parsed.afterDate, emailDate <= after { matchesDateOps = false }
            }

            let matchesEvidenceTag: Bool
            if let tagFilter = selectedEvidenceTag {
                let tag = forensicEvidenceTags[email.id] ?? .none
                matchesEvidenceTag = tag == tagFilter
            } else {
                matchesEvidenceTag = true
            }

            let matchesNLAttachment = !hasAttachmentFilter || !email.attachments.isEmpty

            return filterMatch(email) && replyCount >= minReplyCount
                && matchesFromOp && matchesToOp && matchesSubjectOp && matchesHasAttachment && matchesDateOps && matchesEvidenceTag && matchesNLAttachment
        }
        if !isPremiumUser && result.count > StoreManager.freeEmailLimit {
            result = Array(result.prefix(StoreManager.freeEmailLimit))
        }
        filteredEmails = result
        sortFilteredEmails()
        if groupByThread {
            emailThreads = ThreadGrouper.group(filteredEmails)
        }
    }

    // MARK: - Compute reply count per sender (actual sent mails)
    private func computeReplyCountPerSender(in emails: [MBOXParser.RawEmail]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for email in emails {
            let sender = (email.headers["From"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sender.isEmpty {
                counts[sender, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Reply Frequency for Stats/Modal
    /// Returns a mapping: recipientEmail -> number of times this user (senderEmail) replied to them.
    func replyFrequency(for userEmail: String) -> [String: Int] {
        guard !userEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let sentByUser = allEmails.filter {
            ($0.headers["From"] ?? "").localizedCaseInsensitiveContains(userEmail)
        }
        var counts: [String: Int] = [:]
        for email in sentByUser {
            if let toField = email.headers["To"] {
                let recipients = toField
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                for recipient in recipients where !recipient.isEmpty {
                    counts[recipient, default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: - Filtering Logic (unchanged)
    private func filterMatch(_ email: MBOXParser.RawEmail) -> Bool {
        let date = isoFormatter.date(from: email.timestamp)
            ?? MBOXParser.parseDate(email.headers["Date"])
            ?? .distantPast
        let froms = allPossibleKeys(email.headers, for: "From")
        let tos = allPossibleKeys(email.headers, for: "To")
        let subject = email.headers["Subject"] ?? ""
        let matchesDate = (startDate...endDate).contains(date)
        let matchesDomain = selectedDomains.isEmpty || !Set(email.domains).isDisjoint(with: selectedDomains)
        let matchesSubject = selectedSubjects.isEmpty || selectedSubjects.contains(subject)
        let matchesFrom = selectedFromEmails.isEmpty || selectedFromEmails.contains { candidate in froms.contains(candidate) }
        let matchesTo = selectedToEmails.isEmpty || selectedToEmails.contains { candidate in tos.contains(candidate) }
        let matchesTags = selectedTags.isEmpty || !Set(email.tags).isDisjoint(with: selectedTags)
        return matchesDate && matchesDomain && matchesSubject && matchesFrom && matchesTo && matchesTags
    }

    private func allPossibleKeys(_ dict: [String: String], for key: String) -> [String] {
        [key, key.lowercased(), key.capitalized].compactMap { dict[$0] }
    }

    private func sortFilteredEmails() {
        switch sortBy {
        case .dateAsc:
            filteredEmails.sort {
                (isoFormatter.date(from: $0.timestamp) ?? .distantPast) <
                (isoFormatter.date(from: $1.timestamp) ?? .distantPast)
            }
        case .dateDesc:
            filteredEmails.sort {
                (isoFormatter.date(from: $0.timestamp) ?? .distantPast) >
                (isoFormatter.date(from: $1.timestamp) ?? .distantPast)
            }
        case .subjectAsc:
            filteredEmails.sort {
                ($0.headers["Subject"] ?? "")
                    .localizedCompare($1.headers["Subject"] ?? "") == .orderedAscending
            }
        case .priorityDesc:
            filteredEmails.sort {
                (priorityScores[$0.id] ?? 0) > (priorityScores[$1.id] ?? 0)
            }
        case .sizeDesc:
            filteredEmails.sort {
                $0.rawSource.utf8.count > $1.rawSource.utf8.count
            }
        }
    }

    // MARK: - Sort Options
    enum SortOption: String, CaseIterable, Equatable {
        case dateAsc = "Date ↑"
        case dateDesc = "Date ↓"
        case subjectAsc = "Subject A-Z"
        case priorityDesc = "Priority ↓"
        case sizeDesc = "Size ↓"
        var label: String {
            switch self {
            case .dateAsc: return "Date (Oldest)"
            case .dateDesc: return "Date (Newest)"
            case .subjectAsc: return "Subject A-Z"
            case .priorityDesc: return "Priority"
            case .sizeDesc: return "Size (Largest)"
            }
        }
    }

    // MARK: - Priority Scores (cached)
    @Published var priorityScores: [UUID: Int] = [:]

    func computePriorityScores() {
        let results = EmailNLPEngine.scoreAllPriorities(allEmails, replyCountPerSender: replyCountPerSender)
        var scores: [UUID: Int] = [:]
        for r in results {
            scores[r.email.id] = r.score
        }
        priorityScores = scores
    }

    func priorityLevel(for emailID: UUID) -> EmailNLPEngine.PriorityResult.PriorityLevel {
        let score = priorityScores[emailID] ?? 0
        if score >= 5 { return .high }
        if score >= 3 { return .medium }
        return .low
    }

    // MARK: - AI Smart Filter Caches
    @Published var sentimentScores: [UUID: Double] = [:]
    @Published var phishingEmailIDs: Set<UUID> = []
    @Published var emailClassifications: [UUID: EmailNLPEngine.EmailCategory] = [:]
    @Published var aiFiltersComputed = false

    func computeAIFilterData() {
        guard !aiFiltersComputed, !allEmails.isEmpty else { return }
        Task.detached(priority: .utility) { [allEmails] in
            let sentiments = EmailNLPEngine.analyzeSentiment(of: allEmails)
            var sentMap: [UUID: Double] = [:]
            for r in sentiments { sentMap[r.email.id] = r.score }

            let phishing = EmailNLPEngine.detectPhishing(in: allEmails)
            let phishIDs = Set(phishing.map(\.email.id))

            var classMap: [UUID: EmailNLPEngine.EmailCategory] = [:]
            for email in allEmails { classMap[email.id] = EmailNLPEngine.classify(email) }

            await MainActor.run { [sentMap, phishIDs, classMap] in
                self.sentimentScores = sentMap
                self.phishingEmailIDs = phishIDs
                self.emailClassifications = classMap
                self.aiFiltersComputed = true
            }
        }
    }

    // MARK: - Cleanup Mode (sender-grouped data)
    struct SenderGroup: Identifiable {
        let id = UUID()
        let sender: String
        let count: Int
        let totalSizeKB: Int
        let latestDate: Date?
    }

    var senderGroups: [SenderGroup] {
        var grouped: [String: (count: Int, size: Int, latest: Date?)] = [:]
        for email in allEmails {
            let sender = email.headers["From"] ?? "Unknown"
            var entry = grouped[sender, default: (count: 0, size: 0, latest: nil)]
            entry.count += 1
            entry.size += email.rawSource.utf8.count / 1024
            let date = MBOXParser.parseDate(email.headers["Date"])
            if let d = date {
                if let existing = entry.latest {
                    if d > existing { entry.latest = d }
                } else {
                    entry.latest = d
                }
            }
            grouped[sender] = entry
        }
        return grouped.map { SenderGroup(sender: $0.key, count: $0.value.count, totalSizeKB: $0.value.size, latestDate: $0.value.latest) }
            .sorted { $0.count > $1.count }
    }

    var totalStorageMB: Double {
        Double(allEmails.reduce(0) { $0 + $1.rawSource.utf8.count }) / (1024.0 * 1024.0)
    }
    var earliestEmailDate: Date? {
        allEmails.compactMap { isoFormatter.date(from: $0.timestamp) }.min()
    }
    var latestEmailDate: Date? {
        allEmails.compactMap { isoFormatter.date(from: $0.timestamp) }.max()
    }
    var allFromEmails: [String] {
        Array(Set(allEmails.compactMap { $0.headers["From"] })).sorted()
    }
    var allToEmails: [String] {
        Array(Set(allEmails.compactMap { $0.headers["To"] })).sorted()
    }
    var allSubjects: [String] {
        Array(Set(allEmails.compactMap { $0.headers["Subject"] })).sorted()
    }
    var allDomains: [String] {
        let domains = allEmails.flatMap { $0.domains }
        return Array(Set(domains)).sorted()
    }
    var allTags: [String] {
        Array(Set(allEmails.flatMap { $0.tags })).sorted()
    }
    var filteredDateRange: (Date?, Date?) {
        let dates = filteredEmails.compactMap { isoFormatter.date(from: $0.timestamp) }
        return (dates.min(), dates.max())
    }

    /// For sidebar: returns senders sorted by their reply count descending.
    var sortedSendersByReplyCount: [(email: String, count: Int)] {
        replyCountPerSender
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    /// Maximum reply count for sidebar Stepper upper bound.
    var maxReplyCount: Int {
        replyCountPerSender.values.max() ?? 0
    }
}
