# mailin — Shortcuts and command-line automation (3.1, preview)

Turn on **Settings ▸ Modules ▸ Shortcuts actions**. Until then every mailin action in Shortcuts says it is off and does nothing.

## Actions

| Action | Input | Output | Notes |
|---|---|---|---|
| Find Emails (automatic) | Filters: From, Subject, Preview (text), Date, Has Attachments, Recovered; "all" or "any" | Emails | Up to 10,000 emails per Find (a Shortcuts list is held in memory). Use **Count Emails** for the exact total |
| Count Emails in mailin | Search (mailin search syntax) | Number | Exact, whole archive |
| Tag Emails in mailin | Search, Tag | Summary text with the email-set fingerprint | Shows the count and asks first; needs the Reviewer role or higher |
| Place Legal Hold in mailin | Search | Summary text with fingerprint | Shows the count and asks first; needs the Examiner role or higher |
| Export Emails as CSV from mailin | Search | CSV file | Every matching email, streamed; fails if the archive changed during the export |
| Search Emails in mailin | Search | Text | Exact total and the first 10 |

Search uses the same syntax as the app's search field: `from:anna@example.com has:attachment after:2024-01-01 is:recovered -tag:reviewed`.

Tag and hold runs go through the same engine as the app: they show progress in the app, can be cancelled, and write an audit entry only after the work happened. A stopped run reports "X of Y".

## From Terminal (macOS)

Build a shortcut in the Shortcuts app (for example "mailin Export" containing *Export Emails as CSV from mailin* followed by *Save File*), then:

```sh
shortcuts run "mailin Export" --input-path query.txt --output-path export.csv
```

`query.txt` holds the search text. `shortcuts list` shows your shortcuts. Actions that ask for confirmation (tag, hold) show their prompt on screen; run them from Terminal only when someone is at the Mac.

## Folder watch (macOS)

Shortcuts ▸ Automation ▸ "When a file is added to a folder" can run *Count Emails* or an export each time a new mailbox lands. mailin itself never watches folders or connects to a network.
