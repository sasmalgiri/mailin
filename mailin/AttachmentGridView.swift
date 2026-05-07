import SwiftUI
import ImageIO
import QuickLook
#if os(macOS)
import AppKit
import PDFKit
#else
import UIKit
import PDFKit
#endif

struct AttachmentGridView: View {
    let emails: [MBOXParser.RawEmail]
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var previewURL: URL?

    enum SortOrder: String, CaseIterable {
        case name = "Name", size = "Size", type = "Type", date = "Date"
    }

    private struct AttachmentItem: Identifiable {
        let id = UUID()
        let attachment: AttachmentMetadata
        let emailSubject: String
        let emailDate: String
    }

    private var allItems: [AttachmentItem] {
        emails.flatMap { email in
            email.attachments.map {
                AttachmentItem(attachment: $0, emailSubject: email.headers["Subject"] ?? "(No Subject)", emailDate: email.timestamp)
            }
        }
    }

    private var filteredItems: [AttachmentItem] {
        let base = searchText.isEmpty ? allItems : allItems.filter {
            let q = searchText.lowercased()
            return $0.attachment.filename.lowercased().contains(q) || $0.attachment.mimeType.lowercased().contains(q)
        }
        return base.sorted { a, b in
            switch sortOrder {
            case .name: return a.attachment.filename.localizedCaseInsensitiveCompare(b.attachment.filename) == .orderedAscending
            case .size: return a.attachment.size > b.attachment.size
            case .type: return a.attachment.mimeType < b.attachment.mimeType
            case .date: return a.emailDate > b.emailDate
            }
        }
    }

    private var totalSize: Int { filteredItems.reduce(0) { $0 + $1.attachment.size } }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if filteredItems.isEmpty {
                emptyState
            } else {
                gridContent
            }
        }
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
    }

    private var headerBar: some View {
        VStack(spacing: Spacing.xSmall) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.secondary)
                    .accessibilityHidden(true)
                TextField("Filter by filename or type", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search attachments")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(Spacing.xSmall)
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.medium)

            HStack {
                Text("\(filteredItems.count) attachments, \(formattedSize(totalSize)) total")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .accessibilityLabel("\(filteredItems.count) attachments, \(formattedSize(totalSize)) total size")
                Spacer()
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .accessibilityLabel("Sort attachments by")
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "paperclip",
            title: searchText.isEmpty ? "No Attachments" : "No Matching Attachments",
            message: searchText.isEmpty ? "Parsed emails contain no attachments." : "Try a different search term."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.small)],
                spacing: Spacing.small
            ) {
                ForEach(filteredItems) { item in
                    attachmentCell(item)
                }
            }
            .padding(Spacing.medium)
        }
    }

    private func attachmentCell(_ item: AttachmentItem) -> some View {
        Button {
            openPreview(for: item)
        } label: {
            VStack(spacing: Spacing.xxSmall) {
                thumbnailView(for: item.attachment)
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .clipped()

                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Text(item.attachment.filename)
                        .font(Typography.caption1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: Spacing.xxSmall) {
                        Text(formattedSize(item.attachment.size))
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                        Spacer()
                        Text(shortMimeLabel(item.attachment.mimeType))
                            .font(Typography.caption2)
                            .padding(.horizontal, Spacing.xxSmall)
                            .padding(.vertical, 1)
                            .background(AppColors.primary.opacity(0.12))
                            .cornerRadius(CornerRadius.small)
                    }

                    Text(item.emailSubject)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, Spacing.xSmall)
                .padding(.bottom, Spacing.xSmall)
            }
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.attachment.filename), \(formattedSize(item.attachment.size)), \(shortMimeLabel(item.attachment.mimeType))")
        .accessibilityHint("Double tap to open")
    }

    @ViewBuilder
    private func thumbnailView(for attachment: AttachmentMetadata) -> some View {
        if attachment.mimeType.hasPrefix("image/"), let image = imageFromBase64(attachment.base64) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .accessibilityLabel("Image preview of \(attachment.filename)")
        } else if attachment.mimeType == "application/pdf", let pdfImage = pdfThumbnail(attachment.base64) {
            pdfImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(Spacing.xSmall)
                .accessibilityLabel("PDF preview of \(attachment.filename)")
        } else {
            VStack(spacing: Spacing.xxSmall) {
                Image(systemName: systemIcon(for: attachment.filename))
                    .font(.title)
                    .foregroundColor(AppColors.primary)
                    .accessibilityHidden(true)
                Text(fileExtension(attachment.filename).uppercased())
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.backgroundSecondary.opacity(0.5))
            .accessibilityLabel("\(fileExtension(attachment.filename).uppercased()) file icon")
        }
    }

    private func imageFromBase64(_ base64: String?) -> Image? {
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 300,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Image(nsImage: nsImage)
        #else
        return Image(uiImage: UIImage(cgImage: cgImage))
        #endif
    }

    private func pdfThumbnail(_ base64: String?) -> Image? {
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return nil
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300.0 / max(bounds.width, bounds.height, 1)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        #if os(macOS)
        let nsImage = page.thumbnail(of: size, for: .mediaBox)
        return Image(nsImage: nsImage)
        #else
        let uiImage = page.thumbnail(of: size, for: .mediaBox)
        return Image(uiImage: uiImage)
        #endif
    }

    private func openPreview(for item: AttachmentItem) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin_preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent(item.attachment.filename)
        if let base64 = item.attachment.base64,
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            try? data.write(to: fileURL, options: .atomic)
        } else if let url = item.attachment.fileURL {
            try? FileManager.default.copyItem(at: url, to: fileURL)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(fileURL)
        #else
        previewURL = fileURL
        #endif
    }

    private func formattedSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if bytes < 1024 { return "\(bytes) B" }
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    private func shortMimeLabel(_ mime: String) -> String {
        mime.split(separator: "/").last.map { String($0).uppercased() } ?? mime.uppercased()
    }

    private func fileExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "FILE" : ext
    }

    private func systemIcon(for filename: String) -> String {
        switch fileExtension(filename).lowercased() {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.stack"
        case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
        case "txt", "rtf", "log": return "doc.plaintext"
        case "html", "htm": return "globe"
        case "mp3", "wav", "aac", "m4a": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "eml", "msg": return "envelope"
        default: return "doc"
        }
    }
}
