//
//  NavigationHistory.swift
//  mailin
//
//  Back / Forward across the three pages and the sections inside them
//  (owner, 2026-10-09: "why is there no back and forth button beside the
//  three page names?"). One history for the window: pages report where
//  they are, the strip's ‹ › buttons move through it, and the page being
//  returned to applies the section it was on.
//

import SwiftUI
import Observation

/// Where the user is: a page and, when the page has sections, the section
/// (Archive: "home", a hub destination's raw value; AI Insights: the tab;
/// Professional: the Work Center tab index).
struct NavigationLocation: Equatable, Sendable {
    var page: AppModule
    var section: String?
}

@MainActor
@Observable
final class NavigationHistory {
    private(set) var entries: [NavigationLocation] = []
    private(set) var index: Int = -1
    /// The location a page must show because Back or Forward asked for it;
    /// the page clears it once applied. While it is set, nothing is recorded.
    var pending: NavigationLocation?

    static let limit = 200

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }
    var current: NavigationLocation? { entries.indices.contains(index) ? entries[index] : nil }

    /// Records the place the user is now. The same place twice is one entry
    /// (pages report on appear and on every change); a page-only entry
    /// followed by that page's section is the same place, refined; anything
    /// forward of the current position is dropped, as in a browser.
    func record(_ location: NavigationLocation) {
        guard pending == nil else { return }
        if current == location { return }
        if let cur = current, cur.page == location.page, cur.section == nil {
            entries[index] = location
            return
        }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(location)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    func record(page: AppModule, section: String?) {
        record(NavigationLocation(page: page, section: section))
    }

    /// For a page that moves itself somewhere without the user asking (the
    /// Archive page landing on the inbox once an archive is open): the place
    /// it left is not one to go Back to, so it is replaced, not stacked.
    func replaceCurrent(page: AppModule, section: String?) {
        guard pending == nil else { return }
        let location = NavigationLocation(page: page, section: section)
        guard let cur = current, cur.page == page else { return record(location) }
        entries[index] = location
        // Replacing may make it the same as the entry before it.
        if index > 0, entries[index - 1] == location {
            entries.remove(at: index)
            index -= 1
        }
    }

    @discardableResult
    func goBack() -> NavigationLocation? {
        guard canGoBack else { return nil }
        index -= 1
        pending = entries[index]
        return pending
    }

    @discardableResult
    func goForward() -> NavigationLocation? {
        guard canGoForward else { return nil }
        index += 1
        pending = entries[index]
        return pending
    }
}

// MARK: - Environment (optional: previews and tool windows have no history)

private struct NavigationHistoryKey: EnvironmentKey {
    static let defaultValue: NavigationHistory? = nil
}

extension EnvironmentValues {
    var navigationHistory: NavigationHistory? {
        get { self[NavigationHistoryKey.self] }
        set { self[NavigationHistoryKey.self] = newValue }
    }
}

// MARK: - A page's section, kept in step with the history

/// Reports `current` whenever it changes (and on appear), and applies the
/// section Back/Forward asks for through `apply`. Does nothing when no
/// history is in the environment.
struct NavigationSectionModifier: ViewModifier {
    @Environment(\.navigationHistory) private var history
    /// nil: this instance is not a remembered place (a view reused inside
    /// another page), so it neither records nor applies.
    let page: AppModule?
    let current: String?
    let apply: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let page else { return }
                // Apply first: a page arriving through Back must not record
                // its default section as a new place. `current` here is still
                // the default (apply takes effect on the next update), so when
                // a section was applied there is nothing to record.
                if applyPending() { return }
                // Already the current page (the page placed itself first, or
                // it was rebuilt in place): nothing new to record.
                if history?.current?.page == page { return }
                history?.record(page: page, section: current)
            }
            .onChange(of: current) { _, newValue in
                guard let page else { return }
                history?.record(page: page, section: newValue)
            }
            .onChange(of: history?.pending) { _, _ in
                applyPending()
            }
    }

    /// Returns true when a pending location for this page was consumed.
    @discardableResult
    private func applyPending() -> Bool {
        guard let page, let history, let target = history.pending, target.page == page else { return false }
        history.pending = nil
        if target.section != current { apply(target.section) }
        return true
    }
}

extension View {
    /// Makes `current` the section Back/Forward remembers for `page`.
    func navigationSection(_ page: AppModule?, current: String?, apply: @escaping (String?) -> Void) -> some View {
        modifier(NavigationSectionModifier(page: page, current: current, apply: apply))
    }
}
