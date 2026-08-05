//
//  MemoryPressureHandler.swift
//  maxmailin
//
//  Responds to iOS / macOS memory pressure signals by dropping in-memory
//  caches. Prevents jetsam kills on large archives.
//
//  iOS: listens for UIApplication.didReceiveMemoryWarningNotification
//  macOS: listens for ProcessInfo.thermalStateDidChangeNotification + uses
//         DispatchSource memory-pressure events
//

import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class MemoryPressureHandler {
    static let shared = MemoryPressureHandler()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "MemoryPressure")

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Caches that register here are asked to drop content when system memory
    /// pressure spikes. The handler receives the current pressure level so it
    /// can choose how much to evict.
    ///
    /// `@Sendable` because handlers may be invoked from a non-main context
    /// when reposting to subscribers — though we always dispatch back to the
    /// main actor before calling.
    typealias EvictionHandler = @Sendable (PressureLevel) -> Void
    private var evictionHandlers: [EvictionHandler] = []

    /// Last observed pressure level and when it fired. Lets startup paths
    /// (self-test, archive restoration, large precompute) skip optional
    /// work when the OS is already complaining. `nil` means "no pressure
    /// observed since launch".
    private(set) var lastObservedLevel: PressureLevel?
    private(set) var lastObservedAt: Date?

    /// True if a memory-pressure event of any severity occurred within the
    /// last `window` seconds. Default window is 60 s — enough to skip the
    /// next pile of optional work after pressure has been seen.
    func isUnderRecentPressure(window: TimeInterval = 60) -> Bool {
        guard let at = lastObservedAt else { return false }
        return Date().timeIntervalSince(at) <= window
    }

    private init() {}

    /// Start listening for memory pressure events. Call once at app launch.
    func start() {
        registerSystemNotifications()
        registerMemoryPressureSource()
        logger.info("Memory pressure handler started.")
    }

    /// Register a cache-eviction handler. Returns nothing — handlers stay
    /// for the app lifetime, which is appropriate for the long-lived
    /// singletons (FTSSearchIndex, EmailPersistence, etc.) that use this.
    func register(_ handler: @escaping EvictionHandler) {
        evictionHandlers.append(handler)
    }

    // MARK: - System notifications

    private func registerSystemNotifications() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePressure(level: .warning) }
        }
        #endif

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                // Hop to the main actor: handlePressure is @MainActor-isolated
                // and the notification closure is nonisolated.
                Task { @MainActor in self?.handlePressure(level: .thermal) }
            }
        }
    }

    private func registerMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let level: PressureLevel = source.data.contains(.critical) ? .critical : .warning
            Task { @MainActor in self.handlePressure(level: level) }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Handler

    enum PressureLevel: String {
        case warning, critical, thermal
    }

    private func handlePressure(level: PressureLevel) {
        logger.warning("Memory pressure: \(level.rawValue, privacy: .public) — dropping caches.")
        lastObservedLevel = level
        lastObservedAt = Date()
        evictCaches(aggressive: level != .warning)
        // Fan out to any registered cache so domain-specific eviction
        // (e.g. closing idle FTS5 shard handles) runs alongside the
        // system-wide caches.
        for handler in evictionHandlers {
            handler(level)
        }
    }

    private func evictCaches(aggressive: Bool) {
        // System-wide URL cache.
        URLCache.shared.removeAllCachedResponses()

        // SwiftData metadata caches are managed by the framework; nudging
        // the runtime via clearing temp dirs helps.
        let tempDir = FileManager.default.temporaryDirectory
        try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .forEach { try? FileManager.default.removeItem(at: $0) }

        if aggressive {
            // Hint the system that thumbnails / image caches can go.
            #if canImport(UIKit)
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification,
                                           object: nil)
            #endif
        }
    }
}
