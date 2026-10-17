//
//  ErrorDescriptions.swift
//  maxmailin
//
//  App error types shown to people through `localizedDescription` (audit 2026-10-17): without
//  `LocalizedError` they read "The operation couldn't be completed (… error 0)".
//

import Foundation

extension StoreManager.StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return String(localized: "The App Store could not verify this purchase. Nothing was unlocked; try again, or use Restore Purchases if you have already paid.")
        }
    }
}

extension ArchiveComparisonEngine.EngineError: LocalizedError {
    var errorDescription: String? { description }
}

extension StorageEnvironmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .refusedProductionPath(let path):
            return "A test environment was refused because it pointed at the real archive (\(path))."
        }
    }
}
