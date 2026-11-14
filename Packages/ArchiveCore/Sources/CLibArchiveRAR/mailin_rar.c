/*
 * mailin_rar.c — a small C surface over the vendored libarchive read core,
 * with only the RAR (1.5–4.x) and RAR5 format readers registered. No filter
 * (gzip, bzip2 …) and no other format is compiled in. See ../VENDORED.md.
 */
#include "mailin_rar.h"

#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "libarchive/archive.h"
#include "libarchive/archive_entry.h"
#include "libarchive/archive_blake2.h"

struct mailin_rar {
    struct archive *archive;
    struct archive_entry *entry;
    int open_status;
    /* mailin_rar_open_reader: the caller's stream. */
    void *reader_context;
    mailin_rar_read_fn reader_read;
    mailin_rar_skip_fn reader_skip;
};

static int map_status(int r) {
    if (r == ARCHIVE_OK || r == ARCHIVE_WARN) return MAILIN_RAR_OK;
    if (r == ARCHIVE_EOF) return MAILIN_RAR_EOF;
    if (r == ARCHIVE_FATAL) return MAILIN_RAR_FATAL;
    return MAILIN_RAR_ERROR;
}

mailin_rar *mailin_rar_open(const char *const *paths, int count) {
    mailin_rar *rar = calloc(1, sizeof *rar);
    if (rar == NULL) return NULL;
    rar->archive = archive_read_new();
    if (rar->archive == NULL) { free(rar); return NULL; }
    archive_read_support_format_rar(rar->archive);
    archive_read_support_format_rar5(rar->archive);
    if (paths == NULL || count <= 0) {
        rar->open_status = MAILIN_RAR_FATAL;
        return rar;
    }
    /* archive_read_open_filenames wants a NULL-terminated list. */
    const char **list = calloc((size_t)count + 1, sizeof *list);
    if (list == NULL) { archive_read_free(rar->archive); free(rar); return NULL; }
    for (int i = 0; i < count; i++) list[i] = paths[i];
    int r = archive_read_open_filenames(rar->archive, list, 64 * 1024);
    free(list);
    rar->open_status = map_status(r);
    return rar;
}

static la_ssize_t reader_read_trampoline(struct archive *a, void *client, const void **buffer) {
    (void)a;
    mailin_rar *rar = client;
    long n = rar->reader_read(rar->reader_context, buffer);
    if (n < 0) {
        archive_set_error(rar->archive, EIO, "the decrypted RAR stream could not be read");
        return ARCHIVE_FATAL;
    }
    return (la_ssize_t)n;
}

static la_int64_t reader_skip_trampoline(struct archive *a, void *client, la_int64_t request) {
    (void)a;
    mailin_rar *rar = client;
    if (rar->reader_skip == NULL || request <= 0) return 0;
    int64_t n = rar->reader_skip(rar->reader_context, (int64_t)request);
    return n < 0 ? 0 : (la_int64_t)n;
}

mailin_rar *mailin_rar_open_reader(void *context, mailin_rar_read_fn read, mailin_rar_skip_fn skip) {
    mailin_rar *rar = calloc(1, sizeof *rar);
    if (rar == NULL) return NULL;
    rar->archive = archive_read_new();
    if (rar->archive == NULL) { free(rar); return NULL; }
    archive_read_support_format_rar(rar->archive);
    archive_read_support_format_rar5(rar->archive);
    rar->reader_context = context;
    rar->reader_read = read;
    rar->reader_skip = skip;
    if (read == NULL) {
        rar->open_status = MAILIN_RAR_FATAL;
        return rar;
    }
    archive_read_set_read_callback(rar->archive, reader_read_trampoline);
    archive_read_set_skip_callback(rar->archive, reader_skip_trampoline);
    archive_read_set_callback_data(rar->archive, rar);
    rar->open_status = map_status(archive_read_open1(rar->archive));
    return rar;
}

int mailin_rar_open_status(const mailin_rar *rar) {
    return rar == NULL ? MAILIN_RAR_FATAL : rar->open_status;
}

int mailin_rar_next(mailin_rar *rar) {
    if (rar == NULL || rar->open_status != MAILIN_RAR_OK) return MAILIN_RAR_FATAL;
    rar->entry = NULL;
    struct archive_entry *entry = NULL;
    int r = archive_read_next_header(rar->archive, &entry);
    int status = map_status(r);
    if (status == MAILIN_RAR_OK) rar->entry = entry;
    return status;
}

const char *mailin_rar_entry_name(mailin_rar *rar) {
    if (rar == NULL || rar->entry == NULL) return NULL;
    return archive_entry_pathname_utf8(rar->entry);
}

int64_t mailin_rar_entry_size(mailin_rar *rar) {
    if (rar == NULL || rar->entry == NULL || !archive_entry_size_is_set(rar->entry)) return -1;
    return (int64_t)archive_entry_size(rar->entry);
}

int mailin_rar_entry_is_directory(mailin_rar *rar) {
    if (rar == NULL || rar->entry == NULL) return 0;
    return archive_entry_filetype(rar->entry) == AE_IFDIR;
}

int mailin_rar_entry_is_encrypted(mailin_rar *rar) {
    if (rar == NULL || rar->entry == NULL) return 0;
    return archive_entry_is_encrypted(rar->entry) ? 1 : 0;
}

long mailin_rar_read(mailin_rar *rar, void *buffer, size_t length) {
    if (rar == NULL || rar->entry == NULL) return MAILIN_RAR_FATAL;
    la_ssize_t n = archive_read_data(rar->archive, buffer, length);
    if (n >= 0) return (long)n;
    return n == ARCHIVE_FATAL ? MAILIN_RAR_FATAL : MAILIN_RAR_ERROR;
}

const char *mailin_rar_error(mailin_rar *rar) {
    if (rar == NULL || rar->archive == NULL) return "out of memory";
    const char *message = archive_error_string(rar->archive);
    return message == NULL ? "" : message;
}

void mailin_rar_close(mailin_rar *rar) {
    if (rar == NULL) return;
    if (rar->archive != NULL) archive_read_free(rar->archive);
    free(rar);
}

const char *mailin_rar_libarchive_version(void) {
    return archive_version_string();
}

void *mailin_blake2sp_new(void) {
    blake2sp_state *state = calloc(1, sizeof *state);
    if (state != NULL && blake2sp_init(state, 32) != 0) { free(state); return NULL; }
    return state;
}

void mailin_blake2sp_update(void *state, const void *bytes, size_t length) {
    if (state != NULL && length > 0) blake2sp_update((blake2sp_state *)state, bytes, length);
}

void mailin_blake2sp_final(void *state, uint8_t digest[32]) {
    if (state == NULL) return;
    blake2sp_final((blake2sp_state *)state, digest, 32);
    free(state);
}
