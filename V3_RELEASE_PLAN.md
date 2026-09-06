# mailin v3 — Release Plan (consumer 3.0 + Enterprise Custom App)

Date: 2026-09-06. All v3 feature work is code-complete and behaviorally verified
(see `V3_PLAN.md`, `V3_JOB_COVERAGE_MATRIX.csv`: 64 Present / 11 Partial / 0 Absent).
This plan covers the path from "code-complete" to "on the store + sellable to orgs".

**E2 licensing decision — RESOLVED:** Enterprise ships as an Apple **Custom App**
(private distribution via Apple Business Manager). Rationale: Apple confirms IAP/
subscriptions cannot be bulk-purchased through ABM; Custom Apps are Apple's sanctioned
route; pricing is negotiable per organization; orgs deploy via their MDM and our
managed-config keys (E1). The Enterprise Program (in-house certs) is not applicable.

---

## Release sequencing (hard order)

```
NOW ──► iOS 2.0 approved & released (in review; price + IAP steps resolved)
     ──► 2.0.1 both platforms (PST fix, rating removal, IAP discoverability)
     ──► R1–R2: v3.0 consumer release (both platforms)
     ──► R3: "mailin Enterprise" Custom App SKU (macOS first, iOS follows)
     ──► R4: website + enterprise page + outreach
```

v3 must NOT jump the queue: 2.0.1 fixes a shipped defect (PST export) and should
reach users first and fast.

---

## R1 — Code readiness (engineering, ~2–4 days)

R1.1 **Enterprise build configuration**
- New bundle id `com.ecosanskriti.mailin.enterprise`, target/config "mailin Enterprise"
  from the same codebase; compile flag `ENTERPRISE_EDITION`
- Behavior under the flag: all Professional features unlocked (StoreManager reports
  `.professional`), no paywall UI, no IAP references (App Review rejects dead IAP UI),
  About shows "Enterprise Edition" + managed-org provenance
- Managed-config `licenseKey` remains for pilots on the consumer build only
- Exit: enterprise config builds; behavioral check confirms tier == professional and
  paywall/IAP surfaces absent

R1.2 **Gold-case closure (the three deferred checks)**
- S/MIME: generate a self-signed S/MIME sample message; verify SMIMEHandler verdict path
- TAR: add an async XCTest host (unit-test target) asserting relevant>irrelevant ranking
  on the labeled synthetic set
- Bates-stamped PDF: PDFKit read-back asserting the stamp appears on page 1
- Exit: all three PASS or documented as known-limitation in the whitepaper table

R1.3 **Partial-row triage (11 Partials)**
- Ship-blockers: NONE (all Partials are enhancements: cited dossier, timeline locators,
  issues register, reopen history, publish-gate hard enforcement, renewal extraction,
  researcher catalogue view, periodisation)
- Action: mark each Partial with "v3.1" in the matrix; no code work in R1
- Exit: matrix annotated; release notes claim only Present rows

R1.4 **Regression + platform pass**
- Full build both platforms (macOS + iOS simulators); fix any iOS-only layout issues in
  the five studios (Grid on iPhone width, pickers, sheets)
- v13 schema migration smoke: open a copy of a 2.0 database in the v3 build
- UI test: extend MailinClickThroughUITests to open each new studio (screenshot source)
- Exit: both platforms build + studios usable on iPhone/iPad/Mac

## R2 — Consumer 3.0 release (release engineering, ~2 days after iOS 2.0.1 is live)

R2.1 Version/bump: MARKETING_VERSION 3.0, fresh build number (both targets)
R2.2 Store metadata: update description (add the five studios + Researcher persona +
  team handoff — every claim maps to a verified matrix row), What's New, keywords
R2.3 Screenshots: macOS 2880×1800 + iOS 6.9" set featuring ACH matrix, Reasoning
  Studio, Fact–Evidence matrix, Evidence Desks, Researcher hub
R2.4 Archive + upload both, TestFlight sanity (import → studio → sealed doc → export),
  submit both; EULA link + price confirmations already learned from 2.0 review cycle
R2.5 Landing page: v3 section + updated gallery (reuse UI-test capture pipeline)

## R3 — Enterprise Custom App SKU (~2 days + Apple review)

R3.1 App Store Connect: new app record "mailin Enterprise" (enterprise bundle id)
R3.2 ⚠️ BEFORE first submission: Pricing & Availability → App Distribution Methods →
  **Private** (locks at approval; cannot be changed after) + add first Organization ID
  (own/test org first — enroll EcoSanskriti in Apple Business Manager to self-test the
  managed-license flow end to end)
R3.3 Price: set list custom-app price (negotiated per org; start USD 199/seat/year
  equivalent as paid-upfront — final call: Shirshendu)
R3.4 Review notes: sample archive + explanation (forensic tool, no account, features
  unlocked because enterprise SKU); attach ENTERPRISE_DEPLOYMENT.md + whitepaper links
R3.5 Post-approval: verify appears in ABM Custom Apps; MDM-deploy to a test Mac with
  managed config; run the E1 policy checks on the deployed build
R3.6 Per-customer runbook: collect Org ID → add in ASC (no new binary needed) →
  invoice/agreement outside Apple or via custom-app price

## R4 — Go-to-market (parallel with R3 review)

R4.1 Website: /enterprise page — "nothing to breach" positioning, MDM guide link,
  whitepaper download, contact for Org-ID onboarding
R4.2 Store description enterprise note ("Organizations: mailin Enterprise is available
  via Apple Business Manager — contact us")
R4.3 Outreach kit: 1-page PDF from the whitepaper §5 validation table

## Owner actions (only Shirshendu can do)
- Release iOS 2.0 when approved; then 2.0.1 archives/uploads (guided, as before)
- Enroll EcoSanskriti Innovation Pvt Ltd in Apple Business Manager (D-U-N-S required)
- Set enterprise list price; sign first pilot customer and collect their Org ID
- Approve v3.0 store metadata + screenshots before submission

## Release gates (claims discipline)
- No store/website claim without a Present matrix row + executed check
- 3.0 What's New mentions PST export only as fixed in 2.0.1 (already true)
- Enterprise SKU review build must contain zero IAP UI (rejection risk)
