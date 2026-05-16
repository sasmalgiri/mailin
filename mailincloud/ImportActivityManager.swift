import UserNotifications

// MARK: - Import Progress Notification System
// Uses UserNotifications to show import progress in Notification Center
// on both macOS and iOS (no ActivityKit widget extension required).

class ImportProgressNotifier {
    static let shared = ImportProgressNotifier()
    private let notificationID = "mailin-import-progress"

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func updateProgress(filename: String, current: Int, total: Int, bytesProcessed: Int64, totalBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Importing \(filename)"
        let pct = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
        content.body = "\(current) of \(total) emails (\(pct)%) — \(ContentViewModel.formatByteCount(bytesProcessed)) / \(ContentViewModel.formatByteCount(totalBytes))"
        content.sound = nil

        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func completeImport(filename: String, count: Int) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])

        let content = UNMutableNotificationContent()
        content.title = "Import Complete"
        content.body = "Successfully imported \(count) emails from \(filename)"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "\(notificationID)-done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelProgress() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }
}
