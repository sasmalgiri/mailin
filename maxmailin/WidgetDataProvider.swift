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

    /// Stage 5 W2-B: the widget receives only bounded, already-derived data
    /// (aggregate top senders + a few recent subjects) — never the corpus.
    func updateWidgetData(
        totalEmails: Int,
        importFilename: String?,
        topSenders: [String],
        recentSubjects: [String]
    ) {
        var data = WidgetData()
        data.totalEmails = totalEmails
        data.lastImportDate = Date()
        data.lastImportFilename = importFilename
        data.topSenders = Array(topSenders.prefix(5))
        data.recentSubjects = Array(recentSubjects.prefix(5))
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
