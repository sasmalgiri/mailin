# mailin / maxmailin 2.0 — Release Checklist

Status as of 2026-08-11. Engineering is complete and green (full unit suite +
macOS click-through + iOS Simulator build). Everything below is **owner-side**
work that can only be done on your hardware / accounts — it is NOT code.

App identity (already set — verify, don't change unless noted):
- Version (`MARKETING_VERSION`): **2.0.0**
- Build (`CURRENT_PROJECT_VERSION`): **200**
- Bundle id: **com.ecosanskriti.mailin**
- Deployment targets: iOS 17.6 / macOS 14.6
- Signing: Automatic, team 6TPTCJD42Q

---

## 1. Data safety — the one that can hurt real users
- [ ] **v1 → v11 migration rehearsal on a real device.** Install the *current
      App Store 1.0*, use it enough to create real data (imports, tags,
      annotations, reviews), then upgrade in place to this 2.0 build.
- [ ] Confirm: no rows lost, tags/annotations/review state intact, audit chain
      still verifies, `PRAGMA user_version` = 11, app opens without the
      "refuses to open (newer schema)" guard firing.
- [ ] Test the migration on the **largest** archive you can (scale + memory).

## 2. Money — the paywall has never really run
- [ ] Build in **Release** (Debug hardcodes `isPremium/isProfessional = true`,
      so the paywall is invisible until Release).
- [ ] In **App Store Connect**, create the app record and the **in-app-purchase
      products** with IDs matching `StoreManager.allProductIDs`. A local
      `Products.storekit` file is NOT a substitute.
- [ ] Sandbox-test: purchase each tier, **restore purchases**, and confirm gated
      features unlock/lock correctly (personal vs professional).
- [ ] Confirm free-tier limits behave (paging gate, locked destinations show
      the lock badge and route to the paywall).

## 3. Device smoke
- [ ] macOS Release build: launch, import, run one workflow per persona to
      "Executed", print a Stakeholder Summary, open Work Center → Documents.
- [ ] Physical **iPhone** (not simulator): launch, import, run a workflow,
      verify tool windows present as sheets and nothing is clipped.
- [ ] Apple Intelligence paths degrade gracefully on a device without it
      (NL search + AI clean-up fall back, no crash).

## 4. Privacy & entitlements
- [ ] `PrivacyInfo.xcprivacy` present in the shipping target (it is — verify it
      declares the right API-usage reasons).
- [ ] Confirm the **offline promise**: no unexpected network egress in Release
      (the differentiator). Any online feature stays behind an explicit toggle.
- [ ] App Store privacy **nutrition labels** filled in to match (data not
      collected / stays on device).

## 5. Store assets & submission
- [ ] App icon complete for all sizes (macOS + iOS).
- [ ] Screenshots for each required device class.
- [ ] Description, keywords, support URL, marketing copy.
- [ ] TestFlight build uploaded; internal test pass.
- [ ] Submit for review.

## 6. Git / release hygiene
- [ ] `main` is up to date with the shipping commit (see branch note below).
- [ ] Tag the release commit `v2.0.0`.
- [ ] PR #4 is already merged; ensure no later fixes are stranded on
      `v2-core-cutover` only.

---

### Notes
- **Highest risk items are §1 and §2.** Everything else is process; those two
  are the only ones that can cause data loss or broken revenue, and both are
  invisible in the automated tests because Debug masks the paywall and the CI
  never upgrades over a real 1.0 database.
- Do **not** merge/ship until §1 passes on a real device.
