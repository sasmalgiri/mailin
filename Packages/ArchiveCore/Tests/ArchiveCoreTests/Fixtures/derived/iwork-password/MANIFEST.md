# iwork-password — password-protected iWork 2013+ documents and their unprotected twins

Made 2026-11-09 on macOS 27.0.1 with the owner's permission to drive the installed apps through
AppleScript. All content is synthetic; no other document was touched.

| App | Version (CFBundleShortVersionString / CFBundleVersion) |
|---|---|
| Pages | 14.4 / 7043.0.93 |
| Numbers | 14.4 / 7043.0.93 |
| Keynote | 14.4 / 7043.0.93 |

## How they were made

Each app's scripting dictionary (`sdef`) has `set password <text> to <document> hint <text>` (Pages,
Numbers and Keynote alike); `export … with properties {password: …}` exists only for non-native
formats. For every app the script made a new document, filled it, and for the protected variant ran
`set password "Lighthouse-4650" to d hint "synthetic fixture"` before `save d in POSIX file …`.
The unprotected twin is a separate document made the same way without `set password`.

- **Pages**: body text `Synthetic fixture for mailin. The quorum clause lighthouse stands at the harbour.`
- **Numbers**: table 1 of sheet 1: A1 `Harbour ledger`, B1 `Amount`, C1 `Date`; A2 `quorum clause lighthouse`,
  B2 `4650`, C2 the date 2026-03-14 (00:00 local).
- **Keynote**: slide 1 title `Quorum clause lighthouse`, presenter notes `Speaker note: the harbour count is 4650.`

AppleScript `save … in` always writes the single-file form (a ZIP with `Index/*.iwa` at its top). The
package (bundle) form was made for Pages only: File ▸ Advanced ▸ Change File Type ▸ Package (System
Events menu click), then saved through the Save panel; the plain twin is a package Pages autosaved with
the same text. The bundles were zipped as Mail attaches a package (`ditto -c -k --keepParent --norsrc`),
so `pages-bundle-*.pages` are ZIPs of `pages-bundle-*.pages/` holding `Index.zip`. Numbers/Keynote
bundles were not made (the Save-panel keystrokes are not safe to automate while other work uses the
screen).

Password: **`Lighthouse-4650`** (hint `synthetic fixture`) for every protected file.

## What the protected files hold

`.iwpv2` (104 bytes: version 2, format 1, 100,000 PBKDF2 iterations, salt, IV, verifier blob) and `.iwph`
(the hint) at the top of the file or bundle; every `Index/*.iwa` (and every `Data/` file) encrypted —
16 bytes, 16-byte IV, AES-128-CBC with PKCS#7 padding, 20 trailing bytes; `Metadata/` plain. See
`Sources/ArchiveCore/IWork13Encryption.swift`.

## SHA-256

```
d670c104a6e3e92635c62b58f58228a32798c8c539f73a6656cf62d43b257090  keynote-plain.key
725bb9c1053117bfc214c6b29d9430aba3913fe4836f95907f671973a3378349  keynote-protected.key
07173e7cb2c7433f05ef25f7076f7e3fd2af374e893444fad301507795dd432f  numbers-plain.numbers
ac4cd0a509399676754015c7d28d77198e3c8a8db9362697ccb11cff24154c72  numbers-protected.numbers
a533fc729f16f36a265c652c4b6180b0b79f14888453008aa4115de2f1b0ac6a  pages-bundle-plain.pages
e75259b5543d111bb19bbc41b553674e81459b37b899129021a3c597c1943c74  pages-bundle-protected.pages
0e02a42c0bc219c46c8e64119f929a8482c8cbdd33f2d1b4919da40bd97dfdf5  pages-plain.pages
1710a911a1ea570dacc82112e89a3a3d05c7687bd1683a2576e682723a69cf30  pages-protected.pages
```

Tests: `IWorkPasswordFixtureTests` (each protected file locked without a password, "the password did not
open the file" with a wrong one, and with the right one the same text and sections as its twin).
