# Open-source fixtures for the ArchiveCore package tests (downloaded 2026-11-07)

Real files written by Publisher, Visio, Project, Access and OneNote, taken from the test corpora of
three open-source projects. They are test data and are used here only to verify mailin's readers
(directive 2026-11-07 §6 "Other business formats"). Read by path from `#filePath`, not bundled.

| Folder | Source | Revision | Licence |
|---|---|---|---|
| `tika/` | https://github.com/apache/tika — `tika-parsers/tika-parsers-standard/tika-parsers-standard-modules/tika-parser-microsoft-module/src/test/resources/test-documents/` | `main` on 2026-11-07 | Apache-2.0 |
| `poi/` | https://github.com/apache/poi — `test-data/publisher/` (Publisher files and `Sample.txt`, the author's record of `Sample.pub`'s text), `test-data/diagram/` (binary Visio files, including the malformed `NegativeChunkLength.vsd` and `ShortChunk1.vsd`) | `trunk` on 2026-11-07 | Apache-2.0 |
| `mpxj/` | https://github.com/joniles/mpxj — `junit/data/` (Microsoft Project .mpp files: MPP8 `DurationTest8.mpp`, MPP9 `SubprojectA-9.mpp`, MPP12 `mpp12columns.mpp`, MPP14 `ResourceIdAndUniqueId-project2013-mpp14.mpp`) | `master` on 2026-11-07 | LGPL-2.1 (test data) |

## Files

| File | Written by | What the tests assert (from the upstream tests where they exist) |
|---|---|---|
| `tika/testPUBLISHER.pub` | Publisher (author Nick Burch) | text contains `0123456789` and `abcdef` (Tika `PublisherParserTest`) |
| `poi/Sample.pub`, `poi/Sample.txt` | Publisher | every line of `Sample.txt`; hyperlinks `http://poi.apache.org/`, `mailto:dev@poi.apache.org` |
| `poi/LinkAt10.pub` | Publisher | one hyperlink |
| `tika/testVISIO.vsd` | Visio 2003 (author Hogwarts) | `Some random text, on a page` (Tika `VisioParserTest`) |
| `poi/44594.vsd`, `poi/44501.vsd`, `poi/SimpleMacro.vsd` | Visio | opened and read; `NegativeChunkLength.vsd`, `ShortChunk1.vsd` are malformed files that must not trap |
| `tika/testPROJECT2003.mpp`, `tika/testPROJECT2007.mpp` | Project 2003 / 2007 (author Nevin Nollop) | summary title `The quick brown fox jumps over the lazy dog`; Tika reads only metadata from these |
| `mpxj/*.mpp` | Project 98 / 2000–2003 / 2007 / 2013 | task and resource names read; MPXJ's own tests compare against MSPDI, not reproduced here |
| `tika/testACCESS.mdb`, `tika/testAccess_V1997.mdb` | Access 2000–2003 (Jet 4) / Access 97 (Jet 3) | tables and rows read |
| `tika/testAccess2.accdb`, `tika/testAccess2_2000.mdb`, `tika/testAccess2_2002-2003.mdb` | Access 2007+ / 2000 / 2002–2003 | column `ShortTextField`, date 2015-06-24, memo text `over the bold italic dog`, Unicode `普林斯顿大学` (Tika `JackcessParserTest`) |
| `tika/testAccess2_encrypted.accdb` | Access 2010 (password `tika`) | reported locked, nothing read |
| `tika/testOneNote*.one`, `tika/test-tika-*.one` | OneNote 2010–2016, OneNote 2007, Office 365 | see `OneNoteReaderTests` (Tika `OneNoteParserTest` strings); `testOneNote-fuzz1..3.one` are fuzzer regressions that must not trap |

Nothing from an owner-private pack is in this folder.
