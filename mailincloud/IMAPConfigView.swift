import SwiftUI

struct IMAPConfigView: View {
    @StateObject private var client = IMAPClient()
    @State private var server = ""
    @State private var port = "993"
    @State private var username = ""
    @State private var password = ""
    @State private var selectedFolder = ""
    @State private var messageLimit = 100
    @State private var fetchedEmails: [MBOXParser.RawEmail] = []
    @State private var errorMessage = ""
    @Environment(\.dismiss) private var dismiss

    var onImport: ([MBOXParser.RawEmail]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(AppColors.primary)
                Text("IMAP Connect")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
                connectionStatusBadge
                #if os(iOS)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(AppColors.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                #else
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                #endif
            }
            .padding(Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    presetButtons

                    #if os(iOS)
                    VStack(spacing: Spacing.xSmall) {
                        imapField(label: "Server", placeholder: "imap.gmail.com", text: $server)
                        HStack(spacing: Spacing.xSmall) {
                            imapField(label: "Port", placeholder: "993", text: $port)
                                .frame(width: 140)
                            Spacer()
                            Text("SSL/TLS")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(AppColors.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                        imapField(label: "Username", placeholder: "user@example.com", text: $username)
                        HStack {
                            Text("Password")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                                .frame(width: 72, alignment: .leading)
                            SecureField("Password or App Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    #else
                    Group {
                        LabeledContent("Server") {
                            TextField("imap.gmail.com", text: $server)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("IMAP server address")
                        }
                        LabeledContent("Port") {
                            TextField("993", text: $port)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .accessibilityLabel("IMAP port number")
                        }
                        LabeledContent("Username") {
                            TextField("user@example.com", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("IMAP username or email address")
                        }
                        LabeledContent("Password") {
                            SecureField("Password or App Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("IMAP password or app password")
                        }
                    }
                    #endif

                    Button {
                        connectToServer()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "bolt.fill")
                            Text("Connect")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(server.isEmpty || username.isEmpty || password.isEmpty)
                    .accessibilityLabel("Connect to IMAP server")
                    .accessibilityHint("Connects to \(server.isEmpty ? "the configured server" : server)")

                    if !client.folders.isEmpty {
                        Divider()
                        folderPicker
                    }

                    if !fetchedEmails.isEmpty {
                        Divider()
                        VStack(spacing: Spacing.small) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Fetched \(fetchedEmails.count) emails")
                                    .font(Typography.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            Button {
                                onImport(fetchedEmails)
                                dismiss()
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Import to mailin")
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Import \(fetchedEmails.count) emails to mailin")
                        }
                    }

                    if !errorMessage.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                            Text(errorMessage)
                                .font(Typography.caption1)
                        }
                        .foregroundColor(AppColors.error)
                        .padding(Spacing.xSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.error.opacity(0.08))
                        .cornerRadius(CornerRadius.small)
                    }

                    if client.progress > 0 && client.progress < 1 {
                        VStack(spacing: 4) {
                            ProgressView(value: client.progress)
                            Text("\(Int(client.progress * 100))%")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                        .accessibilityLabel("Fetch progress")
                        .accessibilityValue("\(Int(client.progress * 100)) percent complete")
                    }

                    Text(client.statusMessage)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(Spacing.medium)
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #else
        .presentationDetents([.large])
        #endif
    }

    #if os(iOS)
    private func imapField(label: String, placeholder: String, text: Binding<String>) -> some View {
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

    private var presetButtons: some View {
        HStack(spacing: Spacing.small) {
            Button("Gmail") {
                server = "imap.gmail.com"
                port = "993"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Set server to Gmail")
            .accessibilityHint("Sets server to imap.gmail.com, port 993")

            Button("Outlook") {
                server = "outlook.office365.com"
                port = "993"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Set server to Outlook")
            .accessibilityHint("Sets server to outlook.office365.com, port 993")

            Button("Yahoo") {
                server = "imap.mail.yahoo.com"
                port = "993"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Set server to Yahoo")
            .accessibilityHint("Sets server to imap.mail.yahoo.com, port 993")
        }
    }

    private var connectionStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(statusText)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(statusText)")
    }

    private var statusColor: Color {
        switch client.connectionState {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .yellow
        case .authenticated: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch client.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .authenticated: return "Authenticated"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Select Folder")
                .font(Typography.subheadline)
                .fontWeight(.semibold)

            Picker("Folder", selection: $selectedFolder) {
                Text("Select...").tag("")
                ForEach(client.folders) { folder in
                    Text("\(folder.name) \(folder.messageCount.map { "(\($0))" } ?? "")")
                        .tag(folder.name)
                }
            }
            .accessibilityLabel("Select IMAP folder")

            HStack {
                Stepper("Fetch limit: \(messageLimit)", value: $messageLimit, in: 10...5000, step: 50)
                    .font(Typography.caption1)
                    .accessibilityLabel("Fetch limit")
                    .accessibilityValue("\(messageLimit) messages")
                Spacer()
                Button("Fetch Messages") { fetchMessages() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedFolder.isEmpty)
                    .accessibilityLabel("Fetch messages from selected folder")
            }
        }
    }

    private func connectToServer() {
        errorMessage = ""
        let config = IMAPConfig(
            server: server,
            port: UInt16(port) ?? 993,
            username: username,
            password: password
        )
        Task {
            do {
                try await client.connect(config: config)
                let folders = try await client.listFolders()
                if let inbox = folders.first(where: { $0.name.uppercased() == "INBOX" }) {
                    selectedFolder = inbox.name
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fetchMessages() {
        errorMessage = ""
        Task {
            do {
                fetchedEmails = try await client.fetchAllMessages(folder: selectedFolder, limit: messageLimit)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
