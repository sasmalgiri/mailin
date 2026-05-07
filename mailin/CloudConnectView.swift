import SwiftUI

struct GmailConnectView: View {
    @ObservedObject private var connector = GmailConnector.shared
    @State private var fetchCount = 100
    @State private var searchQuery = ""
    @State private var fetchedEmails: [MBOXParser.RawEmail] = []
    @State private var errorMessage = ""
    @Environment(\.dismiss) private var dismiss

    var onImport: ([MBOXParser.RawEmail]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundColor(.red)
                Text("Gmail Connect")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    if !connector.isAuthenticated {
                        VStack(spacing: Spacing.small) {
                            Image(systemName: "person.badge.key")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                                .accessibilityHidden(true)

                            Text("Sign in with your Google account to access Gmail messages.")
                                .font(Typography.subheadline)
                                .foregroundColor(AppColors.secondary)
                                .multilineTextAlignment(.center)

                            Button("Sign in with Google") {
                                Task {
                                    do {
                                        try await connector.authenticate()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .accessibilityLabel("Sign in with Google")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.large)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .accessibilityHidden(true)
                            Text("Signed in as \(connector.userEmail)")
                                .font(Typography.subheadline)
                            Spacer()
                            Button("Sign Out") { connector.signOut() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("Sign out of Google account")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Connected, signed in as \(connector.userEmail)")

                        Divider()

                        HStack {
                            TextField("Search (optional)", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Search query for messages")
                            Stepper("Limit: \(fetchCount)", value: $fetchCount, in: 10...5000, step: 50)
                                .font(Typography.caption1)
                                .accessibilityLabel("Message fetch limit")
                                .accessibilityValue("\(fetchCount)")
                        }

                        Button("Fetch Messages") {
                            errorMessage = ""
                            Task {
                                do {
                                    fetchedEmails = try await connector.fetchMessages(
                                        maxResults: fetchCount,
                                        query: searchQuery.isEmpty ? nil : searchQuery
                                    )
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connector.isFetching)
                        .accessibilityLabel("Fetch messages from Gmail")
                        .accessibilityHint("Downloads up to \(fetchCount) messages")

                        if connector.isFetching {
                            ProgressView(value: connector.fetchProgress)
                                .accessibilityLabel("Fetching messages")
                                .accessibilityValue("\(Int(connector.fetchProgress * 100)) percent complete")
                        }

                        if !fetchedEmails.isEmpty {
                            HStack {
                                Text("Fetched \(fetchedEmails.count) emails")
                                    .font(Typography.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Button("Import to mailin") {
                                    onImport(fetchedEmails)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Import \(fetchedEmails.count) emails to mailin")
                            }
                        }
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }

                    Text(connector.statusMessage)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .accessibilityLabel("Status: \(connector.statusMessage)")
                }
                .padding(Spacing.medium)
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 350)
        #else
        .presentationDetents([.large])
        #endif
    }
}

struct OutlookConnectView: View {
    @ObservedObject private var connector = OutlookConnector.shared
    @State private var selectedFolderID = ""
    @State private var fetchCount = 100
    @State private var fetchedEmails: [MBOXParser.RawEmail] = []
    @State private var folders: [OutlookFolder] = []
    @State private var errorMessage = ""
    @Environment(\.dismiss) private var dismiss

    var onImport: ([MBOXParser.RawEmail]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "cloud")
                    .foregroundColor(.blue)
                Text("Office 365 Connect")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    if !connector.isAuthenticated {
                        VStack(spacing: Spacing.small) {
                            Image(systemName: "person.badge.key")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                                .accessibilityHidden(true)

                            Text("Sign in with your Microsoft account to access Outlook messages.")
                                .font(Typography.subheadline)
                                .foregroundColor(AppColors.secondary)
                                .multilineTextAlignment(.center)

                            Button("Sign in with Microsoft") {
                                Task {
                                    do {
                                        try await connector.authenticate()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .accessibilityLabel("Sign in with Microsoft")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.large)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .accessibilityHidden(true)
                            Text("Signed in as \(connector.userDisplayName)")
                                .font(Typography.subheadline)
                            Spacer()
                            Button("Sign Out") { connector.signOut() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("Sign out of Microsoft account")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Connected, signed in as \(connector.userDisplayName)")

                        Divider()

                        if folders.isEmpty {
                            Button("Load Folders") {
                                Task {
                                    do {
                                        folders = try await connector.listFolders()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Load Outlook mail folders")
                        } else {
                            Picker("Folder", selection: $selectedFolderID) {
                                Text("Select...").tag("")
                                ForEach(folders) { folder in
                                    Text("\(folder.displayName) (\(folder.totalItemCount))")
                                        .tag(folder.id)
                                }
                            }
                            .accessibilityLabel("Select mail folder")

                            HStack {
                                Stepper("Limit: \(fetchCount)", value: $fetchCount, in: 10...5000, step: 50)
                                    .font(Typography.caption1)
                                    .accessibilityLabel("Message fetch limit")
                                    .accessibilityValue("\(fetchCount)")
                                Spacer()
                                Button("Fetch Messages") {
                                    errorMessage = ""
                                    Task {
                                        do {
                                            fetchedEmails = try await connector.fetchMessages(
                                                folder: selectedFolderID.isEmpty ? "inbox" : selectedFolderID,
                                                maxResults: fetchCount
                                            )
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(connector.isLoading)
                                .accessibilityLabel("Fetch messages from Outlook")
                                .accessibilityHint("Downloads up to \(fetchCount) messages")
                            }
                        }

                        if connector.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .accessibilityLabel("Loading messages")
                        }

                        if !fetchedEmails.isEmpty {
                            HStack {
                                Text("Fetched \(fetchedEmails.count) emails")
                                    .font(Typography.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Button("Import to mailin") {
                                    onImport(fetchedEmails)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Import \(fetchedEmails.count) emails to mailin")
                            }
                        }
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }

                    Text(connector.statusMessage)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .accessibilityLabel("Status: \(connector.statusMessage)")
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
}
