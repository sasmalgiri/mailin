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

Latest completed run before the simulator hung:

| Action | Result |
|---|---|
| eDiscovery, Bates Numbering, Redaction, Review Batches, Investigation Report (Professional) | each opens its tool sheet |
| Free tier: Bates Numbering, Redaction, Production… | each shows the paywall |
| Free tier plan badge | "Free plan. Upgrade" |
| Production… (Professional) | not reached (end of the horizontal tool strip) |
| CSV and mbox export | **open question:** the menu is reached and "Spreadsheet (.csv)" tapped, but no pre-flight sheet appeared within 15 s; not yet known whether this is the app or the test |

On iPad, "Production…" opens the Bates Numbering sheet; the production window is Mac-only.

## Regression after the fixes

macOS: app suite 510 XCTest (12 skipped, 0 failures) + 184 Swift Testing passed; ArchiveCore 56 tests (3 skipped, 0 failures); macOS Release build succeeded.

## Still owner-side

App Store sandbox purchase and restore on TestFlight (both platforms), the signed Release archive, Mac hands-on testing (UI automation needs one Touch ID approval at the Mac).
