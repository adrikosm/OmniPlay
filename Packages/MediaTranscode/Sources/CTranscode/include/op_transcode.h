// File-to-file media conversion for OmniPlay's media preparation, over FFmpeg (Native/prebuilt/ffmpeg, LGPL).
//
// Reads anything FFmpeg decodes and writes one of four shapes an engine plays:
//   MP4 H.264 + AAC      WebKit (VideoToolbox H.264, FFmpeg's AAC)
//   OGV Theora + Vorbis  mkxp-z and Ren'Py, whose own decoders read Theora and Vorbis
//   OGG Vorbis           audio for mkxp-z and Ren'Py
//   WAV PCM 16-bit       audio anything decodes
// One frame at a time: memory stays at a few decoded frames whatever the file's length. Metadata is copied, so an
// RPG Maker loop point (LOOPSTART / LOOPLENGTH) survives into the new file. The FFmpeg symbols come from static
// libraries the app links; this header exposes none of FFmpeg's types.

#ifndef OP_TRANSCODE_H
#define OP_TRANSCODE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    OP_TARGET_MP4_H264_AAC = 0,
    OP_TARGET_OGV_THEORA_VORBIS = 1,
    OP_TARGET_OGG_VORBIS = 2,
    OP_TARGET_WAV_PCM = 3,
} op_target;

typedef struct {
    op_target target;
    int max_width;      // 0: keep. Frames larger than the box are scaled down, keeping the aspect ratio.
    int max_height;
    int max_fps;        // 0: keep. Faster sources drop frames.
    int video_quality;  // Theora quality 0...10 (0: 7). H.264 target bit rate in bits per second (0: from size).
    int audio_quality;  // Vorbis quality 0...10 (0: 5). AAC bit rate in bits per second (0: 160000).
} op_transcode_spec;

// Called now and then with the fraction done; return nonzero to cancel.
typedef int (*op_progress)(void *context, double fraction);

// 0 on success, else a negative code with a message in `error` (NUL-terminated, at most `error_size` bytes). A
// cancelled run returns OP_TRANSCODE_CANCELLED. The output file may be partly written on failure; the caller removes
// it.
enum { OP_TRANSCODE_CANCELLED = -100000, OP_TRANSCODE_NOTHING = -100001 };
int op_transcode(const char *input, const char *output, const op_transcode_spec *spec, op_progress progress,
                 void *context, char *error, int error_size);

// Nonzero when a failure code says the same file will always fail (damaged, or no codec for it); anything else, such
// as a full disk or a lost hardware encoder, may pass on another try.
int op_transcode_permanent(int code);

#ifdef __cplusplus
}
#endif

#endif
