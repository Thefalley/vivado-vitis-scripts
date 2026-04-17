# P_30_A — Registro de cambios, pruebas y plan futuro

Fecha inicio: 2026-04-17
Última actualización: 2026-04-17 22:00

---

## 1. Cambios realizados

### 1.1 conv_engine_v4.vhd (basado en conv_engine_v3)

| Cambio | Líneas | Motivo |
|---|---|---|
| Entity renombrada a `conv_engine_v4` | todo | Diferenciar de v3 |
| Puerto `cfg_no_clear : in std_logic` | 124 | IC tiling ARM: no limpiar MAC entre ic_tiles |
| Puerto `cfg_no_requantize : in std_logic` | 125 | IC tiling ARM: skip requantize en ic_tiles intermedios |
| Puertos `ext_wb_addr/data/we` | 160-163 | Escritura externa al wb_ram desde FIFO_W |
| FSM INIT_PIXEL_1: `mac_clr` condicional | 570 | Si `cfg_no_clear='1'`, no limpia acumuladores |
| FSM IC_TILE_ADV: skip requantize | 880-884 | Si `cfg_no_requantize='1'`, va a DONE sin requantize |
| p_wb_bram: mux ext_wb vs wb_we | 350-370 | Dos fuentes de escritura al wb_ram |
| **PENDIENTE**: Reemplazar array wb_ram por `xpm_memory_tdpram` | — | Fix timing: el mux impide inferencia BRAM36 |

**Verificación**: XSIM bit-exact layer 0 (512/512 OK) + layer 2 (1024/1024 OK)

### 1.2 fifo_weights.vhd (nuevo)

| Aspecto | Detalle |
|---|---|
| Función | FIFO BRAM entre DMA_W y wrapper (AXI-Stream 32b in, byte out) |
| Patrón | P_102 handshake (valid/ready) |
| Profundidad | 512 words (configurable via generic DEPTH_LOG2) |
| Deserialización | 32 bits → 4 bytes secuenciales (LSB first) |
| Backpressure | s_axis_tready='0' cuando full; m_valid='0' cuando empty |
| Líneas | 176 |

**Verificación**: Compila limpio en xvhdl. Test standalone pendiente.

### 1.3 dpu_stream_wrapper_v4.vhd (basado en wrapper P_18)

| Cambio | Motivo |
|---|---|
| BRAM_DEPTH: 1024 → 2048 (4 KB → 8 KB) | Bias de c_out=1024 = 4 KB, no cabía |
| Instancia conv_engine_v3 → conv_engine_v4 | Usar puertos nuevos |
| Puertos ext_wb_* conectados al conv | Escritura wb_ram desde FIFO |
| Registros REG_NO_CLEAR (0x68), REG_NO_REQUANTIZE (0x6C), REG_WB_N_BYTES (0x70) | Control IC tiling desde ARM |
| Comando CMD_LOAD_WEIGHTS (bit 3 de REG_CTRL) | Nuevo estado para cargar pesos |
| Estado S_LOAD_WEIGHTS en FSM | Lee de w_stream, escribe a ext_wb del conv |
| Puerto w_stream_data_i/valid_i/ready_o | Interface con FIFO_W |
| **BUG CONOCIDO**: Address signals son 10 bits (solo 1024 words accesibles de 2048) | Fix en progreso |

**Verificación**: Compila limpio con todo el stack (12 archivos). Sintetiza OK.

### 1.4 create_bd.tcl (Block Design)

| Cambio | Motivo |
|---|---|
| DMA_W nuevo (axi_dma_w, MM2S only) | Streaming de pesos a FIFO |
| fifo_weights_0 (module reference) | Entre DMA_W y wrapper |
| HP1 habilitado en Zynq PS | Puerto AXI para DMA_W |
| Interconnect ic_hp1 nuevo | DMA_W → HP1 → DDR |
| GP0 expandido a 5 masters (M04 para DMA_W ctrl) | Control register del DMA_W |
| IRQ concat a 4 puertos (+DMA_W mm2s_introut) | Interrupción DMA_W |
| Sources: solo v4 (eliminados v1/v2/v3 legacy) | Sin duplicados |

**Verificación**: BD creado OK en Vivado GUI. Validate_bd_design OK.

### 1.5 dpu_exec_v4.c (firmware ARM, nuevo)

| Aspecto | Detalle |
|---|---|
| 2 DMAs | g_dma_in (input+bias→BRAM) + g_dma_w (pesos→FIFO→wb_ram) |
| IC tiling | Loop ARM por ic_tiles; cada tile carga pesos parciales via DMA_W |
| Flags | REG_NO_CLEAR y REG_NO_REQUANTIZE controlados por is_first/is_last |
| Spatial tiling | Loop H+W con pads asimétricos (heredado de P_18 tiled) |
| Input extraction | NCHW canal por canal (fix del bug de P_18) |
| Output composition | NCHW (fix del bug de P_18) |
| Cache coherence | Xil_DCacheInvalidateRange antes de cada memcpy |

**Verificación**: No compilado aún (depende de BSP con xparameters.h del XSA).

---

## 2. Pruebas realizadas

### 2.1 Simulación XSIM

| Test | Resultado | Vectores |
|---|---|---|
| conv_engine_v4 layer 0 (regresión, stride=1) | **512/512 OK** | onnx_refs layer_001→layer_002 |
| conv_engine_v4 layer 2 (stride=2, pesos 18 KB) | **1024/1024 OK** | onnx_refs layer_003→layer_004 |
| conv_engine_v4 layer 0 post-fix timing mux | **512/512 OK** | mismos vectores |

Todos contra datos ONNX reales de `yolov4_int8_qop.onnx`.

### 2.2 Síntesis + Implementación (Build 1)

```
Fecha:       2026-04-17 19:21 — 21:47
SYNTH:       Complete ✅
IMPL:        write_bitstream Complete ✅
WNS:         -0.647 ns ❌ (timing violation)
Critical:    wb_addr_reg → RAMD64E (distributed RAM por mux dual-write)
BIT:         generado (extraído de XSA)
XSA:         p30a_dpu.xsa (979 KB)
Errors:      0
```

### 2.3 Test en board

**Pendiente** — bitstream disponible pero firmware no compilado aún.

---

## 3. Bugs encontrados durante P_30_A

| # | Bug | Estado | Fix |
|---|---|---|---|
| 1 | Entity duplicada `dpu_stream_wrapper` (v3 + v4 en src/) | ✅ Fijado | Borrar v3/v2/v1 de src/ |
| 2 | BD ya existía al re-crear | ✅ Fijado | `remove_bd_design` antes de `create_bd_design` |
| 3 | Address BRAM 10 bits para BRAM_DEPTH=2048 | 🔄 En progreso | Agent ampliando a 11 bits |
| 4 | wb_ram inferido como distributed RAM (WNS -0.647) | 🔄 En progreso | Agent reemplazando por xpm_memory_tdpram |
| 5 | Re-síntesis falló por rm -rf de runs/ | Conocido | No borrar runs; usar reset_run en Vivado |

---

## 4. Agentes activos ahora mismo

| Agente | Tarea | Archivos que toca |
|---|---|---|
| 1 | Reemplazar wb_ram array por `xpm_memory_tdpram` | conv_engine_v4.vhd |
| 2 | Ampliar address signals de 10 a 11 bits | dpu_stream_wrapper_v4.vhd |
| 3 | Preparar firmware ARM (copiar sources + build script) | P_30_A/sw/*.c, *.h, *.tcl |

---

## 5. Plan inmediato (próximas horas)

### 5.1 Cuando terminen los 3 agentes
1. Aplicar cambios del xpm_memory al conv_engine_v4
2. Aplicar fix address 11 bits al wrapper
3. Verificar compilación xvhdl de todo el stack
4. Re-run XSIM layer 0 + layer 2 (regresión)
5. Re-sintetizar en Vivado
6. Verificar WNS > 0

### 5.2 Build firmware
1. Generar BSP con xsct (build_vitis.tcl + XSA)
2. Compilar dpu_exec_v4.c + eth_server.c + main.c
3. Generar FSBL

### 5.3 Test en board (ZedBoard)
1. Programar con hard_reset.tcl (bit + FSBL + ELF)
2. Verificar Ethernet (ping + TCP)
3. Layer 0 bit-exact (regresión P_18: CRC 0x8FACA837)
4. Layer 1 LEAKY bit-exact (regresión: CRC 0xF51B4D0C)
5. **Layer 2 CONV stride=2** (primera vez: pesos 18 KB via FIFO_W)
6. Si OK: run_all_layers.py con las primeras 20 capas
7. Si OK: 255 capas completas

---

## 6. Plan medio plazo (próximos días)

### 6.1 Validación completa
- 255/255 capas bit-exact vs ONNX
- Incluye: 110 CONV, 107 LEAKY, 23 ADD, 10 CONCAT, 3 MAXPOOL, 2 RESIZE
- Orquestador: `host/run_all_layers.py` con allocator DDR y mapping ONNX

### 6.2 Performance
- Medir tiempo total de inferencia (255 capas)
- Comparar: Ethernet load (64 MB pesos) + compute + read heads
- Objetivo: < 30 s por imagen (hoy layer 0 sola = 10.8 s)

### 6.3 Decodificación YOLOv4
- 3 heads (52×52, 26×26, 13×13) → bboxes
- NMS (Non-Maximum Suppression)
- Puede correr en PC (Python) o en ARM

### 6.4 Salida HDMI (P_19)
- Framebuffer 720p RGB888
- Dibujar bboxes sobre imagen original
- ADV7511 I2C init (ya hecho en P_401)

### 6.5 P_30_B (opción alternativa)
- 3 FIFOs + 3 DMAs (pesos/input/bias separados)
- Más escalable para redes más grandes
- Solo si P_30_A no es suficiente

---

## 7. Archivos del proyecto

```
P_30_A/
├── src/                              ← RTL (12 archivos VHDL + 1 TCL)
│   ├── conv_engine_v4.vhd           ← v3 + flags + ext_wb (EN MODIFICACIÓN: xpm_memory)
│   ├── fifo_weights.vhd             ← FIFO BRAM para pesos (nuevo)
│   ├── dpu_stream_wrapper_v4.vhd    ← wrapper 8KB + S_LOAD_WEIGHTS (EN MODIFICACIÓN: addr 11b)
│   ├── dm_s2mm_ctrl.vhd             ← sin cambios
│   ├── mac_unit.vhd                 ← sin cambios
│   ├── mac_array.vhd                ← sin cambios
│   ├── mul_s32x32_pipe.vhd          ← sin cambios
│   ├── mul_s9xu30_pipe.vhd          ← sin cambios
│   ├── requantize.vhd               ← sin cambios
│   ├── leaky_relu.vhd               ← sin cambios
│   ├── maxpool_unit.vhd             ← sin cambios
│   ├── elem_add.vhd                 ← sin cambios
│   └── create_bd.tcl                ← BD con 2 DMAs + FIFO + HP1
├── sim/                              ← Testbenches + vectores
│   ├── conv_v4_layer0_tb.vhd        ← regresión v4 = v3 (512/512 OK)
│   ├── conv_v4_layer2_tb.vhd        ← stride=2, pesos 18 KB (1024/1024 OK)
│   ├── vectors_layer0/              ← hex files del ONNX layer 0
│   ├── vectors_layer2/              ← hex files del ONNX layer 2
│   ├── run_sim_layer2.sh            ← script batch XSIM
│   └── *.log, *.backup.*            ← logs de simulaciones
├── sw/                               ← Firmware ARM (EN PREPARACIÓN por agente)
│   └── dpu_exec_v4.c                ← runtime con IC tiling via 2 DMAs
├── build/                            ← Vivado project + outputs
│   ├── p30a_dpu.xpr                 ← proyecto Vivado
│   ├── p30a_dpu.xsa                 ← hardware platform (979 KB)
│   ├── xsa_extract/p30a_dpu.bit     ← bitstream extraído
│   ├── run_all.tcl                  ← script synth+impl batch
│   └── vivado_run.log               ← log de la primera build
├── docs/
│   ├── ESPECIFICACION.md            ← requisitos + reglas + prohibiciones
│   ├── ARCH_V4_FIFOS.md            ← diseño arquitectural (con diagrama secuencia)
│   └── CAMBIOS_Y_PRUEBAS.md        ← este archivo
└── README.md                        ← overview + ejemplos concretos

Referencia cruzada:
  ONNX: C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx
  Refs:  C:/project/vivado/P_18_dpu_eth/host/onnx_refs/ (263 tensores)
  Blob:  C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin (64 MB)
  P_18:  C:/project/vivado/P_18_dpu_eth/ (base verificada, layers 0+1 bit-exact)
  P_102: C:/project/vivado/P_102_bram_ctrl_v2/ (patrón FIFO handshake)
```

---

## 8. Commits del proyecto

```
8ecde9c  P_30_A: fix timing WNS — wb_ram mux con variables dentro del process
19dd625  P_30_A: limpieza RTL (sin legacy v1/v2/v3) + BD validado en Vivado
106e0f8  P_30_A: firmware dpu_exec_v4.c + BD completo
1f01504  P_30_A: wrapper_v4 compila (BRAM 8KB + S_LOAD_WEIGHTS + FIFO port)
1771c62  P_30_A: conv_engine_v4 bit-exact layers 0 y 2 en XSIM
ec45d41  P_30_B: spec + README de arquitectura 3 FIFOs + 3 DMAs
d38284b  P_18: RTL local + punto de control pre-IC-tiling
3b91a43  P_18 Ethernet + CONV + LEAKY bit-exact 1:1 vs ONNX YOLOv4
```
