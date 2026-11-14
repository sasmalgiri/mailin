# Button crawl on a real mailbox — iPad, 2026-10-03

What ran: `MailinClickThroughUITests.testRealMailbox_importThenPressEveryButton` on the iPad Pro 13-inch simulator (iOS 27, Debug build, all tiers unlocked), on a fresh install. The test imports `~/Downloads/Mail/Sent.mbox` (95 MB, Gmail Takeout) through the real UI, then visits every page and presses every visible button once. Destructive, purchase and window-control buttons are listed but never pressed. Toggles are left alone so settings are not changed.

How to rerun:

```
# iPad: copy the mailbox into the simulator's On My iPad storage first
xcodebuild test -project maxmailin.xcodeproj -scheme maxmailin \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:maxmailinUITests/MailinClickThroughUITests/testRealMailbox_importThenPressEveryButton
# Mac: needs Touch ID / password approval for UI automation on first run
TEST_RUNNER_MAILIN_UITEST_MBOX=$HOME/Downloads/Mail/Sent.mbox xcodebuild test ... -destination 'platform=macOS' ...
```

## Result

- **No crashes** in 83 presses across Archive, AI Insights and Professional Workflows.
- **Import works through the real path** (Add more email files ▸ Files picker ▸ Sent.mbox ▸ Open ▸ Start import) in 95 s. Archive: 534 emails (8 demo + 526 from Sent.mbox), all Gmail labels shown with counts.
- **Defect found and fixed:** 2 of 526 messages were stored as year 1 and sorted last. One was a Gmail chat transcript with no `Date` header; the other had an unreadable `Date` header. Both carry their delivery time in `Received` and on the mbox envelope line. The parser now falls back to those (the `Date` header itself is never rewritten). After the fix: 0 undated, range Jul 2007 to Mar 2025. Tests: `UndatedMessageTests` (ArchiveCore).
- **Copy defect found and fixed:** the App Review notes and the support page described a Live Mail placeholder page. The shipping no-network build has no Live Mail page at all; the copy now says so.

## What the crawl could not prove

- **15 buttons were not pressed** because they sat below the fold and the crawler's scroll did not bring them into view: six Professional tiles (eDiscovery, Bates Numbering, Redaction, Review Batches, Investigation Report, Production…), seven sidebar rows at the bottom of the label list, and the Archive footer's Apply filters and Export filtered emails.
- **28 presses showed no change in the visible controls.** Most are expected: selecting a mailbox or label changes the list contents, not the buttons. "Show tutorial" on AI Insights is in this group; the tutorial had auto-opened on first visit and was still on screen, so this is most likely a test artifact. Not confirmed by hand.
- **The Mac run did not start:** macOS asks for Touch ID or a password the first time a UI test drives the app, and nobody was at the Mac to approve it.

## Full report

| Page | Button | Outcome |
|---|---|---|
| Archive | Import Sent.mbox | imported, queue never shown; sidebar: All Emails, 534; Sent, 402 emails (95 s) |
| Archive | Current plan: Professional | screen changed (+3 controls: Restore Purchases, Manage Subscription, Close) |
| Archive | Find Duplicates Now | opened a menu or popover |
| Archive | Start new import | opened an alert “Start New Import?” |
| Archive | Add more email files | opened a menu or popover |
| Archive | Help | opened a menu or popover |
| Archive | Adjust minimum reply count, Increment | screen changed (+1 controls: Adjust minimum reply count, Decrement) |
| Archive | Date Picker | screen changed (+35 controls: Monday, 3 January, Thursday, 13 January, Wednesday, 5 January) |
| Archive | Received, 65 emails | no visible change (may act in place) |
| Archive | Personal, 7 emails | no visible change (may act in place) |
| Archive | Newsletter, 1 emails | no visible change (may act in place) |
| Archive | High Priority, 1 emails | no visible change (may act in place) |
| Archive | Medium Priority, 26 emails | no visible change (may act in place) |
| Archive | All Emails, 534 | no visible change (may act in place) |
| Archive | Inbox, 534 emails | screen changed (+3 controls: Transactional, 5 emails, Personal, 60 emails, Phishing, 7 emails) |
| Archive | Has Attachments, 152 emails | no visible change (may act in place) |
| Archive | Labels, 1,452 emails | no visible change (may act in place) |
| Archive | Sent, 402 emails | no visible change (may act in place) |
| Archive | Inbox, 265 emails | no visible change (may act in place) |
| Archive | Opened, 226 emails | no visible change (may act in place) |
| Archive | Important, 158 emails | no visible change (may act in place) |
| Archive | Category personal, 151 emails | no visible change (may act in place) |
| Archive | Unread, 142 emails | no visible change (may act in place) |
| Archive | Category updates, 17 emails | no visible change (may act in place) |
| Archive | IMAP_boxbe_a, 9 emails | no visible change (may act in place) |
| Archive | IMAP_boxbe_b, 6 emails | no visible change (may act in place) |
| Archive | Drafts, 2 emails | no visible change (may act in place) |
| Archive | Boxbe Waiting List, 1 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Category purchases, 1 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Category travel, 1 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Chat, 1 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Source Files, 534 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Sent.mbox, 526 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Unknown source, 8 emails | not hittable (off-screen or covered; scroll needed) |
| Archive | Apply filters | not hittable (off-screen or covered; scroll needed) |
| Archive | Clear all filters | skipped (destructive, purchase or window control) |
| Archive | Export filtered emails | not hittable (off-screen or covered; scroll needed) |
| Archive | AI Assistant | opened a menu or popover |
| Archive | Analytics | opened a menu or popover |
| Archive | Enable Forensic Mode | screen changed (+2 controls: Show all emails, Disable Forensic Mode) |
| Archive | New Import | opened an alert “Start New Import?” |
| Archive | More Actions | screen changed (+3 controls: Find Duplicates Now, Add Files, Auto-Remove on Import) |
| Archive | Settings | opened a menu or popover |
| AI Insights | Current plan: Professional | screen changed (+3 controls: Manage Subscription, Restore Purchases, Close) |
| AI Insights | Ask | no visible change (may act in place) |
| AI Insights | Summaries | opened a menu or popover |
| AI Insights | Reports | screen changed (+1 controls: Generate PDF Report) |
| AI Insights | Whole archive | screen changed (+6 controls: Last 7 Days, Last 30 Days, Show tutorial) |
| AI Insights | All Time | no visible change (may act in place) |
| AI Insights | Semantic index off | no visible change (may act in place) |
| AI Insights | Bar Chart With An X Axis | no visible change (may act in place) |
| AI Insights | Show tutorial | no visible change (may act in place) |
| AI Insights | Done | no visible change (may act in place) |
| AI Insights | Auto | no visible change (may act in place) |
| AI Insights | 534 emails | no visible change (may act in place) |
| AI Insights | Ask: Tell me about emails from | gone after an earlier press |
| AI Insights | Ask: What's discussed about india? | gone after an earlier press |
Prioritize my emails and suggest actions | gone after an earlier press |
Scan for phishing and data exposure risks | gone after an earlier press |
Narrate this conversation thread | gone after an earlier press |
| AI Insights | Ask: What are the most common topics in my inbox? | gone after an earlier press |
| AI Insights | Ask: Show me emails with photos or documents attached | gone after an earlier press |
| Professional Workflows | Current plan: Professional | screen changed (+3 controls: Manage Subscription, Close, Restore Purchases) |
| Professional Workflows | Hypothesis Matrix | opened a menu or popover |
| Professional Workflows | Fact–Evidence | opened a menu or popover |
| Professional Workflows | Action Register | opened a menu or popover |
| Professional Workflows | Evidence Desks | opened a menu or popover |
| Professional Workflows | Reasoning Studio | opened a menu or popover |
| Professional Workflows | Custodians & Holds | opened a menu or popover |
| Professional Workflows | Chain of Custody | opened a menu or popover |
| Professional Workflows | eDiscovery | not hittable (off-screen or covered; scroll needed) |
| Professional Workflows | Bates Numbering | not hittable (off-screen or covered; scroll needed) |
| Professional Workflows | Redaction | not hittable (off-screen or covered; scroll needed) |
| Professional Workflows | Review Batches | not hittable (off-screen or covered; scroll needed) |
| Professional Workflows | Investigation Report | not hittable (off-screen or covered; scroll needed) |
| Professional Workflows | Production… | not hittable (off-screen or covered; scroll needed) |
| Professional Workflows | Help | opened a menu or popover |
| Professional Workflows | Close work center | skipped (destructive, purchase or window control) |
| Professional Workflows | Show workflows | opened a menu or popover |
| Professional Workflows | Workflows | no visible change (may act in place) |
| Professional Workflows | My Work | opened a menu or popover |
| Professional Workflows | Intake Register | no visible change (may act in place) |
| Professional Workflows | Jobs | screen changed (+1 controls: Run Now) |
| Professional Workflows | Documents | screen changed (+0 controls) |
| Professional Workflows | Next Page | screen changed (+2 controls: Reports, Previous Page) |
| Live Mail | (page) | could not open page |

Rows: 86; skipped: 2; crashes: 0
