/*
 * mailin_rar.c — a small C surface over the vendored libarchive read core,
 * with only the RAR (1.5–4.x) and RAR5 format readers registered. No filter
 * (gzip, bzip2 …) and no other format is compiled in. See ../VENDORED.md.
 */
#include "mailin_rar.h"

#include <stdlib.h>
#include <string.h>

#include "libarchive/archive.h"
#include "libarchive/archive_entry.h"

struct mailin_rar {
    struct archive *archive;
    struct archive_entry *entry;
    int open_status;
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
