# Network and privacy matrix (3.0 §11)

What each configuration can do on the network, what it does by default, and how each claim is
proven. Written 2026-09-27. `NO_NETWORK_PROOF.md` holds the artifact-level checks for the offline build.

## Configurations

| Configuration | Compile condition | Entitlements (network) | Pages available | Status |
|---|---|---|---|---|
| **3.0 Private** (this branch, both configurations) | `NO_NETWORK_BUILD` defined (renamed from `OFFLINE_MODE` 2026-09-27) | none — `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `print` only | Archive, AI Insights, Professional; Live Mail reported "not included in this edition" | **no network capability at all**; the kernel refuses a socket. Bundle id for the ABM Custom App pending (owner) |
| **Consumer with Live Mail** (feature branch `live-mail`, L0) | `NO_NETWORK_BUILD` absent | adds `com.apple.security.network.client` | + Live Mail | not merged; see `LIVE_MAIL_PROVIDER_MATRIX.md` |

## Per feature: network behaviour

| Feature | Network use | Default | Consent | Org control | Proof |
|---|---|---|---|---|---|
| Import / search / export / receipts (Page 1) | none | — | — | — | `Scripts/verify-no-network.sh` on the built app |
| On-device AI (Foundation Models, NLEmbedding) | none | on with Page 2 | page activation sheet | `disable AI Insights` policy | model runs in-process; no entitlement |
| Semantic index | none (NLEmbedding on device) | **off** (opt-in switch) | explicit switch | page policy | `SemanticIndex.swift` |
| Cloud AI (OpenAI / Anthropic) | HTTPS to the provider **only when compiled in** (`#if !NO_NETWORK_BUILD`) | off; needs key | **per request** — `CloudAIConsentSheet` shows provider, model, bytes, excerpt; fails closed without a host | `disableCloudAI` hard-off (managed configuration), checked in the provider and in the consent center | `CloudAIConsent.swift`; not compiled in this configuration |
| Digest notifications | none (local notifications) | off | Settings | — | `DigestScheduler` |
| Watch folders | none (local filesystem) | off | Settings | — | `WatchFolderManager` |
| Live Mail (IMAP/SMTP, Graph) | yes, to the user's own providers | off; page must be enabled and an account added | account setup; intent interception on Send/Receive | `disable Live Mail` policy; edition exclusion | feature branch only |
| Crash / analytics telemetry | none | — | — | — | no SDK linked |

## Data at rest

| Data | Where | Protection |
|---|---|---|
| Archive (SQLite, blobs, FTS, embeddings) | `<Application Support>/com.ecosanskriti.mailin/` or the relocated root | sandbox container; owner-only file modes on shards; Data Protection class on receipts |
| Receipts (import, export, relocation) | Application Support | HMAC-signed with a per-install Keychain key |
| Cloud AI API keys | Keychain | per provider |
| Managed configuration | `com.apple.configuration.managed` in UserDefaults | read-only policy |

## Privacy label consequences (App Store)

- 3.0 consumer as built: **Data Not Collected**; no network capability.
- If the Live Mail branch merges: the label must state that email content is transmitted to the
  user's own mail providers at the user's request, and that cloud AI, when enabled and consented per
  request, sends selected text to the chosen provider. Draft text is in `STORE_LISTING_3_0.md`.

## v4.0 (V4-14, 2026-11-12) — offline and connected editions

The table above is the 3.0 record. From v4.0 there are two configurations of one code base. Details and sources:
`docs/V4_PROVIDER_REGISTRATION.md` §0, `docs/PRIVACY_V4_DRAFT.md`.

| Configuration | Compile conditions | Entitlements (macOS) | Mail at run time |
|---|---|---|---|
| **Offline** (`Release`, `Debug`, enterprise edition) | `NO_NETWORK_BUILD` | no `network.client` / `network.server` | not compiled: `ConnectedBuildFeatures.mailTransportsCompiled == false`; Mail page shows "This edition has no mail connection"; proof unchanged (`NO_NETWORK_PROOF.md`) |
| **Connected** (`Release-Connected`, owner creates it) | `MAILIN_CONNECTED_MAIL`, **not** `NO_NETWORK_BUILD`, **not** `MAILIN_CLOUD_AI` | `mailin/mailin-connected.entitlements` = offline set + `network.client` | **off by default**: `MailNetworkPolicy` refuses everything until the Live Mail page / `connectedMail` capability is on; each account off with no modes until granted |

Every mail request asks `MailNetworkPolicy` first (socket, OAuth refresh, redirect, retry, download, request); an
account is bound to its own hosts; AI hosts (`aiHostSuffixes`) and remote content are always refused; no redirect
is followed with a bearer token.

### Hosts the connected edition may contact (exact)

| Provider | Host | Used for | Opened by |
|---|---|---|---|
| Google | `accounts.google.com` | sign-in page | system sign-in window (`ASWebAuthenticationSession`, ephemeral) |
| Google | `oauth2.googleapis.com` | token exchange / refresh (POST) | app, `PolicyCheckedTokenTransport` |
| Google | `gmail.googleapis.com` | capture (`profile`, `labels`, `messages`, `messages/{id}?format=raw`, `history`), send (`upload/…/messages/send`), server actions (`modify`, `trash`, `untrash`) | app (`GmailAdapter`, `GmailSendSubmitter`, `GmailActionExecutor`) |
| Microsoft | `login.microsoftonline.com` (`/common/oauth2/v2.0/authorize`, `/token`); personal accounts may continue on `login.live.com` inside the sign-in window | sign-in, token exchange / refresh | sign-in window; app for `/token` |
| Microsoft | `graph.microsoft.com` | capture (mail folders, delta, `/$value`), `sendMail`, PATCH / move | app (`GraphAdapter`, `GraphSendSubmitter`, `GraphActionExecutor`) |
| iCloud Mail | `imap.mail.me.com:993`, `smtp.mail.me.com:587` | IMAP capture / actions, SMTP send | app (Network.framework, TLS before AUTH) |
| Fastmail | `imap.fastmail.com:993`, `smtp.fastmail.com:465` | same | app |
| Other IMAP | the host and port the user enters | same | app |

Nothing else: no mailin server, no analytics, no AI provider, no remote images. Cloud AI stays uncompiled in both
editions (BYOK scaffolding only, refuses every request).

### Per feature (connected edition)

| Feature | Network use | Default | Consent | Proof |
|---|---|---|---|---|
| Connected mail — Preserve mail | provider → device | off (page + capability + per-account mode) | account sign-in (provider consent screen) + mode switch | `MailPolicyTests`, `GmailAdapterTests`, `GraphAdapterTests`, `IMAPAdapterTests` |
| Connected mail — Send mail | device → provider | off | mode switch + re-consent (`gmail.send` / `Mail.Send`) + explicit Send per message | `OutboxSendTests` |
| Connected mail — Change server mail | device → provider | off | mode switch + re-consent (`gmail.modify` / `Mail.ReadWrite`) + preview / typed count | `RemoteActionService` tests |
| Everything else (import, search, export, on-device AI) | none | as 3.0 | — | as 3.0 |

### Data at rest added by v4

| Data | Where | Protection |
|---|---|---|
| OAuth tokens, IMAP / SMTP passwords | Keychain service `com.ecosanskriti.mailin.connected-account`, account `<UUID>/<kind>` | not synchronised, `AfterFirstUnlockThisDeviceOnly`, never in backup / export |
| Connected accounts, remote folders / messages / memberships, sync checkpoints, capture runs | archive SQLite (`mail_accounts`, `remote_*`, `sync_checkpoints`, `capture_*`) | as the archive |
| Drafts, outbox | archive folder (`draft.json`, `operation.json`, `message.eml`) | as the archive |
| Sending identities, SMTP host names | UserDefaults (`MailAccountExtrasStore`), no secrets | app container |

### Privacy label consequences (v4)

Not decided mechanically from the entitlement: see `docs/V4_APP_PRIVACY_ANSWERS.md` (recommended "Data Not
Collected" with reasoning; conservative alternative; owner questions). Offline edition: unchanged.
