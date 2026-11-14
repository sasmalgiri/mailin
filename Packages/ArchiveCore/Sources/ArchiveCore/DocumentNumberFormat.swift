//
//  DocumentNumberFormat.swift
//  ArchiveCore
//

import Foundation

/// Pure formatting — unit-tested independent of the store.
enum DocumentNumberFormat {
    static func format(type: String, year: Int, sequence: Int) -> String {
        String(format: "%@-%d-%04d", type.uppercased(), year, sequence)
    }

    /// Master-element alias for a source row: SRC-0001.
    static func sourceAlias(_ sourceID: Int64) -> String {
        String(format: "SRC-%04d", sourceID)
    }
}
