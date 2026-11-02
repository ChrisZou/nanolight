"""Nanolight's icon, after the Bauhaus: a magnifier made of a circle, a ring
and a bar, in the primaries on cream, on Apple's macOS icon grid (an
824-pixel tile in 1024) with a soft shadow under the tile.

Every shape is a signed distance, so its edge is anti-aliased exactly;
Python's standard library alone writes the PNG (no image tools needed).

    python3 tools/nanolight-icon.py src/icon.png
"""
import math
import struct
import sys
import zlib

SIZE = 1024
CREAM = (0xF0, 0xEB, 0xE0)
YELLOW = (0xF2, 0xB7, 0x05)
BLACK = (0x1B, 0x1B, 0x1B)
RED = (0xD7, 0x37, 0x2A)

TILE_C, TILE_HALF, TILE_R = 512.0, 412.0, 185.0
LENS = (452.0, 452.0)
DISC_R, RING_R, RING_W = 132.0, 210.0, 64.0
# The handle: along 45 degrees from the lens's centre, from 252 to 448 out.
BAR_MID, BAR_HALF_LEN, BAR_HALF_W = 350.0, 98.0, 42.0
SHADOW_Y, SHADOW_SIGMA, SHADOW_ALPHA = 10.0, 14.0, 0.30


def rounded_box(x, y, cx, cy, half, r):
    qx = abs(x - cx) - (half - r)
    qy = abs(y - cy) - (half - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - r


def box(u, v, hu, hv):
    qx = abs(u) - hu
    qy = abs(v) - hv
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0)


def cover(d):
    """A shape's share of a pixel, from the distance at its centre."""
    return min(1.0, max(0.0, 0.5 - d))


def over(px, rgb, a):
    """Paints `rgb` at alpha `a` over premultiplied `px` (r, g, b, a)."""
    if a <= 0.0:
        return px
    k = 1.0 - a
    return (rgb[0] * a + px[0] * k, rgb[1] * a + px[1] * k, rgb[2] * a + px[2] * k, a + px[3] * k)


def pixel(x, y):
    px = (0.0, 0.0, 0.0, 0.0)
    ds = rounded_box(x, y - SHADOW_Y, TILE_C, TILE_C, TILE_HALF, TILE_R)
    if ds < 4 * SHADOW_SIGMA:
        shade = SHADOW_ALPHA * 0.5 * math.erfc(ds / (SHADOW_SIGMA * math.sqrt(2.0)))
        px = over(px, (0, 0, 0), shade)
    dt = rounded_box(x, y, TILE_C, TILE_C, TILE_HALF, TILE_R)
    if dt > 1.0:
        return px
    px = over(px, CREAM, cover(dt))
    dx, dy = x - LENS[0], y - LENS[1]
    if abs(dx) > 400 or abs(dy) > 400:
        return px
    dist = math.hypot(dx, dy)
    px = over(px, YELLOW, cover(dist - DISC_R))
    px = over(px, BLACK, cover(abs(dist - RING_R) - RING_W / 2))
    u = (dx + dy) / math.sqrt(2.0) - BAR_MID
    v = (dy - dx) / math.sqrt(2.0)
    px = over(px, RED, cover(box(u, v, BAR_HALF_LEN, BAR_HALF_W)))
    return px


def png(path, rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    head = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "src/icon.png"
    rows = bytearray()
    for j in range(SIZE):
        rows.append(0)
        for i in range(SIZE):
            r, g, b, a = pixel(i + 0.5, j + 0.5)
            if a > 0.0:
                # Straight alpha, as PNG keeps it.
                rows += bytes((round(r / a), round(g / a), round(b / a), round(a * 255)))
            else:
                rows += b"\0\0\0\0"
    png(out, bytes(rows))
    print(out)


if __name__ == "__main__":
    main()
