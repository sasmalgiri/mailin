# Selling mailin: private users and enterprises (decided 2026-10-11)

mailin is sold through **two channels from one code base**. Nothing in the product differs except how it is
paid for and who can install it.

| | Private users | Enterprises |
|---|---|---|
| App | **mailin** on the public App Store | **mailin Enterprise**, a Custom App in Apple Business Manager |
| Bundle ID | `com.ecosanskriti.mailin` | `com.ecosanskriti.mailin.enterprise` |
| Build | `Scripts/testflight.sh --build N --upload` | `Scripts/testflight.sh --build N --edition enterprise --upload` |
| Payment | In-app purchase through Apple (Free / Personal / Professional; monthly, yearly, lifetime) | You invoice the organization directly; the app is unlocked by a **signed license key** |
| Who can install | Anyone | Only organizations you add in App Store Connect |
| Apple's share | 15% (Small Business Program) or 30% | None on your invoice (the Custom App itself is free) |

## What you need to do — private users (public App Store)

1. **App Store Connect ▸ Agreements, Tax, and Banking**: the *Paid Apps* agreement active, bank and tax forms done
   (needed for any in-app purchase revenue).
2. **Enroll in the App Store Small Business Program** (15% instead of 30% on the first USD 1M per year).
3. **In-app purchases** — the six products already used by the app must exist and be "Ready to Submit":
   `mailin_personal`, `personal_monthly`, `personal_yearly_01`, `professional_monthly`, `professional_yearly`,
   `Professional_Lifetime`. Set prices, the subscription group, and localized names/descriptions.
4. Upload with `Scripts/testflight.sh --build <N> --upload`, test in TestFlight, then submit the version with the
   in-app purchases attached.

## What you need to do — enterprises (Custom App)

1. **Developer account ▸ Identifiers**: register the App ID `com.ecosanskriti.mailin.enterprise` (no extra
   capabilities are needed — the app uses no App Groups or iCloud).
2. **App Store Connect ▸ Apps ▸ +**: new app "mailin Enterprise" with that bundle ID (macOS and iOS).
3. **Pricing and Availability**: price **Free**; Distribution: **Private** (Custom App) — add each customer's
   **Organization ID** (the customer finds it in Apple Business Manager ▸ Preferences ▸ Enrollment
   Information). Customers you add can install; nobody else can see the app.
4. Upload with `Scripts/testflight.sh --build <N> --edition enterprise --upload` and submit for review (Custom
   Apps are reviewed like any app; the App Review note should explain that a license key is required for the
   Professional tools and include a test key — issue one with `--days 90`).
5. **Per customer** (each sale):
   1. Agree price and seats; invoice them directly.
   2. Issue the key: `swift Scripts/mailin-license.swift issue --org "Customer Name" --seats 25 --days 365 --id CUST-2026-01`
   3. Send the key. The customer either puts it in their MDM profile (managed app configuration key
      `licenseKey`, with the other keys in `ENTERPRISE_DEPLOYMENT.md`) or each user pastes it in **About mailin ▸
      Enter license key…**.
   4. In Apple Business Manager the customer takes free licenses of the Custom App and assigns them through MDM.
6. **Renewals**: issue a new key before the old one expires (same command, new `--days`); the old key keeps
   working until its date.

### The key pair — keep it safe

- `~/mailin-license-keys/mailin-license-private.key` signs every license. **Back it up offline** (an encrypted
  USB drive or a password manager). If it is lost you cannot issue new keys for the shipped app; if it leaks,
  anyone can.
- The public half is embedded in `maxmailin/EnterpriseLicense.swift`. Never run `keygen` again unless you mean to
  replace the key pair in a new app version — keys issued with the old pair would stop working.

### What a license does in the app

| State | What the user gets |
|---|---|
| Valid key | Everything (Professional) |
| Expired, within 30 days | Everything, with a "renew" warning in About |
| No key / expired over 30 days / invalid | The whole archive, search and exports (Personal); Professional tools wait for a key. **Nothing is ever locked away or deleted.** |

- Checked offline (Ed25519 signature) — no network, in line with the Private edition.
- Setting the device clock back does not revive an expired key.
- **Seats are printed on the license, not enforced** — an offline app cannot count installs. Enforce seats in the
  contract and through the customer's Apple Business Manager license count.

## Suggestions on pricing

- Private users: keep the current three tiers. Professional Lifetime is the anchor for solo lawyers and
  investigators; the yearly plan is the default.
- Enterprise: per-seat yearly (e.g. a 10-seat minimum), with a 30-day pilot key (`--days 30`) for evaluations.
  Larger customers will ask for the assurance pack (`ENTERPRISE_ASSURANCE_PACK.md`) and the security
  whitepaper — both exist.

# Third-party software compiled into the app (V4-14 check, 2026-11-12)

Checked for v4.0: `Packages/ArchiveCore/Package.swift` (targets and dependencies), the project's package
references (one local package, `Packages/ArchiveCore`; **no remote Swift packages**), and every vendored source
folder. The connected edition adds no third-party code: it uses Apple's AuthenticationServices, Network,
URLSession, Security (Keychain) and CryptoKit only.

| Component | Where | Licence | Notice shipped in the app | Licence file in the repo |
|---|---|---|---|---|
| libarchive 3.8.11 — RAR 1.5–4.x and RAR 5.0 readers and the read core they need | `Packages/ArchiveCore/Sources/CLibArchiveRAR/libarchive` (target `CLibArchiveRAR`) | BSD-2-Clause; `archive_blake2*` CC0 1.0 (chosen from CC0 / OpenSSL / Apache-2.0); `archive_ppmd7*` public domain | About ▸ Licenses ("Third-Party Notices") = `LegalComplianceManager.thirdPartyNotices` + `VendoredNotices.libarchive` (verbatim BSD-2 text, held to `COPYING` by a test) | `Packages/ArchiveCore/Sources/CLibArchiveRAR/COPYING` (upstream, verbatim); provenance and SHA-256s in `VENDORED.md`, `VENDORED-SHA256SUMS` |
| Apple frameworks (SwiftUI, Foundation, NaturalLanguage, FoundationModels, Vision, Speech, PDFKit, CryptoKit, StoreKit, AuthenticationServices, Network, Security, …) | system | Apple SDK licence | listed in Third-Party Notices | — |

Not compiled into the app (no notice needed): test fixtures under `maxmailinTests/Fixtures` and
`Packages/ArchiveCore/Tests/…/Fixtures` (their own licences sit beside them), `Scripts/*` (developer tools),
`ModelRunner.xcodeproj` references (not a target dependency). Format knowledge taken from public specifications or
read for understanding only (MS-PST, libpff / libpst / libnsfdb documentation, the Notes C API) is not copied code;
`NSFODSReader.swift` records that no libnsfdb (LGPL) code was copied.

Gaps found: **none** for v4.0. Re-run this check if any package, vendored folder or SDK (e.g. a crypto or IMAP
library) is added; a new component needs its licence file copied from its source and an entry in
`VendoredNotices.all`.
