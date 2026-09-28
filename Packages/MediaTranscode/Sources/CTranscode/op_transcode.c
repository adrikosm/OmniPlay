#include "op_transcode.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    AVFormatContext *in, *out;
    int vin, ain;
    AVCodecContext *vdec, *adec, *venc, *aenc;
    AVStream *vst, *ast;
    struct SwsContext *sws;
    AVFrame *scaled, *decoded, *chunk;
    SwrContext *swr;
    AVAudioFifo *fifo;
    int64_t apts;
    int64_t last_index;
    double fps;
    double duration;
    double done;
    op_progress progress;
    void *context;
    int cancelled;
} job;

static int fail(char *error, int size, const char *what, int code) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = "";
    if (code < 0 && code != OP_TRANSCODE_NOTHING && code != OP_TRANSCODE_CANCELLED) av_strerror(code, reason, sizeof reason);
    if (error && size > 0) snprintf(error, (size_t)size, "%s%s%s", what, reason[0] ? ": " : "", reason);
    return code < 0 ? code : AVERROR_UNKNOWN;
}

// Every quarter second of media: progress (-1 when the length is unknown), and the caller's chance to cancel.
static int report(job *j, double seconds) {
    if (seconds >= j->done + 0.25) {
        j->done = seconds;
        double fraction = j->duration > 0 ? fmin(1.0, seconds / j->duration) : -1;
        if (j->progress && j->progress(j->context, fraction)) j->cancelled = 1;
    }
    return j->cancelled ? OP_TRANSCODE_CANCELLED : 0;
}

// Writes every packet the encoder has ready; `frame` NULL drains it.
static int encode(job *j, AVCodecContext *enc, AVStream *st, AVFrame *frame) {
    int rc = avcodec_send_frame(enc, frame);
    if (rc < 0 && rc != AVERROR_EOF) return rc;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return AVERROR(ENOMEM);
    for (;;) {
        rc = avcodec_receive_packet(enc, pkt);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) { rc = 0; break; }
        if (rc < 0) break;
        av_packet_rescale_ts(pkt, enc->time_base, st->time_base);
        pkt->stream_index = st->index;
        rc = av_interleaved_write_frame(j->out, pkt);
        if (rc < 0) break;
    }
    av_packet_free(&pkt);
    return rc;
}

static const void *first_config(AVCodecContext *ctx, const AVCodec *codec, enum AVCodecConfig which) {
    const void *configs = NULL;
    int count = 0;
    if (avcodec_get_supported_config(ctx, codec, which, 0, &configs, &count) < 0 || count == 0) return NULL;
    return configs;
}

static int open_video_encoder(job *j, const op_transcode_spec *spec, char *error, int size) {
    AVStream *in = j->in->streams[j->vin];
    const AVCodec *codec = spec->target == OP_TARGET_MP4_H264_AAC ? avcodec_find_encoder_by_name("h264_videotoolbox")
                                                                  : avcodec_find_encoder_by_name("libtheora");
    if (!codec) return fail(error, size, "no video encoder", AVERROR_ENCODER_NOT_FOUND);
    j->venc = avcodec_alloc_context3(codec);
    if (!j->venc) return AVERROR(ENOMEM);

    // Fit the box, keep the aspect ratio, even dimensions (4:2:0 chroma).
    int w = j->vdec->width, h = j->vdec->height;
    if (w <= 0 || h <= 0) return fail(error, size, "video has no size", AVERROR_INVALIDDATA);
    double scale = 1.0;
    if (spec->max_width > 0 && w > spec->max_width) scale = fmin(scale, (double)spec->max_width / w);
    if (spec->max_height > 0 && h > spec->max_height) scale = fmin(scale, (double)spec->max_height / h);
    j->venc->width = ((int)lrint(w * scale)) & ~1;
    j->venc->height = ((int)lrint(h * scale)) & ~1;
    if (j->venc->width < 2 || j->venc->height < 2) return fail(error, size, "video too small", AVERROR_INVALIDDATA);

    AVRational rate = av_guess_frame_rate(j->in, in, NULL);
    if (rate.num <= 0 || rate.den <= 0) rate = (AVRational){30, 1};
    if (spec->max_fps > 0 && av_q2d(rate) > spec->max_fps) rate = (AVRational){spec->max_fps, 1};
    j->fps = av_q2d(rate);
    j->venc->framerate = rate;
    j->venc->time_base = av_inv_q(rate);
    j->venc->pix_fmt = AV_PIX_FMT_YUV420P;
    j->venc->sample_aspect_ratio = j->vdec->sample_aspect_ratio;
    j->venc->gop_size = (int)fmax(1, lrint(j->fps * 2));
    if (spec->target == OP_TARGET_MP4_H264_AAC) {
        j->venc->bit_rate = spec->video_quality > 0 ? spec->video_quality
                                                    : (int64_t)fmax(1.5e6, fmin(12e6, j->venc->width * j->venc->height * j->fps * 0.12));
        j->venc->profile = AV_PROFILE_H264_HIGH;
        av_opt_set_int(j->venc->priv_data, "allow_sw", 1, 0);  // the simulator has no hardware encoder
    } else {
        int q = spec->video_quality > 0 ? spec->video_quality : 7;
        j->venc->flags |= AV_CODEC_FLAG_QSCALE;
        j->venc->global_quality = q * FF_QP2LAMBDA;
    }
    if (j->out->oformat->flags & AVFMT_GLOBALHEADER) j->venc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    int rc = avcodec_open2(j->venc, codec, NULL);
    if (rc < 0) return fail(error, size, "video encoder refused the settings", rc);

    j->vst = avformat_new_stream(j->out, NULL);
    if (!j->vst) return AVERROR(ENOMEM);
    j->vst->time_base = j->venc->time_base;
    j->vst->avg_frame_rate = rate;
    avcodec_parameters_from_context(j->vst->codecpar, j->venc);
    if (spec->target == OP_TARGET_MP4_H264_AAC) j->vst->codecpar->codec_tag = MKTAG('a', 'v', 'c', '1');

    j->scaled = av_frame_alloc();
    if (!j->scaled) return AVERROR(ENOMEM);
    j->scaled->format = j->venc->pix_fmt;
    j->scaled->width = j->venc->width;
    j->scaled->height = j->venc->height;
    rc = av_frame_get_buffer(j->scaled, 0);
    return rc < 0 ? fail(error, size, "no memory for a frame", rc) : 0;
}

static int open_audio_encoder(job *j, const op_transcode_spec *spec, char *error, int size) {
    const char *name = spec->target == OP_TARGET_MP4_H264_AAC ? "aac" : spec->target == OP_TARGET_WAV_PCM ? "pcm_s16le" : "libvorbis";
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    if (!codec) return fail(error, size, "no audio encoder", AVERROR_ENCODER_NOT_FOUND);
    j->aenc = avcodec_alloc_context3(codec);
    if (!j->aenc) return AVERROR(ENOMEM);

    int channels = j->adec->ch_layout.nb_channels;
    av_channel_layout_default(&j->aenc->ch_layout, channels >= 2 ? 2 : 1);
    const enum AVSampleFormat *formats = first_config(j->aenc, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT);
    j->aenc->sample_fmt = formats ? formats[0] : AV_SAMPLE_FMT_FLTP;
    int rate = j->adec->sample_rate > 0 ? j->adec->sample_rate : 44100;
    const int *rates = first_config(j->aenc, codec, AV_CODEC_CONFIG_SAMPLE_RATE);
    if (rates) {
        int best = rates[0];
        for (const int *r = rates; *r; r++) {
            if (*r == rate) { best = rate; break; }
            if (abs(*r - rate) < abs(best - rate)) best = *r;
        }
        rate = best;
    }
    j->aenc->sample_rate = rate;
    j->aenc->time_base = (AVRational){1, rate};
    if (spec->target == OP_TARGET_MP4_H264_AAC) {
        j->aenc->bit_rate = spec->audio_quality > 0 ? spec->audio_quality : 160000;
    } else if (spec->target != OP_TARGET_WAV_PCM) {
        int q = spec->audio_quality > 0 ? spec->audio_quality : 5;
        j->aenc->flags |= AV_CODEC_FLAG_QSCALE;
        j->aenc->global_quality = q * FF_QP2LAMBDA;
    }
    if (j->out->oformat->flags & AVFMT_GLOBALHEADER) j->aenc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    int rc = avcodec_open2(j->aenc, codec, NULL);
    if (rc < 0) return fail(error, size, "audio encoder refused the settings", rc);

    j->ast = avformat_new_stream(j->out, NULL);
    if (!j->ast) return AVERROR(ENOMEM);
    j->ast->time_base = j->aenc->time_base;
    avcodec_parameters_from_context(j->ast->codecpar, j->aenc);
    // Stream tags become the Vorbis comments: RPG Maker keeps its loop points there.
    av_dict_copy(&j->ast->metadata, j->in->metadata, 0);
    av_dict_copy(&j->ast->metadata, j->in->streams[j->ain]->metadata, 0);

    // Some files give a channel count and no order (a WAV without a mask); the resampler wants a layout.
    AVChannelLayout source = {0};
    if (j->adec->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_default(&source, FFMAX(1, channels));
    else av_channel_layout_copy(&source, &j->adec->ch_layout);
    rc = swr_alloc_set_opts2(&j->swr, &j->aenc->ch_layout, j->aenc->sample_fmt, j->aenc->sample_rate, &source,
                             j->adec->sample_fmt, j->adec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&source);
    if (rc < 0 || (rc = swr_init(j->swr)) < 0) return fail(error, size, "cannot convert this audio", rc);
    j->fifo = av_audio_fifo_alloc(j->aenc->sample_fmt, j->aenc->ch_layout.nb_channels, 4096);
    j->chunk = av_frame_alloc();
    return j->fifo && j->chunk ? 0 : AVERROR(ENOMEM);
}

static int open_decoder(job *j, int index, AVCodecContext **out) {
    AVStream *st = j->in->streams[index];
    // FFmpeg's own AV1 decoder only drives hardware; dav1d decodes AV1 anywhere.
    const AVCodec *codec = st->codecpar->codec_id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : NULL;
    if (!codec) codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->pkt_timebase = st->time_base;
    ctx->thread_count = 0;
    int rc = avcodec_open2(ctx, codec, NULL);
    if (rc < 0) { avcodec_free_context(&ctx); return rc; }
    *out = ctx;
    return 0;
}

// Audio frames go through the resampler into a FIFO, then out in the encoder's frame size; NULL flushes.
static int audio_frame(job *j, AVFrame *frame) {
    int rc;
    int want = frame ? swr_get_out_samples(j->swr, frame->nb_samples) : swr_get_out_samples(j->swr, 0);
    if (want > 0) {
        uint8_t **buffer = NULL;
        rc = av_samples_alloc_array_and_samples(&buffer, NULL, j->aenc->ch_layout.nb_channels, want, j->aenc->sample_fmt, 0);
        if (rc < 0) return rc;
        int got = swr_convert(j->swr, buffer, want, frame ? (const uint8_t **)frame->extended_data : NULL, frame ? frame->nb_samples : 0);
        if (got > 0) av_audio_fifo_write(j->fifo, (void **)buffer, got);
        av_freep(&buffer[0]);
        av_freep(&buffer);
        if (got < 0) return got;
    }
    int step = j->aenc->frame_size > 0 ? j->aenc->frame_size : 4096;
    while (av_audio_fifo_size(j->fifo) >= step || (!frame && av_audio_fifo_size(j->fifo) > 0)) {
        int n = FFMIN(step, av_audio_fifo_size(j->fifo));
        av_frame_unref(j->chunk);
        j->chunk->nb_samples = n;
        j->chunk->format = j->aenc->sample_fmt;
        j->chunk->sample_rate = j->aenc->sample_rate;
        av_channel_layout_copy(&j->chunk->ch_layout, &j->aenc->ch_layout);
        if ((rc = av_frame_get_buffer(j->chunk, 0)) < 0) return rc;
        av_audio_fifo_read(j->fifo, (void **)j->chunk->data, n);
        j->chunk->pts = j->apts;
        j->apts += n;
        if ((rc = encode(j, j->aenc, j->ast, j->chunk)) < 0) return rc;
    }
    return 0;
}

static int video_frame(job *j, AVFrame *frame) {
    int64_t ts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
    double seconds = ts != AV_NOPTS_VALUE ? ts * av_q2d(j->in->streams[j->vin]->time_base) : (j->last_index + 1) / j->fps;
    if (j->in->start_time != AV_NOPTS_VALUE) seconds -= j->in->start_time / (double)AV_TIME_BASE;
    int64_t index = llrint(fmax(0, seconds) * j->fps);
    if (index <= j->last_index) return 0;  // faster than the output rate: dropped
    j->sws = sws_getCachedContext(j->sws, frame->width, frame->height, frame->format, j->venc->width, j->venc->height,
                                  j->venc->pix_fmt, SWS_BICUBIC, NULL, NULL, NULL);
    if (!j->sws) return AVERROR(EINVAL);
    int rc = av_frame_make_writable(j->scaled);
    if (rc < 0) return rc;
    sws_scale(j->sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, j->scaled->data, j->scaled->linesize);
    j->scaled->pts = index;
    j->last_index = index;
    return encode(j, j->venc, j->vst, j->scaled);
}

static int drain_decoder(job *j, AVCodecContext *dec, int is_video) {
    int rc;
    for (;;) {
        rc = avcodec_receive_frame(dec, j->decoded);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) return 0;
        if (rc < 0) return rc;
        rc = is_video ? video_frame(j, j->decoded) : audio_frame(j, j->decoded);
        av_frame_unref(j->decoded);
        if (rc < 0) return rc;
    }
}

int op_transcode(const char *input, const char *output, const op_transcode_spec *spec, op_progress progress, void *context,
                 char *error, int error_size) {
    job jb = {0};
    job *j = &jb;
    j->vin = j->ain = -1;
    j->last_index = -1;
    j->progress = progress;
    j->context = context;
    int rc;
    const int wants_video = spec->target == OP_TARGET_MP4_H264_AAC || spec->target == OP_TARGET_OGV_THEORA_VORBIS;

    if ((rc = avformat_open_input(&j->in, input, NULL, NULL)) < 0) { rc = fail(error, error_size, "cannot open the file", rc); goto end; }
    if ((rc = avformat_find_stream_info(j->in, NULL)) < 0) { rc = fail(error, error_size, "cannot read the streams", rc); goto end; }
    j->duration = j->in->duration > 0 ? j->in->duration / (double)AV_TIME_BASE : 0;

    if (wants_video) {
        int v = av_find_best_stream(j->in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (v >= 0 && !(j->in->streams[v]->disposition & AV_DISPOSITION_ATTACHED_PIC)) j->vin = v;
    }
    int a = av_find_best_stream(j->in, AVMEDIA_TYPE_AUDIO, -1, j->vin, NULL, 0);
    if (a >= 0) j->ain = a;
    if (j->vin < 0 && j->ain < 0) { rc = fail(error, error_size, "no audio or video in the file", OP_TRANSCODE_NOTHING); goto end; }
    if (j->vin >= 0 && (rc = open_decoder(j, j->vin, &j->vdec)) < 0) { rc = fail(error, error_size, "cannot decode the video", rc); goto end; }
    if (j->ain >= 0 && (rc = open_decoder(j, j->ain, &j->adec)) < 0) { rc = fail(error, error_size, "cannot decode the audio", rc); goto end; }

    const char *container = spec->target == OP_TARGET_MP4_H264_AAC ? "mp4" : spec->target == OP_TARGET_WAV_PCM ? "wav" : "ogg";
    if ((rc = avformat_alloc_output_context2(&j->out, NULL, container, output)) < 0) { rc = fail(error, error_size, "cannot create the file", rc); goto end; }
    av_dict_copy(&j->out->metadata, j->in->metadata, 0);
    if (j->vin >= 0 && (rc = open_video_encoder(j, spec, error, error_size)) < 0) goto end;
    if (j->ain >= 0 && (rc = open_audio_encoder(j, spec, error, error_size)) < 0) goto end;
    if ((rc = avio_open(&j->out->pb, output, AVIO_FLAG_WRITE)) < 0) { rc = fail(error, error_size, "cannot write the file", rc); goto end; }
    AVDictionary *mux = NULL;
    if (spec->target == OP_TARGET_MP4_H264_AAC) av_dict_set(&mux, "movflags", "+faststart", 0);
    rc = avformat_write_header(j->out, &mux);
    av_dict_free(&mux);
    if (rc < 0) { rc = fail(error, error_size, "cannot start the file", rc); goto end; }

    j->decoded = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    if (!j->decoded || !pkt) { av_packet_free(&pkt); rc = AVERROR(ENOMEM); goto end; }
    while ((rc = av_read_frame(j->in, pkt)) >= 0) {
        AVCodecContext *dec = pkt->stream_index == j->vin ? j->vdec : pkt->stream_index == j->ain ? j->adec : NULL;
        if (dec) {
            if (pkt->pts != AV_NOPTS_VALUE) {
                double at = pkt->pts * av_q2d(j->in->streams[pkt->stream_index]->time_base);
                if (j->in->start_time != AV_NOPTS_VALUE) at -= j->in->start_time / (double)AV_TIME_BASE;
                if ((rc = report(j, at)) < 0) break;
            }
            rc = avcodec_send_packet(dec, pkt);
            // A damaged packet is skipped the way players skip it; the file still converts.
            if (rc >= 0 || rc == AVERROR_INVALIDDATA) rc = drain_decoder(j, dec, dec == j->vdec);
        }
        av_packet_unref(pkt);
        if (rc < 0) break;
    }
    av_packet_free(&pkt);
    if (rc == OP_TRANSCODE_CANCELLED) { rc = fail(error, error_size, "cancelled", rc); goto end; }
    if (rc < 0 && rc != AVERROR_EOF) { rc = fail(error, error_size, "conversion failed", rc); goto end; }

    // Flush: decoders, the resampler and FIFO, then the encoders.
    if (j->vdec) { avcodec_send_packet(j->vdec, NULL); if ((rc = drain_decoder(j, j->vdec, 1)) < 0) goto flushfail; }
    if (j->adec) { avcodec_send_packet(j->adec, NULL); if ((rc = drain_decoder(j, j->adec, 0)) < 0) goto flushfail; }
    if (j->aenc && (rc = audio_frame(j, NULL)) < 0) goto flushfail;
    if (j->venc && (rc = encode(j, j->venc, j->vst, NULL)) < 0) goto flushfail;
    if (j->aenc && (rc = encode(j, j->aenc, j->ast, NULL)) < 0) goto flushfail;
    if ((rc = av_write_trailer(j->out)) < 0) { rc = fail(error, error_size, "cannot finish the file", rc); goto end; }
    if (j->progress) j->progress(j->context, 1.0);
    rc = 0;
    goto end;
flushfail:
    rc = fail(error, error_size, "conversion failed at the end", rc);
end:
    if (j->out && !(j->out->oformat->flags & AVFMT_NOFILE)) avio_closep(&j->out->pb);
    avformat_free_context(j->out);
    avformat_close_input(&j->in);
    avcodec_free_context(&j->vdec);
    avcodec_free_context(&j->adec);
    avcodec_free_context(&j->venc);
    avcodec_free_context(&j->aenc);
    sws_freeContext(j->sws);
    swr_free(&j->swr);
    if (j->fifo) av_audio_fifo_free(j->fifo);
    av_frame_free(&j->scaled);
    av_frame_free(&j->decoded);
    av_frame_free(&j->chunk);
    return rc;
}
