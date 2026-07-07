import SwiftUI
import NaturalLanguage

@MainActor
class ForensicReviewManager: ObservableObject {
    static let shared = ForensicReviewManager()

    // MARK: - Hot Document Folders

    struct HotFolder: Identifiable, Codable {
        let id: UUID
        var name: String
        var emailIDs: [UUID]
        var colorName: String
        var createdAt: Date

        init(name: String, colorName: String = "red") {
            self.id = UUID()
            self.name = name
            self.emailIDs = []
            self.colorName = colorName
            self.createdAt = Date()
        }
    }

    @Published var hotFolders: [HotFolder] = [] {
        didSet { if _initialized { save() } }
    }

    func createHotFolder(name: String, color: String = "red") {
        hotFolders.append(HotFolder(name: name, colorName: color))
    }

    func addToHotFolder(_ folderID: UUID, emailIDs: [UUID]) {
        guard let idx = hotFolders.firstIndex(where: { $0.id == folderID }) else { return }
        let existing = Set(hotFolders[idx].emailIDs)
        let newIDs = emailIDs.filter { !existing.contains($0) }
        hotFolders[idx].emailIDs.append(contentsOf: newIDs)
    }

    func removeFromHotFolder(_ folderID: UUID, emailIDs: Set<UUID>) {
        guard let idx = hotFolders.firstIndex(where: { $0.id == folderID }) else { return }
        hotFolders[idx].emailIDs.removeAll { emailIDs.contains($0) }
    }

    func deleteHotFolder(_ folderID: UUID) {
        hotFolders.removeAll { $0.id == folderID }
    }

    // MARK: - Production Sets

    enum ProductionStatus: String, Codable, CaseIterable {
        case draft = "Draft"
        case inReview = "In Review"
        case produced = "Produced"
        case delivered = "Delivered"

        var color: Color {
            switch self {
            case .draft: return .secondary
            case .inReview: return .blue
            case .produced: return .green
            case .delivered: return .purple
            }
        }

        var icon: String {
            switch self {
            case .draft: return "doc.badge.gearshape"
            case .inReview: return "eye"
            case .produced: return "checkmark.seal"
            case .delivered: return "shippingbox"
            }
        }
    }

    struct ProductionSet: Identifiable, Codable {
        let id: UUID
        var name: String
        var emailIDs: [UUID]
        var batesPrefix: String
        var batesStart: Int
        var status: ProductionStatus
        var createdAt: Date
        var notes: String

        init(name: String, batesPrefix: String = "PROD", batesStart: Int = 1) {
            self.id = UUID()
            self.name = name
            self.emailIDs = []
            self.batesPrefix = batesPrefix
            self.batesStart = batesStart
            self.status = .draft
            self.createdAt = Date()
            self.notes = ""
        }

        var emailCount: Int { emailIDs.count }

        func batesRange() -> String {
            guard !emailIDs.isEmpty else { return "—" }
            let pad = 6
            let first = "\(batesPrefix)\(String(format: "%0\(pad)d", batesStart))"
            let last = "\(batesPrefix)\(String(format: "%0\(pad)d", batesStart + emailIDs.count - 1))"
            return "\(first) – \(last)"
        }
    }

    @Published var productionSets: [ProductionSet] = [] {
        didSet { if _initialized { save() } }
    }

    func createProductionSet(name: String, prefix: String = "PROD", start: Int = 1) {
        productionSets.append(ProductionSet(name: name, batesPrefix: prefix, batesStart: start))
    }

    func addToProductionSet(_ setID: UUID, emailIDs: [UUID]) {
        guard let idx = productionSets.firstIndex(where: { $0.id == setID }) else { return }
        let existing = Set(productionSets[idx].emailIDs)
        let newIDs = emailIDs.filter { !existing.contains($0) }
        productionSets[idx].emailIDs.append(contentsOf: newIDs)
    }

    func removeFromProductionSet(_ setID: UUID, emailIDs: Set<UUID>) {
        guard let idx = productionSets.firstIndex(where: { $0.id == setID }) else { return }
        productionSets[idx].emailIDs.removeAll { emailIDs.contains($0) }
    }

    func updateProductionStatus(_ setID: UUID, status: ProductionStatus) {
        guard let idx = productionSets.firstIndex(where: { $0.id == setID }) else { return }
        productionSets[idx].status = status
    }

    func deleteProductionSet(_ setID: UUID) {
        productionSets.removeAll { $0.id == setID }
    }

    // MARK: - Reviewer Notes (Multiple Per Email)

    struct ReviewerNote: Identifiable, Codable {
        let id: UUID
        var text: String
        var author: String
        var timestamp: Date
        var category: NoteCategory

        enum NoteCategory: String, Codable, CaseIterable {
            case general = "General"
            case privilege = "Privilege"
            case issue = "Issue"
            case followUp = "Follow Up"
            case redaction = "Redaction"

            var icon: String {
                switch self {
                case .general: return "note.text"
                case .privilege: return "lock.shield"
                case .issue: return "exclamationmark.circle"
                case .followUp: return "arrow.uturn.forward"
                case .redaction: return "eye.slash"
                }
            }

            var color: Color {
                switch self {
                case .general: return .secondary
                case .privilege: return .orange
                case .issue: return .red
                case .followUp: return .blue
                case .redaction: return .purple
                }
            }
        }

        init(text: String, author: String, category: NoteCategory = .general) {
            self.id = UUID()
            self.text = text
            self.author = author
            self.timestamp = Date()
            self.category = category
        }
    }

    @Published var emailNotes: [UUID: [ReviewerNote]] = [:] {
        didSet { if _initialized { save() } }
    }

    func addNote(to emailID: UUID, text: String, category: ReviewerNote.NoteCategory = .general) {
        let author = ForensicManager.shared.examinerName.isEmpty ? "Reviewer" : ForensicManager.shared.examinerName
        let note = ReviewerNote(text: text, author: author, category: category)
        emailNotes[emailID, default: []].append(note)
    }

    func deleteNote(_ noteID: UUID, from emailID: UUID) {
        emailNotes[emailID]?.removeAll { $0.id == noteID }
    }

    func notesCount(for emailID: UUID) -> Int {
        emailNotes[emailID]?.count ?? 0
    }

    // MARK: - Saved Searches

    struct SavedSearch: Identifiable, Codable {
        let id: UUID
        var name: String
        var query: String
        var createdAt: Date

        init(name: String, query: String) {
            self.id = UUID()
            self.name = name
            self.query = query
            self.createdAt = Date()
        }
    }

    @Published var savedSearches: [SavedSearch] = [] {
        didSet { if _initialized { save() } }
    }

    func saveSearch(name: String, query: String) {
        savedSearches.append(SavedSearch(name: name, query: query))
    }

    func deleteSavedSearch(_ id: UUID) {
        savedSearches.removeAll { $0.id == id }
    }

    // MARK: - Near-Duplicate Clusters

    struct DuplicateCluster: Identifiable {
        let id: UUID
        let representative: UUID
        var memberIDs: [UUID]
        var similarity: Double
    }

    func findNearDuplicateClusters(emails: [MBOXParser.RawEmail], threshold: Double = 0.85) -> [DuplicateCluster] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }

        struct EmailVec {
            let id: UUID
            let subject: String
            let body: String
        }

        let items = emails.map { EmailVec(id: $0.id, subject: $0.headers["Subject"] ?? "", body: String($0.plainBody.prefix(200))) }
        var clusters: [DuplicateCluster] = []
        var assigned: Set<UUID> = []

        for i in 0..<items.count {
            guard !assigned.contains(items[i].id) else { continue }
            var members: [UUID] = []
            let textA = items[i].subject + " " + items[i].body

            for j in (i + 1)..<items.count {
                guard !assigned.contains(items[j].id) else { continue }
                let textB = items[j].subject + " " + items[j].body
                let dist = embedding.distance(between: textA, and: textB)
                let sim = max(0, 1.0 - Double(dist))
                if sim >= threshold {
                    members.append(items[j].id)
                    assigned.insert(items[j].id)
                }
            }

            if !members.isEmpty {
                assigned.insert(items[i].id)
                clusters.append(DuplicateCluster(
                    id: UUID(),
                    representative: items[i].id,
                    memberIDs: [items[i].id] + members,
                    similarity: threshold
                ))
            }
        }

        return clusters
    }

    // MARK: - Privilege Log Export

    func generatePrivilegeLog(emails: [MBOXParser.RawEmail]) -> String {
        let forensic = ForensicManager.shared
        let privilegedEmails = emails.filter { forensic.tagForEmail($0.id) == .privileged }

        guard !privilegedEmails.isEmpty else {
            return "No emails tagged as Privileged."
        }

        var log = "PRIVILEGE LOG\n"
        log += "Case: \(forensic.caseNumber)\n"
        log += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        log += "Examiner: \(forensic.examinerName)\n"
        log += String(repeating: "=", count: 80) + "\n\n"

        let bates = BatesNumberingManager.shared

        for (i, email) in privilegedEmails.enumerated() {
            let batesNum = bates.getBatesNumber(for: email.id) ?? "N/A"
            let from = email.headers["From"] ?? "Unknown"
            let to = email.headers["To"] ?? "Unknown"
            let cc = email.headers["Cc"] ?? ""
            let date = email.headers["Date"] ?? "Unknown"
            let subject = email.headers["Subject"] ?? "(No Subject)"

            let flags = forensic.privilegeFlags[email.id] ?? []
            let basis = flags.isEmpty ? "Attorney-Client Privilege" : flags.joined(separator: "; ")

            let notes = emailNotes[email.id]?
                .filter { $0.category == .privilege }
                .map(\.text)
                .joined(separator: "; ") ?? ""

            log += "Entry \(i + 1)\n"
            log += "  Bates:     \(batesNum)\n"
            log += "  Date:      \(date)\n"
            log += "  From:      \(from)\n"
            log += "  To:        \(to)\n"
            if !cc.isEmpty { log += "  CC:        \(cc)\n" }
            log += "  Subject:   \(subject)\n"
            log += "  Basis:     \(basis)\n"
            if !notes.isEmpty { log += "  Notes:     \(notes)\n" }
            log += String(repeating: "-", count: 60) + "\n"
        }

        log += "\nTotal Privileged Documents: \(privilegedEmails.count)\n"
        return log
    }

    // MARK: - Review Queue

    @Published var reviewQueueMode = false
    @Published var reviewQueueIndex = 0

    func startReviewQueue() {
        reviewQueueMode = true
        reviewQueueIndex = 0
    }

    func stopReviewQueue() {
        reviewQueueMode = false
    }

    // MARK: - Coding Dashboard Stats

    struct CodingDashboard {
        var totalEmails: Int
        var codedCount: Int
        var tagDistribution: [ForensicManager.EvidenceTag: Int]
        var privilegeFlagCount: Int
        var codingVelocity: Double
        var estimatedCompletionMinutes: Double
        var progress: Double
    }

    func computeDashboard(emails: [MBOXParser.RawEmail]) -> CodingDashboard {
        let forensic = ForensicManager.shared
        let total = emails.count
        var dist: [ForensicManager.EvidenceTag: Int] = [:]
        var coded = 0

        for email in emails {
            let tag = forensic.tagForEmail(email.id)
            dist[tag, default: 0] += 1
            if tag != .none { coded += 1 }
        }

        let stats = forensic.computeReviewerStats()
        let velocity = stats.avgSecondsPerTag > 0 ? 60.0 / stats.avgSecondsPerTag : 0
        let remaining = total - coded
        let etaMinutes = velocity > 0 ? Double(remaining) / velocity : 0
        let progress = total > 0 ? Double(coded) / Double(total) : 0

        return CodingDashboard(
            totalEmails: total,
            codedCount: coded,
            tagDistribution: dist,
            privilegeFlagCount: forensic.privilegeFlags.count,
            codingVelocity: velocity,
            estimatedCompletionMinutes: etaMinutes,
            progress: progress
        )
    }

    // MARK: - Persistence

    private var _initialized = false

    private static let storageURL: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("forensic_review_manager.json")
    }()

    private struct StorageData: Codable {
        var hotFolders: [HotFolder]
        var productionSets: [ProductionSet]
        var emailNotes: [String: [ReviewerNote]]
        var savedSearches: [SavedSearch]
    }

    private init() {
        load()
        _initialized = true
    }

    private func save() {
        let noteDict = emailNotes.reduce(into: [String: [ReviewerNote]]()) { dict, pair in
            dict[pair.key.uuidString] = pair.value
        }
        let data = StorageData(
            hotFolders: hotFolders,
            productionSets: productionSets,
            emailNotes: noteDict,
            savedSearches: savedSearches
        )
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: Self.storageURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let decoded = try? JSONDecoder().decode(StorageData.self, from: data) else { return }
        hotFolders = decoded.hotFolders
        productionSets = decoded.productionSets
        savedSearches = decoded.savedSearches
        emailNotes = decoded.emailNotes.reduce(into: [UUID: [ReviewerNote]]()) { dict, pair in
            if let uuid = UUID(uuidString: pair.key) {
                dict[uuid] = pair.value
            }
        }
    }

    func clearAll() {
        hotFolders = []
        productionSets = []
        emailNotes = [:]
        savedSearches = []
        try? FileManager.default.removeItem(at: Self.storageURL)
    }
}
