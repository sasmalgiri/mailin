# Third-party notices — mailin 3.0

## Ideas acknowledged (no code copied)

- **Bundled scripts** (`maxmailin/ScriptLibrary.swift`): the choice of several scripts — hash-list exclusion, IP / type / size / date / domain filters, hash columns, IP extraction — follows the public crawler-script samples Vound published for Intella under the MIT licence. mailin's scripts are written from scratch for mailin's own JavaScript API; no sample code is included. Should a sample ever be ported verbatim, its MIT licence text and copyright line go here with it.
- **PST reading and recovery** (`PSTSpecReader.swift`, `PSTParser.swift`): implemented from Microsoft's published [MS-PST] specification. libpff (LGPL) was used as a reading reference only; it is not linked or included.
- **Review Pack** and **carving templates** follow product ideas described publicly by Magnet AXIOM (Portable Case, carving) and Aid4Mail / Metaspike; no code or data from them is used.

## Test data (not shipped in the app)

- **ARC validation suite** — `Packages/ArchiveCore/Tests/ArchiveCoreTests/Fixtures/arc/` holds `arc-draft-validation-tests.yml` from [ValiMail/arc_test_suite](https://github.com/ValiMail/arc_test_suite) (MIT, © 2017 ValiMail Inc.; licence text in `LICENSE.txt` beside it) and a JSON conversion of it. Used only by `ARCOpenSuiteTests`.
- **Digital Corpora "filetypes1"** — `PST.zip` and `Tbird.zip` from [digitalcorpora.org](https://digitalcorpora.org) (published for research and testing, free to use). Not committed: `Scripts/fetch_open_fixtures.sh` downloads them. The expected counts in `Fixtures/real/` were produced by independent tools — `readpst` from libpst (GPL), run separately as a command-line tool and never linked or shipped, and a separate X-Mozilla-Status scan.
