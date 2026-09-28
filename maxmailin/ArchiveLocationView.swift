@testable import ArchiveCore
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
    // B5: the automated move.
    @State private var relocationPlan: RelocationPlan?
    @State private var relocationProgress: (done: Int64, total: Int64)?
    @State private var relocationReceipt: RelocationReceipt?
    @State private var relocationError: String?
    @State private var isRelocating = false
    @State private var confirmDeleteRetired = false
    @State private var retiredCopy: URL?
    @State private var retiredBytes: Int64 = 0
    /// F01: a verified move exists but this run still has the old copy open.
    @State private var moveAwaitsRelaunch = false

    private let store = ArchiveLocationStore(url: ArchiveLocationStore.productionURL)

    /// The root actually in use — chosen, relocated or default.
    private var currentDirectory: URL { ArchiveLayout.productionRoot }

    var body: some View {
        Form {
            currentSection

            if modules.isOn(.externalStorage) {
                chooseSection
                if relocationPlan != nil || isRelocating || relocationReceipt != nil || relocationError != nil {
                    moveSection
                }
                if retiredCopy != nil {
                    retiredSection
                } else if moveAwaitsRelaunch {
                    relaunchSection
                }
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

            if ArchiveLayout.isShowingFallbackCopy {
                Label("""
                    The archive was moved to another volume that is not connected right now. \
                    You are seeing the copy left on this Mac, which may be behind. Reconnect the \
                    volume and relaunch to use the moved archive.
                    """, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("archive.location.fallbackBanner")
            }

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

    // MARK: Move (B5)

    private var moveSection: some View {
        Section {
            if let plan = relocationPlan, relocationReceipt == nil {
                LabeledContent("Archive", value: bytes(plan.archiveBytes) + " in \(plan.fileCount) files")
                LabeledContent("Free there", value: bytes(plan.freeBytes))
                LabeledContent("Destination") {
                    Text(plan.destinationRoot.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2).truncationMode(.middle)
                }
                if let why = plan.refusalReason {
                    Label(why, systemImage: "xmark.octagon")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if ImportQueue.shared.isActive {
                    Label("An import is running. Let it finish or cancel it before moving the archive.", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                } else if isRelocating, let progress = relocationProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(bytes(progress.done)) of \(bytes(progress.total)) copied — verifying follows")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Button("Move the archive there now") { Task { await relocate(plan) } }
                        .buttonStyle(.borderedProminent)
                        .help("Copies the database, message bodies and search index, verifies every file and the row count, then records the new location. The copy on this Mac stays until you delete it.")
                        .accessibilityIdentifier("archive.location.moveNow")
                }
            }
            if let receipt = relocationReceipt {
                Label(receipt.summary, systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("archive.location.moveReceipt")
            }
            if let relocationError {
                Label(relocationError, systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Move the existing archive").font(.headline)
        } footer: {
            Text("""
                The move is a verified copy: byte counts for every file, the database hash, and \
                a fresh open of the copy that must report the same number of messages. Nothing on \
                this Mac is removed by the move. If the new volume is ever disconnected, mailin \
                falls back to the copy here and says so.
                """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Shown between a verified move and the relaunch. The copy on this Mac is
    /// still the one open, so it is not offered for deletion yet.
    private var relaunchSection: some View {
        Section {
            Label("""
                The archive has been copied and verified. This Mac's copy is still the one in use \
                until you quit and relaunch mailin. After the relaunch you can delete the copy here.
                """, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("archive.location.relaunchToFinish")
        } header: {
            Text("Copy on this Mac").font(.headline)
        }
    }

    private var retiredSection: some View {
        Section {
            Text("A copy of the archive from before the move is still on this Mac (\(bytes(retiredBytes))). The moved archive is the one in use.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete the copy on this Mac…", role: .destructive) { confirmDeleteRetired = true }
                .controlSize(.small)
                .accessibilityIdentifier("archive.location.deleteRetired")
                .confirmationDialog("Delete the copy on this Mac?", isPresented: $confirmDeleteRetired, titleVisibility: .visible) {
                    Button("Delete \(bytes(retiredBytes))", role: .destructive) {
                        do { try ArchiveRelocator.deleteRetiredCopy() } catch { relocationError = error.localizedDescription }
                        refresh()
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("Only the moved archive will remain. If its volume is disconnected, mailin will have nothing to show until it is reconnected.")
                }
        } header: {
            Text("Copy on this Mac").font(.headline)
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
        // With an archive already here, choosing a folder proposes the move
        // rather than silently recording a location that would only apply to
        // a NEW archive.
        if ArchiveLayout.hasArchive(at: ArchiveLayout.productionRoot) {
            relocationReceipt = nil
            relocationError = nil
            relocationPlan = ArchiveRelocator.plan(destinationVolume: directory)
        } else {
            store.save(location)
        }
        chosen = location
        refresh()
    }

    private func relocate(_ plan: RelocationPlan) async {
        isRelocating = true
        relocationError = nil
        relocationProgress = (0, plan.archiveBytes)
        defer { isRelocating = false }
        do {
            let receipt = try await ArchiveRelocator.perform(plan, store: SQLiteEmailStore.shared, fts: .shared,
                                                             progress: { done, total in
                                                                 Task { @MainActor in relocationProgress = (done, total) }
                                                             })
            relocationReceipt = receipt
            relocationPlan = nil
            refresh()
        } catch {
            relocationError = error.localizedDescription
        }
    }

    private func refresh() {
        chosen = store.load()
        retiredCopy = ArchiveRelocator.retiredCopyOnThisMac()
        moveAwaitsRelaunch = ArchiveRelocator.moveAwaitsRelaunch()
        if let retiredCopy {
            let measured = ArchiveRelocator.measure([ArchiveLayout.sqliteDirectory(under: retiredCopy),
                                                     ArchiveLayout.ftsDirectory(under: retiredCopy)])
            retiredBytes = measured.bytes
        }
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
