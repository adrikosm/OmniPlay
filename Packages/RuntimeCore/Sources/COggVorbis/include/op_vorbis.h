// Ogg Vorbis to PCM, for games whose audio WebKit cannot decode. WebKit on iOS plays Vorbis inside WebM video but
// neither <audio> nor WebAudio decodes it in an Ogg file, and that is how RPG Maker MV ships every sound.
//
// The decoder is libvorbisfile, which the app already links for mkxp-z; this file only declares the call. Input is
// untrusted game content: every read is bounded by `size`, and the sink can stop the decode.

#ifndef OP_VORBIS_H
#define OP_VORBIS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Receives interleaved signed 16-bit little-endian PCM; return nonzero to stop.
typedef int (*op_vorbis_sink)(void *context, const void *pcm, size_t bytes);

// 0 on success. -1: not an Ogg Vorbis stream. -2: damaged stream. -3: the sink stopped. -4: the stream changes
// channel count or sample rate part way (a chained file the caller would mangle).
int op_vorbis_decode(const unsigned char *data, size_t size, op_vorbis_sink sink, void *context, int *rate, int *channels);

#ifdef __cplusplus
}
#endif

#endif
