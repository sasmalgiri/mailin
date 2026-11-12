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
| V4-14 | Google / Entra registrations, privacy, store metadata (owner) | agent part: V4-14 commit (packets, drafts, manifest reasons, edition-aware About / privacy summary, T47 check) | `V414ClaimsTests` (5) **not yet run** (run with `RunSomeTests`); `Scripts/check-connected-release.sh` exercised on mock bundles | — (owner: registrations, verification) | — (T47 on the connected candidate) |
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
| SCAF-01…05 | SCAF commit (disabled scaffolding, below) | Package `AIScaffoldContractTests` 14/14 (`swift test`, Mac, 2026-11-12). App `AIScaffoldTests` (5, incl. B01) compiled only — run with `RunSomeTests` | — (no live provider by design) | — |

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
3. **OAuth client values and callbacks** (V4-14 — exact packets in
   [`V4_PROVIDER_REGISTRATION.md`](V4_PROVIDER_REGISTRATION.md); corrected 2026-11-12 from the code):
   - The shipped sign-in (`ConnectedMailProductionTransports`) reads `Info.plist` keys **`MailinGmailClientID`**,
     **`MailinGraphClientID`**, **`MailinGraphRedirectURI`**. Put them in the connected build only (plist fragment
     and build settings `MAILIN_GMAIL_CLIENT_ID` / `MAILIN_GRAPH_CLIENT_ID` in the registration doc's "paste these
     values back" lists).
   - Gmail redirect = the **reversed client ID** `com.googleusercontent.apps.<CLIENT_ID_PREFIX>:/oauth2redirect`
     (`GmailOAuth.defaultRedirectURI`; any other custom scheme is refused). The older
     `com.ecosanskriti.mailin:/oauth2callback` belongs to the legacy `GmailConnector`, which has no caller.
   - Microsoft redirect = **`msauth.com.ecosanskriti.mailin://auth`** (Entra iOS / macOS platform for bundle
     `com.ecosanskriti.mailin`). The enterprise edition is built with `NO_NETWORK_BUILD`
     (`Scripts/testflight.sh --edition enterprise`), so it needs no registration.
   - `CFBundleURLTypes`: not required — `ASWebAuthenticationSession` receives the callback itself. If declared,
     declare only in the connected plist. Either way, giving `Release-Connected` its own `INFOPLIST_FILE`
     (`Info-Connected.plist`, a copy plus the three keys) keeps the offline build's `Info.plist` byte-identical.
   - T47: `Scripts/check-connected-release.sh <connected app>` and
     `V414ClaimsTests.testT47_thisConnectedReleaseBuildHasRealClientIDs` fail while any value is missing, empty,
     `YOUR_…`, `$(…)` or malformed. The legacy connectors' placeholders (`kGmailClientIDPlaceholder`,
     `YOUR_AZURE_CLIENT_ID`) are in uncalled code and are not read by the check.
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
   `nm <binary> | grep -c CloudAIManager` must be 0 on both. On the connected archive also run
   `Scripts/check-connected-release.sh <app>` (T47, all checks PASS).
8. **Accounts, verification, privacy, store (V4-14).** Follow, in this order:
   1. [`V4_PROVIDER_REGISTRATION.md`](V4_PROVIDER_REGISTRATION.md) §1 Google Cloud (project, Gmail API, iOS-type
      client for `com.ecosanskriti.mailin`, scopes, consent screen, verification + demo video) and §2 Microsoft
      Entra (registration, redirect, delegated permissions, publisher verification); paste the values back (step 3).
   2. Verify `sasmalgiri.github.io` (or a custom domain) in Google Search Console and as the Entra publisher domain.
   3. Publish [`privacy/v4-connected-draft.html`](privacy/v4-connected-draft.html) at `/privacy/` **when the connected
      build is distributed** (not before — the live page describes the shipping offline app); reasoning and the
      `PrivacyPolicy.html` section in [`PRIVACY_V4_DRAFT.md`](PRIVACY_V4_DRAFT.md).
   4. App Store Connect ▸ App Privacy from [`V4_APP_PRIVACY_ANSWERS.md`](V4_APP_PRIVACY_ANSWERS.md) (owner decides).
   5. Listing and App Review notes from [`V4_STORE_METADATA_DRAFT.md`](V4_STORE_METADATA_DRAFT.md); demo Gmail /
      IMAP account in the review credentials.
   6. Run `~/mailin-loc-work/keys-v414.py` once the strings are extracted (3 new keys), then `V414ClaimsTests`.

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

## SCAF-01…05 — disabled BYOK AI scaffolding (what was built)

Scaffolding only (plan §0 items 3–5, §8.4). **No live inference, no network transport, no UI entry, no new
purchase product, no price change.** Code: `Packages/ArchiveCore/Sources/ArchiveCore/AIScaffold/` (ArchiveCore
target, no networking API at all) and `maxmailin/AIScaffoldRuntime.swift` (app glue, no callers).

- **SCAF-01** `AIProviderContracts.swift`: `AIProviderKind`, `AIEndpoint` (host + provider-operated /
  customer-managed), `AIProviderProfile` (model is profile data, no hard-coded model list),
  `AICredentialReference` (profile UUID + provider + endpoint host; never the secret), `AISecret` (redacted in
  every textual form, not Codable), `AIRequest` (immutable snapshot: profile, credential reference, purpose,
  trigger, sources, exact payload + SHA-256, prompt version, output limit, cost estimate), `AIRequestRecord`,
  `AIResult` (success / partial / error / cancelled + **actual engine** + usage + transport-call count),
  `AITransport`, `UnavailableAITransport` (the only production transport; refuses everything),
  `AIProductionTransport.liveInferenceShipped = false`, `AIProviderAdapter` (state mapping: no terminal event =
  partial). `AIPolicy.swift`: AI policy independent of `MailNetworkPolicy` (no input from it), off on a fresh
  install, refuses everything while no runtime is shipped, refuses mail hosts (Gmail/Graph/Outlook/IMAP/SMTP
  names), loopback, IP literals and anything that is not a bare host; a cancellation registry; process-wide
  `AIScaffoldCounters` (B01). `AIRequestCoordinator.swift`: the one door — entitlement → policy → source
  eligibility → transport available → budget pre-check → consent on the frozen request → re-check
  (cancellation, policy, entitlement, revocation) → reserve → key by the frozen reference → transport →
  settle + ledger. `AIScaffoldFakes.swift`: `MockAITransport` (success / partial / error / cancel / hang /
  answered-by-another-model), `ScriptedConsentBroker`, `FixedAIEntitlement`, `InMemoryAISecretKeychain`.
- **SCAF-02** `AIKeyProfileStore.swift`: Keychain only, service `com.ecosanskriti.mailin.ai-provider-key`
  (distinct from the connected-mail service and the legacy global one), account `<UUID>/<provider>/<host>`,
  never synchronised, `WhenUnlockedThisDeviceOnly`. `add` never overwrites; `replace` is an in-place update
  (a failed replace keeps the old working key); `remove` reports whether anything was removed; every other
  OSStatus is thrown with its operation. No default/embedded developer key. No settings screen:
  `AIScaffoldRuntime.showsKeyProfileSettings` is false until a runtime exists. The legacy
  `CloudAIProvider` keys (`KeychainHelper`, `cloudAI_<provider>_apiKey`) are untouched and not migrated —
  that is PRO-02.
- **SCAF-03** `AIConsent.swift`: `AIConsentGrant` (one-run grant binds run, payload hash, profile, endpoint,
  model, credential reference, purpose, source fingerprint, data types, spending allowance; automation grant
  binds its rule — a one-run grant never covers automation, B04), `AIGrantRegistry` (revocation, checked
  again just before the transport; one-run grants are used once), `AIOnce`, `AIPendingConsentQueue` (answer,
  host closed and task cancellation race; each request resumes exactly once), `AISourcePolicy` (file imports
  eligible; Gmail-origin blocked until the Google route is approved; Graph/IMAP/unknown need an explicit
  decision). `AIBudget.swift`: `AIPriceTable` (nil rate = unknown), `AICostEstimate` (**unknown ≠ free**:
  never zero, never fits a numeric allowance, refused unless the budget explicitly accepts unknown pricing),
  local `AITokenEstimator`, `AIRunBudget` (per-run + period limits; concurrent reservations share the
  period), `AIUsageLedger` contract (one line per transport call, `reported` / `uncertain`; never a secret or
  payload) and `InMemoryAIUsageLedger`.
- **SCAF-04** `ProAIEntitlement` (app): the existing Professional entitlement through the existing
  `AccessPolicy` — active or lifetime Professional only; Free, Personal and lapsed plans are refused (LIFE-06
  keeps their data). No new product ID; `StoreManager.allProductIDs` unchanged (six).
- **Strings:** none user-facing (no screen). `AIKeyStoreError.message` is English developer text; it must be
  localised in the 10 languages when a settings screen is built.

Tests: package `AIScaffoldContractTests` (14) — production refusal with zero prompts / key reads / transport
calls; mock outcomes and actual engine; mail-host / local-host refusal and policy independence; denied /
pending / cancelled / revoked / AI-off / entitlement-lost during consent → zero transport calls; provider
switch during consent cannot cross-route key or payload (B03); grant coverage and automation grants (B04);
saving a key starts nothing (B04); consent queue resolves once under answer / dismiss / cancel races; unknown
price ≠ free and concurrent reservations; ledger contract; Gmail-origin stays local; Keychain add / replace /
remove with every OSStatus and a failed replace keeping the old key (B02); secret redaction; no key-shaped
literal or network API in the scaffold sources. App `AIScaffoldTests` (5): **B01** (Mail enabled with a fully
granted account, AI off; archive import, Advanced Search, Find-and-export recipe, backup and a connected
capture through `ConnectedArchiveSink` → `AIScaffoldCounters` all zero; no production file outside the
scaffold names a scaffold type; legacy cloud provider not compiled), policy independence, **B02** (a saved key
appears in no export / receipt / backup file, preference domain, diagnostics text or exported script), **B05**
(no developer key, no screen), **SCAF-04** (entitlement table; a key does not unlock Pro; Free access policy
and product list unchanged; Pro + key + yes + a working mock transport still makes no call).

## SCAF-04 — provider billing and retained output

- mailin's subscription pays for app features. **Pro includes the future BYOK software access; it includes no
  provider tokens, credits or allowance.** A future AI request is billed by the customer's chosen provider to
  the customer's own provider account (subject to that account's terms and any credits on it). mailin holds
  no shared developer key, funded proxy, automatic paid fallback or AI credit pack — developer-funded
  inference is zero by design (plan §13.1); development, support and Apple fees are separate costs.
- A ChatGPT / Claude app subscription is not the same as API billing; say "check your provider account",
  never "your chatbot subscription covers it" (§13.2).
- No new purchase product and no price change in this release (§14). A saved key is not proof of Pro and
  never unlocks it; Pro never starts inference on its own; a key never starts spending (B04).
- Unknown prices are shown as unknown. Local estimates are estimates; the provider's invoice is
  authoritative; a local budget cannot see spending by other apps on the same key (§13.5).
- Retained output: AI output already saved locally stays readable under the existing access policy (LIFE-06)
  after a lapse; new AI work stops. Nothing is deleted because a plan changed.

## SCAF-05 — activation checklist for a future live AI route

None of these is required for the scaffolding-only candidate; **all** applicable ones are required before any
live route is enabled, a working AI control is shown, or a model is named in product text.

1. **Owner decision** recorded in the tracker: which provider(s), which features, which configuration
   compiles a transport (a new flag beside `MAILIN_CLOUD_AI`; offline Release still compiles none).
2. **Transport** (PRO-02): a real `AITransport` per provider, compiled only in the AI configuration; TLS only;
   the request's own endpoint is the only destination; redirects / pagination / tool hosts never receive the
   key (TA08); `AIProductionTransport.liveInferenceShipped` flipped only in that configuration.
3. **Adapters** (PRO-02): Anthropic / OpenAI request encoding and complete response + stream parsing (all
   content blocks, stop / error / usage events, no terminal event = partial); models validated through the
   provider's model list at runtime; Opus 5.5 (`claude-opus-5-5`) and others re-checked for availability and
   price on the activation date (TA10, TA11).
4. **One coordinator** (PRO-01): every UI, background, workflow, script and Shortcuts entry goes through
   `AIRequestCoordinator`; the legacy direct calls in `CloudAIProvider` / `FoundationModelEngine` /
   `AIAssistantView` are routed through it or stay uncompiled; the §12.2 race (key read, consent awaited,
   mutable provider used) is gone (TA04–TA06, TA25).
5. **Keys** (PRO-02): settings screen for add / replace / remove showing every Keychain error; legacy
   `cloudAI_*` items migrated by copy-verify (rule 1) or left and ignored; restore shows profiles as
   disconnected; TA07 scan (logs, preferences, backups, exports, review packs, crash output, accessibility).
6. **Consent** (PRO-03): a sheet driving `AIPendingConsentQueue` that shows provider, model, purpose,
   accounts, message / file counts, data types, coverage and estimated cost, with inspection of the exact
   payload; scoped grants; revocation UI; automation grants separate (TA04–TA06, B04).
7. **Source policy** (PRO-03, §13.8): Google Workspace / Limited Use route decided (and assessment if needed)
   before `gmailRouteApproved` can be true; organisation mail allow / deny controls; provenance survives
   export / reimport (TA26, TA27).
8. **Cost** (PRO-04): dated price tables per model; per-run and period budgets and confirmation above a
   threshold in UI; reservations before every step; uncertain billing recorded on timeout; bounded retries
   honouring `Retry-After`; a bounded paid test with an authorised key reconciles the ledger with returned
   usage (TA12–TA14).
9. **Evidence** (PRO-05): full-index retrieval and one evidence bundle for transport, citations and
   provenance; the 500 / 2,000-character shortcuts removed from upgraded paths; abstention on no evidence
   (TA15–TA18).
10. **Entitlement** (PRO-13): Release StoreKit matrix — Pro monthly / yearly / lifetime, restore, lapse,
    legacy lifetime — with no DEBUG unlock (`debugUnlocksAllTiers`) in the evidence (TA02, TA03, B06).
11. **Privacy and store text**: App Privacy answers, privacy page, onboarding and help say "optional AI
    through your chosen provider"; no blanket "zero cloud" claim on that build; Apple guideline for sharing
    personal data with third-party AI met (§13.8).
12. **Localisation and accessibility**: every new string in the 10 languages (rule 10); keyboard and
    VoiceOver for the new controls (TA35).
13. **Gates on the exact candidate**: B01–B06 still pass; TA01 (no key, no internet: five jobs and exact
    search work); the applicable TA rows for every advertised capability; five-job and online-mail journeys;
    a focused Pro pilot (§16) with thresholds chosen before it runs. Only then expose the feature and name
    the tested model IDs.
