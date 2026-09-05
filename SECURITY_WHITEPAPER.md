# mailin — Security & Assurance Whitepaper (v3)

Prepared for enterprise security reviews. Companion documents:
`ENTERPRISE_DEPLOYMENT.md` (MDM guide), `V3_PLAN.md` (engineering plan),
`V3_JOB_COVERAGE_MATRIX.csv` (capability ledger).

## 1. Architecture: local-first by construction

mailin has **no server component**. There is no tenant, no account system, no vendor-side
data store, and no telemetry. The attack surface a reviewer normally evaluates for a SaaS
product — transport, storage-at-rest in vendor infrastructure, employee access, breach
notification — does not exist because the data never leaves the customer's device.

Data flow:
1. **Ingest** — user-selected archive files (.mbox/.pst/.ost/.eml/.emlx/.msg/.nsf) are
   parsed on-device (streaming parsers; memory-mapped for large PST/OST).
2. **Store** — a local SQLite database inside the App Sandbox container
   (Application Support), with schema-versioned transactional migrations.
3. **Process** — search (FTS5), NLP (Apple NaturalLanguage), and AI
   (Apple Intelligence / FoundationModels) run on-device.
4. **Egress** — only user-initiated exports to user-chosen locations. The single optional
   network feature (cloud AI with a user-supplied API key) is off by default, opt-in with
   an explicit consent dialog, and can be **disabled fleet-wide** via managed configuration
   (`disableCloudAI`) — a hard gate the UI cannot override.

## 2. Key management

| Key | Purpose | Storage |
|---|---|---|
| HMAC audit-log key (symmetric) | Chains and signs every audit entry | Device Keychain, per-install |
| Ed25519 signing key | Sealed receipts on documents, signed exports, case bundles | Device Keychain, per-install |
| Cloud AI API key (optional, user's own) | Only if the user opts into cloud AI | Device Keychain |

Public keys travel inside sealed artifacts, so third parties verify signatures without
contacting the originating machine.

## 3. Integrity mechanisms

- **HMAC-chained audit log** — every entry's MAC covers the previous entry's hash;
  a verification walk detects tampering at the exact index.
- **Sealed receipts** — every numbered work product (reports, matrices, registers)
  carries a SHA-256 digest + Ed25519 signature over its content; verification strips the
  receipt section, recomputes, and fails loudly on any edit.
- **Sealed case bundles (`.mailincase`)** — team handoff files carry the same seal over
  the entire payload; import verifies BEFORE opening and refuses tampered bundles.
- **Chain of custody** — per-email SHA-256 baselines, custody events (who/when/what),
  and integrity re-verification.
- **Legal hold** — held emails are excluded from every delete path.

## 4. Evidence-gating (kalsmritikosh discipline)

Professional outputs are constrained by design:
- Every claim in a studio work product cites an email locator (Message-ID + date) or is
  explicitly recorded as an assumption/UNKNOWN.
- Tier-4 decisions (findings, closures, root causes, effectiveness) require an explicit,
  named human decision; the app never concludes on its own.
- Prohibited outcomes are displayed on every guided job (e.g., forensic jobs never assert
  guilt; journalist jobs never publish uncited claims).
- Contradictions preserve both sides; gap registers record absence without treating it
  as proof.

## 5. Executed validation evidence (not just code review)

Every claim below was verified by EXECUTING the feature in the shipping codebase and
observing the result (dates per repository history):

| Claim | Executed check | Result |
|---|---|---|
| Audit chain detects tampering | append entries → `verifyChain()` | PASS |
| Ed25519 seals reject modification | sign → verify; flip 1 byte → rejected | PASS |
| Document receipts detect edits | seal document → verify; mutate field → content mismatch | PASS |
| Case bundles refuse tampering | export sealed bundle → corrupt 1 char → import refused with digest diff | PASS |
| Legal hold blocks deletion | delete 3 with 1 held → held email blocked | PASS |
| Redaction output is clean | person redaction → independent output re-scan finds no leak (defect found & fixed in v3: standalone tokens + case-insensitivity) | PASS |
| Bates numbering sequences correctly | 5 emails → prefix000001–000005 + CSV index | PASS |
| Concordance DAT format valid | þ-delimited, 13 standard fields | PASS |
| Anomaly statistics behave | planted spike / late-night / new-domain corpora → detected at documented thresholds | PASS |
| Managed policies enforce | injected MDM dictionary → cloud AI hard-off, forced lock, managed identity in seals | PASS |
| Multi-examiner merge preserves conflicts | same-id different-content artifact → both readings kept with attribution | PASS |
| PST/EML round-trip fidelity | write → re-parse → byte-compare (incl. 5 MB attachment) | PASS |

Deferred to the gold-case suite (documented, not claimed): S/MIME verification against a
signed sample; TAR ranking quality under an async test host; Bates-stamped PDF visual
read-back.

## 6. Honest limitations

- mailin's exported PST containers round-trip through mailin; native Microsoft Outlook
  mountability is not yet claimed (allocation-map work tracked).
- Admissibility of digital evidence is jurisdiction-specific; mailin's integrity artifacts
  support defensibility but no software determines admissibility.
- AI features can produce inaccurate results; all AI outputs are grounded, cited, and
  positioned as assistance, never determinations.

Contact: sasmalgiri@gmail.com · EcoSanskriti Innovation Pvt Ltd
