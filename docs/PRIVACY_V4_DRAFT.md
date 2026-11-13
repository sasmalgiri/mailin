# Privacy policy — v4.0 connected edition (draft, V4-14)

Status: **draft, not published.** The live `docs/privacy/index.html` and `PrivacyPolicy.html` describe the shipping
offline 3.0.x app and stay unchanged until the connected edition ships; each now carries an HTML comment pointing
here. The publishable page is [`privacy/v4-connected-draft.html`](privacy/v4-connected-draft.html) (same look as
the live page). The in-app summary for the connected build is `LegalComplianceManager.connectedPrivacyPolicySummary`
(`maxmailin/ConnectedEditionClaims.swift`), shown by About ▸ Privacy and the terms sheet only when
`ConnectedBuildFeatures.mailTransportsCompiled`; the offline build shows its old summary unchanged.

## Data-flow inventory the text is based on (read from the code, 2026-11-12)

| Data | Where it goes | Where it is kept | Source |
|---|---|---|---|
| Imported archives, search index, duplicates, exports, receipts | nowhere | archive folder (container or chosen disk) | unchanged from 3.0 |
| Gmail mail in 4.0 (V4-16): over IMAP with a Google app password — raw RFC 822 bytes, X-GM-MSGID, X-GM-LABELS | Google → device only (`imap.gmail.com:993`, TLS; sending via `smtp.gmail.com:465`, TLS) | same tables as IMAP mail; one record per X-GM-MSGID, labels as memberships | `IMAPAdapter` (Gmail extensions, EXAMINE + BODY.PEEK, no mutation) |
| Gmail mail with Google sign-in (switched off in 4.0 by `MailinGmailSignInMode = imap`; TestFlight / demo builds and 4.0.x) (raw RFC 822, labels, history ids) | Google → device only (`gmail.googleapis.com`) | archive tables `mail_accounts`, `remote_folders`, `remote_messages`, `remote_memberships`, `sync_checkpoints`, `capture_runs`, `capture_items` + message blobs | `SQLiteEmailStore+ConnectedMail.swift`, `GmailAdapter` |
| Outlook / M365 mail (Graph `/$value` MIME, folders, delta tokens) | Microsoft → device only (`graph.microsoft.com`) | same tables | `GraphAdapter` |
| IMAP mail | IMAP server → device only (the host the account uses) | same tables | `IMAPAdapter` (EXAMINE + BODY.PEEK, no mutation in capture) |
| Messages the user sends | device → that account's provider (Gmail API, Graph sendMail, or the account's SMTP server) | outbox folder (`operation.json`, `message.eml`) until settled; drafts folder | `Outbox`, `OutboxStore`, `DraftStore`, `APISendSubmitters`, `SMTPSubmitter` |
| Server changes the user confirms | device → provider | journal of operations | `RemoteActionService`, `APIActionExecutors` |
| OAuth tokens, IMAP/SMTP passwords (incl. a Google app password) | only to the issuing provider's token / mail host (a Google app password only to `imap.gmail.com` / `smtp.gmail.com`) | Keychain `com.ecosanskriti.mailin.connected-account`, not synchronised, this-device-only | `CredentialStore.swift` |
| Account display settings (sending identities, SMTP host names) | nowhere | `UserDefaults` (no secrets) | `MailAccountExtrasStore` |
| Sign-in page traffic | the system sign-in window loads the provider's page (`login.microsoftonline.com`, `login.live.com`; `accounts.google.com` only when Google sign-in is switched on — not in 4.0) — ephemeral session, no cookies kept | — | `ASWebAuthenticationSession`, `prefersEphemeralWebBrowserSession = true` |
| Anything to the developer | **nothing** — no server, no relay, no analytics, no crash SDK | — | no SDK linked; `PrivacyInfo.xcprivacy` collects nothing |
| Anything to an AI provider | **nothing** — cloud AI not compiled (`MAILIN_CLOUD_AI` not defined); BYOK scaffolding refuses everything (`AIProductionTransport.liveInferenceShipped = false`) | — | `docs/V4_ONLINE_IMPLEMENTATION.md` SCAF |
| Remote content in messages | never loaded by mail code (`MailNetworkPolicy` refuses `.remoteContent`) | — | `MailNetworkPolicy.swift` |

Gates: compile time `MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD`; run time `MailNetworkPolicy` (Mail off on a fresh
install until the Live Mail page / `connectedMail` capability is on; each account off with no modes; each account
bound to its own mail and sign-in hosts; AI hosts and remote content always refused).

## Section text for `PrivacyPolicy.html` (replaces "Live Mail (not included in version 3.0)", "No Cloud AI" and "Network Access")

> **Two editions.** The offline edition is built without network code: it cannot connect to any server and no
> account can be added. The connected edition adds optional connected mail for Gmail, Outlook / Microsoft 365 and
> IMAP / SMTP accounts. Connected mail is off until you turn it on, and each account is allowed nothing until you
> switch on what it may do. About mailin says which edition you have.
>
> **Connected mail.** When you turn it on and add an account, your device connects directly to that account's own
> mail provider — Google (Gmail's IMAP and SMTP servers, `imap.gmail.com` and `smtp.gmail.com`), Microsoft
> (`login.microsoftonline.com`, `graph.microsoft.com`) or the IMAP and SMTP servers of your provider. Nothing goes
> through a mailin server or any other relay. *Preserve mail* downloads a read-only copy into your archive; *Send
> mail* sends messages you submit; *Change server mail* applies the changes you confirm. Your provider handles
> your mail under its own terms.
>
> **Sign-in and credentials.** Gmail connects with a Google app password you create in your Google Account
> (2-Step Verification on, myaccount.google.com/apppasswords); mailin never asks for your Google account password.
> Outlook / Microsoft 365 sign-in happens on Microsoft's own page; mailin never sees your Microsoft password. Tokens,
> app passwords and any IMAP / SMTP password are kept only in this device's Keychain, never synchronised, never in
> backups or exports, and sent only to the provider that issued them — a Google app password only to Google's mail
> servers. To withdraw it, revoke the app password in your Google Account.
>
> **Google API Services.** (Only when Google sign-in is offered — 4.0.x, after Google's verification; 4.0 connects
> Gmail over IMAP and uses no Google API.) mailin's use and transfer of information received from Google APIs adheres
> to the Google API Services User Data Policy, including the Limited Use requirements.
>
> **No cloud AI.** Neither edition contains cloud AI; no email content is sent to an AI provider.
>
> **Removing an account.** Removing an account stops its connections and deletes its sign-in data from the
> Keychain; its saved mail stays in your archive until you delete it in a separate step that shows the count first.
> To withdraw mailin's access at the provider, revoke the app password in your Google Account, or remove mailin in
> your Microsoft account's app permissions.
>
> **Network access.** The offline edition has none. The connected edition connects only to the servers above, only
> for accounts you added and only for what you allowed; Settings ▸ Health ▸ Mail network shows every allowed and
> refused attempt.

## Owner decisions / checks before publishing

1. Effective date and version; support e-mail address on the page (placeholder `<SUPPORT EMAIL>`).
2. **Fixed 2026-11-12:** Settings ▸ Delete All Data (`ArchiveLifecycleService.eraseAllData`) now also removes every
   `com.ecosanskriti.mailin.connected-account` Keychain item (`KeychainCredentialStore.deleteAll`, guarded by
   `EraseConnectedSecretsTests` and `MailAccountCredentialTests.testDeleteAll_…`); the "remove each connected account
   first" caveat is gone from the drafts.
3. The in-app offline summary (`LegalComplianceManager.privacyPolicySummary`, unchanged by request) still mentions an
   optional Cloud AI feature and iCloud review sync that the offline 3.0.x build does not compile — worth a
   correction in a later offline release (it is English legal text, not in the string catalog).
4. Publish the connected page at the same URL (`/privacy/`) when the connected build is distributed — Google's
   consent screen and Entra's branding point to it, and Google reads it during verification.
6. **V4-16 (owner, 2026-11-13):** 4.0 connects Gmail over IMAP with an app password (`MailinGmailSignInMode = imap`);
   Google sign-in returns in 4.0.x after Google verifies the restricted scopes. When 4.0.x switches the key to
   `oauth`, restore the Gmail API rows (`accounts.google.com`, `oauth2.googleapis.com`, `gmail.googleapis.com`) as
   the Gmail path and keep the IMAP wording for accounts added with an app password.
5. Have the text reviewed for the jurisdictions you sell in (plan §10: engineering tests do not establish legal
   compliance).
