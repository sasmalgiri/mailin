import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Platform Type Aliases

#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

// MARK: - PlatformImage Helpers

extension PlatformImage {
    var cgImageCompat: CGImage? {
        #if os(macOS)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}

// MARK: - Clipboard

enum PlatformClipboard {
    static func copyString(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - URL Opening

enum PlatformURLOpener {
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - App Icon

enum PlatformApp {
    @MainActor
    static var appIconImage: Image {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
        #else
        if let icon = Bundle.main.appIcon {
            Image(uiImage: icon)
        } else {
            Image(systemName: "app.fill")
        }
        #endif
    }

    @MainActor
    static func activate() {
        #if os(macOS)
        NSApp.activate()
        #endif
    }
}

#if os(iOS)
extension Bundle {
    var appIcon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last {
            return UIImage(named: name)
        }
        return nil
    }
}
#endif

// MARK: - File Save (macOS imperative panels)

#if os(macOS)
import UniformTypeIdentifiers

@MainActor
enum PlatformFileSaver {
    static func savePanel(suggestedName: String, allowedTypes: [UTType]? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let types = allowedTypes {
            panel.allowedContentTypes = types
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func saveText(_ text: String, suggestedName: String) -> Bool {
        guard let url = savePanel(suggestedName: suggestedName) else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static func saveData(_ data: Data, suggestedName: String) -> Bool {
        guard let url = savePanel(suggestedName: suggestedName) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
enum PlatformFileOpener {
    static func openPanel(title: String, allowedTypes: [UTType], allowsMultiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
#endif

// MARK: - Share Sheet (iOS file sharing)

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
enum PlatformFileSaver {
    static func tempFileURL(name: String, data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func tempFileURL(name: String, text: String) -> URL? {
        guard let data = text.data(using: .utf8) else { return nil }
        return tempFileURL(name: name, data: data)
    }
}
#endif

// MARK: - Print Helper

enum PlatformPrinter {
    #if os(macOS)
    @MainActor
    static func printText(_ text: String) {
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        printView.string = text
        printView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let printOp = NSPrintOperation(view: printView)
        printOp.printInfo.horizontalPagination = .fit
        printOp.printInfo.verticalPagination = .automatic
        printOp.runModal(for: NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
    #else
    @MainActor
    static func printText(_ text: String) {
        let formatter = UISimpleTextPrintFormatter(text: text)
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
    #endif
}
