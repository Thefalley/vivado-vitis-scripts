#!/usr/bin/env python3
"""Golden elem_add bit-exact con P_11/src/elem_add.vhd."""

# Params de layer_017 YOLOv4 (QLinearAdd)
A_ZP     = -102
B_ZP     = -97
Y_ZP     = -102
M0_A     = 605961470
M0_B     = 715593500
N_SHIFT  = 30


def s8(x):
    x &= 0xFF
    return x - 256 if x >= 128 else x


def elem_add_ref(a_i8: int, b_i8: int) -> int:
    va = a_i8 - A_ZP
    vb = b_i8 - B_ZP
    tot = va * M0_A + vb * M0_B
    rnd = 1 << (N_SHIFT - 1)
    shifted = (tot + rnd) >> N_SHIFT
    y = shifted + Y_ZP
    if y > 127:
        y = 127
    elif y < -128:
        y = -128
    return y


N = 64
a = []
b = []
for i in range(N):
    a_val = (-32 + i) % 256
    b_val = (127 - i) % 256
    a.append(a_val)
    b.append(b_val)

expected = [elem_add_ref(s8(ai), s8(bi)) & 0xFF for ai, bi in zip(a, b)]

print("/* ===== Auto-generado por gen_elem_add_test.py ===== */")
print("/* layer_017 YOLOv4 params */")
print()
print(f"#define EA_N_BYTES  {N}")
print(f"#define EA_N_WORDS  {N//4}")
print(f"#define EA_A_ZP     {A_ZP}")
print(f"#define EA_B_ZP     {B_ZP}")
print(f"#define EA_Y_ZP     {Y_ZP}")
print(f"#define EA_M0_A     {M0_A}u")
print(f"#define EA_M0_B     {M0_B}u")
print(f"#define EA_N_SHIFT  {N_SHIFT}")
print()
print("static const u8 ea_a[EA_N_BYTES] = {")
for i in range(0, N, 16):
    print("    " + ", ".join(f"0x{v:02X}" for v in a[i:i+16]) + ",")
print("};")
print()
print("static const u8 ea_b[EA_N_BYTES] = {")
for i in range(0, N, 16):
    print("    " + ", ".join(f"0x{v:02X}" for v in b[i:i+16]) + ",")
print("};")
print()
print("static const u8 ea_expected[EA_N_BYTES] = {")
for i in range(0, N, 16):
    print("    " + ", ".join(f"0x{v:02X}" for v in expected[i:i+16]) + ",")
print("};")
