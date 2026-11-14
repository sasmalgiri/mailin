# CLibArchiveRAR — vendored libarchive RAR reader

Owner decision 2026-11-07 (tracker row GAP-RAR): compressed RAR members are decoded with
libarchive's RAR 1.5–4.x and RAR 5.0 readers, vendored here as a C target of the ArchiveCore
package. Nothing is downloaded or linked at run time; the code is compiled into the app.

## Source

| | |
|---|---|
| Project | libarchive — https://www.libarchive.org, https://github.com/libarchive/libarchive |
| Version | 3.8.11 (latest release on 2026-11-07) |
| Tarball | https://github.com/libarchive/libarchive/releases/download/v3.8.11/libarchive-3.8.11.tar.gz |
| SHA-256 | `900fe9fc7237c2b04f090f3c3648de8fe597525771f5035016537ce2d667d12b` — equal to the `digest` GitHub publishes for the release asset (checked 2026-11-07). The detached PGP signature (`.tar.gz.asc`) was downloaded but not checked: no `gpg` on the development Mac. |
| Licence | BSD-2-Clause (`COPYING`, kept verbatim beside this file). `archive_blake2*.{c,h}` are CC0 / OpenSSL / Apache-2.0 at the user's choice (CC0 taken); `archive_ppmd7*` is Igor Pavlov's public-domain PPMd var.H code. |

## Files

Copied byte for byte from `libarchive-3.8.11/libarchive/` into `libarchive/` — except
`archive_read_support_format_rar.c` and `archive_read_support_format_rar5.c`, which carry the two mailin
patches below — per-file SHA-256 in `VENDORED-SHA256SUMS` (compare with `shasum -a 256 -c` inside
`libarchive/`; the lines for the patched files are the patched files' hashes):

- format readers: `archive_read_support_format_rar.c` (RAR 1.5–4.x, incl. its PPMd7 model use and the
  RAR 3 VM filters), `archive_read_support_format_rar5.c` (RAR 5.0, incl. the x86/ARM/delta filters)
- codecs and checks: `archive_ppmd7.c`, `archive_crc32.c`, `archive_blake2s_ref.c`, `archive_blake2sp_ref.c`
- the read core they need: `archive_read.c`, `archive_read_open_filename.c`, `archive_check_magic.c`,
  `archive_virtual.c`, `archive_util.c`, `archive_string.c`, `archive_string_sprintf.c`, `archive_time.c`,
  `archive_entry.c`, `archive_acl.c`, `archive_entry_sparse.c`, `archive_entry_xattr.c`
- headers: `archive.h`, `archive_entry.h`, `archive_platform.h`, `archive_private.h`, `archive_read_private.h`,
  `archive_entry_private.h`, `archive_entry_locale.h`, `archive_string.h`, `archive_string_composition.h`,
  `archive_endian.h`, `archive_integer.h`, `archive_acl_private.h`, `archive_ppmd_private.h`,
  `archive_ppmd7_private.h`, `archive_blake2.h`, `archive_blake2_impl.h`, `archive_platform_stat.h`,
  `archive_random_private.h`, `archive_time_private.h`

No other format reader, no filter (gzip, bzip2, xz …), no writer and no disk-extraction code is
included. Only `archive_read_support_format_rar` and `archive_read_support_format_rar5` are registered.

## Local additions (not upstream)

- `libarchive/config.h` — written for this target: the subset of the macros the files above test, taken
  from what libarchive's `./configure` wrote on macOS with every optional library off
  (`--without-zlib --without-bz2lib --without-libb2 --without-iconv --without-lz4 --without-zstd
  --without-lzma --without-cng --without-openssl --without-xml2 --without-expat --without-mbedtls
  --without-nettle --disable-acl --disable-xattr`). Valid for macOS 14+ and iOS 17+ (64-bit Darwin).
  Only libSystem is used: no zlib, bzip2, lzma, iconv, OpenSSL, libxml2 or libb2.
- `mailin_rar.c` and `include/mailin_rar.h` — the C surface ArchiveCore calls (open a file or a volume
  set by path, step through entries, read an entry's data, report the error). `RARDecompressor.swift`
  is the Swift side. Audit R6 added `mailin_rar_open_reader` (libarchive reads a stream mailin supplies:
  the decrypted view of an encrypted archive, `RARDecryptedArchive.swift`) and `mailin_blake2sp_*`
  (the vendored BLAKE2sp, for RAR 5.0 checksums keyed to the password). libarchive itself still
  decrypts nothing; decryption is mailin's (`RARCrypto.swift`, CommonCrypto/CryptoKit).
- `Package.swift` builds the target with `HAVE_CONFIG_H` and `-w`: upstream's own 64→32-bit
  shortening warnings are silenced for this target only (no edit beyond the patch below).

## Patch (audit R6, 2026-11-09): `patches/rar4-solid.patch`

libarchive 3.8.11 refuses every RAR 1.5–4.x member flagged solid after the first ("RAR solid archive
support unavailable"). `patches/rar4-solid.patch` (apply with `patch -p1` inside this folder to the
pristine `archive_read_support_format_rar.c`, SHA-256
`c9afc9af8b2f537f1ecaee4ce521208562b3c37aa103f7d87e8e656e2150ab88`; result
`4b981d084ee6be70848754477809be95d6e11bffc070b90c07ec53d49793a520`) makes the reader continue the solid
stream the way unrar's `Unpack29(Solid=true)` does:

- a member with `FHD_SOLID` in an archive with `MHD_SOLID` keeps the LZSS window and its position, the
  Huffman tables (and whether new ones follow, as the previous member's end-of-file code said), the
  PPMd model, the repeat distances and the filter programs; a new bit stream starts at its packed data;
  pending filter blocks are dropped;
- output is counted from the member's own start (`solid_base`): the end-of-member test, the offset
  handed back at the end (otherwise `archive_read_data` pads the gap with zeros) and the file position
  given to the E8/E8E9 filters;
- a solid archive's window is the largest RAR 3 dictionary (4 MiB) from its first table and is never
  reallocated or cleared later;
- reaching the end of a member no longer resets the tables and the PPMd model in a solid archive;
- skipping a compressed member of a solid archive decodes it (output discarded), so a later member can
  be read; a member that fails to decode marks the stream broken and the members after it fail with
  "an earlier member of the RAR solid stream could not be decoded" instead of producing wrong bytes.

Verified on libarchive's only RAR 4 solid file (`test_read_format_rar4_solid_encrypted.rar`, through
mailin's decryption, and its decrypted form read straight from disk): every member's bytes and WinRAR's
CRC-32, in order and out of order. When updating libarchive, re-apply the patch (or drop it if upstream
has gained RAR 4 solid support) and re-run `LibArchiveRARTests`.

## Patch (owner decision 2026-11-09): `patches/rar7.patch`

libarchive 3.8.11 ignores the RAR 5.0 header's compression version and refuses every dictionary over
64 MiB. RAR 7.0 (rarlab.com/technote.htm, "Compression information") is the RAR 5.0 format with
version 1: a 5-bit dictionary exponent plus a 1/32 fraction (dictionaries up to 1 TB, not only powers
of two), bit 0x100000 meaning "version 1 header, version 0 algorithm", and — in the algorithm — 80
distance codes instead of 64, so distances can pass 4 GiB. `patches/rar7.patch` (apply with
`patch -p1` inside this folder to the pristine `archive_read_support_format_rar5.c`, SHA-256
`0a21cc37ef7ae0f83bbffdac1b08414380787ddf1cddae7b8539985e4b28e3ab`; result
`b42b517b1ec34707819b239642ca178f271c8df622434fc5769702e5a282d7b2`):

- reads the version 1 dictionary field (exponent and fraction) and the compatibility bit; refuses
  compression versions above 1 by name;
- reads 80 distance codes for version 1 data (the Huffman table and the distance slots 64–79, whose
  33/34 extra bits are read in two steps) and keeps distances and the repeat-distance cache 64-bit;
- sizes the window to the data instead of the declared dictionary: the smallest power of two of at
  least 8 MiB that holds every byte the stream can have produced by the end of the member (in a solid
  archive the members before it count), at most the declared dictionary rounded up to a power of two.
  A distance never reaches further back than the data produced, so nothing is lost; a 5 GiB
  dictionary on a 174 KB member allocates 8 MiB. mailin applies the same rule before decoding
  (`RARReader.assignDecoderWindows`) and refuses, by name, a member whose window would exceed
  `RARReader.maxDecoderWindowBytes` (a quarter of the device's memory, at most 4 GiB);
- a solid stream's window grows member by member (never shrinks) — the old "same window size"
  check is replaced by moving the window's bytes to where the larger mask expects them;
- the filters' window positions are 64-bit (windows over 4 GiB);
- the window-sized `filtered_buf` allocated at the start of every file is dropped (`run_filter`
  allocates the block's own size before each use), halving the memory.

Verified on archives written by rar 7.23 (Fixtures/rar7/MANIFEST.md): version 1 with 5 GiB and
4.5 GiB dictionaries, a version 1 member followed by version 0 members in one solid stream, a solid
three-volume version 1 set, encrypted data and encrypted headers — every member's CRC-32 and the
SHA-256 of the generated text; with the 80-code table switched off the version 1 members fail. No
fixture holds a match over 4 GiB back (it would need more than 4 GiB of data), so the 33/34-bit
distance path is exercised by no file.

## What the vendored reader does not do (stated in FormatCapabilityRegistry, rows `rar` and `7z-rar-source`)

- RAR 1.5 and RAR 2.0 compression (unpack versions 15, 20, 26) — libarchive implements only the
  RAR 2.9–4.x algorithm; these members are decoded by mailin's own Swift decoder
  (`ArchiveCore/RARLegacyDecoder.swift`, not part of this target), never by libarchive.
- RAR 5.0/7.0 members whose unpacked size the header does not record (written from a pipe into
  volumes) — libarchive refuses them; named per member.
- A decoding window over `RARReader.maxDecoderWindowBytes` — named per member.
- Decryption — done by mailin (`RARCrypto.swift`, `RARDecryptedArchive.swift`) with the password given
  through Unlock…; libarchive reads the decrypted view. RAR 1.5/2.0 encryption is not implemented and
  is named per member.

## Updating

1. Download the new release tarball, check its SHA-256 against the release's published digest.
2. Copy the same file list over `libarchive/`, re-apply `patches/rar4-solid.patch` and `patches/rar7.patch`, regenerate
   `VENDORED-SHA256SUMS`, keep `config.h`
   (re-run `./configure` with the flags above and compare the macros the files test).
3. Run `xcrun swift test --filter LibArchiveRARTests`, `--filter RAR7AndLegacyRARTests` and the RAR rows of `ContainerReaderTests`.
4. Bump `RARReader.version` if decoding output changes.

## Attribution

The libarchive copyright notice and licence (`COPYING`) must accompany the app. The same text is
available to the app as `VendoredNotices.libarchive` (ArchiveCore) for its third-party notices screen.
