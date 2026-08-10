import SwiftUI

/// Stage 5 W2-D: a lightweight duplicate-finding record. Duplicate review holds
/// these projections (subject/from/date/preview) rather than full `[RawEmail]`,
/// so the removed set never retains bodies/raw source.
struct DuplicateFinding: Identifiable, Sendable, Equatable {
    let id: UUID
    let subject: String
    let from: String
    let dateString: String
    let messageID: String?
    let preview: String
    let reason: String

    init(from email: MBOXParser.RawEmail, reason: String = "duplicate") {
        self.id = email.id
        self.subject = email.headers["Subject"] ?? "(No Subject)"
        self.from = email.headers["From"] ?? "Unknown"
        self.dateString = email.headers["Date"] ?? ""
        self.messageID = email.headers["Message-ID"] ?? email.headers["Message-Id"]
        self.preview = String(email.plainBody.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        self.reason = reason
    }
}

struct RemovedDuplicatesView: View {
    let findings: [DuplicateFinding]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedEmailID: UUID?

    private var filteredFindings: [DuplicateFinding] {
        guard !searchText.isEmpty else { return findings }
        let query = searchText.lowercased()
        return findings.filter {
            $0.subject.lowercased().contains(query) || $0.from.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if findings.isEmpty {
                emptyView
            } else {
                searchBar
                emailList
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 750, minHeight: 360, idealHeight: 600)
        #endif
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(AppColors.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("Removed Duplicates")
                    .font(Typography.headline)
                Text("\(findings.count) emails were removed during deduplication")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.medium)
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundColor(AppColors.success)
            Text("No duplicates were removed")
                .font(Typography.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColors.secondary)
            TextField("Search removed duplicates...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(filteredFindings.count) of \(findings.count)")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(Color.gray.opacity(0.05))
    }

    private var emailList: some View {
        List(filteredFindings, selection: $selectedEmailID) { finding in
            emailRow(finding)
        }
        .listStyle(.plain)
    }

    private func emailRow(_ finding: DuplicateFinding) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
            HStack {
                Text(finding.subject)
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if !finding.dateString.isEmpty {
                    Text(formatDate(finding.dateString))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
            HStack(spacing: Spacing.small) {
                Text(finding.from)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
                if let msgID = finding.messageID {
                    Text(msgID)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            if !finding.preview.isEmpty {
                Text(finding.preview)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    private func formatDate(_ dateStr: String) -> String {
        if let date = MBOXParser.parseDate(dateStr) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return dateStr
    }
}
