import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct EmailDetailView: View {
    let email: MBOXParser.RawEmail

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var storeManager: StoreManager
    @State private var showCleanView = true
    @State private var safeHTML: String = ""

    @State private var htmlMinHeightString: String = "600"
    @State private var htmlMinHeight: CGFloat = 600


    
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    subjectView
                    headerBlock
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
        .animation(AnimationTiming.normal, value: showCleanView)
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .padding(.trailing, Spacing.medium)
            .help("Close this email")
        }
        .padding(.top, Spacing.xSmall)
    }

    private var subjectView: some View {
        Text(subjectLine)
            .font(Typography.title2)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var cleanToggle: some View {
        Toggle(isOn: $showCleanView) {
            Label("Clean Quote View", systemImage: "text.quote")
                .font(Typography.callout)
        }
        .toggleStyle(SwitchToggleStyle())
        .padding(.bottom, Spacing.xSmall)
    }

    private var emailBodyView: some View {
        Group {
            Label("Plain Text", systemImage: "doc.text")
                .font(Typography.headline)
            ScrollView {
                Text(emailBody)
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

                HStack(spacing: Spacing.xSmall) {
                    Text("View Height:")
                        .font(Typography.callout)
                    TextField("Height", text: $htmlMinHeightString)
                        .frame(width: 60)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .multilineTextAlignment(.trailing)
                        .onChange(of: htmlMinHeightString) { oldValue, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if let val = Int(filtered), val >= 100, val <= 14000 {
                                htmlMinHeight = CGFloat(val)
                                htmlMinHeightString = "\(val)"
                            } else if let val = Int(filtered), val < 100 {
                                htmlMinHeight = 100
                                htmlMinHeightString = "100"
                            } else if let val = Int(filtered), val > 14000 {
                                htmlMinHeight = 14000
                                htmlMinHeightString = "14000"
                            }
                        }
                    Text("px")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(.leading, Spacing.xSmall)

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

                ForEach(email.attachments, id: \.filename) { att in
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "paperclip")
                            .foregroundColor(AppColors.secondary)
                        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                            Text(att.filename.isEmpty ? "Unnamed Attachment" : att.filename)
                                .font(Typography.subheadline)
                                .fontWeight(.medium)
                            Text("\(att.mimeType) · \(formatSize(att.size))")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                        Spacer()
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
                    }
                    .padding(.vertical, Spacing.xxxSmall)
                }
            }
        }
    }

    private var exportButtons: some View {
        HStack(spacing: Spacing.medium) {
            Button {
                if storeManager.requirePremium() {
                    exportAsPlainText()
                }
            } label: {
                Label(storeManager.isPremium ? "Export as TXT" : "Export TXT (Pro)", systemImage: "doc.text")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                if storeManager.requirePremium() {
                    exportAsCSV()
                }
            } label: {
                Label(storeManager.isPremium ? "Export as CSV" : "Export CSV (Pro)", systemImage: "tablecells")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
    }

    private var subjectLine: String {
        let raw = header("Subject")
        return decodeMIMEHeader(raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(Untitled Email)" : decodeMIMEHeader(raw)
    }

    private var emailBody: String {
        guard !email.plainBody.isEmpty else { return "(No Body Content Found)" }
        let cleaned = showCleanView ? cleanText(email.plainBody) : email.plainBody
        return cleaned.isEmpty ? email.plainBody : cleaned
    }

    private func cleanText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
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
        safe = safe.replacingOccurrences(
            of: #"src="data:image/[^;]+;base64,[^"]+""#,
            with: #"src="""#,
            options: .regularExpression
        )
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
                    print("Error copying file: \(error.localizedDescription)")
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
                for att in email.attachments {
                    guard let fileURL = att.fileURL else { continue }
                    let destURL = folderURL.appendingPathComponent(att.filename)
                    do {
                        try FileUtils.copyFile(from: fileURL, to: destURL)
                    } catch {
                        print("Error copying attachment \(att.filename): \(error)")
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
                    print("Failed to export as TXT: \(error)")
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
                let csvRow = "\"\(subjectLine.replacingOccurrences(of: "\"", with: "'"))\",\"\(header("From"))\",\"\(header("To"))\",\"\(header("Date"))\",\"\(emailBody.replacingOccurrences(of: "\"", with: "'"))\"\n"
                let csvContent = csvHeaders + csvRow

                do {
                    try FileUtils.writeString(csvContent, to: url)
                } catch {
                    print("Failed to export CSV: \(error)")
                }
            }
        }
    }

    private var headerBlock: some View {
        VStack(spacing: Spacing.small) {
            HStack(alignment: .top, spacing: Spacing.large) {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    LabelText(title: "From", value: header("From"))
                    LabelText(title: "To", value: header("To"))
                    LabelText(title: "Reply-To", value: header("Reply-To"))
                }
                Spacer()
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    LabelText(title: "Date", value: header("Date"))
                    LabelText(title: "CC", value: header("Cc"))
                    LabelText(title: "BCC", value: header("Bcc"))
                    LabelText(title: "Message-ID", value: header("Message-ID"))
                }
            }
        }
        .padding(Spacing.small)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.medium)
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
            let qpDecoded = QuotedPrintableDecoder.decode(encodedText, isHeader: true, charset: charset)
            if let data = qpDecoded.data(using: .utf8) {
                decoded = decodeWithCharset(data: data, charset: charset) ?? qpDecoded
            }
        }
        result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
    }
    return result
}

func decodeWithCharset(data: Data, charset: String) -> String? {
    let encoding: String.Encoding
    switch charset.lowercased() {
    case "utf-8", "utf8": encoding = .utf8
    case "iso-8859-1", "latin1": encoding = .isoLatin1
    case "us-ascii", "ascii": encoding = .ascii
    case "windows-1252": encoding = .windowsCP1252
    default:
        encoding = .utf8
    }
    return String(data: data, encoding: encoding)
}
import AppKit

extension View {
    func openInWindow(title: String = "Email", storeManager: StoreManager? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        if let storeManager {
            window.contentView = NSHostingView(rootView: self.environmentObject(storeManager))
        } else {
            window.contentView = NSHostingView(rootView: self)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
