import Foundation
import SwiftUI

@MainActor
class ParsedEmailListViewModel: ObservableObject {
    // MARK: - Root ViewModel
    var viewModel: ContentViewModel

    private var isResettingFilters = false

    // FTS5-backed match cache. `ftsMatchKey` is the query string the cached IDs
    // correspond to. Free-text / boolean searches are resolved by the SQLite
    // FTS5 engine (FTSSearchIndex, async). The legacy in-RAM EmailSearchIndex
    // is no longer built (Part F); interim fallbacks scan only the bounded
    // preview array already resident for the legacy list.
    private var ftsMatchIDs: Set<UUID>? = nil
    private var ftsMatchKey: String? = nil
    /// Bumped on any content mutation (delete / redact / reindex) so the search
    /// cache key tracks mutations, not just cardinality — a redaction changes
    /// content without changing count and must invalidate cached hits.
    private var corpusVersion = 0

    /// Invalidate the FTS result cache. Call after delete/redact/reindex so a
    /// stale hit isn't served for content that changed in place.
    func invalidateSearchCache() {
        corpusVersion &+= 1
        ftsMatchKey = nil
        ftsMatchIDs = nil
    }

    #if DEBUG
    /// Test-only: retains the most recent FTS search Task so a wiring test can
    /// await it deterministically (`await lastFTSSearchTask?.value`) instead of
    /// polling a timeout.
    var lastFTSSearchTask: Task<Void, Never>?
    #endif

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
        didSet { if !isResettingFilters { applyFilters() } }
    }

    // Reply count filter
    @Published var minReplyCount: Int = 0 {
        didSet { if !isResettingFilters { applyFilters() } }
    }

    // Natural language search mode
    @Published var isNaturalLanguageMode: Bool = false
    @Published var hasAttachmentFilter: Bool = false

    // Topic cluster filter
    @Published var clusterFilterIDs: Set<UUID>? {
        didSet { if !isResettingFilters { applyFilters() } }
    }

    // Smart tag filter
    @Published var selectedSmartTags: Set<SmartTag> = [] {
        didSet { if !isResettingFilters { applyFilters() } }
    }

    enum SmartTag: String, CaseIterable, Hashable {
        case sent = "Sent"
        case received = "Received"
        case personal = "Personal"
        case transactional = "Transactional"
        case newsletter = "Newsletter"
        case promotional = "Promotional"
        case automated = "Automated"
        case relevant = "Relevant"
        case privileged = "Privileged"
        case irrelevant = "Irrelevant"
        case flagged = "Flagged"
        case suspicious = "Suspicious"
        case positive = "Positive"
        case negative = "Negative"
        case highPriority = "High Priority"
        case mediumPriority = "Medium Priority"
        case hasAttachment = "Has Attachment"
        case phishing = "Phishing"

        var icon: String {
            switch self {
            case .sent: return "arrow.up.circle"
            case .received: return "arrow.down.circle"
            case .personal: return "person.fill"
            case .transactional: return "creditcard"
            case .newsletter: return "newspaper"
            case .promotional: return "megaphone"
            case .automated: return "gearshape"
            case .relevant: return "checkmark.seal.fill"
            case .privileged: return "lock.shield.fill"
            case .irrelevant: return "xmark.circle"
            case .flagged: return "flag.fill"
            case .suspicious: return "exclamationmark.triangle.fill"
            case .positive: return "face.smiling"
            case .negative: return "face.dashed"
            case .highPriority: return "exclamationmark.triangle.fill"
            case .mediumPriority: return "exclamationmark.circle"
            case .hasAttachment: return "paperclip"
            case .phishing: return "shield.slash"
            }
        }

        var color: Color {
            switch self {
            case .sent: return .blue
            case .received: return .teal
            case .personal: return .cyan
            case .transactional: return .indigo
            case .newsletter: return .mint
            case .promotional: return .pink
            case .automated: return .gray
            case .relevant: return .green
            case .privileged: return .orange
            case .irrelevant: return .gray
            case .flagged: return .red
            case .suspicious: return .purple
            case .positive: return .green
            case .negative: return .red
            case .highPriority: return .red
            case .mediumPriority: return .orange
            case .hasAttachment: return .brown
            case .phishing: return .red
            }
        }
    }

    func resolveSmartTag(for email: MBOXParser.RawEmail) -> SmartTag? {
        let forensicTag = ForensicManager.shared.tagForEmail(email.id)
        if forensicTag != .none {
            switch forensicTag {
            case .relevant: return .relevant
            case .privileged: return .privileged
            case .irrelevant: return .irrelevant
            case .flagged: return .flagged
            case .suspicious: return .suspicious
            case .none: break
            }
        }

        let priority = priorityLevel(for: email.id)
        if priority == .high { return .highPriority }
        if priority == .medium { return .mediumPriority }

        if phishingEmailIDs.contains(email.id) { return .phishing }

        if let score = sentimentScores[email.id] {
            if score > 0.4 { return .positive }
            if score < -0.4 { return .negative }
        }

        if let category = emailClassifications[email.id] {
            switch category {
            case .personal: return .personal
            case .transactional: return .transactional
            case .newsletter: return .newsletter
            case .promotional: return .promotional
            case .automated: return .automated
            case .unknown: break
            }
        }

        if email.messageType == "sent" { return .sent }
        if email.messageType == "received" { return .received }

        if !email.attachments.isEmpty { return .hasAttachment }

        return nil
    }

    @Published var smartTagCounts: [(tag: SmartTag, count: Int)] = []

    func recomputeSmartTagCounts() {
        var counts: [SmartTag: Int] = [:]
        for email in allEmails {
            if let tag = resolveSmartTag(for: email) {
                counts[tag, default: 0] += 1
            }
        }
        smartTagCounts = SmartTag.allCases.compactMap { tag in
            guard let count = counts[tag], count > 0 else { return nil }
            return (tag: tag, count: count)
        }
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
    // NOTE (Part G): both arrays are the BOUNDED preview backing the legacy
    // Simple list — never archive truth. Archive-wide totals/analytics come
    // from ArchiveDataService / ArchiveAggregateService.
    @Published var allEmails: [MBOXParser.RawEmail] = []
    @Published var filteredEmails: [MBOXParser.RawEmail] = []

    // MARK: - Archive truth (Part G3)

    /// Store-backed archive total. The resident preview arrays are capped, so
    /// their counts must never be presented as the archive total.
    @Published private(set) var archiveTotalCount = 0

    /// Refresh the store-backed archive total (fire-and-forget, bounded O(1)).
    func refreshArchiveTotalCount() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.archiveTotalCount = (try? await ArchiveDataService.shared.count()) ?? self.archiveTotalCount
        }
    }

    /// The count shown in list headers/titles. When nothing is filtered out of
    /// the preview the archive total (store COUNT) is the truth; when a filter
    /// narrows the list, the count of the visible (preview-backed) list is
    /// exactly what the user sees.
    var displayedEmailCount: Int {
        filteredEmails.count == allEmails.count
            ? max(archiveTotalCount, allEmails.count)
            : filteredEmails.count
    }

    /// The current legacy filter state mapped onto the bounded archive query
    /// (text + date bounds — the fields `EmailQuery` resolves today). This is
    /// the same mapping the AI assistant scope uses (Part D precedent); feature
    /// views stream their own bounded working sets for this query instead of
    /// receiving the preview arrays.
    var currentArchiveQuery: EmailQuery {
        var query = EmailQuery.all
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { query.text = text }
        if startDate > .distantPast { query.afterDate = startDate }
        if endDate < .distantFuture { query.beforeDate = endDate }
        return query
    }
    @Published var aiPinnedIDs: Set<UUID>? = nil
    @Published var emailThreads: [EmailThread] = []
    @Published var replyCountPerSender: [String: Int] = [:]

    // MARK: - Pin/Star & Custom Tags & Annotations
    @Published var pinnedIDs: Set<UUID> = [] { didSet { if _userDataInitialized { persistUserData() } } }
    @Published var readIDs: Set<UUID> = [] { didSet { if _userDataInitialized { persistUserData() } } }
    @Published var deletedIDs: Set<UUID> = [] { didSet { if _userDataInitialized { persistUserData() } } }
    @Published var archivedIDs: Set<UUID> = [] { didSet { if _userDataInitialized { persistUserData() } } }
    @Published var userTags: [UUID: Set<String>] = [:] { didSet { if _userDataInitialized { persistUserData() } } }
    @Published var annotations: [UUID: String] = [:] { didSet { if _userDataInitialized { persistUserData() } } }
    private var _userDataInitialized = false
    @Published var showPinnedOnly = false { didSet { if !isResettingFilters { applyFilters() } } }

    func togglePin(_ emailID: UUID) {
        if pinnedIDs.contains(emailID) { pinnedIDs.remove(emailID) }
        else { pinnedIDs.insert(emailID) }
    }

    func isPinned(_ emailID: UUID) -> Bool { pinnedIDs.contains(emailID) }

    func markRead(_ emailID: UUID) { readIDs.insert(emailID) }
    func markUnread(_ emailID: UUID) { readIDs.remove(emailID) }
    func toggleRead(_ emailID: UUID) {
        if readIDs.contains(emailID) { readIDs.remove(emailID) }
        else { readIDs.insert(emailID) }
    }
    func isRead(_ emailID: UUID) -> Bool { readIDs.contains(emailID) }

    func deleteEmail(_ emailID: UUID) { deletedIDs.insert(emailID) }
    func undeleteEmail(_ emailID: UUID) { deletedIDs.remove(emailID) }
    func isDeleted(_ emailID: UUID) -> Bool { deletedIDs.contains(emailID) }

    func archiveEmail(_ emailID: UUID) { archivedIDs.insert(emailID) }
    func unarchiveEmail(_ emailID: UUID) { archivedIDs.remove(emailID) }
    func isArchived(_ emailID: UUID) -> Bool { archivedIDs.contains(emailID) }

    func addUserTag(_ tag: String, to emailID: UUID) {
        userTags[emailID, default: []].insert(tag)
    }

    func removeUserTag(_ tag: String, from emailID: UUID) {
        userTags[emailID]?.remove(tag)
    }

    func userTagsFor(_ emailID: UUID) -> Set<String> {
        userTags[emailID] ?? []
    }

    var allUserTags: [String] {
        Array(Set(userTags.values.flatMap { $0 })).sorted()
    }

    func setAnnotation(_ text: String, for emailID: UUID) {
        annotations[emailID] = text.isEmpty ? nil : text
    }

    func annotationFor(_ emailID: UUID) -> String {
        annotations[emailID] ?? ""
    }

    private static let userDataURL: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_review_data.json")
    }()

    private func persistUserData() {
        let data = UserReviewData(
            pinnedIDs: Array(pinnedIDs).map(\.uuidString),
            readIDs: Array(readIDs).map(\.uuidString),
            deletedIDs: Array(deletedIDs).map(\.uuidString),
            archivedIDs: Array(archivedIDs).map(\.uuidString),
            userTags: userTags.reduce(into: [String: [String]]()) { $0[$1.key.uuidString] = Array($1.value) },
            annotations: annotations.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        )
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: Self.userDataURL, options: [.atomic, .completeFileProtection])
        }
    }

    private func loadUserData() {
        guard FileManager.default.fileExists(atPath: Self.userDataURL.path),
              let data = try? Data(contentsOf: Self.userDataURL),
              let decoded = try? JSONDecoder().decode(UserReviewData.self, from: data) else { return }
        pinnedIDs = Set(decoded.pinnedIDs.compactMap { UUID(uuidString: $0) })
        readIDs = Set((decoded.readIDs ?? []).compactMap { UUID(uuidString: $0) })
        deletedIDs = Set((decoded.deletedIDs ?? []).compactMap { UUID(uuidString: $0) })
        archivedIDs = Set((decoded.archivedIDs ?? []).compactMap { UUID(uuidString: $0) })
        userTags = decoded.userTags.reduce(into: [UUID: Set<String>]()) {
            if let uuid = UUID(uuidString: $1.key) { $0[uuid] = Set($1.value) }
        }
        annotations = decoded.annotations.reduce(into: [UUID: String]()) {
            if let uuid = UUID(uuidString: $1.key) { $0[uuid] = $1.value }
        }
    }

    struct UserReviewData: Codable {
        let pinnedIDs: [String]
        var readIDs: [String]? = []
        var deletedIDs: [String]? = []
        var archivedIDs: [String]? = []
        let userTags: [String: [String]]
        let annotations: [String: String]
    }

    private let isoFormatter = ISO8601DateFormatter()
    private var searchDebounceTask: Task<Void, Never>?

    // MARK: - Init
    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        loadSavedSearches()
        loadUserData()
        _userDataInitialized = true
    }

    func rehydrateIfNeeded(_ emailID: UUID) {
        guard let idx = filteredEmails.firstIndex(where: { $0.id == emailID }),
              filteredEmails[idx].isBodyCompacted else { return }
        if let rehydrated = viewModel.rehydrateBody(for: emailID) {
            filteredEmails[idx] = rehydrated
            if let allIdx = allEmails.firstIndex(where: { $0.id == emailID }) {
                allEmails[allIdx] = rehydrated
            }
        }
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

    func removeDuplicateEmails(ids: Set<UUID>) {
        // Part M(a): route removal through the GUARDED store deletion path
        // (ContentViewModel.removeEmailsAwaitingResult — FTS-first delete with
        // UI rollback on store failure). The resident preview arrays here
        // mutate only AFTER the authority confirms the delete, so a failed
        // delete can never leave this list claiming the emails are gone.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await viewModel.removeEmailsAwaitingResult(ids: ids) else { return }
            allEmails.removeAll { ids.contains($0.id) }
            emailCount = allEmails.count
            refreshArchiveTotalCount()
            applyFilters()
        }
    }

    // MARK: - Load Emails from ContentViewModel
    func loadFromContentViewModel() {
        allEmails = viewModel.parsedEmails
        emailCount = allEmails.count
        isParsed = !allEmails.isEmpty
        refreshArchiveTotalCount()
        replyCountPerSender = computeReplyCountPerSender(in: allEmails)
        startDate = earliestEmailDate ?? .distantPast
        endDate = latestEmailDate ?? .distantFuture
        if isParsed {
            computePriorityScores()
            applyFilters()
            showParsedList = true
            computeAIFilterData()
            // Part L: incremental persisted thread-key backfill (no-op once
            // every stored email has a key).
            ArchiveThreadService.shared.kickBackfill()
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
                    self.refreshArchiveTotalCount()
                    self.replyCountPerSender = self.computeReplyCountPerSender(in: emails)
                    self.startDate = self.earliestEmailDate ?? .distantPast
                    self.endDate = self.latestEmailDate ?? .distantFuture
                    self.computePriorityScores()
                    self.applyFilters()
                    self.showParsedList = true
                    self.recomputeSmartTagCounts()
                    self.computeAIFilterData()
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
        isResettingFilters = true
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
        selectedSmartTags.removeAll()
        selectedEvidenceTag = nil
        clusterFilterIDs = nil
        isResettingFilters = false
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
        var typeOperator: String?
        var tagOperator: String?
        var sourceOperator: String?
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
            } else if lower.hasPrefix("type:") {
                parsed.typeOperator = String(part.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased()
            } else if lower.hasPrefix("tag:") {
                parsed.tagOperator = String(part.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("source:") {
                parsed.sourceOperator = String(part.dropFirst(7)).trimmingCharacters(in: .whitespaces)
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
                let r1 = result.range(at: 1)
                let r2 = result.range(at: 2)
                let r3 = result.range(at: 3)
                let r4 = result.range(at: 4)
                let r5 = result.range(at: 5)
                let t1 = r1.location != NSNotFound ? (matchStr as NSString).substring(with: r1)
                       : r2.location != NSNotFound ? (matchStr as NSString).substring(with: r2) : nil
                let dist = r3.location != NSNotFound ? (matchStr as NSString).substring(with: r3) : nil
                let t2 = r4.location != NSNotFound ? (matchStr as NSString).substring(with: r4)
                       : r5.location != NSNotFound ? (matchStr as NSString).substring(with: r5) : nil
                if let t1, let t2 {
                    parsed.isProximityQuery = true
                    parsed.proximityTerm1 = t1
                    parsed.proximityTerm2 = t2
                    parsed.proximityDistance = Int(dist ?? "") ?? 5
                }
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

    /// Bounded regex scan over the resident preview array (regex has no FTS5
    /// form). Caps pattern length and per-email scanned characters like the
    /// retired in-RAM index did.
    nonisolated static func boundedRegexMatchIDs(pattern: String, in emails: [MBOXParser.RawEmail]) -> Set<UUID> {
        guard pattern.count <= 1000 else { return [] }
        let cleanPattern: String
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            cleanPattern = String(pattern.dropFirst().dropLast())
        } else {
            cleanPattern = pattern.replacingOccurrences(of: "*", with: ".*")
        }
        guard let regex = try? NSRegularExpression(pattern: cleanPattern, options: .caseInsensitive) else { return [] }
        var ids = Set<UUID>()
        for email in emails {
            let text = String(email.fullText.prefix(100_000))
            let range = NSRange(location: 0, length: (text as NSString).length)
            if regex.firstMatch(in: text, options: .withoutAnchoringBounds, range: range) != nil {
                ids.insert(email.id)
            }
        }
        return ids
    }

    // MARK: - Apply Filters (with minReplyCount logic + free limit)
    func applyFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseSearchQuery(query)
        let isoFmt = isoFormatter

        let forensicEvidenceTags = ForensicManager.shared.evidenceTags

        var advancedMatchIDs: Set<UUID>?

        // Compile the parsed query into valid FTS5 grammar (FTSQueryBuilder).
        // Regex has no FTS5 form and stays in-RAM. Proximity compiles to a
        // native NEAR(...) and is routed through FTS5 with NO in-RAM fallback
        // (removes the whole-array `EmailSearchIndex.proximitySearch` scale
        // violation). Free-text/Boolean use FTS when the index isn't mid-build,
        // else the in-RAM engine (which holds the parsed-so-far set).
        let ftsQuery: String?
        let allowInRAMFallback: Bool
        if parsed.isRegexQuery {
            ftsQuery = nil
            allowInRAMFallback = true
        } else if parsed.isProximityQuery {
            ftsQuery = FTSQueryBuilder.proximity(
                term1: parsed.proximityTerm1,
                term2: parsed.proximityTerm2,
                distance: parsed.proximityDistance
            )
            allowInRAMFallback = false   // proximity is FTS5-only now
        } else {
            let t = parsed.freeText.trimmingCharacters(in: .whitespaces)
            ftsQuery = t.isEmpty ? nil : FTSQueryBuilder.freeTextOrBoolean(t)
            allowInRAMFallback = true
        }

        // Proximity always routes through FTS (partial-during-import is the real
        // index, not an in-memory answer presented as authoritative). Free-text/
        // Boolean route through FTS only once the index isn't mid-build.
        let useFTS = (ftsQuery != nil) && (!isParsing || !allowInRAMFallback)
        if let ftsQuery, useFTS {
            let cacheKey = "\(ftsQuery)\u{1}\(allEmails.count)\u{1}\(corpusVersion)"
            if cacheKey != ftsMatchKey {
                let searchTask = Task { [weak self] in
                    guard let self else { return }
                    let populated = ((try? await FTSSearchIndex.shared.rowCount()) ?? 0) > 0
                    if populated {
                        let ids = (try? await FTSSearchIndex.shared.searchRaw(ftsQuery, limit: 100_000)) ?? []
                        self.ftsMatchIDs = Set(ids)   // empty set = authoritative zero matches
                    } else {
                        // Nothing indexed yet. Free-text/Boolean fall back to
                        // in-RAM; proximity has no fallback → authoritative empty.
                        self.ftsMatchIDs = allowInRAMFallback ? nil : Set<UUID>()
                    }
                    self.ftsMatchKey = cacheKey
                    self.applyFilters()
                }
                #if DEBUG
                lastFTSSearchTask = searchTask
                #endif
            }
            if ftsMatchKey == cacheKey, let ids = ftsMatchIDs {
                advancedMatchIDs = ids
            }
        } else {
            ftsMatchKey = nil
            ftsMatchIDs = nil
        }

        // Bounded fallbacks — the legacy in-RAM EmailSearchIndex is gone
        // (Part F). Regex (no FTS5 form) scans only the bounded preview array
        // already resident for the legacy list. Boolean queries simply wait
        // for FTS (advancedMatchIDs stays nil → plain substring matching
        // below applies in the meantime).
        if advancedMatchIDs == nil && allowInRAMFallback {
            if parsed.isRegexQuery && !parsed.freeText.isEmpty {
                advancedMatchIDs = Self.boundedRegexMatchIDs(pattern: parsed.freeText, in: allEmails)
            }
        }

        if parsed.searchInAttachments && !parsed.freeText.isEmpty {
            // Degraded but bounded: match attachment FILENAMES over the
            // resident preview (extracted attachment text lived only in the
            // retired in-RAM index; FTS attachment text is a later phase).
            let terms = parsed.freeText.lowercased().split(separator: " ").map(String.init)
            let attachIDs = Set(allEmails.filter { email in
                !email.attachments.isEmpty && email.attachments.contains { att in
                    let name = att.filename.lowercased()
                    return terms.contains { name.contains($0) }
                }
            }.map(\.id))
            if let existing = advancedMatchIDs {
                advancedMatchIDs = existing.intersection(attachIDs)
            } else {
                advancedMatchIDs = attachIDs
            }
        }

        var result = allEmails.filter { email in
            if deletedIDs.contains(email.id) { return false }
            if archivedIDs.contains(email.id) { return false }
            if showPinnedOnly && !pinnedIDs.contains(email.id) { return false }
            if let clusterIDs = clusterFilterIDs {
                if !clusterIDs.contains(email.id) { return false }
            }
            if let pinnedIDs = aiPinnedIDs {
                if !pinnedIDs.contains(email.id) { return false }
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

            let matchesSmartTag: Bool
            if selectedSmartTags.isEmpty {
                matchesSmartTag = true
            } else {
                matchesSmartTag = resolveSmartTag(for: email).map { selectedSmartTags.contains($0) } ?? false
            }

            let matchesNLAttachment = !hasAttachmentFilter || !email.attachments.isEmpty

            let matchesType = parsed.typeOperator.map { email.messageType == $0 } ?? true
            let matchesTag = parsed.tagOperator.map { tag in
                let emailTags = email.headers["X-Keywords"] ?? email.headers["X-Gmail-Labels"] ?? ""
                return emailTags.localizedCaseInsensitiveContains(tag)
            } ?? true
            let matchesSource = parsed.sourceOperator.map { source in
                let emailSource = email.headers["X-Source-File"] ?? ""
                return emailSource.localizedCaseInsensitiveContains(source)
            } ?? true

            return filterMatch(email) && replyCount >= minReplyCount
                && matchesFromOp && matchesToOp && matchesSubjectOp && matchesHasAttachment && matchesDateOps && matchesEvidenceTag && matchesSmartTag && matchesNLAttachment && matchesType && matchesTag && matchesSource
        }
        if !isPremiumUser && result.count > StoreManager.freeEmailLimit {
            result = Array(result.prefix(StoreManager.freeEmailLimit))
        }
        filteredEmails = result
        sortFilteredEmails()
        if groupByThread {
            emailThreads = ThreadGrouper.group(filteredEmails)
        }
        recomputeSmartTagCounts()
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

    // Reply frequency stats moved to ArchiveAggregateService.replyRecipientCounts
    // (Part G4): a bounded SQL GROUP BY over the store, consumed by
    // ReplyStatsView directly — no preview-array walk.

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

    // Part I.2: this synchronous pass over the BOUNDED resident preview keeps
    // sort-by-priority correct immediately at load; the persisted per-email
    // priority (derived store, computed by the archive-wide background job
    // with DB-side sender counts) overwrites these values when
    // computeAIFilterData's fetch completes, and is the archive truth.
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

    @AppStorage("enableAIFeatures") private var enableAIFeatures = true

    func computeAIFilterData() {
        guard !aiFiltersComputed, !allEmails.isEmpty, enableAIFeatures else { return }
        // Part I: the filter attributes are PERSISTED derived state
        // (ArchiveDerivedStateStore), computed once by a bounded background job
        // — not recomputed over the resident array every time filters need
        // them. This reads the persisted records for the resident preview
        // page, computes-and-persists only the missing ones (bounded by the
        // preview cap, in 300-email batches), then kicks the incremental
        // archive-wide job for everything else. Reopening costs one fetch.
        let previewEmails = allEmails
        let senderCounts = replyCountPerSender
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = ArchiveDerivedStateStore.shared
            let ids = previewEmails.map(\.id)
            var records = (try? await store.fetch(ids: ids)) ?? [:]

            // Fill in preview emails that have no (current-version) record yet.
            let missing = previewEmails.filter {
                (records[$0.id]?.analysisVersion ?? 0) < DerivedAIAnalysis.analysisVersion
            }
            if !missing.isEmpty {
                let revision = (try? await ArchiveCorpusRevision.shared.reconciled()) ?? 0
                var start = 0
                while start < missing.count {
                    let batch = Array(missing[start..<min(start + 300, missing.count)])
                    let computed = await DerivedAIAnalysis.computeRecords(
                        for: batch, existing: records, senderCounts: senderCounts, revision: revision
                    )
                    try? await store.upsert(computed)
                    for record in computed { records[record.emailID] = record }
                    start += 300
                }
            }

            // Publish the persisted attributes into the filter caches the
            // legacy UI reads (same thresholds/values as before).
            var sentMap: [UUID: Double] = [:]
            var classMap: [UUID: EmailNLPEngine.EmailCategory] = [:]
            var phishIDs = Set<UUID>()
            var priorities = priorityScores
            for (id, record) in records {
                if let score = DerivedAIAnalysis.sentimentScore(from: record) { sentMap[id] = score }
                if let category = DerivedAIAnalysis.classification(from: record) { classMap[id] = category }
                if record.phishing == true { phishIDs.insert(id) }
                if let priority = record.priority { priorities[id] = priority }
            }
            sentimentScores = sentMap
            phishingEmailIDs = phishIDs
            emailClassifications = classMap
            priorityScores = priorities
            aiFiltersComputed = true
            recomputeSmartTagCounts()

            // Incremental archive-wide job (no-op when already computed).
            DerivedAIAnalysisJob.shared.kickIfNeeded()
        }
    }

    // Cleanup Mode sender rollups + archive storage total moved to
    // ArchiveAggregateService.senderRollups / totalSizeBytes (Part G9): SQL
    // GROUP BY / SUM aggregates over the store, consumed by the cleanup view
    // directly — the preview arrays must not be presented as archive stats.

    // NOTE (Part G9): everything below is PREVIEW-SCOPED by design — it
    // describes the resident bounded preview backing the legacy Simple list
    // (its filter pickers and date-filter defaults), not the whole archive.
    // Archive-wide equivalents live in ArchiveAggregateService.
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
    /// Date span of the visible (preview-backed) filtered list.
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
