# mailin Enterprise 4.0 — plan (owner decisions 2026-11-24)

## Decisions

| Question | Decision |
|---|---|
| Live Mail in the enterprise edition | **Included, and the organisation can switch it off by MDM.** Companies that want "nothing leaves the Mac" turn it off; others use it to preserve staff mailboxes. |
| Distribution | **Changed 2026-11-24 (no customer yet): A + B now, C later.** **A** — a public, paid-upfront **"mailin Enterprise"** listing that any organisation can buy in volume through Apple Business Manager (Apps and Books) and deploy with its MDM; no in-app purchase (Apple cannot sell those in volume). **B** — TestFlight pilots (email invites or a public link, 90 days per build) to find the first customers. **C** — a Custom App (private listing per organisation, needs its ABM Organisation ID) later, for a customer who wants its own terms; same build, only the App Store Connect availability differs. Mac, iPhone and iPad. Apple review applies. |
| Timing | **After 4.0 is approved.** The enterprise build starts from the approved 4.0 code (Mac 4.0 in review, iOS 4.0 to be submitted, both build 1003). |

## Already built (3.0, October 2026)

- One target builds both editions: `Scripts/testflight.sh --edition enterprise` → bundle `com.ecosanskriti.mailin.enterprise`, `ENTERPRISE_EDITION`, in-app purchase compiled out, everything unlocked by the licence.
- Offline Ed25519-signed licence keys (organisation, seats, expiry, 30-day grace, never below Personal): `maxmailin/EnterpriseLicense.swift`, issuing tool `Scripts/mailin-license.swift`, key pair in `~/mailin-license-keys` (never run `keygen` again — it invalidates every issued key). Owner steps: `LICENSING.md`.
- Managed configuration (`com.apple.configuration.managed`, `maxmailin/EnterpriseConfig.swift`): `orgName`, `examinerName`, `disableCloudAI`, `requireBiometricLock`, `caseNumberPrefix`, `licenseKey`, `disabledModules`, `role`, `allowExport`, `allowPrint`; managed feedback back to the MDM (edition, licence state, config issues).

## Work, in order (each with its test, build, tracker row, commit — CLAUDE.md working mode)

| ID | Item |
|---|---|
| ENT4-01 | Enterprise build on the approved 4.0 code: the connected edition (`MAILIN_CONNECTED_MAIL`, network entitlement) plus `ENTERPRISE_EDITION`, bundle `com.ecosanskriti.mailin.enterprise`; `testflight.sh --edition enterprise` updated for the connected configuration; build and the five-jobs gate on it. |
| ENT4-02 | MDM controls for Live Mail: `allowConnectedMail` (default true; false = the page and every connection off, stated in the app), `allowedMailProviders` (e.g. only Microsoft 365), `allowSendMail`, `allowServerChanges`, `syncOnlyOnWiFi` / `syncOnlyWhileCharging` (locks the DL-05 conditions), `maxDownloadMBps` (locks DL-06). Shown as "Set by your organisation" in Settings; validated and reported in managed feedback. Tests for each key. 10 languages. |
| ENT4-03 | Licences for two channels. **Public paid listing (A): the purchase unlocks everything — no key needed** (App Review rejects a paid app that needs an outside key to work); an MDM `licenseKey`, if present, only adds the organisation's name and seat count to About and managed feedback. **Custom App / direct deals (C): the 3.0 rule stays** (valid key = everything; 30-day grace; without a key never below Personal; nothing locked away). One build decides by its availability channel (a build setting, not a runtime guess). Tests for both. |
| ENT4-04 | IT admin guide: every managed key with type and default, a sample `.plist` / Jamf / Intune profile, what each Live Mail key changes, network hosts the app may contact (Microsoft Graph, Gmail IMAP/SMTP, the account's IMAP host — nothing else). |
| ENT4-05 | App Store Connect: new app record "mailin Enterprise" (`com.ecosanskriti.mailin.enterprise`), **public availability, paid upfront**, volume purchase on, listing text written for IT and compliance buyers, screenshots of the admin controls, review notes, privacy answers (same as 4.0: Data Not Collected). TestFlight external group for pilots (Beta App Review once). Custom App availability added per customer later (C). |
| ENT4-06 | Enterprise privacy page and terms (organisation-managed devices, admin controls), linked from the enterprise listing. |
| ENT4-07 | Gate on the enterprise build: five-jobs gate + touched classes, MailConnectivity both modes, package `-c release`, Release-configuration build, a managed-config walk with Live Mail off and on. |

## Owner to provide

1. **The price of the public "mailin Enterprise" listing** (one-time, per copy; organisations buy copies in volume through Apple Business Manager). Subscriptions are in-app purchases and cannot be bought in volume, so the listing is paid upfront.
2. **Pilot list for TestFlight**: names / emails of companies or people to invite (law firms, compliance teams, forensic investigators), or a public TestFlight link to share.
3. Later, for a Custom App (C): that customer's **ABM Organisation ID** (their Business Manager ▸ Preferences ▸ Enrolment Information) and a licence key issued with `Scripts/mailin-license.swift`.
