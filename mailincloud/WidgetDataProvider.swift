import Foundation

// MARK: - Widget Data Provider
// Provides data that a future WidgetKit extension can read from shared storage.
// Currently stores in UserDefaults; can be migrated to App Group when a widget target is added.

class WidgetDataProvider {
    static let shared = WidgetDataProvider()

    // Shared data stored in UserDefaults (or App Group if configured)
    private let defaults = UserDefaults.standard

    struct WidgetData: Codable {
        var totalEmails: Int = 0
        var lastImportDate: Date?
        var lastImportFilename: String?
        var topSenders: [String] = []
        var sentimentSummary: String = "No data"
        var recentSubjects: [String] = []
        var unreadHighPriority: Int = 0
    }

    func updateWidgetData(
        totalEmails: Int,
        importFilename: String?,
        emails: [MBOXParser.RawEmail]
    ) {
        var data = WidgetData()
        data.totalEmails = totalEmails
        data.lastImportDate = Date()
        data.lastImportFilename = importFilename

        // Top 5 senders by frequency
        var senderCounts: [String: Int] = [:]
        for email in emails {
            let from = email.headers["From"] ?? ""
            let sender = from.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? from
            if !sender.isEmpty {
                senderCounts[sender, default: 0] += 1
            }
        }
        data.topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)

        // Recent 5 subjects sorted by date descending
        data.recentSubjects = emails
            .sorted { (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) > (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast) }
            .prefix(5)
            .map { $0.headers["Subject"] ?? "(No Subject)" }

        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: "mailin_widget_data")
        }
    }

    func readWidgetData() -> WidgetData {
        guard let data = defaults.data(forKey: "mailin_widget_data"),
              let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else {
            return WidgetData()
        }
        return decoded
    }
}
