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
