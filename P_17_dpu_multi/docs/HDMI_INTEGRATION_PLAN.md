# P_17 DPU + HDMI Integration Plan

Goal: display the YOLOv4 input image (416x416) with detected bboxes drawn on
top, live on a monitor connected to the ZedBoard HDMI output, while keeping
the DPU detections bit-exact vs the ONNX reference.

Status of dependencies:
- P_17 DPU multi: AXI-Lite GP0 + HP0 (DMA MM2S + DataMover S2MM), DDR-based.
- P_401 HDMI test: HW-VERIFIED on ZedBoard 12-Apr-2026 (REPORTE_HDMI.md). 720p@60Hz visible. PL-only, no PS dependency. No power-cycle / special boot needed beyond programming the bitstream and waiting ~200 ms for I2C init.

---

## 1. Summary of P_401 architecture

- Resolution: 1280x720 @ 60 Hz, CEA-861 timing (H_TOTAL=1650, V_TOTAL=750).
- Pixel clock: 74.2268 MHz from MMCME2_BASE (M=9.000, D=12.125, sys_clk 100 MHz, error 0.031%).
- Encoder chip: ADV7511 (external HDMI transmitter, license-free).
- I2C config: pure-PL FSM (i2c_init.vhd) writes 31 registers at boot via hdmi_scl/hdmi_sda (PL pins AA18/Y16, with PULLUP). Done in ~200 ms.
- Pixel data: 16-bit bus (hdmi_d[15:0]) on PL bank pins; ADV7511 configured as YCbCr 4:2:2 input with internal CSC -> RGB. The current bitstream sends only R+G (B lost) — this is a "future improvement" noted in REPORTE_HDMI.md and must be addressed for color-correct image display.
- Sync/DE: hdmi_de=U16, hdmi_hsync=V17, hdmi_vsync=W17, hdmi_clk=W18 via ODDR.
- Source modules: video_timing.vhd (counters 1280x720, DE), color_bars.vhd (test pattern, 1-cycle latency), hdmi_top.vhd (MMCM + ODDR + I2C glue).
- Resources: 1 MMCM, ~200 LUTs, 0 BRAM. Negligible.

---

## 2. Proposed integration — three options

### Option A — Two-bitstream flow (load HDMI bitstream after DPU)
ARM runs full inference with P_17 bitstream, stores result image+bboxes in DDR, then ARM reprograms PL with a P_17+HDMI bitstream that has VDMA pointing to that DDR buffer. Simple but requires re-program pause and loses DPU.

### Option B — Unified bitstream, DPU + HDMI concurrent
Single PL design: P_17 (HP0) + AXI VDMA (HP1) + HDMI pipeline + ADV7511 I2C. DDR shared, PS-controlled. Most elegant; supports re-running inference + live update without re-program.

### Option C — Post-process on ARM, framebuffer in DDR (RECOMMENDED)
Same as B at the HW level. ARM (bare-metal C, runtime/) does:
1. Run P_17 layers end-to-end (already works, bit-exact vs ONNX).
2. Compute bbox list from final tensors (NMS in C — same impl as ONNX reference, no hardware reordering).
3. memcpy the original 416x416x3 RGB image into a 1280x720x3 framebuffer in DDR (centered, padded with gray). Then draw rectangles by writing 1-pixel-thick lines into the framebuffer (just plain CPU loop on uncached/DDR pointer or with Xil_DCacheFlushRange after).
4. Configure VDMA once (S2MM disabled, MM2S enabled, base = framebuffer phys addr, stride = 1280*3) and start it. After this, HDMI runs forever from DDR; re-running inference just rewrites the buffer — no PL change.

Why C beats B in our context: **all bbox math stays in software**, identical to the ONNX numeric pipeline. Zero risk of introducing PL-side rounding that breaks the 1:1 match. The PL just acts as a frame scanner.

Why C beats A: no re-program cycle, ARM can refresh frame on demand, supports live video later (camera -> DPU -> screen) without architectural change.

**Recommendation: Option C.**

---

## 3. Resource budget (Option C, on top of P_17)

| Block | LUT | FF | BRAM | DSP | Notes |
|---|---|---|---|---|---|
| MMCM (74.25 MHz pclk) | 0 | 0 | 0 | 0 | 1 MMCM primitive (2 free on Z-7020) |
| video_timing + sync pipe | ~50 | ~50 | 0 | 0 | reuse P_401 |
| AXI VDMA (1 ch, MM2S only, 1920px line, 24bpp) | ~3000 | ~3500 | ~6 | 0 | Xilinx IP, async clocks |
| Pixel-format / RGB-to-YCbCr 4:2:2 (or DDR 24-bit) | ~300 | ~200 | 0 | 4 | needed for full color (P_401 only does R+G) |
| ADV7511 I2C init | ~200 | ~150 | 0 | 0 | reuse P_401 i2c_init.vhd as-is |
| ODDR clk forwarding | 0 | 0 | 0 | 0 | 1 ODDR primitive |
| **Total extra** | **~3500 LUT** | **~3900 FF** | **~6 BRAM** | **4 DSP** | well within Z-7020 budget |

Framebuffer: 1280*720*3 = **2.76 MB** in DDR (zynq has 512 MB). NOT in BRAM.
For the 416x416 image alone: 416*416*3 = **519 KB** — also DDR (BRAM=140 KB total on Z-7020 is too small anyway for 720p).

Bandwidth: 1280*720*3 * 60 Hz = **165 MB/s** sustained read.
- HP port = 64-bit @ 100 MHz = 800 MB/s peak. 165 MB/s leaves 635 MB/s headroom.
- HP0 is already used by P_17 (DMA MM2S + DataMover S2MM). Use **HP1 for VDMA** — confirmed free in P_17/src/create_bd.tcl (only HP0 enabled). No contention with DPU traffic.

Pixel clock: dedicated MMCM, fully independent of the existing 100 MHz DPU clock. Async crossing inside the VDMA IP (async FIFO) handles it.

---

## 4. Risks / blockers

1. **P_401 16-bit color limitation.** Current P_401 drops the blue channel. For a real bbox demo this is unacceptable. Two fixes documented but not yet implemented:
   - DDR clocking on hdmi_d to send 24 bits per cycle (true RGB 4:4:4).
   - Or RGB->YCbCr 4:2:2 in PL, then ADV7511 CSC back to RGB.
   The DDR 24-bit option needs new PL logic (~1 day). The 4:2:2 option needs an RGB->YCbCr 8-bit converter (3 multipliers + offsets, ~half day).
2. **I2C bus**: hdmi_scl/sda are PL-only on ZedBoard, no conflict with PS I2C, no conflict with Vitis. Safe to keep i2c_init.vhd as-is.
3. **MMCM count**: Z-7020 has 4 MMCM. P_17 uses FCLK0 only; adding 1 MMCM for pclk leaves 2 free.
4. **Cache coherency**: ARM writes framebuffer through L1/L2; must Xil_DCacheFlushRange before VDMA reads. Standard pattern, not a blocker.
5. **No power cycle needed** — P_401 boots clean from JTAG program. Will integrate cleanly with the existing P_17 program.tcl flow.
6. **VDMA license**: AXI VDMA is Xilinx LogiCORE included with Vivado, no extra license.

---

## 5. Boot sequence (Option C)

1. JTAG program unified bitstream (P_17 + VDMA + HDMI + I2C).
2. PL: MMCM lock (~1 ms), I2C init writes 31 ADV7511 regs (~200 ms), VDMA idle.
3. Vitis loads bare-metal ELF: FSBL -> main().
4. main() initializes DPU registers (P_17 already-working sequence).
5. main() loads input image (416x416 RGB) into DDR.
6. main() runs all 110 YOLOv4 layers via P_17, gets final tensors.
7. main() runs CPU-side NMS, produces bbox list.
8. main() composites: copy/pad image to 1280x720 framebuffer, draw bbox rectangles.
9. Xil_DCacheFlushRange(framebuffer, 2.76 MB).
10. main() programs VDMA: base=framebuffer, hsize=3840, vsize=720, stride=3840, MM2S enable.
11. HDMI shows the result. Subsequent inferences just rewrite framebuffer + flush; VDMA keeps scanning forever.

---

## 6. Estimated complexity

| Phase | Effort |
|---|---|
| 6.1 Fix P_401 to 24-bit RGB (DDR clocking on hdmi_d) | 0.5 - 1 day |
| 6.2 Add VDMA + connect to P_17 BD on HP1 | 0.5 day |
| 6.3 Wire i2c_init/video_timing/MMCM into P_17 top | 0.5 day |
| 6.4 Bare-metal C: framebuffer compositor + bbox draw + VDMA cfg | 1 day |
| 6.5 HW bring-up + first frame | 0.5 day |
| 6.6 End-to-end test with real YOLOv4 image | 0.5 day |
| **Total** | **~4 days of focused work** |

This is a "nice-to-have" so it should not block other agents. Reasonable to defer until P_17 inference is fully verified end-to-end.

---

## 7. Sources cited

- C:/project/vivado/P_401_hdmi_test/REPORTE_HDMI.md — HW-verified status, ADV7511 register map, pinout.
- C:/project/vivado/P_401_hdmi_test/GUIA_OPERATIVA.md — boot sequence, LED diagnostics.
- C:/project/vivado/P_401_hdmi_test/src/{hdmi_top,video_timing,color_bars,i2c_init}.vhd — RTL to reuse.
- C:/project/vivado/P_401_hdmi_test/vivado/zedboard_hdmi.xdc — pin constraints to merge.
- C:/project/vivado/P_17_dpu_multi/docs/P_17_ARCHITECTURE.md — DPU register map and HP0 usage.
- C:/project/vivado/P_17_dpu_multi/src/create_bd.tcl — confirms HP0-only, HP1/2/3 free for VDMA.
- Xilinx PG020 (AXI VDMA) and ADV7511 datasheet (referenced via P_401 register set).
