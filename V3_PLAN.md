# mailin v3 — Plan, Persona Decision, and Professional-Claim Verification

Date: 2026-09-05 · Basis: kalsmritikosh persona-job matrix (107 jobs, 16 shared job-kinds,
4-tier tooling model) cross-mapped against mailin 2.0's 47 workflows + tools.

---

## 1. Professional-claim verification (2.0, BEHAVIORAL — executed, not code-read)

The PST lesson (2.0.1): "code looks right" is not "verified working". Every professional
claim must pass a behavioral check. Results of this round:

| # | Claim | Check executed | Result |
|---|-------|----------------|--------|
| 1 | Tamper-evident HMAC audit log | Appended entries, ran `verifyChain()` | ✅ PASS |
| 2 | Ed25519 signed exports | Signed payload, verified genuine, tampered byte → rejected | ✅ PASS |
| 3 | Bates numbering | 5 emails → MAILIN000001–000005 sequential; CSV index with 7 std columns | ✅ PASS |
| 4 | Concordance load file | Generated DAT: þ-delimited, 13 standard fields (DOCID…CUSTODIAN,TAG), row/header parity | ✅ PASS |
| 5 | Legal hold blocks deletion | Held 1 of 3, attempted delete of all → held email blocked | ✅ PASS |
| 6 | Person redaction (GDPR/share-safely) | Redact "Priya Sharma"/address → **standalone first name "Priya" LEAKED** | ❌ **DEFECT** |
| 7 | S/MIME verification | Not yet behaviorally checked (needs a signed sample email) | ⬜ TODO |
| 8 | Predictive coding ranking quality | Not yet behaviorally checked (needs labeled gold set) | ⬜ TODO |
| 9 | Bates-stamped PDF (stamp visible on page) | Not yet behaviorally checked (PDFKit read-back) | ⬜ TODO |
| 10 | Anomaly detection statistics | Not yet behaviorally checked (synthetic spike corpus) | ⬜ TODO |
| 11 | PST/EML/MSG export round-trips | ✅ Done in 2.0.1 cycle (write → re-parse → byte-compare) | ✅ PASS |

**Defect V3-D1 (fix in 2.0.x, before v3):** `RedactionEngine.personRedactionRules` covers
full name + email but not standalone name tokens. "Priya will bring it." survives redaction.
Fix: add word-boundary token rules per name part (opt-in for ambiguous/common-word names),
and add a redaction-validation pass (LAW-14) that re-scans output for the targets.

**Standing rule:** checks 7–10 become part of Phase 0 gold cases; every future professional
feature ships with a behavioral check, CI-runnable.

---

## 2. Persona decision

| Persona | Decision | Rationale |
|---|---|---|
| Forensic (≈ Investigator) | Keep, deepen | Core buyer; gets ACH matrix + reliability grid + contradiction desk |
| Legal (≈ Lawyer) | Keep, deepen | Core buyer; gets fact–evidence matrix + redaction validation + issues register |
| IT Admin | Keep as-is | mailin exclusive — kalsmritikosh has no counterpart; 10 workflows already strong |
| Journalist | Keep, deepen | Gets cited fact-check board + enforced publish gate + correction chain |
| Personal (≈ Individual) | Keep, email-scoped | Adopt only email-relevant jobs; life-document binders stay out of scope |
| **Researcher** | **ADD (light) — the one new persona** | Email corpora are real research material (archives, FOIA, collections). Costs little: reuses shared studios + search + timeline; needs ~6 light workflows (protocol, corpus catalogue, screening, extraction/coding, chronology, closure). Differentiator no email tool has. |
| Others (HR, insurance-SIU, etc.) | NOT in v3 | No email-primary evidence case strong enough; revisit with sales signal |

---

## 3. What v3 includes (job families) — and what it does not

### Included — five build-families clear ~45 of the 107 kalsmritikosh jobs

**F1. Reasoning Studio (shared shell; the headline feature)**
- ACH Hypothesis Matrix (INV-07/LAW-19/JRN-19/RES-17): hypotheses × email-evidence grid,
  per-cell consistency {CC/C/N/I/II}, fewest-inconsistencies ranking, assumptions panel, gated report
- Brainstorm board (INV-04), 5W1H worksheet (INV-05), Five Whys (INV-13), Fishbone (INV-14),
  Root-cause assessment w/ human decision (INV-15)
- Clears ~12 jobs across all personas

**F2. Fact–Evidence Matrix + citation locators**
- LAW-04 matrix: facts × supporting/opposing emails, every cell reopens the exact email
- Locator type everywhere: Message-ID + date + archive UUID; findings/report approval gate
  refuses uncited assertions (kalsmritikosh "report == receipt" rule)
- Upgrades JRN-02 fact-check board and JRN-12 publish gate (publish blocked until every claim cited)

**F3. CAPA / remediation chain (shared register)**
- CAPA register (INV-16), effectiveness review (INV-17), remediation register/effectiveness
  (LAW-20/21), correction actions/effectiveness (JRN-21/22), fix-it list (IND-20/21)
- One shared register + human-gated verify clears ~9 jobs

**F4. Contradiction & Gap desk + Source-reliability grid**
- Contradiction detection over email claims (both sides preserved, reopenable); gap register
  ("no email from X in scope" — absence ≠ proof) — INV-12, IND-18, RES equivalents
- Admiralty-style A–F × 1–6 reliability grid seeded from SPF/DKIM/DMARC + spoof flags
  (INV-08, LAW-18, JRN-04)

**F5. Evidence-gating layer (applies to all workflows)**
- `prohibitedOutcomes` per workflow (e.g., "assert guilt", "publish unverified") surfaced at sign-off
- Sealed receipts on work products (manifest + HMAC digest; edit → verify fails)
- Honesty ledger labels: undated / single-source / contradicted / unsupported
- Gold case per persona (known-answer dataset) used for onboarding + CI behavioral tests

Plus: **Researcher persona (light)** — 6 workflows reusing F1–F5 surfaces.

### Explicitly OUT of v3 (with reasons)
- Life-document binders (IND-02/04/05/06/07/10/13) — document management, not email; kalsmritikosh's territory
- Interview plans, transcription (JRN-05/07, RES-04) — non-email evidence
- Transaction/asset flow (INV-11), damages ledger (LAW-09), obligations/clauses (LAW-08) — needs structured
  financial/contract tooling beyond email
- Deadlines/docketing (LAW-10), right of reply (JRN-11) — practice-management, not archive analysis
- New personas beyond Researcher

---

## 4. Phases

| Phase | Scope | Exit criterion |
|---|---|---|
| **0 — Prove & fix (pre-v3, ships in 2.0.x)** | Fix V3-D1 redaction leak + validation pass; behavioral checks 7–10 (S/MIME sample, TAR gold set, Bates-PDF read-back, anomaly synthetic corpus); gold-case datasets per persona | All professional claims have a passing executed check |
| **1 — Reasoning Studio** | Shared studio shell + ACH matrix first, then 5W1H/5-whys/fishbone/root-cause/brainstorm | ACH gold case passes; ranked hypotheses cite emails |
| **2 — Citations & gates** | Locator type, fact–evidence matrix, uncited-assertion approval gate, publish gate | No report approvable with an uncited claim |
| **3 — Registers & desks** | CAPA/remediation chain, contradiction & gap desk, Admiralty reliability grid | Each register round-trips to a numbered document |
| **4 — Evidence-gating layer** | prohibitedOutcomes, sealed receipts, honesty-ledger labels | Receipt tamper-check demo passes |
| **5 — Researcher persona + catalog** | 6 researcher workflows; wire all new surfaces into existing personas' catalogs | Coverage matrix: targeted jobs → Present |

Tracking artifact: `V3_JOB_COVERAGE_MATRIX.csv` (kalsmritikosh-style, honest
Present/Partial/Absent status per job) — to be created at Phase 0 start and burned down.

---

## 5. Marketing guardrail (claims discipline)

No v3 claim ships without its behavioral check passing (extends the no-artificial-caps /
round-trip-verify rules). The website's professional section may add features only when the
matching Phase exit criterion is green.
