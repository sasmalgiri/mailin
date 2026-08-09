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
        window.contentView = NSHostingView(rootView: content())
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
