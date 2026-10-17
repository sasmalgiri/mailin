//
//  ErrorDescriptions.swift
//  ArchiveCore
//
//  Errors shown to people read `localizedDescription`, which ignores `CustomStringConvertible`:
//  without `LocalizedError` they appeared as "The operation couldn't be completed (… error 3)"
//  although each type already says what went wrong (audit 2026-10-17).
//

import Foundation

extension FileUtilsError: LocalizedError {
    public var errorDescription: String? { description }
}

extension EmailExtractionError: LocalizedError {
    public var errorDescription: String? { description }
}

extension ExtractionError: LocalizedError {
    public var errorDescription: String? { description }
}

extension ZIPArchiveReader.ReadError: LocalizedError {
    var errorDescription: String? { description }
}

extension EmailRepositoryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedQueryCombination(let what):
            return "This combination of filters is not supported yet: \(what). Remove one of them and try again."
        case .staleSearchCursor:
            return "The search changed while more results were loading. Scroll to load them again."
        }
    }
}
