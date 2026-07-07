//
//  MaxmailinError.swift
//  maxmailin
//
//  Typed error hierarchy. New v2 code (EmailStore, FTSSearchIndex,
//  BulkImportCoordinator, ExportSigner, etc.) throws domain-specific errors
//  that conform to MaxmailinError so the UI layer can react with appropriate
//  hints rather than displaying raw strings.
//

import Foundation

enum MaxmailinError: LocalizedError {
    case parser(ParserDomain, detail: String)
    case persistence(PersistenceDomain, detail: String)
    case search(SearchDomain, detail: String)
    case forensic(ForensicDomain, detail: String)
    case io(IODomain, detail: String)
    case privacy(PrivacyDomain, detail: String)

    enum ParserDomain: String {
        case mbox, eml, emlx, msg, pst, ost, nsf, unknown
    }
    enum PersistenceDomain: String {
        case containerUnavailable, insertFailed, fetchFailed, migrationFailed
    }
    enum SearchDomain: String {
        case indexOpenFailed, indexBuildFailed, queryFailed
    }
    enum ForensicDomain: String {
        case chainBroken, hashMismatch, signatureInvalid, missingKey
    }
    enum IODomain: String {
        case fileNotFound, readFailed, writeFailed, permissionDenied
    }
    enum PrivacyDomain: String {
        case fileProtectionFailed, keychainFailed, secureEnclaveFailed
    }

    var errorDescription: String? {
        switch self {
        case .parser(let d, let m): return "Parse error (\(d.rawValue)): \(m)"
        case .persistence(let d, let m): return "Storage error (\(d.rawValue)): \(m)"
        case .search(let d, let m): return "Search error (\(d.rawValue)): \(m)"
        case .forensic(let d, let m): return "Forensic error (\(d.rawValue)): \(m)"
        case .io(let d, let m): return "I/O error (\(d.rawValue)): \(m)"
        case .privacy(let d, let m): return "Privacy error (\(d.rawValue)): \(m)"
        }
    }

    /// User-facing recovery hint. UI layers can surface this in alert bodies.
    var recoverySuggestion: String? {
        switch self {
        case .parser(.pst, _):
            return "This .pst file may be larger than the 2 GB supported size, or it may be corrupt. Try splitting it with a desktop tool first."
        case .parser(.unknown, _):
            return "Unrecognized email format. Supported: .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf, .zip."
        case .persistence(.containerUnavailable, _):
            return "Storage isn't available. Restart the app, or free up device storage and try again."
        case .persistence(.migrationFailed, _):
            return "Migration didn't complete. Your original archive is preserved as a backup."
        case .search(_, _):
            return "Search index is unavailable. Try a fresh import."
        case .forensic(.chainBroken, _):
            return "The audit log integrity chain is broken. Do not rely on this log for evidentiary purposes."
        case .forensic(.signatureInvalid, _):
            return "The signature on this export does not verify. The file may have been modified after export."
        case .io(.fileNotFound, _):
            return "Could not find the file. Check that it still exists and is readable."
        case .io(.writeFailed, _):
            return "Could not save. Check available device storage."
        case .privacy(.fileProtectionFailed, _):
            return "Could not enable file protection. The file is still saved, but is not encrypted at the file-system level."
        default:
            return nil
        }
    }
}
