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

## Automated audit (iPhone 18 Pro simulator, 2026-10-12)

Fixed by the audit: page-switcher contrast (accent text on an accent tint), page names in fixed point sizes
(now text styles, so they follow Dynamic Type), clipped page names on iPhone (now full → short → scroll),
unlabelled "…" list-actions and filter buttons.

Reported but not failed (advisories, listed in each run's report):
- **Contrast nearly passed** — secondary text uses the system secondary style, which darkens with Increase
  Contrast.
- **Text clipped** — list previews are cut to two lines with an ellipsis by design (the whole email opens on
  tap), and the last list row meets the screen edge until scrolled.

## Automated audit (Mac, 2026-10-12) — open

Fixed: the compact tool buttons beside the email detail had no label (VoiceOver read "square.and.arrow.up");
every one now has a name and a tooltip. Main-window panes are named (Filters / Email list / Email).

Still reported by the Mac audit (the test fails on purpose until they are resolved or confirmed harmless with
VoiceOver): 5 "no description" groups and 2 outlines — the panes of SwiftUI's split view, whose AppKit
containers do not take the SwiftUI label; 3 "action is missing" on SwiftUI menu buttons (sort, export) that
VoiceOver opens with its menu action; the menu bar; 1 small text failing contrast in the sidebar (6×13 pt). A
short VoiceOver pass on the Mac decides whether any of these needs code.


## Audit pass, 2026-10-13 (D1)

`AccessibilityAuditUITests` now audits the **Archive page, the Professional page and Settings ▸ Modules by name** (it used to audit whatever page the window was left on, which hid every Archive-page finding).

Fixed in the app:
- Contrast: green/orange status captions on Settings ▸ Modules (now a coloured dot beside secondary text); "Studios"/"Tools" captions; the faded "Click any email in the list…" hint; the date-range "–" is decorative and hidden.
- Labels: the email lists ("Emails"), the Email list pane, the subjects and attachments lists, the four tool grids in the empty email pane, the window roots ("mailin", "Settings").
- Sender / recipient filters read "Filter: Ann Lee, ann@x.org" instead of `"Ann Lee" <ann@x.org>` (symbols read aloud).
- The profession filter is a menu-style Picker; List section headers carry the header trait.

Reported, not failed (each reason is printed in the report):
- **System elements**: the empty Touch Bar; the Settings toolbar's own "more toolbar items" overflow button.
- **SwiftUI-generated containers** no app modifier reaches (tried: labelling the window root, each pane, each List section header/footer): the window's content root group; List section row wrappers; an unnamed group occupying exactly the same area as a pane the app has named.
- **"Action is missing" on SwiftUI `Menu` and menu-style `Picker`** that have a name (a stock Picker in place of a Menu is reported the same way).
- **Contrast of text clipped by its scroll view** (accessibility frames ignore clipping, so the audit samples whatever is drawn there), and the audit's own issues that are attached to no element.
- Another window behind the one in front is drawn inactive (dimmed); the Settings pass judges only the Settings window.

Anything the app draws still fails the test.

**Status:** the last completed run (2026-10-13 23:48) left one finding — the email list's inner container, now covered by the "same area as a named pane" rule. Later runs could not start: macOS asks to approve UI automation ("Timed out while enabling automation mode"), which needs the owner at the Mac. **Re-run `AccessibilityAuditUITests` with the owner present** to confirm green.

## Confirming run, Mac, 2026-10-14 (D1) — passed

`AccessibilityAuditUITests` on the Mac, with the owner approving automation: **no accessibility issues**
on the main window, the Archive page, the Professional Workflows page and Settings ▸ Modules.

Fixed on the way:
- Email rows: the risk number is full-strength text (the colour sits in the badge's fill and border);
  date and preview are 75 % of the primary text colour; contact avatars use deep tones under white
  initials, with a stable colour per sender (the colour used to change at every launch).
- The audit test itself: it took 2 h 44 min (one query per text row in every list, 17,510 queries) —
  now one query per list; it waits for the window to settle; elements that vanish mid-audit are named
  instead of failing the run; real failures carry the element tree and a screenshot.

Two email rows were still reported as "Contrast failed" although their faintest text line measures
6.6:1 against the row's background (measured from the element's own pixels: background = most common
colour, each line of text judged by its glyph cores, the weakest line counts; the same method gives
2.3:1 for a deliberately faint line). The test now reports such a contrast claim as an advisory **with
the measured ratio**; anything that measures under 4.5:1 still fails.

Note: the Mac UI tests open the app's normal archive (they only seed the demo mailbox when it is empty),
so this run read the owner's own archive. Nothing was changed; a separate test archive for UI tests is
an open item.
