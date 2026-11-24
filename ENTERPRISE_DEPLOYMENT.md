# mailin Enterprise — Deployment Guide (MDM)

mailin is local-first: the app processes email archives entirely on the device. There is no server
component, no tenant and no vendor data processing — IT deploys an app, not a service. From 4.0 the app can
also preserve live mailboxes (Live Mail): the device then connects **directly** to the organisation's own mail
provider, never to a mailin server, and IT can restrict or switch this off (see Live Mail controls). This guide covers
deployment through Apple Business Manager and an MDM (Jamf, Intune, Kandji, Mosyle, Workspace ONE, Apple
Business Manager's built-in device management).

## Requirements

- macOS 14.6+ / iOS 17.6+ devices enrolled in your MDM.
- App: **mailin Enterprise**, bundle id **`com.ecosanskriti.mailin.enterprise`**. Two ways to get it:
  - **App Store listing (4.0):** buy copies in Apple Business Manager ▸ Apps and Books (volume purchase) and
    assign them with your MDM. The purchase includes everything; no licence key is needed.
  - **Custom App (on request):** a private listing for your organisation in Apple Business Manager ▸ Apps and
    Books ▸ Custom Apps, with your own terms; the licence is a signed key (see Licensing).
- When `requireBiometricLock` is on, devices must have a passcode / login password; a device with no
  authentication method cannot satisfy the lock and mailin turns it off to prevent a lock-out (logged).
- macOS: FileVault on (the archive is protected at rest by FileVault; on iOS by Data Protection).

## Configuration keys

Delivered as **Managed App Configuration** (iOS, and MDMs that support it on macOS) or, on macOS, as a
**configuration profile for the preference domain `com.ecosanskriti.mailin.enterprise`** (Jamf, Intune,
Kandji "custom settings"). The app reads both; a key forced by a profile wins.

Ready-made files in `Enterprise/`:

| File | Use |
|---|---|
| `mailin-appconfig.xml` | AppConfig specification — import in Intune / Workspace ONE / Ivanti for a form |
| `jamf-schema.json` | Jamf Pro ▸ Application & Custom Settings ▸ External Applications ▸ Custom Schema |
| `mailin-enterprise-macOS.mobileconfig` | Sample macOS profile to edit and upload |

| Key | Type | Default | Effect |
|---|---|---|---|
| `orgName` | string | — | Shown in About, reports and receipts ("Managed by …") |
| `examinerName` | string | — | The person's name on audit entries and sealed receipts (use your MDM's full-name variable) |
| `role` | string | `administrator` if absent | `viewer`, `reviewer`, `examiner` or `administrator` — see Roles. **An unknown value is treated as `viewer`** and reported |
| `allowExport` | bool | `true` | `false`: no exporting, saving or sharing out of mailin, for any role |
| `allowPrint` | bool | `true` | `false`: no printing |
| `disableCloudAI` | bool | `false` | Hard off for cloud AI (this edition has none compiled in; kept for parity) |
| `requireBiometricLock` | bool | `false` | Forces the app lock (Touch ID / Face ID / passcode); users cannot turn it off |
| `caseNumberPrefix` | string | — | Preset prefix for case and Bates numbering |
| `licenseKey` | string | — | Your organisation's `MAILIN1.…` licence key |
| `disabledModules` | array of strings | — | Pages switched off for everyone: `aiInsights`, `professional`, `liveMail`. Settings shows them "locked by your organisation" |
| `allowConnectedMail` | bool | `true` | `false`: Live Mail is off — the page is locked and no mail connection is made |
| `allowedMailProviders` | array of strings | all | Only these providers: `gmail`, `microsoft365` (or `outlook`), `icloud`, `fastmail`, `imap` (any other IMAP server) |
| `allowSendMail` | bool | `true` | `false`: nothing is sent from mailin |
| `allowServerChanges` | bool | `true` | `false`: mailin never moves, flags or deletes mail on the server |
| `syncOnlyOnWiFi` | bool | person decides | Fixes automatic sync's "Only on Wi-Fi or a wired network" |
| `syncOnlyWhileCharging` | bool | person decides | Fixes automatic sync's "Only while charging" |
| `maxDownloadMBps` | number | no limit | Highest average download speed in MB/s; the person may choose a lower one |

## Live Mail controls

Live Mail preserves Microsoft 365 / Outlook, Gmail and IMAP mailboxes into the archive (kept even if the server
later deletes them), and can optionally send mail and change mail on the server — each mode is switched on per
account by the person, and each can be refused by you:

| You set | What the person sees | What the app does |
|---|---|---|
| `allowConnectedMail` = `false` | Live Mail locked in the tab bar and Settings ▸ Modules, "disabled by your organization" | No account is listed, synced or contacted; the mail network gate is closed. Mail already saved stays in the archive and stays searchable. Takes effect without a relaunch. |
| `allowedMailProviders` | Add account lists only the allowed providers | Adding another provider is refused. An existing account of another provider gets no network and says "Your organisation does not allow this kind of mail account on this device. Mail already saved stays in the archive." |
| `allowSendMail` = `false` | The Send switch of every account explains the refusal | Send is never granted at the network layer; queueing a message is refused (the draft is kept); messages already queued are not sent. |
| `allowServerChanges` = `false` | The Change server mail switch explains the refusal | Moving, flagging, deleting and Safe cleanup on the server are refused before any request is made. |
| `syncOnlyOnWiFi` / `syncOnlyWhileCharging` | Settings ▸ Live Mail ▸ Automatic sync shows the condition fixed, "Set by your organisation" | Applies to every automatic run (the one at launch and the timed ones). **Sync now**, which the person starts by hand, is not held back by these two conditions. |
| `maxDownloadMBps` | "Set by your organisation: at most … /s on average." under Download speed | Every download (all accounts together) is paced to the lower of your limit and the person's. |

Each refusal is enforced at the point where the network is granted for an account, not only in the interface,
so no screen, rule or retry can get around it. A changed configuration is applied while the app runs.

**Network hosts the app may contact** (only when Live Mail is allowed and an account of that provider is added;
put these on your proxy or firewall allow-list):

| Provider | Hosts |
|---|---|
| Microsoft 365 / Outlook | `login.microsoftonline.com` (sign-in), `graph.microsoft.com` (mail) |
| Gmail (app password) | `imap.gmail.com`, `smtp.gmail.com` |
| iCloud Mail | `imap.mail.me.com`, `smtp.mail.me.com` |
| Fastmail | `imap.fastmail.com`, `smtp.fastmail.com` |
| Any other IMAP server | the IMAP and SMTP hosts typed when the account is added |

Nothing else: no mailin server, no analytics, no crash upload. Microsoft 365 tenants may need an admin consent
for the mailin app registration (Entra ID ▸ Enterprise applications) if users cannot consent themselves.

## Roles

The person's role decides what they may do on the device. The check runs at the one place each action passes
through — permanent deletion and legal-hold changes are refused by the archive itself, whichever screen, rule
or engine asks. A refused action says why ("Your role is Reviewer. To delete emails permanently, the Administrator role or higher is needed.").

| Can … | Viewer | Reviewer | Examiner | Administrator |
|---|---|---|---|---|
| Read, search, open emails and reports | ✓ | ✓ | ✓ | ✓ |
| Tag, code, annotate, pin, review batches, move to Trash | | ✓ | ✓ | ✓ |
| Import mail | | | ✓ | ✓ |
| Export, save, share, print (also subject to `allowExport` / `allowPrint`) | | | ✓ | ✓ |
| Place legal holds | | | ✓ | ✓ |
| Bates numbering and productions | | | ✓ | ✓ |
| Permanently delete emails | | | | ✓ |
| Release legal holds | | | | ✓ |
| Change modules and engines, restore a snapshot, move the archive, change the licence | | | | ✓ |

Every audit-trail entry records the examiner **and the role** the action was taken with.

Unmanaged installs (no configuration) behave as before roles existed: the single user is Administrator.

## Reporting back to the MDM

mailin writes **Managed App Feedback** (`com.apple.feedback.managed`) at every launch, which your MDM reads
with the *Managed Application Feedback* command (iOS) or its app-inventory report:

`appVersion`, `appBuild`, `edition`, `role`, `allowExport`, `allowPrint`, `licenseState`
(`valid` / `grace` / `expired` / `missing` / `invalid`), `licenseID`, `licenseOrg`, `licenseExpires`,
`configIssues` (every problem in the pushed configuration), `liveMail` (the Live Mail controls in force:
`allowConnectedMail`, `allowSendMail`, `allowServerChanges`, `allowedMailProviders`, and the sync conditions and
speed limit when set), `reportedAt`.

Nothing from the archive is ever reported.

**Configuration problems** — an unknown key, a wrong type, an unknown role, module or mail provider, a
download limit of 0 or less — are listed in About on
the device and in `configIssues`, and never silently dropped.

## Seats

A seat is one device installation. The app cannot count installs (it has no network); account for seats with
your MDM's inventory of devices reporting your `licenseID` in Managed App Feedback, and with the seat count in
Apple Business Manager. The seat number printed on the key is the contractual figure.

## Licensing

mailin Enterprise is a free Custom App in Apple Business Manager; the organisation's licence is a signed key
checked offline on the device. Push it as `licenseKey` (or users paste it in About mailin ▸ Enter license
key…). A valid key unlocks everything; without one — or 30 days after expiry — the archive, search and exports
keep working and only the Professional tools wait for a key. Details: `LICENSING.md`. Contact
sasmalgiri@gmail.com for licensing.

## Audit log for your SIEM / records system

Audit trail ▸ Export ▸ *For a SIEM or records system (.jsonl)* writes JSON Lines: a header (format
`mailin-audit/1`, organisation, case, entry count, chain verification), one line per entry (sequence, time,
action, detail, examiner and role, HMAC, previous hash) and a trailer with the chain head. A missing or edited
entry breaks the chain and is visible after ingestion. Exporting follows `allowExport` and the role.

## Offboarding (removing the app or a person)

- **iOS / iPadOS:** when the MDM removes the managed app (or the device is unenrolled), iOS deletes the app and
  its data, including the archive.
- **macOS:** removing the app does **not** delete its data. The archive stays in
  `~/Library/Containers/com.ecosanskriti.mailin.enterprise/` (or the folder the archive was moved to). To
  remove it, delete that container after removing the app (for example with an MDM script running as the user),
  or keep it as the matter's record. Legal holds and seals live in the archive and go with it.
- A person who changes role gets the new role at the next launch after the MDM pushes it.

## Data flow summary (for security review)

- Import: user-chosen archive files (.mbox/.pst/.eml/.emlx/.msg/.nsf/.ost, folders, ZIP) parsed on the device
  into a local SQLite store inside the app sandbox.
- Processing: search, index and AI (Apple NaturalLanguage, Apple Intelligence on-device) on the device.
- Network: only Live Mail, only to the mail provider of an account the person added, and only what your
  Live Mail controls allow (hosts above). With `allowConnectedMail` = `false` the app makes no network
  connection for mail. HTML mail never loads remote content.
- Mail passwords and sign-in tokens live in the device Keychain; they are sent only to the provider they
  belong to.
- Keys: the HMAC audit-log key and the Ed25519 signing key live in the device Keychain.
- Telemetry: none. mailin has no analytics SDKs and collects nothing.
