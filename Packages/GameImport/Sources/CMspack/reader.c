// libmspack behind CMspack.h. The cabinet is read with stdio; the single output "file" libmspack opens for writing
// is the caller's callback, never a path.

#include "CMspack.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mspack.h"

struct op_system {
    struct mspack_system sys;
    op_cab_write_fn write;
    void *context;
};

struct op_file {
    FILE *input;          // the cabinet, or NULL for the output sink
    op_cab_write_fn write;
    void *context;
};

static struct mspack_file *op_open(struct mspack_system *self, const char *name, int mode) {
    struct op_system *sys = (struct op_system *)self;
    struct op_file *file = calloc(1, sizeof *file);
    if (!file) return NULL;
    if (mode == MSPACK_SYS_OPEN_WRITE) {
        file->write = sys->write;
        file->context = sys->context;
        return (struct mspack_file *)file;
    }
    if (mode != MSPACK_SYS_OPEN_READ || !(file->input = fopen(name, "rb"))) {
        free(file);
        return NULL;
    }
    return (struct mspack_file *)file;
}

static void op_close(struct mspack_file *handle) {
    struct op_file *file = (struct op_file *)handle;
    if (file && file->input) fclose(file->input);
    free(file);
}

static int op_read(struct mspack_file *handle, void *buffer, int bytes) {
    struct op_file *file = (struct op_file *)handle;
    if (!file || !file->input || bytes < 0) return -1;
    size_t count = fread(buffer, 1, (size_t)bytes, file->input);
    return ferror(file->input) ? -1 : (int)count;
}

static int op_write(struct mspack_file *handle, void *buffer, int bytes) {
    struct op_file *file = (struct op_file *)handle;
    if (!file || !file->write || bytes < 0) return -1;
    return file->write(file->context, buffer, (size_t)bytes) == 0 ? bytes : -1;
}

static int op_seek(struct mspack_file *handle, off_t offset, int mode) {
    struct op_file *file = (struct op_file *)handle;
    if (!file || !file->input) return -1;
    int whence = mode == MSPACK_SYS_SEEK_START ? SEEK_SET : mode == MSPACK_SYS_SEEK_CUR ? SEEK_CUR : SEEK_END;
    return fseeko(file->input, offset, whence) == 0 ? 0 : -1;
}

static off_t op_tell(struct mspack_file *handle) {
    struct op_file *file = (struct op_file *)handle;
    return file && file->input ? ftello(file->input) : -1;
}

static void op_message(struct mspack_file *file, const char *format, ...) { (void)file; (void)format; }
static void *op_alloc(struct mspack_system *self, size_t bytes) { (void)self; return malloc(bytes); }
static void op_free(void *buffer) { free(buffer); }
static void op_copy(void *src, void *dest, size_t bytes) { memcpy(dest, src, bytes); }

struct op_cab {
    struct op_system system;
    struct mscab_decompressor *decompressor;
    struct mscabd_cabinet *cabinets;
    char *path;           // search() keeps using the name until close()
    struct mscabd_file **files;
    char **names;
    int count;
};

op_cab *op_cab_open(const char *path, int *error) {
    op_cab *cab = calloc(1, sizeof *cab);
    if (!cab) { if (error) *error = MSPACK_ERR_NOMEMORY; return NULL; }
    cab->system.sys = (struct mspack_system){op_open, op_close, op_read, op_write, op_seek, op_tell, op_message,
                                             op_alloc, op_free, op_copy, NULL};
    cab->decompressor = mspack_create_cab_decompressor(&cab->system.sys);
    if (!cab->decompressor) { if (error) *error = MSPACK_ERR_NOMEMORY; free(cab); return NULL; }
    if (!(cab->path = strdup(path))) { if (error) *error = MSPACK_ERR_NOMEMORY; op_cab_close(cab); return NULL; }
    cab->cabinets = cab->decompressor->search(cab->decompressor, cab->path);
    if (!cab->cabinets) {
        int code = cab->decompressor->last_error(cab->decompressor);
        if (error) *error = code ? code : MSPACK_ERR_SIGNATURE;
        op_cab_close(cab);
        return NULL;
    }
    for (struct mscabd_cabinet *c = cab->cabinets; c; c = c->next)
        for (struct mscabd_file *f = c->files; f; f = f->next) cab->count++;
    cab->files = calloc((size_t)cab->count + 1, sizeof *cab->files);
    cab->names = calloc((size_t)cab->count + 1, sizeof *cab->names);
    if (!cab->files || !cab->names) { if (error) *error = MSPACK_ERR_NOMEMORY; op_cab_close(cab); return NULL; }
    int i = 0;
    for (struct mscabd_cabinet *c = cab->cabinets; c; c = c->next)
        for (struct mscabd_file *f = c->files; f; f = f->next) {
            char *name = strdup(f->filename ? f->filename : "");
            if (!name) { if (error) *error = MSPACK_ERR_NOMEMORY; op_cab_close(cab); return NULL; }
            for (char *p = name; *p; p++) if (*p == '\\') *p = '/';
            cab->files[i] = f;
            cab->names[i++] = name;
        }
    return cab;
}

int op_cab_count(const op_cab *cab) { return cab ? cab->count : 0; }

int op_cab_entry(const op_cab *cab, int index, OPCabEntry *entry) {
    if (!cab || !entry || index < 0 || index >= cab->count) return -1;
    entry->path = cab->names[index];
    entry->size = cab->files[index]->length;
    entry->utf8 = (cab->files[index]->attribs & MSCAB_ATTRIB_UTF_NAME) != 0;
    return 0;
}

int op_cab_extract(op_cab *cab, int index, op_cab_write_fn write, void *context) {
    if (!cab || !write || index < 0 || index >= cab->count) return MSPACK_ERR_ARGS;
    cab->system.write = write;
    cab->system.context = context;
    int code = cab->decompressor->extract(cab->decompressor, cab->files[index], "omniplay-sink");
    cab->system.write = NULL;
    cab->system.context = NULL;
    return code;
}

void op_cab_close(op_cab *cab) {
    if (!cab) return;
    if (cab->names) for (int i = 0; i < cab->count; i++) free(cab->names[i]);
    free(cab->names);
    free(cab->files);
    if (cab->decompressor) {
        // close() on search()'s result frees the whole `next` chain; never on the chained cabinets themselves.
        if (cab->cabinets) cab->decompressor->close(cab->decompressor, cab->cabinets);
        mspack_destroy_cab_decompressor(cab->decompressor);
    }
    free(cab->path);
    free(cab);
}
