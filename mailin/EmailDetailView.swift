import SwiftUI
import CryptoKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct EmailDetailView: View {
    let email: MBOXParser.RawEmail
    var allEmails: [MBOXParser.RawEmail] = []
    var onNavigate: ((UUID) -> Void)? = nil
    var searchText: String = ""

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @AppStorage("showInlineImages") private var showInlineImages = true
    @State private var showCleanView = true
    @State private var safeHTML: String = ""
    @State private var showForensicHeaders = false
    @State private var annotationText: String = ""
    @State private var showSpoofIndicators = false

    @State private var htmlMinHeight: CGFloat = 600
    @State private var exportError: String?
    @AppStorage("autoAdvanceAfterTag") private var autoAdvanceAfterTag = true

    private var currentIndex: Int? {
        allEmails.firstIndex(where: { $0.id == email.id })
    }
    private var hasPrev: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }
    private var hasNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < allEmails.count - 1
    }

    private func advanceToNextUnreviewed() {
        guard let idx = currentIndex, let navigate = onNavigate else { return }
        for i in (idx + 1)..<allEmails.count {
            let tag = forensicManager.tagForEmail(allEmails[i].id)
            if tag == .none {
                navigate(allEmails[i].id)
                return
            }
        }
        if hasNext {
            navigate(allEmails[idx + 1].id)
        }
    }


    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    subjectView
                    if forensicManager.isEnabled || personaManager.selectedPersona == .legal {
                        evidenceTagBar
                    }
                    headerBlock
                    if forensicManager.isEnabled || personaManager.config.showTechnicalHeaders {
                        forensicHeaderSection
                    }
                    Divider()
                    cleanToggle
                    emailBodyView
                    htmlBodyView
                    attachmentsSection
                    exportButtons
                    Spacer(minLength: Spacing.medium)
                }
                .padding(Spacing.medium)
            }
        }
        .navigationTitle("Email Detail")
        .onAppear {
            safeHTML = sanitizedHTMLBody(from: email)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tagCurrentEmail)) { notification in
            if let tag = notification.object as? ForensicManager.EvidenceTag {
                forensicManager.tag(email.id, as: tag)
                if autoAdvanceAfterTag && tag != .none {
                    advanceToNextUnreviewed()
                }
            }
        }
        .animation(AnimationTiming.normal, value: showCleanView)
    }

    private var topBar: some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: "envelope.open.fill")
                .foregroundColor(AppColors.primary)
                .accessibilityHidden(true)
            Text("Email Detail")
                .font(Typography.subheadline)
                .foregroundColor(AppColors.secondary)

            if onNavigate != nil {
                HStack(spacing: Spacing.xxSmall) {
                    Button {
                        if let idx = currentIndex, idx > 0 {
                            onNavigate?(allEmails[idx - 1].id)
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasPrev)
                    .help("Previous email")
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    .accessibilityLabel("Previous email")

                    Button {
                        if let idx = currentIndex, idx < allEmails.count - 1 {
                            onNavigate?(allEmails[idx + 1].id)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasNext)
                    .help("Next email")
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .accessibilityLabel("Next email")

                    if let idx = currentIndex {
                        Text("\(idx + 1) of \(allEmails.count)")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                }
            }

            Spacer()

            Button {
                printEmail()
            } label: {
                Image(systemName: "printer")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("Print this email")
            .accessibilityLabel("Print email")
            .keyboardShortcut("p", modifiers: .command)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("Close this email")
            .accessibilityLabel("Close email detail")
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.xSmall)
    }

    private var subjectView: some View {
        Text(highlightedBody(subjectLine))
            .font(.system(size: 20, weight: .bold, design: .default))
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityAddTraits(.isHeader)
    }

    private var cleanToggle: some View {
        HStack(spacing: Spacing.small) {
            Toggle(isOn: $showCleanView) {
                Label("Clean Quote View", systemImage: "text.quote")
                    .font(Typography.callout)
            }
            .toggleStyle(SwitchToggleStyle())
            .help("Hide quoted reply text (lines starting with >) for easier reading")
            .accessibilityLabel("Clean quote view")
            .accessibilityHint("Hide quoted reply text for easier reading")

            if showCleanView {
                Text("Quoted text hidden")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(AppColors.primary.opacity(0.08))
                    .cornerRadius(CornerRadius.small)
            }
        }
        .padding(.bottom, Spacing.xSmall)
    }

    private var emailBodyView: some View {
        Group {
            Label("Plain Text", systemImage: "doc.text")
                .font(Typography.headline)
            ScrollView {
                Text(highlightedBody(emailBody))
                    .font(Typography.monoBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xSmall)
            }
            .frame(minHeight: 500, maxHeight: 800)
            .emailBoxStyle()
        }
    }
    @ViewBuilder
    private var htmlBodyView: some View {
        let trimmedHTML = email.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHTML.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Label("HTML View", systemImage: "globe")
                    .font(Typography.headline)
                    .padding(.leading, Spacing.medium)

                Picker("View Height", selection: $htmlMinHeight) {
                    Text("Small").tag(CGFloat(400))
                    Text("Medium").tag(CGFloat(600))
                    Text("Large").tag(CGFloat(1000))
                    Text("Extra Large").tag(CGFloat(2000))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .padding(.leading, Spacing.xSmall)
                .accessibilityLabel("HTML view height")

                EmailHTMLView(html: trimmedHTML, minHeight: htmlMinHeight)
                    .padding(Spacing.small)
                    .frame(maxWidth: .infinity, minHeight: htmlMinHeight)
                    .emailBoxStyle()
            }
            .padding(.top, Spacing.medium)
        }
    }

    // MARK: - Attachments Section
    private var attachmentsSection: some View {
        Group {
            if !email.attachments.isEmpty {
                Divider()
                Label("Attachments (\(email.attachments.count))", systemImage: "paperclip")
                    .font(Typography.headline)

                Button {
                    if storeManager.requirePremium() {
                        downloadAllAttachments()
                    }
                } label: {
                    Label(storeManager.isPremium ? "Download All Attachments" : "Download All (Pro)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.vertical, Spacing.xxSmall)
                .accessibilityLabel("Download all \(email.attachments.count) attachments")
                .accessibilityHint("Save all attachments to a folder")

                ForEach(Array(email.attachments.enumerated()), id: \.offset) { _, att in
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: attachmentIcon(for: att.mimeType))
                                .foregroundColor(attachmentIconColor(for: att.mimeType))
                            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                                Text(att.filename.isEmpty ? "Unnamed Attachment" : att.filename)
                                    .font(Typography.subheadline)
                                    .fontWeight(.medium)
                                Text("\(att.mimeType) · \(formatSize(att.size))")
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                            }
                            Spacer()
                            if let fileURL = att.fileURL {
                                Button {
                                    NSWorkspace.shared.open(fileURL)
                                } label: {
                                    Label("Quick Look", systemImage: "eye")
                                        .font(Typography.caption1)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(AppColors.primary)
                                .accessibilityLabel("Preview \(att.filename)")
                            }
                            Button {
                                if let fileURL = att.fileURL {
                                    saveAttachmentToUserFolder(fileURL: fileURL, suggestedName: att.filename)
                                }
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                                    .font(Typography.caption1)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(att.fileURL == nil)
                            .accessibilityLabel("Download \(att.filename.isEmpty ? "attachment" : att.filename)")
                        }

                        attachmentPreview(for: att)
                            .padding(.leading, Spacing.large)
                    }
                    .padding(.vertical, Spacing.xxSmall)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var exportButtons: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Divider()

            Menu {
                ForEach(personaManager.config.exportOrder, id: \.rawValue) { format in
                    exportButton(for: format)
                }
            } label: {
                Label(storeManager.isPremium ? "Export Email" : "Export Email (Pro)", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .accessibilityLabel("Export email")
            .accessibilityHint("Choose from text, CSV, PDF, forensic, or redacted export formats")
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "An unknown error occurred while saving the file.")
        }
    }

    @ViewBuilder
    private func exportButton(for format: PersonaManager.ExportFormat) -> some View {
        switch format {
        case .plainText:
            Button { if storeManager.requirePremium() { exportAsPlainText() } } label: {
                Label("Plain Text (.txt)", systemImage: "doc.text")
            }
        case .csv:
            Button { if storeManager.requirePremium() { exportAsCSV() } } label: {
                Label("Spreadsheet (.csv)", systemImage: "tablecells")
            }
        case .pdf:
            Button { if storeManager.requirePremium() { exportAsPDF() } } label: {
                Label("PDF Document", systemImage: "doc.richtext")
            }
        case .batesPDF:
            Button { if storeManager.requirePremium() { exportBatesStampedPDF() } } label: {
                Label("Bates-Stamped PDF", systemImage: "number.square")
            }
        case .forensicReport:
            Button { if storeManager.requirePremium() { exportForensicReport() } } label: {
                Label("Forensic Report", systemImage: "shield.checkered")
            }
        case .redacted:
            Button { if storeManager.requirePremium() { exportRedacted() } } label: {
                Label("Redacted (PII Removed)", systemImage: "eye.slash")
            }
        }
    }

    // MARK: - Evidence Tagging (Forensic Mode)
    private var evidenceTagBar: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "shield.checkered")
                .foregroundColor(.orange)
                .font(.system(size: 12))

            Text("Evidence:")
                .font(Typography.caption1)
                .fontWeight(.semibold)

            ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tag in
                Button {
                    forensicManager.tag(email.id, as: tag)
                    if autoAdvanceAfterTag && tag != .none {
                        advanceToNextUnreviewed()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tag.icon)
                            .font(.system(size: 10))
                        Text(tag.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(forensicManager.tagForEmail(email.id) == tag ? tag.color.opacity(0.2) : Color.clear)
                    .foregroundColor(forensicManager.tagForEmail(email.id) == tag ? tag.color : .secondary)
                    .cornerRadius(CornerRadius.small)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .stroke(forensicManager.tagForEmail(email.id) == tag ? tag.color.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tag as \(tag.rawValue)")
            }
            Spacer()
        }
        .padding(.vertical, Spacing.xxSmall)
    }

    // MARK: - Forensic Header Analysis
    private var forensicHeaderSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button {
                withAnimation { showForensicHeaders.toggle() }
            } label: {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: showForensicHeaders ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Image(systemName: "network")
                        .foregroundColor(.orange)
                    Text("Forensic Header Analysis")
                        .font(Typography.headline)
                    Spacer()
                    spoofBadge
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle forensic header analysis")

            if showForensicHeaders {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    spoofIndicatorsView
                    Divider()
                    authResultsView
                    Divider()
                    receivedChainView
                    Divider()
                    mimeTreeView
                    Divider()
                    hashVerificationView
                    Divider()
                    annotationView
                }
                .padding(Spacing.small)
                .background(.ultraThinMaterial)
                .cornerRadius(CornerRadius.medium)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var spoofBadge: some View {
        let indicators = ForensicManager.detectSpoofingIndicators(email)
        let highCount = indicators.filter { $0.severity == .high }.count
        if highCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("\(highCount) spoof risk")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(.red)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12))
            .cornerRadius(4)
        } else if !indicators.isEmpty {
            HStack(spacing: 2) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text("\(indicators.count) notice")
                    .font(.system(size: 9))
            }
            .foregroundColor(.orange)
        }
    }

    private var spoofIndicatorsView: some View {
        let indicators = ForensicManager.detectSpoofingIndicators(email)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Spoofing Analysis")
                .font(Typography.callout)
                .fontWeight(.semibold)

            if indicators.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("No spoofing indicators detected")
                        .font(Typography.caption1)
                        .foregroundColor(.green)
                }
            } else {
                ForEach(indicators) { indicator in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: indicator.severity == .high ? "exclamationmark.triangle.fill" : indicator.severity == .medium ? "exclamationmark.circle.fill" : "info.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(indicator.severity.color)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(indicator.severity.rawValue)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(indicator.severity.color)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(indicator.severity.color.opacity(0.12))
                                    .cornerRadius(3)
                                Text(indicator.type)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(indicator.detail)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var mimeTreeView: some View {
        let tree = ForensicManager.buildMIMETree(email)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("MIME Structure")
                .font(Typography.callout)
                .fontWeight(.semibold)

            ForEach(tree) { node in
                mimeNodeView(node, depth: 0)
            }
        }
    }

    private func mimeNodeView(_ node: ForensicManager.MIMETreeNode, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if depth > 0 {
                        ForEach(0..<depth, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.orange.opacity(0.3))
                                .frame(width: 1, height: 14)
                                .padding(.horizontal, 4)
                        }
                    }
                    Image(systemName: node.children.isEmpty ? "doc" : "folder")
                        .font(.system(size: 9))
                        .foregroundColor(node.children.isEmpty ? .secondary : .orange)
                    Text(node.contentType)
                        .font(.system(size: 10, design: .monospaced))
                    if let filename = node.filename {
                        Text("(\(filename))")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                    }
                    Text("\(node.size) bytes")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                ForEach(node.children) { child in
                    mimeNodeView(child, depth: depth + 1)
                }
            }
        )
    }

    private var annotationView: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Examiner Notes")
                .font(Typography.callout)
                .fontWeight(.semibold)

            if let existing = forensicManager.annotationFor(email.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing.text)
                        .font(Typography.caption1)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.06))
                        .cornerRadius(4)
                    Text("— \(existing.examiner), \(existing.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 4) {
                TextField("Add annotation...", text: $annotationText)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.caption1)
                Button("Save") {
                    guard !annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    forensicManager.annotate(email.id, text: annotationText)
                    annotationText = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            annotationText = forensicManager.annotationFor(email.id)?.text ?? ""
        }
    }

    private var authResultsView: some View {
        let auth = ForensicManager.extractAuthResults(email)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Authentication")
                .font(Typography.callout)
                .fontWeight(.semibold)

            HStack(spacing: Spacing.medium) {
                authBadge(label: "SPF", value: auth.spf)
                authBadge(label: "DKIM", value: auth.dkim)
                authBadge(label: "DMARC", value: auth.dmarc)
            }
        }
    }

    private func authBadge(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(value == "pass" ? .green : value == "fail" ? .red : .orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    (value == "pass" ? Color.green : value == "fail" ? Color.red : Color.orange).opacity(0.12)
                )
                .cornerRadius(3)
        }
    }

    private var receivedChainView: some View {
        let hops = ForensicManager.parseReceivedChain(email)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Received Chain (\(hops.count) hops)")
                .font(Typography.callout)
                .fontWeight(.semibold)

            if hops.isEmpty {
                Text("No Received headers found")
                    .font(Typography.caption1)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(hops.enumerated()), id: \.offset) { index, hop in
                    HStack(alignment: .top, spacing: Spacing.xSmall) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .frame(width: 18)
                            .foregroundColor(.orange)

                        VStack(alignment: .leading, spacing: 1) {
                            if !hop.from.isEmpty {
                                Text(hop.from)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            if !hop.by.isEmpty {
                                Text(hop.by)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            if let ip = hop.ip {
                                HStack(spacing: 2) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 9))
                                    Text(ip)
                                        .font(.system(size: 10, design: .monospaced))
                                }
                                .foregroundColor(.blue)
                            }
                            if !hop.date.isEmpty {
                                Text(hop.date)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    if index < hops.count - 1 {
                        Rectangle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 1, height: 8)
                            .padding(.leading, 9)
                    }
                }
            }
        }
    }

    private var hashVerificationView: some View {
        let rawData = email.rawSource.data(using: .utf8) ?? Data()
        let sha256 = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        let md5 = Insecure.MD5.hash(data: rawData).map { String(format: "%02x", $0) }.joined()

        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Message Integrity")
                .font(Typography.callout)
                .fontWeight(.semibold)

            Group {
                HStack(spacing: 4) {
                    Text("SHA-256:")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text(sha256)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sha256, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Copy SHA-256 hash")
                    .accessibilityLabel("Copy SHA-256 hash to clipboard")
                }
                HStack(spacing: 4) {
                    Text("MD5:")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text(md5)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md5, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Copy MD5 hash")
                    .accessibilityLabel("Copy MD5 hash to clipboard")
                }
                Text("Raw source: \(rawData.count) bytes")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var subjectLine: String {
        let decoded = decodeMIMEHeader(header("Subject"))
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(Untitled Email)" : decoded
    }

    private var emailBody: String {
        guard !email.plainBody.isEmpty else { return "(No Body Content Found)" }
        let cleaned = showCleanView ? cleanText(email.plainBody) : email.plainBody
        return cleaned.isEmpty ? email.plainBody : cleaned
    }

    private func highlightedBody(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        let lowered = text.lowercased()
        let queryLowered = query.lowercased()
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: queryLowered, range: searchStart..<lowered.endIndex) {
            let attrStart = AttributedString.Index(range.lowerBound, within: result)
            let attrEnd = AttributedString.Index(range.upperBound, within: result)
            if let attrStart, let attrEnd {
                result[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                result[attrStart..<attrEnd].foregroundColor = .primary
            }
            searchStart = range.upperBound
        }
        return result
    }

    private func cleanText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
    }

    private func attachmentIcon(for mimeType: String) -> String {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.contains("zip") || mime.contains("compressed") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.on.rectangle" }
        return "paperclip"
    }

    private func attachmentIconColor(for mimeType: String) -> Color {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") { return .blue }
        if mime == "application/pdf" { return .red }
        if mime.hasPrefix("text/") { return .green }
        if mime.hasPrefix("audio/") { return .purple }
        if mime.hasPrefix("video/") { return .orange }
        return AppColors.secondary
    }

    @ViewBuilder
    private func attachmentPreview(for att: AttachmentMetadata) -> some View {
        let mime = att.mimeType.lowercased()
        if mime.hasPrefix("image/"), let data = attachmentData(for: att), let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 400, maxHeight: 300)
                .cornerRadius(CornerRadius.medium)
                .accessibilityLabel("Preview of \(att.filename)")
        } else if mime.hasPrefix("text/") || att.filename.hasSuffix(".txt") || att.filename.hasSuffix(".csv") || att.filename.hasSuffix(".log"),
                  let data = attachmentData(for: att), let text = String(data: data, encoding: .utf8) {
            Text(String(text.prefix(2000)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.secondary)
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.small)
                .frame(maxHeight: 200)
                .accessibilityLabel("Text preview of \(att.filename)")
        }
    }

    private func attachmentData(for att: AttachmentMetadata) -> Data? {
        if let fileURL = att.fileURL {
            return try? Data(contentsOf: fileURL)
        }
        if let base64 = att.base64 {
            return Data(base64Encoded: base64)
        }
        return nil
    }

    private func formatSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.1f KB", kb)
    }

    private func header(_ key: String) -> String {
        let tryKeys = [key, key.lowercased(), key.capitalized]
        for k in tryKeys {
            if let val = email.headers[k], !val.isEmpty {
                return decodeMIMEHeader(val)
            }
        }
        return "(Not Available)"
    }

    private func sanitizedHTMLBody(from email: MBOXParser.RawEmail) -> String {
        let html = email.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !html.isEmpty else {
            return "<pre>\(email.plainBody.htmlEscaped())</pre>"
        }
        var safe = html.replacingOccurrences(of: "\u{0}", with: "")
        safe = safe.replacingOccurrences(of: #"<script[^>]*>[\s\S]*?</script>"#, with: "", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"<iframe[^>]*>[\s\S]*?</iframe>"#, with: "", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"<object[^>]*>[\s\S]*?</object>"#, with: "", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"<embed[^>]*/?>"#, with: "", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"\bon\w+\s*=\s*"[^"]*""#, with: "", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"\bon\w+\s*=\s*'[^']*'"#, with: "", options: .regularExpression)
        if !showInlineImages {
            safe = safe.replacingOccurrences(
                of: #"src="data:image/[^;]+;base64,[^"]+""#,
                with: #"src="""#,
                options: .regularExpression
            )
        }
        return safe
    }

    private var htmlAttributedString: NSAttributedString? {
        guard let data = safeHTML.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    // MARK: - Download Logic

    // Save one file
    private func saveAttachmentToUserFolder(fileURL: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { result in
            if result == .OK, let destinationURL = panel.url {
                do {
                    try FileUtils.copyFile(from: fileURL, to: destinationURL)
                } catch {
                    exportError = "Failed to save attachment: \(error.localizedDescription)"
                }
            }
        }
    }

    // Download all attachments
    private func downloadAllAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder to save all attachments"
        panel.prompt = "Save All"
        panel.begin { result in
            if result == .OK, let folderURL = panel.url {
                var usedNames = Set<String>()
                for att in email.attachments {
                    guard let fileURL = att.fileURL else { continue }
                    var filename = att.filename
                    var counter = 1
                    while usedNames.contains(filename) {
                        let name = (att.filename as NSString).deletingPathExtension
                        let ext = (att.filename as NSString).pathExtension
                        filename = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
                        counter += 1
                    }
                    usedNames.insert(filename)
                    let destURL = folderURL.appendingPathComponent(filename)
                    do {
                        try FileUtils.copyFile(from: fileURL, to: destURL)
                    } catch {
                        DispatchQueue.main.async {
                            exportError = "Failed to save \(att.filename): \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func exportAsPlainText() {
        let fileName = "\(subjectLine.replacingOccurrences(of: " ", with: "_")).txt"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true

        panel.begin { result in
            if result == .OK, let url = panel.url {
                var exportText = ""
                exportText += "Subject: \(subjectLine)\n"
                exportText += "From: \(header("From"))\n"
                exportText += "To: \(header("To"))\n"
                exportText += "Date: \(header("Date"))\n"
                exportText += "Reply-To: \(header("Reply-To"))\n"
                exportText += "CC: \(header("Cc"))\n"
                exportText += "BCC: \(header("Bcc"))\n"
                exportText += "Message-ID: \(header("Message-ID"))\n\n"
                exportText += emailBody

                do {
                    try FileUtils.writeString(exportText, to: url)
                } catch {
                    exportError = "Failed to export as TXT: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportAsCSV() {
        let fileName = "\(subjectLine.replacingOccurrences(of: " ", with: "_")).csv"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true

        panel.begin { result in
            if result == .OK, let url = panel.url {
                let csvHeaders = "Subject,From,To,Date,Body\n"
                func csvEscape(_ s: String) -> String {
                    let sanitized = s
                        .replacingOccurrences(of: "\"", with: "\"\"")
                        .replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    return "\"" + sanitized + "\""
                }
                let csvRow = [subjectLine, header("From"), header("To"), header("Date"), emailBody]
                    .map { csvEscape($0) }
                    .joined(separator: ",") + "\n"
                let csvContent = csvHeaders + csvRow

                do {
                    try FileUtils.writeString(csvContent, to: url)
                } catch {
                    exportError = "Failed to export CSV: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportAsPDF() {
        let headerText = """
        Subject: \(subjectLine)
        From: \(header("From"))
        To: \(header("To"))
        Date: \(header("Date"))
        \(hasHeader("Cc") ? "CC: \(header("Cc"))\n" : "")\(hasHeader("Bcc") ? "BCC: \(header("Bcc"))\n" : "")
        """

        let htmlContent: String
        let trimmedHTML = email.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHTML.isEmpty {
            htmlContent = """
            <html><body style="font-family: -apple-system, Helvetica, sans-serif; font-size: 13px;">
            <pre style="font-family: -apple-system, Helvetica, sans-serif; white-space: pre-wrap;">\(headerText.htmlEscaped())</pre>
            <hr>
            \(trimmedHTML)
            </body></html>
            """
        } else {
            htmlContent = """
            <html><body style="font-family: -apple-system, Helvetica, sans-serif; font-size: 13px;">
            <pre style="font-family: -apple-system, Helvetica, sans-serif; white-space: pre-wrap;">\(headerText.htmlEscaped())</pre>
            <hr>
            <pre style="font-family: Menlo, monospace; font-size: 12px; white-space: pre-wrap;">\(emailBody.htmlEscaped())</pre>
            </body></html>
            """
        }

        guard let data = htmlContent.data(using: .utf8),
              let attrString = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { return }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0,
            width: printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin,
            height: printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin))
        textView.textStorage?.setAttributedString(attrString)

        let panel = NSSavePanel()
        let safeName = subjectLine.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        panel.nameFieldStringValue = "\(safeName).pdf"
        panel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.pdf]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobDisposition] = NSPrintInfo.JobDisposition.save
        printInfo.dictionary()[NSPrintInfo.AttributeKey("NSJobSavingURL")] = url

        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = false
        printOp.showsProgressPanel = false
        printOp.run()
    }

    private func exportBatesStampedPDF() {
        let batesPrefix = forensicManager.isEnabled && !forensicManager.caseNumber.isEmpty
            ? forensicManager.caseNumber
            : "MAILIN"
        let batesNumber = ForensicManager.batesNumber(prefix: batesPrefix, index: 1)
        let examiner = forensicManager.isEnabled ? forensicManager.examinerName : ""
        let caseNum = forensicManager.isEnabled ? forensicManager.caseNumber : ""
        let tag = forensicManager.tagForEmail(email.id)
        let emailHash = forensicManager.perEmailHashes[email.id]

        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 54
        let headerHeight: CGFloat = 60
        let footerHeight: CGFloat = 40
        let contentWidth = pageWidth - margin * 2
        let contentTop = pageHeight - margin - headerHeight
        let contentBottom = margin + footerHeight

        var lines: [String] = []
        lines.append("Subject: \(subjectLine)")
        lines.append("From: \(header("From"))")
        lines.append("To: \(header("To"))")
        lines.append("Date: \(header("Date"))")
        if hasHeader("Cc") { lines.append("CC: \(header("Cc"))") }
        if hasHeader("Bcc") { lines.append("BCC: \(header("Bcc"))") }
        lines.append("Message-ID: \(header("Message-ID"))")
        if forensicManager.isEnabled {
            if tag != .none { lines.append("Evidence Tag: \(tag.rawValue)") }
            if let hash = emailHash { lines.append("SHA-256: \(hash.sha256)") }
        }
        lines.append("")
        lines.append(String(repeating: "─", count: 72))
        lines.append("")

        let bodyLines = emailBody.components(separatedBy: .newlines)
        lines.append(contentsOf: bodyLines)

        let bodyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let batesFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor]
        let batesAttrs: [NSAttributedString.Key: Any] = [.font: batesFont, .foregroundColor: NSColor.textColor]

        let lineHeight: CGFloat = 14
        let usableHeight = contentTop - contentBottom
        let linesPerPage = Int(usableHeight / lineHeight)

        var pages: [[String]] = []
        var currentPage: [String] = []
        for line in lines {
            let wrapped = wrapLine(line, maxWidth: contentWidth, font: bodyFont)
            for w in wrapped {
                currentPage.append(w)
                if currentPage.count >= linesPerPage {
                    pages.append(currentPage)
                    currentPage = []
                }
            }
        }
        if !currentPage.isEmpty { pages.append(currentPage) }
        if pages.isEmpty { pages.append([]) }

        let panel = NSSavePanel()
        let safeName = subjectLine.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        panel.nameFieldStringValue = "\(batesNumber)_\(safeName).pdf"
        panel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.pdf]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            exportError = "Failed to create PDF context"
            return
        }

        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)

        for (pageIndex, pageLines) in pages.enumerated() {
            context.beginPage(mediaBox: &mediaBox)

            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext

            // Header: case info left, Bates number right
            let headerY = pageHeight - margin - 12
            var headerLeft = "mailin Forensic Export"
            if !caseNum.isEmpty { headerLeft = "Case: \(caseNum)" }
            if !examiner.isEmpty { headerLeft += "  |  Examiner: \(examiner)" }
            (headerLeft as NSString).draw(at: NSPoint(x: margin, y: headerY), withAttributes: headerAttrs)

            let batesStr = "\(batesNumber) — Page \(pageIndex + 1) of \(pages.count)"
            let batesSize = (batesStr as NSString).size(withAttributes: batesAttrs)
            (batesStr as NSString).draw(at: NSPoint(x: pageWidth - margin - batesSize.width, y: headerY), withAttributes: batesAttrs)

            // Header divider
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: headerY - 4))
            context.addLine(to: CGPoint(x: pageWidth - margin, y: headerY - 4))
            context.strokePath()

            // Body content
            for (lineIdx, line) in pageLines.enumerated() {
                let y = contentTop - CGFloat(lineIdx) * lineHeight - lineHeight
                (line as NSString).draw(at: NSPoint(x: margin, y: y), withAttributes: bodyAttrs)
            }

            // Footer divider
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.move(to: CGPoint(x: margin, y: contentBottom + 8))
            context.addLine(to: CGPoint(x: pageWidth - margin, y: contentBottom + 8))
            context.strokePath()

            // Footer: date left, hash right
            let footerY = margin + 10
            (dateStr as NSString).draw(at: NSPoint(x: margin, y: footerY), withAttributes: headerAttrs)
            if let hash = emailHash {
                let hashStr = "MD5: \(hash.md5)"
                let hashSize = (hashStr as NSString).size(withAttributes: headerAttrs)
                (hashStr as NSString).draw(at: NSPoint(x: pageWidth - margin - hashSize.width, y: footerY), withAttributes: headerAttrs)
            }

            NSGraphicsContext.current = nil
            context.endPage()
        }

        context.closePDF()

        if forensicManager.isEnabled {
            forensicManager.logAction("Bates PDF Export", detail: "\(batesNumber) — \(pages.count) pages, subject: \(subjectLine)")
        }
    }

    private func wrapLine(_ line: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        if line.isEmpty { return [""] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (line as NSString).size(withAttributes: attrs)
        if size.width <= maxWidth { return [line] }

        var result: [String] = []
        var current = ""
        for char in line {
            let test = current + String(char)
            let testSize = (test as NSString).size(withAttributes: attrs)
            if testSize.width > maxWidth {
                result.append(current)
                current = String(char)
            } else {
                current = test
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func printEmail() {
        let headerText = """
        Subject: \(subjectLine)
        From: \(header("From"))
        To: \(header("To"))
        Date: \(header("Date"))
        """

        let htmlContent: String
        let trimmedHTML = email.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHTML.isEmpty {
            htmlContent = """
            <html><body style="font-family: -apple-system, Helvetica, sans-serif; font-size: 13px;">
            <pre style="font-family: -apple-system, Helvetica, sans-serif; white-space: pre-wrap;">\(headerText.htmlEscaped())</pre>
            <hr>
            \(trimmedHTML)
            </body></html>
            """
        } else {
            htmlContent = """
            <html><body style="font-family: -apple-system, Helvetica, sans-serif; font-size: 13px;">
            <pre style="font-family: -apple-system, Helvetica, sans-serif; white-space: pre-wrap;">\(headerText.htmlEscaped())</pre>
            <hr>
            <pre style="font-family: Menlo, monospace; font-size: 12px; white-space: pre-wrap;">\(emailBody.htmlEscaped())</pre>
            </body></html>
            """
        }

        guard let data = htmlContent.data(using: .utf8),
              let attrString = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { return }

        let printInfo = NSPrintInfo.shared
        let textView = NSTextView(frame: NSRect(x: 0, y: 0,
            width: printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin,
            height: printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin))
        textView.textStorage?.setAttributedString(attrString)

        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }

    // MARK: - Forensic Report Export
    private func exportForensicReport() {
        let rawData = email.rawSource.data(using: .utf8) ?? Data()
        let sha256 = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        let md5 = Insecure.MD5.hash(data: rawData).map { String(format: "%02x", $0) }.joined()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let exportDate = dateFormatter.string(from: Date())

        let batesNum = ForensicManager.batesNumber(prefix: "MAIL", index: (currentIndex ?? 0) + 1)
        let evidenceTag = forensicManager.tagForEmail(email.id)

        var report = "FORENSIC EMAIL REPORT\n"
        report += "Chain of Custody Document\n"
        report += String(repeating: "=", count: 70) + "\n\n"

        if forensicManager.isEnabled {
            report += "CASE INFORMATION\n"
            report += "Case Number: \(forensicManager.caseNumber.isEmpty ? "N/A" : forensicManager.caseNumber)\n"
            report += "Examiner: \(forensicManager.examinerName.isEmpty ? "N/A" : forensicManager.examinerName)\n"
            report += "Organization: \(forensicManager.organization.isEmpty ? "N/A" : forensicManager.organization)\n"
            report += "Bates Number: \(batesNum)\n"
            report += "Evidence Tag: \(evidenceTag.rawValue)\n\n"
        }

        report += "Export Date: \(exportDate)\n"
        report += "Export Tool: mailin (macOS)\n"
        report += "SHA-256: \(sha256)\n"
        report += "MD5: \(md5)\n"
        report += "Raw Source Size: \(rawData.count) bytes\n\n"

        let auth = ForensicManager.extractAuthResults(email)
        report += "AUTHENTICATION RESULTS\n"
        report += String(repeating: "-", count: 70) + "\n"
        report += "SPF: \(auth.spf)\n"
        report += "DKIM: \(auth.dkim)\n"
        report += "DMARC: \(auth.dmarc)\n"

        let hops = ForensicManager.parseReceivedChain(email)
        if !hops.isEmpty {
            report += "\nRECEIVED CHAIN (\(hops.count) hops)\n"
            report += String(repeating: "-", count: 70) + "\n"
            for (i, hop) in hops.enumerated() {
                report += "Hop \(i + 1):\n"
                if !hop.from.isEmpty { report += "  \(hop.from)\n" }
                if !hop.by.isEmpty { report += "  \(hop.by)\n" }
                if let ip = hop.ip { report += "  IP: \(ip)\n" }
                if !hop.date.isEmpty { report += "  Date: \(hop.date)\n" }
            }
        }

        report += "\nCOMPLETE HEADERS\n"
        report += String(repeating: "-", count: 70) + "\n"
        for (key, value) in email.headers.sorted(by: { $0.key < $1.key }) {
            report += "\(key): \(value)\n"
        }

        report += "\n\nMESSAGE METADATA\n"
        report += String(repeating: "-", count: 70) + "\n"
        report += "Message-ID: \(email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? "N/A")\n"
        report += "Thread-ID: \(email.threadID ?? "N/A")\n"
        report += "In-Reply-To: \(email.inReplyTo ?? "N/A")\n"
        report += "References: \(email.references?.joined(separator: " ") ?? "N/A")\n"
        report += "Message Type: \(email.messageType)\n"
        report += "Domains: \(email.domains.joined(separator: ", "))\n"
        report += "Tags: \(email.tags.joined(separator: ", "))\n"
        report += "Anomalies: \(email.anomalies.isEmpty ? "None" : email.anomalies.joined(separator: "; "))\n"

        if !email.attachments.isEmpty {
            report += "\n\nATTACHMENTS\n"
            report += String(repeating: "-", count: 70) + "\n"
            for (i, att) in email.attachments.enumerated() {
                report += "\(i + 1). \(att.filename) (\(att.mimeType), \(att.size) bytes)\n"
            }
        }

        report += "\n\nPLAIN TEXT BODY\n"
        report += String(repeating: "-", count: 70) + "\n"
        report += email.plainBody

        report += "\n\n" + String(repeating: "=", count: 70) + "\n"
        report += "END OF FORENSIC REPORT\n"
        report += "Document integrity verified at time of export.\n"
        report += "SHA-256: \(sha256)\n"

        let panel = NSSavePanel()
        let safeName = subjectLine.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        panel.nameFieldStringValue = "forensic_\(batesNum)_\(safeName).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            forensicManager.logAction("Forensic Export", detail: "Exported forensic report for \(batesNum): \(subjectLine)")
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Redacted Export (GDPR)
    private func exportRedacted() {
        var redactedText = "Subject: \(EmailNLPEngine.redactPII(in: subjectLine))\n"
        redactedText += "From: \(EmailNLPEngine.redactPII(in: header("From")))\n"
        redactedText += "To: \(EmailNLPEngine.redactPII(in: header("To")))\n"
        redactedText += "Date: \(header("Date"))\n\n"
        redactedText += EmailNLPEngine.redactPII(in: emailBody)

        let panel = NSSavePanel()
        let safeName = subjectLine.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        panel.nameFieldStringValue = "redacted_\(safeName).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try redactedText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var headerBlock: some View {
        ViewThatFits(in: .horizontal) {
            wideHeaderLayout
            narrowHeaderLayout
        }
        .padding(Spacing.medium)
        .background(.ultraThinMaterial)
        .cornerRadius(CornerRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.large)
                .stroke(AppColors.separatorLight, lineWidth: 0.5)
        )
    }

    private var wideHeaderLayout: some View {
        VStack(spacing: Spacing.small) {
            HStack(alignment: .top, spacing: Spacing.large) {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    LabelText(title: "From", value: header("From"))
                    LabelText(title: "To", value: header("To"))
                    if hasHeader("Reply-To") {
                        LabelText(title: "Reply-To", value: header("Reply-To"))
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    LabelText(title: "Date", value: header("Date"))
                    if hasHeader("Cc") {
                        LabelText(title: "CC", value: header("Cc"))
                    }
                    if hasHeader("Bcc") {
                        LabelText(title: "BCC", value: header("Bcc"))
                    }
                    if hasHeader("Message-ID") {
                        LabelText(title: "Message-ID", value: header("Message-ID"))
                    }
                }
            }
        }
        .frame(minWidth: 500)
    }

    private var narrowHeaderLayout: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            LabelText(title: "From", value: header("From"))
            LabelText(title: "To", value: header("To"))
            LabelText(title: "Date", value: header("Date"))
            if hasHeader("Reply-To") {
                LabelText(title: "Reply-To", value: header("Reply-To"))
            }
            if hasHeader("Cc") {
                LabelText(title: "CC", value: header("Cc"))
            }
            if hasHeader("Bcc") {
                LabelText(title: "BCC", value: header("Bcc"))
            }
            if hasHeader("Message-ID") {
                LabelText(title: "Message-ID", value: header("Message-ID"))
            }
        }
    }

    private func hasHeader(_ key: String) -> Bool {
        let tryKeys = [key, key.lowercased(), key.capitalized]
        for k in tryKeys {
            if let val = email.headers[k], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }
}

// MARK: - Reusable Label Component
struct LabelText: View {
    let title: String, value: String
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xxSmall) {
            Text("\(title):")
                .fontWeight(.semibold)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.footnote)
    }
}

// MARK: - View Modifier for Consistent Box Styling
extension View {
    func emailBoxStyle() -> some View {
        self
            .background(AppColors.backgroundTertiary)
            .cornerRadius(CornerRadius.medium)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .stroke(AppColors.separatorLight, lineWidth: 1)
            )
    }
}

// MARK: - HTML Escaping Extension
extension String {
    func htmlEscaped() -> String {
        return self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - MIME Header Decoding Extension (RFC 2047)
func decodeMIMEHeader(_ value: String) -> String {
    let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let nsValue = value as NSString
    let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
    var result = value
    for match in matches.reversed() {
        guard match.numberOfRanges == 4,
              let charsetRange = Range(match.range(at: 1), in: value),
              let encodingRange = Range(match.range(at: 2), in: value),
              let dataRange = Range(match.range(at: 3), in: value) else { continue }
        let charset = value[charsetRange].lowercased()
        let encoding = value[encodingRange].lowercased()
        let encodedText = String(value[dataRange])
        var decoded = encodedText
        if encoding == "b", let data = Data(base64Encoded: encodedText) {
            decoded = decodeWithCharset(data: data, charset: charset) ?? encodedText
        } else if encoding == "q" {
            decoded = QuotedPrintableDecoder.decode(encodedText, isHeader: true, charset: charset)
        }
        result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
    }
    return result
}

func decodeWithCharset(data: Data, charset: String) -> String? {
    let encoding: String.Encoding
    switch charset.lowercased() {
    case "utf-8", "utf8": encoding = .utf8
    case "iso-8859-1", "latin1", "latin-1": encoding = .isoLatin1
    case "iso-8859-2", "latin2", "latin-2": encoding = .isoLatin2
    case "us-ascii", "ascii": encoding = .ascii
    case "windows-1252", "cp1252": encoding = .windowsCP1252
    case "windows-1251", "cp1251":
        encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
    case "shift_jis", "shift-jis", "sjis": encoding = .shiftJIS
    case "euc-jp": encoding = .japaneseEUC
    case "iso-2022-jp": encoding = .iso2022JP
    default:
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cfEnc != kCFStringEncodingInvalidId {
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        } else {
            encoding = .utf8
        }
    }
    return String(data: data, encoding: encoding)
}
import AppKit

extension View {
    func openInWindow(title: String = "Email", storeManager: StoreManager? = nil) {
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let windowWidth = min(900, max(600, screenSize.width * 0.55))
        let windowHeight = min(700, max(450, screenSize.height * 0.7))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = true
        window.minSize = NSSize(width: 500, height: 400)
        if let storeManager {
            window.contentView = NSHostingView(rootView: self.environmentObject(storeManager))
        } else {
            window.contentView = NSHostingView(rootView: self)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
