# P_19 — DPU + Ethernet + HDMI Integration Plan

Objetivo: un único bitstream para ZedBoard que contenga (a) el DPU multi-primitiva
de P_17, (b) el stack Ethernet/TCP de P_18, y (c) la salida HDMI 720p de P_401, de
forma que el bare-metal en el ARM pueda mostrar la imagen de entrada con bounding
boxes detectadas por el DPU en una pantalla HDMI.

Este documento extiende (no duplica) `P_17_dpu_multi/docs/HDMI_INTEGRATION_PLAN.md`.

---

## 1. Estado heredado

**P_401 (verificado HW 12-abr-2026, REPORTE_HDMI.md):**
- 720p@60Hz visible, license-free, PL-only, ADV7511 vía I2C en PL.
- Pixel clock 74.2268 MHz desde MMCME2 (M=9.000 / D=12.125, error 0.031%).
- Bus de datos de 16 bits hacia el ADV7511 (`hdmi_d[15:0]`).
- En el bitstream actual sólo se transmiten R+G; **B se pierde**. El ADV7511 está
  configurado para 16-bit YCbCr 4:2:2 input + CSC interno → RGB a la salida.
- Módulos RTL reusables: `video_timing.vhd`, `i2c_init.vhd`, `hdmi_top.vhd`
  (skeleton MMCM/ODDR/glue). `color_bars.vhd` se descarta para P_19.
- XDC: `P_401_hdmi_test/vivado/zedboard_hdmi.xdc` (pinout completo y verificado).
- Recursos: 1 MMCM + ~200 LUT, 0 BRAM/DSP.

**P_18 (`P_18_dpu_eth/src/create_bd.tcl`, base de partida):**
- ZedBoard preset, GP0 + HP0, FCLK0=100 MHz, IRQ_F2P, ENET0 + MDIO + reset
  (MIO16-27, MIO52-53, reset MIO9), GPIO MIO.
- AXI DMA MM2S → `dpu_stream_wrapper` s_axis (LOAD).
- `dpu_stream_wrapper` m_axis → AXI DataMover S2MM → DDR.
- `dm_s2mm_ctrl` controlado por dos AXI GPIO (addr / ctrl+status).
- HP0 ya tiene 2 maestros (DMA MM2S + DataMover S2MM). **HP0 saturado para video.**
- IRQ_F2P concat de 3: `mm2s_introut`, `dm_done`, `s2mm_err`. Hay slots libres.

P_18 es la base correcta para P_19 (incluye Ethernet); P_17 era subset sin ETH.

---

## 2. Decisiones de arquitectura para P_19

| Decisión | Valor | Justificación |
|---|---|---|
| Estrategia | Framebuffer en DDR + AXI VDMA MM2S | Toda la lógica de bbox/draw queda en C; el PL solo escanea. Mantiene bit-exactitud con ONNX. |
| Resolución HDMI | 1280×720 nativa (sin scaler) | Reusar 100% timings P_401. |
| Formato framebuffer | RGB888 packed, 4 bytes/pixel (XRGB) | Aligned a 32-bit; VDMA stride simple = 1280·4 = 5120 B; total 3.51 MB por frame. |
| Canvas | 416×416 imagen + bboxes, centrada en lienzo gris 1280×720 | El ARM compone una sola vez por inferencia. |
| Color depth en PL→ADV7511 | 24-bit RGB vía DDR clocking sobre `hdmi_d[15:0]` | Necesario fix vs P_401. Nibble alto del pixel en flanco subida, nibble bajo en bajada de `hdmi_clk`. Cambiar registros ADV7511 al modo 24-bit Style 1 input. |
| Color path alternativo (fallback) | RGB→YCbCr 4:2:2 en PL (3 mults + offsets) y dejar `hdmi_d` como en P_401 | Plan B si DDR clocking del bus de datos da problemas timing. |
| Pixel clock | MMCM dedicada (74.2268 MHz) | Independiente del 100 MHz del DPU. |
| Cruce de dominios | Async FIFO interna del AXI VDMA | VDMA permite `s_axi_lite_aclk≠m_axis_mm2s_aclk≠m_axi_mm2s_aclk`. |
| Puerto HP para VDMA | **HP1** | HP0 ya saturado (DMA + DataMover). Activar `PCW_USE_S_AXI_HP1`. |
| Dirección base framebuffer | `0x1B000000` (DDR alto) | Fuera de pesos (`0x12000000` ~60 MB), input (`0x10000000`), heads (`0x18000000-0x18300000`). 3.5 MB <<< headroom restante. |
| AXI-Lite VDMA | Map en GP0, slot M04 | Añadir 5º MI al `axi_ic_gp0`. |
| I2C ADV7511 | `i2c_init.vhd` tal cual sobre FCLK0 (100 MHz, I2C 100 kHz) | Pines PL `AA18/Y16` no chocan con PS. ENET0 va por MIO, no toca esos pines. Done en LD1. |
| IRQ HDMI | VDMA `mm2s_introut` opcional → concat slot 3 | Útil para tear-free pero no crítico. |

### 2.1 Mapa DDR final P_19
```
0x10000000  Input image 416×416×3       (519 KB)
0x12000000  Weights blob YOLOv4         (~60 MB)
0x18000000  Head 0 / activations            (1 MB)
0x18100000  Head 1                          (1 MB)
0x18200000  Head 2                          (1 MB)
0x1B000000  Framebuffer 1280×720×4      (3.51 MB)  <-- VDMA MM2S
```

### 2.2 Mapa AXI-Lite (GP0, 5 MI tras integrar P_18)
| MI | Slave | Base sugerida |
|----|-------|---------------|
| M00 | axi_dma_0 | `0x40400000` (heredado) |
| M01 | dpu_stream_wrapper | `0x43C00000` |
| M02 | gpio_addr | `0x41200000` |
| M03 | gpio_ctrl | `0x41210000` |
| **M04** | **axi_vdma_0** | **`0x43000000`** (nuevo) |

---

## 3. Snippets create_bd.tcl a añadir sobre P_18

Insertar tras la creación de los GPIO y antes del `assign_bd_address`:

```tcl
# === Habilitar HP1 en el PS ===
set_property -dict [list CONFIG.PCW_USE_S_AXI_HP1 {1}] $zynq

# === MMCM 74.25 MHz para pixel clock ===
# Se instancia desde un módulo VHDL nuevo `hdmi_pclk_gen.vhd` (extracto de hdmi_top.vhd
# de P_401: MMCME2_BASE M=9.000 D=12.125 + BUFG + reset sync). Esto evita que el
# Block Designer toque la primitiva MMCM directamente.
read_vhdl [file join $src_dir hdmi_pclk_gen.vhd]
read_vhdl [file join $src_dir ../../P_401_hdmi_test/src/video_timing.vhd]
read_vhdl [file join $src_dir ../../P_401_hdmi_test/src/i2c_init.vhd]
read_vhdl [file join $src_dir hdmi_out_24bit.vhd]   ;# nuevo: ODDR data + sync pipeline
update_compile_order -fileset sources_1
create_bd_cell -type module -reference hdmi_pclk_gen   pclk_gen_0
create_bd_cell -type module -reference video_timing    vtim_0
create_bd_cell -type module -reference i2c_init        i2c_0
create_bd_cell -type module -reference hdmi_out_24bit  hdmi_out_0

# === AXI VDMA (MM2S only, RGB888-pack 32-bpp) ===
set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma_0]
set_property -dict [list \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_mm2s_genlock_mode {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_linebuffer_depth {2048} \
    CONFIG.c_num_fstores {1} \
    CONFIG.c_use_mm2s_fsync {0} \
    CONFIG.c_include_mm2s_dre {0} \
] $vdma

# === Interconnect HP1: solo VDMA MM2S ===
set ic_hp1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp1]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $ic_hp1

# === Ampliar ic_gp0 a 5 MI ===
set_property -dict [list CONFIG.NUM_MI {5}] $ic_gp0
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M04_AXI] [get_bd_intf_pins axi_vdma_0/S_AXI_LITE]

# === Clocks ===
# pclk_gen genera pclk (74.25 MHz) y locked
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]    [get_bd_pins pclk_gen_0/sys_clk]
connect_bd_net [get_bd_pins pclk_gen_0/pclk]  [get_bd_pins vtim_0/clk] \
                                              [get_bd_pins hdmi_out_0/pclk] \
                                              [get_bd_pins axi_vdma_0/m_axis_mm2s_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]    [get_bd_pins i2c_0/clk] \
                                              [get_bd_pins axi_vdma_0/s_axi_lite_aclk] \
                                              [get_bd_pins axi_vdma_0/m_axi_mm2s_aclk] \
                                              [get_bd_pins ps7/S_AXI_HP1_ACLK] \
                                              [get_bd_pins axi_ic_hp1/ACLK] \
                                              [get_bd_pins axi_ic_hp1/S00_ACLK] \
                                              [get_bd_pins axi_ic_hp1/M00_ACLK]

# === HP1 path: VDMA → IC → PS DDR ===
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_MM2S] [get_bd_intf_pins axi_ic_hp1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp1/M00_AXI]    [get_bd_intf_pins ps7/S_AXI_HP1]

# === Stream VDMA → hdmi_out_0 (clock domain pclk) ===
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins hdmi_out_0/s_axis]

# === Sync/timing y salidas externas ===
connect_bd_net [get_bd_pins vtim_0/hsync]   [get_bd_pins hdmi_out_0/hsync_in]
connect_bd_net [get_bd_pins vtim_0/vsync]   [get_bd_pins hdmi_out_0/vsync_in]
connect_bd_net [get_bd_pins vtim_0/de]      [get_bd_pins hdmi_out_0/de_in]
connect_bd_net [get_bd_pins vtim_0/pixel_x] [get_bd_pins hdmi_out_0/pixel_x]
connect_bd_net [get_bd_pins vtim_0/pixel_y] [get_bd_pins hdmi_out_0/pixel_y]

# === Make external: HDMI pinout + I2C ===
make_bd_pins_external  [get_bd_pins hdmi_out_0/hdmi_clk hdmi_out_0/hdmi_d \
                                    hdmi_out_0/hdmi_de hdmi_out_0/hdmi_hsync \
                                    hdmi_out_0/hdmi_vsync hdmi_out_0/hdmi_spdif]
make_bd_pins_external  [get_bd_pins i2c_0/scl i2c_0/sda]
make_bd_pins_external  [get_bd_pins hdmi_out_0/hdmi_int_n]

# === IRQ opcional ===
set_property CONFIG.NUM_PORTS {4} $concat
connect_bd_net [get_bd_pins axi_vdma_0/mm2s_introut] [get_bd_pins xlconcat_0/In3]
```

`hdmi_out_24bit.vhd` (nuevo, no extenso): consume AXI-Stream 32-bit (XRGB), recibe
`pixel_x/pixel_y/de/hsync/vsync` del `video_timing`, sincroniza el TREADY al `de`,
y emite `hdmi_d[15:0]` por flancos DDR (R[7:0]+G[7:4] en flanco+, G[3:0]+B[7:0] en
flanco–) más `hdmi_clk` por ODDR. Si el DDR-data falla timing, fallback: instanciar
`rgb_to_ycbcr422.vhd` y mantener mapping P_401.

---

## 4. Constraints XDC adicionales (P_19)

Reusar **íntegro** `P_401_hdmi_test/vivado/zedboard_hdmi.xdc` (pines HDMI + I2C +
LEDs) y añadir los pines Ethernet (ya están en MIO, no hay PL pins). El XDC P_18
(LEDs/UART) se merge sin choques: HDMI usa pins distintos.

```tcl
# Renombrar puertos externos al hacer make_bd_pins_external:
set_property PACKAGE_PIN W18 [get_ports hdmi_clk_0]
# ... resto idéntico al XDC P_401, sólo cambiar nombres con sufijo _0 si Vivado
# añade el sufijo automáticamente al exportar.
# False paths I2C ya cubiertos por XDC P_401.
# Añadir agrupación de relojes para evitar análisis cruzado:
set_clock_groups -asynchronous -group [get_clocks pclk] \
                               -group [get_clocks clk_fpga_0]
```

---

## 5. Recursos extra estimados (sobre P_18)

| Bloque | LUT | FF | BRAM | DSP | Notas |
|---|---|---|---|---|---|
| MMCM + BUFG (74.25 MHz) | 0 | 0 | 0 | 0 | 1/4 MMCM Z-7020 |
| video_timing + i2c_init | ~250 | ~200 | 0 | 0 | Reuse P_401 |
| AXI VDMA (1ch MM2S, async, 64-bit MM, 32-bit AXIS, line buf 2048) | ~3000 | ~3500 | ~6 | 0 | LogiCORE Xilinx |
| hdmi_out_24bit (DDR data, sync pipe, ready gate) | ~250 | ~200 | 0 | 0 | Nuevo |
| ic_hp1 + ampliación ic_gp0 (4→5 MI) | ~600 | ~700 | 0 | 0 | |
| **Total extra** | **~4100 LUT** | **~4600 FF** | **~6 BRAM** | **0 DSP** | |

Z-7020 disponibles: 53k LUT, 106k FF, 140 BRAM, 220 DSP. Holgura sobrada.

Ancho de banda HP1: 1280·720·4·60 Hz = **221 MB/s** sostenido. HP1 64-bit @ 100 MHz
= 800 MB/s pico. OK. HP0 (DMA+DataMover) sigue libre de carga de video.

---

## 6. Boot sequence en el ARM (extiende firmware P_18)

1. FSBL → `main()`.
2. Init Ethernet stack (lwIP raw, P_18).
3. Init DPU (P_17 register sequence).
4. Init VDMA: `XAxiVdma_DmaConfig{HoriSizeInput=5120, VertSizeInput=720, Stride=5120, FrameStoreStartAddr[0]=0x1B000000, EnableCircularBuf=1}`. Start MM2S.
5. Pintar canvas inicial (gris) en framebuffer y `Xil_DCacheFlushRange`.
6. Bucle TCP:
   - Recibir `WRITE_DDR` imagen (0x10000000) y pesos (0x12000000).
   - `RUN_NETWORK` → DPU produce heads.
   - CPU NMS → bbox list.
   - Compositor C: copia 416×416×3 en framebuffer (centrado, RGB→XRGB) y dibuja
     rectángulos de bbox (bucles de 1px de grosor sobre el framebuffer).
   - `Xil_DCacheFlushRange(0x1B000000, 0x380000)`.
   - Responder `ACK` por TCP. VDMA continúa scanning solo.

---

## 7. Riesgos y blockers

1. **24-bit color**: el bitstream P_401 tira B. Soluciones (orden de preferencia):
   a. **DDR clocking sobre `hdmi_d`** y reconfigurar ADV7511 a Input ID que acepte
      24-bit Style 1 sobre 16 pines (datasheet ADV7511 Tabla 11/12). Cambia ~5
      registros del init: `0x15`, `0x16`, `0x48`, `0x16`. Riesgo: timing setup/hold
      del bus DDR a 74.25 MHz sobre LVCMOS33, posibles violaciones.
   b. **RGB→YCbCr 4:2:2 en PL** y mantener mapping actual + CSC del ADV7511. Más
      lógica (3 mults+sumas) pero usa la config I2C ya verificada.
   Decisión recomendada: empezar con (b) por menor riesgo HW; iterar a (a) si se
   quiere chroma sin submuestreo.
2. **I2C bus**: SCL/SDA en pines PL `AA18/Y16`, sin conflicto con PS-I2C ni con
   ENET0 (MIO16-27, 52-53). Comprobado.
3. **CDC 100 MHz ↔ 74.25 MHz**: cubierto por async FIFO interno del VDMA. El
   `video_timing` y `hdmi_out_24bit` viven sólo en `pclk`. Ningún path combinacional
   cruza dominios. Añadir `set_clock_groups -asynchronous`.
4. **MMCM count**: Z-7020 tiene 4 MMCM. Sólo se usa 1 nueva (FCLK0 viene del PS,
   no consume MMCM PL). Sobran 3.
5. **Cache coherency framebuffer**: Xil_DCacheFlushRange tras cada compositor; sin
   esto, la pantalla mostrará basura cacheada.
6. **HP1 vs DPU latency**: VDMA es prioridad media; DPU usa HP0. No hay contención.
7. **Tearing**: si se actualiza framebuffer mientras VDMA escanea hay flicker. Mitigación: doble buffer en DDR (otros 3.5 MB) y conmutar `FrameStoreStartAddr` en VSYNC. No bloqueante para v1.
8. **Power-cycle ZedBoard**: P_401 no lo necesita, pero P_200 IRQ test sí. Verificar que sumar VDMA no introduce el mismo síntoma; si pasa, power-cycle obligatorio antes de cada test (recordatorio operativo).
9. **Vivado VLNV**: `axi_vdma:6.3` puede variar de versión en 2025.2.1; usar el patrón `foreach vlnv` igual que con DataMover en P_18.

---

## 8. Deliverables a producir cuando se ejecute (no en este turno)

- `P_19_dpu_full/src/create_bd.tcl` (copiar P_18 + parches sección 3).
- `P_19_dpu_full/src/hdmi_pclk_gen.vhd` (extracto MMCM/BUFG/reset de P_401).
- `P_19_dpu_full/src/hdmi_out_24bit.vhd` (nuevo, AXIS→DDR pixel bus).
- `P_19_dpu_full/src/rgb_to_ycbcr422.vhd` (opcional, plan B color).
- `P_19_dpu_full/vivado/zedboard_p19.xdc` (merge P_18 + P_401 + clock groups).
- `P_19_dpu_full/sw/main.c` (extensión del firmware P_18 con init VDMA + compositor + bbox draw).
- `P_19_dpu_full/host/draw_bboxes_pc.py` queda obsoleto (ahora se dibuja en board).

---

## 9. Fuentes consultadas

- `P_401_hdmi_test/REPORTE_HDMI.md`, `src/{hdmi_top,video_timing,i2c_init,color_bars}.vhd`, `vivado/{build.tcl,zedboard_hdmi.xdc}`.
- `P_17_dpu_multi/docs/HDMI_INTEGRATION_PLAN.md` (plan turno nocturno, base).
- `P_17_dpu_multi/docs/P_17_ARCHITECTURE.md` (mapa registros DPU).
- `P_18_dpu_eth/src/create_bd.tcl` (BD base con ENET0 + GP0/HP0).
- `P_18_dpu_eth/docs/ETH_PROTOCOL.md` (mapa DDR de pesos/heads).
- Xilinx PG020 (AXI VDMA), ADV7511 datasheet (vía registro map P_401).
