@testable import ArchiveCore
//
//  ExportHandoff.swift
//  maxmailin
//
//  R1 (release audit bf1a5b9): handing a written export on (iOS Share sheet,
//  Save to Files) without ever waiting forever.
//
//  The old `shareAndWait` resumed its continuation only from the activity
//  view controller's completion handler. When the sheet was never shown (the
//  presenter was busy or still dismissing another sheet), nothing resumed it,
//  and because the export run waited for it, the run card stayed on
//  "Exporting mbox — 51 of 51" with Cancel unable to release it.
//
//  Now: the file and its receipt are recorded first (`awaitingDelivery`); the
//  hand-off is a separate step whose continuation is resumed exactly once on
//  every path — the sheet's answer, Cancel / task cancellation, a sheet that
//  could not be shown, a sheet that vanished while the app was away. Extra
//  callbacks after that are ignored.
//

import Foundation
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// Something that can show a hand-off for a written file (Share sheet, Save to
/// Files) — injectable, so the once-only continuation is testable without UIKit.
@MainActor
protocol ExportHandoffPresenting: AnyObject {
    /// Show the hand-off for `url`. Call `completion` when it closes (the
    /// presenter may call it more than once, or never). Return nil once it is
    /// on screen, or why it could not be shown.
    func present(_ url: URL, completion: @escaping @MainActor (ExportOutcome) -> Void) async -> String?
    /// Take the hand-off off screen (Cancel / task cancellation).
    func dismiss()
}

/// One hand-off. `run` returns exactly once, whatever the presenter does.
@MainActor
final class ExportHandoff {
    private let presenter: ExportHandoffPresenting
    private var continuation: CheckedContinuation<ExportOutcome, Never>?
    private var cancelRequested = false
    /// Finding a presenter and showing the sheet; cancelled with the hand-off.
    private var presenting: Task<Void, Never>?
    /// How many times the continuation was resumed (always 0 or 1).
    private(set) var resumeCount = 0
    /// Callbacks that arrived after the outcome was settled, and were ignored.
    private(set) var ignoredCallbacks = 0

    init(presenter: ExportHandoffPresenting) {
        self.presenter = presenter
    }

    func run(_ url: URL) async -> ExportOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ExportOutcome, Never>) in
                self.continuation = continuation
                if Task.isCancelled || self.cancelRequested {
                    self.resolve(.cancelled)
                    return
                }
                // Weak: a presenter that keeps its completion does not keep the hand-off alive.
                let answer: @MainActor (ExportOutcome) -> Void = { [weak self] outcome in self?.resolve(outcome) }
                self.presenting = Task { @MainActor in
                    let failure = await self.presenter.present(url, completion: answer)
                    if let failure {
                        self.resolve(.failed(failure))
                    } else if self.cancelRequested {
                        // Cancelled while the sheet was on its way: take it away again.
                        self.presenter.dismiss()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// Cancel (the run card's Cancel, or the task being cancelled): take the
    /// sheet away and settle as cancelled — unless an answer already came.
    func cancel() {
        cancelRequested = true
        presenting?.cancel()
        guard continuation != nil else { return }
        presenter.dismiss()
        resolve(.cancelled)
    }

    private func resolve(_ outcome: ExportOutcome) {
        guard let continuation else {
            ignoredCallbacks += 1
            return
        }
        self.continuation = nil
        resumeCount += 1
        continuation.resume(returning: outcome)
    }
}

/// R1 (5): the bytes at the destination the system reported, compared with
/// the file mailin wrote — a single file by SHA-256, a folder file by file.
enum ExportDestinationCheck {
    nonisolated static func outcome(source: URL, destination: URL) -> ExportOutcome {
        if let why = mismatch(source: source, destination: destination) {
            return .failed(why)
        }
        return .saved(destination)
    }

    /// Nil when every byte at `destination` matches `source`; otherwise why not.
    nonisolated static func mismatch(source: URL, destination: URL) -> String? {
        let fm = FileManager.default
        var sourceIsFolder: ObjCBool = false
        var destinationIsFolder: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsFolder) else {
            return String(localized: "the written file is no longer inside mailin, so the saved copy could not be compared")
        }
        guard fm.fileExists(atPath: destination.path, isDirectory: &destinationIsFolder),
              sourceIsFolder.boolValue == destinationIsFolder.boolValue else {
            return String(localized: "the saved copy was not found at the destination")
        }
        if !sourceIsFolder.boolValue {
            guard let a = PlatformExport.fileSHA256(source), let b = PlatformExport.fileSHA256(destination), a == b else {
                return String(localized: "the saved copy did not read back identical")
            }
            return nil
        }
        let expected = files(in: source), found = files(in: destination)
        guard expected.keys.sorted() == found.keys.sorted() else {
            let missing = Set(expected.keys).subtracting(found.keys).count
            return String(localized: "the saved folder is missing \(missing) of \(expected.count) files")
        }
        var differing = 0
        for (path, url) in expected {
            let a = PlatformExport.fileSHA256(url)
            let b = found[path].flatMap { PlatformExport.fileSHA256($0) }
            if a == nil || a != b { differing += 1 }
        }
        return differing == 0 ? nil
            : String(localized: "\(differing) of \(expected.count) files in the saved folder did not read back identical")
    }

    /// Regular files under `folder`, by path relative to it.
    nonisolated private static func files(in folder: URL) -> [String: URL] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [String: URL] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            out[path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent] = url
        }
        return out
    }
}

#if os(iOS)
/// The view controller a hand-off is presented from: the top-most one that is
/// on screen and not being dismissed. Waits (while the app is in the
/// background, or while another sheet finishes closing) instead of presenting
/// onto a controller that cannot show anything.
@MainActor
enum HandoffPresentationAnchor {
    enum Found {
        case controller(UIViewController)
        case unavailable(String)
    }

    static func topPresentable(transitionTimeout: Duration = .seconds(5)) async -> Found {
        // Not while mailin is in the background: wait until it is active again.
        while UIApplication.shared.applicationState != .active {
            if Task.isCancelled { return .unavailable(String(localized: "cancelled")) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: transitionTimeout)
        while true {
            if Task.isCancelled { return .unavailable(String(localized: "cancelled")) }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
                  let root = window.rootViewController else {
                return .unavailable(String(localized: "no window to share from"))
            }
            var top = root
            var settling = false
            while let presented = top.presentedViewController {
                if presented.isBeingDismissed { settling = true; break }
                top = presented
            }
            if top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil || top.viewIfLoaded?.window == nil {
                settling = true
            }
            if !settling { return .controller(top) }
            if clock.now >= deadline {
                return .unavailable(String(localized: "another sheet was still closing, so the Share sheet could not be shown"))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// After `present`, wait until the sheet is really on screen; false when it never got there.
    static func waitUntilShown(_ sheet: UIViewController, presentedFlag: @escaping () -> Bool,
                               timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if presentedFlag() || sheet.presentingViewController != nil { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return presentedFlag() || sheet.presentingViewController != nil
    }
}

/// Base for the two UIKit presenters: shows a controller from the top-most
/// presentable controller, and — when mailin returns from the background and
/// the sheet is gone without having answered — settles as closed.
@MainActor
class UIKitHandoffPresenter: NSObject, ExportHandoffPresenting {
    fileprivate weak var sheet: UIViewController?
    fileprivate var completion: (@MainActor (ExportOutcome) -> Void)?
    private var activeObserver: NSObjectProtocol?

    func makeSheet(for url: URL) -> UIViewController { fatalError("subclass") }

    func present(_ url: URL, completion: @escaping @MainActor (ExportOutcome) -> Void) async -> String? {
        if let why = OrgPolicy.denial(.export) { return why }
        self.completion = completion
        let anchor: UIViewController
        switch await HandoffPresentationAnchor.topPresentable() {
        case .controller(let found): anchor = found
        case .unavailable(let why): return why
        }
        let sheet = makeSheet(for: url)
        sheet.popoverPresentationController?.sourceView = anchor.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: anchor.view.bounds.midX, y: anchor.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        final class Flag { var shown = false }
        let flag = Flag()
        anchor.present(sheet, animated: true) { flag.shown = true }
        guard await HandoffPresentationAnchor.waitUntilShown(sheet, presentedFlag: { flag.shown }) else {
            if sheet.presentingViewController != nil { sheet.dismiss(animated: false) }
            return String(localized: "the Share sheet could not be shown")
        }
        self.sheet = sheet
        // A sheet the system took away while mailin was in the background never answers.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.completion != nil else { return }
                if self.sheet?.presentingViewController == nil { self.answer(.cancelled) }
            }
        }
        return nil
    }

    func dismiss() {
        sheet?.dismiss(animated: true)
        answer(nil)
    }

    /// Hand the answer on once and stop listening.
    fileprivate func answer(_ outcome: ExportOutcome?) {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        let completion = self.completion
        self.completion = nil
        if let outcome { completion?(outcome) }
    }
}

/// The Share sheet. It does not say where a file went, so a completed share
/// is `.shared` — "destination not verifiable" on the receipt.
@MainActor
final class ShareSheetHandoffPresenter: UIKitHandoffPresenter {
    override func makeSheet(for url: URL) -> UIViewController {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
            MainActor.assumeIsolated {
                self?.answer(PlatformExport.shareOutcome(url: url, completed: completed, error: error))
            }
        }
        return sheet
    }
}

/// Save to Files (`UIDocumentPickerViewController` exporting a copy). The
/// system returns the destination URL, so the saved bytes are read back and
/// compared before the receipt says "saved".
@MainActor
final class FilesExportHandoffPresenter: UIKitHandoffPresenter, UIDocumentPickerDelegate {
    private var source: URL?

    override func makeSheet(for url: URL) -> UIViewController {
        source = url
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        return picker
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source, let destination = urls.first else {
            answer(.failed(String(localized: "Files did not say where the copy was saved")))
            return
        }
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                return ExportDestinationCheck.outcome(source: source, destination: destination)
            }.value
            self.answer(outcome)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        answer(.cancelled)
    }
}
#endif
