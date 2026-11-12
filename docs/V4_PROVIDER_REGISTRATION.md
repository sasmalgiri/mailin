# mailin v4.0 — provider registration packets (V4-14)

Prepared 2026-11-12 from the code on `v3-architecture` (d4a3ec3 + the V4-14 commit). Every value below was read
from the source, not from earlier plans; the file and symbol are named so it can be re-checked. **The agent
contacted no provider and created no account.** The owner does the account-side steps and pastes the values
back (end of each packet).

Related: [`V4_ONLINE_IMPLEMENTATION.md`](V4_ONLINE_IMPLEMENTATION.md) (owner project checklist),
[`PRIVACY_V4_DRAFT.md`](PRIVACY_V4_DRAFT.md), [`privacy/v4-connected-draft.html`](privacy/v4-connected-draft.html),
[`V4_APP_PRIVACY_ANSWERS.md`](V4_APP_PRIVACY_ANSWERS.md), [`V4_STORE_METADATA_DRAFT.md`](V4_STORE_METADATA_DRAFT.md),
`NETWORK_AND_PRIVACY_MATRIX.md` § v4, `NO_NETWORK_PROOF.md` § v4.

## 0. Facts both packets depend on

| Fact | Value | Source |
|---|---|---|
| Which build connects | Only the **connected** configuration (`Release-Connected`, `MAILIN_CONNECTED_MAIL`, no `NO_NETWORK_BUILD`). Today's `Release` and `Debug` define `NO_NETWORK_BUILD` and contain no transport. | `MailNetworkPolicy.swift` `ConnectedBuildFeatures`; project build settings |
| Bundle ID of the connected build | **`com.ecosanskriti.mailin`** (Mac and iPhone/iPad, same ID). `Release-Connected` is a duplicate of `Release`. | `V4_ONLINE_IMPLEMENTATION.md` owner step 1–2 |
| Enterprise bundle `com.ecosanskriti.mailin.enterprise` | **Not connected.** `Scripts/testflight.sh --edition enterprise` forces `NO_NETWORK_BUILD`. Register a second client only if the owner later decides on a connected enterprise build. | `Scripts/testflight.sh` line 60 |
| Sign-in mechanism | `ASWebAuthenticationSession`, `prefersEphemeralWebBrowserSession = true`; authorization code + **PKCE S256** + random `state` checked on return; **no client secret** (public native client). Token exchange and refresh are POSTs from the app through `PolicyCheckedTokenTransport` (HTTPS only, ephemeral `URLSession`, no redirect followed, only to the sign-in host granted to that account). | `ConnectedMailProductionTransports.swift`, `MailConnectivity/OAuthSession.swift`, `ConnectedMailRuntime.swift` |
| Where client IDs come from | `Info.plist` keys **`MailinGmailClientID`**, **`MailinGraphClientID`**, **`MailinGraphRedirectURI`**. Missing or placeholder values disable that provider's Add button with the reason; no request is ever made with a fake client. | `MailWorkspaceModel.swift` `MailProviderChoice`, `ConnectedMailRuntime.swift` `ConnectedMailProduction` |
| Release check (T47) | `ConnectedReleaseCheck` (app) + `Scripts/check-connected-release.sh` (built app) refuse a connected build whose three values are missing, empty, `YOUR_…`, `$(…)` or malformed, or whose Microsoft redirect is not `msauth.<bundle id>://auth`. | `maxmailin/ConnectedEditionClaims.swift`, `V414ClaimsTests` |
| Tokens at rest | Keychain, service `com.ecosanskriti.mailin.connected-account`, account `<account UUID>/<kind>`, `kSecAttrSynchronizable = false`, `AfterFirstUnlockThisDeviceOnly`. Never in backups, exports or preferences. | `MailConnectivity/CredentialStore.swift` |
| Legacy connectors | `GmailConnector.swift` / `OutlookConnector.swift` (3.0 code, placeholders `YOUR_GOOGLE_OAUTH_CLIENT_ID…`, `YOUR_AZURE_CLIENT_ID`, scopes incl. `gmail.labels`, `Mail.ReadBasic`, `User.Read`) are compiled in the connected build but have **no caller** (plan A14). They are not part of this registration; their scopes are never requested. | `grep -n GmailConnector maxmailin/*.swift` |

### Scopes per mode, exactly as requested by the code

A new account is allowed nothing; each mode is switched on separately (`MailWorkspaceModel` `MailModeText`). A
mode that needs more access asks for it the first time it is used ("re-consent", `MailReconsentRequest`).

| Mode (UI) | Gmail scope requested | Microsoft Graph delegated permission requested | IMAP / SMTP |
|---|---|---|---|
| Add account + **Preserve mail** (read-only capture) | `https://www.googleapis.com/auth/gmail.readonly` (`GmailOAuth.captureScopes`) | `https://graph.microsoft.com/Mail.Read` + `offline_access` (`GraphOAuth.configuration`) | password / app password, no scope |
| **Send mail** | adds `https://www.googleapis.com/auth/gmail.send` (`MailScopeNeeds.gmailSend`) | adds `Mail.Send` (`MailScopeNeeds.graphSend`) | SMTP AUTH after TLS |
| **Change server mail** (flag, read/unread, move/label, Trash, restore) | adds `https://www.googleapis.com/auth/gmail.modify` (`ServerActionScopes.gmailModify`) | adds `Mail.ReadWrite` (`ServerActionScopes.graphReadWrite`); `Mail.ReadWrite.Shared` only for a shared mailbox | IMAP STORE / MOVE, no EXPUNGE of other messages |
| Never requested | `https://mail.google.com/` (full access, incl. permanent delete), `gmail.labels`, `gmail.metadata`, `openid`/`email`/`profile` | `User.Read`, `Mail.ReadBasic`, `Mail.Read.Shared` (no UI sets `sharedMailboxes`), `IMAP.AccessAsUser.All`, `SMTP.Send`, EWS | — |

`GmailOAuth.configuration` refuses any scope outside `https://www.googleapis.com/auth/gmail.*`;
`GraphOAuth.validateScopes` refuses Exchange-protocol scopes in a Graph configuration.

**Known issue to fix before the real-provider run (found while preparing this packet, not fixed here):** a Gmail
re-consent asks for `gmail.readonly` + the one new scope only (`ConnectedMailProductionTransports.signIn`, no
`include_granted_scopes`), and `MailWorkspaceBackend.signIn` then overwrites `grantedScopes` with the returned
token's scopes. Turning on *Change server mail* after *Send mail* can therefore drop `gmail.send` from the stored
grant. Fix: request the union of the account's granted scopes and the new one (or send
`include_granted_scopes=true`). Microsoft returns all consented permissions for the resource, so Graph is
probably unaffected — confirm in the provider run.

---

## 1. Google Cloud packet (Gmail API)

### 1.1 Project and API

1. console.cloud.google.com ▸ new project, e.g. **`mailin-mail`** (owner's organisation or personal account).
2. APIs & Services ▸ Library ▸ **Gmail API** ▸ Enable. No other API is needed (no People API, no Cloud
   Storage, no Pub/Sub — the app polls `history.list`; there is no push/notification backend).

### 1.2 OAuth client

| Field | Value |
|---|---|
| Application type | **iOS** (Google's native client type; the same iOS-type client is used by the Mac app — Google offers no separate macOS type for this flow) |
| Name | `mailin (Mac, iPhone, iPad)` |
| Bundle ID | **`com.ecosanskriti.mailin`** |
| App Store ID | the mailin app's Apple ID number (App Store Connect ▸ App Information) — optional |
| Team ID | the owner's Apple Developer Team ID — optional |
| Client secret | none (iOS clients have none; the app sends none) |
| Redirect URI | **reversed client ID**: `com.googleusercontent.apps.<CLIENT_ID_PREFIX>:/oauth2redirect`, where `<CLIENT_ID_PREFIX>` is the client ID without `.apps.googleusercontent.com`. Google shows it as the client's "iOS URL scheme". The code derives it (`GmailOAuth.defaultRedirectURI`) and refuses any other custom scheme. |

`V4_ONLINE_IMPLEMENTATION.md` step 3's older Gmail scheme `com.ecosanskriti.mailin:/oauth2callback` belongs to the
legacy `GmailConnector`; the shipped sign-in uses the reversed client ID above (corrected there).

### 1.3 Scopes to add (Data Access ▸ Add or remove scopes) — minimum-scope rationale

| Scope | Google class | Feature | Why nothing narrower works |
|---|---|---|---|
| `…/auth/gmail.readonly` | **Restricted** | Preserve mail: `users.getProfile` (historyId boundary), `labels.list`, `messages.list`, `messages.get?format=raw` (the exact RFC 822 bytes the archive keeps, hashed and exportable), `history.list` (incremental sync) | `gmail.metadata` cannot read message bodies or raw MIME; preserving mail *is* reading it. Read-only: nothing on the server changes and messages are not marked read. |
| `…/auth/gmail.send` | Sensitive | Send mail: `messages/send` (upload, `uploadType=media`) of a message the person wrote and submitted from the outbox | Send-only; grants no read. Requested only when Send mail is switched on. |
| `…/auth/gmail.modify` | **Restricted** | Change server mail: `messages.modify` (labels, read/unread, star), `messages.trash` / `untrash` — each change listed and confirmed first, a cleanup only after typing the exact count | Narrowest scope that can change labels or move to Trash. `https://mail.google.com/` (permanent delete) is never requested. Requested only when Change server mail is switched on. |

### 1.4 Verification and security assessment — depends on the scopes actually published

- `gmail.readonly` and `gmail.modify` are restricted scopes, so a production (In production, External) app
  needs Google's **OAuth app verification** and, under Google's restricted-scope policy, may need an annual
  **CASA security assessment**. Google's published policy has said that apps which handle restricted-scope data
  only on the user's device — never on, or through, a developer server — may not need the third-party assessment.
  That is mailin's architecture (no backend, no relay, tokens and mail only on the device), but **Google decides
  during review**; state the architecture plainly and keep this answer as theirs.
- If only `gmail.send` were requested (sensitive), verification is needed but no assessment. Shipping without
  Preserve mail is not a v4 option, so plan for the restricted path.
- Until verification passes: publishing status **Testing**, up to 100 named test users, and Google limits refresh
  tokens of testing apps to about 7 days — fine for the V4-15 provider runs, not for release.
- Plan §13.8: Gmail-origin content stays local; the AI scaffolding refuses Gmail-origin sources
  (`AISourcePolicy`, `gmailRouteApproved = false`). Do **not** describe any AI use of Gmail data to Google —
  there is none in v4.

### 1.5 OAuth consent screen (Branding / Audience / Data access)

| Field | Value |
|---|---|
| App name | **mailin** (must match the App Store name and the in-app name) |
| User support email | `<SUPPORT EMAIL — owner>` (a mailbox the owner reads; it is shown to users) |
| App logo | `docs/app-icon.png` (120×120 PNG export; a logo triggers brand verification) |
| Application home page | `https://sasmalgiri.github.io/mailin/` |
| Privacy policy | `https://sasmalgiri.github.io/mailin/privacy/` — **must be the connected-edition text** (`docs/privacy/v4-connected-draft.html` published there) before submitting; Google reads it for Gmail use and Limited Use |
| Terms of service | `https://sasmalgiri.github.io/mailin/terms/` |
| Authorised domains | `sasmalgiri.github.io` — must be verified in Google Search Console by the owner. `github.io` is a public suffix, so the verifiable unit is the user site `sasmalgiri.github.io` (an HTML-file or meta-tag check served from the root, i.e. the `sasmalgiri.github.io` repository). A custom domain the owner controls makes this and Microsoft's publisher domain (§2.5) straightforward — owner choice. |
| Developer contact | `<DEVELOPER CONTACT EMAIL — owner>` |
| User type | External |

**Limited Use statement for the privacy page** (Google requires it in substance; it is in the drafts):
"mailin's use and transfer of information received from Google APIs adheres to the Google API Services User Data
Policy, including the Limited Use requirements." Truthful because: data goes only from Google to the device; it is
used only to provide the features the person switched on; it is not transferred, sold, used for ads, or read by any
human at mailin; there is no server to store it.

**Scope justification text (paste per scope in the verification form):**

- *gmail.readonly*: "mailin is a local email archive for Mac, iPhone and iPad. When the user turns on Preserve mail
  for their Gmail account, mailin downloads each message's raw RFC 822 source with messages.get (format=raw),
  its labels and history ids, and stores them only on the user's device so the user can search, de-duplicate and
  export their own mail with integrity hashes. There is no mailin server; the data never leaves the device except
  to Google. Read-only: mailin changes nothing on the server."
- *gmail.send*: "When the user turns on Send mail and sends a message they wrote, mailin submits it with
  messages.send from the device. It is requested only when Send mail is turned on."
- *gmail.modify*: "When the user turns on Change server mail, mailin can apply changes the user chooses — add or
  remove labels, mark read/unread, move to Trash or restore — each listed before it runs. Bulk cleanup runs only
  after the user types the exact count shown. mailin never deletes permanently and does not request mail.google.com."

### 1.6 Demo video script (unlisted YouTube link for verification; about 3 minutes)

Record on a Mac with the **connected Release candidate**, a demo Gmail account, the URL visible:

1. Show the app (About ▸ version) and say the app name and bundle ID.
2. Settings ▸ Modules ▸ switch on **Live Mail**, read the activation sheet ("Enabling the page connects to
   nothing…"); make sure **Connected mail** is on.
3. Mail page ▸ **Add account** ▸ Gmail ▸ enter the address ▸ the Google sign-in window opens. **Show the address
   bar with `client_id=<the production client ID>`** and the consent screen listing *View your email messages and
   settings* (gmail.readonly) and the app name/logo.
4. Back in mailin: the account shows Preserve mail / Send mail / Change server mail all **off**. Switch on
   Preserve mail, Sync now; show folders/labels with counts, open a message, show it in Archive search.
5. Switch on **Send mail**: the re-consent prompt names gmail.send; consent; write a message to a test recipient,
   show it waiting in the outbox, send, show it in Gmail's Sent (browser).
6. Switch on **Change server mail**: re-consent names gmail.modify; mark one message read and move one to Trash;
   show the confirmation and the change in Gmail.
7. Remove the account: the counts shown first, saved mail kept; show the account gone from
   myaccount.google.com ▸ Security ▸ Third-party connections only after the user removes it there (say so).
8. Say: "No mailin server is involved; everything you saw ran on this Mac and Google."

### 1.7 Reviewer test instructions (Google and App Review)

- Build: the connected Release candidate (TestFlight link or notarised build for Google, as they request).
- Account: `<DEMO GMAIL ADDRESS — owner>` / `<PASSWORD — owner, via the reviewer notes field only>`; 2-step
  verification off or a backup code supplied; seeded with ~50 messages in 3 labels (V4-15 seeded corpus).
- Steps: as video steps 2–6. Expected: label counts equal Gmail's; nothing changes on the server until Change server
  mail is on and a change is confirmed.

### 1.8 Paste these values back (Google)

| Value from Google | Goes to | Exactly |
|---|---|---|
| OAuth client ID `NNNN-xxxx.apps.googleusercontent.com` | `Info.plist` key **`MailinGmailClientID`** (String) of the connected build | Recommended: build setting `MAILIN_GMAIL_CLIENT_ID` = the ID in target `maxmailin`, configuration `Release-Connected` (and `Debug-Connected` if made); `Info.plist` (or `Info-Connected.plist`) entry `<key>MailinGmailClientID</key><string>$(MAILIN_GMAIL_CLIENT_ID)</string>`. In configurations without the setting it expands to "" and Gmail shows "not set up". |
| iOS URL scheme `com.googleusercontent.apps.NNNN-xxxx` | Nothing required: `ASWebAuthenticationSession` catches the callback itself. If the owner wants the scheme declared, add it to `CFBundleURLTypes` of the **connected** plist only. | — |
| Verification status, test-user list | `FIVE_JOBS_TRACKER.md` V4-14 evidence | date + status |

Check: `Scripts/check-connected-release.sh <connected app>` passes the Gmail line; `V414ClaimsTests` T47 test on
the candidate.

---

## 2. Microsoft Entra packet (Microsoft Graph)

### 2.1 App registration

entra.microsoft.com ▸ Identity ▸ Applications ▸ App registrations ▸ **New registration**

| Field | Value | Why |
|---|---|---|
| Name | **mailin** | shown on the consent screen |
| Supported account types | **Accounts in any organizational directory (any Microsoft Entra ID tenant — multitenant) and personal Microsoft accounts (e.g. Skype, Xbox)** | the app signs in against tenant **`common`** (`ConnectedMailProductionTransports.signIn` → `GraphSignInSettings(tenant: "common")`) so Outlook.com and work/school accounts both work |
| Platform | **Mobile and desktop applications ▸ iOS / macOS**, bundle ID **`com.ecosanskriti.mailin`** | Entra generates the redirect below |
| Redirect URI | **`msauth.com.ecosanskriti.mailin://auth`** | the value the app expects (`ConnectedReleaseCheck.redirectProblem`) |
| Client secret / certificate | **none** — public client, PKCE | the app has no secret |
| Allow public client flows | leave **No** (that switch is for device-code / ROPC flows, which the app does not use) | — |
| Implicit grant / ID tokens | off | not used |

### 2.2 API permissions (Microsoft Graph, **Delegated**)

Remove the default `User.Read` (not requested by the app). Add:

| Permission | Mode | Rationale | Admin consent required? |
|---|---|---|---|
| `Mail.Read` | Preserve mail | list mail folders (full tree), per-folder delta, `/$value` raw MIME of each message, immutable IDs | No (user-consentable), unless the tenant restricts user consent |
| `offline_access` | all | refresh token, so sync resumes without signing in again | No |
| `Mail.Send` | Send mail | `POST /me/sendMail` of a message the user submitted | No |
| `Mail.ReadWrite` | Change server mail | flag, read/unread, move, Trash, restore — each confirmed first | No |
| `Mail.ReadWrite.Shared` | Change server mail on a shared mailbox | only when a shared mailbox is used (not reachable from the v4 UI) — **optional; add only if shared mailboxes ship** | No |

Permissions are requested dynamically (incremental consent): the first sign-in asks for `Mail.Read` +
`offline_access` only; Send / Change ask the first time they are switched on. Listing them in the registration
lets tenant admins pre-consent and is shown during publisher verification.

### 2.3 Tenant consent instructions (for organisations)

- Users can consent themselves unless their tenant's "User consent settings" forbid it or restrict it to verified
  publishers. Since Microsoft's 2020 change, many tenants allow user consent only for **verified publishers** — so
  publisher verification (§2.5) matters for M365 customers.
- Admin pre-consent URL (an admin opens it once):
  `https://login.microsoftonline.com/<TENANT-ID>/adminconsent?client_id=<APPLICATION-ID>`
  or Entra ▸ Enterprise applications ▸ mailin ▸ Permissions ▸ Grant admin consent.
- Conditional Access / app-protection policies of the tenant apply; mailin reports a refused sign-in by name.

### 2.4 Test matrix (V4-15, owner accounts)

| Account | Expected |
|---|---|
| Outlook.com personal | sign-in through login.live.com in the sign-in window; Mail.Read consent; folders and counts equal Outlook web |
| M365 work, user consent allowed | same; Send and Change re-consent prompts |
| M365 work, user consent blocked | "needs admin approval" shown by Microsoft; mailin says the sign-in was refused; after admin consent it works |
| Revoked consent (myapps.microsoft.com / account.live.com/consent/Manage) | next sync: "Account needs sign-in; saved mail remains available." |

### 2.5 Publisher verification

1. The owner's **Microsoft AI Cloud Partner Program (MPN) ID** (Partner Center; free enrolment, verified business).
2. A **publisher domain** verified for the app registration (Branding & properties ▸ Publisher domain): host
   `https://<domain>/.well-known/microsoft-identity-association.json` containing the Application ID. For
   `sasmalgiri.github.io` the file must be served from the user-site root (repository `sasmalgiri.github.io`), not
   from the `/mailin/` project path; a custom domain is simpler.
3. Branding & properties: name **mailin**, logo, home page `https://sasmalgiri.github.io/mailin/`, terms
   `…/terms/`, privacy `…/privacy/` (connected-edition text published first).
4. Branding & properties ▸ Publisher verification ▸ add the MPN ID ▸ Verify. The consent screen then shows the
   blue "verified" badge.

### 2.6 Paste these values back (Microsoft)

| Value from Entra | Goes to | Exactly |
|---|---|---|
| Application (client) ID (GUID) | `Info.plist` key **`MailinGraphClientID`** (String), connected build | build setting `MAILIN_GRAPH_CLIENT_ID` in `Release-Connected`; plist entry `<string>$(MAILIN_GRAPH_CLIENT_ID)</string>` |
| Redirect URI `msauth.com.ecosanskriti.mailin://auth` | `Info.plist` key **`MailinGraphRedirectURI`** (String), connected build | literal `msauth.com.ecosanskriti.mailin://auth` (or `msauth.$(PRODUCT_BUNDLE_IDENTIFIER)://auth`, which expands to the same for this bundle) |
| Directory (tenant) ID | nothing — the app uses `common` | — |
| Publisher-verified date, MPN ID | `FIVE_JOBS_TRACKER.md` V4-14 evidence | — |

Do not add a client secret anywhere. Do not put any value in `Info.plist` of the offline `Release`.

### Ready-made plist fragment (connected build only)

```xml
<key>MailinGmailClientID</key>
<string>$(MAILIN_GMAIL_CLIENT_ID)</string>
<key>MailinGraphClientID</key>
<string>$(MAILIN_GRAPH_CLIENT_ID)</string>
<key>MailinGraphRedirectURI</key>
<string>msauth.$(PRODUCT_BUNDLE_IDENTIFIER)://auth</string>
```

If the shared `Info.plist` is used (owner step 3 in `V4_ONLINE_IMPLEMENTATION.md`), the offline build carries the
three keys with empty values (`MailinGraphRedirectURI` would expand to a real-looking redirect, which is harmless:
no sign-in code is compiled there). The separate `Info-Connected.plist` keeps the offline build byte-identical.

---

## 3. IMAP / SMTP (no registration)

Presets (`IMAPAdapter` presets, `MailProviderChoice.smtpDefault`): iCloud Mail `imap.mail.me.com:993` (TLS),
`smtp.mail.me.com:587` (STARTTLS), app-specific password; Fastmail `imap.fastmail.com:993`, `smtp.fastmail.com:465`,
app password; Other IMAP: the host and port the user enters. TLS before any credential; no plaintext fallback.
Gmail over IMAP works with a Google app password (2-step verification on); Microsoft accounts should use the Graph
route (Microsoft has turned off basic-auth IMAP for most accounts; the app does not request
`IMAP.AccessAsUser.All`).
