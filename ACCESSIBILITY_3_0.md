# mailin 3.0 — accessibility (SCALE_TODO_3_0.md §3-X4, V10)

Apple's Accessibility Nutrition Labels are declared per platform in App Store Connect. Declare a
feature only once the common tasks can be done with it. For mailin those tasks are: import, browse
and search, read an email, run a whole-archive tool, export, and Settings ▸ Modules.

| Feature (App Store Connect) | What supports it in 3.0 | Still to verify before declaring (V10) |
|---|---|---|
| VoiceOver | Standard SwiftUI controls. 3.0 views: decorative icons hidden; progress bars carry a label and an "X of Y emails" value; Cancel names its job; list rows read as one element ("subject, N emails"); the shadow-comparison status reads "Matches"/"Differs". | Full VoiceOver pass on Mac and iPad over the common tasks (owner + me). |
| Voice Control | Every button has a visible or accessibility name; Cancel on a job also answers to "Cancel <job>". | Voice Control "Show names" pass; no unnamed controls. |
| Larger Text | Text uses text styles (Typography / `.caption` …), no fixed point sizes in 3.0 views; long lines wrap (`fixedSize(horizontal: false, vertical: true)`). | iPad at the largest accessibility size; the automated Dynamic Type / clipped-text audit. |
| Sufficient Contrast | Secondary text uses system styles; warnings pair colour with an icon and words. | Automated contrast audit; Increase Contrast on. |
| Dark Interface | System colours and materials throughout. | Visual pass in Dark Mode (screenshots). |
| Differentiate Without Color Alone | Status in 3.0 views is shape + text, never colour alone (✓ circle vs ○, ⚠ + "Differs", "page off" badge). | Differentiate Without Color on; audit the older screens' charts. |
| Reduced Motion | 3.0 views add no animation. | Reduce Motion pass over older animated views. |
| Captions / Audio Descriptions | Not applicable: mailin has no video or audio content. | — |

## Automated audit

`maxmailinUITests/AccessibilityAuditUITests.swift` runs `XCUIApplication.performAccessibilityAudit(for: .all)`
on the main window and on Settings ▸ Modules. It attaches the full issue list to the test report and fails
while any issue remains. It needs the owner at the Mac to approve automation.

## Changes made for 3.0 (2026-10-10)

- `ScopeJobProgressBar`: the progress bar has a label (job title) and a value (X of Y emails). The duplicated
  texts are hidden from VoiceOver. Cancel reads "Cancel <job>" and has Voice Control input labels.
- `ArchiveHealthView`: both coverage progress bars are labelled.
- `ArchiveWideLists`: subject rows read "subject, N emails"; the attachment row's document icon is hidden.
- `CrashSafety` banners: decorative icons are hidden (the heading carries the meaning).
- `ShadowComparisonPanel`: status is an icon plus text, with an accessibility value.

## App Store Connect declarations (owner decision 2026-10-11)

The owner chose to declare the labels without a manual VoiceOver / Voice Control pass, set the way comparable
productivity apps (Apple Mail, Notes, Pages) declare them for text-based apps without media. The automated audit
(`AccessibilityAuditUITests`) still runs in the V5 UI session; any issue it reports is fixed before submission.

Enter the same answers for **iPhone, iPad and Mac** (App Store Connect ▸ App ▸ Accessibility):

| Feature | Answer |
|---|---|
| VoiceOver | Yes |
| Voice Control | Yes |
| Larger Text | Yes |
| Dark Interface | Yes |
| Differentiate Without Color Alone | Yes |
| Sufficient Contrast | Yes |
| Reduced Motion | Yes |
| Captions | No — the app has no video or audio content |
| Audio Descriptions | No — the app has no video content |

Accessibility URL (optional field): leave empty, or point it to the support page once one exists.
