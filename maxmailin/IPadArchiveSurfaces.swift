//
//  IPadArchiveSurfaces.swift
//  maxmailin
//
//  Gate 1 iPad walk (2026-11-08) fixes that need a surface of their own:
//   - IPAD-06 (a): the latest import receipt as a sheet on iPad (the Mac has
//     the "Import Receipt" window), reachable where an import finishes, from
//     File ▸ Last Import Receipt and from Health ▸ Recovery.
//   - IPAD-06 (b): backup and restore through folders chosen in Files, with
//     the restore confirmation naming its counts (rule 4).
//   - IPAD-08: the "Clear & Start Fresh" confirmation names how many emails
//     and sources it clears before it runs (rule 4).
//

@testable import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - IPAD-06 (a): import receipt on iPad

/// Who asked for the latest import receipt. On the Mac the receipt is a
/// window; on iPad the main view presents `ImportReceiptSheet` while
/// `isPresented` is true. `importFinishedAt` drives the "View receipt"
/// banner shown when an import ends.
@MainActor
@Observable
final class ImportReceiptPresenter {
    static let shared = ImportReceiptPresenter()
    var isPresented = false
    /// When the last import finished in this session, until the banner is dismissed.
    var importFinishedAt: Date?

    func show() {
        importFinishedAt = nil
        isPresented = true
    }

    func importFinished(at date: Date = Date()) {
        importFinishedAt = date
    }
}

#if os(iOS)
/// The latest receipt in a sheet with a Done button.
struct ImportReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LatestImportReceiptView()
                .navigationTitle(String(localized: "Import Receipt"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
                // "Retry failed sources" hands the work to the main window; close the sheet so it can show progress.
                .onReceive(NotificationCenter.default.publisher(for: .retryImportSources)) { _ in dismiss() }
        }
        .accessibilityIdentifier("import.receipt.sheet")
    }
}

/// Hosts the receipt sheet and the "Import finished — View receipt" banner on
/// the main iPad/iPhone view.
struct ImportReceiptHost: ViewModifier {
    @State private var presenter = ImportReceiptPresenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if presenter.importFinishedAt != nil, !presenter.isPresented {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.tint)
                        Text("Import finished. The receipt says what was read, saved and skipped.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "View receipt")) { presenter.show() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("import.receipt.view")
                        Button {
                            presenter.importFinishedAt = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Dismiss"))
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .accessibilityIdentifier("import.receipt.banner")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: presenter.importFinishedAt)
            .sheet(isPresented: $presenter.isPresented) { ImportReceiptSheet() }
    }
}
#endif

#if os(iOS)
/// IPAD-10: the Settings sheet's navigation bar takes its own space (inline
/// title, visible bar background), so the floating Done button no longer sits
/// over the first row of Health or the other tabs.
struct IOSSettingsSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
#endif

// MARK: - IPAD-06 (b): backup and restore folders in Files

#if os(iOS)
/// The iOS side of LIFE-02: Files folder pickers for backup and restore, and
/// the restore confirmation with its counts. Attached to the backup row so
/// its pickers do not collide with the other pickers on the Health screen.
struct BackupFolderPickers: ViewModifier {
    @Binding var choosingBackupFolder: Bool
    @Binding var choosingRestoreFolder: Bool
    @Binding var verifiedBackup: ArchiveBackups.VerifiedBackup?
    @Binding var working: Bool
    @Binding var note: String?
    let reload: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                Color.clear
                    .fileImporter(isPresented: $choosingBackupFolder, allowedContentTypes: [.folder],
                                  allowsMultipleSelection: false) { result in
                        switch result {
                        case .success(let folders):
                            guard let parent = folders.first else { note = String(localized: "Backup cancelled."); return }
                            Task { @MainActor in
                                working = true; defer { working = false }
                                note = await ArchiveBackups.backUp(intoChosenFolder: parent)
                            }
                        case .failure(let error):
                            note = String(localized: "Backup failed: \(error.localizedDescription)")
                        }
                    } onCancellation: {
                        note = String(localized: "Backup cancelled.")
                    }
            )
            .background(
                Color.clear
                    .fileImporter(isPresented: $choosingRestoreFolder, allowedContentTypes: [.folder],
                                  allowsMultipleSelection: false) { result in
                        switch result {
                        case .success(let folders):
                            guard let folder = folders.first else { note = String(localized: "Restore cancelled."); return }
                            switch ArchiveBackups.verifyForRestore(folder) {
                            case .success(let verified): verifiedBackup = verified
                            case .failure(let refusal): note = refusal.message
                            }
                        case .failure(let error):
                            note = error.localizedDescription
                        }
                    } onCancellation: {
                        note = String(localized: "Restore cancelled.")
                    }
            )
            .alert(verifiedBackup.map { ArchiveBackups.restoreConfirmation(emails: $0.emails, files: $0.files, createdAt: $0.createdAt) } ?? "",
                   isPresented: Binding(get: { verifiedBackup != nil }, set: { if !$0 { verifiedBackup = nil } }),
                   presenting: verifiedBackup) { backup in
                Button(String(localized: "Restore"), role: .destructive) {
                    verifiedBackup = nil
                    Task { @MainActor in
                        working = true; defer { working = false }
                        note = await ArchiveBackups.restoreVerified(backup)
                        reload()
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    verifiedBackup = nil
                    note = String(localized: "Restore cancelled.")
                }
            } message: { _ in
                Text(ArchiveBackups.restoreExplanation)
            }
    }
}
#endif

// MARK: - IPAD-10: counted nouns that agree with their number

/// "1 email" / "2 emails" — so a count of one never reads "1 emails" on the
/// Health, backup and clear-archive screens.
enum CountPhrase {
    static func emails(_ n: Int) -> String { n == 1 ? String(localized: "1 email") : String(localized: "\(n) emails") }
    static func files(_ n: Int) -> String { n == 1 ? String(localized: "1 file") : String(localized: "\(n) files") }
    static func messages(_ n: Int) -> String { n == 1 ? String(localized: "1 message") : String(localized: "\(n) messages") }
    static func sources(_ n: Int) -> String { n == 1 ? String(localized: "1 imported source") : String(localized: "\(n) imported sources") }
}

// MARK: - IPAD-10: menu shortcuts the iPadOS system menu already owns

/// iPadOS builds its own File/Edit menus with ⌘O (Open), ⌘F (Find), ⌘A
/// (Select All) and ⇧⌘G (Find Previous). Registering the same keys on the
/// app's menu commands logged a `[MenuBuilder]` conflict on every launch, and
/// the system item won anyway. On iPadOS those four commands stay in the menu
/// without the duplicate key; on the Mac every documented shortcut is kept.
enum MenuShortcutPolicy {
    struct Binding: Hashable {
        let key: Character
        let shift: Bool
    }

    static let openArchive = Binding(key: "o", shift: false)
    static let find = Binding(key: "f", shift: false)
    static let selectAll = Binding(key: "a", shift: false)
    static let visualAnalytics = Binding(key: "g", shift: true)

    /// ⌘-key combinations iPadOS's own menus register.
    static let iPadSystemOwned: Set<Binding> = [openArchive, find, selectAll, visualAnalytics]

    static func registers(_ binding: Binding, onIPad: Bool) -> Bool {
        !(onIPad && iPadSystemOwned.contains(binding))
    }
}

extension View {
    /// A ⌘ (or ⇧⌘) menu shortcut that is left off where the system menu owns the same key.
    @ViewBuilder
    func menuShortcut(_ binding: MenuShortcutPolicy.Binding) -> some View {
        #if os(iOS)
        if MenuShortcutPolicy.registers(binding, onIPad: true) {
            keyboardShortcut(KeyEquivalent(binding.key), modifiers: binding.shift ? [.command, .shift] : .command)
        } else {
            self
        }
        #else
        keyboardShortcut(KeyEquivalent(binding.key), modifiers: binding.shift ? [.command, .shift] : .command)
        #endif
    }
}

// MARK: - IPAD-08: what "Clear & Start Fresh" clears

enum ClearArchiveConfirmation {
    /// What the archive holds right now, counted before the confirmation is shown.
    struct Counts: Equatable {
        var emails: Int?
        var sources: Int?
    }

    @MainActor
    static func count(archive: ArchiveDataService = .shared) async -> Counts {
        Counts(emails: try? await archive.unscopedCount(),
               sources: (try? await archive.sources())?.count)
    }

    /// Rule 4: the message names the affected count. An archive that could not
    /// be counted says so instead of hiding the number.
    static func message(_ counts: Counts) -> String {
        guard let emails = counts.emails else {
            return String(localized: "mailin could not count the emails in this archive. Clearing removes every email and returns to the welcome screen. You can re-import anytime.")
        }
        let emailPhrase = CountPhrase.emails(emails)
        guard let sources = counts.sources, sources > 0 else {
            return String(localized: "This clears \(emailPhrase) and returns to the welcome screen. You can re-import anytime.")
        }
        let sourcePhrase = CountPhrase.sources(sources)
        return String(localized: "This clears \(emailPhrase) from \(sourcePhrase) and returns to the welcome screen. You can re-import anytime.")
    }
}
