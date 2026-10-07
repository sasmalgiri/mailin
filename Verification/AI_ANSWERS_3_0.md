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

## Later the same day (2026-10-07, evening)

| Check | Result |
|---|---|
| AI with Apple Intelligence off (Debug launch switch `-simulateAppleIntelligenceOff`) | Model log: 0 calls. App-built answers unchanged and correct; general questions now answered from the emails (train booking, hospital claim request, interviews, still-to-do, packers) instead of the old NLP summary. |
| iPad simulator after importing Sent.mbox (534 emails) | 10/10 typed questions correct, including the discussion story |

## Redact & Export — verified by its output file

The Mac crawl could not reach the button ("not visible"): the settings had no scroll view and pushed it below the window. Fixed (settings scroll, actions pinned). Then the button was pressed in the app on the owner's archive and both files were checked (`~/mailin-loc-work/check-redaction.py`):

| Check on RedactedExport.txt / RedactionLog.csv | Result |
|---|---|
| Emails exported | 526 of 526 (the export now streams the whole scope; it used to write only the tool's newest 2,000) |
| Every entry has a Date line; attachments listed (redacted names, marked not included) | Yes; 152 entries list attachments |
| Email addresses / phone numbers left in the output | 0 / 0 |
| HTML markup left | 0 tags (HTML-only and HTML-in-plain bodies are converted to text) |
| Long identifiers kept (application no., patent no.) | Yes (phone pattern no longer matches inside longer numbers) |
| Log | 3,707 rows, header once |
| On-screen confirmation | "Exported 526 redacted emails with 6328 redactions." |

Known: the default SSN rule also redacts other 9-digit numbers (booking IDs, link parameters) — over-redaction, not a leak; the rule can be switched off.

Full unit suite on the final code (after the redaction changes): 510 XCTest (12 skipped, 0 failures) + 225 Swift Testing — green.

## 21 more typed questions (2026-10-07, night)

The owner turned AI on in Settings ("Apple Intelligence is ready") and asked for more varied questions. 21 new questions with known answers (counts, years, bills, loans, purchases, attachments, people, a matter's history, a misspelled question):

| Run | Correct |
|---|---|
| First | 8 / 21 |
| After the fixes | 21 / 21 (T1–T13 in one run; T14–T21 rerun after a test-harness stall left the question field unreachable — the app had not crashed) |

What was fixed:
- **App-built answers:** which year or month had the most emails; how many emails a person sent; did I get any emails from X; several years compared; top senders for a year; attachments by file type, year and sender (with filenames); oldest and newest email named; payee read from "buy on Udemy"; receipt totals ("Your Price") counted; "how much … approved" quotes the sentence with the amount (one per conversation); a matter's history as a dated timeline of its own conversations, with milestones quoted.
- **Typos:** misspelled routing words are corrected ("wat is my patnt numbr" → patent number 555489).
- **Model answers:** a "nothing found" claim when the emails read do match is replaced by the quoted answer. Sources no longer cite every email the owner sent because the owner's name appears in the answer.

Still imperfect:
- One Abbott email is stored as raw MIME, so the model quoted MIME boundaries from it.
- The Udemy answer shows the receipt's link text, not the course name.
- The oldest email is reported as the owner's own message, which has the same timestamp as the bounce notice.

Gate suites: 102 Swift Testing + 68 XCTest, green.
