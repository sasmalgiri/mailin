import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let searchableIndex = CSSearchableIndex.default()

    /// Index emails into CoreSpotlight in batches of 100 to avoid memory spikes.
    /// Processing happens on a background thread via Task.detached.
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

                    // Title = subject
                    attributeSet.title = email.headers["Subject"] ?? "(No Subject)"

                    // Content description = body snippet (first 500 chars, strip HTML)
                    let bodySnippet: String
                    if !email.plainBody.isEmpty {
                        bodySnippet = String(email.plainBody.prefix(500))
                    } else if !email.htmlBody.isEmpty {
                        let stripped = email.htmlBody
                            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        bodySnippet = String(stripped.prefix(500))
                    } else {
                        bodySnippet = ""
                    }
                    attributeSet.contentDescription = bodySnippet

                    // Author info
                    let from = email.headers["From"] ?? ""
                    attributeSet.authorNames = [from]
                    if let emailStart = from.range(of: "<"), let emailEnd = from.range(of: ">"),
                       emailStart.upperBound <= emailEnd.lowerBound {
                        attributeSet.authorEmailAddresses = [String(from[emailStart.upperBound..<emailEnd.lowerBound])]
                    } else if from.contains("@") {
                        attributeSet.authorEmailAddresses = [from.trimmingCharacters(in: .whitespacesAndNewlines)]
                    } else {
                        attributeSet.authorEmailAddresses = [from]
                    }

                    // Recipient info
                    if let toField = email.headers["To"], !toField.isEmpty {
                        let recipients = toField.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        attributeSet.recipientEmailAddresses = recipients
                    }

                    // Mailbox identifier (source file if available)
                    if let sourceFile = email.headers["sourceFile"], !sourceFile.isEmpty {
                        attributeSet.mailboxIdentifiers = [sourceFile]
                    }

                    // Content creation date
                    if let date = MBOXParser.parseDate(email.headers["Date"]) {
                        attributeSet.contentCreationDate = date
                    }

                    // Content type
                    attributeSet.contentType = UTType.emailMessage.identifier

                    // Keywords from tags and domains
                    var keywords: [String] = []
                    keywords.append(contentsOf: email.tags)
                    keywords.append(contentsOf: email.domains)
                    if let subject = email.headers["Subject"] {
                        // Extract meaningful words from subject as keywords
                        let subjectWords = subject
                            .components(separatedBy: .whitespaces)
                            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                            .filter { $0.count > 2 }
                        keywords.append(contentsOf: subjectWords)
                    }
                    attributeSet.keywords = keywords

                    let item = CSSearchableItem(
                        uniqueIdentifier: email.id.uuidString,
                        domainIdentifier: "com.ecosanskriti.mailin.emails",
                        attributeSet: attributeSet
                    )
                    items.append(item)
                }

                do {
                    try await CSSearchableIndex.default().indexSearchableItems(items)
                } catch {
                    // Silently continue on indexing errors to avoid blocking the import flow
                }
            }
        }
    }

    /// Remove all indexed emails from Spotlight.
    func removeAllIndexedEmails() {
        searchableIndex.deleteSearchableItems(withDomainIdentifiers: ["com.ecosanskriti.mailin.emails"]) { _ in }
    }

    /// Remove specific emails from Spotlight by their UUIDs.
    func removeEmails(withIDs ids: [UUID]) {
        searchableIndex.deleteSearchableItems(withIdentifiers: ids.map(\.uuidString)) { _ in }
    }

    /// Handle Spotlight continuation - when user taps a Spotlight result.
    /// Returns the UUID of the email that was tapped, or nil if invalid.
    func handleSpotlightActivity(_ activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let uuid = UUID(uuidString: identifier) else { return nil }
        return uuid
    }
}
