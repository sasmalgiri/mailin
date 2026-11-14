//
//  ArchiveCoreDefaults.swift
//  ArchiveCore
//
//  The three places the engine used to reach into the app. Each is a hook
//  with a safe default; the app installs its own at launch
//  (`ArchiveCoreBridge.install()` in the app target).
//

import Foundation

enum ArchiveCoreDefaults {
    /// The store the repository binds to when none is injected. The app
    /// points this at its legacy SwiftData store until activation completes.
    nonisolated(unsafe) static var defaultStoreProvider: () -> any EmailArchiveStore = { SQLiteEmailStore.shared }

    /// The storage-authority gate the importer waits on. The app installs
    /// `StorageActivationCoordinator`; without a host the gate is open.
    nonisolated(unsafe) static var storageAuthorityIsActive: @Sendable () async -> Bool = { true }

    /// OS memory-pressure reading for the adaptive batch controller. The app
    /// installs `MemoryPressureHandler`; without a host pressure reads nominal.
    nonisolated(unsafe) static var observedMemoryPressure: @Sendable () -> PressureSample.MemoryPressure = { .nominal }
}
