#!/usr/bin/env python3
"""Genera golden para test maxpool 2x2 de P_17 Fase 3."""

def s8(x):
    x &= 0xFF
    return x - 256 if x >= 128 else x

# Pattern de 64 bytes (16 ventanas 2x2). Cada ventana = 4 bytes consecutivos.
windows = [
    [ 0,   1,   2,   3],   # max = 3
    [-4,  -3,  -2,  -1],   # max = -1
    [127,  0, -128,  42],  # max = 127
    [-128,-128,-128,-128], # max = -128
    [100, -50,  50, -100], # max = 100
    [ 10,  20,  30,  40],  # max = 40
    [-1,  -2,  -3,  -4],   # max = -1
    [  5,   5,   5,   5],  # max = 5
    [ 99, 100, 101, 102],  # max = 102
    [-10, -20,  15, -30],  # max = 15
    [ 50,  50,  50, 127],  # max = 127
    [-128, 127, -128, 127],# max = 127
    [  1,   0,  -1,  -2],  # max = 1
    [ 33,  66,  11,  22],  # max = 66
    [  7,   7,   7,   8],  # max = 8
    [  0,   0,   0, -128], # max = 0
]

pattern = []
expected = []
for w in windows:
    for v in w:
        pattern.append(v & 0xFF)
    expected.append(max(w) & 0xFF)

print("/* ===== Auto-generado por gen_maxpool_test.py ===== */")
print(f"#define MP_TEST_N_INPUT_BYTES  {len(pattern)}")
print(f"#define MP_TEST_N_INPUT_WORDS  {len(pattern)//4}")
print(f"#define MP_TEST_N_OUTPUT_BYTES {len(expected)}")
print(f"#define MP_TEST_N_OUTPUT_WORDS {len(expected)//4}")
print()
print("static const u8 mp_input[MP_TEST_N_INPUT_BYTES] = {")
for i in range(0, len(pattern), 16):
    row = ", ".join(f"0x{p:02X}" for p in pattern[i:i+16])
    print(f"    {row},")
print("};")
print()
print("static const u8 mp_expected[MP_TEST_N_OUTPUT_BYTES] = {")
for i in range(0, len(expected), 16):
    row = ", ".join(f"0x{e:02X}" for e in expected[i:i+16])
    print(f"    {row},")
print("};")
