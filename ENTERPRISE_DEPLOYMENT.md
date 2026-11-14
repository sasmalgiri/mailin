# mailin Enterprise — Deployment Guide (MDM)

mailin is local-first: the app processes email archives entirely on the device. There is no server
component, no tenant and no vendor data processing — IT deploys an app, not a service. This guide covers
deployment through Apple Business Manager and an MDM (Jamf, Intune, Kandji, Mosyle, Workspace ONE, Apple
Business Manager's built-in device management).

## Requirements

- macOS 14.6+ / iOS 17.6+ devices enrolled in your MDM.
- App: **mailin Enterprise**, bundle id **`com.ecosanskriti.mailin.enterprise`**, a Custom App your
  organisation receives in Apple Business Manager (Apps and Books ▸ Custom Apps). Licences in Apple Business
  Manager are free; your mailin licence is a signed key (see Licensing).
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
| `disabledModules` | array of strings | — | Pages switched off for everyone: `aiInsights`, `professional`. Settings shows them "locked by your organisation" |

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
`configIssues` (every problem in the pushed configuration), `reportedAt`.

Nothing from the archive is ever reported.

**Configuration problems** — an unknown key, a wrong type, an unknown role or module — are listed in About on
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
- Network: none. The signed app has no network entitlement (`Scripts/verify-no-network.sh`); HTML mail never
  loads remote content.
- Keys: the HMAC audit-log key and the Ed25519 signing key live in the device Keychain.
- Telemetry: none. mailin has no analytics SDKs and collects nothing.
