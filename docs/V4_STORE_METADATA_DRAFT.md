# mailin 4.0 — store metadata for the connected edition (V4-14), updated 2026-11-21 (positioning)

**Owner decision 2026-11-14:** release v4.0 (build 1000) with connected mail on the existing App Store record:
Gmail over IMAP + Google app password (Google sign-in returns in a 4.0.x update after Google verification);
Outlook / Microsoft 365 via Microsoft sign-in (`Mail.Read`, `User.Read`, `offline_access`; `Mail.Send` /
`Mail.ReadWrite` only on request); iCloud Mail, Fastmail and other IMAP with passwords; **no cloud AI**.
Owner steps: [`RELEASE_4_0_CHECKLIST.md`](RELEASE_4_0_CHECKLIST.md).

English source text; translate into the 10 listing languages with the 3.0.2 listing tooling once approved. Claims are
limited to what the code does. Real-provider evidence (V4-15, `FIVE_JOBS_TRACKER.md`): Gmail over IMAP added and
capturing 2026-11-14; Outlook / Microsoft 365 signed in, folders listed, a real message saved and a message sent
2026-11-15. **Owner decision 2026-11-15: the listing leads with what people buy mailin for — the five jobs and
Live Mail — in that order, first in every field.**

Rules applied (plan §10, §13.8, §0): connected mail is **optional and off until turned on**; it talks **directly** to
the user's provider; **no AI through a provider is advertised** — v4 has disabled BYOK scaffolding only, so the plan's
phrase "optional AI through your chosen provider" is **not used**. Accurate form used instead:
**"Local archive and search. Optional connected mail, directly with your own provider."**
No price change, no new purchase product. No provider trademarks in keywords (guideline 2.3.7); naming the providers
the app works with in the description is factual.

## Positioning (owner 2026-11-21, from the owner's demand research)

Lead with the problem–feature fit that users ask for; everything else is secondary.

- **Headline:** Open large email archives quickly. Keep your folders and attachments. Find what matters. Handle
  duplicates safely. Export with verification. **Then:** Keep the archive growing with optional live-mail preservation.
- **Recurring value** (why a subscription): the archive keeps growing (new files, live-mail preservation) and is
  searched again and again. A one-time "open / convert one archive" need is served by the lifetime plan.
- **Evidence (owner's research, small self-selected sample):** users asking to keep a growing 10 GB offline archive
  without duplicates (reddit r/macapps 1crfqj6); batch MBOX → individual PDF export with meaningful names
  (r/macapps 1wgh4tm — a one-time need); attachment search (DEVONtechnologies forum 64412); fear of losing mail
  before deleting server copies; reluctance to upload mail history elsewhere.
- **Secondary, one line each:** compose / send, iPhone / iPad, Recipes, Professional tools (holds, review, Bates,
  recovery), on-device AI. Not purchase drivers until validated; AI is never in the subtitle or promotional text.
- **Engineering is not a selling point:** say "imports quickly" with a measured example, never "dynamic workers" or
  "adaptive memory".
- **Not yet known:** how many target users choose mailin, finish these jobs and keep paying — the next validation
  measures that with prospective customers.
- Claims checked against the code 2026-11-21: per-message export names = number + subject (`messageFilename`);
  "Show text" opens at the highlighted match (`ExtractedTextSheet`, R7); removed duplicates go to the Trash
  (`DeferredDeduplication`); import speed = FAST-06 measurement (213 MB / 56,699 messages, 29.7 s, Release, quiet
  Apple-silicon Mac).

## Name / subtitle

- Name: **mailin** (unchanged)
- Subtitle (≤30): **Open, search & keep old email** (29) — alternative: "Archive, search & live mail" (27)

## Promotional text (≤170)

Open large email archives quickly, keep every folder and attachment, find what matters, handle duplicates safely and export with proof. Keep it growing with live mail.

(167 characters.)

## Description

Open large email archives quickly. Keep your folders and attachments. Find what matters. Handle duplicates safely. Export with verification. Then keep the archive growing with optional live-mail preservation — all on your own Mac, iPhone or iPad.

1. OPEN LARGE ARCHIVES QUICKLY
• MBOX (Google Takeout, Thunderbird, Apple Mail), EML, EMLX, MSG, PST, OST, Outlook for Mac (OLM), Lotus Notes (NSF) and ZIP — drop the file in.
• Fast import reads mailbox files in parallel: in our tests a 213 MB mailbox of 56,699 messages was imported in about 30 seconds on an Apple-silicon Mac.
• Streams from disk, so size is bounded by your storage, not by mailin. It says exactly what it could not read, and an interrupted import resumes by itself.

2. KEEP YOUR FOLDERS AND ATTACHMENTS
• Outlook folders come through as they were, empty ones included; Gmail labels stay labels — one message, all its labels.
• Attachments and message details are kept with every message. The archive keeps its own verified copy of each mailbox file, so it still works if the original is moved or deleted.

3. FIND WHAT MATTERS
• Searches inside PDFs, Word, Excel, PowerPoint and Pages files, and in scanned images and photos (on-device OCR) — and shows where the match is, opening the attachment's text at the highlighted words.
• Advanced Search (AND / OR / NOT, dates, senders, attachment conditions) and a Whole words option, in every plan. Every search says how much of the archive it covered.

4. HANDLE DUPLICATES SAFELY
• Byte-identical copies are told apart from look-alikes, which are never bulk-removed. You see the count first, and removed copies go to the Trash, where they can be restored.
• Adding the same mailbox again adds nothing twice.

5. EXPORT WITH VERIFICATION
• PST, MBOX, EML, PDF (one PDF per message, named by its subject), CSV and more.
• Every export ends with a receipt: the output is read back and compared with the archive, and any difference is named — so you know your mail is safe before you delete it from the server. Interrupted exports resume.

KEEP IT GROWING
• Add new mailbox files whenever you like; messages already in the archive are skipped.
• Optional live-mail preservation: connect Outlook / Microsoft 365, Gmail, iCloud Mail, Fastmail or any IMAP account, and every new message is saved into your archive — and stays there even if the server deletes it. Off until you add an account; your device talks directly to your provider, with no mailin server or relay.
• You choose what each account may do: Preserve mail, Send mail, Change server mail (only changes you confirm). Gmail connects with a Google app password; Outlook signs in on Microsoft's own page. Passwords and tokens stay in this device's Keychain.

ALSO INCLUDED
• A mailbox to read, write and send: formatting, signatures, attach files or archived messages, Undo Send.
• The same archive features on iPhone and iPad, and Recipes that guide common jobs step by step.
• Professional plan: custodians and legal holds, chain of custody, review and production with Bates numbering, recovery of deleted mail still inside mailbox files.
• Optional on-device AI insights (Apple Intelligence), off until you turn them on.

PRIVATE BY DESIGN
• No mailin server, no analytics, no tracking, no account with us. No cloud AI.

Plans: Free, Personal and Professional, monthly, yearly or lifetime — unchanged. Terms of Use: https://sasmalgiri.github.io/mailin/terms/

(3,433 characters, under the 4,000 limit.)

## Keywords (≤100)

mbox,eml,pst,olm,msg,email archive,backup,takeout,search attachments,duplicates,export pdf,imap

(95 characters. No "gmail"/"outlook"/"icloud" — trademarks, guideline 2.3.7. "offline" left out: the 4.0
build connects to mail servers when the user turns it on.)

## What's New in 4.0

LIVE MAIL — THE FIVE JOBS NOW WORK ON YOUR LIVE MAIL TOO
• Connect Outlook and Microsoft 365, Gmail, iCloud Mail, Fastmail or any IMAP account — optional, off until you add one. Your device talks directly to your provider: no mailin server, no relay.
• Preserve mail saves a read-only copy of every message into your archive, so folders, search, duplicates and verified export work on it — and it stays even if the server deletes it.
• An Apple Mail–style mailbox with Thunderbird-style tools: message previews, hover and swipe actions, a quick filter (text, unread, flagged, attachments, tags), colour tags, conversations, smart folders and actions on several messages at once.
• Write and send: bold, italic, colours, lists and links; signatures per account; drag files in, or attach messages straight from your archive. Undo Send holds a message before it goes.
• You decide what each account may do: Preserve mail, Send mail and Change server mail (mark, flag, move to another folder, move to Trash and restore — only when you ask, every change listed).
• Remove an account and keep its mail, or delete it too — counts first, then progress.
• Gmail connects with a Google app password; Outlook with Microsoft's own sign-in.

FASTER IMPORT
• Large mailboxes import several times faster: mailbox files are read in parallel and duplicates are sorted out after everything is saved. On by default; switch it off for any single import in the import window.

ALSO NEW
• Advanced Search is now in every plan — and one click away beside the search box (⌥⇧⌘F), with a Whole words option and a list of the search operators.
• New Message from any page (⌥⌘N).
• Long emails print in full on every page; every date shows its year; the date range and counts always describe the whole list.
• Recipes show what they found and what they changed.

(About 1,150 characters, under the 4,000 limit. Translations: the owner pastes the English or uses App Store Connect's per-language fields; the app itself is in 10 languages.)

## App Review notes (paste into App Store Connect ▸ App Review Information ▸ Notes)

mailin is a local email archive. Version 4.0 adds optional connected mail, which is OFF on a fresh install. There is no mailin server, no sign-up and no data collection; the device connects directly to the account's own mail provider. Cloud AI is not included.

To test connected mail (Mac; iPhone / iPad use the same names in Settings):
1. Click the "Live Mail" tab (or Settings ▸ Modules ▸ Live Mail) and turn it on. The sheet explains that this connects to nothing by itself; no second switch is needed.
2. (Nothing else to enable: "Connected mail" under Live Mail ▸ Features… is on by default once the page is on.)
3. Open the Live Mail tab ▸ "Add account" (sidebar, bottom left) and choose a provider:
   • Gmail: 4.0 connects Gmail over IMAP with a Google app password — there is no Google sign-in page in this version. Enter the demo Gmail address and paste its 16-character app password into "App password". The servers are filled in (imap.gmail.com:993 and smtp.gmail.com:465, TLS).
   • iCloud Mail: enter the demo iCloud address and its app-specific password.
   • Outlook and Microsoft 365: enter the demo Outlook.com address, click "Sign in…" and sign in on Microsoft's page. Only reading mail is requested (Mail.Read, User.Read, offline_access); sending or changing mail asks again when that switch is turned on.
4. The new account has Preserve mail, Send mail and Change server mail all off. Switch on Preserve mail, then "Sync now": folders and counts appear, and messages can be opened and searched in the Archive.
5. Switch on Send mail (Outlook asks once for the send permission; Gmail and iCloud send with the same app password over SMTP). Write a message to any address you control and send it from the outbox.
6. Change server mail works for the Outlook and iCloud / IMAP accounts: select a message ▸ "On the server" ▸ mark read / unread, flag, "Move to" another folder, "Move to the server's Trash…" (count shown first) and, for a message in Trash, "Restore from the server's Trash". For Gmail over IMAP it is not available in 4.0: the switch is disabled with the reason "Not available for Gmail with an app password in this version. Saving and sending mail work." A Gmail message sits in several label folders, so a folder-level change is not safe; it returns with Google sign-in in 4.0.x.
7. Also try: the quick filter above the list, right-click ▸ Tag, Group by Conversation (⋯ menu), and in a new message "Attach from Archive…" (attaches any archived message as an .eml).
8. Remove the account: Accounts and status ▸ the account ▸ "Remove". "Remove" keeps the saved mail; "Remove and Delete Mail…" also deletes it after showing the count. The account's password or tokens are deleted from the Keychain.

Demo accounts (credentials are in the App Review sign-in fields, never in public text): a Gmail address with 2-Step Verification on and a Google app password created at myaccount.google.com/apppasswords (not the Google account password — Gmail refuses that over IMAP), or an iCloud address with an app-specific password; and an Outlook.com account for the Microsoft sign-in. Each demo mailbox should hold a few messages and one folder / label.
Without an account, every archive feature works: File ▸ Open with the attached sample .mbox.
Purchases use StoreKit; the Professional tools need a Professional purchase (sandbox account).

(Owner: the menu names above are those in `ModulesSettingsView` ("Features…"), `Capability` ("Connected mail"),
`ModuleRegistry` ("Live Mail") and `MailAccountViews` ("Add account…", "Sign in…", "Sync now", "Remove account…",
"Remove and Delete Mail…") at 7d35777 — confirm on the candidate. Attach a small sample .mbox to the submission.)

### Gmail sign-in mode (V4-16)

4.0 for the App Store ships `MailinGmailSignInMode = imap` in `Info-Connected.plist`: the Gmail entry in Add account is
Gmail over IMAP with an app password, and Google sign-in (OAuth, Gmail API) is switched off — its code stays in the
app (rule 14). TestFlight / demo builds that need Google sign-in set the key to `oauth`; 4.0.x ships `oauth` once
Google has verified the restricted Gmail scopes (`V4_PROVIDER_REGISTRATION.md` §1). `Scripts/check-connected-release.sh`
prints the mode of the built app (step 5).

## Screenshots (owner, on the candidate; use demo mail, not a personal mailbox)

The first screenshots are what people look at; they follow the same order as the listing. One caption line on each.

**The ten pictures (owner 2026-11-19).** Pictures 1–5 are the five jobs — the reason the product exists
(`FIVE_JOBS_MASTER_PLAN.md` §1: open large archives, preserve folders, search messages and attachments, identify
duplicates safely, verify exports) — in the order of the description. 6–7 are what 4.0 adds (Live Mail). 8–10 show
the three properties every job rests on: private by design, honest counts, and the recipes that string the jobs
together. Nothing else (AI, Professional tools, studios) goes on the listing: those are secondary in the description too.

Mac (2880 × 1800 or 1440 × 900), on the candidate, demo mail only, one caption line each:
1. **Open large archives** — a big PST or Takeout MBOX just opened: the import receipt with its counts (Complete, X of X). Caption: "Open huge archives — PST, MBOX, EML, MSG, OST, OLM, NSF."
2. **Keep every folder** — the Archive sidebar: the original folder tree with counts, an empty folder kept, nested folders. Caption: "Every folder, exactly as it was."
3. **Search messages and attachments** — a search that matched inside a PDF or Word attachment, the "where it matched" chip and the coverage line. Caption: "Find words inside attachments and scans."
4. **Find duplicates safely** — the duplicates view: a byte-identical group and a "similar, not identical" group, the count shown before moving. Caption: "Duplicates found safely — counts first."
5. **Export with proof** — an export receipt that verified every file (rehash + content). Caption: "Every export ends with a receipt."
6. **Live Mail** — the mailbox: accounts in the sidebar, previews, a message open. Caption: "New: your live mail, in the same place."
7. **Preserve mail** — an account's sheet with Preserve mail on and the capture progress / "Sync now", or the Archive showing captured mail with its labels. Caption: "Preserve mail saves every message into your archive."
8. **Private by design** — Settings ▸ Health ▸ Mail network (every connection listed, nothing else) or the About privacy line. Caption: "No mailin server. Your device talks only to your provider."
9. **Honest counts** — Advanced Search with the result count and "covered N of M" line, or the Free plan's "newest 500" notice. Caption: "Every search says what it covered."
10. **Recipes** — Recipes ▸ "Find & export": choose → review → result with the receipt. Caption: "Find, review, export — one guided run."

iPhone / iPad (up to 10 each): 1, 3, 5, 6 at least; 2, 4, 7, 10 if the layout reads at phone size (GATE1_UI_WALK_2026-11-18.md walked them).

Do not reuse 3.0 screenshots that show "Live Mail is not included" or "Offline & Private" on the connected listing.

## Fields that change from the 3.0 listing

| Field | 3.0 | 4.0 connected |
|---|---|---|
| Promotional text | "…No account, nothing leaves your Mac." | the text above (drop "nothing leaves your Mac") |
| App Privacy | Data Not Collected | owner decision, `V4_APP_PRIVACY_ANSWERS.md` |
| Privacy Policy URL | `/privacy` (offline text, now archived at `/privacy/3.0.html`) | same URL, 4.0 text in `docs/privacy/index.html` — **public only after the site is published; publish before submitting** |
| Sign-in required | No | No (provider sign-in is optional; give the demo account anyway) |
| Review notes | `docs/AppStoreConnect.md` | the notes above |
