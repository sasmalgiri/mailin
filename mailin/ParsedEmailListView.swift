import SwiftUI

struct ParsedEmailListView: View {
    @ObservedObject var model: ParsedEmailListViewModel
 
    private enum ActiveSheet: Identifiable {
        case stats
        case rawSource(String)

        var id: UUID? { nil }
    }

   


    @State private var activeSheet: ActiveSheet?
    @State private var hoveringEmailID: UUID? = nil  // <-- for hover effect
   

    // MARK: - UI
    var body: some View {
        VStack(spacing: 12) {
            headerView
            Divider()
            contentView
            Spacer(minLength: 0)

            // --- Bottom row of actions: Download/Export/AI ---
            if totalAttachments > 0 || !model.filteredEmails.isEmpty {
                HStack(spacing: 16) {
                    if totalAttachments > 0 {
                        Button {
                            downloadAllAttachments()
                        } label: {
                            Label("⬇️ Download All Attachments", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Download all attachments from filtered emails")
                    }

                    if !model.filteredEmails.isEmpty {
                        Button {
                            exportFilteredJSON()
                        } label: {
                            Label("Export JSON", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .help("Export the currently filtered emails as JSON")
                    }

                    // --- AI BUTTON ---
                    AIWindowButton(model: model)

                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.isParsed) { _, newValue in
            if newValue { model.applyFilters() }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .stats:
                ReplyStatsView(replyData: model.replyFrequency(for: model.viewModel.senderEmail))
                    .frame(minWidth: 500, minHeight: 400)
            case .rawSource(let rfc822):
                RawSourceView(rawText: rfc822)
                    .frame(minWidth: 800, minHeight: 600)
            }
        }

        // --- AI Window Sheet ---
        
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .stats
                } label: {
                    Label("Reply Stats", systemImage: "chart.bar")
                }
            }
        }
    }


    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 16) {
            Text("📨 Parsed Emails")
                .font(.title2)
                .bold()
            Spacer()
            Picker("Sort by", selection: $model.sortBy) {
                ForEach(ParsedEmailListViewModel.SortOption.allCases, id: \.self) {
                    Text($0.label)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: model.sortBy) { _, _ in
                model.applyFilters()
            }
        }
    }

    // MARK: - Main List
    @ViewBuilder
    private var contentView: some View {
        if model.filteredEmails.isEmpty {
            VStack {
                Spacer()
                Text("😕 No matching emails found.")
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            }
        } else {
            List(model.filteredEmails, id: \.id) { email in
                HStack(spacing: 6) {
                    Button {
                        EmailDetailView(email: email)
                            .openInWindow(title: decodeMIMEHeader(email.headers["Subject"] ?? "Email"))
                    } label: {
                        EmailRowView(email: email)
                    }

                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill((hoveringEmailID == email.id) ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .onHover { isHovering in
                        hoveringEmailID = isHovering ? email.id : nil
                    }

                    Spacer(minLength: 8)

                    // RAW RFC822 BUTTON
                    Button {
                        let rawData = email.rawSource.data(using: .utf8) ?? Data()
                        let kit = SwiftEmailMessage(rawSource: rawData)
                        let kitString = kit.asRFC822String()
                        let fallback = email.rawSource
                        let rawRFC822 = !kitString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kitString : fallback
                        activeSheet = .rawSource(rawRFC822)
                    } label: {
                        Image(systemName: "doc.plaintext")
                            .foregroundColor(.secondary)
                    }
                    .help("Show Raw RFC822 Source")

                    // Attachments popover icon
                    if !email.attachments.isEmpty {
                        AttachmentsPopoverButton(attachments: email.attachments)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Download All Attachments
    private var totalAttachments: Int {
        model.filteredEmails.map { $0.attachments.count }.reduce(0, +)
    }
    private func downloadAllAttachments() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save All"

            if panel.runModal() == .OK, let folderURL = panel.url {
                for email in model.filteredEmails {
                    for att in email.attachments {
                        guard let sourceURL = att.fileURL else { continue }
                        let destinationURL = folderURL.appendingPathComponent(att.filename)
                        do {
                            try FileUtils.copyFile(from: sourceURL, to: destinationURL)
                        } catch {
                            print("❌ Failed to copy \(att.filename): \(error)")
                        }
                    }
                }
            }
        }

    // MARK: - Export Filtered Emails as JSON
    private func exportFilteredJSON() {
            let exportable = MBOXParser.ExportableParsedMBOXFile(
                emails: model.filteredEmails.map { $0.asExportable() },
                summary: MBOXParser.summarize(emails: model.filteredEmails)
            )

            do {
                let data = try JSONEncoder().encode(exportable)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let suggestedName = "filtered_emails_\(formatter.string(from: Date())).json"

                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggestedName
                panel.canCreateDirectories = true
                if #available(macOS 12.0, *) {
                    panel.allowedContentTypes = [.json]
                } else {
                    panel.allowedFileTypes = ["json"]
                }



                if panel.runModal() == .OK, let url = panel.url {
                    try FileUtils.writeData(data, to: url.path)
                    print("✅ Exported to \(url.path)")
                }
            } catch {
                print("❌ Failed to export JSON: \(error)")
            }
        }
    }
// MARK: - Email Row
struct EmailRowView: View {
    let email: MBOXParser.RawEmail

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Subject line
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: 14) {
                Label(email.headers["From"] ?? "-", systemImage: "arrow.up.forward")
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
                Label(email.headers["To"] ?? "-", systemImage: "arrow.down.backward")
                    .font(.subheadline.bold())
                    .foregroundColor(.green)
                Spacer()
                if !email.attachments.isEmpty {
                    Label("\(email.attachments.count) attachment(s)", systemImage: "paperclip")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            Text(parseDate(email.headers["Date"]))
                .font(.footnote)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 7)
    }

    private func parseDate(_ raw: String?) -> String {
        guard let raw = raw else { return "Unknown Date" }
        if let date = MBOXParser.parseDate(raw) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }
        return raw
    }
}

// MARK: - Attachments Popover (filename preview on hover)
struct AttachmentsPopoverButton: View {
    let attachments: [AttachmentMetadata]
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "paperclip")
                .foregroundColor(.secondary)
        }
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attachments:").bold()
                ForEach(attachments, id: \.filename) { att in
                    Text(att.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .frame(width: 220)
        }
        .help("\(attachments.count) attachment(s)")
    }
}

// MARK: - Raw Source View (unchanged)
struct RawSourceView: View {
    let rawText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("📄 Raw RFC822 Source")
                    .font(.title2)
                    .bold()
                Spacer()
                Button(action: { dismiss() }) {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundColor(.gray)
                }
                .help("Close")
            }
            .padding()

            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(rawText)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Reply Stats View (unchanged)
struct ReplyStatsView: View {
    let replyData: [String: Int]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("📊 Reply Frequency")
                    .font(.title2)
                    .bold()
                Spacer()
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundColor(.gray)
                }
                .help("Close this stats view")
            }

            Divider()
            if replyData.isEmpty {
                Text("No reply data found.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(replyData.sorted { $0.value > $1.value }, id: \.key) { email, count in
                            HStack {
                                Text(email)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 220, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(
                                            width: min(CGFloat(count) * 10, geo.size.width),
                                            height: 10
                                        )
                                        .cornerRadius(2)
                                }
                                .frame(height: 10)
                                Text("\(count)")
                                    .font(.caption)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .padding()
    }
}
