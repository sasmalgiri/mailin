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

## The owner's TestFlight purchase checklist, simulated (2026-10-08)

UI tests `testPurchase1_buyMonthlyUnlocksFeatures`, `testPurchase2_reinstallThenRestore` and `testPurchase3_buyLifetime` (iPad Pro 13-inch simulator) tap through the real purchase screen. StoreKit runs locally from `maxmailin/Products.storekit` via `SKTestSession`. The app runs with the Debug switch `-mailinRealStore`: no Debug unlock and no simulated tier, so the tier comes only from verified StoreKit transactions, as in the App Store build. Runner: `Scripts/purchase-checklist-sim.sh`.

| Step | What happened |
|---|---|
| Fresh install | Plan badge "Free plan. Upgrade"; Redaction (a Personal tool) asks for a purchase |
| Buy monthly | Pressed "Buy Personal — $4.99 / month"; the purchase screen closed itself; badge "Current plan: Personal"; Redaction opens; Bates Numbering (Professional) still asks for a purchase |
| Reinstall | All the app's data wiped (1.9 MB → 4 KB); the store account still holds `personal_monthly`; the app came back as Personal on its own |
| Restore Purchases | "Restored: your Personal access is active on this device."; Redaction opens |
| Buy lifetime | Pressed "Buy Professional — $249.99 once"; the purchase screen closed; badge "Current plan: Professional · Lifetime"; Bates Numbering opens |

All three pass. An earlier run also bought Personal lifetime ($99.99, through a mis-tap in the test) and the app correctly showed "Personal · Lifetime".

Why "reinstall" is a data wipe rather than an uninstall: uninstalling under Xcode's local StoreKit also erases the app's test purchases (the store reported no transactions afterwards), unlike the real App Store, where purchases stay with the Apple Account. In that state Restore correctly reported "No eligible purchases were found".

Not covered: App Store Connect's product setup and a sandbox Apple Account. Those are checked with TestFlight build 3.0 (302), uploaded 2026-10-08.

## Apple sandbox, real servers (2026-10-08, afternoon)

Xcode build launched with `-mailinRealStore` (tier from StoreKit only), sandbox tester `sasmalgiri1@gmail.com`, owner confirming Apple's sheets. StoreKit's own log (`storekitagent`, "Initialized with server Sandbox") confirms the environment for each reading.

| Time | Apple's sandbox | mailin |
|---|---|---|
| 15:45 | Personal monthly bought | Personal; Redaction opens, Bates locked |
| 15:56 | Upgraded to Professional monthly | Professional; "Subscription · renews or ends 8 Oct 2026" |
| 16:39 | still active after ~8 five-minute renewals | Professional |
| 17:01 | subscription ended (12-renewal limit) | Free · Upgrade, all paid tools locked |
| 17:28 | Personal monthly bought again | Personal |
| 18:53 | ended | Free |

Restore Purchases while active once reported "Restore failed: Request Canceled" (Apple's sign-in prompt dismissed) — reported, not hidden; Restore verified on TestFlight (Professional Lifetime, owner's account). Family Sharing is on for all six products and cannot be turned off (Apple rule); single-user products would need new product IDs.

Harness lesson: creating an `SKTestSession` inside a Mac UI test left storekitagent pointing the app at Xcode's local test store ("XcodeTest") for every later launch; readings between 16:05 and 16:31 were from that store and are discarded. Cleared by Product ▸ Run from Xcode with StoreKit Configuration = None. The Mac sandbox tests no longer create a session. `StoreManager.checkEntitlements` now logs tier/lifetime/expiry (subsystem com.ecosanskriti.mailin, category purchases) so a renewal can be read from the log.

Not shown on screen: the renewal time ticking forward — the app shows a date only, and every sandbox renewal falls on the same day. Covered by the 9/9 StoreKit test suite and by the ~60-minute survival of each subscription above.
