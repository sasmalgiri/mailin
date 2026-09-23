//
//  FourPageShell.swift
//  mailin
//
//  Plan tasks A1/A2 — the top-level four-page frame (directive §0–§6).
//
//  The rule this enforces visually: a customer who has enabled nothing sees
//  **no page chrome at all** — just the Archive, looking like an ordinary mail
//  app. The page switcher appears only once a second page is enabled, so the
//  four-page architecture costs a Page-1-only user nothing, on screen or
//  otherwise.
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
    @State private var router = PageRouter()

    var body: some View {
        VStack(spacing: 0) {
            // No chrome for a Page-1-only install.
            if modules.enabledModules.count > 1 {
                PageSwitcher(
                    pages: modules.enabledModules,
                    selection: router.selection,
                    onSelect: { router.select($0, in: modules) }
                )
                Divider()
            }
            page
        }
        .onAppear { router.reconcile(with: modules) }
        .onChange(of: modules.enabledModules) { _, _ in
            router.reconcile(with: modules)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch router.selection {
        case .archive:
            ContentView()
        case .aiInsights:
            // Page 2's own scope is the whole archive; narrowing happens inside
            // the page, not by inheriting Page 1's current filter.
            AIAssistantView(archiveScope: .all)
        case .professional:
            WorkCenterView()
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
    let onSelect: (AppModule) -> Void

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            ForEach(pages, id: \.rawValue) { page in
                Button {
                    onSelect(page)
                } label: {
                    Label(page.displayName, systemImage: icon(page))
                        .labelStyle(.titleAndIcon)
                        .font(Typography.caption1)
                        .padding(.horizontal, Spacing.xSmall)
                        .padding(.vertical, 4)
                        .background(
                            page == selection ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == selection ? [.isSelected] : [])
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
            pages: [.archive, .aiInsights, .professional],
            selection: .aiInsights,
            onSelect: { _ in }
        )
        Divider()
        PageNotBuiltView(
            module: .liveMail,
            detail: "Live Mail is planned for this release but is not implemented in this build."
        )
    }
    .frame(width: 620, height: 380)
}
#endif
