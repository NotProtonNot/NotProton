#!/usr/bin/env python3
import os
import struct
import subprocess
import sys
import tempfile
import zlib


def png(side):
    raw = b"".join(b"\0" + bytes([200, 30, 30, 255]) * side for _ in range(side))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def bmp8(side):
    stride = (side + 3) & ~3
    mask = ((side + 31) // 32) * 4
    header = struct.pack("<IiiHHIIiiII", 40, side, side * 2, 1, 8, 0, (stride + mask) * side, 0, 0, 256, 0)
    return header + bytes(1024) + bytes((stride + mask) * side)


def ico(entries):
    out = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    body = b""
    for side, data, bpp in entries:
        out += struct.pack("<BBBBHHII", side % 256, side % 256, 0, 0, 1, bpp, len(data), offset + len(body))
        body += data
    return out + body


def run(iconmaker, name, data):
    src = os.path.join(tmp, name)
    with open(src, "wb") as f:
        f.write(data)
    dst = src + ".icns"
    rc = subprocess.run([iconmaker, src, dst], capture_output=True).returncode
    return rc == 0 and os.path.getsize(dst) > 0


iconmaker = sys.argv[1]
fails = 0
tmp = tempfile.mkdtemp()
cases = [
    ("plain ico", "plain.ico", ico([(64, png(64), 32)]), True),
    ("ico with an entry ImageIO rejects", "mixed.ico", ico([(10, bmp8(10), 8), (64, png(64), 32)]), True),
    ("truncated ico", "short.ico", ico([(64, png(64), 32)])[:40], False),
    ("not an image", "junk.ico", b"junk", False),
]
for label, name, data, want in cases:
    got = run(iconmaker, name, data)
    print(("  ok    " if got == want else "  FAIL  ") + label)
    fails += got != want
if fails:
    sys.exit(f"iconcheck: {fails} failed")
print("iconcheck: all passed")
