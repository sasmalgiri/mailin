//
//  TagDisplayPolicy.swift
//  maxmailin
//
//  Which auto-labels each mode DISPLAYS. The rule: Simple tells you what
//  to do (category, importance, phishing); Advanced (Pro) adds what's
//  going on (sentiment, medium priority, evidence). Nothing here changes
//  what is computed or stored — analytics, filters and eDiscovery always
//  see everything. String-typed so it's unit-testable without the list
//  view's private tag enum.
//

import Foundation

enum TagDisplayPolicy {
    /// Plain facts the row already shows elsewhere — hidden unless the
    /// "Show basic fact pills" advanced option is on.
    static let factTags: Set<String> = ["Sent", "Received", "Has Attachment"]

    /// Analyst vocabulary — displayed only in Pro (advanced) mode.
    /// Sentiment is analysis, not action; "somewhat important" earns no
    /// pill in Simple. (Evidence tags are gated separately by the same
    /// Pro toggle at the menu level.)
    static let advancedOnlyTags: Set<String> = ["Positive", "Negative", "Neutral", "Medium Priority"]

    /// Filter a list of auto-label names down to what the current mode
    /// shows. Manual labels are never passed through this — the user's
    /// own labels are always visible.
    static func visible(_ tags: [String], advancedMode: Bool, showFacts: Bool) -> [String] {
        tags.filter { tag in
            if !showFacts && factTags.contains(tag) { return false }
            if !advancedMode && advancedOnlyTags.contains(tag) { return false }
            return true
        }
    }
}
