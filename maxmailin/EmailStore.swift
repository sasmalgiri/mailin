//
//  EmailStore.swift
//  maxmailin
//
//  Bridge between the SwiftData persistence layer (StoredEmail / StoredAttachment)
//  and the in-memory MBOXParser.RawEmail shape that every view, viewModel, AI
//  engine, and persona workflow already consumes.
//
//  Design goal: preserve the existing public surface (`[RawEmail]`) while the
//  underlying storage grows to millions of rows. Views ask EmailStore for
//  pages or filtered slices, never for the full archive.
//

import Foundation
import SwiftData

/// Errors that can surface during persistence operations.
enum EmailStoreError: LocalizedError {
    case containerUnavailable
    case migrationFailed(String)
    case insertFailed(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "Email storage container is unavailable."
        case .migrationFailed(let detail):
            return "Migration failed: \(detail)"
        case .insertFailed(let detail):
            return "Failed to save email: \(detail)"
        case .fetchFailed(let detail):
            return "Failed to fetch emails: \(detail)"
        }
    }
}

/// Actor-isolated facade over SwiftData. All persistence I/O goes through here
/// so we get Swift-enforced concurrency safety and a single audit point.
actor EmailStore {

    // MARK: - Container

    static let shared = EmailStore()

    private var container: ModelContainer?

    private init() {}

    /// Lazy container initialization. Called once on first use; safe to call
    /// repeatedly. Container path lives in Application Support so iOS Data
    /// Protection applies automatically.
    func ensureContainer() throws -> ModelContainer {
        if let container { return container }

        let schema = Schema([
            StoredEmail.self,
            StoredAttachment.self
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none      // strictly offline, no iCloud sync
        )
        do {
            let c = try ModelContainer(for: schema, configurations: [config])
            self.container = c
            return c
        } catch {
            throw EmailStoreError.containerUnavailable
        }
    }

    // MARK: - Insertion

    /// Persist a single parsed email. Idempotent on `messageID` when present:
    /// duplicate Message-IDs are skipped so re-importing the same archive is
    /// safe.
    func insert(
        _ email: MBOXParser.RawEmail,
        sourceFileHash: String? = nil,
        accountID: String? = nil
    ) throws {
        let container = try ensureContainer()
        let context = ModelContext(container)

        if let mid = email.headers["Message-ID"], !mid.isEmpty {
            let descriptor = FetchDescriptor<StoredEmail>(
                predicate: #Predicate { $0.messageID == mid }
            )
            if let existing = try context.fetch(descriptor).first {
                _ = existing
                return
            }
        }

        let date = parsedDate(from: email.headers["Date"]) ?? Date.distantPast
        let stored = StoredEmail(
            id: email.id,
            messageID: email.headers["Message-ID"],
            parserVersion: 1,
            subject: email.headers["Subject"] ?? "(No Subject)",
            fromAddress: email.headers["From"] ?? "",
            fromName: nil,
            toAddresses: email.headers["To"] ?? "",
            ccAddresses: email.headers["Cc"],
            bccAddresses: email.headers["Bcc"],
            date: date,
            bodyPreview: String(email.plainBody.prefix(400)),
            sourceFileHash: sourceFileHash
        )
        stored.accountID = accountID
        stored.plainBody = email.plainBody.data(using: .utf8)
        stored.htmlBody = email.htmlBody.data(using: .utf8)
        stored.rawSource = email.rawSource.data(using: .utf8)
        if let headersData = try? JSONEncoder().encode(email.headers) {
            stored.headersJSON = headersData
        }
        stored.inReplyToID = email.headers["In-Reply-To"]
        stored.referencesIDs = email.headers["References"]
        stored.sizeBytes = email.rawSource.utf8.count

        context.insert(stored)
        do {
            try context.save()
        } catch {
            throw EmailStoreError.insertFailed(error.localizedDescription)
        }
    }

    /// Batched insert. Coalesces saves every `batchSize` rows for speed during
    /// large imports.
    func insertBatch(
        _ emails: [MBOXParser.RawEmail],
        sourceFileHash: String? = nil,
        accountID: String? = nil,
        batchSize: Int = 500,
        progress: ((Int, Int) -> Void)? = nil
    ) throws {
        let container = try ensureContainer()
        let context = ModelContext(container)

        let total = emails.count
        var processed = 0

        for chunk in emails.chunked(into: batchSize) {
            for email in chunk {
                if let mid = email.headers["Message-ID"], !mid.isEmpty {
                    let descriptor = FetchDescriptor<StoredEmail>(
                        predicate: #Predicate { $0.messageID == mid }
                    )
                    if let _ = try? context.fetch(descriptor).first { continue }
                }
                let date = parsedDate(from: email.headers["Date"]) ?? Date.distantPast
                let stored = StoredEmail(
                    id: email.id,
                    messageID: email.headers["Message-ID"],
                    parserVersion: 1,
                    subject: email.headers["Subject"] ?? "(No Subject)",
                    fromAddress: email.headers["From"] ?? "",
                    fromName: nil,
                    toAddresses: email.headers["To"] ?? "",
                    ccAddresses: email.headers["Cc"],
                    bccAddresses: email.headers["Bcc"],
                    date: date,
                    bodyPreview: String(email.plainBody.prefix(400)),
                    sourceFileHash: sourceFileHash
                )
                stored.accountID = accountID
                stored.plainBody = email.plainBody.data(using: .utf8)
                stored.htmlBody = email.htmlBody.data(using: .utf8)
                stored.rawSource = email.rawSource.data(using: .utf8)
                if let h = try? JSONEncoder().encode(email.headers) {
                    stored.headersJSON = h
                }
                stored.inReplyToID = email.headers["In-Reply-To"]
                stored.referencesIDs = email.headers["References"]
                stored.sizeBytes = email.rawSource.utf8.count
                context.insert(stored)
            }
            do {
                try context.save()
            } catch {
                throw EmailStoreError.insertFailed(error.localizedDescription)
            }
            processed += chunk.count
            progress?(processed, total)
        }
    }

    // MARK: - Queries

    /// Page of emails for list display, ordered by date descending. Memory
    /// stays bounded regardless of total archive size.
    func page(offset: Int, limit: Int) throws -> [MBOXParser.RawEmail] {
        let container = try ensureContainer()
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<StoredEmail>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        do {
            let stored = try context.fetch(descriptor)
            return stored.map { rawEmail(from: $0, includeBodies: false) }
        } catch {
            throw EmailStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Keyset (cursor-based) page. Returns the next `limit` emails whose
    /// (date, id) tuple is strictly less than the cursor. Pass `nil` for
    /// the first page. Pagination depth no longer causes O(n) scans — SQLite
    /// uses the date index to seek directly to the cursor position.
    ///
    /// The (date, id) compound cursor is essential: with `date` alone, any
    /// two emails sharing the same timestamp would be ordered
    /// non-deterministically across calls — which silently skips or
    /// duplicates rows at the page boundary. `id` is the SwiftData primary
    /// key, so the (date desc, id desc) ordering is total and stable.
    func pageKeyset(beforeDate: Date?, beforeID: UUID? = nil, limit: Int) throws -> [MBOXParser.RawEmail] {
        let container = try ensureContainer()
        let context = ModelContext(container)

        var descriptor: FetchDescriptor<StoredEmail>
        if let beforeDate, let beforeID {
            // Rows strictly older than the cursor: either earlier date,
            // or same date but smaller id.
            descriptor = FetchDescriptor<StoredEmail>(
                predicate: #Predicate {
                    $0.date < beforeDate || ($0.date == beforeDate && $0.id < beforeID)
                },
                sortBy: [
                    SortDescriptor(\.date, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        } else if let beforeDate {
            descriptor = FetchDescriptor<StoredEmail>(
                predicate: #Predicate { $0.date < beforeDate },
                sortBy: [
                    SortDescriptor(\.date, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor<StoredEmail>(
                sortBy: [
                    SortDescriptor(\.date, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = limit

        do {
            let stored = try context.fetch(descriptor)
            return stored.map { rawEmail(from: $0, includeBodies: false) }
        } catch {
            throw EmailStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Keyset paginated, restricted to one account. Same semantics as
    /// `pageKeyset(beforeDate:beforeID:limit:)` but adds an `accountID`
    /// predicate.
    func pageKeyset(accountID: String, beforeDate: Date?, beforeID: UUID? = nil, limit: Int) throws -> [MBOXParser.RawEmail] {
        let container = try ensureContainer()
        let context = ModelContext(container)

        var descriptor: FetchDescriptor<StoredEmail>
        if let beforeDate, let beforeID {
            descriptor = FetchDescriptor<StoredEmail>(
                predicate: #Predicate {
                    $0.accountID == accountID
                        && ($0.date < beforeDate || ($0.date == beforeDate && $0.id < beforeID))
                },
                sortBy: [
                    SortDescriptor(\.date, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        } else if let beforeDate {
            descriptor = FetchDescriptor<StoredEmail>(
                predicate: #Predicate {
                    $0.accountID == accountID && $0.date < beforeDate
                },
                sortBy: [
                    SortDescriptor(\.date, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor<StoredEmail>(
                predicate: #Predicate { $0.accountID == accountID },
                sortBy: [
                    SortDescriptor(\.date, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = limit

        do {
            let stored = try context.fetch(descriptor)
            return stored.map { rawEmail(from: $0, includeBodies: false) }
        } catch {
            throw EmailStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Page of emails restricted to the given account. Pass nil for
    /// `accountID` to fall back to the unfiltered `page(offset:limit:)`
    /// behaviour. Archive imports (no account context) and legacy rows
    /// have `accountID == nil` and are intentionally excluded when a
    /// specific account is requested.
    func page(accountID: String, offset: Int, limit: Int) throws -> [MBOXParser.RawEmail] {
        let container = try ensureContainer()
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<StoredEmail>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        do {
            let stored = try context.fetch(descriptor)
            return stored.map { rawEmail(from: $0, includeBodies: false) }
        } catch {
            throw EmailStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Fetch a single email with full bodies (called when user opens an email).
    func fullEmail(id: UUID) throws -> MBOXParser.RawEmail? {
        let container = try ensureContainer()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredEmail>(
            predicate: #Predicate { $0.id == id }
        )
        guard let stored = try context.fetch(descriptor).first else { return nil }
        return rawEmail(from: stored, includeBodies: true)
    }

    /// Total stored email count. Cheap aggregate query.
    func totalCount() throws -> Int {
        let container = try ensureContainer()
        let context = ModelContext(container)
        return try context.fetchCount(FetchDescriptor<StoredEmail>())
    }

    /// Remove all stored emails. Used by the "New Import" flow.
    func clearAll() throws {
        let container = try ensureContainer()
        let context = ModelContext(container)
        try context.delete(model: StoredEmail.self)
        try context.delete(model: StoredAttachment.self)
        try context.save()
    }

    // MARK: - Conversion

    private nonisolated func rawEmail(from stored: StoredEmail, includeBodies: Bool) -> MBOXParser.RawEmail {
        var headers: [String: String] = [:]
        if let data = stored.headersJSON,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            headers = decoded
        } else {
            headers["From"] = stored.fromAddress
            headers["To"] = stored.toAddresses
            headers["Subject"] = stored.subject
            if let mid = stored.messageID { headers["Message-ID"] = mid }
        }

        let plain: String
        let html: String
        let raw: String
        if includeBodies {
            plain = stored.plainBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            html = stored.htmlBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            raw = stored.rawSource.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } else {
            plain = stored.bodyPreview ?? ""
            html = ""
            raw = ""
        }

        return MBOXParser.RawEmail(
            id: stored.id,
            headers: headers,
            rawSource: raw,
            messageType: "stored",
            attachments: [],
            timestamp: ISO8601DateFormatter().string(from: stored.date),
            domains: extractDomains(from: headers),
            plainBody: plain,
            htmlBody: html,
            mimeRoot: nil,
            mimeSummary: nil,
            mimeDiagnostics: [],
            threadID: stored.messageID,
            inReplyTo: stored.inReplyToID,
            references: stored.referencesIDs.map { $0.components(separatedBy: "\n") },
            tags: stored.tags,
            anomalies: []
        )
    }

    private nonisolated func extractDomains(from headers: [String: String]) -> [String] {
        let fields = ["From", "To", "Cc", "Bcc"].compactMap { headers[$0] }
        var seen = Set<String>()
        for field in fields {
            for token in field.split(whereSeparator: { ",;<> ".contains($0) }) {
                if let at = token.firstIndex(of: "@") {
                    let domain = String(token[token.index(after: at)...]).lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: ">"))
                    if !domain.isEmpty { seen.insert(domain) }
                }
            }
        }
        return Array(seen)
    }

    // MARK: - Helpers

    private nonisolated func parsedDate(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: raw) { return d }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
