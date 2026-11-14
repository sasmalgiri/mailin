/*
 * config.h for mailin's vendored libarchive RAR reader (CLibArchiveRAR).
 *
 * Hand-reduced from the config.h that libarchive 3.8.11's ./configure wrote
 * on macOS with every optional library switched off:
 *   ./configure --without-zlib --without-bz2lib --without-libb2 --without-iconv
 *     --without-lz4 --without-zstd --without-lzma --without-cng --without-openssl
 *     --without-xml2 --without-expat --without-mbedtls --without-nettle
 *     --disable-acl --disable-xattr
 * Only the macros the vendored files actually test are kept. Every value
 * holds on macOS 14+ and iOS 17+ (64-bit Darwin, libSystem only): no zlib,
 * bzip2, lzma, iconv, OpenSSL, libxml2 or libb2 — CRC-32 and BLAKE2sp come
 * from libarchive's own archive_crc32.c / archive_blake2s*_ref.c.
 */
#ifndef MAILIN_LIBARCHIVE_RAR_CONFIG_H
#define MAILIN_LIBARCHIVE_RAR_CONFIG_H

#define HAVE_DECL_INT32_MAX 1
#define HAVE_DECL_INT32_MIN 1
#define HAVE_DECL_INT64_MAX 1
#define HAVE_DECL_INT64_MIN 1
#define HAVE_DECL_INTMAX_MAX 1
#define HAVE_DECL_INTMAX_MIN 1
#define HAVE_DECL_SIZE_MAX 1
#define HAVE_DECL_SSIZE_MAX 1
#define HAVE_DECL_UINT32_MAX 1
#define HAVE_DECL_UINT64_MAX 1
#define HAVE_DECL_UINTMAX_MAX 1
#define HAVE_EFTYPE 1
#define HAVE_EILSEQ 1
#define HAVE_ERRNO_H 1
#define HAVE_FCHMOD 1
#define HAVE_FCHOWN 1
#define HAVE_FCNTL_H 1
#define HAVE_FUTIMENS 1
#define HAVE_FUTIMES 1
#define HAVE_GETEGID 1
#define HAVE_GETEUID 1
#define HAVE_INTTYPES_H 1
#define HAVE_ISSETUGID 1
#define HAVE_LANGINFO_H 1
#define HAVE_LIMITS_H 1
#define HAVE_LOCALTIME_R 1
#define HAVE_MBRTOWC 1
#define HAVE_MKSTEMP 1
#define HAVE_NL_LANGINFO 1
#define HAVE_STDCKDINT_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_TIME_H 1
#define HAVE_UNISTD_H 1
#define HAVE_UTIMENSAT 1
#define HAVE_WCHAR_H 1
#define HAVE_WCRTOMB 1
#define HAVE_WCSLEN 1
#define HAVE_WCTOMB 1
#define HAVE_WMEMCMP 1
#define HAVE_WMEMCPY 1
#define HAVE_WMEMMOVE 1
#define SIZEOF_INT 4
#define SIZEOF_LONG 8

/* SwiftPM and Xcode define DEBUG=1 for Debug builds of C targets; the RAR 5.0
 * reader takes that as its own switch and printf()s every checksum to stdout.
 * Nothing in the vendored files needs it. */
#undef DEBUG

#endif
