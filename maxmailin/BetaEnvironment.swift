//
//  BetaEnvironment.swift
//  maxmailin
//
//  §3-M5 promotion path (2026-10-11). An engine becomes stable only after a
//  TestFlight period with zero trips — so TestFlight testers must actually run
//  the 3.0 engines. In a TestFlight (or development) build every 3.0 preview
//  engine is ON by default; the App Store build keeps them OFF until each one
//  is promoted in EngineSpec. A crash still trips the engine off (M2), and a
//  tester's own choice in Settings ▸ Modules always wins.
//
//  The same binary moves from TestFlight to the App Store, so this is decided
//  at run time from StoreKit's app transaction (`.sandbox` = TestFlight or a
//  development-signed build), cached for the next launch because the
//  store-level engines are armed before any async work can run. The
//  enterprise edition has no StoreKit and never takes this path.
//

import Foundation
#if !ENTERPRISE_EDITION
import StoreKit
#endif

enum BetaEnvironment {
    static let cacheKey = "mailin.betaEnvironment"

    /// True in a TestFlight or development build (as last detected).
    static var isBeta: Bool {
        #if ENTERPRISE_EDITION
        return false
        #else
        // Unit tests run inside the app: they always see the shipping
        // (App Store) defaults, whatever a development run cached.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        return UserDefaults.standard.bool(forKey: cacheKey)
        #endif
    }

    /// Reads the app transaction's environment and caches it. Returns true
    /// when the value changed (the caller re-applies the capability switches).
    @discardableResult
    static func detect() async -> Bool {
        #if ENTERPRISE_EDITION
        return false
        #else
        guard let result = try? await AppTransaction.shared else { return false }
        let transaction: AppTransaction
        switch result {
        case .verified(let t): transaction = t
        case .unverified(let t, _): transaction = t   // the environment, not a purchase, is read
        }
        let beta = transaction.environment != .production
        let changed = beta != isBeta
        UserDefaults.standard.set(beta, forKey: cacheKey)
        return changed
        #endif
    }
}
