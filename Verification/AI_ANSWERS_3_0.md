# AI answers — verification, 2026-10-07

mailin 3.0 (build 301), macOS 27, Apple Intelligence on. Archive: the owner's 526 emails (2007–2025). Design rules adopted from kalsmritikosh: counts, dates and amounts come from code; the on-device model only writes prose from the emails it is given; anything the model gets wrong must be caught or labelled.

## Apple Intelligence: what the model can and cannot do (measured on this Mac)

Direct tests outside mailin (`~/mailin-loc-work/fmlimits`), five runs each:

| Test | Result |
|---|---|
| Context size | 8,192 tokens on this OS (Apple's article says 4,096). A 30,000-character input was refused. |
| Add three payments (₹10,000 + ₹20,000 + ₹3,800, one duplicate confirmation) | Wrong 5/5: 47,600 / 47,600 / 37,600 / 47,600 / 37,400 |
| "Who asked for guidance?" over an email with a quoted reply | Refused 5/5 ("I cannot provide information…") |
| "Until when is the annuity paid?" (single sentence) | Right 5/5 |
| Same simple question five times | Identical 5/5 |

Apple's documentation lists basic math and logical reasoning under "capabilities to avoid" and warns that long or complex input can lead the model to hallucinate details.

## How mailin handles those limits

- **Math and counts** — never by the model: payments, yearly counts, topics, senders, Insights, triage on old archives, slot answers ("What is my patent number?"), password scan.
- **Figures in model prose** — a sentence with an amount or long number that appears in none of the emails the model read is removed, and the answer says so.
- **Dates in stories** — "On 12 Mar" anchors that match no email in the thread are removed.
- **Refusals, empty replies, timeouts, errors, model off** — replaced by an answer quoted from the retrieved emails (key passages, the emails in order, a note that the lines are quoted, not AI-written).
- **Input kept small** — quoted earlier messages are cut (each email speaks for its sender); at most 20 relaxed-search additions; at most five helper model calls per question; background analysis uses the NLP engine, not the model; background work waits while a question is answered.
- **Proof the model is used** — every model request is logged (call site, outcome, time, sizes; no content) under subsystem `com.ecosanskriti.mailin`, category `model`.

## Results on the owner's archive

| Check | Result |
|---|---|
| 12 typed questions with known answers (patent number and grant date, application number, total paid, who is, packers' settlement, 2018 train ticket, interviews, manga thread, still-to-do, passwords, emails sent in 2015, hospital claim) | 12/12 correct (one awkward phrasing: "sent by you to you" for a forwarded email) |
| 10 suggestion buttons + a follow-up button | All correct (one test click did not register; the same question asked by typing answered correctly) |
| Settings ▸ AI switch off/on drives the AI Insights page; page activation turns the setting on; status "Apple Intelligence is ready" | Pass |
| 5,000-email synthetic archive with recent dates (counts, payments, passwords, who-is, find) | Correct, each under 3 s |
| Smart Triage on a recent inbox uses the model's urgency groups | Pass (real model, 12 s) |

## Known limits that remain

- Model-written summaries and stories can still word things awkwardly or miss nuance; facts in them are checked for figures and dates, not sentence by sentence for meaning.
- Answers are written in English whatever the interface language.
- Not yet run on iPhone/iPad simulators since these changes, nor with Apple Intelligence turned off live (the fallback is unit-tested).

## Product-wide checks on the final code (2026-10-07)

| Check | Result |
|---|---|
| Full unit suite | 510 XCTest (12 skipped) + 223 Swift Testing: one failure, the privacy guard flagging the new model log. Fixed (log field renamed, error text private) and that guard plus the offline-gate guard re-run green; the whole suite was not re-run after this log-only change |
| Gate suite | 95 tests green |
| Mac button crawl | 343 buttons pressed (Archive 83, Professional Workflows 240, AI Insights 10, menus 9), 0 crashes |
| Release builds | macOS and iOS (generic device) green |
| `Scripts/verify-no-network.sh` on the Release app | PASS — 8 checks, 0 failures: "This signed build cannot open a network connection." |
