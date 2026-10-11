# mailin Enterprise — what an organisation needs (review 2026-10-11)

The owner asked whether validation, cardinality, authorisation, profiles and business integration are really
needed for an enterprise app, and to implement only what is. This review answers per item, for **this** product:
a local-first, offline app (no server, no network in 3.0 Private) that an organisation deploys through Apple
Business Manager + MDM to examiners, reviewers and investigators who work on email evidence.

Sources: Apple Device Management and ManagedApp documentation (managed app configuration, managed app feedback,
declarative app management, ManagedApp "enforcing the role of a person", Platform SSO), and what MDM consoles
(Jamf, Intune, Kandji, Mosyle) expect from an app they configure. The existing enterprise pieces are in
`ENTERPRISE_DEPLOYMENT.md`, `ENTERPRISE_ASSURANCE_PACK.md`, `EnterpriseConfig.swift`, `EnterpriseLicense.swift`.

Verdict key: **Required** — an organisation will not deploy without it · **Recommended** — expected by larger
buyers, build if time allows · **Not needed** — does not apply to an offline, single-user-per-device app (reason given).

## 1. Validation

| # | Item | Verdict | Why / what |
|---|---|---|---|
| V-1 | Managed configuration is validated: wrong types, unknown keys and bad values are reported, never silently ignored | **Required** | Admins mistype keys; today a wrong type is dropped without trace. Show it in About ▸ Managed configuration and report it to the MDM (V-2). |
| V-2 | Report status back to the MDM (`com.apple.feedback.managed`: app version, edition, license state and id, applied policy, config errors) | **Required** | The standard way an admin sees, in the MDM console, which devices are licensed and correctly configured — without the app using the network. |
| V-3 | License validation (signed key, expiry, grace, clock rollback) | done (78e1315) | — |
| V-4 | Evidence validation (import receipts, fingerprint tree, sealed bundles, verify-seals) | done | — |

## 2. Cardinality (how many of what)

| # | Item | Verdict | Why / what |
|---|---|---|---|
| C-1 | Seats: who counts as one seat, and how the org can account for them | **Required** | The license states seats; an offline app cannot count installs. The accountable answer: one seat = one device install; the app reports its license id in managed feedback (V-2) so the MDM inventory is the seat count. Document it. |
| C-2 | Data relationships are enforced: matter ↔ custodian ↔ email, one hold per email per matter, Bates numbers unique and never renumbered | done (F4, M6, rule 3) | — |
| C-3 | Hard seat enforcement in the app | **Not needed** | Would need a licence server (network) — against the Private edition. Contract + MDM inventory is how offline enterprise software is licensed. |

## 3. Authorisation (who may do what)

| # | Item | Verdict | Why / what |
|---|---|---|---|
| A-1 | **Roles pushed by the MDM**: Viewer, Reviewer, Examiner, Administrator, with a fixed permission matrix | **Required** | Today anyone who can open the app can delete evidence, release a legal hold, produce documents or change modules. Legal and forensic organisations separate these duties. Apple's ManagedApp framework names "enforcing the role of a person" as a core managed-app feature. |
| A-2 | Every restricted action checks the role at one funnel and says why it is unavailable | **Required** | Delete, release hold, production / Bates, import, export, modules, snapshot restore, license entry. |
| A-3 | The role is recorded in the audit trail with each action | **Required** | Who did what, with which authority — the audit trail already records who. |
| A-4 | Unmanaged installs keep today's behaviour (the single user is Administrator) | **Required** | Rule: switching back loses nothing; private users are unaffected. |
| A-5 | Sign-in / SSO inside the app | **Not needed** | No server to sign in to. The person is authenticated by the device login (which an org can back with Platform SSO) plus the app lock the MDM can force (`requireBiometricLock`, done). |
| A-6 | Dual control (a second person approves releasing a hold) | **Not needed for 3.0** | Needs two people on one device or a server; release is restricted to Administrators instead (A-1). |

## 4. Profiles (configuration delivered to devices)

| # | Item | Verdict | Why / what |
|---|---|---|---|
| P-1 | Published configuration schema: an AppConfig specification file (XML) and a Jamf custom-schema JSON, so admins pick keys from a form instead of typing plist | **Required** | MDM consoles import these; without them every key is hand-typed. |
| P-2 | A sample configuration profile (`.mobileconfig`) and per-MDM steps (Jamf, Intune, Kandji) | **Required** | |
| P-3 | Deployment guide names the right bundle id (`com.ecosanskriti.mailin.enterprise`) | **Required** | The guide still names the public app's id. |
| P-4 | Declarative app configuration (ManagedApp framework) in addition to classic managed configuration | **Recommended (later)** | Newer MDMs prefer it; every MDM still supports the classic dictionary this app reads. |

## 5. Business integration

| # | Item | Verdict | Why / what |
|---|---|---|---|
| B-1 | Standard e-discovery exports (Concordance/Relativity DAT + OPT, CSV, PDF, EML/MBOX, privilege log, BagIt) | done | — |
| B-2 | **Data-loss controls** by policy: allow/deny exporting, printing and sharing out of the app | **Required** | Standard for managed apps holding confidential data; all saving goes through one funnel (`PlatformExport`), so it can be enforced there. |
| B-3 | **Audit log export for the organisation's SIEM / records system** (JSON Lines + CSV, with the hash-chain head so tampering shows) | **Required** | Security teams ingest audit logs centrally; offline, the hand-off is a file. |
| B-4 | Matter / case numbering from the organisation (`caseNumberPrefix`) | done | — |
| B-5 | Live API, webhooks, ticketing or DMS connectors | **Not needed** | Network — against the Private edition. File exports are the integration surface. |

## 6. Also expected by enterprise buyers (beyond the five asked)

| # | Item | Verdict | Why / what |
|---|---|---|---|
| X-1 | Data at rest protected (iOS data protection classes; macOS FileVault documented as a requirement) | done / documented | — |
| X-2 | Remote wipe / offboarding: what happens to the archive when the MDM removes the app | **Required (document + test)** | iOS removes a managed app's data with it; on macOS the archive stays — state it and give the admin a removal step. |
| X-3 | Security documentation: whitepaper, assurance pack, no-network proof | done (refresh numbers) | — |
| X-4 | Accessibility conformance statement | done (`ACCESSIBILITY_3_0.md`) | — |

## Status (2026-10-11)

Done (dc6f782 and the following commit): A-1 – A-4 roles and funnels (store gate for delete and holds), B-2
export / print policy, V-1 validation, V-2 / C-1 Managed App Feedback with licence id, B-3 JSON Lines audit
export, P-1 – P-3 schema files / sample profile / guide, X-2 offboarding, macOS profile-forced keys read
(tested). Every new string translated into the 10 languages.
Remaining: P-4 declarative ManagedApp configuration (recommended, later); V5 UI check of the refusal messages.

## Build order (Required items)

1. **A-1 – A-4** roles and permission funnel (largest, highest value).
2. **B-2** export / print / share policy at the `PlatformExport` funnel.
3. **V-1, V-2, C-1** configuration validation + managed feedback (license id for seat accounting).
4. **B-3** audit log export.
5. **P-1 – P-3, X-2** schema files, sample profile, guide fixes, offboarding note.

Each ships with tests and translations, and stays off for unmanaged installs.
