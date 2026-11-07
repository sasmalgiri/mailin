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

Copied byte for byte from `libarchive-3.8.11/libarchive/` into `libarchive/` — per-file SHA-256 in
`VENDORED-SHA256SUMS` (compare with `shasum -a 256 -c` inside `libarchive/`):

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
  is the Swift side.
- `Package.swift` builds the target with `HAVE_CONFIG_H` and `-w`: upstream's own 64→32-bit
  shortening warnings are silenced for this target only, the code is not edited.

**No upstream file is modified.**

## What the vendored reader does not do (stated in FormatCapabilityRegistry, rows `rar` and `7z-rar-source`)

- RAR 1.5 and RAR 2.0 compression (unpack versions 15, 20, 26) — libarchive implements only the
  RAR 2.9–4.x algorithm; `RARReader.Member.compressionRefusal` names these members instead of letting
  the decoder produce wrong bytes.
- RAR 4 solid archives beyond their first member — libarchive 3.8.11 stops with "RAR solid archive
  support unavailable"; named per member.
- RAR 7.0 compression (algorithm version 1) and RAR 5.0 dictionaries over 64 MiB — named per member.
- Encrypted members and encrypted headers — mailin asks for no RAR password; they stay locked.

## Updating

1. Download the new release tarball, check its SHA-256 against the release's published digest.
2. Copy the same file list over `libarchive/`, regenerate `VENDORED-SHA256SUMS`, keep `config.h`
   (re-run `./configure` with the flags above and compare the macros the files test).
3. Run `xcrun swift test --filter LibArchiveRARTests` and the RAR rows of `ContainerReaderTests`.
4. Bump `RARReader.version` if decoding output changes.

## Attribution

The libarchive copyright notice and licence (`COPYING`) must accompany the app. The same text is
available to the app as `VendoredNotices.libarchive` (ArchiveCore) for its third-party notices screen.
