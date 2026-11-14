@testable import ArchiveCore
//
//  BackgroundExecution.swift
//  maxmailin
//
//  §3-S3 (switch: `v3SQLiteHygiene`). iOS suspends an app shortly after it
//  leaves the screen, and kills it (0xdead10cc) if it is suspended while
//  holding a SQLite lock. Imports and whole-archive jobs therefore ask for
//  background time while they run and stop cleanly — at a batch boundary —
//  when that time is running out. Background work also checks that protected
//  data is readable (device unlocked since boot) before touching the archive,
//  and never repairs anything in the background.
//
//  macOS has no such suspension; everything here is a no-op there.
//

import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
final class BackgroundExecution {
    /// One assertion for one piece of work.
    final class Assertion {
        fileprivate var id: Int = 0
        /// Set when iOS says the background time is about to expire; the work
        /// should stop at its next batch boundary.
        private(set) var isExpiring = false
        fileprivate func markExpiring() { isExpiring = true }
    }

    /// Starts an assertion for `name` when the switch is on (iOS only).
    static func begin(_ name: String) -> Assertion {
        let assertion = Assertion()
        #if os(iOS)
        guard SQLiteHygiene.isEnabled else { return assertion }
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak assertion] in
            // Expiration: tell the work to stop; the system ends the task when
            // the work calls `end`. If it never does, ending here prevents a kill.
            assertion?.markExpiring()
            if let assertion { BackgroundExecution.end(assertion) }
        }
        assertion.id = id.rawValue
        #endif
        return assertion
    }

    static func end(_ assertion: Assertion) {
        #if os(iOS)
        guard assertion.id != 0 else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: assertion.id))
        assertion.id = 0
        #endif
    }

    /// Runs `body` under an assertion.
    static func perform<T>(_ name: String, _ body: (Assertion) async throws -> T) async rethrows -> T {
        let assertion = begin(name)
        defer { end(assertion) }
        return try await body(assertion)
    }

    /// Whether protected files (the archive) can be read right now. False on
    /// iOS between boot and first unlock; background work must skip, not fail.
    static var isProtectedDataAvailable: Bool {
        #if os(iOS)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }
}
