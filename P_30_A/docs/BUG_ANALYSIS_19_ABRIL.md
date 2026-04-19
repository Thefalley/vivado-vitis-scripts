# Bug Analysis -- 19 abril 2026

Investigation of 3 firmware bugs in P_30_A DPU runtime.

---

## Bug 1: POOL grande timeout (layers 182-184)

**Affected layers:**
- [182] L187 MaxPool: kernel=5, stride=1, pad=2, c_in=512, h=13x13
- [183] L188 MaxPool: kernel=9, stride=1, pad=4, c_in=512, h=13x13
- [184] L189 MaxPool: kernel=13, stride=1, pad=6, c_in=512, h=13x13

**Root cause:** `dpu_exec_pool()` and the VHDL wrapper `S_STREAM_MP` are
hardcoded for 2x2 max pooling only. The function assumes each window is
exactly 4 bytes (2x2 = 4 elements) and sends 1 AXI word per window.
Layers 182-184 are YOLOv4 SPP (Spatial Pyramid Pooling) layers with
kernel sizes 5x5, 9x9, and 13x13 respectively -- NOT 2x2.

Evidence in `dpu_exec.c` line 406:
```c
/* Each window = 4 input bytes -> 1 output byte (2x2 max). */
```

Evidence in `dpu_stream_wrapper_v4.vhd` line 876-884:
```
--   ARM pre-ordena ventanas 2x2 contiguas: cada word
--   son 4 bytes de 1 ventana. ...
--   Ratio: 4 input bytes (1 word) -> 1 output byte.
```

The hardware maxpool_unit processes exactly 4 values (bytes 0-3 of each
word), asserts clear between windows, and captures the max after byte 3.
There is no support for windows larger than 4 bytes.

When the firmware sends a 5x5 (25 byte) window as if it were a sequence
of 2x2 windows, the hardware produces garbage and/or the byte count
mismatch causes the DataMover to never assert done, leading to timeout.

**Fix needed:** Implement `arm_pool_large()` for kernel > 2. This must
run entirely on the ARM since the hardware does not support it.
Add a dispatch check in `eth_server.c` OP_MAXPOOL case:

```c
case OP_MAXPOOL:
    if (L->kernel > 2) {
        rc = arm_pool_large(L,
                            (const uint8_t *)(uintptr_t)cfg.in_addr,
                            (uint8_t       *)(uintptr_t)cfg.out_addr,
                            &prof);
    } else {
        rc = dpu_exec_pool(L, ...);
    }
    break;
```

The `arm_pool_large()` function iterates NCHW: for each (c, oh, ow),
scans the kernel window in the input and writes the max to the output.
Input layout is NCHW (as confirmed by dpu_exec_conv_v4 scatter/gather).

Approximate implementation:
```c
int arm_pool_large(const layer_config_t *L,
                   const uint8_t *in_ddr, uint8_t *out_ddr,
                   dpu_prof_t *prof)
{
    int K = L->kernel, S = L->stride, P = L->pad;
    int C = L->c_in; /* c_in == c_out for pool */
    Xil_DCacheInvalidateRange((UINTPTR)in_ddr, C * L->h_in * L->w_in);
    for (int c = 0; c < C; c++) {
        for (int oh = 0; oh < L->h_out; oh++) {
            for (int ow = 0; ow < L->w_out; ow++) {
                uint8_t mx = 0;
                for (int kh = 0; kh < K; kh++) {
                    int ih = oh * S - P + kh;
                    if (ih < 0 || ih >= L->h_in) continue;
                    for (int kw = 0; kw < K; kw++) {
                        int iw = ow * S - P + kw;
                        if (iw < 0 || iw >= L->w_in) continue;
                        uint8_t v = in_ddr[c * L->h_in * L->w_in + ih * L->w_in + iw];
                        if (v > mx) mx = v;
                    }
                }
                out_ddr[c * L->h_out * L->w_out + oh * L->w_out + ow] = mx;
            }
        }
    }
    Xil_DCacheFlushRange((UINTPTR)out_ddr, C * L->h_out * L->w_out);
    if (prof) prof->n_tiles = 1;
    return DPU_OK;
}
```

**Files:**
- `sw/dpu_exec.c` -- add `arm_pool_large()` function (after line 443)
- `sw/dpu_api.h` -- add prototype for `arm_pool_large()`
- `sw/eth_server.c` line 207-211 -- add kernel>2 dispatch

---

## Bug 2: c_out=255 rejected (layers 225, 240, 254)

**Affected layers:**
- [225] L230 QLinearConv: c_in=256, c_out=255, 52x52, k=1
- [240] L246 QLinearConv: c_in=512, c_out=255, 26x26, k=1
- [254] L261 QLinearConv: c_in=1024, c_out=255, 13x13, k=1

These are the three YOLO detection head layers (85 * 3 = 255 channels).

**Root cause:** After extensive tracing, no firmware code path rejects
c_out=255 specifically. The `layer_config_t.c_out` is `uint16_t` (holds
0-65535). The `NUM_FPGA_LAYERS=255` guard checks `layer_idx`, not c_out.
All pre-dispatch validity checks pass for these layers.

The most probable root cause is that `dpu_exec_conv_v4()` returns
`DPU_ERR_PARAMS` from the `CHK_STATE(0x10, WRAPPER_IDLE, CE_IDLE)` check
at line 224 of `dpu_exec_v4.c`. This happens when the VHDL wrapper FSM
or conv_engine FSM is NOT in IDLE when the function enters. This would
occur if a *previous* layer left the hardware in a stuck state -- most
likely the POOL timeout from layers 182-184 (Bug 1).

The correlation with c_out=255 is a coincidence: these three layers are
the detection heads, which are the last CONV layers in the network. They
run AFTER the SPP pool layers (182-184) which timeout and leave the
wrapper stuck.

**Verification:** Run the network skipping layers 182-184 (or fixing
Bug 1 first). If layers 225/240/254 then pass, the root cause is
confirmed as wrapper stuck state from prior failures.

**Alternative root cause (if layers pass when pool is fixed):** None
found in firmware. If they still fail after fixing Bug 1, investigate:
1. The `n_oc_groups` loop for `c_out % 32 != 0` (c_out=255, remainder=31)
2. The drain output byte count for the last OC group (31 channels)

**Fix needed:** Fix Bug 1 first. If that resolves it, no additional fix
needed for Bug 2. If not, add a DPU reset between failed layers:

```c
/* In eth_server.c, after rc != DPU_OK (line 249): */
if (rc != DPU_OK) {
    dpu_reset();  /* ensure wrapper returns to IDLE */
    /* ... existing error handling ... */
}
```

**Files:**
- `sw/eth_server.c` line 249 -- add `dpu_reset()` on error
- Root fix: resolve Bug 1 first

---

## Bug 3: CONCAT layout wrong (layers 15, 36, 87)

**Affected layers:**
- [15] L020 QLinearConcat: c_in=64, c_out=128, 208x208 (inputs: [14] c=64, [7] c=64)
- [36] L041 QLinearConcat: c_in=64, c_out=128, 104x104 (inputs: [35] c=64, [23] c=64)
- [87] L092 QLinearConcat: c_in=128, c_out=256, 52x52 (inputs: [86] c=128, [43] c=128)

**Root cause:** `arm_concat()` in `dpu_exec.c` (line 516-535) performs
NHWC concatenation, but the DPU activation layout in DDR is **NCHW**.

The function indexes inputs as:
```c
in_a_ddr + (h * L->w_in + w) * c_a   /* NHWC: pixel-interleaved */
```

But `dpu_exec_conv_v4` stores output activations in NCHW:
```c
out_ddr + c * L->h_out * L->w_out + h * L->w_out + w   /* NCHW: planar */
```

This mismatch means arm_concat reads the wrong bytes from each input,
producing an output where channels are scrambled. The "partial"
correctness (max_diff 65-160, not 255) is because some bytes happen to
be in similar positions under both layouts for small spatial regions.

**Fix needed:** Rewrite `arm_concat()` to use NCHW layout. For NCHW
concatenation along the channel axis (axis=1), the operation is simply
copying c_a full planes followed by c_b full planes:

```c
int arm_concat(const layer_config_t *L,
               const uint8_t *in_a_ddr, uint16_t c_a,
               const uint8_t *in_b_ddr, uint16_t c_b,
               uint8_t       *out_ddr,
               dpu_prof_t    *prof)
{
    const int HW = L->h_in * L->w_in;

    Xil_DCacheInvalidateRange((UINTPTR)in_a_ddr, (uint32_t)c_a * HW);
    Xil_DCacheInvalidateRange((UINTPTR)in_b_ddr, (uint32_t)c_b * HW);

    /* NCHW concat axis=1: copy all c_a planes, then all c_b planes */
    memcpy(out_ddr,              in_a_ddr, (uint32_t)c_a * HW);
    memcpy(out_ddr + c_a * HW,  in_b_ddr, (uint32_t)c_b * HW);

    Xil_DCacheFlushRange((UINTPTR)out_ddr, (uint32_t)(c_a + c_b) * HW);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}
```

This replaces the nested h/w loop with two memcpy calls, which is both
correct for NCHW and much faster.

**Files:**
- `sw/dpu_exec.c` lines 516-535 -- replace `arm_concat()` body

---

## Summary

| Bug | Root cause | Severity | Fix complexity |
|-----|-----------|----------|----------------|
| 1 (POOL) | HW pool only supports 2x2; SPP layers need k=5/9/13 | Blocks SPP | Medium: add ARM fallback |
| 2 (c_out=255) | Wrapper stuck from prior pool timeout (Bug 1) | Blocks heads | Low: fix Bug 1 + add reset |
| 3 (CONCAT) | NHWC indexing in arm_concat but data is NCHW | Wrong output | Low: 2 memcpy replaces loop |
