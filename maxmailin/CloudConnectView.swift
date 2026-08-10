#if !OFFLINE_MODE
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

                            Button {
                                Task {
                                    do {
                                        try await connector.authenticate()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                    Text("Sign in with Google")
                                    Spacer()
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

                        #if os(iOS)
                        VStack(spacing: Spacing.xSmall) {
                            TextField("Search (optional)", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Search query for messages")
                            Stepper("Limit: \(fetchCount)", value: $fetchCount, in: 10...5000, step: 50)
                                .font(Typography.caption1)
                                .accessibilityLabel("Message fetch limit")
                                .accessibilityValue("\(fetchCount)")
                        }
                        #else
                        HStack {
                            TextField("Search (optional)", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Search query for messages")
                            Stepper("Limit: \(fetchCount)", value: $fetchCount, in: 10...5000, step: 50)
                                .font(Typography.caption1)
                                .accessibilityLabel("Message fetch limit")
                                .accessibilityValue("\(fetchCount)")
                        }
                        #endif

                        Button {
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
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                Text("Fetch Messages")
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connector.isFetching)
                        .accessibilityLabel("Fetch messages from Gmail")
                        .accessibilityHint("Downloads up to \(fetchCount) messages")

                        if connector.isFetching {
                            VStack(spacing: 4) {
                                ProgressView(value: connector.fetchProgress)
                                Text("\(Int(connector.fetchProgress * 100))%")
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                            }
                            .accessibilityLabel("Fetching messages")
                            .accessibilityValue("\(Int(connector.fetchProgress * 100)) percent complete")
                        }

                        if !fetchedEmails.isEmpty {
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

                            Button {
                                Task {
                                    do {
                                        try await connector.authenticate()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                    Text("Sign in with Microsoft")
                                    Spacer()
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
                            Button {
                                Task {
                                    do {
                                        folders = try await connector.listFolders()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "folder")
                                    Text("Load Folders")
                                    Spacer()
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

                            #if os(iOS)
                            VStack(spacing: Spacing.xSmall) {
                                Stepper("Limit: \(fetchCount)", value: $fetchCount, in: 10...5000, step: 50)
                                    .font(Typography.caption1)
                                    .accessibilityLabel("Message fetch limit")
                                    .accessibilityValue("\(fetchCount)")
                                Button {
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
                                } label: {
                                    HStack {
                                        Spacer()
                                        Image(systemName: "arrow.down.circle")
                                        Text("Fetch Messages")
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(connector.isLoading)
                                .accessibilityLabel("Fetch messages from Outlook")
                                .accessibilityHint("Downloads up to \(fetchCount) messages")
                            }
                            #else
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
                            #endif
                        }

                        if connector.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Loading messages")
                        }

                        if !fetchedEmails.isEmpty {
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

// MARK: - Unified Cloud Connect View

struct CloudConnectView: View {
    var onImport: ([MBOXParser.RawEmail]) -> Void
    @State private var selectedTab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "cloud.fill")
                    .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                Text("Cloud Connect")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
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

            Picker("Service", selection: $selectedTab) {
                Label("Gmail", systemImage: "envelope.fill").tag(0)
                Label("Outlook", systemImage: "cloud.fill").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)

            if selectedTab == 0 {
                GmailConnectView(onImport: onImport)
            } else {
                OutlookConnectView(onImport: onImport)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #else
        .presentationDetents([.large])
        #endif
    }
}

#endif
