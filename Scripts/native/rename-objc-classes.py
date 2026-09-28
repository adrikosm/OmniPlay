#!/usr/bin/env python3
# rename-objc-classes.py <mach-o> <prefix>: SDL* Objective-C classes become <prefix>*, same length.
# SDL's UIKit backend registers Objective-C classes by name (SDL_uikitview, SDLUIKitDelegate, ...), and the app
# already has SDL for mkxp-z; each engine framework has its own. Classes register by the name string in
# __TEXT,__objc_classname, so renaming those strings in place (same length) gives every copy its own classes.
import struct, sys
path, prefix = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, "rb").read())
assert struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF, "thin 64-bit Mach-O expected"
ncmds = struct.unpack_from("<I", data, 16)[0]
off, renamed = 32, 0
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        for i in range(nsects):
            s = off + 72 + i * 80
            if data[s:s + 16].rstrip(b"\0") == b"__objc_classname":
                start = struct.unpack_from("<I", data, s + 48)[0]
                length = struct.unpack_from("<Q", data, s + 40)[0]
                pos = start
                while pos < start + length:
                    end = data.index(b"\0", pos)
                    if data[pos:pos + 3] == b"SDL":
                        data[pos:pos + 3] = prefix
                        renamed += 1
                    pos = end + 1
    off += size
open(path, "wb").write(data)
print(f"renamed {renamed} SDL Objective-C classes to {prefix.decode()}*")
