//
//  DuplicateSummary.swift
//  maxmailin
//
//  IPAD-05 (c)/(d): what the Duplicate Manager says about its result, in one
//  testable place. The sheet used to end on "Your email archive has no
//  duplicate messages" whenever no identical copy was left — also while
//  similar messages were on screen or had never been looked for. It now says
//  what was found and what was checked, with proper plurals.
//

import Foundation

/// Plural-correct text through Foundation's automatic grammar agreement
/// (`^[1 group](inflect: true)` → "1 group", `^[2 group](inflect: true)` →
/// "2 groups"), so the screens stop saying "1 copies" / "1 groups".
enum Inflect {
    static func string(_ resource: String.LocalizationValue) -> String {
        String(AttributedString(localized: resource).characters)
    }
}

enum DuplicateSummary {
    /// How far the near-duplicate (similar) search reached.
    enum NearCoverage: Equatable {
        /// "Include near-duplicates" is off: similar messages were not looked for.
        case notChecked
        /// Every email was compared.
        case wholeArchive
        /// The previous engine's window: the newest N emails only.
        case newest(Int)
    }

    struct Text: Equatable {
        let title: String
        let detail: String
    }

    /// The headline for a result. `verified` = groups proven identical,
    /// `candidates` = groups that share a key but differ (DUP-01: shown,
    /// never bulk-removed), `similar` = near-duplicate groups.
    static func text(verified: Int, candidates: Int, similar: Int, near: NearCoverage) -> Text {
        let toReview = candidates + similar
        if verified == 0 && toReview == 0 {
            switch near {
            case .notChecked:
                return Text(title: String(localized: "No identical copies found"),
                            detail: String(localized: "Similar messages were not looked for. Turn on “Include near-duplicates” to check for them."))
            case .wholeArchive:
                return Text(title: String(localized: "No identical copies found"),
                            detail: String(localized: "No similar messages were found at the chosen similarity either."))
            case .newest(let n):
                return Text(title: String(localized: "No identical copies found"),
                            detail: String(localized: "No similar messages were found among the newest \(n.formatted()) emails at the chosen similarity; older emails were not compared for similarity."))
            }
        }
        if verified == 0 {
            return Text(title: String(localized: "No identical copies"),
                        detail: Inflect.string("Similar, not identical: ^[\(toReview) group](inflect: true) to review below. Similar copies are never removed in bulk; tick one only after comparing."))
        }
        let identical = Inflect.string("^[\(verified) group](inflect: true) of identical copies")
        guard toReview > 0 else {
            return Text(title: identical, detail: String(localized: "Every copy in them was compared in full; the extra copies can be moved to the Trash and restored from there."))
        }
        return Text(title: identical,
                    detail: Inflect.string("Also similar, not identical: ^[\(toReview) group](inflect: true) to review one copy at a time."))
    }
}
