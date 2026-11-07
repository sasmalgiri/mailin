/*
 * mailin_rar.h — the only interface ArchiveCore sees of the vendored
 * libarchive RAR 1.5–4.x / RAR 5.0 reader (see ../VENDORED.md).
 *
 * One handle is one sequential read of a RAR file or of a multi-volume set
 * (the volumes in order). Entries come in archive order; an entry's data is
 * read in chunks. libarchive checks every header CRC and, at the end of each
 * entry's data, the file's CRC-32 (RAR 1.5–4.x, RAR 5.0) or BLAKE2sp (RAR 5.0);
 * a mismatch comes back as an error from mailin_rar_read.
 *
 * Not thread-safe: one handle is used by one thread at a time.
 */
#ifndef MAILIN_RAR_H
#define MAILIN_RAR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mailin_rar mailin_rar;

/* Status codes. */
enum {
    MAILIN_RAR_OK = 0,      /* an entry is ready / the call succeeded */
    MAILIN_RAR_EOF = 1,     /* no more entries */
    MAILIN_RAR_ERROR = -1,  /* failed; mailin_rar_error says why; the handle may still be usable */
    MAILIN_RAR_FATAL = -2   /* failed; the handle can only be closed */
};

/* Opens `count` volume paths (one for a single archive). Returns NULL only
 * when memory runs out; otherwise check mailin_rar_open_status. */
mailin_rar *mailin_rar_open(const char *const *paths, int count);
int mailin_rar_open_status(const mailin_rar *rar);

/* Advances to the next entry: MAILIN_RAR_OK, MAILIN_RAR_EOF or an error. */
int mailin_rar_next(mailin_rar *rar);

/* The current entry. The name is UTF-8 or NULL when libarchive could not
 * convert it (valid until the next mailin_rar_next). Size is -1 when unknown. */
const char *mailin_rar_entry_name(mailin_rar *rar);
int64_t mailin_rar_entry_size(mailin_rar *rar);
int mailin_rar_entry_is_directory(mailin_rar *rar);
int mailin_rar_entry_is_encrypted(mailin_rar *rar);

/* Up to `length` bytes of the current entry's data: > 0 bytes read, 0 at the
 * end of the entry (its checksum verified), < 0 an error (MAILIN_RAR_ERROR /
 * MAILIN_RAR_FATAL). */
long mailin_rar_read(mailin_rar *rar, void *buffer, size_t length);

/* The last error, or "" — valid until the next call on the handle. */
const char *mailin_rar_error(mailin_rar *rar);

void mailin_rar_close(mailin_rar *rar);

/* "libarchive 3.8.11" */
const char *mailin_rar_libarchive_version(void);

#ifdef __cplusplus
}
#endif

#endif
