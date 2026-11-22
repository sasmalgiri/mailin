//
//  BandwidthLimiter.swift
//  MailConnectivity
//
//  DL-06 (owner 2026-11-23, download-manager techniques: a speed limiter).
//  An optional cap on how fast connected mail downloads, across every
//  account together, so a first large sync leaves the internet connection
//  usable. Off by default.
//
//  It paces whole messages, not single network reads: each download books
//  its bytes on one shared timeline (`bytes / limit` seconds each) and waits
//  for its turn — before it starts when the provider gave the size (IMAP),
//  otherwise right after it arrived, while it still holds its download slot,
//  so the next ones wait. The average stays at the limit; one large message
//  may still arrive in a burst. Stated in the UI as an average.
//

import Foundation

public actor BandwidthLimiter {
    public static let shared = BandwidthLimiter()

    /// Bytes per second; 0 = no limit.
    public private(set) var bytesPerSecond: Int64 = 0
    private var nextFree: ContinuousClock.Instant = .now
    private let clock = ContinuousClock()

    public init(bytesPerSecond: Int64 = 0) { self.bytesPerSecond = max(0, bytesPerSecond) }

    public func setLimit(bytesPerSecond: Int64) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        nextFree = clock.now
    }

    /// Books `bytes` on the shared timeline; returns how long the caller waits first.
    public func reserve(_ bytes: Int64) -> Duration {
        guard bytesPerSecond > 0, bytes > 0 else { return .zero }
        let now = clock.now
        let start = max(now, nextFree)
        nextFree = start + .nanoseconds(Int64((Double(bytes) / Double(bytesPerSecond)) * 1_000_000_000))
        return start - now
    }

    /// Books `bytes` and waits for their turn (cancellable).
    public func pace(_ bytes: Int64) async throws {
        let wait = reserve(bytes)
        if wait > .zero { try await clock.sleep(for: wait) }
    }
}
