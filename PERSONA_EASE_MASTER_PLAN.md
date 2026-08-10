# mailin — Persona Ease Master Plan (SAP-inspired governance for email work)

Status: PLAN. Date: 2026-08-10. Grounded in current (2025–26) tools, frameworks,
and verbatim user reviews. This plan translates documented pain into a build.

## 0. The thesis

Every professional persona already owns a capable *analysis* tool (Nuix, Relativity,
PhishER, Datashare). The universal, documented pain is NOT analysis — it is the
**orchestration and record-keeping around the work**: manual logs, tedious clicks,
context-gathering across tools, repeat setup, and stakeholder-facing output. That is
exactly the problem SAP solved for enterprises with its *governance* mechanics
(documents, master data, number ranges, status networks, determination, reversal).

mailin's goal: be the **offline, zero-config governance layer** that makes the record
a byproduct of doing the work — the thing the $11B incumbents don't offer.

## 1. Evidence — what they use and what they complain about

### Forensic (DFIR) — EnCase, Nuix, Magnet AXIOM
Verbatim pain (Forensic Focus, G2, AWS Marketplace):
- "slow with multiple sources"; "viewer doesn't load artifacts"
- "costs have increased each year… difficult in planning budgets"
- reporting "can feel clunky"; "portable case is difficult for detectives and
  prosecutors to use" (stakeholder output is bad)
- chain-of-custody logging is "time-consuming and prone to human error"; incomplete
  logs "break audit trails" → evidence inadmissible
- labs face "case backlogs… one of the most pressing challenges"
Sources: cybertriage.com, forensicfocus.com, champlain.edu, g2.com

### Legal / eDiscovery — RelativityOne
Verbatim pain (G2, Capterra):
- top cons: "Performance Issues (69), Difficult Learning (37), Not User-Friendly (30),
  Expensive (29)"
- "clunky and shows its age… UI for review is slow… few options for batch processing"
- "times out on sessions… losing your place in the document queue"
- "a lot of clicks to accomplish a task"; "can't search the image of the document"
- $0.50–$1.00/doc or $40+/hr review; AI adds "15–30%" to spend
- privilege review = highest-stakes, most time-consuming; missing one is a serious error
Sources: complexdiscovery.com, g2.com, capterra.com, aivortex.io

### IT / SOC — PhishER, Cofense Triage, SOAR
Verbatim pain (SANS/Cyber Insiders surveys, G2/AWS reviews):
- "76% cite alert fatigue"; "73% false positives"; ~6 hrs/shift on triage
- phishing workflows "consuming up to 12 hours daily" pre-automation
- even with tools: "frequent false positives… require manual review" (automation leaks)
- "wanting to see the specific reasons" a verdict was reached (explainability gap)
- "reporting could be greatly improved… executive summary reports"
- analyst tenure 3–5 yrs; burnout; institutional knowledge walks out
Sources: torq.io, vectra.ai, g2.com, aws marketplace reviews

### Journalist — ICIJ Datashare, OCCRP Aleph, Google Pinpoint
Verbatim pain (ICIJ, GitHub, hacksandleaks):
- self-hosted for source protection (no cloud) — a hard requirement
- "issues trying to install it" (Docker setup is hard)
- "reporters missing as much as 20% of features" (discoverability) → 2025 redesign
- "each set of documents brings its own challenge"
Sources: icij.org, github.com/ICIJ/datashare

### Personal — Gmail/Outlook + export tools
Light, episodic. No daily pain. Do not manufacture one.

## 2. The cross-persona pattern (what the reviews agree on)

1. **The record is manual and error-prone** (custody log, privilege log, incident
   write-up). → SAP **document principle**: post it automatically.
2. **Too many clicks / tedious steps / session loss.** → SAP **determination + step
   execution**: derive what's known, run the mechanical action, don't re-key.
3. **Unsafe deprioritization under load; privilege gaps caught late.** → SAP **status
   network + gates**: block the unsafe transition before it happens.
4. **Automation leaks (false positives) with no explanation.** → **explainable
   suggestions**: show *why*, keep the human on the 20% judgment.
5. **Stakeholder output is clunky** (portable case, exec summaries). → **clean,
   printable documents** as a byproduct.
6. **Repeat jobs re-set up each time.** → SAP **selection variants**.
7. **Expensive, per-seat, cloud.** → mailin's structural edge: **offline, one-time,
   one-person**.

## 3. The build — "SAP governance pack" (all offline, no new network surface)

### Phase A — Status network + gates (schema v10)  [FOUNDATION]
- Every WorkflowInstance is a real state machine: statuses with governed transitions.
- Per-operation GATES: an op is locked until its precondition holds, with a plain
  reason shown. Grounded examples from the pain:
  - Legal: "Produce" locked until "Privilege log complete = yes" (the caught-late gap).
  - IT: "Close" locked until a Verdict exists (unsafe deprioritization).
  - Forensic: "Report" locked until hashes verified (broken custody chain).
- Status history table (who/when each transition), folded into the audit chain.
- Pure `WorkflowStatus`/`GatePolicy` engine, fully unit-tested.

### Phase B — Determination / auto-derivation
- At each step, prefill every field the app can compute, so the human keys ~nothing:
  - IT: sender/subject/auth-result derived from the reported email; IOC count computed.
  - Legal: responsive/privileged counts derived from live tags, not typed.
  - Forensic: case # carried across the run; hash algorithm/method defaulted.
- Explainable suggestions (the "why" the reviews beg for): suggested verdict/privilege
  basis with a one-line rationale; user always overrides.

### Phase C — Step execution + selection variants
- Confirm RUNS the mechanical action (import picker, dedup, IOC export, report gen)
  and auto-captures the result number, then auto-advances — kills the "too many
  clicks / navigate-and-return" tax.
- Selection variants: save a run's parameters; start a recurring production/triage
  pre-configured in one click (SAP variant).
- Bulk keyboard-first confirm where a step spans many items.

### Phase D — Stakeholder output + resilience
- Clean, printable "portable" documents for non-technical readers (the AXIOM
  portable-case complaint; the Relativity exec-summary complaint).
- Autosave/never-lose-place (the Relativity session-timeout complaint) — workflow
  state already persists per step; extend to in-progress field entry.

### Phase E — Discoverability (the Datashare 20% lesson)
- The Work Center + guided workflow already lead the user; add a per-persona
  "next best action" hint and ensure no capability is more than one guided step away.

## 4. Sequencing & honesty

- Order: A → B → C → D → E. A is the foundation the rest gate on.
- Each phase is its own verified commit (build + unit suite + macOS UI sim + iOS build),
  same discipline as every prior increment.
- Schema bump: v9 → v10 (status history + variants). Migration suite must stay green.
- Scope honesty (unchanged): single-examiner, on-device; augments judgment, never
  replaces it (the line SOAR/aiR/ICIJ all hold); strongest fit forensic + legal;
  personal stays light. No SAP connector — SAP *principles*, native and offline.

## 5. What success looks like (measurable)
- A persona completes a full job from the workflow with the record produced
  automatically and **zero manual log-writing**.
- Interaction count for a standard run drops ~4× (execute vs. navigate-and-return).
- No run can reach a defensibility hole the reviews describe (missing verdict,
  unlogged privilege, unverified custody) — the gates make it structurally impossible.
