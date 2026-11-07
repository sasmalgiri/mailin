# Open-source fixtures (downloaded 2026-11-07)

Real files written by Outlook, Word, Excel, PowerPoint, Visio, Project and Exchange, taken from the
test corpora of two Apache projects. Both are licensed under the Apache License 2.0; the files are
test data and are used here only to verify mailin's readers.

| Folder | Source | Revision | Licence |
|---|---|---|---|
| `tika/` | https://github.com/apache/tika — `tika-parsers/tika-parsers-standard/tika-parsers-standard-modules/{tika-parser-microsoft-module,tika-parser-pdf-module,tika-parser-mail-module}/src/test/resources/test-documents/` | `main` on 2026-11-07 | Apache-2.0 |
| `poi/` | https://github.com/apache/poi — `test-data/hsmf/` (Outlook messages), `test-data/poifs/` (encrypted Office files) | `trunk` on 2026-11-07 | Apache-2.0 |
| `mpxj/` | https://github.com/joniles/mpxj — `junit/data/` (Microsoft Project MSPDI XML) | `master` on 2026-11-07 | LGPL-2.1 (test data) |

Known passwords: Tika's `*_protected_passtika.*` files open with `tika`; POI's `extenxls_pwd123.xlsx`
with `pwd123`; the rest are probed by `testREAL_openSourceFixtures_*`, which records which opened.

## `public-pack/` — the owner's pack of 2026-11-07 (`Mailin_Public_Test_Fixtures_2026-11-07.zip`)

| Part | Source | Licence / reuse |
|---|---|---|
| `02_archives/public/` | libarchive test fixtures (commit eb57ffe), uudecoded; passwords `password` (WinZip AES zips) and `12345678` (7z) | BSD (COPYING in `licenses/`) |
| `02_archives/7zip_generated/` | made for mailin with official 7-Zip 26.05; password `mailin-fixture-2026`; README carries `MAILIN-PROTECTED-CONTENT-20261107` and `nested/W05_tracked_retained.docx` | generated for mailin tests |
| `03_word/` | InterTechSA/docx-edit-trail-analyser `samples/word_native` (Word for Microsoft 365, build 16.0.20326.20072): W05 keeps two insertions (`red`, ` `) and one deletion (`brown `) | MIT (in `licenses/`) |
| `04_import_ready_eml/` | synthetic transport envelopes around the files above (the attachment bytes are unchanged) | generated for mailin tests |
| **not in the repo** | `01_outlook/Set_Up_Mobile_Thru_Admin.oft` (Microsoft Download Center id 44066, SHA-256 `ca98181d…dbe1c`) and its wrapper `01_Set_Up_Mobile_Thru_Admin.eml` live in `~/Downloads/Mail/Fixtures/public-pack/`; the test skips that part when they are absent | Microsoft material — not redistributed |

`expected_results.json` is the oracle the test reads (attachment hashes, archive members, revisions).
