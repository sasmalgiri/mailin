import Foundation
import Combine

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
    @Published var sortBy: SortOption = .dateDesc

    // Reply count filter
    @Published var minReplyCount: Int = 0 {
        didSet { applyFilters() }
    }

    // MARK: - Data
    @Published var allEmails: [MBOXParser.RawEmail] = []
    @Published var filteredEmails: [MBOXParser.RawEmail] = []
    @Published var replyCountPerSender: [String: Int] = [:]

    private let isoFormatter = ISO8601DateFormatter()

    // MARK: - Init
    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
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
            applyFilters()
            showParsedList = true
        }
    }

    // MARK: - MBOX Parse Logic with Progress
    func parseMBOX(fileURL: URL, senderEmail: String) {
        isParsing = true
        isParsed = false
        parseProgress = 0.0
        allEmails = []
        filteredEmails = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let emails = try MBOXParser.parse(
                    fileURL: fileURL,
                    senderEmail: senderEmail,
                    onProgress: { progress in
                        DispatchQueue.main.async {
                            self?.parseProgress = progress
                        }
                    }
                )
                DispatchQueue.main.async {
                    self?.allEmails = emails
                    self?.isParsed = true
                    self?.isParsing = false
                    self?.parseProgress = 1.0
                    self?.emailCount = emails.count
                    self?.replyCountPerSender = self?.computeReplyCountPerSender(in: emails) ?? [:]
                    self?.startDate = self?.earliestEmailDate ?? .distantPast
                    self?.endDate = self?.latestEmailDate ?? .distantFuture
                    self?.applyFilters()
                    self?.showParsedList = true
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isParsing = false
                    self?.isParsed = false
                    self?.parseProgress = 0.0
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
        startDate = earliestEmailDate ?? .distantPast
        endDate = latestEmailDate ?? .distantFuture
        minReplyCount = 0
        applyFilters()
    }

    // MARK: - Apply Filters (with minReplyCount logic)
    func applyFilters() {
        filteredEmails = allEmails.filter { email in
            let fromEmail = email.headers["From"] ?? ""
            let replyCount = replyCountPerSender[fromEmail] ?? 0
            return filterMatch(email) && replyCount >= minReplyCount
        }
        sortFilteredEmails()
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
        let date = isoFormatter.date(from: email.timestamp) ?? .distantPast
        let froms = allPossibleKeys(email.headers, for: "From")
        let tos = allPossibleKeys(email.headers, for: "To")
        let subject = email.headers["Subject"] ?? ""
        let matchesDate = (startDate...endDate).contains(date)
        let matchesDomain = selectedDomains.isEmpty || !Set(email.domains).isDisjoint(with: selectedDomains)
        let matchesSubject = selectedSubjects.isEmpty || selectedSubjects.contains(subject)
        let matchesFrom = selectedFromEmails.isEmpty || selectedFromEmails.contains { candidate in froms.contains(candidate) }
        let matchesTo = selectedToEmails.isEmpty || selectedToEmails.contains { candidate in tos.contains(candidate) }
        return matchesDate && matchesDomain && matchesSubject && matchesFrom && matchesTo
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
        }
    }

    // MARK: - Sort Options
    enum SortOption: String, CaseIterable, Equatable {
        case dateAsc = "Date ↑"
        case dateDesc = "Date ↓"
        case subjectAsc = "Subject A-Z"
        var label: String {
            switch self {
            case .dateAsc: return "🕒 Date ↑"
            case .dateDesc: return "🕒 Date ↓"
            case .subjectAsc: return "🔤 Subject A-Z"
            }
        }
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
