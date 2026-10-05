@testable import ArchiveCore
//
//  FourPageShell.swift
//  mailin
//
//  Plan tasks A1/A2 — the top-level four-page frame (directive §0–§6).
//
//  Shape (owner decision, 2026-09-24): every page the edition ships has a tab
//  that is always visible, so the app's structure is discoverable, and Archive
//  is the page shown by default. (Owner, 2026-09-28: a page compiled out of the
//  edition gets no tab — the no-network build shows three.)
//  Clicking an INACTIVE tab does not switch to it — it opens that page's
//  feature matrix and asks whether to turn the page on. Nothing about an
//  inactive page runs until the user agrees (§3.3 R2), so a visible tab costs
//  a Page-1-only user nothing but a tab.
//
//  (This supersedes the earlier reading, where chrome was hidden entirely for a
//  Page-1-only install.)
//
//  Each page hosts its own experience. Subwindows, sheets and tabs inside a
//  page are not extra top-level pages.
//

import SwiftUI
import Observation

/// Which page is showing. Selection is validated against the registry, so a
/// page that gets switched off (by the user or by an organization policy)
/// cannot remain on screen.
@MainActor
@Observable
final class PageRouter {
    private static let defaultsKey = "selectedTopLevelPage"

    private(set) var selection: AppModule

    init(initial: AppModule? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let initial {
            self.selection = initial
        } else if let raw = defaults.string(forKey: Self.defaultsKey),
                  let restored = AppModule(rawValue: raw) {
            self.selection = restored
        } else {
            self.selection = .archive
        }
    }

    private let defaults: UserDefaults

    /// Switches page. Refuses a page that is not enabled — the switcher should
    /// never offer one, and a stale keyboard shortcut or restored state must
    /// not be able to open a disabled page either.
    @discardableResult
    func select(_ page: AppModule, in registry: ModuleRegistry) -> Bool {
        guard registry.isEnabled(page) else { return false }
        selection = page
        defaults.set(page.rawValue, forKey: Self.defaultsKey)
        return true
    }

    /// Re-checks the current selection after module state changes: if the page
    /// on screen has been switched off, fall back to Archive, which is always
    /// available.
    func reconcile(with registry: ModuleRegistry) {
        guard !registry.isEnabled(selection) else { return }
        selection = .archive
        defaults.set(AppModule.archive.rawValue, forKey: Self.defaultsKey)
    }
}

// MARK: - Shell

struct FourPageShell: View {
    @Environment(ModuleRegistry.self) private var modules
    @EnvironmentObject private var storeManager: StoreManager
    @State private var router = PageRouter()
    /// The page whose activation sheet is showing. Set by tapping an inactive
    /// tab: nothing is enabled until the user reads the matrix and agrees.
    @State private var pendingActivation: AppModule?

    var body: some View {
        VStack(spacing: 0) {
            // Every page this edition ships has a tab, so the app's shape is
            // discoverable. An inactive tab does not switch to its page: it
            // asks first, showing that page's feature matrix. A page compiled
            // out of the edition (Live Mail in the no-network build) has no
            // tab at all — nothing behind it exists to turn on.
            HStack(spacing: 0) {
                PageSwitcher(
                    pages: modules.shippedModules,
                    selection: router.selection,
                    isEnabled: { modules.isEnabled($0) },
                    isLocked: { !modules.activation($0).isUserSwitchable },
                    onSelect: { page in
                        if modules.isEnabled(page) {
                            router.select(page, in: modules)
                        } else {
                            pendingActivation = page
                        }
                    }
                )
                // The current-plan control sits on the page strip, so it is
                // on every page and every platform without crowding a page's
                // own toolbar. Not built in the enterprise edition (no IAP).
                #if !ENTERPRISE_EDITION
                PlanBadgeButton()
                    .padding(.trailing, Spacing.xSmall)
                #endif
            }
            // The strip must always be on screen: it is the only way between
            // pages. On a short Mac window a tall page (AI Insights ▸ Ask)
            // pushed it above the window's top edge and the user could not
            // get back to Archive (found 2026-10-05). The strip keeps its
            // height and wins layout; the page takes what is left, clipped.
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Divider()
            page
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .onAppear {
            router.reconcile(with: modules)
            #if DEBUG
            storeManager.applyDebugLaunchOverride()
            #endif
        }
        .onChange(of: modules.enabledModules) { _, _ in
            router.reconcile(with: modules)
        }
        // I5: the one place a cloud AI request asks before anything leaves
        // the device. Attached at the root so any page's request can ask.
        .modifier(CloudAIConsentSheetModifier())
        // The main window's paywall presenter. Every purchase gate raises a
        // request on the one StoreManager; this root shows the requests aimed
        // at the main window, whichever page is on screen. Settings and tool
        // windows host their own presenter for requests raised there.
        .purchasePresenter(target: .main)
        .sheet(item: $pendingActivation) { module in
            PageActivationSheet(
                module: module,
                activation: modules.activation(module),
                hasProfessional: storeManager.isProfessional,
                onEnable: {
                    try? modules.enable(module)
                    router.select(module, in: modules)
                    pendingActivation = nil
                },
                onCancel: { pendingActivation = nil }
            )
        }
    }

    @ViewBuilder
    private var page: some View {
        switch router.selection {
        case .archive:
            ContentView()
        case .aiInsights:
            // Page 2's own scope is the whole archive; narrowing happens inside
            // the page (its scope bar), not by inheriting Page 1's filter.
            AIInsightsPageView()
        case .professional:
            ProfessionalPageView()
        case .liveMail:
            PageNotBuiltView(
                module: .liveMail,
                detail: """
                    Live Mail is planned for this release but is not implemented in \
                    this build. Nothing here connects to a mail server yet, and no \
                    account can be added.
                    """
            )
        }
    }
}

// MARK: - Switcher

private struct PageSwitcher: View {
    let pages: [AppModule]
    let selection: AppModule
    let isEnabled: (AppModule) -> Bool
    let isLocked: (AppModule) -> Bool
    let onSelect: (AppModule) -> Void

    var body: some View {
        // Compact widths (iPhone): the three names do not fit side by side at
        // heading size, and a wrapped "Professio-nal Workflow-s" is worse than
        // a scroll. Names never wrap; the strip scrolls sideways if it must.
        ScrollView(.horizontal, showsIndicators: false) {
            switcherRow
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var switcherRow: some View {
        HStack(spacing: Spacing.xxSmall) {
            ForEach(pages, id: \.rawValue) { page in
                // Owner, 2026-09-30: these are the PAGE names, so they read
                // at heading size, and a page that is on looks different
                // from one that is off — filled tint and a green dot when on;
                // dimmed text with an "Off" marker (or a lock) when not.
                let on = isEnabled(page)
                let current = page == selection && on
                Button {
                    onSelect(page)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(page))
                            .font(.system(size: 15, weight: .semibold))
                        Text(page.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if isLocked(page) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                        } else if on {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("On")
                        } else {
                            Text("Off")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(AppColors.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    .foregroundColor(on ? (current ? .accentColor : .primary) : AppColors.secondary.opacity(0.8))
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, 7)
                    .background(
                        current
                            ? Color.accentColor.opacity(0.16)
                            : (on ? AppColors.secondary.opacity(0.08) : .clear),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(on ? Color.clear : AppColors.secondary.opacity(0.25),
                                          style: StrokeStyle(lineWidth: 1, dash: on ? [] : [3, 3]))
                    )
                }
                .buttonStyle(.plain)
                .help(isEnabled(page)
                      ? page.displayName
                      : "\(page.displayName) is off — click to see what it includes")
                .accessibilityAddTraits(page == selection ? [.isSelected] : [])
                .accessibilityHint(isEnabled(page) ? "" : String(localized: "Off. Opens a summary before turning it on."))
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 4)
    }

    private func icon(_ page: AppModule) -> String {
        switch page {
        case .archive: return "archivebox"
        case .aiInsights: return "sparkles"
        case .professional: return "briefcase"
        case .liveMail: return "envelope.badge"
        }
    }
}

// MARK: - Honest placeholder

/// Shown for a page that is enabled but genuinely not implemented in this
/// build. Saying so plainly is better than an empty screen that looks broken,
/// and better than a demo that implies a capability that does not exist.
struct PageNotBuiltView: View {
    let module: AppModule
    let detail: String

    var body: some View {
        VStack(spacing: Spacing.small) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundColor(AppColors.secondary)
            Text("\(module.displayName) is not built yet")
                .font(Typography.title3)
            Text(detail)
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("You can turn this page off again in Settings ▸ Modules.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#if DEBUG
#Preview("Page switcher — three pages on") {
    VStack(spacing: 0) {
        PageSwitcher(
            pages: AppModule.allCases,
            selection: .archive,
            isEnabled: { $0 == .archive },
            isLocked: { _ in false },
            onSelect: { _ in }
        )
        Divider()
        PageNotBuiltView(
            module: .liveMail,
            detail: String(localized: "Live Mail is planned for this release but is not implemented in this build.")
        )
    }
    .frame(width: 620, height: 380)
}
#endif
