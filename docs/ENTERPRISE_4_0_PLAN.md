# mailin Enterprise 4.0 — plan (owner decisions 2026-11-24)

## Decisions

| Question | Decision |
|---|---|
| Live Mail in the enterprise edition | **Included, and the organisation can switch it off by MDM.** Companies that want "nothing leaves the Mac" turn it off; others use it to preserve staff mailboxes. |
| Distribution | **Apple Business Manager Custom App** — a private App Store listing per customer organisation (their ABM Organisation ID), deployed by their MDM. Mac, iPhone and iPad. Apple review applies. |
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
| ENT4-03 | Licence check on 4.0: seats, expiry, grace, About shows the organisation; Live Mail included in the licence. |
| ENT4-04 | IT admin guide: every managed key with type and default, a sample `.plist` / Jamf / Intune profile, what each Live Mail key changes, network hosts the app may contact (Microsoft Graph, Gmail IMAP/SMTP, the account's IMAP host — nothing else). |
| ENT4-05 | App Store Connect: new app record for `com.ecosanskriti.mailin.enterprise`, availability = Private (Custom App), the customer's ABM Organisation ID, price (free with a licence key, or a Volume Purchase price), review notes with a demo licence key, privacy answers (same as 4.0: Data Not Collected). |
| ENT4-06 | Enterprise privacy page and terms (organisation-managed devices, admin controls), linked from the enterprise listing. |
| ENT4-07 | Gate on the enterprise build: five-jobs gate + touched classes, MailConnectivity both modes, package `-c release`, Release-configuration build, a managed-config walk with Live Mail off and on. |

## Owner to provide

1. The first customer's **ABM Organisation ID** (needed before the Custom App can be made available; Apple shows it in their Business Manager ▸ Preferences ▸ Enrolment Information).
2. **Pricing**: free download unlocked by your licence key (your invoice), or a Volume Purchase price in App Store Connect.
3. A **demo licence key** for App Review (issue with `Scripts/mailin-license.swift`).
