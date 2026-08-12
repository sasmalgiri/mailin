//
//  ArchiveEmailPickerView.swift
//  maxmailin
//
//  A small, reusable multi-select picker over the archive: search, tick the
//  emails you want, and hand them back. Used by the workflow runner to attach
//  the actual emails a step refers to (the "pivotal events", the custodian's
//  messages, the DSAR hits) without leaving the job. Reads lightweight
//  summaries via ArchiveDataService — no bodies loaded, fully on-device.
//

import SwiftUI

struct ArchiveEmailPickerView: View {
    /// Called with the chosen emails when the user taps Add.
    var onDone: ([EmailSummary]) -> Void
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [EmailSummary] = []
    @State private var selected: Set<EmailID> = []
    @State private var isLoading = false
    @State private var total = 0
    @State private var searchTask: Task<Void, Never>? = nil

    private static let limit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add emails from your archive").font(Typography.title3)
                    Text("Search, tick the messages you want, then Add them to this step.")
                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                }
                Spacer()
                Button { onCancel(); dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(AppColors.secondary).imageScale(.large)
                }
                .buttonStyle(.plain).help("Cancel")
            }
            .padding(Spacing.medium)

            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "magnifyingglass").foregroundColor(AppColors.secondary)
                TextField("Search subject, sender, or text…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { scheduleSearch(immediate: true) }
                if !selected.isEmpty {
                    Text("\(selected.count) selected").font(Typography.caption2).foregroundColor(AppColors.primary)
                }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, Spacing.xSmall)
            Divider()

            if isLoading && results.isEmpty {
                Spacer(); HStack { Spacer(); ProgressView(); Spacer() }; Spacer()
            } else if results.isEmpty {
                Spacer()
                VStack(spacing: Spacing.xSmall) {
                    Image(systemName: "tray").font(.largeTitle).foregroundColor(AppColors.secondary)
                    Text(searchText.isEmpty ? "No emails in the archive yet." : "No matches for “\(searchText)”.")
                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(results) { row in
                    Button { toggle(row.id) } label: {
                        HStack(alignment: .top, spacing: Spacing.small) {
                            Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(row.id) ? AppColors.primary : AppColors.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                                    .font(Typography.callout).lineLimit(1)
                                HStack(spacing: Spacing.xxSmall) {
                                    Text(row.from).lineLimit(1)
                                    Text("·")
                                    Text(row.date.formatted(date: .abbreviated, time: .shortened))
                                    if row.hasAttachments {
                                        Image(systemName: "paperclip")
                                    }
                                }
                                .font(Typography.caption2).foregroundColor(AppColors.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            HStack {
                Text(total > 0 ? "Showing \(results.count) of \(total)" : " ")
                    .font(Typography.caption2).foregroundColor(AppColors.secondary)
                Spacer()
                Button("Cancel") { onCancel(); dismiss() }
                Button("Add \(selected.count == 0 ? "" : "\(selected.count) ")email\(selected.count == 1 ? "" : "s")") {
                    let chosen = results.filter { selected.contains($0.id) }
                    onDone(chosen); dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(Spacing.medium)
        }
        .frame(minWidth: 540, minHeight: 460)
        .task { await load() }
        .onChange(of: searchText) { _, _ in scheduleSearch(immediate: false) }
    }

    private func toggle(_ id: EmailID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func scheduleSearch(immediate: Bool) {
        searchTask?.cancel()
        searchTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 300_000_000) }
            if Task.isCancelled { return }
            await load()
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let query = EmailQuery(text: trimmed.isEmpty ? nil : trimmed)
        let page = try? await ArchiveDataService.shared.page(query: query, cursor: nil, limit: Self.limit)
        results = page?.summaries ?? []
        total = (try? await ArchiveDataService.shared.count(query: query)) ?? results.count
    }
}
