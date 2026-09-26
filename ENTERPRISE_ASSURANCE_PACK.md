# Enterprise assurance pack — mailin 3.0 Private

What an organisation's security reviewer can verify about this build, where the evidence is, and
how it was produced. Written 2026-09-27. Every claim names its proof; a claim without an executed
proof is marked **NOT YET EXECUTED**.

## 1. The claim

**mailin 3.0 Private cannot reach the network.** Not "does not" — cannot. The signed binary carries
no network entitlement under the App Sandbox, so the kernel refuses any socket the code might ask
for, and the networking code is not compiled in at all (`NO_NETWORK_BUILD`).

| Layer | Evidence | How to check yourself | Status |
|---|---|---|---|
| Signed entitlements | `mailin.entitlements`: sandbox, user-selected files, app-scope bookmarks, print — nothing else | `codesign -d --entitlements :- mailin.app` | NOT YET EXECUTED on a 3.0 build (`Scripts/verify-no-network.sh`, Phase J-4) |
| Compile flag | `NO_NETWORK_BUILD` in both configurations; every network file is `#if !NO_NETWORK_BUILD` | `strings mailin.app/Contents/MacOS/mailin \| grep mailin.offline.attested` | NOT YET EXECUTED on a 3.0 build |
| Edition exclusion | `ModuleRegistry.buildExclusions` reports Live Mail as "not included in this edition" under `NO_NETWORK_BUILD`; a state file carrying `liveMail: true` renders unavailable, never on | `EditionExclusionTests` | written, runs in Phase J |
| In-app attestation | About shows `NoNetworkAttestation.summary`, read from the running process's own entitlements | About window | built |
| Runtime | Release run: zero network sockets | `lsof -i -p <pid>` | measured once (2.1); re-run in J-5 |

## 2. Managed deployment

| Key (`com.apple.configuration.managed`) | Effect | Enforcement | Test |
|---|---|---|---|
| `orgName` | shown in About and reports | — | — |
| `examinerName` | preset who-stamps; wins over local name | `ReceiptSealer.seal` | `GoldCaseClosureTests` |
| `disableCloudAI` | cloud AI off, not user-overridable (moot in this edition: not compiled in) | `CloudAIManager`, `CloudAIConsentCenter` | `ManagedPolicyTests` |
| `requireBiometricLock` | lock always on | `BiometricLockManager` | manual |
| `caseNumberPrefix` | preset Bates / case prefix | `BatesNumberingManager` | manual |
| `disabledModules` | page hard-off; Settings shows "unavailable — locked by your organisation"; applies without relaunch | `ModuleRegistry.orgDisabledReason`, policy observation | `ManagedPolicyTests` |
| `licenseKey` | pilot licensing (E2 interim) | About | — |

Malformed keys are ignored with a fault log; an unknown module name in `disabledModules` is ignored.

## 3. Evidence integrity

| Artifact | Protection | Verification | Test |
|---|---|---|---|
| Import receipt | HMAC over the content hash, per-install Keychain key; owner-only file mode | `ImportReceipt.verify()` | `GoldCaseClosureTests` |
| Export / relocation / production receipts | SHA-256 of the artifact or manifest; production record numbered in `DocumentRegistry` | receipt card, `production.json` | `ExportReceiptTests`, `ArchiveRelocationTests` |
| Sealed case bundle (`.mailincase`) | SHA-256 manifest + Ed25519 signature over the digest; public key travels in the receipt | `CaseBundleService.open` refuses a tampered bundle | `GoldCaseClosureTests` (seal/verify) |
| Multi-examiner merge | conflicting readings preserved side by side, never silently merged | `CaseBundleService.mergeArtifacts` → `MergeReport` | `GoldCaseClosureTests` |
| Audit chain | HMAC chain; genesis at Page-3 enablement; `verifyChain()` | Audit trail view | `ProfessionalGatingTests` (no entry on a Page-1-only launch) |
| Legal holds | held rows are not deleted; holds survive disabling Page 3 | `CustodianManager` | `ProfessionalGatingTests` |

## 4. Data locality

- The archive is a folder the operator owns: `<Application Support>/com.ecosanskriti.mailin/` or a
  verified relocation root on a local volume. Cloud-synced and network folders are refused for the
  active store (`ArchiveLocationPolicy`).
- No telemetry, no analytics SDK, no account.
- On-device AI only (Foundation Models, NLEmbedding). The semantic index is opt-in and local.

## 5. Documents in the pack

`NO_NETWORK_PROOF.md` · `NETWORK_AND_PRIVACY_MATRIX.md` · `MODULE_ACTIVATION_MATRIX.md` ·
`SECURITY_WHITEPAPER.md` · `IMPORT_RECEIPT_SPEC.md` · `STORAGE_TIER_FEASIBILITY.md` ·
`WORKFLOW_INVENTORY.md` · `SUPPORTED_FORMATS_AND_LIMITS.md` · `SCALE_RESULTS.md` ·
`PAGE_WINDOW_MATRIX.md` · `RELEASE_READINESS.md` · `ENTERPRISE_DEPLOYMENT.md`.

## 6. What this pack does not claim

- Any size beyond the executed runs in `SCALE_RESULTS.md`.
- Any executed import of OST or NSF (no fixture exists).
- Certification of any workflow row (`WORKFLOW_INVENTORY.md` marks 47 of 51 as Draft / Needs review).
- Anything about the public 2.x consumer app, which is a different binary.
