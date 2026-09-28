#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct OPRar OPRar;
typedef int (*OPRarWrite)(void *context, const void *bytes, size_t count);
typedef struct {
    const char *path;
    uint64_t size;
    uint64_t packedSize;
    uint32_t dictionaryKiB;
    int kind; /* 0 regular, 1 directory, 2 link/device */
    int encrypted;
    int splitBefore;
} OPRarEntry;
/* Serializes UnRAR's process-global error handler until close. Never writes files. */
OPRar *op_rar_open(const char *path, const char *password, int *error);
int op_rar_next(OPRar *reader, OPRarEntry *entry);
int op_rar_process(OPRar *reader, int skip, OPRarWrite write, void *context);
const char *op_rar_missing_volume(OPRar *reader);
void op_rar_close(OPRar *reader);
#ifdef __cplusplus
}
#endif
