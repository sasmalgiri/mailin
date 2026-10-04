# Purchases, restore and core actions — 2026-10-04

## Purchase flows (StoreKit 2, local StoreKit test environment)

Suite `StoreKitPurchaseFlowTests` in `maxmailinTests/ModuleGatingTests.swift`, run on the iPad Pro 13-inch simulator. Each test drives real StoreKit 2 calls through `SKTestSession` with `maxmailin/Products.storekit` (the six product IDs the app ships with), and the app's own `StoreManager` decides the tier from `Transaction.currentEntitlements` with the Debug all-unlocked shortcut switched off — the code path the App Store build takes.

| Test | Result |
|---|---|
| Fresh install is Free; six products load; exports capped at 500 | pass |
| Buy Personal yearly → Personal (not Professional), renewal date set | pass |
| Upgrade to Professional lifetime → Professional, lifetime, no renewal date | pass |
| Refund (revocation) → back to Free | pass |
| Cancelled subscription lapses on its own at period end, app left running | pass (≈30 s at accelerated StoreKit time) |
| Expired subscription grants nothing once the app is next active | pass |
| Ask to Buy: pending unlocks nothing; approval unlocks via the listener | pass |
| Restore Purchases on a new install finds the purchase; with none says so | pass |

8/8 passed in four consecutive runs (latest xcresult: `Test-maxmailin-2026.10.04_08-45-40`).

Two defects found and fixed in `StoreManager`:

1. **A subscription that lapsed while the app stayed open kept paid access** until the app was next activated (expiry is not a transaction update). The app now schedules an entitlement re-check at the latest expiry date.
2. **An expired subscription still listed by StoreKit could grant access.** Transactions whose expiry has passed are now skipped.

Not covered here: the App Store sandbox, an Apple Account sign-in, and the purchase confirmation sheet. Those need TestFlight. The suite is iOS-only; on macOS `Product.purchase()` needs a window to anchor its sheet and the hosted test runner has none.

## Core actions the button crawl missed (iPad, `testCoreActions_exportAndProfessionalTools`)

Passed on the iPad Pro 13-inch simulator, 2026-10-04 (190 s), archive of 534 emails (Sent.mbox + demo).

| Action | Result |
|---|---|
| CSV export (Professional) | pre-flight "534 emails as CSV spreadsheet · about 10.1 MB needed" ▸ Start ▸ receipt shown |
| mbox export (Professional) | pre-flight "534 emails as mbox archive · about 171.4 MB needed" ▸ Start ▸ receipt shown |
| eDiscovery, Bates Numbering, Redaction, Review Batches, Investigation Report | each opens its tool sheet |
| Production… | opens (on iPad this is the Bates Numbering sheet; the production window is Mac-only) |
| Free plan badge | "Free plan. Upgrade" |
| Free: Bates Numbering, Redaction, Production… | each shows the paywall |
| Free CSV export | pre-flight "500 emails as CSV spreadsheet — free tier writes the first 500" ▸ receipt "Exported 500 of 534 emails. Personal and Professional export without the 500-email limit." |

The Free run uses the Debug build with the tier set to Free (`-mailinSimulateTier free`); the gates are the same code the Release build runs, but a signed Release build has not been driven through them.

Earlier "pre-flight did not appear" results were a test defect (iOS does not expose the Start button's identifier inside the sheet), and earlier interrupted runs were the test harness: the background build shared a process group with a tool call that timed out. Both are fixed.

## Regression after the fixes

macOS: app suite 510 XCTest (12 skipped, 0 failures) + 184 Swift Testing passed; ArchiveCore 56 tests (3 skipped, 0 failures); macOS Release build succeeded.

## Still owner-side

App Store sandbox purchase and restore on TestFlight (both platforms), the signed Release archive, Mac hands-on testing (UI automation needs one Touch ID approval at the Mac).
