#if !OFFLINE_MODE
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum ComposeMode {
    case new
    case reply(original: MBOXParser.RawEmail)
    case replyAll(original: MBOXParser.RawEmail)
    case forward(original: MBOXParser.RawEmail)
}

@MainActor
class ComposeViewModel: ObservableObject {
    @Published var fromAddress: String = ""
    @Published var toField: String = ""
    @Published var ccField: String = ""
    @Published var bccField: String = ""
    @Published var subject: String = ""
    @Published var body: String = ""
    @Published var showCc: Bool = false
    @Published var showBcc: Bool = false
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published var sentSuccessfully: Bool = false
    @Published var attachments: [EmailAttachmentData] = []

    let mode: ComposeMode

    // SMTP Settings
    @Published var smtpServer: String = ""
    @Published var smtpPort: String = "587"
    @Published var smtpUsername: String = ""
    @Published var smtpPassword: String = ""
    @Published var showSMTPSettings: Bool = false

    // Signature
    @Published var signatureEnabled: Bool = UserDefaults.standard.bool(forKey: "emailSignatureEnabled")
    @Published var signatureText: String = UserDefaults.standard.string(forKey: "emailSignatureText") ?? ""

    // Send retry
    @Published var sendAttempts: Int = 0
    private static let maxRetries = 2

    private var inReplyTo: String?
    private var references: String?

    init(mode: ComposeMode) {
        self.mode = mode
        loadSavedSMTPConfig()
        prefill()
    }

    private func prefill() {
        switch mode {
        case .new:
            break

        case .reply(let original):
            toField = original.headers["From"] ?? ""
            let subj = original.headers["Subject"] ?? ""
            subject = subj.hasPrefix("Re:") ? subj : "Re: \(subj)"
            body = buildQuotedBody(original)
            inReplyTo = original.headers["Message-ID"]
            references = buildReferences(original)

        case .replyAll(let original):
            toField = original.headers["From"] ?? ""
            let toHeader = original.headers["To"] ?? ""
            let ccHeader = original.headers["Cc"] ?? ""
            let others = (toHeader.components(separatedBy: ",") + ccHeader.components(separatedBy: ","))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != fromAddress.lowercased() }
            ccField = others.joined(separator: ", ")
            if !ccField.isEmpty { showCc = true }
            let subj = original.headers["Subject"] ?? ""
            subject = subj.hasPrefix("Re:") ? subj : "Re: \(subj)"
            body = buildQuotedBody(original)
            inReplyTo = original.headers["Message-ID"]
            references = buildReferences(original)

        case .forward(let original):
            let subj = original.headers["Subject"] ?? ""
            subject = subj.hasPrefix("Fwd:") ? subj : "Fwd: \(subj)"
            body = buildForwardBody(original)
        }
    }

    private func buildQuotedBody(_ email: MBOXParser.RawEmail) -> String {
        let date = email.headers["Date"] ?? email.timestamp
        let from = email.headers["From"] ?? "Unknown"
        let bodyText = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
        let header = "\n\nOn \(date), \(from) wrote:\n"
        let quoted = bodyText.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        return header + quoted
    }

    private func buildForwardBody(_ email: MBOXParser.RawEmail) -> String {
        let date = email.headers["Date"] ?? email.timestamp
        let from = email.headers["From"] ?? "Unknown"
        let subj = email.headers["Subject"] ?? "(No Subject)"
        let to = email.headers["To"] ?? ""
        let bodyText = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
        return """
        \n\n---------- Forwarded message ----------
        From: \(from)
        Date: \(date)
        Subject: \(subj)
        To: \(to)

        \(bodyText)
        """
    }

    private func buildReferences(_ email: MBOXParser.RawEmail) -> String? {
        let messageID = email.headers["Message-ID"]
        if let refs = email.references, !refs.isEmpty {
            return refs.joined(separator: " ") + " " + (messageID ?? "")
        }
        return messageID
    }

    func send() async {
        guard !toField.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter at least one recipient."
            return
        }
        guard !fromAddress.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter your email address in SMTP settings."
            showSMTPSettings = true
            return
        }
        guard !smtpServer.isEmpty, !smtpUsername.isEmpty, !smtpPassword.isEmpty else {
            errorMessage = "Please configure SMTP settings before sending."
            showSMTPSettings = true
            return
        }

        isSending = true
        errorMessage = nil
        sendAttempts = 0

        let portNum = UInt16(smtpPort) ?? 587
        let config = SMTPConfig(
            server: smtpServer,
            port: portNum,
            username: smtpUsername,
            password: smtpPassword,
            useSSL: portNum == 465
        )

        var finalBody = body
        if signatureEnabled && !signatureText.isEmpty {
            finalBody += "\n\n-- \n\(signatureText)"
        }

        let includeXMailer = UserDefaults.standard.bool(forKey: "includeXMailerHeader")

        let outgoing = OutgoingEmail(
            from: fromAddress,
            to: parseAddresses(toField),
            cc: parseAddresses(ccField),
            bcc: parseAddresses(bccField),
            subject: subject,
            body: finalBody,
            isHTML: false,
            attachments: attachments,
            inReplyTo: inReplyTo,
            references: references,
            includeXMailer: includeXMailer
        )

        let client = SMTPClient(config: config)

        while sendAttempts <= Self.maxRetries {
            sendAttempts += 1
            do {
                try await client.send(outgoing)
                saveSMTPConfig()
                saveDraft(clear: true)
                sentSuccessfully = true
                NotificationCenter.default.post(name: .composeEmailSent, object: nil)
                return
            } catch {
                if sendAttempts > Self.maxRetries {
                    saveDraft(clear: false)
                    errorMessage = "\(error.localizedDescription) (failed after \(sendAttempts) attempts). Draft saved."
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(sendAttempts) * 1_000_000_000)
                }
            }
        }

        isSending = false
    }

    // MARK: - Draft Persistence

    private static let draftKey = "compose_draft"

    func saveDraft(clear: Bool) {
        if clear {
            UserDefaults.standard.removeObject(forKey: Self.draftKey)
            return
        }
        let draft: [String: String] = [
            "to": toField, "cc": ccField, "bcc": bccField,
            "subject": subject, "body": body, "from": fromAddress
        ]
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: Self.draftKey)
        }
    }

    func loadDraft() {
        guard case .new = mode else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.draftKey),
              let draft = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if toField.isEmpty { toField = draft["to"] ?? "" }
        if subject.isEmpty { subject = draft["subject"] ?? "" }
        if body.isEmpty { body = draft["body"] ?? "" }
        if ccField.isEmpty { ccField = draft["cc"] ?? "" }
        if bccField.isEmpty { bccField = draft["bcc"] ?? "" }
    }

    static var hasSavedDraft: Bool {
        UserDefaults.standard.data(forKey: draftKey) != nil
    }

    private func parseAddresses(_ text: String) -> [String] {
        text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func addAttachment(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = mimeTypeForExtension(url.pathExtension)
        attachments.append(EmailAttachmentData(
            filename: url.lastPathComponent,
            mimeType: mimeType,
            data: data
        ))
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        case "eml": return "message/rfc822"
        default: return "application/octet-stream"
        }
    }

    // MARK: - SMTP Config Persistence

    private static let smtpServerKey = "smtp_server"
    private static let smtpPortKey = "smtp_port"
    private static let smtpUsernameKey = "smtp_username"
    private static let smtpFromKey = "smtp_from"
    private static let smtpPasswordKeychainKey = "smtp_password"

    private func saveSMTPConfig() {
        UserDefaults.standard.set(smtpServer, forKey: Self.smtpServerKey)
        UserDefaults.standard.set(smtpPort, forKey: Self.smtpPortKey)
        UserDefaults.standard.set(smtpUsername, forKey: Self.smtpUsernameKey)
        UserDefaults.standard.set(fromAddress, forKey: Self.smtpFromKey)
        KeychainHelper.save(key: Self.smtpPasswordKeychainKey, value: smtpPassword)
    }

    private func loadSavedSMTPConfig() {
        smtpServer = UserDefaults.standard.string(forKey: Self.smtpServerKey) ?? ""
        smtpPort = UserDefaults.standard.string(forKey: Self.smtpPortKey) ?? "587"
        smtpUsername = UserDefaults.standard.string(forKey: Self.smtpUsernameKey) ?? ""
        fromAddress = UserDefaults.standard.string(forKey: Self.smtpFromKey) ?? ""
        smtpPassword = KeychainHelper.load(key: Self.smtpPasswordKeychainKey)
    }
}

// MARK: - Compose Email View

struct ComposeEmailView: View {
    @StateObject private var vm: ComposeViewModel
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)?
    #if os(iOS)
    @State private var showAttachmentPicker = false
    #endif

    init(mode: ComposeMode = .new, onClose: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ComposeViewModel(mode: mode))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(spacing: Spacing.small) {
                    addressFields
                    subjectField
                    Divider()
                    bodyEditor
                    attachmentsList
                }
                .padding(Spacing.medium)
            }

            if vm.showSMTPSettings {
                Divider()
                smtpSettingsSection
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 640, minHeight: 350, idealHeight: 600)
        #endif
        .background(AppColors.backgroundPrimary)
        .onAppear { vm.loadDraft() }
        .onDisappear { if !vm.sentSuccessfully { vm.saveDraft(clear: false) } }
        .alert("Email Sent", isPresented: $vm.sentSuccessfully) {
            Button("OK") { closeCompose() }
        } message: {
            Text("Your email has been sent successfully.")
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $showAttachmentPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    vm.addAttachment(url: url)
                }
            }
        }
        #endif
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button { closeCompose() } label: {
                #if os(iOS)
                Text("Cancel")
                    .font(Typography.callout)
                #else
                Image(systemName: "xmark")
                #endif
            }
            .buttonStyle(.plain)
            .foregroundColor(AppColors.primary)
            .accessibilityLabel("Discard")

            #if os(iOS)
            Spacer()
            Text(toolbarTitle)
                .font(Typography.headline)
            Spacer()
            #else
            Text(toolbarTitle)
                .font(Typography.headline)
            Spacer()

            Button {
                vm.showSMTPSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("SMTP Settings")
            #endif

            #if os(iOS)
            HStack(spacing: Spacing.small) {
                Button {
                    vm.showSMTPSettings.toggle()
                } label: {
                    Image(systemName: vm.smtpServer.isEmpty ? "gearshape.circle" : "gearshape.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(vm.smtpServer.isEmpty ? AppColors.error : AppColors.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await vm.send() }
                } label: {
                    if vm.isSending {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(vm.toField.trimmingCharacters(in: .whitespaces).isEmpty ? AppColors.secondary.opacity(0.4) : AppColors.primary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(vm.isSending || vm.toField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            #else
            Button {
                Task { await vm.send() }
            } label: {
                HStack(spacing: Spacing.xxSmall) {
                    if vm.isSending {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("Send")
                }
            }
            .buttonStyle(CompactPrimaryButtonStyle())
            .disabled(vm.isSending || vm.toField.trimmingCharacters(in: .whitespaces).isEmpty)
            #endif
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    private var toolbarTitle: String {
        switch vm.mode {
        case .new: return "New Email"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }

    // MARK: - Address Fields

    private var addressFields: some View {
        let labelWidth: CGFloat = {
            #if os(iOS)
            return 44
            #else
            return 50
            #endif
        }()

        return VStack(spacing: Spacing.xSmall) {
            HStack {
                Text("From:")
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                TextField("your@email.com", text: $vm.fromAddress)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    #endif
            }

            HStack {
                Text("To:")
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                TextField("recipient@email.com", text: $vm.toField)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    #endif

                if !vm.showCc {
                    Button("Cc/Bcc") {
                        vm.showCc = true
                        vm.showBcc = true
                    }
                    .font(Typography.caption1)
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.primary)
                }
            }

            if vm.showCc {
                HStack {
                    Text("Cc:")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("cc@email.com", text: $vm.ccField)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        #endif
                }
            }

            if vm.showBcc {
                HStack {
                    Text("Bcc:")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("bcc@email.com", text: $vm.bccField)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        #endif
                }
            }

            if let error = vm.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .font(Typography.caption1)
                }
                .foregroundColor(AppColors.error)
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.error.opacity(0.08))
                .cornerRadius(CornerRadius.small)
            }
        }
    }

    // MARK: - Subject

    private var subjectField: some View {
        HStack {
            Text("Subject:")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .frame(width: 50, alignment: .trailing)
            TextField("Subject", text: $vm.subject)
                .textFieldStyle(.plain)
        }
    }

    // MARK: - Body

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            TextEditor(text: $vm.body)
                .font(Typography.body)
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)

            HStack(spacing: Spacing.small) {
                Toggle("Signature", isOn: $vm.signatureEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(Typography.caption1)
                    .onChange(of: vm.signatureEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "emailSignatureEnabled")
                    }

                if vm.signatureEnabled && !vm.signatureText.isEmpty {
                    Text("— \(vm.signatureText.prefix(40))…")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    // MARK: - Attachments

    private var attachmentsList: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Button {
                    pickAttachment()
                } label: {
                    Label("Attach File", systemImage: "paperclip")
                        .font(Typography.caption1)
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.primary)

                Spacer()
            }

            ForEach(Array(vm.attachments.enumerated()), id: \.offset) { index, attachment in
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "doc")
                        .foregroundColor(AppColors.secondary)
                    Text(attachment.filename)
                        .font(Typography.caption1)
                    Text("(\(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)))")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                    Spacer()
                    Button {
                        vm.removeAttachment(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.xSmall)
                .background(AppColors.secondary.opacity(0.08))
                .cornerRadius(CornerRadius.small)
            }
        }
    }

    private func pickAttachment() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                vm.addAttachment(url: url)
            }
        }
        #else
        showAttachmentPicker = true
        #endif
    }

    // MARK: - SMTP Settings

    private var smtpSettingsSection: some View {
        VStack(spacing: Spacing.small) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundColor(AppColors.primary)
                Text("SMTP Settings")
                    .font(Typography.headline)
                Spacer()
                Button { vm.showSMTPSettings = false } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Spacing.xSmall) {
                Text("Quick setup:")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                smtpPresetButton("Gmail", config: .gmailDefaults)
                smtpPresetButton("Outlook", config: .outlookDefaults)
                smtpPresetButton("Yahoo", config: .yahooDefaults)
            }

            #if os(iOS)
            VStack(spacing: Spacing.xSmall) {
                smtpField(label: "Server", placeholder: "smtp.gmail.com", text: $vm.smtpServer)
                HStack(spacing: Spacing.xSmall) {
                    smtpField(label: "Port", placeholder: "587", text: $vm.smtpPort)
                        .frame(width: 120)
                    Spacer()
                    if let portNum = UInt16(vm.smtpPort) {
                        Text(portNum == 465 ? "SSL" : "STARTTLS")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(AppColors.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                smtpField(label: "Username", placeholder: "your@email.com", text: $vm.smtpUsername)
                HStack {
                    Text("Password")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .frame(width: 72, alignment: .leading)
                    SecureField("App password", text: $vm.smtpPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
            #else
            HStack(spacing: Spacing.small) {
                HStack {
                    Text("Server:")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    TextField("smtp.gmail.com", text: $vm.smtpServer)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                HStack {
                    Text("Port:")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    TextField("587", text: $vm.smtpPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }

            HStack(spacing: Spacing.small) {
                HStack {
                    Text("Username:")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    TextField("your@email.com", text: $vm.smtpUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                HStack {
                    Text("Password:")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    SecureField("App password", text: $vm.smtpPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }
            #endif

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("For Gmail, use an App Password (Google Account → Security → App Passwords)")
                    .font(Typography.caption2)
            }
            .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.medium)
        .background(AppColors.secondary.opacity(0.05))
    }

    #if os(iOS)
    private func smtpField(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .frame(width: 72, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }
    #endif

    private func smtpPresetButton(_ name: String, config: SMTPConfig) -> some View {
        Button(name) {
            vm.smtpServer = config.server
            vm.smtpPort = String(config.port)
        }
        .font(Typography.caption2)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func closeCompose() {
        if let onClose = onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

#endif
