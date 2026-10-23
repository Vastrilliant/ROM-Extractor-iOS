#include "ios_shim.h"
#include <sys/stat.h>

#include <stdio.h>
#include <string.h>
#include <stdarg.h>

#include "types.h"
#include "filepath.h"

#include "ConvertUTF.h"

#ifdef _WIN32
#include <wchar.h>
#endif

void os_strcpy(oschar_t *dst, const char *src) {
#ifdef _WIN32
    if (src == NULL) return;

    const UTF8 *sourceStart = (const UTF8 *)src;
    UTF16 *targetStart = (UTF16 *)dst;
    uint32_t src_len, dst_len;
    src_len = strlen(src);
    dst_len = src_len + 1;
    const UTF8 *sourceEnd = (const UTF8 *)(src + src_len);
    UTF16 *targetEnd = (UTF16 *)(dst + dst_len);

    if (ConvertUTF8toUTF16(&sourceStart, sourceEnd, &targetStart, targetEnd, 0) != conversionOK) {
        fprintf(stderr, "Failed to convert %s to UTF-16!\n", src);
        exit(EXIT_FAILURE);
    }
#else
    strcpy(dst, src);
#endif
}

int os_makedir(const oschar_t *dir) {
#ifdef _WIN32
    return _wmkdir(dir);
#else
    return mkdir(dir, 0777);
#endif
}

int os_rmdir(const oschar_t *dir) {
#ifdef _WIN32
    return _wrmdir(dir);
#else
    return remove(dir);
#endif
}

static void filepath_update(filepath_t *fpath) {
    memset(fpath->os_path, 0, MAX_PATH * sizeof(oschar_t));
    os_strcpy(fpath->os_path, fpath->char_path);
}

void filepath_init(filepath_t *fpath) {
    fpath->valid = VALIDITY_INVALID;
}

void filepath_copy(filepath_t *fpath, filepath_t *copy) {
    if (copy != NULL && copy->valid == VALIDITY_VALID)
        memcpy(fpath, copy, sizeof(filepath_t));
    else
        memset(fpath, 0, sizeof(filepath_t));
}

void filepath_append(filepath_t *fpath, const char *format, ...) {
    char tmppath[MAX_PATH];
    va_list args;

    if (fpath->valid == VALIDITY_INVALID)
        return;

    memset(tmppath, 0, MAX_PATH);

    va_start(args, format);
    vsnprintf(tmppath, sizeof(tmppath), format, args);
    va_end(args);

    strcat(fpath->char_path, OS_PATH_SEPARATOR);
    strcat(fpath->char_path, tmppath);
    filepath_update(fpath);
}

void filepath_append_bytes_n(filepath_t *fpath, const char *bytes, uint32_t n) {
    if (fpath->valid == VALIDITY_INVALID) return;
    if (bytes == NULL || n > MAX_PATH || memchr(bytes, '\0', n) != NULL ||
        memchr(bytes, '/', n) != NULL || memchr(bytes, '\\', n) != NULL ||
        (n == 1 && bytes[0] == '.') || (n == 2 && bytes[0] == '.' && bytes[1] == '.')) {
        fpath->valid = VALIDITY_INVALID;
        memset(fpath->os_path, 0, sizeof(fpath->os_path));
        return;
    }

    size_t current_length = strnlen(fpath->char_path, sizeof(fpath->char_path));
    size_t separator_length = strlen(OS_PATH_SEPARATOR);
    if (current_length >= sizeof(fpath->char_path) ||
        current_length + separator_length + n >= sizeof(fpath->char_path)) {
        fpath->valid = VALIDITY_INVALID;
        memset(fpath->os_path, 0, sizeof(fpath->os_path));
        return;
    }

    memcpy(fpath->char_path + current_length, OS_PATH_SEPARATOR, separator_length);
    current_length += separator_length;
    memcpy(fpath->char_path + current_length, bytes, n);
    current_length += n;
    fpath->char_path[current_length] = '\0';
    filepath_update(fpath);
}

void filepath_append_n(filepath_t *fpath, uint32_t n, const char *format, ...) {
    char tmppath[MAX_PATH];
    va_list args;

    if (fpath->valid == VALIDITY_INVALID || format == NULL) return;
    if (strcmp(format, "%s") == 0) {
        va_start(args, format);
        const char *value = va_arg(args, const char *);
        va_end(args);
        filepath_append_bytes_n(fpath, value, n);
        return;
    }

    memset(tmppath, 0, sizeof(tmppath));
    va_start(args, format);
    vsnprintf(tmppath, sizeof(tmppath), format, args);
    va_end(args);
    size_t formatted_length = strnlen(tmppath, sizeof(tmppath));
    if (n > formatted_length) n = (uint32_t)formatted_length;
    filepath_append_bytes_n(fpath, tmppath, n);
}

void filepath_set(filepath_t *fpath, const char *path) {
    if (strlen(path) < MAX_PATH) {
        fpath->valid = VALIDITY_VALID;
        memset(fpath->char_path, 0, MAX_PATH);
        strncpy(fpath->char_path, path, MAX_PATH);
        filepath_update(fpath);
    } else {
        fpath->valid = VALIDITY_INVALID;
    }
}

void filepath_set_format(filepath_t *fpath, const char *format, ...) {
    va_list args;

    if (fpath->valid == VALIDITY_INVALID)
        return;

    memset(fpath->char_path, 0, MAX_PATH);

    va_start(args, format);
    vsnprintf(fpath->char_path, MAX_PATH, format, args);
    va_end(args);

    filepath_update(fpath);
}

oschar_t *filepath_get(filepath_t *fpath) {
    if (fpath->valid == VALIDITY_INVALID)
        return NULL;
    else
        return fpath->os_path;
}
