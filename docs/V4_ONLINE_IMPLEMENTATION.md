# mailin v4.0 — online implementation index

Index of the v4.0 rows in [`FIVE_JOBS_TRACKER.md`](../FIVE_JOBS_TRACKER.md) § "v4.0" (plan:
`Mailin_V4_Online_Mail_Audit_and_Implementation_Plan_2026-11-09-3.md`). The tracker stays the authority for
state; this file shows the **evidence** for each row in four separate columns, so that
"implemented" can never be read as "verified":

- **Implemented**: the code is merged, with the commit.
- **Automatically verified**: the named deterministic tests have **run and passed** on the Mac (and iOS where relevant).
- **Provider / device verified**: run against a real provider account or a real device (plan §9).
- **Candidate Release verified**: run on the signed distribution candidate (offline and connected Release, plan T47).

A dash means no evidence yet. An empty cell is never "done".

## Connected mail

| ID | Item | Implemented | Automatically verified | Provider / device verified | Candidate Release verified |
|---|---|---|---|---|---|
| V4-00 | Baseline; live-mail branch concepts only | 1e0209f | — (build only) | — | — |
| V4-01 | Mail / cloud-AI flag split; `MailNetworkPolicy`; `connectedMail` capability; Health; connected entitlements file; owner project checklist (below) | V4-01 commit (code + entitlements file); **project changes pending (owner, below)** | Compiled only: Mac + iOS Simulator `build-for-testing` with the offline flags, Mac `build` with `MAILIN_CONNECTED_MAIL` alone and with `MAILIN_CLOUD_AI` alone. Symbol check: offline binary has 0 IMAPClient/GmailConnector/OutlookConnector/CloudAIManager symbols; mail-only binary has the mail ones and 0 CloudAIManager; AI-only binary has CloudAIManager and 0 mail ones. `MailPolicyTests` (7) **not yet run** — `xcodebuild test` cannot run from the agent sandbox; run with `RunSomeTests` | — | — (needs the Release-Connected configuration) |
| V4-02 | MailAccount + account-scoped Keychain; native OAuth PKCE + state; single-flight refresh | — | — | — | — |
| V4-03 | Provider adapter + archive sink contracts; migrations; provenance; FIELD_CONTRACT.md | — | — | — | — |
| V4-04 | Persistent sync scheduler | — | — | — | — |
| V4-05 | Gmail RAW MIME capture, labels, history | — | — | — | — |
| V4-06 | Outlook / M365 Graph MIME capture, folders, delta | — | — | — | — |
| V4-07 | IMAP byte-correct UID engine | — | — | — | — |
| V4-08 | Live mail through all five jobs | — | — | — | — |
| V4-09 | Durable multi-draft editor | — | — | — | — |
| V4-10 | Sending + durable outbox | — | — | — | — |
| V4-11 | Journalled server actions | — | — | — | — |
| V4-12 | Drives, backup/restore, account removal, lifecycle | — | — | — | — |
| V4-13 | Mail workspace UI, accessibility, 10 languages | — | — | — | — |
| V4-14 | Google / Entra registrations, privacy, store metadata (owner) | — | — | — | — |
| V4-15 | All gates on one candidate | — | — | — | — |

## Archive closeout, recipes, Advanced Search, AI scaffolding

| ID | Implemented | Automatically verified | Provider / device verified | Candidate Release verified |
|---|---|---|---|---|
| CLOSE-01 | edcc45d | `LargeSingleMessageTests` (Mac, 2026-11-09) | — | — |
| CLOSE-02 | 8926d1c | `ContainerRecursiveIntakeTests`, `ContainerKillResumeTests` (Mac, 2026-11-09) | — | — |
| CLOSE-03 | 904cd5a, fd45b97 | `IWork13StreamingUnlockTests`, `InlineAttachmentDecodingTests` | — | — |
| CLOSE-04 | fd45b97 | `NativeOLMPairFixtureTests` 5/5, preflight 0 unresolved | — | — |
| CLOSE-05 | — | — | — | — |
| CLOSE-06 | — | — | — | — (needs ReleaseTesting, below) |
| REC-01…04 | d351d5b | `RecipeRunTruthTests` RQ01–RQ05 (Mac, 2026-11-09) | — | — |
| REC-05…08 | — | — | — | — |
| SEARCH-01…03 | 1e0209f | `testSEARCH01_*`, `testSEARCH02_*`, `testSEARCH03_*` (Mac, 2026-11-09) | — | — |
| SEARCH-04 | — | — | — | — |
| SCAF-01…05 | — | — | — | — |

## V4-01 — what was built

- **Two compile-time conditions** replace the one broad `NO_NETWORK_BUILD` gate:
  `MAILIN_CONNECTED_MAIL` (mail transports) and `MAILIN_CLOUD_AI` (cloud AI). `NO_NETWORK_BUILD` still
  keeps both out. Every gate is written `#if <condition> && !NO_NETWORK_BUILD`. With neither new
  condition defined (today's shipping build) nothing changes: no transport and no cloud AI is compiled.
  Classification of the 31 code gates (NoNetworkAttestation's marker stays on `NO_NETWORK_BUILD`):
  - mail (9): CloudConnectView, ComposeEmailView, EmailDetailView (empty compose block), GmailConnector,
    IMAPClient, IMAPConfigView, OutlookConnector, SMTPClient (file gates) and
    `ModuleRegistry.buildExclusions` (Live Mail page).
  - cloud AI (22): CloudAIProvider (file), SettingsView ×4, AIAssistantView ×10, FoundationModelEngine ×7.
- **`MailNetworkPolicy`** (`maxmailin/MailNetworkPolicy.swift`): the gate every mail transport asks
  before a socket, OAuth refresh, redirect, retry, download or request. Mail off on a fresh install;
  account permission modes Preserve mail / Send mail / Change server mail, all off; each account bound
  to its own mail and sign-in hosts (no bearer token to a redirected host); AI hosts and remote content
  always refused; refused and permitted attempts counted by reason; a cancellation registry so
  switching Mail or an account off cancels its work and refuses new work.
- **Capability `connectedMail`**: owned by the existing Live Mail page (`AppModule.liveMail`), maturity
  preview, off. `CapabilityWiring` pushes its resolved state into the policy, so switching the page or
  the capability off closes the policy and cancels mail tasks. In a build without the transports the
  page is excluded, so the switch can never be on.
- **Health**: Settings ▸ Health ▸ "Mail network" shows whether this edition has mail / cloud-AI code,
  Mail on/off, each account's modes, connections allowed / refused (with reasons) and tasks stopped.
  No account UI yet (V4-02).
- **Entitlements file**: `mailin/mailin-connected.entitlements` = `mailin/mailin.entitlements`
  (app-sandbox, print, user-selected read-write, app-scope bookmarks) **plus**
  `com.apple.security.network.client`. Nothing signs with it until the owner does step 2 below.

## Owner checklist — project changes to make in Xcode (rule 12: not applied by the agent)

Do these in Xcode's project editor (not by editing `project.pbxproj` while Xcode is open), then commit.

1. **Add the connected configuration.** Project `maxmailin` ▸ Info ▸ Configurations ▸ **+** ▸
   *Duplicate "Release" Configuration*; name it **`Release-Connected`**. This creates the configuration for
   the project and for the `maxmailin`, `maxmailinTests` and `maxmailinUITests` targets.
2. **Target `maxmailin`, configuration `Release-Connected`** (Build Settings, "Release-Connected" column only):
   - `SWIFT_ACTIVE_COMPILATION_CONDITIONS` = `MAILIN_CONNECTED_MAIL $(inherited)` — remove
     `NO_NETWORK_BUILD`; do **not** add `MAILIN_CLOUD_AI`.
   - `CODE_SIGN_ENTITLEMENTS` (macOS / Any SDK) = `mailin/mailin-connected.entitlements`.
   - `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` stays `mailin/mailin_iOS.entitlements` (iOS needs no network
     entitlement).
   - Leave `Release` exactly as it is: `NO_NETWORK_BUILD`, `mailin/mailin.entitlements` (the offline build).
3. **OAuth callback URL schemes** (`CFBundleURLTypes` in `Info.plist`), connected build only. Add beside the
   existing `mailin` scheme (do not remove it):
   - Gmail: scheme **`com.ecosanskriti.mailin`** (redirect `com.ecosanskriti.mailin:/oauth2callback`, as
     `GmailConnector` uses). If the Google iOS/macOS client is registered with the reversed client ID
     instead, the scheme is `com.googleusercontent.apps.<CLIENT_ID_PREFIX>` and `GmailConnector`'s
     redirect must change to match — decide when the client is registered (V4-14).
   - Microsoft: scheme **`msauth.com.ecosanskriti.mailin`** (redirect `msauth.com.ecosanskriti.mailin://auth`,
     as `OutlookConnector` uses). The 3.0 Private edition's bundle is `com.ecosanskriti.mailin.enterprise`;
     its scheme would be `msauth.com.ecosanskriti.mailin.enterprise` with its own Entra redirect.
   - Because `Info.plist` is shared by both configurations, either accept that the offline build also
     declares the two schemes (nothing in it handles them — mail code is not compiled), or give
     `Release-Connected` its own `INFOPLIST_FILE` (e.g. `Info-Connected.plist`, a copy plus the schemes).
     Owner choice; the second keeps the offline build's declarations unchanged.
   - Client IDs are still placeholders (`kGmailClientIDPlaceholder`, `YOUR_AZURE_CLIENT_ID`): no connected
     build is labelled ready until they are real (plan A03, T47).
4. **`Info.plist` path case (A03).** The project's `INFOPLIST_FILE` is **`info.plist`** (target `maxmailin`,
   Debug and Release), but the file on disk and in Git is **`Info.plist`** (repository root). It builds only
   because the Mac's disk is case-insensitive; a case-sensitive checkout (CI, Xcode Cloud) would not find it.
   Fix: set `INFOPLIST_FILE` = `Info.plist` for every configuration of target `maxmailin` (including
   `Release-Connected`). **No file rename is needed** — the file already has the correct case; only the
   build setting changes.
5. **ReleaseTesting / ENABLE_TESTABILITY (R10 / CLOSE-06, already pending).** Duplicate `Release` as
   **`ReleaseTesting`** and set `ENABLE_TESTABILITY = YES` for target `maxmailin` in that configuration only;
   point the "maxmailin Release Tests" scheme's Test action at `ReleaseTesting`. Alternative without a
   project edit: `xcodebuild test -scheme "maxmailin Release Tests" -configuration Release ENABLE_TESTABILITY=YES`.
   If connected tests are wanted in Release too, also duplicate `Release-Connected` as
   `ReleaseTesting-Connected` with the same two settings as step 2 plus `ENABLE_TESTABILITY = YES`.
6. **Schemes.** Add a shared scheme "maxmailin Connected" whose Run / Archive use `Release-Connected`
   (Archive) and Debug with `MAILIN_CONNECTED_MAIL` for Run if a connected Debug is wanted (that needs a
   `Debug-Connected` configuration made the same way from `Debug`, keeping `DEBUG`).
7. **Verify the signed result (A01, T47)** for both archives:
   `codesign -d --entitlements - <app>` — offline Release shows **no** `network.client`;
   Release-Connected shows `network.client` and nothing else new. `Scripts/verify-no-network.sh` must PASS
   on the offline Release and is expected to report "online capable" on the connected one.
   `nm <binary> | grep -c CloudAIManager` must be 0 on both.

## New user-facing strings (V4-01) — to translate into the 10 languages

Capability matrix: "Connected mail"; "Lets mail accounts connect to their own mail servers, each only for
what you allow it: preserve mail, send mail, change server mail. Never connects to an AI service or loads
remote content."; "Every mail connection in progress stops and no new one starts. Mail already in the
archive stays and is fully usable."

Policy: "Preserve mail"; "Send mail"; "Change server mail"; "This edition has no mail connection code.";
"Mail is switched off."; "The account is not known to mailin."; "The account is switched off.";
"The account has not been allowed to do this."; "The server is not one this account uses.";
"Mail never connects to an AI service."; "Mail never loads remote content."

Health: "Mail network"; "Mail connection code"; "In this edition"; "Not in this edition"; "Mail"; "On";
"Off"; "Cloud AI code"; "No mail accounts."; "Connections allowed"; "Connections refused";
"%lld × %@"; "Mail tasks running: %lld; stopped by a switch: %lld"; "On, nothing allowed";
"Every mail connection asks this policy first. It never allows an AI service or remote content."
