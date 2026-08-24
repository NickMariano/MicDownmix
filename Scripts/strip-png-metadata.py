#!/usr/bin/env python3
"""Rewrites PNGs keeping only the chunks needed to render them.

Image files arrive carrying more than pixels. Screenshots keep EXIF and XMP blocks, and generated
images can embed a C2PA provenance manifest naming the tool that made them, with timestamps to the
microsecond. None of that belongs in a public repository, and none of it is visible without looking.
"""

import struct
import sys

# Everything required to decode the image, and nothing else.
KEEP = {b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND", b"acTL", b"fcTL", b"fdAT"}


def strip(path: str) -> tuple[int, list[str]]:
    with open(path, "rb") as handle:
        data = handle.read()

    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")

    out = bytearray(data[:8])
    removed = []
    pos = 8
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos : pos + 12 + length]
        if ctype in KEEP:
            out += chunk
        else:
            removed.append(f"{ctype.decode('latin-1')} ({length}B)")
        pos += 12 + length
        if ctype == b"IEND":
            break

    saved = len(data) - len(out)
    with open(path, "wb") as handle:
        handle.write(out)
    return saved, removed


if __name__ == "__main__":
    for target in sys.argv[1:]:
        saved, removed = strip(target)
        detail = ", ".join(removed) if removed else "nothing to remove"
        print(f"  {target}: -{saved}B  [{detail}]")
