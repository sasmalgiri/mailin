# Live Mail provider matrix (3.0 Page 4 — feature branch)

Owner decision 2026-09-27: Page 4 is built on the `live-mail` feature branch and does not gate 3.0.
This matrix is the staging the plan commits to; every row is **NOT TESTED** until the branch has a
running account. Provider policy must be re-verified when the work starts — app-password
availability has been tightening.

| Provider | Route in 3.x | Auth | Read | Send | Folders / labels | Status | Needs from owner |
|---|---|---|---|---|---|---|---|
| Generic IMAP + SMTP (Fastmail, Zoho, self-hosted Dovecot, most ISPs) | 3.0 branch | password or app-specific password over TLS | IMAP4rev1, headers first, bodies on demand | SMTP AUTH | IMAP folders | code exists (`IMAPClient`, `SMTPClient`: plaintext LOGIN only) — XOAUTH2 + hardening pending | test accounts |
| iCloud Mail | via generic IMAP | app-specific password (2FA account) | yes | yes | folders | as generic | an iCloud test account |
| Gmail | via generic IMAP in 3.0 | app password (requires 2-step verification) | yes | yes | labels as folders | as generic; **native Gmail API is 3.1** (restricted scopes, CASA) | Google Cloud project decision (3.1) |
| Outlook.com / Microsoft 365 | Microsoft Graph OAuth (PKCE) | `Mail.Read`, `Mail.ReadWrite`, `Mail.Send`, `User.Read`, `offline_access` | Graph messages | Graph sendMail | Graph mailFolders | scaffold exists (`OutlookConnector`: placeholder client id, no `Mail.Send`) | **Entra client ID**, redirect `msauth.com.ecosanskriti.mailin://auth` |
| Exchange on-premises (EWS) | not planned for 3.x | — | — | — | — | — | — |
| Yahoo / AOL | via generic IMAP | app password | yes | yes | folders | as generic | test account |

## Non-negotiables carried by every row

- Account-scoped everything: Keychain item per account, SQLite records keyed `(accountID, uid)`,
  From shown before editing and again at Send, draft + credentials + Sent mapping bound to one account.
- Nothing from Live Mail writes archive tables except through `ArchiveImporting` ("Copy to Archive"
  / "Reference"), preserving account, UID and original MIME.
- Zero connections while the page is off — proven by `NetworkBaselineTests` (L1) on the branch.
- Remote content in messages is blocked by default in the reading pane.

## Test accounts the owner will provide

Two generic IMAP accounts (different providers preferred) with app-specific passwords, one
Microsoft 365 or Outlook.com mailbox. A local Dovecot (Docker or Homebrew) covers the two IMAP slots
for automated tests; the executed matrix in `LIVE_MAIL_MULTI_ACCOUNT_TESTS.md` needs the real ones.
