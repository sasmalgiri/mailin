@testable import ArchiveCore
//
//  CrashSafety.swift
//  maxmailin
//
//  The user-facing half of crash isolation (SCALE_TODO_3_0.md §3-M2, §3-S6):
//
//   • EngineTripBanner — shown once after an engine was switched off because
//     the previous launch stopped inside it.
//   • SafeMode — if the app stops twice in a row within the first seconds after
//     launch, the next launch starts in Safe Mode: no background jobs, no 3.0
//     engines, and a banner offering Restore snapshot / Rebuild search index /
//     Copy diagnostics. Nothing here repairs anything on its own — every
//     recovery action is the user's choice, in the foreground (Apple's advice:
//     automatic "fixing" does more damage than the original fault).
//

import SwiftUI

// MARK: - Engine trip banner

struct EngineTripBanner: View {
    @State private var center = EngineTripCenter.shared
    @State private var copied = false

    var body: some View {
        if !center.newlyTripped.isEmpty {
            HStack(alignment: .top, spacing: Spacing.small) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("mailin stopped unexpectedly last time while a new engine was running")
                        .font(Typography.callout).fontWeight(.semibold)
                    Text("Switched off and replaced by the previous engine: \(center.newlyTripped.map(\.displayName).joined(separator: ", ")). Your data was not changed. You can switch it back on in Settings ▸ Modules.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(copied ? String(localized: "Copied") : String(localized: "Copy diagnostics")) {
                    PlatformClipboard.copyString(center.diagnosticsText())
                    copied = true
                }
                .controlSize(.small)
                Button { center.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(Spacing.small)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Safe Mode

@MainActor
@Observable
final class SafeMode {
    static let shared = SafeMode()

    nonisolated private static let unsettledLaunchesKey = "safeMode.unsettledLaunches"
    private static let settleDelay: Duration = .seconds(20)

    /// Decided once in the app's `init` (before any task or view can start
    /// background work), from the launch counter.
    nonisolated(unsafe) private static var decidedAtLaunch = false
    private var armed = false

    /// True for this launch only. Never persisted as "on" — the next normal
    /// launch leaves it automatically.
    private(set) var isActive = SafeMode.decidedAtLaunch
    private(set) var actionNote: String?

    /// Call at the very start of the app (before UI): counts launches that
    /// have not yet "settled" (stayed up for `settleDelay`), and decides Safe
    /// Mode: two earlier launches that never settled, plus this one.
    nonisolated static func recordLaunchStart() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: unsettledLaunchesKey) + 1
        defaults.set(count, forKey: unsettledLaunchesKey)
        decidedAtLaunch = count >= 3
    }

    /// Logs a Safe Mode launch and arms the "settled" timer that resets the
    /// counter once this launch has stayed up. Idempotent.
    func evaluateAtLaunch(registry: ModuleRegistry) {
        guard !armed else { return }
        armed = true
        if isActive {
            ForensicManager.shared.logAction(
                "Started in Safe Mode",
                detail: "The previous launches stopped within \(Int(Self.settleDelay.components.seconds)) seconds; background work and 3.0 engines are paused for this launch")
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            UserDefaults.standard.set(0, forKey: Self.unsettledLaunchesKey)
        }
    }

    /// Whether background work and 3.0 engines may run this launch.
    var allowsBackgroundWork: Bool { !isActive }

    func leave() {
        isActive = false
        actionNote = nil
    }

    func note(_ text: String) { actionNote = text }
}

struct SafeModeBanner: View {
    @State private var safeMode = SafeMode.shared
    @State private var working = false

    var body: some View {
        if safeMode.isActive {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                HStack(alignment: .top, spacing: Spacing.small) {
                    Image(systemName: "lifepreserver.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safe Mode").font(Typography.callout).fontWeight(.semibold)
                        Text("mailin stopped twice right after starting. Background work and the new 3.0 engines are paused for this launch; your archive is untouched. Choose what to do — nothing runs on its own.")
                            .font(Typography.caption1).foregroundColor(AppColors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: Spacing.small) {
                    Button(String(localized: "Restore last snapshot…")) {
                        Task { @MainActor in
                            working = true
                            defer { working = false }
                            safeMode.note(await ArchiveSnapshots.restoreLatestInteractively())
                        }
                    }
                    .disabled(working || ArchiveSnapshots.latest() == nil)
                    Button(String(localized: "Rebuild search index")) {
                        Task { @MainActor in
                            working = true
                            defer { working = false }
                            safeMode.note(await SafeModeActions.rebuildSearchIndex())
                        }
                    }
                    .disabled(working)
                    Button(String(localized: "Copy diagnostics")) {
                        PlatformClipboard.copyString(EngineTripCenter.shared.diagnosticsText())
                        safeMode.note(String(localized: "Diagnostics copied."))
                    }
                    Button(String(localized: "Continue normally")) { safeMode.leave() }
                }
                .controlSize(.small)
                if let note = safeMode.actionNote {
                    Text(note).font(Typography.caption2).foregroundColor(AppColors.secondary)
                }
            }
            .padding(Spacing.small)
            .background(Color.orange.opacity(0.12))
        }
    }
}

enum SafeModeActions {
    /// Rebuilds the full-text index from the stored emails (the archive itself
    /// is not modified).
    @MainActor
    static func rebuildSearchIndex() async -> String {
        do {
            try await ArchiveDataService.shared.rebuildSearchIndex()
            return String(localized: "Search index rebuilt.")
        } catch {
            return String(localized: "The search index couldn't be rebuilt: \(error.localizedDescription)")
        }
    }
}
