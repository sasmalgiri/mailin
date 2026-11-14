//
//  ModelVersionWatch.swift
//  maxmailin
//
//  §3-I5 (switch: `v3AIAnswers`). Apple updates the on-device model with the
//  OS ("Updating prompts for new model versions"). Prompts were tuned and
//  checked (the typed-question checks) on one OS build; after an update the
//  same prompts can behave differently. This records the build the checks
//  last passed on and says on the Health page when the model may have
//  changed since — so the checks are re-run deliberately, not discovered by
//  a user.
//

import Foundation

enum ModelVersionWatch {
    static let promptVersion = 1
    private static let checkedBuildKey = "ai.promptChecks.osBuild"
    private static let checkedPromptKey = "ai.promptChecks.promptVersion"

    static var currentBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// The OS build the prompt checks last passed on (nil = never recorded).
    static var checkedBuild: String? { UserDefaults.standard.string(forKey: checkedBuildKey) }

    /// True when the OS (and so possibly the model) or the prompts changed
    /// since the checks last passed.
    static var needsRecheck: Bool {
        checkedBuild != currentBuild || UserDefaults.standard.integer(forKey: checkedPromptKey) != promptVersion
    }

    /// Call after the typed-question checks pass on this build.
    static func recordChecksPassed() {
        UserDefaults.standard.set(currentBuild, forKey: checkedBuildKey)
        UserDefaults.standard.set(promptVersion, forKey: checkedPromptKey)
    }
}
