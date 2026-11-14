@testable import ArchiveCore
import SwiftUI
import CryptoKit
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
        let panel = ManagedSavePanel()   // honours the organisation's export policy
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

// MARK: - Honest export (both platforms)

/// What actually happened to an export — so a button never reports success
/// (or writes an audit entry) for a file that was cancelled or failed.
enum ExportOutcome: Equatable {
    case saved(URL)      // macOS: written and read back intact
    case shared(URL)     // iOS: written, Share sheet shown
    case cancelled
    case failed(String)

    var url: URL? {
        switch self {
        case .saved(let u), .shared(let u): return u
        default: return nil
        }
    }
    var succeeded: Bool { url != nil }

    /// A one-line status for the button's screen.
    func message(_ what: String) -> String {
        switch self {
        case .saved(let u): return String(localized: "\(what) saved — \(u.lastPathComponent)")
        case .shared(let u): return String(localized: "\(what) ready to share — \(u.lastPathComponent)")
        case .cancelled: return String(localized: "\(what) not saved — cancelled.")
        case .failed(let why): return String(localized: "\(what) couldn't be saved: \(why)")
        }
    }
}

@MainActor
enum PlatformExport {
    /// macOS: save panel, write, then read back and compare (a file counts
    /// as exported only if it is really there, byte for byte).
    /// iOS: write to a temporary file and present the Share sheet.
    static func save(data: Data, suggestedName: String) -> ExportOutcome {
        // Enterprise: the organisation's export policy and the person's role.
        if let why = OrgPolicy.denial(.export) { return .failed(why) }
        #if os(macOS)
        let panel = ManagedSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try data.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == data else {
                return .failed(String(localized: "the saved file did not read back identical"))
            }
            return .saved(url)
        } catch {
            return .failed(error.localizedDescription)
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }
        return share(url)
        #endif
    }

    #if os(iOS)
    /// Presents the Share sheet for a file (or folder) already on disk.
    static func share(_ url: URL) -> ExportOutcome {
        if let why = OrgPolicy.denial(.export) { return .failed(why) }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return .failed(String(localized: "no window to share from"))
        }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(sheet, animated: true)
        return .shared(url)
    }

    /// IPAD-09 (rule 5): presents the Share sheet and waits for it to close, so
    /// the caller knows shared from cancelled — `.shared` only when an activity
    /// (Save to Files, AirDrop, …) completed, `.cancelled` when the sheet was
    /// dismissed without one. R1: returns exactly once on every path — a sheet
    /// that could not be shown is `.failed(reason)`, task cancellation is
    /// `.cancelled` (see `ExportHandoff`).
    static func shareAndWait(_ url: URL) async -> ExportOutcome {
        if let why = OrgPolicy.denial(.export) { return .failed(why) }
        return await ExportHandoff(presenter: ShareSheetHandoffPresenter()).run(url)
    }

    /// R1 (5): Save to Files — the system names the destination, so the saved
    /// bytes are read back and compared: `.saved` only when they match.
    static func saveToFilesAndWait(_ url: URL) async -> ExportOutcome {
        if let why = OrgPolicy.denial(.export) { return .failed(why) }
        return await ExportHandoff(presenter: FilesExportHandoffPresenter()).run(url)
    }
    #endif

    /// IPAD-09: the Share sheet's answer as an outcome — cancelled is never "shared".
    nonisolated static func shareOutcome(url: URL, completed: Bool, error: Error?) -> ExportOutcome {
        if let error { return .failed(error.localizedDescription) }
        return completed ? .shared(url) : .cancelled
    }

    static func save(text: String, suggestedName: String) -> ExportOutcome {
        save(data: Data(text.utf8), suggestedName: suggestedName)
    }

    /// 3.0 whole-scope exports: the file is STREAMED by `write` (never held
    /// in memory), then verified by re-hashing it in chunks against the
    /// SHA-256 the writer computed while writing. macOS: save panel first;
    /// iOS: temporary file, then the Share sheet.
    static func saveStreamed(suggestedName: String,
                             write: (URL) async throws -> ArchiveExportResult) async -> (ExportOutcome, ArchiveExportResult?) {
        if let why = OrgPolicy.denial(.export) { return (.failed(why), nil) }
        #if os(macOS)
        let panel = ManagedSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return (.cancelled, nil) }
        #else
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        #endif
        do {
            let result = try await write(destination)
            if result.cancelled { return (.cancelled, result) }
            if let expected = result.sha256Hex {
                guard let actual = fileSHA256(destination), actual == expected else {
                    return (.failed(String(localized: "the saved file did not read back identical")), result)
                }
            }
            #if os(macOS)
            return (.saved(destination), result)
            #else
            return (share(destination), result)
            #endif
        } catch is CancellationError {
            return (.cancelled, nil)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    /// Chunked SHA-256 of a file (flat memory).
    nonisolated static func fileSHA256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// RFC 4180 CSV field: always quoted, quotes doubled. Commas, newlines and
/// the commas inside RFC 2822 dates stay intact instead of shifting columns.
/// Formula-leading cells are neutralised so a spreadsheet won't execute them.
func csvField(_ value: String) -> String {
    var v = value
    if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
    return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

func csvRow(_ fields: [String]) -> String {
    fields.map(csvField).joined(separator: ",") + "\n"
}

// MARK: - Print Helper

enum PlatformPrinter {
    #if os(macOS)
    @MainActor
    static func printText(_ text: String) {
        guard OrgPolicy.confirmAllowed(.print) else { return }
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
        guard OrgPolicy.confirmAllowed(.print) else { return }
        let formatter = UISimpleTextPrintFormatter(text: text)
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
    #endif
}
