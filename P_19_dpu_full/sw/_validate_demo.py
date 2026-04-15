"""
_validate_demo.py - Python re-implementation that mirrors framebuffer.c
exactly, used to validate the demo_test logic since the local MinGW
toolchain is broken (cc1.exe DLL load failure). Parses font8x8.h to
recover the same glyph data used by C.
"""
import re, struct, os, sys

W, H, BPP = 1280, 720, 3
SW_DIR = os.path.dirname(os.path.abspath(__file__))

# ---- parse font8x8.h ---------------------------------------------------
with open(os.path.join(SW_DIR, "font8x8.h"), "r", encoding="utf-8") as f:
    src = f.read()

def parse_b8(s):
    # B8(c0,c1,...,c7) - col0 leftmost on screen, stored at bit 0.
    bits = [int(b) for b in re.findall(r'\d', s)]
    val = 0
    for i, b in enumerate(bits):
        val |= (b & 1) << i
    return val

# Glyph table: each glyph is index 0x20..0x7E, 8 bytes.
glyphs = {}
# Find all named macros for placeholders / blanks first
G_BOX = [0,
    parse_b8("0,1,1,1,1,1,1,0"),
    parse_b8("0,1,0,0,0,0,1,0"),
    parse_b8("0,1,0,0,0,0,1,0"),
    parse_b8("0,1,0,0,0,0,1,0"),
    parse_b8("0,1,0,0,0,0,1,0"),
    parse_b8("0,1,1,1,1,1,1,0"),
    0]
G_BLANK = [0]*8

# Match each glyph entry: comment with hex code, then either G_BOX/G_BLANK or { ... }
entry_re = re.compile(
    r'/\*\s*0x([0-9A-Fa-f]{2})\s*\'.*?\'\s*\*/\s*'
    r'(G_BOX|G_BLANK|\{[^}]*\})',
    re.DOTALL)

for m in entry_re.finditer(src):
    code = int(m.group(1), 16)
    body = m.group(2).strip()
    if body == "G_BOX":
        glyphs[code] = list(G_BOX)
    elif body == "G_BLANK":
        glyphs[code] = list(G_BLANK)
    else:
        rows = re.findall(r'B8\(([^)]*)\)', body)
        assert len(rows) == 8, f"glyph 0x{code:02x} has {len(rows)} rows"
        glyphs[code] = [parse_b8(r) for r in rows]

print(f"parsed {len(glyphs)} glyphs (expected 95)")
assert len(glyphs) == 95

# ---- framebuffer ops mirroring framebuffer.c --------------------------
fb = bytearray(W * H * BPP)

def in_bounds(x, y): return 0 <= x < W and 0 <= y < H

def put_px(x, y, r, g, b):
    if not in_bounds(x, y): return
    o = (y * W + x) * 3
    fb[o:o+3] = bytes((r, g, b))

def clear(r, g, b):
    row = bytes((r, g, b)) * W
    for y in range(H):
        o = y * W * 3
        fb[o:o + W*3] = row

def fill_rect(x, y, w, h, r, g, b):
    if w <= 0 or h <= 0: return
    if x >= W or y >= H: return
    if x + w <= 0 or y + h <= 0: return
    if x < 0: w += x; x = 0
    if y < 0: h += y; y = 0
    if x + w > W: w = W - x
    if y + h > H: h = H - y
    if w <= 0 or h <= 0: return
    row = bytes((r, g, b)) * w
    for j in range(h):
        o = ((y + j) * W + x) * 3
        fb[o:o + w*3] = row

def draw_rect(x, y, w, h, r, g, b, t):
    if t < 1: t = 1
    if w <= 0 or h <= 0: return
    if t*2 >= w or t*2 >= h:
        fill_rect(x, y, w, h, r, g, b); return
    fill_rect(x, y, w, t, r, g, b)
    fill_rect(x, y+h-t, w, t, r, g, b)
    fill_rect(x, y+t, t, h-2*t, r, g, b)
    fill_rect(x+w-t, y+t, t, h-2*t, r, g, b)

def draw_line(x0, y0, x1, y1, r, g, b):
    dx = abs(x1 - x0); dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        put_px(x0, y0, r, g, b)
        if x0 == x1 and y0 == y1: break
        e2 = 2 * err
        if e2 >= dy: err += dy; x0 += sx
        if e2 <= dx: err += dx; y0 += sy

def draw_text(x, y, text, r, g, b):
    cx = x
    for ch in text:
        c = ord(ch)
        if ch == '\n': cx = x; y += 8; continue
        if c < 0x20 or c > 0x7E: c = ord('?')
        glyph = glyphs[c]
        for row in range(8):
            bits = glyph[row]
            for col in range(8):
                if bits & (1 << col):
                    put_px(cx + col, y + row, r, g, b)
        cx += 8

def draw_image_rgb(dx, dy, src, sw, sh):
    sx0 = sy0 = 0
    w, h = sw, sh
    if dx < 0: sx0 = -dx; w += dx; dx = 0
    if dy < 0: sy0 = -dy; h += dy; dy = 0
    if dx >= W or dy >= H: return
    if dx + w > W: w = W - dx
    if dy + h > H: h = H - dy
    if w <= 0 or h <= 0: return
    for j in range(h):
        sp = ((sy0 + j) * sw + sx0) * 3
        dp = ((dy + j) * W + dx) * 3
        fb[dp:dp + w*3] = src[sp:sp + w*3]

# ---- replicate demo_test.c steps -------------------------------------
clear(0x40, 0x40, 0x40)
draw_rect(100, 80, 400, 300, 0xFF, 0, 0, 3)
fill_rect(600, 100, 200, 150, 0, 0xC0, 0)
draw_line(50, 50, 1230, 670, 0, 0x80, 0xFF)
draw_line(50, 670, 1230, 50, 0, 0x80, 0xFF)
draw_text(120, 100, "hello dpu", 0xFF, 0xFF, 0xFF)
draw_text(610, 110, "person 0.95", 0, 0, 0)
for i in range(-5, 5): put_px(i, i, 0xFF, 0xFF, 0)
for i in range(-5, 5): put_px(W-1+i, H-1+i, 0xFF, 0xFF, 0)

tile = bytearray(32*32*3)
for j in range(32):
    for i in range(32):
        o = (j*32 + i)*3
        tile[o]   = (i*8) & 0xFF
        tile[o+1] = (j*8) & 0xFF
        tile[o+2] = 0x80
draw_image_rgb(900, 400, tile, 32, 32)
draw_image_rgb(W-16, 500, tile, 32, 32)
draw_image_rgb(-16, 600, tile, 32, 32)

# Save PPM exactly like demo_test.c
ppm_path = os.path.join(SW_DIR, "demo_test_python.ppm")
with open(ppm_path, "wb") as f:
    f.write(f"P6\n{W} {H}\n255\n".encode())
    f.write(bytes(fb))

# Save PNG too for easy viewing
from PIL import Image
img = Image.frombytes("RGB", (W, H), bytes(fb))
png_path = os.path.join(SW_DIR, "demo_test_python.png")
img.save(png_path)

painted = sum(1 for i in range(0, len(fb), 3)
              if not (fb[i] == 0x40 and fb[i+1] == 0x40 and fb[i+2] == 0x40))
print(f"OK  fb={W}x{H}  bytes={len(fb)}  painted_px={painted}")
print(f"PPM: {ppm_path}")
print(f"PNG: {png_path}")
