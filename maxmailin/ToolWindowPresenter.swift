@testable import ArchiveCore
//
//  ToolWindowPresenter.swift
//  maxmailin
//
//  Opens a tool in its OWN macOS window — movable, resizable, minimizable,
//  and able to sit beside the main window — instead of a sheet pinned over
//  it. One window per title: re-opening focuses the existing window.
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class ToolWindowPresenter {
    static let shared = ToolWindowPresenter()
    private var windows: [String: NSWindow] = [:]
    private var observers: [String: NSObjectProtocol] = [:]

    func open<Content: View>(
        title: String,
        size: CGSize = CGSize(width: 1020, height: 800),
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[title], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(size.width, screen.width * 0.92)
        let height = min(size.height, screen.height * 0.92)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 520)
        // A tool window is a new SwiftUI root: it does not inherit the main
        // window's environment, so the page registry and the ONE store
        // manager are attached here (never a second StoreManager), and the
        // window hosts its own purchase presenter so a locked action inside
        // it shows the purchase screen in this window, not behind it.
        window.contentView = NSHostingView(rootView: Self.windowRoot(content(), title: title))
        window.center()

        observers[title] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windows[title] = nil
                if let obs = self?.observers[title] {
                    NotificationCenter.default.removeObserver(obs)
                    self?.observers[title] = nil
                }
            }
        }
        windows[title] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The ONE way to build a secondary window's SwiftUI root. A new
    /// NSHostingView does not inherit the main window's environment, so the
    /// page registry and the single store manager are attached here, with
    /// the window's own purchase presenter. Order matters: the environment
    /// flows DOWN, so both objects go OUTSIDE the presenter (which reads the
    /// store) — the reverse crashed every tool window on 2026-10-04 with
    /// "No ObservableObject of type StoreManager found".
    static func windowRoot<Content: View>(_ content: Content, title: String) -> AnyView {
        var root = AnyView(content)
        if let store = StoreManager.live {
            root = AnyView(root.purchasePresenter(target: .window(title)).environmentObject(store))
        }
        if let modules = ModuleRegistry.live {
            root = AnyView(root.environment(modules))
        }
        return root
    }

    /// In-content Close buttons close the hosting window.
    func close(title: String) {
        windows[title]?.close()
    }

    /// Drop-in replacement for a sheet's isPresented binding: reads true,
    /// and setting it false closes the hosting window.
    static func closeBinding(title: String) -> Binding<Bool> {
        Binding(get: { true }, set: { if !$0 { Task { @MainActor in shared.close(title: title) } } })
    }
}
#endif
