# mailin 4.0 — store metadata draft for the connected edition (V4-14)

English source text; translate into the 10 listing languages with the 3.0.2 listing tooling once approved. Claims are
limited to what the code does at d4a3ec3 and what V4-15 must still prove on the candidate — **any line marked (V4-15)
stays out of the submitted listing until that journey has passed on a real provider account.**

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
• Gmail connects over IMAP with a Google app password (Google requires 2-Step Verification; create the app password at myaccount.google.com/apppasswords). Outlook / Microsoft 365 sign-in happens on Microsoft's own page. Passwords and sign-in tokens stay in this device's Keychain and are sent only to that provider.
• Remove an account at any time; its saved mail stays in your archive.

PRIVATE BY DESIGN
• mailin collects no data: no analytics, no tracking, no account with us.
• No cloud AI. On-device features use Apple's frameworks on your device.
• An offline edition built without any network code remains available for organisations that need it.

Plans: Free, Personal and Professional, monthly, yearly or lifetime — unchanged. Terms of Use: https://sasmalgiri.github.io/mailin/terms

## What's New in 4.0

• Connected mail (optional, off until you turn it on): save Gmail, Outlook / Microsoft 365 and IMAP mail into your archive, directly from your provider. Gmail connects over IMAP with a Google app password; each Gmail message is saved once, with all its labels. (V4-15, V4-16)
• Drafts and an outbox: messages wait until you send them; nothing is sent twice. (V4-15)
• Server changes you confirm — mark read, flag, move, Trash — each listed first. (V4-15)
• Advanced Search is now in every plan.
• Recipes show what they found and what they changed.
• Folders, search, duplicates and verified export work the same for saved and imported mail.

## Keywords (≤100)

mbox,eml,pst,msg,email archive,imap,takeout,backup,search,ediscovery,duplicates,export,offline

(94 characters. No "gmail"/"outlook" — trademarks.)

## App Review notes (paste into App Store Connect ▸ App Review Information ▸ Notes)

mailin is a local email archive. Connected mail is optional and OFF on a fresh install.

To test connected mail:
1. Settings ▸ Modules ▸ switch on "Live Mail" (the sheet explains that enabling it connects to nothing), and make sure "Connected mail" is on.
2. Open the Mail page ▸ Add account.
   • Gmail (4.0 connects Gmail over IMAP — there is no Google sign-in page in this version): choose Gmail, enter <DEMO GMAIL ADDRESS> and paste the 16-character Google app password below into "App password". The servers are filled in (imap.gmail.com:993 and smtp.gmail.com:465, both TLS). The demo Gmail account has 2-Step Verification on and an app password created at myaccount.google.com/apppasswords.
   • Or iCloud Mail: choose iCloud Mail, enter <DEMO ICLOUD ADDRESS> and the app-specific password below.
   • Outlook / Microsoft 365: choose it, enter <DEMO OUTLOOK ADDRESS> and sign in on Microsoft's page.
3. The new account has Preserve mail, Send mail and Change server mail all off. Switch on Preserve mail, then Sync now: folders and counts appear and messages can be opened and searched in Archive.
4. Switch on Send mail (Outlook asks for the send permission once; Gmail and iCloud send with the same app password over SMTP), write a message to <TEST RECIPIENT>, and send it from the outbox.
5. Switch on Change server mail to mark a message read or move it to Trash; each change is shown before it runs. (For Gmail over IMAP, 4.0 does not change server mail; it says so and changes nothing — use the iCloud or Outlook account for this step.)
6. Remove the account in its menu: counts are shown first and the saved mail stays.

Demo account credentials: <supplied by the owner in the credential fields, never in public text> — a demo Gmail address with its Google app password (not the Google account password, which Gmail refuses over IMAP), or an iCloud address with an app-specific password.
Without an account the app's archive features work fully: use File ▸ Open with any .mbox or .eml file (owner: attach a small sample .mbox to the review submission).
There is no mailin server, no sign-up and no data collection. Purchases use StoreKit; the Professional tools need a Professional purchase (sandbox account).

(Owner: confirm the exact menu names on the candidate before pasting — the Modules / Live Mail / Connected mail labels are those in `ModuleRegistry` and `Capability` at d4a3ec3.)

### Gmail sign-in mode (V4-16)

4.0 for the App Store ships `MailinGmailSignInMode = imap` in `Info-Connected.plist`: the Gmail entry in Add account is
Gmail over IMAP with an app password, and Google sign-in (OAuth, Gmail API) is switched off — its code stays in the
app (rule 14). TestFlight / demo builds that need Google sign-in set the key to `oauth`; 4.0.x ships `oauth` once
Google has verified the restricted Gmail scopes (`V4_PROVIDER_REGISTRATION.md` §1). `Scripts/check-connected-release.sh`
prints the mode of the built app (step 5).

## Screenshots (owner, on the candidate)

1. Mail page with one Gmail and one IMAP account, modes visible (all three switches).
2. Add account sheet with Gmail chosen: the "App password" field and its guidance (2-Step Verification, myaccount.google.com/apppasswords), servers filled in.
3. Archive search showing a captured message next to an imported one.
4. Outbox with one queued message and its Send button.
5. About ▸ "Private by design" line (connected edition text).

Do not reuse 3.0 screenshots that show "Live Mail is not included" or "Offline & Private" on the connected listing.

## Fields that change from the 3.0 listing

| Field | 3.0 | 4.0 connected |
|---|---|---|
| Promotional text | "…No account, nothing leaves your Mac." | the text above (drop "nothing leaves your Mac") |
| App Privacy | Data Not Collected | owner decision, `V4_APP_PRIVACY_ANSWERS.md` |
| Privacy Policy URL | `/privacy` (offline text) | same URL, connected text published first (`privacy/v4-connected-draft.html`) |
| Sign-in required | No | No (provider sign-in is optional; give the demo account anyway) |
| Review notes | `docs/AppStoreConnect.md` | the notes above |
