//
//  ArchiveLocationView.swift
//  mailin
//
//  B5's surface: where the archive lives, what it occupies, and how to put it
//  somewhere else.
//
//  Shows the CURRENT footprint from `StoragePlanner.archiveFootprint`, split
//  by tier, because "how big is my archive?" is the question this screen is
//  actually opened for — and because after the blob tier most of the bytes are
//  no longer inside the database file.
//
//  Behind `Capability.externalStorage`. When it is off the whole section is
//  hidden and nothing about the archive's location changes.
//

import SwiftUI

struct ArchiveLocationView: View {
    @Environment(ModuleRegistry.self) private var modules

    @State private var footprint: StoragePlanner.ArchiveFootprint?
    @State private var chosen: ArchiveLocation?
    @State private var verdict: ArchiveLocationVerdict?
    @State private var showPicker = false
    /// S4: messages stored from their headers only. The store has been able to
    /// count these since the locator table existed, and nothing asked — so an
    /// archive could hold messages with no searchable body and offer the user
    /// no way to find that out after the import that created them. The receipt
    /// reports it per run; this reports it for the archive as it stands.
    @State private var deferredBodies: Int?

    private let store = ArchiveLocationStore(url: ArchiveLocationStore.productionURL)

    private var currentDirectory: URL {
        chosen?.url ?? SQLiteEmailStore.productionDirectory.deletingLastPathComponent()
    }

    var body: some View {
        Form {
            currentSection

            if modules.isOn(.externalStorage) {
                chooseSection
            } else {
                Section {
                    Label("Switch on “Archive on another volume” in Settings ▸ Modules ▸ Features to choose a different location.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    // MARK: Current

    private var currentSection: some View {
        Section {
            LabeledContent("Folder") {
                Text(currentDirectory.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            Button("Show in Finder") { revealInFinder() }
                .controlSize(.small)

            if let footprint {
                LabeledContent("Total", value: bytes(footprint.total))
                LabeledContent("Database", value: bytes(footprint.databaseBytes))
                // Called out separately because after the blob tier this is
                // where most of a large archive's bytes are, and a "database
                // size" that omitted it would understate the archive badly.
                LabeledContent("Message bodies", value: bytes(footprint.blobBytes))
                LabeledContent("Search index", value: bytes(footprint.indexBytes))
                if footprint.journalBytes > 0 {
                    LabeledContent("Journal", value: bytes(footprint.journalBytes))
                }

                if let deferredBodies, deferredBodies > 0 {
                    Divider()
                    Label("""
                        \(deferredBodies) message\(deferredBodies == 1 ? "" : "s") \
                        \(deferredBodies == 1 ? "was" : "were") stored from headers only, because \
                        \(deferredBodies == 1 ? "it was" : "they were") too large to read fully. \
                        Their original bytes are recorded, but their text is not searchable.
                        """, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Measuring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Archive location").font(.headline)
        }
    }

    // MARK: Choose

    private var chooseSection: some View {
        Section {
            Button("Choose a folder…") { showPicker = true }
                .fileImporter(isPresented: $showPicker,
                              allowedContentTypes: [.folder],
                              allowsMultipleSelection: false) { result in
                    handle(result)
                }

            if let verdict, let message = verdict.message {
                Label(message, systemImage: verdict.isUsable
                      ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(verdict.isUsable ? .orange : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if chosen != nil {
                Button("Use the default location again") {
                    store.clear()
                    chosen = nil
                    verdict = nil
                    refresh()
                }
                .controlSize(.small)
            }
        } header: {
            Text("Move the archive").font(.headline)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(ArchiveLocationStore.moveIsNotAutomated)
                Text("""
                    Cloud folders are refused, not warned about: a database in iCloud or \
                    Dropbox can be corrupted, because its main file and its write-ahead log \
                    sync independently. Network volumes are refused for the same class of \
                    reason — their file locking is unreliable.
                    """)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func handle(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let directory = urls.first else { return }
        let judgement = ArchiveLocationPolicy.verdict(for: directory)
        verdict = judgement
        guard judgement.isUsable else { return }

        let location = ArchiveLocation(
            path: directory.path,
            bookmark: ArchiveLocationStore.bookmark(for: directory),
            recordedAt: Date())
        store.save(location)
        chosen = location
        refresh()
    }

    private func refresh() {
        chosen = store.load()
        let directory = SQLiteEmailStore.productionDirectory
        Task.detached(priority: .utility) {
            let measured = StoragePlanner.archiveFootprint(storeDirectory: directory)
            await MainActor.run { footprint = measured }
        }
        Task { @MainActor in
            // Best effort: a store that cannot be opened is not a reason to
            // fail the storage screen, and nil reads as "not counted" rather
            // than as zero.
            deferredBodies = try? await SQLiteEmailStore.shared.deferredBodyCount()
        }
    }

    private func revealInFinder() {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([currentDirectory])
        #endif
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
