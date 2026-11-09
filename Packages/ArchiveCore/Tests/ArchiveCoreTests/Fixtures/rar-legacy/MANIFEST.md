# RAR 1.5 / RAR 2.0 test fixtures (real archives from public test suites)

Owner decision 2026-11-09: the RAR 1.5 and RAR 2.0 decoders are verified only on real archives found in
public corpora — no self-made fixtures (modern `rar` cannot write these formats). Oracle: the CRC-32 that
the archiver wrote into each file header (checked by the extractor for every member), and for the four
junrar archives of the same WAV recording, byte equality with libarchive's decode of the RAR 2.9 archive
of that file (`BoatModernEnglish-regular-unpack30.rar`, CRC-32 0x82D2ED89, 56,464 bytes).

## junrar (https://github.com/junrar/junrar)

Downloaded 2026-11-09 from `src/test/resources/com/github/junrar/` at commit
`51ea7dc09262bd56cd191159acddea31bee65c5b` (master, 2026-11-03), raw files from
`https://raw.githubusercontent.com/junrar/junrar/master/<path>`. Repository licence: the UnRAR licence
(`LICENSE`: free use and redistribution of UnRAR-derived software, not for re-creating a RAR compressor).
The archives hold a recording of the word "boat" and a LICENSE.txt naming its licence:
"UofG Language Modules, CC BY-SA 4.0 <https://creativecommons.org/licenses/by-sa/4.0>, via Wikimedia
Commons" — used here as test data with that attribution. `-dos` / `-win` = written by the DOS and Windows
RAR 1.5x programs; `audio-text-unpack20` = RAR 2.x with multimedia (audio) compression.

| file (junrar path) | members (unpack version, method) | bytes | SHA-256 |
|---|---|---|---|
| BoatModernEnglish-regular-unpack15-dos.rar (`audio/`) | BOATMO~1.WAV (15, m5), LICENSE.TXT (15, m5) | 42948 | 9c1deb8e11baa6fa1658c453b26a128a8437cefcbdeef3f4bcc499f6f7720a98 |
| BoatModernEnglish-regular-unpack15-win.rar (`audio/`) | BoatModernEnglish.wav (15, m5), LICENSE.txt (15, m5) | 42964 | d60bb4720a49148d928728d70215b4f8a6b6ac68e838f09fa776d626eb0cbae6 |
| BoatModernEnglish-regular-unpack20.rar (`audio/`) | BoatModernEnglish.wav (20, m5), LICENSE.txt (20, stored) | 42774 | 3baa87e8e4f44628655d64954a03e79b28abf84261eba6b21e7244f27c104b79 |
| BoatModernEnglish-audio-text-unpack20.rar (`audio/`) | BoatModernEnglish.wav (20, m5, audio blocks), LICENSE.txt (20, stored) | 28125 | 4144b4063f2f7c997b28b0bf42dc16cdb42ec913f271eecc47cd07b71335396e |
| BoatModernEnglish-regular-unpack30.rar (`audio/`) | BoatModernEnglish.wav (29, m5), LICENSE.txt (29, stored) — the libarchive reference | 42230 | 0da83cdf9201e40d8a3e9359a3169988d31b6264eec3d346722477bac204c542 |
| v20-solid-negative-backref.rar (`solid/`) | f0 (20, m1), f1 (20, m1, solid) — junrar's hostile file (a back-reference before the start), CRC 0 | 112 | 72fbe3965d7c748fe6518e4776ce2dc2565038de9970bfe042ed02c1285650ed |

## rarfile (https://github.com/markokr/rarfile)

Downloaded 2026-11-09 from `test/files/` at commit `d2f7df6fc843dae356fd6b0a85971dc36fd6e757`
(master, 2026-08-23). Licence: ISC (Copyright (c) 2005-2026 Marko Kreen). rarfile's `.exp` files give
the expected listing (`rar15-comment.rar`: os=DOS ver=15, FILE1.TXT meth=3 crc=0xe27f07a9, archive and
file comments in the headers; `rar2-unix-owner.rar`: os=UNIX ver=20 meth=3 cmp=17 dec=4 crc=0x7e3265a8).

| file | members (unpack version, method) | bytes | SHA-256 |
|---|---|---|---|
| rar15-comment.rar | FILE1.TXT (15, m3), FILE2.TXT (15, stored); comments in the main and file headers | 210 | f81c66b8a2d424e74a8ba76cf265206173404c3504b8dae7da6a27cf58141057 |
| rar2-unix-owner.rar | file.txt (20, m3) | 643 | 899724d4ac341fee19567a23a4d3b08b35d69cca0d14a4d01a6e08a5869d2281 |

## Not found / not used

- A real **solid** RAR 1.5/2.0 archive with checkable content: none found (junrar's `rar14-solid.rar` is the
  RAR 1.4 format with its own signature, out of scope; `v20-solid-negative-backref.rar` is hostile, CRC 0).
  Solid RAR 1.5/2.0 members after the first are therefore refused by name, not decoded.
- RAR 1.5/2.0 **encryption** (junrar `rar15-password-*.rar`, `rar20-password-*.rar`; rarfile
  `rar202-comment-psw.rar`): not implemented (outside this task); refused by name.
- RAR 2.6 (unpack version 26, files over 2 GB): same algorithm as 20, no real file; decoded by the
  RAR 2.0 path.

## Sources read to understand the algorithms (nothing copied)

- UnRAR source 7.3.2 (`unrarsrc-7.3.2.tar.gz` from https://www.rarlab.com/rar_add.htm, SHA-256
  `f61a1160d6e2ebbda2ad353c8e82f62ab4312f97fde23c6c2c982d25e0014f99`): `unpack15.cpp`, `unpack20.cpp`,
  `unpack.cpp` (`MakeDecodeTables`, `UnpInitData`), `unpackinline.cpp` (`DecodeNumber`, `CopyString`),
  `getbits.hpp`, `compress.hpp`, `arcread.cpp` (RAR 1.5 header CRC over the fields before an in-header
  comment); for RAR 7.0: `unpack50.cpp` (`ReadTables`, distance slots), `unpack.cpp` (`Init`),
  `arcread.cpp` (RAR 5.0/7.0 compression information), `compress.hpp` (`DCB`/`DCX`).
- RARLAB, "RAR 5.0 archive format" technote (https://www.rarlab.com/technote.htm), compression
  information field incl. RAR 7.0 version 1.
- Not read: The Unarchiver/XADMaster, 7-Zip, junrar's Java decoders.
