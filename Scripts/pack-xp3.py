#!/usr/bin/env python3
"""pack-xp3.py <folder> <out.xp3>: packs a KiriKiri project folder into an XP3 archive (the version-1 layout every
KiriKiri 2/Z reads): magic, index offset, zlib-compressed file bodies, then a zlib-compressed index of File chunks
(info: name and sizes, segm: where the bytes are, adlr: Adler-32 of the original). No encryption, no cushion header.
Used to make test games; real games bring their own archives."""
import os
import struct
import sys
import zlib

MAGIC = b"XP3\r\n \n\x1a\x8b\x67\x01"


def chunk(tag, body):
    return tag + struct.pack("<Q", len(body)) + body


def pack(folder, out):
    entries, body = [], bytearray()
    offset = len(MAGIC) + 8
    for root, dirs, files in os.walk(folder):
        dirs.sort()
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, folder).replace(os.sep, "/")
            data = open(path, "rb").read()
            packed = zlib.compress(data, 9)
            entries.append((rel, len(data), offset + len(body), len(packed), zlib.adler32(data) & 0xFFFFFFFF))
            body += packed
    index = bytearray()
    for rel, size, at, packed_size, adler in entries:
        name = rel.encode("utf-16-le")
        info = struct.pack("<IQQH", 0, size, packed_size, len(rel)) + name
        segm = struct.pack("<IQQQ", 1, at, size, packed_size)  # 1: zlib
        index += chunk(b"File", chunk(b"info", info) + chunk(b"segm", segm) + chunk(b"adlr", struct.pack("<I", adler)))
    index_offset = len(MAGIC) + 8 + len(body)
    compressed = zlib.compress(bytes(index), 9)
    with open(out, "wb") as f:
        f.write(MAGIC + struct.pack("<Q", index_offset))
        f.write(body)
        f.write(b"\x01" + struct.pack("<QQ", len(compressed), len(index)) + compressed)
    return len(entries)


if __name__ == "__main__":
    print(f"packed {pack(sys.argv[1], sys.argv[2])} files into {sys.argv[2]}")
