# mailin 4.0 — store metadata for the connected edition (V4-14), updated 2026-11-15

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

## Name / subtitle

- Name: **mailin** (unchanged)
- Subtitle (≤30): **Archive, search & live mail** (27) — alternative: "Open, search, export mail" (25)

## Promotional text (≤170)

Open huge mail archives, keep every folder, search inside attachments, find duplicates safely and export with proof. New: Live Mail for Outlook, Gmail, iCloud and IMAP.

(168 characters.)

## Description

mailin does the five things people need from an email archive — properly, on your own Mac, iPhone or iPad — and now brings your live mail into the same place.

1. OPEN LARGE ARCHIVES
• MBOX (Google Takeout, Thunderbird, Apple Mail), EML, EMLX, MSG, PST, OST, Outlook for Mac (OLM), Lotus Notes (NSF) and ZIP — drop the file in and you are in it.
• Streams from disk: size is bounded by your storage, not by mailin. It says exactly what it could not read, and resumes by itself.

2. KEEP EVERY FOLDER
• Outlook folders come through as they were, empty ones included; Gmail labels stay labels — one message, all its labels.

3. SEARCH MESSAGES AND ATTACHMENTS
• Finds words inside PDFs, Word, Excel, PowerPoint and Pages files, and in scanned images and photos (on-device OCR).
• Advanced Search (AND / OR / NOT, dates, senders, attachment conditions) in every plan. Every search says how much of the archive it covered.

4. FIND DUPLICATES SAFELY
• Byte-identical copies are told apart from look-alikes. Nothing is removed without showing you the count first; look-alike groups are never bulk-removed.

5. EXPORT WITH PROOF
• PST, MBOX, EML, PDF and more. Every export ends with a receipt: outputs are read back and compared with the archive, and any difference is named. Interrupted exports resume.

NEW IN 4.0 — LIVE MAIL
• Connect Outlook / Microsoft 365, Gmail, iCloud Mail, Fastmail or any IMAP account. Off until you add one; your device talks directly to your provider — no mailin server, no relay.
• Preserve mail saves every message into your archive, so the five jobs above work on your live mail too — and the copy stays even if the server deletes it.
• An Apple Mail–style mailbox with quick filter, colour tags, conversations and smart folders. Write with formatting and signatures, attach files or messages from your archive, Undo Send.
• You choose what each account may do: Preserve mail, Send mail, Change server mail (only changes you confirm, each listed).
• Gmail connects with a Google app password (2-Step Verification; myaccount.google.com/apppasswords); changing Gmail mail on the server is not available in this version. Outlook signs in on Microsoft's own page. Passwords and tokens stay in this device's Keychain.

PRIVATE BY DESIGN
• No mailin server, no analytics, no tracking, no account with us. No cloud AI.

Plans: Free, Personal and Professional, monthly, yearly or lifetime — unchanged. Terms of Use: https://sasmalgiri.github.io/mailin/terms/

## What's New in 4.0

LIVE MAIL — THE FIVE JOBS NOW WORK ON YOUR LIVE MAIL TOO
• Connect Outlook and Microsoft 365, Gmail, iCloud Mail, Fastmail or any IMAP account — optional, off until you add one. Your device talks directly to your provider: no mailin server, no relay.
• Preserve mail saves a read-only copy of every message into your archive, so folders, search, duplicates and verified export work on it — and it stays even if the server deletes it.
• An Apple Mail–style mailbox with Thunderbird-style tools: message previews, hover and swipe actions, a quick filter (text, unread, flagged, attachments, tags), colour tags, conversations, smart folders and actions on several messages at once.
• Write and send: bold, italic, colours, lists and links; signatures per account; drag files in, or attach messages straight from your archive. Undo Send holds a message before it goes.
• You decide what each account may do: Preserve mail, Send mail and Change server mail (mark, flag, move to another folder, move to Trash and restore — only when you ask, every change listed).
• Remove an account and keep its mail, or delete it too — counts first, then progress.
• Gmail connects with a Google app password; Outlook with Microsoft's own sign-in.

ALSO NEW
• Advanced Search is now in every plan.
• Recipes show what they found and what they changed.

(About 1,150 characters, under the 4,000 limit. Translations: the owner pastes the English or uses App Store Connect's per-language fields; the app itself is in 10 languages.)

## Keywords (≤100)

mbox,eml,pst,msg,email archive,imap,takeout,backup,search,ediscovery,duplicates,export,smtp

(91 characters. No "gmail"/"outlook"/"icloud" — trademarks, guideline 2.3.7. "offline" dropped: the 4.0 App Store
build connects to mail servers when the user turns it on.)

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
