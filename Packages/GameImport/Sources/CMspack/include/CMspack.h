// A callback-only seam over libmspack's cabinet decompressor. libmspack only decodes: the cabinet is read from
// disk, and every output byte goes to the caller's write callback, so OmniPlay validates names and owns every write.

#ifndef CMSPACK_H
#define CMSPACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct op_cab op_cab;

typedef struct {
    // Stored name with '\' turned into '/'; UTF-8 when `utf8`, otherwise ISO-8859-1 bytes as stored.
    const char *path;
    uint64_t size;
    int utf8;
} OPCabEntry;

// Returns 0 to go on, anything else to stop the extraction.
typedef int (*op_cab_write_fn)(void *context, const void *bytes, size_t count);

// Finds every cabinet in `path`: a .cab, or a self-extracting .exe with cabinets inside. NULL with `error` set to
// libmspack's error code when there is none.
op_cab *op_cab_open(const char *path, int *error);
int op_cab_count(const op_cab *cab);
// 0, or -1 for an index out of range.
int op_cab_entry(const op_cab *cab, int index, OPCabEntry *entry);
// Decodes file `index` through `write`. 0, or libmspack's error code (MSPACK_ERR_*).
int op_cab_extract(op_cab *cab, int index, op_cab_write_fn write, void *context);
void op_cab_close(op_cab *cab);

#ifdef __cplusplus
}
#endif

#endif
