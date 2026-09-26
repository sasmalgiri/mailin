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
