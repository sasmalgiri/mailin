//
//  ArchiveListView.swift
//  maxmailin
//
//  Stage 5 Wave 1B/1C/1D (v2-core-cutover): the production browse surface — a
//  clean, standalone list that renders bounded `EmailSummary` pages from
//  `ArchiveListViewModel` and hydrates detail by id via `ArchiveDetailViewModel`.
//  It replaces the legacy 3,460-line array-backed list for the NORMAL browse
//  path; feature-rich legacy paths stay on the old view until their own slices.
//
//  No `RawEmail` is required to render a row; a full email is fetched only when
//  a row is opened.
//

import SwiftUI

struct ArchiveListView: View {
    @StateObject private var model: ArchiveListViewModel
    @StateObject private var detail: ArchiveDetailViewModel
    @State private var selectedID: EmailID?

    init(archive: ArchiveDataService = .shared) {
        _model = StateObject(wrappedValue: ArchiveListViewModel(archive: archive, pageSize: 100, maxRetained: 500))
        _detail = StateObject(wrappedValue: ArchiveDetailViewModel(archive: archive))
    }

    var body: some View {
        NavigationSplitView {
            listPane
                .navigationTitle("Archive")
        } detail: {
            ArchiveDetailHost(detail: detail)
        }
        .task {
            if model.summaries.isEmpty && model.error == nil { await model.loadInitial() }
        }
        .onChange(of: selectedID) { _, id in
            Task { await detail.select(id) }
        }
    }

    @ViewBuilder
    private var listPane: some View {
        if model.isLoading && model.summaries.isEmpty {
            ProgressView("Loading archive…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("archive.list.initialLoading")
        } else if let error = model.error, model.summaries.isEmpty {
            ArchiveLoadFailureView(message: error.localizedDescription) {
                Task { await model.reload() }
            }
        } else if model.summaries.isEmpty {
            ArchiveEmptyState()
        } else {
            List(selection: $selectedID) {
                if model.hasPrevious {
                    Button {
                        Task { await model.loadPreviousPage() }
                    } label: {
                        Label("Load earlier", systemImage: "chevron.up")
                    }
                    .accessibilityIdentifier("archive.list.loadPrevious")
                }

                ForEach(model.summaries) { summary in
                    ArchiveSummaryRow(summary: summary)
                        .tag(summary.id)
                        .onAppear {
                            if summary.id == model.summaries.last?.id && model.hasMore {
                                Task { await model.loadNextPage() }
                            }
                        }
                }

                if model.hasMore {
                    ArchiveListLoadingFooter()
                }
            }
            .accessibilityIdentifier("archive.list")
            .overlay(alignment: .bottom) {
                Text("\(model.totalCount) emails")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .accessibilityIdentifier("archive.list.count")
            }
        }
    }
}

// MARK: - Row

struct ArchiveSummaryRow: View {
    let summary: EmailSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(summary.from.isEmpty ? "(unknown sender)" : summary.from)
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if summary.hasAttachments {
                    Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                }
                Text(summary.date, format: .dateTime.year().month().day())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(summary.subject.isEmpty ? "(No Subject)" : summary.subject)
                .font(.subheadline).lineLimit(1)
            if !summary.bodyPreview.isEmpty {
                Text(summary.bodyPreview)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("archive.row.\(summary.id.uuidString)")
    }
}

// MARK: - Detail host

struct ArchiveDetailHost: View {
    @ObservedObject var detail: ArchiveDetailViewModel

    var body: some View {
        switch detail.state {
        case .idle:
            ContentUnavailableView("No email selected", systemImage: "envelope")
                .accessibilityIdentifier("archive.detail.idle")
        case .loading:
            ProgressView("Loading email…")
                .accessibilityIdentifier("archive.detail.loading")
        case .loaded(let email):
            EmailDetailView(email: email)
                .accessibilityIdentifier("archive.detail.loaded")
        case .failed(_, let message):
            ArchiveLoadFailureView(message: message, retry: nil)
                .accessibilityIdentifier("archive.detail.failed")
        }
    }
}

// MARK: - States

struct ArchiveEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No emails yet",
            systemImage: "tray",
            description: Text("Import an archive to get started.")
        )
        .accessibilityIdentifier("archive.list.empty")
    }
}

struct ArchiveLoadFailureView: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text("Couldn't load").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry {
                Button("Try Again", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("archive.list.failure")
    }
}

struct ArchiveListLoadingFooter: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .accessibilityIdentifier("archive.list.pageLoading")
    }
}
