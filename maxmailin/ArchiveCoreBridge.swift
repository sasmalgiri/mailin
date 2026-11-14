//
//  ArchiveCoreBridge.swift
//  maxmailin
//
//  Installs the app's implementations behind ArchiveCore's three hooks.
//  Called first thing in `mailinApp.init()`, before any store or repository
//  is touched, so the engine's defaults are never observed by the app.
//

import Foundation
@testable import ArchiveCore

enum ArchiveCoreBridge {
    @MainActor
    static func install() {
        // The repository's default store stays the legacy SwiftData store
        // until activation completes — exactly what it was before the split.
        ArchiveCoreDefaults.defaultStoreProvider = { EmailStore.shared }
        ArchiveCoreDefaults.storageAuthorityIsActive = { await StorageActivationCoordinator.shared.isActive }
        ArchiveCoreDefaults.observedMemoryPressure = { Self.currentPressure() }
    }

    /// The reading the adaptive batch controller used to take directly from
    /// `MemoryPressureHandler`. The sampler calls from the importer's
    /// actor; the handler is main-actor isolated, so the last observed level
    /// is read through a synchronous main-actor hop.
    private nonisolated static func currentPressure() -> PressureSample.MemoryPressure {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { readPressure() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { readPressure() } }
    }

    @MainActor
    private static func readPressure() -> PressureSample.MemoryPressure {
        guard let observed = MemoryPressureHandler.shared.lastObservedLevel,
              MemoryPressureHandler.shared.isUnderRecentPressure(window: 30) else {
            return .nominal
        }
        switch observed {
        case .critical: return .critical
        case .warning, .thermal: return .warning
        }
    }
}
