# Mac button crawl — 2026-10-05

`MailinClickThroughUITests.testRealMailbox_importThenPressEveryButton` on macOS (Debug build, the owner's existing archive of 526 emails, Professional unlocked). It visits Archive, AI Insights and Professional Workflows, presses every enabled button once (scrolling to off-screen ones), and inside every tool window a press opens it presses every button again. It skips destructive, purchase, import and window-close buttons, and leaves toggles alone.

## Result of the final run

- 173 rows, **no crashes**, no new crash report.
- Archive 59 rows · AI Insights 7 · Professional Workflows 94 · menu bar 9 menus.
- Tool windows opened and crawled: Duplicates, Hypothesis Matrix, Fact–Evidence, Action Register, Evidence Desks, Reasoning Studio, Custodians & Holds, Chain of Custody, eDiscovery, Bates Numbering, Redaction, Review Batches, Investigation Report, Production, and a workflow window.

## Defects the crawl found, all fixed

| Defect | Fix | Commit |
|---|---|---|
| Opening any tool window crashed (StoreManager missing from the window's environment) | store attached outside the purchase presenter; one shared window root | dd495b6, a45be5f |
| Email-detail window lacked the page registry (same crash class) | shared window root | a45be5f |
| "Done" on AI Insights closed the main window | Done hidden when the assistant is embedded in a page | e7a7511 |
| No way to reopen a closed main window | File ▸ New Window (⇧⌘N) | e7a7511 |
| Pressing an AI suggestion crashed the app inside AppKit accessibility (EXC_BAD_ACCESS) | plain VStack, one stable element while streaming, one question at a time | d4aac47 and the commit adding this file |
| Page strip pushed off-screen on a short window, no way back to Archive | strip keeps its height; page clipped below it | 4286667 |

## Not pressed

- Mailbox and label rows below the fold of the sidebar list, and eight saved workflows further down the Work Center list (the wheel scroll did not reach them).
- Redaction ▸ Redact & Export (below the fold of its window).

## Side effects in the Debug archive

The crawl presses real buttons, so the Debug archive now contains test items: a new ACH analysis, fact–evidence matrix, action register, evidence desk and reasoning case; the eDiscovery phases marked complete; and review batches created. None of it touches the App Store build.

The full per-button table is in `~/mailin-loc-work/mac-report.md` on the owner's Mac.
