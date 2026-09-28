#!/usr/bin/env python3
"""Generates the media format corpus the engine probes play: every video, audio and image format a game is likely
to ship, small enough to run all of them in one session.

Needs ffmpeg (with libx264, libx265, libvpx, libsvtav1, libopus, libmp3lame), ImageMagick, cwebp and heif-enc from
Homebrew. Two encoders are missing there: Theora, and a production Vorbis encoder (ffmpeg's own "vorbis" is
experimental and writes files some decoders reject). Pass existing files instead: --theora for a Theora/Vorbis .ogv
(a public Big Buck Bunny trailer works) and --vorbis for libvorbis .ogg files (Ren'Py's SDK ships several); their
first seconds are copied. Output is local only (Fixtures/private is gitignored).

Usage: make-media-corpus.py [--out DIR] [--theora any.ogv] [--vorbis a.ogg --vorbis b.ogg ...]
"""

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys

SECONDS = 4
VIDEO_SRC = [
    "-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=30:duration={SECONDS}",
    "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=44100:duration={SECONDS}",
]
AUDIO_SRC = ["-f", "lavfi", "-i", f"sine=frequency=330:sample_rate=44100:duration={SECONDS}", "-ac", "2"]

# name, extension, ffmpeg output arguments. Names say what is inside, so a failure reads as a format.
VIDEOS = [
    ("h264-aac", "mp4", ["-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"]),
    ("h264-baseline-aac", "mp4", ["-c:v", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("h264-mp3", "mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "libmp3lame"]),
    ("h264-aac-moov-at-end", "mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("h264-10bit-aac", "mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p10le", "-c:a", "aac"]),
    ("hevc-hvc1-aac", "mp4", ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-x265-params", "log-level=error"]),
    ("hevc-hev1-aac", "mp4", ["-c:v", "libx265", "-tag:v", "hev1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-x265-params", "log-level=error"]),
    ("av1-aac", "mp4", ["-c:v", "libsvtav1", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("h264-aac", "m4v", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("h264-aac", "mov", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("prores-pcm", "mov", ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le"]),
    ("h264-aac", "mkv", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("vp9-opus", "mkv", ["-c:v", "libvpx-vp9", "-b:v", "600k", "-c:a", "libopus"]),
    ("vp8-vorbis", "webm", ["-c:v", "libvpx", "-b:v", "800k", "-c:a", "vorbis", "-strict", "-2", "-ac", "2"]),
    ("vp8-opus", "webm", ["-c:v", "libvpx", "-b:v", "800k", "-c:a", "libopus"]),
    ("vp9-opus", "webm", ["-c:v", "libvpx-vp9", "-b:v", "600k", "-c:a", "libopus"]),
    ("vp9-vorbis", "webm", ["-c:v", "libvpx-vp9", "-b:v", "600k", "-c:a", "vorbis", "-strict", "-2", "-ac", "2"]),
    ("vp9-alpha-opus", "webm", ["-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "600k", "-c:a", "libopus"]),
    ("av1-opus", "webm", ["-c:v", "libsvtav1", "-pix_fmt", "yuv420p", "-c:a", "libopus"]),
    ("mpeg4-mp3", "avi", ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "4", "-c:a", "libmp3lame"]),
    ("divx3-mp3", "avi", ["-c:v", "msmpeg4", "-q:v", "4", "-c:a", "libmp3lame"]),
    ("mjpeg-pcm", "avi", ["-c:v", "mjpeg", "-q:v", "4", "-pix_fmt", "yuvj420p", "-c:a", "pcm_s16le"]),
    ("mpeg1-mp2", "mpg", ["-c:v", "mpeg1video", "-b:v", "1500k", "-c:a", "mp2", "-f", "mpeg"]),
    ("mpeg2-mp2", "mpg", ["-c:v", "mpeg2video", "-b:v", "1500k", "-c:a", "mp2", "-f", "vob"]),
    ("h264-aac", "ts", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
    ("wmv2-wma", "wmv", ["-c:v", "wmv2", "-b:v", "1000k", "-c:a", "wmav2"]),
]

AUDIOS = [
    ("vorbis", "ogg", ["-c:a", "vorbis", "-strict", "-2"]),
    # RPG Maker loops BGM from these Vorbis comments.
    ("vorbis-looptags", "ogg", ["-c:a", "vorbis", "-strict", "-2", "-metadata", "LOOPSTART=44100", "-metadata", "LOOPLENGTH=88200"]),
    ("opus", "ogg", ["-c:a", "libopus"]),
    ("opus", "opus", ["-c:a", "libopus"]),
    ("mp3", "mp3", ["-c:a", "libmp3lame", "-b:a", "128k"]),
    ("aac", "m4a", ["-c:a", "aac", "-b:a", "128k"]),
    ("alac", "m4a", ["-c:a", "alac"]),
    ("pcm16", "wav", ["-c:a", "pcm_s16le"]),
    ("pcm8", "wav", ["-c:a", "pcm_u8"]),
    ("adpcm-ms", "wav", ["-c:a", "adpcm_ms"]),
    ("flac", "flac", ["-c:a", "flac"]),
    ("pcm16be", "aiff", ["-c:a", "pcm_s16be"]),
    ("wma2", "wma", ["-c:a", "wmav2", "-b:a", "128k"]),
    ("ac3", "ac3", ["-c:a", "ac3"]),
]

IMAGE_BASE = "base.png"


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("%s\n%s" % (" ".join(cmd), result.stderr[-2000:]))


def ffmpeg(args, out):
    run(["ffmpeg", "-v", "error", "-y"] + args + [out])


def midi(path):
    """A four-bar C major scale on piano: the smallest standard MIDI file the soundfont path has to play."""
    track = b""
    for i, note in enumerate([60, 62, 64, 65, 67, 69, 71, 72]):
        track += bytes([0x00 if i == 0 else 0x00, 0x90, note, 0x60]) + bytes([0x83, 0x60, 0x80, note, 0x40])
    track = bytes([0x00, 0xC0, 0x00]) + track + bytes([0x00, 0xFF, 0x2F, 0x00])
    data = b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(track)) + track
    open(path, "wb").write(data)


def images(out):
    base = os.path.join(out, IMAGE_BASE)
    # 256x256: a gradient, a translucent disc and a white corner triangle, so colour, alpha and orientation show.
    run([
        "magick", "-size", "256x256", "gradient:#3b6fd8-#f2b233", "(", "-size", "256x256", "xc:none", "-fill", "#d9303080",
        "-draw", "circle 128,128 128,40", ")", "-composite", "-fill", "white", "-draw", "polygon 0,0 72,0 0,72",
        "PNG32:" + base,
    ])
    todo = [
        ("png-rgba.png", ["magick", base, "PNG32:{o}"]),
        ("png-rgb.png", ["magick", base, "-background", "black", "-flatten", "PNG24:{o}"]),
        ("png-indexed.png", ["magick", base, "-colors", "64", "PNG8:{o}"]),
        ("png-gray.png", ["magick", base, "-colorspace", "Gray", "-alpha", "off", "{o}"]),
        ("png-16bit.png", ["magick", base, "-depth", "16", "PNG64:{o}"]),
        ("png-interlaced.png", ["magick", base, "-interlace", "PNG", "PNG32:{o}"]),
        ("apng-animated.png", None),
        ("jpeg-baseline.jpg", ["magick", base, "-background", "white", "-flatten", "-interlace", "none", "{o}"]),
        ("jpeg-progressive.jpg", ["magick", base, "-background", "white", "-flatten", "-interlace", "JPEG", "{o}"]),
        ("jpeg-gray.jpg", ["magick", base, "-background", "white", "-flatten", "-colorspace", "Gray", "{o}"]),
        ("jpeg-cmyk.jpg", ["magick", base, "-background", "white", "-flatten", "-colorspace", "CMYK", "{o}"]),
        ("jpeg-bytes-named.png", ["magick", base, "-background", "white", "-flatten", "JPG:{o}"]),
        ("png-bytes-named.jpg", ["magick", base, "PNG32:{o}"]),
        ("bmp-24.bmp", ["magick", base, "-background", "black", "-flatten", "-type", "TrueColor", "BMP3:{o}"]),
        ("bmp-32-alpha.bmp", ["magick", base, "-type", "TrueColorAlpha", "BMP:{o}"]),
        ("bmp-8-indexed.bmp", ["magick", base, "-background", "black", "-flatten", "-colors", "256", "-type", "Palette", "BMP3:{o}"]),
        ("gif-static.gif", ["magick", base, "{o}"]),
        ("gif-animated.gif", ["magick", "-delay", "20", base, "(", base, "-flop", ")", "(", base, "-flip", ")", "-loop", "0", "{o}"]),
        ("webp-lossy.webp", ["cwebp", "-quiet", "-q", "80", base, "-o", "{o}"]),
        ("webp-lossless-alpha.webp", ["cwebp", "-quiet", "-lossless", base, "-o", "{o}"]),
        ("webp-animated.webp", ["magick", "-delay", "20", base, "(", base, "-flop", ")", "-loop", "0", "-define", "webp:lossless=true", "{o}"]),
        ("avif.avif", ["heif-enc", "--avif", "-q", "60", base, "-o", "{o}"]),
        ("heic.heic", ["heif-enc", "-q", "60", base, "-o", "{o}"]),
        ("tiff.tif", ["magick", base, "{o}"]),
        ("tga.tga", ["magick", base, "{o}"]),
        ("svg.svg", None),
        ("svg-animated.svg", None),
        ("avif-animated.avif", None),
        ("ico.ico", ["magick", base, "-define", "icon:auto-resize=64,32", "{o}"]),
    ]
    made = []
    for name, cmd in todo:
        o = os.path.join(out, name)
        if name == "svg.svg":
            open(o, "w").write(
                '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><rect width="256" height="256" fill="#3b6fd8"/>'
                '<circle cx="128" cy="128" r="88" fill="#d93030" fill-opacity="0.5"/>'
                '<text x="128" y="40" font-size="28" text-anchor="middle" fill="white">OmniPlay</text></svg>'
            )
        elif name == "svg-animated.svg":
            # SMIL (the disc moves) and CSS keyframes (the square turns): the two ways SVG art animates.
            open(o, "w").write(
                '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><style>@keyframes t{to{transform:rotate(360deg)}}'
                '#sq{transform-origin:192px 192px;animation:t 1s linear infinite}</style><rect width="256" height="256" fill="#3b6fd8"/>'
                '<circle cy="96" r="40" fill="#f2b233"><animate attributeName="cx" values="48;208;48" dur="1s" repeatCount="indefinite"/>'
                '</circle><rect id="sq" x="160" y="160" width="64" height="64" fill="#d93030"/></svg>'
            )
        elif name == "avif-animated.avif":
            ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=256x256:rate=5:duration=1", "-c:v", "libsvtav1", "-pix_fmt", "yuv420p", "-f", "avif"], o)
        elif name == "apng-animated.png":
            ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=256x256:rate=5:duration=1", "-plays", "0", "-f", "apng"], o)
        else:
            run([c.replace("{o}", o) for c in cmd])
        made.append(name)
    os.unlink(base)
    return made


def main():
    parser = argparse.ArgumentParser()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument("--out", default=os.path.join(root, "Fixtures/private/media-corpus"))
    parser.add_argument("--theora", help="an existing Theora/Vorbis .ogv to cut the Theora sample from")
    parser.add_argument("--vorbis", action="append", default=[], help="an existing libvorbis .ogg (repeatable)")
    args = parser.parse_args()
    for tool in ["ffmpeg", "magick", "cwebp", "heif-enc"]:
        if not shutil.which(tool):
            sys.exit("missing %s (brew install ffmpeg imagemagick webp libheif)" % tool)

    shutil.rmtree(args.out, ignore_errors=True)
    for d in ["video", "audio", "image"]:
        os.makedirs(os.path.join(args.out, d))
    manifest = {"video": [], "audio": [], "image": []}

    for name, ext, opts in VIDEOS:
        out = os.path.join(args.out, "video", "%s.%s" % (name, ext))
        ffmpeg(VIDEO_SRC + ["-shortest"] + opts, out)
        manifest["video"].append(os.path.basename(out))
    if args.theora:
        out = os.path.join(args.out, "video", "theora-vorbis.ogv")
        ffmpeg(["-i", args.theora, "-t", str(SECONDS), "-c", "copy"], out)
        manifest["video"].append(os.path.basename(out))

    for name, ext, opts in AUDIOS:
        out = os.path.join(args.out, "audio", "%s.%s" % (name, ext))
        ffmpeg(AUDIO_SRC + opts, out)
        manifest["audio"].append(os.path.basename(out))
    for i, source in enumerate(args.vorbis):
        out = os.path.join(args.out, "audio", "libvorbis-%d.ogg" % (i + 1))
        ffmpeg(["-i", source, "-t", str(SECONDS), "-c", "copy"], out)
        manifest["audio"].append(os.path.basename(out))
    midi(os.path.join(args.out, "audio", "scale.mid"))
    manifest["audio"].append("scale.mid")

    manifest["image"] = images(os.path.join(args.out, "image"))
    json.dump(manifest, open(os.path.join(args.out, "manifest.json"), "w"), indent=1)
    print("wrote %d videos, %d audio files, %d images to %s" % (
        len(manifest["video"]), len(manifest["audio"]), len(manifest["image"]), args.out))


if __name__ == "__main__":
    main()
