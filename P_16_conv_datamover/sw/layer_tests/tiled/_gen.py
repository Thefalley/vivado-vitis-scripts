#!/usr/bin/env python3
"""
Generate IC-tiling test variants from P_16 baseline layer tests.

Each variant is a byte-for-byte copy of the baseline with ONLY:
  1) the single `conv_write(REG_IC_TILE_SIZE, C_IN);` line replaced
     with a literal `ic_tile_size` value, and
  2) the opening printf banner annotated with the tile config.

Everything else (input data, weights, biases, expected_full[], scales,
zero points, padding, etc.) is preserved verbatim.
"""
import os
import re
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.abspath(os.path.join(BASE, ".."))
OUT  = BASE

# (out_file, baseline, c_in, ic_tile_size)
VARIANTS = [
    # Divisible cases
    ("layer_005_ic1_test.c", "layer_005_test.c", 3, 1),
    ("layer_038_ic1_test.c", "layer_038_test.c", 9, 1),
    ("layer_038_ic3_test.c", "layer_038_test.c", 9, 3),
    ("layer_043_ic1_test.c", "layer_043_test.c", 5, 1),
    ("layer_045_ic1_test.c", "layer_045_test.c", 5, 1),
    ("layer_047_ic1_test.c", "layer_047_test.c", 5, 1),
    # Non-divisible cases (partial last tile)
    ("layer_005_ic2_test.c", "layer_005_test.c", 3, 2),
    ("layer_043_ic2_test.c", "layer_043_test.c", 5, 2),
    ("layer_049_ic2_test.c", "layer_049_test.c", 5, 2),
    ("layer_038_ic4_test.c", "layer_038_test.c", 9, 4),
]

IC_RE = re.compile(r'conv_write\(REG_IC_TILE_SIZE,\s*C_IN\);')

# layer_005 uses a multi-line banner starting with the "###" box.
BANNER_005_RE = re.compile(
    r'(xil_printf\("\\r\\n#+\\r\\n"\);\s*\r?\n'
    r'\s*xil_printf\("  P_16 Conv \+ DataMover Test -- ZedBoard\\r\\n"\);\s*\r?\n'
    r'\s*xil_printf\("  Layer 005: [^"]*\\r\\n"\);)'
)

# The other five layers use a one-line banner: "=== P_16 Layer NNN test ==="
BANNER_GEN_RE = re.compile(
    r'(xil_printf\("\\r\\n=== P_16 Layer (\d{3}) test ===\\r\\n"\);)'
)


def tile_count(c_in: int, ic_ts: int) -> int:
    return (c_in + ic_ts - 1) // ic_ts


def patch(text: str, c_in: int, ic_ts: int, layer_tag: str) -> str:
    n_tiles = tile_count(c_in, ic_ts)
    suffix = (f" [IC TILED: ic_tile_size={ic_ts}, {n_tiles} tile(s), c_in={c_in}]"
              f"  last_tile_len={c_in - (n_tiles - 1) * ic_ts}")

    # 1) Replace the one ic_tile_size write.
    new_text, n_ic = IC_RE.subn(
        f"conv_write(REG_IC_TILE_SIZE, {ic_ts}); "
        f"/* IC tiling variant: {n_tiles} tile(s) over c_in={c_in} */",
        text,
    )
    if n_ic != 1:
        raise RuntimeError(f"{layer_tag}: expected 1 REG_IC_TILE_SIZE write, found {n_ic}")

    # 2) Annotate the banner (style depends on which baseline).
    if layer_tag.startswith("layer_005"):
        def _rep(m):
            return (m.group(1) +
                    f'\n    xil_printf("  IC TILING: ic_tile_size={ic_ts}, '
                    f'{n_tiles} tile(s), c_in={c_in}\\r\\n");')
        new_text, n_b = BANNER_005_RE.subn(_rep, new_text, count=1)
        if n_b != 1:
            raise RuntimeError(f"{layer_tag}: failed to patch layer_005 banner")
    else:
        def _rep(m):
            orig = m.group(1)
            lay  = m.group(2)
            replaced = (
                f'xil_printf("\\r\\n=== P_16 Layer {lay} test '
                f'[ic_tile_size={ic_ts}, {n_tiles} tile(s)] ===\\r\\n");'
            )
            return replaced
        new_text, n_b = BANNER_GEN_RE.subn(_rep, new_text, count=1)
        if n_b != 1:
            raise RuntimeError(f"{layer_tag}: failed to patch generic banner")

    # 3) Prepend a visible header comment so the file self-documents.
    header = (
        "/* =========================================================================\n"
        f" * Auto-generated IC-tiling variant of {layer_tag}\n"
        f" *   c_in           = {c_in}\n"
        f" *   ic_tile_size   = {ic_ts}\n"
        f" *   num tiles      = {n_tiles}\n"
        f" *   last tile size = {c_in - (n_tiles - 1) * ic_ts}\n"
        " *\n"
        " * Algorithm is identical to the baseline -- ic_tile_size is a HW\n"
        " * micro-architectural knob (how many IC channels the MAC array\n"
        " * accumulates per pass). Expected output bytes (expected_full[]) must\n"
        " * match the baseline bit-exactly.\n"
        " * ========================================================================= */\n"
    )
    return header + new_text


def main() -> int:
    for out_name, base_name, c_in, ic_ts in VARIANTS:
        src_path = os.path.join(SRC, base_name)
        dst_path = os.path.join(OUT, out_name)
        with open(src_path, "r", encoding="utf-8", newline="") as f:
            text = f.read()
        patched = patch(text, c_in, ic_ts, base_name.replace("_test.c", ""))
        with open(dst_path, "w", encoding="utf-8", newline="") as f:
            f.write(patched)
        n = tile_count(c_in, ic_ts)
        print(f"wrote {out_name:30s}  <- {base_name}  (ic_ts={ic_ts}, {n} tile(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
