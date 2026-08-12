import Foundation
import SwiftUI
// Combine stays ONLY for the ObservableObject objectWillChange forwarder in
// init — removable when the VM stack migrates to @Observable (v2.1 backlog).
import Combine

// Part S (v2-core-cutover): the "Advanced" list mode's view model, rebuilt on
// the SAME bounded architecture as the Simple list. It owns an
// `ArchiveListViewModel` pager (keyset/ranked pages over the SQLite archive via
// `ArchiveDataService`) and hydrates only the resident page WINDOW into full
// emails for the feature-rich UI (smart tags, evidence tags, sort, threading).
// There is NO whole-corpus array anywhere: `residentEmails` is the bounded
// hydrated window (≤ pager.maxRetained), `visibleEmails` is that window after
// the in-window refinements. Free text / Boolean queries page the whole
// archive through the repository's ranked search; every match is reachable by
// scrolling — nothing is preview-truncated.
@MainActor
class ParsedEmailListViewModel: ObservableObject {
    // MARK: - Root ViewModel
    var viewModel: ContentViewModel

    private var isResettingFilters = false

    // FTS5-backed match cache for the resident window. `ftsMatchKey` is the
    // query string the cached IDs correspond to. Free-text / boolean searches
    // are resolved by the SQLite FTS5 engine (FTSSearchIndex, async) against
    // the WINDOW's ids (`matchingSubset`) — never an archive-wide id list.
    private var ftsMatchIDs: Set<UUID>? = nil
    private var ftsMatchKey: String? = nil
    /// Bumped on any content mutation (delete / redact / reindex) so the search
    /// cache key tracks mutations, not just cardinality — a redaction changes
    /// content without changing count and must invalidate cached hits.
    private var corpusVersion = 0

    // Part P3: bounded regex result cache (async, like the FTS cache) — the
    // matched ids come from BoundedRegexSearch (literal-derived FTS candidates
    // + exact verify, or a capped scope scan), never an unbounded corpus walk.
    private var regexMatchIDs: Set<UUID>? = nil
    private var regexMatchKey: String? = nil

    /// User-visible search caveat (Part P): regex cap truncation, the
    /// attachment filename-only limitation, or proximity's loaded-pages scope.
    /// Silent truncation is not allowed — the list surfaces this under the
    /// search field.
    @Published var searchNotice: String? = nil

    /// Invalidate the FTS result cache. Call after delete/redact/reindex so a
    /// stale hit isn't served for content that changed in place.
    func invalidateSearchCache() {
        corpusVersion &+= 1
        ftsMatchKey = nil
        ftsMatchIDs = nil
        regexMatchKey = nil
        regexMatchIDs = nil
    }

    #if DEBUG
    /// Test-only: retains the most recent FTS search Task so a wiring test can
    /// await it deterministically (`await lastFTSSearchTask?.value`) instead of
    /// polling a timeout.
    var lastFTSSearchTask: Task<Void, Never>?

    /// Test-only window seed: V2VerificationTests injects fixtures and drives
    /// `applyFilters()` directly to observe the FTS dispatch. This seeds the
    /// bounded resident window — it is NOT a corpus property.
    var allEmails: [MBOXParser.RawEmail] {
        get { residentEmails }
        set {
            residentEmails = newValue
            emailCount = newValue.count
        }
    }
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

    // Natural language search mode. The interpreted intent (on-device
    // foundation model on macOS 26/iOS 26, heuristic parser otherwise)
    // compiles into currentArchiveQuery — SQL, archive-wide.
    @Published var isNaturalLanguageMode: Bool = false {
        didSet {
            guard !isResettingFilters, oldValue != isNaturalLanguageMode else { return }
            nlIntent = nil
            nlInterpretTask?.cancel()
            if isNaturalLanguageMode {
                applyNaturalLanguageFilter(searchText)
            } else {
                reloadPagesForQueryChange()
            }
        }
    }
    @Published var nlIntent: NLSearchIntent? = nil
    @Published var isInterpretingNL: Bool = false
    private var nlInterpretTask: Task<Void, Never>? = nil
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
        for email in residentEmails {
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

    // MARK: - Data (bounded page window — Part S)

    /// The internal pager: bounded keyset/ranked pages over the archive. Owns
    /// the query cursor bookkeeping; this model hydrates its summary window.
    private let pager: ArchiveListViewModel
    private let archive: ArchiveDataService

    /// Shared-singleton side effects (derived-state publication, sender
    /// aggregates, thread-key backfill) run only against the production
    /// archive — isolated test/harness archives must not touch the shared
    /// derived stores.
    private var isProductionArchive: Bool { archive === ArchiveDataService.shared }

    /// The hydrated resident page window, in archive/rank order. Bounded by
    /// `pager.maxRetained` (a few hundred), never the corpus.
    @Published private(set) var residentEmails: [MBOXParser.RawEmail] = []

    /// The resident window after in-window refinements (review state, smart
    /// tags, operators, quick pickers) and sorting. What the list renders.
    @Published private(set) var visibleEmails: [MBOXParser.RawEmail] = []

    /// Ordered ids of the visible window — detail-view navigation order.
    var visibleOrderedIDs: [UUID] { visibleEmails.map(\.id) }

    @Published private(set) var isLoadingPage = false

    /// Store-truth count for the CURRENT query (pager total).
    @Published private(set) var queryTotalCount = 0

    /// Guards concurrent reload/hydrate cycles (a superseded reload must not
    /// overwrite a newer window).
    private var windowRevision: UInt64 = 0
    /// Forward pages fetched for the current query — free-tier paging gate.
    private var forwardPagesLoaded = 0

    // MARK: - Archive truth (Part G3)

    /// Store-backed archive total (query-independent). The resident window is
    /// bounded, so its count must never be presented as the archive total.
    @Published private(set) var archiveTotalCount = 0

    /// Refresh the store-backed archive total (fire-and-forget, bounded O(1)).
    func refreshArchiveTotalCount() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.archiveTotalCount = (try? await self.archive.count()) ?? self.archiveTotalCount
        }
    }

    /// The count shown in list headers/titles. When nothing is refined out of
    /// the window the query total (store COUNT / ranked total) is the truth;
    /// when an in-window refinement narrows the list, the visible count is
    /// exactly what the user sees.
    var displayedEmailCount: Int {
        visibleEmails.count == residentEmails.count
            ? max(queryTotalCount, visibleEmails.count)
            : visibleEmails.count
    }

    /// §13.1: the current filter state compiled onto the full archive query —
    /// operator syntax (from:/to:/has:attachment/…) via ArchiveQueryCompiler
    /// plus the structured UI filter state. This is the same mapping the AI
    /// assistant scope uses (Part D precedent); feature views stream their own
    /// bounded working sets for this query instead of receiving email arrays.
    var currentArchiveQuery: EmailQuery {
        var base = EmailQuery.all
        if startDate > .distantPast { base.afterDate = startDate }
        if endDate < .distantFuture { base.beforeDate = endDate }
        // v1 parity: EVERY sidebar checkbox selection compiles to SQL, so the
        // filters apply to the whole archive — not just the resident window.
        base.senders = selectedFromEmails
        base.recipients = selectedToEmails.map { $0.lowercased() }
        base.domains = selectedDomains.map { $0.lowercased() }
        base.subjects = selectedSubjects
        base.tags = selectedTags
        if let evidence = selectedEvidenceTag, evidence != .none { base.evidenceTag = evidence.rawValue }
        if hasAttachmentFilter { base.hasAttachments = true }
        if let quickType = quickTypeFilter { base.messageType = quickType }
        if minReplyCount > 0 { base.minSenderMessages = minReplyCount }
        if let minPriority = quickMinPriority { base.minPriority = minPriority }
        if quickPhishingOnly { base.phishingOnly = true }
        if quickNegativeOnly { base.sentimentBelow = -0.4 }
        if quickNewsletterOnly { base.classifications = ["newsletter", "promotional"] }
        if showPinnedOnly { base.pinnedOnly = true }
        switch sortBy {
        case .dateDesc: base.sort = .dateDesc
        case .dateAsc: base.sort = .dateAsc
        case .subjectAsc: base.sort = .subjectAZ
        case .sizeDesc: base.sort = .sizeDesc
        case .priorityDesc: base.sort = .priorityDesc
        }
        if isNaturalLanguageMode {
            // The raw sentence is NOT an FTS/operator query — the interpreted
            // intent is. While interpretation is in flight (or yielded
            // nothing) show the unnarrowed base rather than garbage matches.
            return nlIntent?.apply(to: base) ?? base
        }
        return ArchiveQueryCompiler.compile(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines), base: base)
    }
    @Published var aiPinnedIDs: Set<UUID>? = nil
    @Published var emailThreads: [EmailThread] = []
    @Published var replyCountPerSender: [String: Int] = [:]

    // MARK: - Pin/Star & Custom Tags & Annotations (§19: SQLite-backed)
    //
    // Review state lives in indexed SQLite tables behind ReviewStateService.
    // The service caches ONLY the visible window; these wrappers keep the
    // long-standing VM API stable for every view that consumes it. The
    // service is @Published-observed so row state changes re-render.
    let review = ReviewStateService.shared

    @Published var showPinnedOnly = false { didSet { if !isResettingFilters { applyFilters() } } }

    /// Quick-chip type filter (Sent/Received) — compiles to SQL messageType
    /// so the chips filter the WHOLE archive, including header-recovered
    /// rows that have flags but no re-parsable metadata.
    @Published var quickTypeFilter: String? = nil
    /// AI-chip filters — compile to SQL over the persisted `derived` table
    /// (archive-wide). Unanalyzed rows don't match; the coverage notice says
    /// so honestly and the background analysis is kicked to close the gap.
    @Published var quickMinPriority: Int? = nil
    @Published var quickPhishingOnly = false
    @Published var quickNegativeOnly = false
    @Published var quickNewsletterOnly = false
    /// Cached derived-analysis coverage (refreshed on reload paths).
    private(set) var derivedCoverage: (analyzed: Int, total: Int) = (0, 0)

    func togglePin(_ emailID: UUID) { review.togglePin(emailID); applyFilters() }
    func isPinned(_ emailID: UUID) -> Bool { review.isPinned(emailID) }

    func markRead(_ emailID: UUID) { review.setFlag(.isRead, ids: [emailID], value: true) }
    func markUnread(_ emailID: UUID) { review.setFlag(.isRead, ids: [emailID], value: false) }
    func toggleRead(_ emailID: UUID) { review.toggleRead(emailID) }
    func isRead(_ emailID: UUID) -> Bool { review.isRead(emailID) }

    /// §19.1: "delete" is Move to Trash — a soft, restorable flag. Permanent
    /// destruction is a separate explicit operation on ReviewStateService.
    func deleteEmail(_ emailID: UUID) { review.moveToTrash([emailID]); applyFilters() }
    func undeleteEmail(_ emailID: UUID) { review.restoreFromTrash([emailID]); applyFilters() }
    func isDeleted(_ emailID: UUID) -> Bool { review.isTrashed(emailID) }

    func archiveEmail(_ emailID: UUID) { review.setFlag(.archived, ids: [emailID], value: true); applyFilters() }
    func unarchiveEmail(_ emailID: UUID) { review.setFlag(.archived, ids: [emailID], value: false); applyFilters() }
    func isArchived(_ emailID: UUID) -> Bool { review.isArchived(emailID) }

    func addUserTag(_ tag: String, to emailID: UUID) { review.addTag(tag, to: [emailID]) }
    func removeUserTag(_ tag: String, from emailID: UUID) { review.removeTag(tag, from: [emailID]) }
    func userTagsFor(_ emailID: UUID) -> Set<String> { review.tags(for: emailID) }
    var allUserTags: [String] { review.knownTags }

    func setAnnotation(_ text: String, for emailID: UUID) { review.setAnnotation(text, for: emailID) }
    func annotationFor(_ emailID: UUID) -> String { review.annotation(for: emailID) }

    private let isoFormatter = ISO8601DateFormatter()
    private var searchDebounceTask: Task<Void, Never>?

    // MARK: - Init
    init(viewModel: ContentViewModel, archive: ArchiveDataService = .shared,
         pageSize: Int = 100, maxRetained: Int = 500) {
        self.viewModel = viewModel
        self.archive = archive
        self.pager = ArchiveListViewModel(archive: archive, pageSize: pageSize, maxRetained: maxRetained)
        loadSavedSearches()
        // Views observe this VM — forward review-state changes (pin/read/tag
        // badges) so rows re-render without observing the service directly.
        reviewChangeForwarder = review.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // §20: one-time migration of the legacy review JSON into SQLite —
        // idempotent, verified, keeps the JSON as rollback evidence.
        Task { @MainActor [review] in await review.migrateLegacyJSONIfNeeded() }
        // New attachment text indexed → cached in:attachments results are stale.
        attachmentIndexObserver = NotificationCenter.default.addObserver(
            forName: .attachmentIndexUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attachmentSearchCache.removeAll()
                self?.applyFilters()
            }
        }
    }

    private var reviewChangeForwarder: AnyCancellable?

    /// Attachment-content search: per-query id cache + indexing progress for
    /// the honest notice. Cache clears when the index job reports new data.
    private var attachmentSearchCache: [String: Set<UUID>] = [:]
    private var attachmentIndexProgress: (attempted: Int, pending: Int)?
    /// Test-visible: awaitable handle for the async attachment lookup.
    var lastAttachmentSearchTask: Task<Void, Never>?
    private var attachmentIndexObserver: NSObjectProtocol?

    // MARK: - Paging (Part S)

    /// The pager's query. §13: EVERY structured operator (tag:/source:/type:/
    /// from:/…) compiles into the repository query so matches page in from the
    /// WHOLE archive — a window-only refinement silently misses matches that
    /// live outside the resident pages (e.g. a 9-email label deep in history).
    /// Free text / Boolean route to the ranked FTS search. Regex and proximity
    /// have no repository text form, and in:attachments resolves to an id set —
    /// those page by their date/structured bounds and refine the window.
    private var pagerQuery: EmailQuery {
        // The FULL archive query — search operators AND every sidebar
        // selection AND the sort — so pages come back already filtered and
        // ordered archive-wide (v1 semantics at any scale).
        var query = currentArchiveQuery
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parsed = parseSearchQuery(trimmed)
            if parsed.isRegexQuery || parsed.isProximityQuery || parsed.searchInAttachments {
                query.text = nil
            }
        }
        return query
    }

    /// Archive-wide AI chips are only as complete as the persisted analysis:
    /// while coverage is partial, say so and kick the background analysis so
    /// the gap closes (minimum-touch: using the chip starts the work).
    private var derivedChipActive: Bool {
        quickMinPriority != nil || quickPhishingOnly || quickNegativeOnly || quickNewsletterOnly
    }

    @MainActor
    func refreshDerivedCoverageNotice() async {
        guard derivedChipActive, isProductionArchive else { return }
        if let coverage = try? await SQLiteEmailStore.shared.derivedAnalysisCoverage() {
            derivedCoverage = coverage
            if coverage.analyzed < coverage.total {
                searchNotice = "AI filters cover \(coverage.analyzed) of \(coverage.total) emails — analysis running for the rest."
                await BackgroundAnalysisManager.shared.runAnalysis()
            }
        }
    }

    /// The query the pager last ran — applyFilters() re-pages when the
    /// compiled query ACTUALLY changed (sidebar selections, sort, operators)
    /// and only refines in-window otherwise. Equality-guarded, so the
    /// applyFilters that follows the reload cannot loop.
    private var lastPagedQuery: EmailQuery? = nil

    /// Reload the page window from the first page of the current query, then
    /// re-apply the in-window refinements. Also refreshes archive-truth counts
    /// and the per-sender aggregate used by the reply-count filter.
    func refreshFromStore() {
        Task { @MainActor [weak self] in await self?.refreshFromStoreNow() }
    }

    /// Awaitable form (deterministic for tests; the fire-and-forget wrapper is
    /// what view code calls).
    func refreshFromStoreNow() async {
        let revision = windowRevision &+ 1
        windowRevision = revision
        isLoadingPage = true
        let total = (try? await archive.count()) ?? 0
        guard revision == windowRevision else { return }
        archiveTotalCount = total
        isParsed = total > 0
        showParsedList = total > 0
        await refreshSenderAggregates()
        let compiled = pagerQuery
        lastPagedQuery = compiled
        await pager.setQuery(compiled)
        forwardPagesLoaded = 1
        guard revision == windowRevision else { return }
        await hydrateWindow(revision: revision)
        isLoadingPage = false
        if isParsed && isProductionArchive {
            // Part L: incremental persisted thread-key backfill (no-op once
            // every stored email has a key).
            ArchiveThreadService.shared.kickBackfill()
        }
    }

    /// Re-page when the archive query (text/date bounds) changed. In-window
    /// refinements go through `applyFilters()` alone.
    private func reloadPagesForQueryChange() {
        Task { @MainActor [weak self] in await self?.reloadForQueryChangeNow() }
    }

    /// Awaitable form (deterministic for tests).
    func reloadForQueryChangeNow() async {
        let revision = windowRevision &+ 1
        windowRevision = revision
        isLoadingPage = true
        await refreshDerivedCoverageNotice()
        let compiled = pagerQuery
        lastPagedQuery = compiled
        await pager.setQuery(compiled)
        forwardPagesLoaded = 1
        guard revision == windowRevision else { return }
        await hydrateWindow(revision: revision)
        isLoadingPage = false
    }

    /// Whether more pages can be fetched forward (free tier caps the paging
    /// depth at `StoreManager.freeEmailLimit` — gated from store counts, the
    /// sidebar upgrade banner explains the cap).
    var hasMorePages: Bool {
        guard pager.hasMore else { return false }
        if isPremiumUser { return true }
        return forwardPagesLoaded * pager.pageSize < StoreManager.freeEmailLimit
    }

    /// Pages exist before the window head (deep-scrolled windows drop early
    /// pages; "Load earlier" re-fetches them).
    var hasEarlierPages: Bool { pager.hasPrevious }

    /// Infinite-scroll trigger: fetch the next page when the given row is at
    /// (or past) the window's tail.
    func loadMoreIfNeeded(currentID: UUID) {
        guard hasMorePages, !isLoadingPage else { return }
        guard let idx = visibleEmails.lastIndex(where: { $0.id == currentID }),
              idx >= max(0, visibleEmails.count - 10) else { return }
        loadNextPage()
    }

    func loadNextPage() {
        Task { @MainActor [weak self] in await self?.loadNextPageNow() }
    }

    /// Awaitable form (deterministic for tests).
    func loadNextPageNow() async {
        guard hasMorePages, !isLoadingPage else { return }
        let revision = windowRevision
        isLoadingPage = true
        await pager.loadNextPage()
        guard revision == windowRevision else { return }
        forwardPagesLoaded += 1
        await hydrateWindow(revision: revision)
        isLoadingPage = false
    }

    func loadEarlierPage() {
        Task { @MainActor [weak self] in await self?.loadEarlierPageNow() }
    }

    /// Awaitable form (deterministic for tests).
    func loadEarlierPageNow() async {
        guard hasEarlierPages, !isLoadingPage else { return }
        let revision = windowRevision
        isLoadingPage = true
        await pager.loadPreviousPage()
        guard revision == windowRevision else { return }
        await hydrateWindow(revision: revision)
        isLoadingPage = false
    }

    /// Hydrate the pager's summary window into full emails (bodies included)
    /// in window order, then re-apply the in-window refinements.
    private func hydrateWindow(revision: UInt64) async {
        let ids = pager.summaries.map(\.id)
        let fetched = (try? await archive.fullEmails(ids: ids)) ?? []
        guard revision == windowRevision else { return }
        var byID: [UUID: MBOXParser.RawEmail] = [:]
        byID.reserveCapacity(fetched.count)
        for email in fetched { byID[email.id] = email }
        residentEmails = ids.compactMap { byID[$0] }
        emailCount = residentEmails.count
        queryTotalCount = pager.totalCount
        // §19: review state for exactly this window (bounded read).
        await review.hydrateWindow(ids: ids)
        // §21: forensic hashes/tags/annotations for this window (bounded read;
        // keeps badges exact even beyond the startup hydration cap).
        if ForensicManager.shared.isEnabled {
            await ForensicManager.shared.prefetchForensicWindow(ids: ids)
        }
        // Window changed → per-window derived state must be recomputed.
        computePriorityScores()
        if isProductionArchive {
            aiFiltersComputed = false
            computeAIFilterData()
        }
        applyFilters()
    }

    /// Per-sender email counts from a bounded SQL aggregate (GROUP BY over the
    /// store) — used by the reply-count filter and the sidebar ranking. Never
    /// computed from a corpus array.
    private func refreshSenderAggregates() async {
        guard isProductionArchive else { return }
        let rollups = (try? await ArchiveAggregateService.shared.senderRollups(limit: 500)) ?? []
        var counts: [String: Int] = [:]
        for rollup in rollups { counts[rollup.sender] = rollup.count }
        replyCountPerSender = counts
    }

    func searchTextDidChange() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.isNaturalLanguageMode {
                self.applyNaturalLanguageFilter(self.searchText)
            } else {
                self.reloadPagesForQueryChange()
            }
        }
    }

    /// Date-bound pickers changed: the archive query changed, so re-page.
    func dateBoundsChanged() {
        reloadPagesForQueryChange()
    }

    /// Interprets a natural-language query into structured SQL filters via
    /// NLQueryInterpreter (Apple's on-device foundation model when available,
    /// heuristic parser otherwise) and re-pages the archive. Unlike the old
    /// regex version this never clobbers the user's sidebar selections or
    /// the search field text.
    func applyNaturalLanguageFilter(_ query: String) {
        nlInterpretTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nlIntent = nil
            isInterpretingNL = false
            reloadPagesForQueryChange()
            return
        }
        isInterpretingNL = true
        nlInterpretTask = Task { @MainActor [weak self] in
            let intent = await NLQueryInterpreter.interpret(trimmed)
            guard let self, !Task.isCancelled else { return }
            self.nlIntent = intent.isEmpty ? nil : intent
            self.isInterpretingNL = false
            self.reloadPagesForQueryChange()
        }
    }

    func removeDuplicateEmails(ids: Set<UUID>) {
        // Part M(a): route removal through the GUARDED store deletion path
        // (ContentViewModel.removeEmailsAwaitingResult — FTS-first delete).
        // The paged window reloads only AFTER the authority confirms the
        // delete, so a failed delete can never leave this list claiming the
        // emails are gone.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await viewModel.removeEmailsAwaitingResult(ids: ids) else { return }
            invalidateSearchCache()
            refreshFromStore()
        }
    }

    /// Awaitable duplicate removal. Deletes via the guarded store path, then
    /// refreshes the paged window BEFORE returning, so view code can update its
    /// own state and dismiss only AFTER the mutation has landed — never
    /// mid-flight, which races window teardown on macOS (observed as the app
    /// quitting when the Duplicate Manager was closed on removal).
    @MainActor
    func removeDuplicateEmailsAwaiting(ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return true }
        let ok = await viewModel.removeEmailsAwaitingResult(ids: ids)
        guard ok else { return false }
        invalidateSearchCache()
        await refreshFromStoreNow()
        return true
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
        startDate = .distantPast
        endDate = .distantFuture
        minReplyCount = 0
        hasAttachmentFilter = false
        isNaturalLanguageMode = false
        nlIntent = nil
        nlInterpretTask?.cancel()
        isInterpretingNL = false
        selectedSmartTags.removeAll()
        selectedEvidenceTag = nil
        clusterFilterIDs = nil
        isResettingFilters = false
        reloadPagesForQueryChange()
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
        // Quote-aware tokenization (shared with the SQL compiler): keeps
        // `tag:"Boxbe Waiting List"` one token so multiword operator values
        // survive — a bare space-split cut them in half.
        let parts = ArchiveQueryCompiler.tokenize(raw)
        func unquoted(_ value: String) -> String {
            var v = value.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var i = 0
        while i < parts.count {
            let part = parts[i]
            let lower = part.lowercased()
            if lower.hasPrefix("from:") {
                parsed.fromOperator = unquoted(String(part.dropFirst(5)))
            } else if lower.hasPrefix("to:") {
                parsed.toOperator = unquoted(String(part.dropFirst(3)))
            } else if lower.hasPrefix("subject:") {
                parsed.subjectOperator = unquoted(String(part.dropFirst(8)))
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
                parsed.typeOperator = unquoted(String(part.dropFirst(5))).lowercased()
            } else if lower.hasPrefix("tag:") {
                parsed.tagOperator = unquoted(String(part.dropFirst(4)))
            } else if lower.hasPrefix("source:") {
                parsed.sourceOperator = unquoted(String(part.dropFirst(7)))
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

    // MARK: - Apply Filters (in-window refinement; paging is separate)

    /// Refine the resident page window into `visibleEmails`. This NEVER
    /// re-pages the archive — query (text/date) changes go through
    /// `reloadPagesForQueryChange()`; everything here is bounded by the
    /// resident window. Free-text/Boolean matches are verified through FTS5
    /// (`matchingSubset` over the window ids); regex uses BoundedRegexSearch;
    /// proximity compiles to a native FTS5 NEAR — no in-RAM corpus engine.
    func applyFilters() {
        // Part U: sidebar selections / sort COMPILE into the pager query —
        // when it changed, kick an archive re-page AND still refine the
        // current residents below for instant feedback (the reload re-runs
        // applyFilters with an unchanged query, so this cannot loop). The
        // nil guard keeps legacy/preview-mode VMs (never paged) in pure
        // in-window refinement.
        let compiled = pagerQuery
        if let lastPaged = lastPagedQuery, compiled != lastPaged {
            lastPagedQuery = compiled
            reloadPagesForQueryChange()
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseSearchQuery(query)
        let isoFmt = isoFormatter

        let forensicEvidenceTags = ForensicManager.shared.evidenceTags

        var advancedMatchIDs: Set<UUID>?

        // Compile the parsed query into valid FTS5 grammar (FTSQueryBuilder).
        // Regex has no FTS5 form. Proximity compiles to a native NEAR(...) and
        // is routed through FTS5 with NO in-RAM fallback. Free-text/Boolean use
        // FTS when the index isn't mid-build, else a bounded window scan.
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
            allowInRAMFallback = false   // proximity is FTS5-only
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
            // Bounded on purpose: ask FTS which WINDOW ids match
            // (`matchingSubset`) instead of materializing an archive-wide id
            // list. Archive-wide truth (totals) comes from the pager's store
            // count, never this set.
            let windowIDs = residentEmails.map(\.id)
            let cacheKey = "\(ftsQuery)\u{1}\(residentEmails.count)\u{1}\(corpusVersion)"
            if cacheKey != ftsMatchKey {
                let searchTask = Task { [weak self] in
                    guard let self else { return }
                    let populated = ((try? await FTSSearchIndex.shared.rowCount()) ?? 0) > 0
                    if populated {
                        let ids = (try? await FTSSearchIndex.shared.matchingSubset(of: windowIDs, ftsQuery: ftsQuery)) ?? []
                        self.ftsMatchIDs = ids   // empty set = authoritative zero matches
                    } else {
                        // Nothing indexed yet. Free-text/Boolean fall back to a
                        // window scan; proximity has no fallback → authoritative empty.
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

        // Part P3 — bounded regex: literal-derived FTS candidates + exact
        // verification (or a capped scope scan, with the cap SURFACED via
        // `searchNotice`, never silent). Async like the FTS path; while the
        // result is pending the list shows no regex matches rather than wrong
        // ones, and re-renders when the task lands.
        if parsed.isRegexQuery && !parsed.freeText.isEmpty {
            let pattern = parsed.freeText
            let cacheKey = "\(pattern)\u{1}\(corpusVersion)"
            if cacheKey != regexMatchKey {
                let searchTask = Task { [weak self] in
                    guard let self else { return }
                    let outcome = (try? await self.archive.regexSearch(pattern: pattern)) ?? RegexSearchOutcome()
                    self.regexMatchIDs = outcome.matchedIDs
                    self.searchNotice = outcome.truncated
                        ? "Regex too broad — only the first \(outcome.scanned) emails were scanned. Add a text term or a date filter to narrow it."
                        : nil
                    self.regexMatchKey = cacheKey
                    self.applyFilters()
                }
                #if DEBUG
                lastFTSSearchTask = searchTask
                #endif
            }
            advancedMatchIDs = (regexMatchKey == cacheKey ? regexMatchIDs : nil) ?? []
        } else {
            regexMatchKey = nil
            regexMatchIDs = nil
            if parsed.isProximityQuery {
                // Proximity matches within the loaded page window (NEAR has no
                // repository paging form) — surfaced, never silent.
                searchNotice = "Proximity search matches loaded pages — scroll or Load More to search further."
            } else if searchNotice != nil {
                searchNotice = nil
            }
        }

        if parsed.searchInAttachments && !parsed.freeText.isEmpty {
            // Attachment-CONTENT search: filenames AND extracted text (PDF,
            // text families) via the persisted attachment_search FTS table.
            // Results are cached per query; a cache miss dispatches one
            // bounded async lookup and re-applies when it lands.
            let cacheKey = parsed.freeText.lowercased()
            if let cached = attachmentSearchCache[cacheKey] {
                if let existing = advancedMatchIDs {
                    advancedMatchIDs = existing.intersection(cached)
                } else {
                    advancedMatchIDs = cached
                }
                if let progress = attachmentIndexProgress, progress.pending > 0 {
                    searchNotice = "Searching attachment names + contents — \(progress.pending) email(s) still being indexed."
                } else if searchNotice == nil && cached.isEmpty {
                    searchNotice = "No attachments matched. Contents of PDF and text files are searched; other binary formats match by filename."
                }
            } else {
                advancedMatchIDs = advancedMatchIDs ?? []   // empty until the lookup lands
                searchNotice = "Searching attachment contents…"
                lastAttachmentSearchTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(parsed.freeText) ?? FTSQueryBuilder.escapeTerm(parsed.freeText)
                    let ids = (try? await SQLiteEmailStore.shared.attachmentTextSearch(ftsQuery)) ?? []
                    self.attachmentSearchCache[cacheKey] = ids
                    self.attachmentIndexProgress = try? await SQLiteEmailStore.shared.attachmentTextProgress()
                    self.applyFilters()
                }
            }
        }

        var result = residentEmails.filter { email in
            if review.isTrashed(email.id) { return false }
            if review.isArchived(email.id) { return false }
            if showPinnedOnly && !review.isPinned(email.id) { return false }
            if let clusterIDs = clusterFilterIDs {
                if !clusterIDs.contains(email.id) { return false }
            }
            if let pinnedIDs = aiPinnedIDs {
                if !pinnedIDs.contains(email.id) { return false }
            }

            // Min Reply Count is SQL-compiled (minSenderMessages) — the old
            // in-window lookup against the 500-sender rollup dropped rows
            // whose sender fell outside the rollup (the 'weird behavior').

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

            // hasAttachmentFilter is SQL-compiled (currentArchiveQuery →
            // has_attach flag) — an in-window attachments.isEmpty re-check
            // would wrongly drop header-recovered rows whose flag is set
            // but whose metadata is unrecoverable.

            let matchesType = parsed.typeOperator.map { email.messageType == $0 } ?? true
            let matchesTag = parsed.tagOperator.map { tag in
                // Parser labels live in email.tags (side table) and headers;
                // user tags in the review service. Any of the three counts —
                // the SQL page already restricted to true matches.
                let headerTags = email.headers["X-Keywords"] ?? email.headers["X-Gmail-Labels"] ?? ""
                return headerTags.localizedCaseInsensitiveContains(tag)
                    || email.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                    || review.tags(for: email.id).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            } ?? true
            let matchesSource = parsed.sourceOperator.map { source in
                let emailSource = email.headers["sourceFile"] ?? email.headers["X-Source-File"] ?? ""
                return emailSource.localizedCaseInsensitiveContains(source)
            } ?? true

            return filterMatch(email)
                && matchesFromOp && matchesToOp && matchesSubjectOp && matchesHasAttachment && matchesDateOps && matchesEvidenceTag && matchesSmartTag && matchesType && matchesTag && matchesSource
        }
        // Free-tier visibility cap — gated from the store-count-driven paging
        // depth; this is a defensive second bound on the visible list.
        if !isPremiumUser && result.count > StoreManager.freeEmailLimit {
            result = Array(result.prefix(StoreManager.freeEmailLimit))
        }
        visibleEmails = result
        sortVisibleEmails()
        if groupByThread {
            emailThreads = ThreadGrouper.group(visibleEmails)
        }
        recomputeSmartTagCounts()
    }

    // MARK: - Filtering Logic (in-window)
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

    private func sortVisibleEmails() {
        switch sortBy {
        case .dateAsc:
            visibleEmails.sort {
                (isoFormatter.date(from: $0.timestamp) ?? .distantPast) <
                (isoFormatter.date(from: $1.timestamp) ?? .distantPast)
            }
        case .dateDesc:
            visibleEmails.sort {
                (isoFormatter.date(from: $0.timestamp) ?? .distantPast) >
                (isoFormatter.date(from: $1.timestamp) ?? .distantPast)
            }
        case .subjectAsc:
            visibleEmails.sort {
                ($0.headers["Subject"] ?? "")
                    .localizedCompare($1.headers["Subject"] ?? "") == .orderedAscending
            }
        case .priorityDesc:
            visibleEmails.sort {
                (priorityScores[$0.id] ?? 0) > (priorityScores[$1.id] ?? 0)
            }
        case .sizeDesc:
            visibleEmails.sort {
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

    // MARK: - Priority Scores (cached, per window)
    @Published var priorityScores: [UUID: Int] = [:]

    // Part I.2: this synchronous pass over the BOUNDED resident window keeps
    // sort-by-priority correct immediately at load; the persisted per-email
    // priority (derived store, computed by the archive-wide background job
    // with DB-side sender counts) overwrites these values when
    // computeAIFilterData's fetch completes, and is the archive truth.
    func computePriorityScores() {
        let results = EmailNLPEngine.scoreAllPriorities(residentEmails, replyCountPerSender: replyCountPerSender)
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
        guard !aiFiltersComputed, !residentEmails.isEmpty, enableAIFeatures else { return }
        // Part I: the filter attributes are PERSISTED derived state
        // (ArchiveDerivedStateStore), computed once by a bounded background job
        // — not recomputed over the resident window every time filters need
        // them. This reads the persisted records for the resident window,
        // computes-and-persists only the missing ones (bounded by the window,
        // in 300-email batches), then kicks the incremental archive-wide job
        // for everything else. Reopening costs one fetch.
        let windowEmails = residentEmails
        let senderCounts = replyCountPerSender
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = ArchiveDerivedStateStore.shared
            let ids = windowEmails.map(\.id)
            var records = (try? await store.fetch(ids: ids)) ?? [:]

            // Fill in window emails that have no (current-version) record yet.
            let missing = windowEmails.filter {
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
            // list UI reads (same thresholds/values as before).
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

    // Cleanup Mode sender rollups + archive storage total live in
    // ArchiveAggregateService.senderRollups / totalSizeBytes (Part G9): SQL
    // GROUP BY / SUM aggregates over the store, consumed by the cleanup view
    // directly — the page window must not be presented as archive stats.

    // NOTE (Part S): everything below is WINDOW-SCOPED by design — it
    // describes the resident bounded page window (its filter pickers and
    // date-filter defaults), not the whole archive. Archive-wide equivalents
    // live in ArchiveAggregateService.
    var earliestEmailDate: Date? {
        residentEmails.compactMap { isoFormatter.date(from: $0.timestamp) }.min()
    }
    var latestEmailDate: Date? {
        residentEmails.compactMap { isoFormatter.date(from: $0.timestamp) }.max()
    }
    var allFromEmails: [String] {
        Array(Set(residentEmails.compactMap { $0.headers["From"] })).sorted()
    }
    var allToEmails: [String] {
        Array(Set(residentEmails.compactMap { $0.headers["To"] })).sorted()
    }
    var allSubjects: [String] {
        Array(Set(residentEmails.compactMap { $0.headers["Subject"] })).sorted()
    }
    var allDomains: [String] {
        let domains = residentEmails.flatMap { $0.domains }
        return Array(Set(domains)).sorted()
    }
    var allTags: [String] {
        Array(Set(residentEmails.flatMap { $0.tags })).sorted()
    }
    /// Date span of the visible (window-backed) list.
    var filteredDateRange: (Date?, Date?) {
        let dates = visibleEmails.compactMap { isoFormatter.date(from: $0.timestamp) }
        return (dates.min(), dates.max())
    }

    /// For sidebar: returns senders sorted by their email count descending
    /// (store aggregate).
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
