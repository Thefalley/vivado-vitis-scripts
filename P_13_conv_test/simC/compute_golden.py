#!/usr/bin/env python3
"""
compute_golden.py -- Compute expected outputs for the 3 critical configs of
conv_engine_v3 used by critical_{A,B,C}_tb.vhd.

Quantization model (matches conv_engine_v3 / requantize.vhd):
  acc = sum_{kh,kw,ic} (x_int[ih,iw,ic] - x_zp) * (w_int[oc,kh,kw,ic] - w_zp) + bias
        (x_zp is 9-bit signed, so x>=0 - (-128) = x+128; result fits in 32 bits)
  y = round(acc * M0 / 2^n_shift) + y_zp
      where round = arithmetic shift with bankers/round-half-up; we use the
      Python "round half away from zero" since requantize.vhd does + (1<<(n-1))
      then arithmetic shift right.
  y = sat(y, -128, 127)
"""

import numpy as np


def rq(acc: int, M0: int, n: int, y_zp: int) -> int:
    # bit-exact match to requantize.vhd:
    #   prod = acc * M0  (signed * unsigned = signed64)
    #   half = 1 << (n-1)
    #   shifted = (prod + half) >> n   (arithmetic)
    prod = acc * M0
    half = 1 << (n - 1)
    if prod >= 0:
        shifted = (prod + half) >> n
    else:
        # arithmetic right shift on negative numbers in Python is correct for >>
        shifted = (prod + half) >> n
    y = shifted + y_zp
    if y > 127:
        y = 127
    if y < -128:
        y = -128
    return y


def conv_one(x, w, bias, x_zp, w_zp, pad_t, pad_b, pad_l, pad_r, stride, M0, n_shift, y_zp):
    """x: [ic,ih,iw] uint8 reinterpreted as int. w: [oc,kh,kw,ic]. bias: [oc] int32."""
    c_in, h_in, w_in = x.shape
    c_out, kh, kw, _ = w.shape
    h_out = (h_in + pad_t + pad_b - kh) // stride + 1
    w_out = (w_in + pad_l + pad_r - kw) // stride + 1
    y = np.zeros((c_out, h_out, w_out), dtype=np.int64)
    y_q = np.zeros((c_out, h_out, w_out), dtype=np.int32)
    for oc in range(c_out):
        for oh in range(h_out):
            for ow in range(w_out):
                acc = int(bias[oc])
                for kh_i in range(kh):
                    for kw_i in range(kw):
                        ih = oh * stride + kh_i - pad_t
                        iw = ow * stride + kw_i - pad_l
                        for ic in range(c_in):
                            if 0 <= ih < h_in and 0 <= iw < w_in:
                                xv = int(x[ic, ih, iw])
                            else:
                                xv = x_zp  # padding contributes (x_zp - x_zp) = 0
                            wv = int(w[oc, kh_i, kw_i, ic])
                            acc += (xv - x_zp) * (wv - w_zp)
                y[oc, oh, ow] = acc
                y_q[oc, oh, ow] = rq(int(acc), M0, n_shift, y_zp)
    return y, y_q


# ===========================================================================
# Config A: stride=2 asymmetric pad (YOLOv4 style)
# ===========================================================================
def gen_A():
    c_in, c_out, h_in, w_in = 3, 32, 8, 8
    kh = kw = 3
    stride = 2
    pad_t, pad_b, pad_l, pad_r = 1, 0, 1, 0
    x_zp, w_zp = -128, 0
    M0, n_shift, y_zp = 656954014, 37, -17

    # Inputs: signed pattern; uint8 storage will be (i*7+13) % 256 - 128
    x = np.zeros((c_in, h_in, w_in), dtype=np.int32)
    idx = 0
    for ic in range(c_in):
        for ih in range(h_in):
            for iw in range(w_in):
                x[ic, ih, iw] = ((idx * 7 + 13) % 256) - 128
                idx += 1

    # Weights OHWI, simple identity-ish:
    #   filter 0 : all 1s    (sum-of-input style)
    #   filter 1 : center 1  (acts as identity for the center pixel)
    #   filter 2..31 : zeros
    w = np.zeros((c_out, kh, kw, c_in), dtype=np.int32)
    w[0, :, :, :] = 1
    w[1, 1, 1, :] = 1

    bias = np.zeros((c_out,), dtype=np.int32)
    bias[0] = 1000

    acc, yq = conv_one(x, w, bias, x_zp, w_zp, pad_t, pad_b, pad_l, pad_r,
                       stride, M0, n_shift, y_zp)
    return x, w, bias, acc, yq, (h_in + pad_t + pad_b - kh) // stride + 1


# ===========================================================================
# Config B: maximum tiling stress (ic_tile_size=1, c_in=9 -> 9 tiles)
# ===========================================================================
def gen_B():
    c_in, c_out, h_in, w_in = 9, 32, 4, 4
    kh = kw = 3
    stride = 1
    pad_t = pad_b = pad_l = pad_r = 1
    x_zp, w_zp = -128, 0
    M0, n_shift, y_zp = 656954014, 37, -17

    x = np.zeros((c_in, h_in, w_in), dtype=np.int32)
    idx = 0
    for ic in range(c_in):
        for ih in range(h_in):
            for iw in range(w_in):
                x[ic, ih, iw] = ((idx * 5 + 7) % 256) - 128
                idx += 1

    w = np.zeros((c_out, kh, kw, c_in), dtype=np.int32)
    # filter 0: all-ones across kh,kw,ic
    w[0, :, :, :] = 1
    # filter 1: center, ic=0 only
    w[1, 1, 1, 0] = 1
    # filter 2: center, ic=8 only (last channel, must be picked up by last tile)
    w[2, 1, 1, 8] = 1
    # filter 3: top-left, ic=4
    w[3, 0, 0, 4] = 1

    bias = np.zeros((c_out,), dtype=np.int32)

    acc, yq = conv_one(x, w, bias, x_zp, w_zp, pad_t, pad_b, pad_l, pad_r,
                       stride, M0, n_shift, y_zp)
    return x, w, bias, acc, yq, (h_in + pad_t + pad_b - kh) // stride + 1


# ===========================================================================
# Config C: partial tile (c_in=5, ic_tile_size=2 -> tiles of 2,2,1)
# ===========================================================================
def gen_C():
    c_in, c_out, h_in, w_in = 5, 32, 4, 4
    kh = kw = 3
    stride = 1
    pad_t = pad_b = pad_l = pad_r = 1
    x_zp, w_zp = -128, 0
    M0, n_shift, y_zp = 656954014, 37, -17

    x = np.zeros((c_in, h_in, w_in), dtype=np.int32)
    idx = 0
    for ic in range(c_in):
        for ih in range(h_in):
            for iw in range(w_in):
                x[ic, ih, iw] = ((idx * 3 + 11) % 256) - 128
                idx += 1

    w = np.zeros((c_out, kh, kw, c_in), dtype=np.int32)
    w[0, :, :, :] = 1
    w[1, 1, 1, 0] = 1
    # filter 2: ic=4 only -> partial tile discriminator
    w[2, 1, 1, 4] = 1
    w[3, 0, 0, 2] = 1

    bias = np.zeros((c_out,), dtype=np.int32)

    acc, yq = conv_one(x, w, bias, x_zp, w_zp, pad_t, pad_b, pad_l, pad_r,
                       stride, M0, n_shift, y_zp)
    return x, w, bias, acc, yq, (h_in + pad_t + pad_b - kh) // stride + 1


def main():
    for name, fn in [("A", gen_A), ("B", gen_B), ("C", gen_C)]:
        x, w, bias, acc, yq, h_out = fn()
        print(f"=== Config {name} : c_out=32 h_out={h_out} ===")
        print(f"  filter 0..3 expected (OC, all pixels, requantized):")
        for oc in range(4):
            row = yq[oc].flatten().tolist()
            print(f"    oc={oc}: {row}")
        print(f"  filter 0..3 raw acc (first pixel oh=0 ow=0):")
        for oc in range(4):
            print(f"    oc={oc}: acc={int(acc[oc, 0, 0])}")
        # Print all expected as flat list, in HW write order:
        # output layout per pixel oc=0..31 contiguous
        flat = []
        for oh in range(yq.shape[1]):
            for ow in range(yq.shape[2]):
                for oc in range(yq.shape[0]):
                    flat.append(int(yq[oc, oh, ow]))
        print(f"  flat expected (per-pixel oc=0..31), {len(flat)} bytes:")
        print(f"    {flat}")
        print()


if __name__ == "__main__":
    main()
