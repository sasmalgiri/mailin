import SwiftUI

struct ParsedEmailListView: View {
    @ObservedObject var model: ParsedEmailListViewModel
    @EnvironmentObject var storeManager: StoreManager
 
    private enum ActiveSheet: Identifiable {
        case stats
        case rawSource(String)

        var id: String {
            switch self {
            case .stats: return "stats"
            case .rawSource: return "rawSource"
            }
        }
    }

   


    @State private var activeSheet: ActiveSheet?
    @State private var hoveringEmailID: UUID? = nil  // <-- for hover effect
   

    // MARK: - UI
    var body: some View {
        VStack(spacing: Spacing.small) {
            headerView
            Divider()
            contentView
            Spacer(minLength: 0)

            if totalAttachments > 0 || !model.filteredEmails.isEmpty {
                HStack(spacing: Spacing.medium) {
                    if totalAttachments > 0 {
                        Button {
                            if storeManager.requirePremium() {
                                downloadAllAttachments()
                            }
                        } label: {
                            Label(storeManager.isPremium ? "Download All" : "Download All (Pro)", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Download all attachments from filtered emails")
                    }

                    if !model.filteredEmails.isEmpty {
                        Button {
                            if storeManager.requirePremium() {
                                exportFilteredJSON()
                            }
                        } label: {
                            Label(storeManager.isPremium ? "Export JSON" : "Export JSON (Pro)", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Export the currently filtered emails as JSON")
                    }

                    AIWindowButton(model: model)
                        .environmentObject(storeManager)
                }
                .padding(.vertical, Spacing.small)
                .padding(.horizontal, Spacing.xSmall)
            }
        }
        .padding()
        .background(AppColors.backgroundPrimary)
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
        
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if storeManager.requirePremium() {
                        activeSheet = .stats
                    }
                } label: {
                    Label("Reply Stats", systemImage: "chart.bar")
                }
            }
        }
    }


    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: Spacing.medium) {
            Label("Parsed Emails", systemImage: "envelope.open.fill")
                .font(Typography.title2)
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
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No matching emails",
                message: "Try adjusting your filters to see more results."
            )
        } else {
            List(model.filteredEmails, id: \.id) { email in
                HStack(spacing: Spacing.xSmall) {
                    Button {
                        EmailDetailView(email: email)
                            .openInWindow(title: decodeMIMEHeader(email.headers["Subject"] ?? "Email"), storeManager: storeManager)
                    } label: {
                        EmailRowView(email: email)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .fill((hoveringEmailID == email.id) ? AppColors.primary.opacity(0.08) : Color.clear)
                    )
                    .onHover { isHovering in
                        withAnimation(AnimationTiming.fast) {
                            hoveringEmailID = isHovering ? email.id : nil
                        }
                    }

                    Spacer(minLength: Spacing.xSmall)

                    Button {
                        let rawData = email.rawSource.data(using: .utf8) ?? Data()
                        let kit = SwiftEmailMessage(rawSource: rawData)
                        let kitString = kit.asRFC822String()
                        let fallback = email.rawSource
                        let rawRFC822 = !kitString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kitString : fallback
                        activeSheet = .rawSource(rawRFC822)
                    } label: {
                        Image(systemName: "doc.plaintext")
                            .foregroundColor(AppColors.secondary)
                    }
                    .help("Show Raw RFC822 Source")

                    if !email.attachments.isEmpty {
                        AttachmentsPopoverButton(attachments: email.attachments)
                    }
                }
                .padding(.vertical, Spacing.xxxSmall)
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
                            print("Failed to copy \(att.filename): \(error)")
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
                    print("Exported to \(url.path)")
                }
            } catch {
                print("Failed to export JSON: \(error)")
            }
        }
    }
// MARK: - Email Row
struct EmailRowView: View {
    let email: MBOXParser.RawEmail

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(Typography.headline)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: Spacing.small) {
                Label(email.headers["From"] ?? "-", systemImage: "arrow.up.forward")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(AppColors.sentEmail)
                    .lineLimit(1)
                Label(email.headers["To"] ?? "-", systemImage: "arrow.down.backward")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(AppColors.receivedEmail)
                    .lineLimit(1)
                Spacer()
                if !email.attachments.isEmpty {
                    Label("\(email.attachments.count)", systemImage: "paperclip")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }

            Text(parseDate(email.headers["Date"]))
                .font(Typography.footnote)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.vertical, Spacing.xSmall)
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

// MARK: - Attachments Popover
struct AttachmentsPopoverButton: View {
    let attachments: [AttachmentMetadata]
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "paperclip")
                .foregroundColor(AppColors.secondary)
        }
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text("Attachments")
                    .font(Typography.headline)
                ForEach(attachments, id: \.filename) { att in
                    Text(att.filename)
                        .font(Typography.caption1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(Spacing.small)
            .frame(width: 220)
        }
        .help("\(attachments.count) attachment(s)")
    }
}

// MARK: - Raw Source View
struct RawSourceView: View {
    let rawText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Raw RFC822 Source", systemImage: "doc.plaintext")
                    .font(Typography.title2)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(Spacing.medium)

            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(rawText)
                    .font(Typography.monoBody)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(AppColors.backgroundTertiary)
    }
}

// MARK: - Reply Stats View
struct ReplyStatsView: View {
    let replyData: [String: Int]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Label("Reply Frequency", systemImage: "chart.bar.fill")
                    .font(Typography.title2)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close this stats view")
            }

            Divider()
            if replyData.isEmpty {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "No reply data",
                    message: "Reply frequency data will appear after parsing emails."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        ForEach(replyData.sorted { $0.value > $1.value }, id: \.key) { email, count in
                            HStack {
                                Text(email)
                                    .font(Typography.monoSmall)
                                    .frame(width: 220, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: CornerRadius.small)
                                        .fill(
                                            LinearGradient(
                                                colors: [AppColors.primary, AppColors.primary.opacity(0.6)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(
                                            width: min(CGFloat(count) * 10, geo.size.width),
                                            height: 10
                                        )
                                }
                                .frame(height: 10)
                                Text("\(count)")
                                    .font(Typography.caption1)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.small)
                }
            }
        }
        .padding(Spacing.medium)
    }
}
