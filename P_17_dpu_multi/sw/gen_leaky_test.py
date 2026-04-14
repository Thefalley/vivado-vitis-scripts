#!/usr/bin/env python3
"""
gen_leaky_test.py - Genera valores golden para un test de leaky_relu en P_17.

Reproduce bit-exact la logica de leaky_relu.vhd (P_9) usando params de YOLOv4
layer_006 (QLinearLeakyRelu).

Salida: un bloque de arrays C que se puede copiar al test.
"""

# Params de layer_006 (de layer_configs.h)
X_ZP    = -17
Y_ZP    = -110
M0_POS  = 881676063
N_POS   = 29
M0_NEG  = 705340861
N_NEG   = 32


def leaky_relu(x_int8: int) -> int:
    """Bit-exact match de leaky_relu.vhd."""
    # Stage: x - x_zp (signed 9-bit)
    v = x_int8 - X_ZP
    # Stage: multiply + shift + round + saturate
    if v >= 0:
        acc = v * M0_POS
        # Round to nearest: add 2^(n-1) then arithmetic shift right by n
        rounding = (1 << (N_POS - 1)) if N_POS > 0 else 0
        shifted = (acc + rounding) >> N_POS
    else:
        acc = v * M0_NEG
        rounding = (1 << (N_NEG - 1)) if N_NEG > 0 else 0
        shifted = (acc + rounding) >> N_NEG
    # Add y_zp and saturate to int8
    y = shifted + Y_ZP
    if y > 127:
        y = 127
    elif y < -128:
        y = -128
    return y


def s8(x: int) -> int:
    """Convertir int a signed 8-bit bitwise."""
    x = x & 0xFF
    if x >= 128:
        x -= 256
    return x


# Test pattern: 64 bytes (16 words) cubriendo el rango int8
# Usamos valores que exploran ambas ramas (pos y neg de x-x_zp)
pattern = []
for i in range(64):
    # pattern cubre valores signados de -32 a +31
    val = -32 + i
    if val < -128:
        val = -128
    if val > 127:
        val = 127
    pattern.append(val & 0xFF)

# Expected output
expected = [leaky_relu(s8(p)) & 0xFF for p in pattern]

# Emit como arrays C
print("/* ===== Auto-generado por gen_leaky_test.py ===== */")
print(f"/* layer_006 params: x_zp={X_ZP}, y_zp={Y_ZP},")
print(f"   M0_pos={M0_POS}, n_pos={N_POS},")
print(f"   M0_neg={M0_NEG}, n_neg={N_NEG} */")
print()
print(f"#define LEAKY_TEST_N_BYTES {len(pattern)}")
print(f"#define LEAKY_TEST_N_WORDS {len(pattern)//4}")
print(f"#define LEAKY_X_ZP   {X_ZP}")
print(f"#define LEAKY_Y_ZP   {Y_ZP}")
print(f"#define LEAKY_M0_POS {M0_POS}u")
print(f"#define LEAKY_N_POS  {N_POS}")
print(f"#define LEAKY_M0_NEG {M0_NEG}u")
print(f"#define LEAKY_N_NEG  {N_NEG}")
print()
print("static const u8 leaky_input[LEAKY_TEST_N_BYTES] = {")
for i in range(0, len(pattern), 16):
    row = ", ".join(f"0x{p:02X}" for p in pattern[i:i+16])
    print(f"    {row},")
print("};")
print()
print("static const u8 leaky_expected[LEAKY_TEST_N_BYTES] = {")
for i in range(0, len(expected), 16):
    row = ", ".join(f"0x{e:02X}" for e in expected[i:i+16])
    print(f"    {row},")
print("};")
print()
print("/* Sanity samples (signed representation):")
print("   input  signed: ", [s8(p) for p in pattern[:8]])
print("   output signed: ", [s8(e) for e in expected[:8]])
print("*/")
