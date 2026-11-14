# mailin 4.0 — store metadata for the connected edition (V4-14), updated 2026-11-15

**Owner decision 2026-11-14:** release v4.0 (build 1000) with connected mail on the existing App Store record:
Gmail over IMAP + Google app password (Google sign-in returns in a 4.0.x update after Google verification);
Outlook / Microsoft 365 via Microsoft sign-in (`Mail.Read`, `User.Read`, `offline_access`; `Mail.Send` /
`Mail.ReadWrite` only on request); iCloud Mail, Fastmail and other IMAP with passwords; **no cloud AI**.
Owner steps: [`RELEASE_4_0_CHECKLIST.md`](RELEASE_4_0_CHECKLIST.md).

English source text; translate into the 10 listing languages with the 3.0.2 listing tooling once approved. Claims are
limited to what the code does at 7d35777. Real-provider evidence (V4-15, `FIVE_JOBS_TRACKER.md`): Gmail over IMAP
account added and capture started 2026-11-14 (owner accepted Gmail without a count comparison); **Outlook not yet
run on a real account** — lines marked (V4-15 Outlook) describe what the code does and must be walked on a real
Outlook / Microsoft 365 account before submission, or removed.

Rules applied (plan §10, §13.8, §0): connected mail is **optional and off until turned on**; it talks **directly** to
the user's provider; **no AI through a provider is advertised** — v4 has disabled BYOK scaffolding only, so the plan's
phrase "optional AI through your chosen provider" is **not used**. Accurate form used instead:
**"Local archive and search. Optional connected mail, directly with your own provider."**
No price change, no new purchase product. No provider trademarks in keywords (guideline 2.3.7); naming the providers
the app works with in the description is factual.

## Name / subtitle

- Name: **mailin** (unchanged)
- Subtitle (≤30): **Mail archive, search, export** (or keep "Email Archive Analyzer")

## Promotional text (≤170)

Local archive and search. Optional connected mail, directly with your own provider: save Gmail, Outlook and IMAP mail into an archive you own. Off until you turn it on.

## Description

mailin keeps your email in an archive you own — on your Mac, iPhone or iPad — and lets you open, search, de-duplicate and export it with proof of what was exported.

LOCAL ARCHIVE AND SEARCH
• Open large archives: MBOX (Google Takeout, Thunderbird, Apple Mail), EML, EMLX, MSG, PST and OST, and more.
• Keep every folder exactly as it was.
• Search messages and the text inside attachments, with Advanced Search in every plan.
• Find duplicates safely: nothing is removed without showing you the count first.
• Export to the formats reviewers use, with a receipt that verifies every file.

OPTIONAL CONNECTED MAIL — OFF UNTIL YOU TURN IT ON
• Add Gmail, Outlook / Microsoft 365, iCloud Mail, Fastmail or another IMAP account. Your device connects directly to that provider — there is no mailin server and no relay.
• Each account starts with nothing allowed. Switch on, one by one: Preserve mail (a read-only copy into your archive), Send mail (from your outbox, only when you send), Change server mail (only changes you confirm).
• Saved mail goes through the same five jobs as imported files: folders, search, duplicates and verified export.
• Gmail connects over IMAP with a Google app password (Google requires 2-Step Verification; create the app password at myaccount.google.com/apppasswords). Gmail mail is saved and can be sent; changing Gmail mail on the server is not available in this version. Outlook / Microsoft 365 sign-in happens on Microsoft's own page. Passwords and sign-in tokens stay in this device's Keychain and are sent only to that provider.
• Remove an account at any time; its saved mail stays in your archive unless you choose to delete it too.

PRIVATE BY DESIGN
• mailin collects no data: no analytics, no tracking, no account with us.
• No cloud AI. On-device features use Apple's frameworks on your device.
• An offline edition, whose sandbox has no network access, remains available for organisations that need it.

Plans: Free, Personal and Professional, monthly, yearly or lifetime — unchanged. Terms of Use: https://sasmalgiri.github.io/mailin/terms

## What's New in 4.0

LIVE MAIL — YOUR MAIL AND YOUR ARCHIVE IN ONE PLACE
• Connect Outlook and Microsoft 365, Gmail, iCloud Mail, Fastmail or any IMAP account — optional, off until you add one. Your device talks directly to your provider: no mailin server, no relay.
• Preserve mail saves a read-only copy of every message into your archive, so folders, search, duplicates and verified export work on it — and it stays even if the server deletes it.
• An Apple Mail–style mailbox with Thunderbird-style tools: message previews, hover and swipe actions, a quick filter (text, unread, flagged, attachments, tags), colour tags, conversations, smart folders and actions on several messages at once.
• Write and send: bold, italic, colours, lists and links; signatures per account; drag files in, or attach messages straight from your archive. Undo Send holds a message before it goes.
• You decide what each account may do: Preserve mail, Send mail and Change server mail (mark, flag, move to Trash — only when you ask, every change listed).
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
1. Open Settings ▸ Modules. Switch on "Live Mail" (the sheet explains that enabling the page connects to nothing by itself).
2. Next to Live Mail, click "Features…" and make sure "Connected mail" is on.
   (Steps 1–2 are already on in a fresh 4.0 install if the Live Mail tab shows a green dot.)
3. Open the Live Mail tab ▸ "Add account" (sidebar, bottom left) and choose a provider:
   • Gmail: 4.0 connects Gmail over IMAP with a Google app password — there is no Google sign-in page in this version. Enter the demo Gmail address and paste its 16-character app password into "App password". The servers are filled in (imap.gmail.com:993 and smtp.gmail.com:465, TLS).
   • iCloud Mail: enter the demo iCloud address and its app-specific password.
   • Outlook and Microsoft 365: enter the demo Outlook.com address, click "Sign in…" and sign in on Microsoft's page. Only reading mail is requested (Mail.Read, User.Read, offline_access); sending or changing mail asks again when that switch is turned on.
4. The new account has Preserve mail, Send mail and Change server mail all off. Switch on Preserve mail, then "Sync now": folders and counts appear, and messages can be opened and searched in the Archive.
5. Switch on Send mail (Outlook asks once for the send permission; Gmail and iCloud send with the same app password over SMTP). Write a message to any address you control and send it from the outbox.
6. Change server mail (mark read, flag, move, move to Trash — each change listed before it runs) works for the Outlook and iCloud / IMAP accounts. For Gmail over IMAP it is not available in 4.0: the switch is disabled with the reason "Not available for Gmail with an app password in this version. Saving and sending mail work." A Gmail message sits in several label folders, so a folder-level change is not safe; it returns with Google sign-in in 4.0.x.
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

## Screenshots (owner, on the candidate; use a demo mailbox, not a personal one)

Mac (2880 × 1800 or 1440 × 900), in this order:
1. Live Mail with a demo account: folders in the sidebar with counts, the list with previews, a message open on the right.
2. The quick filter in use (text typed, Unread on) with colour tags on a few messages.
3. The composer: To / Subject / From, the formatting bar, one attachment chip, a signature.
4. Accounts and status: the three switches (Preserve mail, Send mail, Change server mail) and the status block.
5. Archive search showing a captured message next to an imported one.
6. Add account sheet (Outlook and Microsoft 365 / Gmail app password guidance).

iPhone / iPad: the same 1, 3 and 4 if the layout has been checked on device (not yet done, see the tracker).

Do not reuse 3.0 screenshots that show "Live Mail is not included" or "Offline & Private" on the connected listing.

## Fields that change from the 3.0 listing

| Field | 3.0 | 4.0 connected |
|---|---|---|
| Promotional text | "…No account, nothing leaves your Mac." | the text above (drop "nothing leaves your Mac") |
| App Privacy | Data Not Collected | owner decision, `V4_APP_PRIVACY_ANSWERS.md` |
| Privacy Policy URL | `/privacy` (offline text, now archived at `/privacy/3.0.html`) | same URL, 4.0 text in `docs/privacy/index.html` — **public only after the site is published; publish before submitting** |
| Sign-in required | No | No (provider sign-in is optional; give the demo account anyway) |
| Review notes | `docs/AppStoreConnect.md` | the notes above |
