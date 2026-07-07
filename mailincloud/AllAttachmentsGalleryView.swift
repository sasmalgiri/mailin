import SwiftUI

struct AllAttachmentsGalleryView: View {
    let emails: [MBOXParser.RawEmail]
    @State private var filterType: AttachmentFilterType = .all
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .dateDesc
    @State private var selectedAttachment: AttachmentEntry?
    @Environment(\.dismiss) private var dismiss

    enum AttachmentFilterType: String, CaseIterable {
        case all = "All"
        case images = "Images"
        case documents = "Documents"
        case pdfs = "PDFs"
        case spreadsheets = "Spreadsheets"
        case archives = "Archives"
        case other = "Other"
    }

    enum SortOrder: String, CaseIterable {
        case dateDesc = "Newest First"
        case dateAsc = "Oldest First"
        case nameAsc = "Name A-Z"
        case sizeDesc = "Largest First"
    }

    struct AttachmentEntry: Identifiable, Hashable {
        let id: String
        let attachment: AttachmentMetadata
        let emailID: UUID
        let emailSubject: String
        let emailFrom: String
        let emailDate: String

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: AttachmentEntry, rhs: AttachmentEntry) -> Bool { lhs.id == rhs.id }
    }

    private var allAttachments: [AttachmentEntry] {
        emails.flatMap { email in
            email.attachments.enumerated().map { idx, att in
                AttachmentEntry(
                    id: "\(email.id.uuidString)-\(idx)",
                    attachment: att,
                    emailID: email.id,
                    emailSubject: email.headers["Subject"] ?? "(No Subject)",
                    emailFrom: email.headers["From"] ?? "",
                    emailDate: email.timestamp
                )
            }
        }
    }

    private var filteredAttachments: [AttachmentEntry] {
        var result = allAttachments

        if filterType != .all {
            result = result.filter { entry in
                let mime = entry.attachment.mimeType.lowercased()
                let name = entry.attachment.filename.lowercased()
                switch filterType {
                case .images: return mime.hasPrefix("image/")
                case .documents: return mime.contains("document") || mime.contains("msword") || name.hasSuffix(".doc") || name.hasSuffix(".docx") || name.hasSuffix(".rtf")
                case .pdfs: return mime.contains("pdf")
                case .spreadsheets: return mime.contains("spreadsheet") || mime.contains("excel") || name.hasSuffix(".csv") || name.hasSuffix(".xls") || name.hasSuffix(".xlsx")
                case .archives: return mime.contains("zip") || mime.contains("compressed") || name.hasSuffix(".zip") || name.hasSuffix(".gz") || name.hasSuffix(".tar")
                case .other: return !mime.hasPrefix("image/") && !mime.contains("pdf") && !mime.contains("document") && !mime.contains("spreadsheet") && !mime.contains("zip")
                case .all: return true
                }
            }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.attachment.filename.lowercased().contains(query) ||
                $0.emailSubject.lowercased().contains(query) ||
                $0.emailFrom.lowercased().contains(query)
            }
        }

        switch sortOrder {
        case .dateDesc: result.sort { $0.emailDate > $1.emailDate }
        case .dateAsc: result.sort { $0.emailDate < $1.emailDate }
        case .nameAsc: result.sort { $0.attachment.filename.localizedCaseInsensitiveCompare($1.attachment.filename) == .orderedAscending }
        case .sizeDesc: result.sort { $0.attachment.size > $1.attachment.size }
        }

        return result
    }

    private var typeCounts: [AttachmentFilterType: Int] {
        var counts: [AttachmentFilterType: Int] = [.all: allAttachments.count]
        for entry in allAttachments {
            let mime = entry.attachment.mimeType.lowercased()
            let name = entry.attachment.filename.lowercased()
            if mime.hasPrefix("image/") { counts[.images, default: 0] += 1 }
            else if mime.contains("pdf") { counts[.pdfs, default: 0] += 1 }
            else if mime.contains("document") || mime.contains("msword") || name.hasSuffix(".doc") || name.hasSuffix(".docx") { counts[.documents, default: 0] += 1 }
            else if mime.contains("spreadsheet") || mime.contains("excel") || name.hasSuffix(".csv") || name.hasSuffix(".xls") { counts[.spreadsheets, default: 0] += 1 }
            else if mime.contains("zip") || mime.contains("compressed") { counts[.archives, default: 0] += 1 }
            else { counts[.other, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if filteredAttachments.isEmpty {
                emptyState
            } else {
                attachmentGrid
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("All Attachments")
                    .font(.headline)
                Text("\(allAttachments.count) files across \(emails.filter { !$0.attachments.isEmpty }.count) emails")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            #if os(macOS)
            TextField("Search files...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            #endif
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue) }
            }
            .frame(maxWidth: 160)
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
        }
        .padding()
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AttachmentFilterType.allCases, id: \.self) { type in
                    let count = typeCounts[type] ?? 0
                    Button {
                        filterType = type
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconFor(type))
                            Text("\(type.rawValue) (\(count))")
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(filterType == type ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && type != .all)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "paperclip.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No attachments found")
                .font(.headline)
            if !searchText.isEmpty {
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var attachmentGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(filteredAttachments) { entry in
                    attachmentCard(entry)
                }
            }
            .padding()
        }
    }

    private func attachmentCard(_ entry: AttachmentEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconForMIME(entry.attachment.mimeType))
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Spacer()
                if entry.attachment.size > 0 {
                    Text(formatSize(entry.attachment.size))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text(entry.attachment.filename)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(entry.emailSubject)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(entry.emailFrom)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.attachment.filename), from \(entry.emailSubject)")
    }

    private func iconFor(_ type: AttachmentFilterType) -> String {
        switch type {
        case .all: return "tray.full"
        case .images: return "photo"
        case .documents: return "doc.text"
        case .pdfs: return "doc.richtext"
        case .spreadsheets: return "tablecells"
        case .archives: return "archivebox"
        case .other: return "doc"
        }
    }

    private func iconForMIME(_ mime: String) -> String {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.contains("spreadsheet") || m.contains("excel") { return "tablecells" }
        if m.contains("zip") || m.contains("compressed") { return "archivebox" }
        if m.contains("audio") { return "waveform" }
        if m.contains("video") { return "film" }
        return "doc"
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
