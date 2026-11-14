# Third-party notices — mailin 3.0

## Code compiled into the app

- **libarchive 3.8.11 — RAR 1.5–4.x and RAR 5.0 readers** (`Packages/ArchiveCore/Sources/CLibArchiveRAR/`,
  owner decision 2026-11-07, GAP-RAR). BSD-2-Clause; vendored unmodified, provenance and file list in
  `VENDORED.md`, licence in `COPYING` beside it. The RAR readers are © 2003-2007 Tim Kientzle,
  © 2011 Andres Mejia (RAR 1.5–4.x) and © 2018 Grzegorz Antoniak (RAR 5.0); PPMd var.H (Dmitry Shkarin,
  Igor Pavlov) is public domain; the BLAKE2 reference code (© 2012 Samuel Neves) is used under CC0 1.0.
  The notice the app must show is `VendoredNotices.libarchive` in ArchiveCore:

  > Copyright (c) 2003-2018 <author(s)>
  > All rights reserved.
  >
  > Redistribution and use in source and binary forms, with or without
  > modification, are permitted provided that the following conditions
  > are met:
  > 1. Redistributions of source code must retain the above copyright
  >    notice, this list of conditions and the following disclaimer
  >    in this position and unchanged.
  > 2. Redistributions in binary form must reproduce the above copyright
  >    notice, this list of conditions and the following disclaimer in the
  >    documentation and/or other materials provided with the distribution.
  >
  > THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
  > IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
  > OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
  > IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
  > INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
  > NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  > DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  > THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  > (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
  > THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Ideas acknowledged (no code copied)

- **Bundled scripts** (`maxmailin/ScriptLibrary.swift`): the choice of several scripts — hash-list exclusion, IP / type / size / date / domain filters, hash columns, IP extraction — follows the public crawler-script samples Vound published for Intella under the MIT licence. mailin's scripts are written from scratch for mailin's own JavaScript API; no sample code is included. Should a sample ever be ported verbatim, its MIT licence text and copyright line go here with it.
- **PST reading and recovery** (`PSTSpecReader.swift`, `PSTParser.swift`): implemented from Microsoft's published [MS-PST] specification. libpff (LGPL) was used as a reading reference only; it is not linked or included.
- **Review Pack** and **carving templates** follow product ideas described publicly by Magnet AXIOM (Portable Case, carving) and Aid4Mail / Metaspike; no code or data from them is used.

## Test data (not shipped in the app)

- **libarchive RAR fixtures** — `Packages/ArchiveCore/Tests/ArchiveCoreTests/Fixtures/libarchive-rar/`: WinRAR-written
  RAR 4 / RAR 5 archives uudecoded from libarchive 3.8.11's `libarchive/test/*.rar.uu` (BSD-2-Clause, as above;
  per-file source and SHA-256 in its `MANIFEST.md`). Used only by `LibArchiveRARTests`.

- **ARC validation suite** — `Packages/ArchiveCore/Tests/ArchiveCoreTests/Fixtures/arc/` holds `arc-draft-validation-tests.yml` from [ValiMail/arc_test_suite](https://github.com/ValiMail/arc_test_suite) (MIT, © 2017 ValiMail Inc.; licence text in `LICENSE.txt` beside it) and a JSON conversion of it. Used only by `ARCOpenSuiteTests`.
- **Digital Corpora "filetypes1"** — `PST.zip` and `Tbird.zip` from [digitalcorpora.org](https://digitalcorpora.org) (published for research and testing, free to use). Not committed: `Scripts/fetch_open_fixtures.sh` downloads them. The expected counts in `Fixtures/real/` were produced by independent tools — `readpst` from libpst (GPL), run separately as a command-line tool and never linked or shipped, and a separate X-Mozilla-Status scan.
