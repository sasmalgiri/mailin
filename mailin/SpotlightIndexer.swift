import CoreSpotlight
import UniformTypeIdentifiers
import Contacts

@MainActor
class SpotlightIndexer: NSObject, CSSearchableIndexDelegate {
    static let shared = SpotlightIndexer()
    private let searchableIndex = CSSearchableIndex.default()

    private var aiSummaries: [String: String] = [:]
    private var aiPriorities: Set<String> = []

    override init() {
        super.init()
        searchableIndex.indexDelegate = self
    }

    /// Index emails into CoreSpotlight in batches of 100.
    /// Uses CSPerson for authors, full textContent for AI summarization,
    /// and updateListenerOptions for Apple Intelligence summaries + priority.
    func indexEmails(_ emails: [MBOXParser.RawEmail]) {
        let emailsCopy = emails
        Task.detached(priority: .utility) {
            let batchSize = 100
            for batchStart in stride(from: 0, to: emailsCopy.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, emailsCopy.count)
                let batch = Array(emailsCopy[batchStart..<batchEnd])

                var items: [CSSearchableItem] = []
                for email in batch {
                    let attributeSet = CSSearchableItemAttributeSet(contentType: UTType.emailMessage)

                    attributeSet.title = email.headers["Subject"] ?? "(No Subject)"
                    attributeSet.contentType = UTType.emailMessage.identifier

                    // Full text content for Apple Intelligence summarization (needs 200+ chars)
                    let fullText: String
                    if !email.plainBody.isEmpty {
                        fullText = email.plainBody
                    } else if !email.htmlBody.isEmpty {
                        fullText = email.htmlBody
                            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        fullText = ""
                    }
                    attributeSet.textContent = fullText

                    // Short description for Spotlight results UI
                    attributeSet.contentDescription = String(fullText.prefix(500))

                    // CSPerson author — enables Apple Intelligence to distinguish conversation participants
                    let fromRaw = email.headers["From"] ?? ""
                    let (displayName, emailAddr) = Self.parseFromHeader(fromRaw)
                    let author = CSPerson(
                        displayName: displayName,
                        handles: emailAddr.isEmpty ? [fromRaw] : [emailAddr],
                        handleIdentifier: CNContactEmailAddressesKey
                    )
                    attributeSet.authors = [author]
                    attributeSet.authorNames = [displayName]
                    if !emailAddr.isEmpty {
                        attributeSet.authorEmailAddresses = [emailAddr]
                    }

                    // Recipients
                    if let toField = email.headers["To"], !toField.isEmpty {
                        let recipients = toField.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        attributeSet.recipientEmailAddresses = recipients
                    }

                    // Thread domain ID — Apple Intelligence uses this to group conversation threads
                    let threadID: String
                    if let msgID = email.headers["In-Reply-To"], !msgID.isEmpty {
                        threadID = msgID
                    } else if let refs = email.headers["References"]?.components(separatedBy: " ").first, !refs.isEmpty {
                        threadID = refs
                    } else {
                        threadID = email.headers["Subject"]?
                            .replacingOccurrences(of: "^(Re|Fwd|Fw):\\s*", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? email.id.uuidString
                    }
                    attributeSet.domainIdentifier = threadID

                    // Content creation date
                    if let date = MBOXParser.parseDate(email.headers["Date"]) {
                        attributeSet.contentCreationDate = date
                    }

                    // Source file
                    if let sourceFile = email.headers["sourceFile"], !sourceFile.isEmpty {
                        attributeSet.mailboxIdentifiers = [sourceFile]
                    }

                    // Keywords
                    var keywords: [String] = []
                    keywords.append(contentsOf: email.tags)
                    keywords.append(contentsOf: email.domains)
                    if let subject = email.headers["Subject"] {
                        let subjectWords = subject
                            .components(separatedBy: .whitespaces)
                            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                            .filter { $0.count > 2 }
                        keywords.append(contentsOf: subjectWords)
                    }
                    attributeSet.keywords = keywords

                    let item = CSSearchableItem(
                        uniqueIdentifier: email.id.uuidString,
                        domainIdentifier: "com.ecosanskriti.mailincloud.emails",
                        attributeSet: attributeSet
                    )

                    // Enable Apple Intelligence summarization + priority classification
                    if #available(macOS 15.4, iOS 18.4, *) {
                        item.updateListenerOptions = [.summarization, .priority]
                    }

                    items.append(item)
                }

                do {
                    try await CSSearchableIndex.default().indexSearchableItems(items)
                } catch {
                    // Silently continue on indexing errors
                }
            }
        }
    }

    // MARK: - CSSearchableIndexDelegate (receive AI-generated summaries & priority)

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        acknowledgementHandler()
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        acknowledgementHandler()
    }

    nonisolated func searchableItemsDidUpdate(_ items: [CSSearchableItem]) {
        if #available(macOS 15.4, iOS 18.4, *) {
            Task { @MainActor in
                for item in items {
                    let id = item.uniqueIdentifier
                    if let summary = item.attributeSet.textContentSummary, !summary.isEmpty {
                        aiSummaries[id] = summary
                    }
                    if let isPriority = item.attributeSet.isPriority, isPriority.boolValue {
                        aiPriorities.insert(id)
                    }
                }
            }
        }
    }

    /// Get Apple Intelligence generated summary for an email (if available)
    func aiSummary(for emailID: UUID) -> String? {
        aiSummaries[emailID.uuidString]
    }

    /// Check if Apple Intelligence flagged an email as priority
    func isAIPriority(_ emailID: UUID) -> Bool {
        aiPriorities.contains(emailID.uuidString)
    }

    // MARK: - CSUserQuery Semantic Search (Apple Intelligence powered)

    func semanticSearch(query: String, limit: Int = 10) async -> [(id: String, title: String, snippet: String)] {
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title", "textContent", "authorNames", "contentDescription", "textContentSummary"]
        context.maxResultCount = limit
        context.enableRankedResults = true

        let userQuery = CSUserQuery(userQueryString: query, userQueryContext: context)

        var results: [(id: String, title: String, snippet: String)] = []
        do {
            for try await element in userQuery.responses {
                switch element {
                case .item(let item):
                    let attrs = item.item.attributeSet
                    let title = attrs.title ?? "(No Subject)"
                    let snippet: String
                    if #available(macOS 15.4, iOS 18.4, *) {
                        snippet = attrs.textContentSummary ?? attrs.contentDescription ?? ""
                    } else {
                        snippet = attrs.contentDescription ?? ""
                    }
                    results.append((id: item.item.uniqueIdentifier, title: title, snippet: snippet))
                case .suggestion:
                    break
                @unknown default:
                    break
                }
            }
        } catch {
            // Fall through — return whatever results we got
        }
        return results
    }

    // MARK: - Removal

    func removeAllIndexedEmails() {
        searchableIndex.deleteSearchableItems(withDomainIdentifiers: ["com.ecosanskriti.mailincloud.emails"]) { [weak self] _ in
            Task { @MainActor in
                self?.aiSummaries.removeAll()
                self?.aiPriorities.removeAll()
            }
        }
    }

    func removeEmails(withIDs ids: [UUID]) {
        let idStrings = ids.map(\.uuidString)
        searchableIndex.deleteSearchableItems(withIdentifiers: idStrings) { [weak self] _ in
            Task { @MainActor in
                for id in idStrings {
                    self?.aiSummaries.removeValue(forKey: id)
                    self?.aiPriorities.remove(id)
                }
            }
        }
    }

    func handleSpotlightActivity(_ activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let uuid = UUID(uuidString: identifier) else { return nil }
        return uuid
    }

    // MARK: - Helpers

    private nonisolated static func parseFromHeader(_ from: String) -> (displayName: String, email: String) {
        if let angleBracketStart = from.range(of: "<"),
           let angleBracketEnd = from.range(of: ">"),
           angleBracketStart.upperBound <= angleBracketEnd.lowerBound {
            let email = String(from[angleBracketStart.upperBound..<angleBracketEnd.lowerBound])
            let name = from[from.startIndex..<angleBracketStart.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (name.isEmpty ? email : name, email)
        } else if from.contains("@") {
            return (from.trimmingCharacters(in: .whitespacesAndNewlines), from.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (from, "")
    }
}
