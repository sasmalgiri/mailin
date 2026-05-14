import SwiftUI

struct RemovedDuplicatesView: View {
    let emails: [MBOXParser.RawEmail]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedEmailID: UUID?

    private var filteredEmails: [MBOXParser.RawEmail] {
        guard !searchText.isEmpty else { return emails }
        let query = searchText.lowercased()
        return emails.filter {
            ($0.headers["Subject"] ?? "").lowercased().contains(query) ||
            ($0.headers["From"] ?? "").lowercased().contains(query) ||
            ($0.headers["To"] ?? "").lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if emails.isEmpty {
                emptyView
            } else {
                searchBar
                emailList
            }
        }
        #if os(macOS)
        .frame(minWidth: 650, idealWidth: 750, minHeight: 500, idealHeight: 600)
        #endif
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(AppColors.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("Removed Duplicates")
                    .font(Typography.headline)
                Text("\(emails.count) emails were removed during deduplication")
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
            Text("\(filteredEmails.count) of \(emails.count)")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(Color.gray.opacity(0.05))
    }

    private var emailList: some View {
        List(filteredEmails, selection: $selectedEmailID) { email in
            emailRow(email)
        }
        .listStyle(.plain)
    }

    private func emailRow(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
            HStack {
                Text(email.headers["Subject"] ?? "(No Subject)")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if let date = email.headers["Date"] {
                    Text(formatDate(date))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
            HStack(spacing: Spacing.small) {
                Text(email.headers["From"] ?? "Unknown")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
                if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"] {
                    Text(msgID)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            if !email.plainBody.isEmpty {
                Text(String(email.plainBody.prefix(120)).replacingOccurrences(of: "\n", with: " "))
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
