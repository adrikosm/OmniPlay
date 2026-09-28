#include "op_vorbis.h"

#include <string.h>
#include <vorbis/vorbisfile.h>

typedef struct {
    const unsigned char *data;
    size_t size;
    size_t pos;
} memory_source;

static size_t memory_read(void *out, size_t size, size_t count, void *source) {
    memory_source *m = source;
    size_t want = size * count, left = m->size - m->pos;
    if (want > left) want = left;
    memcpy(out, m->data + m->pos, want);
    m->pos += want;
    return size ? want / size : 0;
}

static int memory_seek(void *source, ogg_int64_t offset, int whence) {
    memory_source *m = source;
    ogg_int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (ogg_int64_t)m->pos : (ogg_int64_t)m->size;
    ogg_int64_t target = base + offset;
    if (target < 0 || target > (ogg_int64_t)m->size) return -1;
    m->pos = (size_t)target;
    return 0;
}

static long memory_tell(void *source) { return (long)((memory_source *)source)->pos; }

int op_vorbis_decode(const unsigned char *data, size_t size, op_vorbis_sink sink, void *context, int *rate, int *channels) {
    memory_source source = {data, size, 0};
    ov_callbacks callbacks = {memory_read, memory_seek, NULL, memory_tell};
    OggVorbis_File file;
    if (ov_open_callbacks(&source, &file, NULL, 0, callbacks) != 0) return -1;
    vorbis_info *info = ov_info(&file, -1);
    *rate = (int)info->rate;
    *channels = info->channels;
    char buffer[16384];
    int result = 0, section = 0;
    for (;;) {
        long n = ov_read(&file, buffer, sizeof buffer, 0, 2, 1, &section);
        if (n == 0) break;
        if (n == OV_HOLE) continue;  // a gap in the stream; libvorbisfile resynchronises
        if (n < 0) { result = -2; break; }
        vorbis_info *now = ov_info(&file, section);
        if (!now || now->channels != *channels || (int)now->rate != *rate) { result = -4; break; }
        if (sink(context, buffer, (size_t)n) != 0) { result = -3; break; }
    }
    ov_clear(&file);
    return result;
}
