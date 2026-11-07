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
| `poi/44501.vsd` (Visio 2000), `poi/44594.vsd`, `poi/SimpleMacro.vsd` (Visio 2003) | Visio | `Penible`, `Nouveau farine`; `Drag the side handles to change the width of the text block.`; `This is a macro vector graphics drawing` (no VBA storage despite the name) |
| `poi/NegativeChunkLength.vsd`, `poi/ShortChunk1.vsd` | Visio 2003, damaged | POI regression files: text still read (`Feldbreite einstellen, um Absatzbreite festzulegen.`, `Betätigung des`), the over-long chunk recorded by position, no trap |
| `tika/testPROJECT2003.mpp`, `tika/testPROJECT2007.mpp` | Project 2003 (MPP9) / 2007 (MPP12), author Nevin Nollop | title `The quick brown fox jumps over the lazy dog`, subject `Gym class featuring a brown fox and lazy dog`, keywords `Pangram, fox, dog`, comments `Comment Vulpes vulpes comment`, company `CompanyA`, manager `Mr Burns`, category `Category1` (Tika `ProjectParserTest`); tasks `Aquire fox` / `Obtain Dog` / `Fox does his jump`, resources `Fox` / `Dog` (Tika reads no body text from these) |
| `mpxj/mpp12columns.mpp` (MPP12), `mpxj/ResourceIdAndUniqueId-project2013-mpp14.mpp` (MPP14), `mpxj/SubprojectA-9.mpp` (saved as MPP14) | Project 2007 / 2013 | `Task One` + `Resource One`; summary task `ResourceIdAndUniqueId`, resources `Resource One/Two/Three` with IDs 11–13; `Subproject Task A/A1/A2`, author `Wade Golden` |
| `mpxj/legacy/readpassword9.mpp`, `bothpassword9.mpp`, `writepassword9.mpp` (kept flat in `mpxj/`) | Project 2003 with a read / both / write-reservation password | read password → reported locked, nothing read; write reservation → blocks decoded with the file's code (`Task One`) and said so |
| `mpxj/DurationTest8.mpp` | Project 98 (MPP8) | recognised; properties (`Jon Iles`) read; tasks honestly reported as not read |
| `tika/testACCESS.mdb`, `tika/testAccess_V1997.mdb` | Access 2000–2003 (Jet 4) / Access 97 (Jet 3) | tables and rows read |
| `tika/testAccess2.accdb`, `tika/testAccess2_2000.mdb`, `tika/testAccess2_2002-2003.mdb` | Access 2007+ / 2000 / 2002–2003 | column `ShortTextField`, date 2015-06-24, memo text `over the bold italic dog`, Unicode `普林斯顿大学` (Tika `JackcessParserTest`) |
| `tika/testAccess2_encrypted.accdb` | Access 2010 (password `tika`) | reported locked, nothing read |
| `tika/testOneNote1.one`, `testOneNote2.one`, `testOneNote3.one`, `testOneNote4.one` | OneNote 2013 (MS-ONESTORE) | Doc2: `wow this is neat`, `neat info about totally killin it bro`, `Section1TextArea1`, `Section1HeaderTitle`, `Section1TextArea2`; Doc3: `awesome information about sports or some crap like that.`, `Quit doing horrible things to me. Dang you.`, `Section2*`; Doc4: `way too much information about poptarts to handle.`, `Section3*`; no `Calibri` or garbage UTF-16 in any (Tika `OneNoteParserTest`) |
| `tika/testOneNote2016.one` | OneNote 2016 | `So good`, `This is one note 2016` |
| `tika/test-tika-4303-Chinese-notes.one` | OneNote 2016 | `中文标题` (TIKA-4303) |
| `tika/testOneNoteFromOffice365.one`, `testOneNoteFromOffice365-2.one`, `testOneNoteTablesLists.one` | Office 365 (FSSHTTPB packaging) | `Section1Page1Content`, `Section1Page2Content`; table cells `Table cell 1a` … `Table cell 4b`, list items `Bullet 2`, `Indented bullet`, `Number 2`, `Letter a`, `Numeral I`, `Outdented number` |
| `tika/testOneNote2007OrEarlier.one` | OneNote 2007 (packaging GUID, no readable revision store) | the long "One note is the application…" paragraph and `Correlation between Outlook and OneNote` |
| `tika/testOneNoteEmbeddedWordDoc.one` | OneNote 2013 | the embedded Word file is listed as not text |
| `tika/testOneNote.one`, `tika/testOneNote-fuzz1..3.one` | OneNote 2010; fuzzer regressions | fuzz files must not trap; fuzz1/fuzz2 report their damage |
| `../derived/testOneNote.onepkg` (+ `make_onepkg.py`) | built here from `testOneNote2.one` + `testOneNote3.one` | cabinet with one MSZIP folder in 15 blocks (byte-identical members), a stored `.onetoc2` stub, an LZX folder named and not opened |

Nothing from an owner-private pack is in this folder.
