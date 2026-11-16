//
//  PackageLocalization.swift
//  ArchiveCore
//
//  Rule 10 (review 2026-11-16): package texts that reach the screen are
//  looked up with `String(localized:bundle:)` in the app's string catalog —
//  the package ships no catalog of its own (as ChildHashRepair's texts, which
//  use the main bundle). The keys are added to maxmailin/Localizable.xcstrings
//  by the app. `bundle` is the main bundle; tests point it at a bundle of
//  marked values to prove a text is looked up rather than fixed English.
//

import Foundation

public enum PackageLocalization {
    /// Where package texts are looked up (the app's bundle).
    nonisolated(unsafe) public static var bundle: Bundle = .main
}
