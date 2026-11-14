# Owner-run checks — scripts (7 November 2026)

Three runs only the owner can do, each recorded the same way so the result is release evidence.
Record for every run: **app commit and build number, macOS version, Mac model, the fixture (name + SHA-256), the
result line by line, and the folder the logs/receipts were saved to.** A failed step is a defect to file, not a
reason to stop the run; note it and continue.

Before all three: build the candidate in **Release**, launch it once, and confirm in Settings ▸ Health that the
"Formats" list shows the real-file evidence and the "Limits" list names the per-run ceilings.

---

## Script 1 — Gate 1: the five journeys and the six LIFE checks, by hand

Use a disposable archive (Archive location ▸ a new folder on this Mac). Fixtures: `maxmailinTests/Fixtures/opensource`
(real Outlook .msg files, protected Office files) and one PST of your own.

| # | Step | Expected | Record |
|---|---|---|---|
| 1 | Import the PST, then three .msg files from `opensource/tika` (`testMSG.msg`, `testMSG_att_msg.msg`, `attachment_msg_pdf.msg` from `poi`) | The import receipt shows each source with parsed = committed; folders of the PST appear in the sidebar tree, empty ones included | receipt path |
| 2 | Open the message from `testMSG_att_msg.msg` | An attached message is listed; its own attachment appears under **Contents**; **Open** opens the file | screenshot |
| 3 | Search (Advanced Search) for an attachment of type `pdf` containing a word from the PDF inside `attachment_msg_pdf.msg` | Exactly that message; the evidence chip names the PDF; the chip opens it | — |
| 4 | Import `public-pack/04_import_ready_eml/07_7zip_AES256.eml`; open the message | The ZIP shows **Locked**; **Unlock…** with a wrong password says so; with `mailin-fixture-2026` and "Keep searchable" on, the README marker `MAILIN-PROTECTED-CONTENT-20261107` becomes findable | — |
| 5 | Duplicates: import `testMSG.msg` a second time with dedup off (Settings ▸ Import), then run Find duplicates | One group, class **content-equivalent** or **byte-identical** stated on screen; the **Compare** button shows the two copies side by side; bulk removal offers only the verified group | — |
| 6 | Export the PST's Inbox as .eml folder, then **Verify export** on the receipt | "rehash checked N of N" and "content checked N of N files say what the archive says" both appear | receipt path |
| LIFE-01 | Quit, move the original PST away, relaunch, open a PST message with an attachment | Still opens (self-contained copy) | — |
| LIFE-02 | Settings ▸ Health ▸ Back up archive…, then Restore from backup… into an empty folder | Counts equal; a search from step 3 finds the same message | — |
| LIFE-03 | Start a second import while a search is open | The list grows, never shrinks; the search re-runs cleanly | — |
| LIFE-04 | Finder ▸ Get Info on the archive folder | Owner-only permissions | — |
| LIFE-05 | Settings ▸ Health ▸ Recovery | Every action present: Retry failed imports, Rebuild search index, Re-read attachments from the original files, Restore… | — |
| LIFE-06 | Settings ▸ Purchases with the sandbox account | The plan state is shown; after a sandbox expiry the archive stays readable and .eml/mbox export stays uncapped | — |

---

## Script 2 — Gate 5 / OUT-05: destination clients

Export the same 20 messages (with at least two attachments among them) twice: as an **.eml folder** and as **mbox**.
Keep the export receipts and the inventory file.

| Client | Steps | Expected | Record |
|---|---|---|---|
| Apple Mail | File ▸ Import Mailboxes ▸ "Files in mbox format" ▸ pick the mbox | 20 messages; attachments open; dates and senders as in mailin | Mail version (Mail ▸ About) |
| Apple Mail | Drag the .eml folder's files onto a mailbox | 20 messages | — |
| Thunderbird (if you claim it) | Tools ▸ Import ▸ Mail ▸ mbox (ImportExportTools NG or built-in) | 20 messages; attachments open | Thunderbird version |
| Outlook (optional) | Export the same 20 as PST; File ▸ Open ▸ Outlook Data File | Folder tree and 20 messages | Outlook version |

Compare one message per client against mailin's detail view: subject, sender, date, body, attachment names and
sizes. Any difference is a defect: file it with the receipt and the inventory.

---

## Script 3 — Gate 10: usability pilot (9 of 10 on each task)

Ten people, or as many as you can get; each person is new to the app. One Mac, Release build, the sample
archive plus one PST. Time each task; a task passes when the person finishes without help in under five minutes
and can say what the app told them. Record pass/fail per person per task and every sentence of confusion.

1. Import the PST and say how many messages came in and whether anything failed.
2. Find every message with an attachment that mentions a word you give them; open one attachment from the result.
3. Find a message inside a ZIP attachment (give the word); open the file inside the ZIP.
4. Tell you whether two given messages are the same message or not, and why.
5. Export a folder as .eml, then prove the export is complete and unchanged.
6. Unlock a password-protected attachment (give the password) and make its text searchable.
7. Back up the archive and restore it to a new location.
8. Find out, from the app alone, what kinds of files it cannot read yet.

A task that fewer than 9 of 10 complete is a usability defect: record what they tried, not what they should have done.
