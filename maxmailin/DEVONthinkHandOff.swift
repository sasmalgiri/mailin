//
//  DEVONthinkHandOff.swift
//  maxmailin
//
//  E2 (FINAL_TODO_3_0_MAJOR.md Phase E): work alongside DEVONthink instead of replacing it.
//
//  Send to DEVONthink — the emails go through the normal .eml export run (pre-flight, free-tier
//  cap, receipt, resume, bounded memory), into a folder of mailin's own; when the run ends the
//  .eml files are opened with DEVONthink through Launch Services, which imports them by the
//  user's own Import setting (Global Inbox or a chosen group). No Apple Events, so nothing is
//  needed beyond the sandbox. Without DEVONthink the folder is shown in Finder instead, and the
//  receipt says which happened.
//
//  Email links — mailin://email/<uuid> opens that email in mailin; DEVONthink, Notes or any app
//  can store the link. A link to an email that is not in this archive says so.
//

import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DEVONthinkHandOff {
    /// Capability `.devonthinkHandOff`, pushed by CapabilityWiring.
    nonisolated(unsafe) static var isEnabled = false

    /// DEVONthink 4, then DEVONthink 3. Any other app whose identifier starts with the
    /// prefix and opens .eml is accepted too (editions and future versions).
    static let bundleIdentifiers = ["com.devon-technologies.think", "com.devon-technologies.think3"]
    static let bundlePrefix = "com.devon-technologies.think"

    /// Where hand-off folders are written: mailin's own caches, one folder per send.
    static func handOffRoot(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("DEVONthink hand-off", isDirectory: true)
    }

    /// A new, empty folder for one send, named so DEVONthink shows where the files came from.
    static func newHandOffFolder(root: URL = handOffRoot(), now: Date = Date(),
                                 fileManager: FileManager = .default) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = root.appendingPathComponent("mailin \(formatter.string(from: now))", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes hand-off folders older than `age`; DEVONthink has imported (copied) them by then.
    @discardableResult
    static func prune(root: URL = handOffRoot(), olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = Date(),
                      fileManager: FileManager = .default) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return 0 }
        var removed = 0
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if now.timeIntervalSince(created) > age, (try? fileManager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }

    /// Every .eml the export wrote, in nested year folders too, in path order; nothing else
    /// (the export manifest and attachment folders stay behind).
    static func emlFiles(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "eml" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// What happened to the files — the receipt and the user are told which.
    enum Delivery: Equatable {
        case opened(appName: String, files: Int)
        case revealedInFinder(files: Int)          // DEVONthink not installed
        case failed(message: String, files: Int)   // DEVONthink refused; folder shown in Finder
        case nothingToSend

        var summary: String {
            switch self {
            case .opened(let app, let files):
                return String(localized: "Sent \(files) emails to \(app)")
            case .revealedInFinder(let files):
                return String(localized: "DEVONthink is not installed; \(files) .eml files are shown in Finder")
            case .failed(let message, let files):
                return String(localized: "DEVONthink could not open the \(files) files (\(message)); they are shown in Finder")
            case .nothingToSend:
                return String(localized: "No emails were written, so nothing was sent to DEVONthink")
            }
        }
    }

    #if os(macOS)
    /// DEVONthink's location, or nil when it is not installed.
    static func applicationURL(workspace: NSWorkspace = .shared) -> URL? {
        for id in bundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }
        }
        if let eml = UTType(filenameExtension: "eml") {
            for url in workspace.urlsForApplications(toOpen: eml)
            where (Bundle(url: url)?.bundleIdentifier ?? "").hasPrefix(bundlePrefix) {
                return url
            }
        }
        return nil
    }

    /// Opens the folder's .eml files with DEVONthink (or shows them in Finder).
    @MainActor
    static func deliver(folder: URL, workspace: NSWorkspace = .shared) async -> Delivery {
        let files = emlFiles(in: folder)
        guard !files.isEmpty else { return .nothingToSend }
        guard let app = applicationURL(workspace: workspace) else {
            workspace.activateFileViewerSelecting([folder])
            return .revealedInFinder(files: files.count)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await workspace.open(files, withApplicationAt: app, configuration: configuration)
            return .opened(appName: app.deletingPathExtension().lastPathComponent, files: files.count)
        } catch {
            workspace.activateFileViewerSelecting([folder])
            return .failed(message: error.localizedDescription, files: files.count)
        }
    }
    #endif
}

/// mailin://email/<uuid> — a link that opens one email in mailin.
enum EmailLink {
    static let scheme = "mailin"
    static let host = "email"

    static func url(for emailID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + emailID.uuidString
        return components.url
    }

    /// The email a link names, or nil when the URL is not an email link.
    static func emailID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: id)
    }

    /// What opening a URL should do.
    enum Resolution: Equatable {
        case open(UUID)
        case switchedOff
        case missing
        case notALink
    }

    /// The decision for an incoming URL; `exists` is asked only for a well-formed link while
    /// the switch is on.
    static func resolve(_ url: URL, isEnabled: Bool, exists: (UUID) -> Bool) -> Resolution {
        guard let id = emailID(from: url) else { return .notALink }
        guard isEnabled else { return .switchedOff }
        return exists(id) ? .open(id) : .missing
    }

    /// Puts the link on the clipboard, with the subject as its title where the receiver keeps one.
    @MainActor
    static func copy(emailID: UUID, subject: String) {
        guard let link = url(for: emailID) else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.URL, .string], owner: nil)
        pasteboard.setString(link.absoluteString, forType: .URL)
        pasteboard.setString(link.absoluteString, forType: .string)
        pasteboard.setString(subject, forType: NSPasteboard.PasteboardType("public.url-name"))
        #else
        UIPasteboard.general.url = link
        #endif
    }
}

