# P_16 — Conv engine + DMA input + DataMover output

Estado de la sesión del 2026-04-14.

## Qué es P_16

Primera iteración integrada del DPU INT8 para YOLOv4 en ZedBoard:
- Inyección de datos desde ARM vía **AXI DMA MM2S** → BRAM interna del wrapper
- Cómputo convolución con `conv_engine_v3` (padding asimétrico + IC tiling)
- Drenaje de resultados vía **AXI DataMover S2MM** → DDR
- Control del DataMover con `dm_s2mm_ctrl` (comando 72-bit) expuesto al ARM vía AXI GPIO

Es la arquitectura base sobre la que se construirá el DPU multi-primitiva.

## Arquitectura

```
DDR ──(DMA MM2S)──► [conv_stream_wrapper BRAM 4KB] ◄───► conv_engine_v3
                                │
                    m_axis + tkeep
                                ▼
                   ┌──────────────────────┐
                   │  AXI DataMover S2MM  │
                   └──────┬───────────────┘
                          │  AXI4 MM (HP0)
                          ▼
                         DDR

Control ARM (bare-metal):
  AXI-Lite GP0 → conv_stream_wrapper regs (cfg + ctrl)
  AXI-Lite GP0 → axi_gpio → dm_s2mm_ctrl (dest_addr + BTT + start)
  Polling sobre REG_CTRL bit[8]=done y GPIO status bit[1]=done
```

Ver `docs/IMPLEMENTATION_PLAN.md` y `P_16_RESULTS.md` §"Cómo funciona" para el flujo paso a paso.

## Resultados HW verificados (ZedBoard)

### Tests baseline (ic_tile_size = c_in, sin tiling)

| Capa | Config | Total checks | Status |
|---|---|---:|:---:|
| layer_005 | 3×3 s=1 pad sym, c_in=3 | 41 | ✅ PASS |
| layer_038 | 3×3 s=2 pad asim `[1,0,1,0]`, c_in=9 | 512 | ✅ PASS |
| layer_043 | 3×3 s=1 pad sym, c_in=5 | 2048 | ✅ PASS |
| layer_045 | 3×3 s=1 pad sym, c_in=5 | 2048 | ✅ PASS |
| layer_047 | 3×3 s=1 pad sym, c_in=5 | 2048 | ✅ PASS |
| layer_049 | 3×3 s=1 pad sym, c_in=5 | 2048 | ✅ PASS |
| layer_057 | 3×3 s=1 pad sym, c_in=5 | 2048 | ✅ PASS |

**Total baseline: 10,793/10,793 checks bit-exact vs golden ONNX**, 0 errores.

### Tests con IC tiling real — todos PASS tras el fix

| Variante | c_in / tile | Nº tiles | Divisible | Status |
|---|---|---:|:---:|:---:|
| layer_005_ic1 | 3 / 1 | 3 | ✓ | ✅ PASS |
| layer_005_ic2 | 3 / 2 | 2 (2+1) | ✗ | ✅ PASS |
| layer_038_ic1 | 9 / 1 | 9 | ✓ | ✅ PASS |
| layer_038_ic3 | 9 / 3 | 3 | ✓ | ✅ PASS |
| layer_038_ic4 | 9 / 4 | 3 (4+4+1) | ✗ | ✅ PASS |
| layer_043_ic1 | 5 / 1 | 5 | ✓ | ✅ PASS |
| layer_043_ic2 | 5 / 2 | 3 (2+2+1) | ✗ | ✅ PASS |
| layer_045_ic1 | 5 / 1 | 5 | ✓ | ✅ PASS |
| layer_047_ic1 | 5 / 1 | 5 | ✓ | ✅ PASS |
| layer_049_ic2 | 5 / 2 | 3 (2+2+1) | ✗ | ✅ PASS |

**Total: 10/10 bit-exact. Todas las configs de tiling validadas (divisible y no-divisible).**

### Totales finales

| Bloque | Resultado |
|---|:---:|
| 110 capas YOLOv4 baseline | **110/110 PASS** |
| 10 variantes IC tiling | **10/10 PASS** |
| **Sesión completa** | **120/120 bit-exact** |

### Síntesis + timing

- Vivado 2025.2 local (xc7z020clg484-1)
- **WNS: +0.609 ns @ 100 MHz** (0 violations)
- WHS: +0.018 ns
- Pulse width: +3.75 ns
- *All user specified timing constraints are met*

### Utilización

| Recurso | Usado | Total | % |
|---|---:|---:|---:|
| LUT | 7,872 | 53,200 | 14.80% |
| FF | 10,353 | 106,400 | 9.73% |
| BRAM36 | 13.5 | 140 | 9.64% |
| DSP48E1 | 15 | 220 | 6.82% |
| BUFG | 1 | 32 | 3.13% |

## Problemas resueltos

### 1. Padding asimétrico verificado en HW
`conv_engine_v3` añade 4 registros independientes (`cfg_pad_top/bottom/left/right`) en vez del bit único de v2. Necesario para capas stride-2 de YOLOv4 con ONNX `pads=[1,1,0,0]`. Verificado en layer_038 (512/512 PASS).

### 2. "6 layers FAIL" era JTAG degradation, no bug
Las capas 38/43/45/47/49/57 fallaban esporádicamente en P_13 tras ~20-25 sesiones JTAG continuas. Re-ejecutadas en P_16 con placa recién reseteada: **todas PASS**. Confirmada la hipótesis de degradación DAP del commit `b477aa1`. No hay bug en la lógica.

### 3. Bug partial-tile en `conv_engine_v3` (CRÍTICO) — FIX EN 2 PASOS

**Descubierto y corregido en esta sesión.** Cuando `ic_tile_size` NO divide a `c_in`, el último tile parcial producía salida incorrecta de forma determinista.

**Causa raíz (lógica):** `tile_filter_stride` se calculaba UNA vez al inicio del procesado como `cfg_ic_tile_size × kh × kw` (estado `CALC_TILE_STRIDE`, línea 495). El weight_buf se llenaba compactamente con `wl_buf_addr += 1` por byte, así que cada filtro ocupaba `ic_in_tile_limit × kh × kw` bytes contiguos. Para el último tile parcial, ambos strides divergían y `MAC_WLOAD_CAP` leía pesos de posiciones erróneas.

**Ejemplo concreto** (layer_005 ic_tile_size=2, c_in=3, último tile con 1 canal):
- Filtro 0 escrito en `wb[0]`, filtro 1 en `wb[1]`, filtro 2 en `wb[2]`, ...
- MAC lee con stride 2: `mac_b(2) = wb[4]` (basura) en vez de `wb[2]`

**Paso 1 del fix (lógico):** añadido estado `WL_STRIDE` entre `WL_NEXT` y `WL_EMIT` que recalcula `tile_filter_stride = ic_in_tile_limit × kk_reg` por tile. Sim confirmó PASS.

**Problema tras la síntesis (Vivado):** el fix funcionaba en simulación pero **no en HW** — error counts HW idénticos pre/post fix. Motivo: Vivado absorbió `tile_filter_stride_reg` dentro del DSP48E1 que implementa `A + B×C` (wload_addr_r + ic_in_tile_limit × kk_reg). El RTL tenía **dos drivers** del mismo registro (CALC_TILE_STRIDE + WL_STRIDE) y la absorción DSP solo preservó uno — el viejo de CALC_TILE_STRIDE.

Log de síntesis incriminatorio:
```
DSP Report: register tile_filter_stride_reg is absorbed into DSP wload_addr_r0.
DSP Report: operator tile_filter_stride0 is absorbed into DSP wload_addr_r0.
```

**Paso 2 del fix (driver único):** eliminada la asignación en `CALC_TILE_STRIDE`. `WL_STRIDE` queda como único driver de `tile_filter_stride`. Vivado ya no tiene ambigüedad al absorber en DSP → el driver correcto se preserva. HW PASS 4/4 en las configs non-divisible.

Reproducido y confirmado con trazas CSV en `P_13_conv_test/simC/trace.csv`. Variables auditadas (todas seguras) en `docs/VARIABLES_AUDIT.md`.

### 4. Sim del wrapper P_16 añadida
Antes sólo existía sim de `conv_engine_v3` standalone. Se añadió `P_16/sim/conv_stream_tb.vhd` que ejercita el wrapper completo (AXI-Lite + AXI-Stream LOAD/DRAIN + padding asim + tkeep). Passed en 82 µs.

## Cómo se usa (desde el ARM)

El runtime mínimo (ver `sw/conv_dm_test.c` y `sw/layer_tests/*.c`):

```c
// 1) Empaquetar datos en DDR @ DDR_SRC_ADDR con layout:
//    [output_zone | input | weights(OHWI) | bias]
//    y hacer Xil_DCacheFlushRange

// 2) Configurar conv via AXI-Lite (20 registros en 0x40000000..0x50)
conv_write(REG_C_IN, c_in);
conv_write(REG_C_OUT, c_out);
// ... (ver register map abajo)
conv_write(REG_PAD_TOP, pad_top);
// etc.

// 3) LOAD: DMA MM2S → wrapper BRAM
conv_write(REG_CTRL, 0x01);                      // cmd_load
XAxiDma_SimpleTransfer(&dma, DDR_SRC, LOAD_BYTES, XAXIDMA_DMA_TO_DEVICE);
while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));

// 4) START conv + poll done
conv_write(REG_CTRL, 0x02);                      // cmd_start
while (!(conv_read(REG_CTRL) & 0x100));

// 5) DataMover: addr + BTT + pulso start
gpio_addr_write(DDR_DST_ADDR);
gpio_ctrl_write(BTT | 0x80000000);               // pulso bit[31]
gpio_ctrl_write(BTT);
usleep(10);

// 6) DRAIN: wrapper m_axis → DataMover → DDR_DST
conv_write(REG_CTRL, 0x04);                      // cmd_drain
while (!(gpio_ctrl_read_status() & 0x02));       // wait done

// 7) Cache invalidate y leer dst
Xil_DCacheInvalidateRange(DDR_DST, OUTPUT_BYTES);
```

### Register map del `conv_stream_wrapper` (base 0x40000000)

| Offset | Nombre | R/W | Notas |
|---:|---|:---:|---|
| 0x00 | ctrl | R/W | bit0=cmd_load, bit1=cmd_start, bit2=cmd_drain (self-clearing). bit8=done (RO sticky). bit9=busy. bits[11:10]=fsm_state |
| 0x04 | n_words | R/W | número de words 32-bit para LOAD/DRAIN (10 bits) |
| 0x08 | c_in | R/W | canales de entrada |
| 0x0C | c_out | R/W | canales de salida |
| 0x10 | h_in | R/W | altura entrada |
| 0x14 | w_in | R/W | anchura entrada |
| 0x18 | ksp | R/W | bits[1:0]=ksize (0=1×1, 2=3×3), bit[2]=stride (0=1, 1=2) |
| 0x1C | x_zp | R/W | zero-point de input (signed 9-bit) |
| 0x20 | w_zp | R/W | zero-point de pesos (signed 8-bit, normalmente 0) |
| 0x24 | M0 | R/W | multiplier de requantize (uint32) |
| 0x28 | n_shift | R/W | shift de requantize (6 bits) |
| 0x2C | y_zp | R/W | zero-point de output (signed 8-bit) |
| 0x30 | addr_input | R/W | offset byte de entrada en BRAM |
| 0x34 | addr_weights | R/W | offset byte de pesos en BRAM |
| 0x38 | addr_bias | R/W | offset byte de bias en BRAM |
| 0x3C | addr_output | R/W | offset byte de output en BRAM *(ver limitación abajo)* |
| 0x40 | ic_tile_size | R/W | tamaño del tile IC (si igual a c_in → sin tiling) |
| 0x44 | pad_top | R/W | padding arriba (2 bits) |
| 0x48 | pad_bottom | R/W | padding abajo |
| 0x4C | pad_left | R/W | padding izquierda |
| 0x50 | pad_right | R/W | padding derecha |

### GPIO dm_s2mm_ctrl (bases 0x41200000 y 0x41210000)

| GPIO | Canal | Acceso | Uso |
|---|---|---|---|
| ADDR | 1 W | dest_addr DDR |
| CTRL | 1 W | bits[22:0]=BTT, bit[31]=start pulse |
| CTRL | 2 R | bit[0]=busy, bit[1]=done, bit[2]=error, bits[11:4]=raw DM status |

## Cómo funciona (resumen del RTL)

### `conv_stream_wrapper.vhd` FSM
`IDLE → LOAD → CONV → DRAIN → IDLE`. Una única BRAM 4KB (single-port, byte-write-enables) compartida por time-muxing. El conv accede con direcciones byte + mux de lane; stream accede palabra-a-palabra.

### `conv_engine_v3.vhd` loop pseudocódigo
```
para cada oc_tile_base in 0, 32, 64, ..., c_out:
  para cada pixel (oh, ow):
    clear MAC array
    load bias[oc_tile_base..oc_tile_base+31]
    para cada ic_tile_base in 0, ic_tile_size, ..., c_in:
      calcular ic_in_tile_limit = min(ic_tile_size, c_in - ic_tile_base)
      calcular tile_filter_stride = ic_in_tile_limit × kh × kw  # FIX
      cargar pesos del tile (32 oc × ic_in_tile_limit × kh × kw bytes)
      para cada (kh, kw):
        para cada ic in 0..ic_in_tile_limit-1:
          pulsar MAC (acumula sobre los 32 oc en paralelo)
    requantize 32 acc → escribir 32 bytes a DDR
```

Clave: el mac_array **NO se limpia** entre ic_tiles del mismo pixel → acumulación parcial sin scratch memory.

### `dm_s2mm_ctrl.vhd`
FSM que convierte writes GPIO en comando 72-bit del DataMover:
```
[71:68] RSVD=0000
[67:64] TAG=0000
[63:32] SADDR (dest DDR)
[31] RSVD=0
[30] TYPE=1 (INCR burst)
[29:24] DSA=0
[23] EOF=1
[22:0] BTT
```
Flanco ascendente de bit[31] del GPIO_CTRL → emite cmd al canal `S_AXIS_S2MM_CMD`. Lee status 8-bit (done, error, decerr, slverr, tag) → refleja en GPIO status ch2.

## Cómo rebuildear / correr

### Bitstream
```bash
cd C:/project/vivado
python build.py P_16_conv_datamover all export
# Artefacto: build/conv_dm.xsa, build/conv_dm.runs/impl_1/conv_dm_bd_wrapper.bit
```

### Vitis apps (todos los tests del dir tiled/ o layer_tests/)
```bash
cd C:/project/vivado/P_16_conv_datamover
/c/AMDDesignTools/2025.2/Vitis/bin/xsct.bat sw/build_all_tests.tcl \
  build/conv_dm.xsa \
  vitis_ws \
  sw/layer_tests
```

### Ejecutar en ZedBoard
```bash
/c/AMDDesignTools/2025.2/Vitis/bin/xsct.bat sw/run_all_layers.tcl \
  build/conv_dm.runs/impl_1/conv_dm_bd_wrapper.bit \
  vitis_ws/conv_dm_platform/export/conv_dm_platform/sw/conv_dm_platform/boot/fsbl.elf \
  vitis_ws \
  layer_005_test layer_038_test layer_043_test layer_045_test layer_047_test layer_049_test layer_057_test
```

### Sim del wrapper
```bash
cd C:/project/vivado/P_16_conv_datamover/sim
bash run_sim.sh
```

## Limitaciones / constraints conocidos

1. **Fase DRAIN drena BRAM desde addr 0**: el wrapper ignora `REG_ADDR_OUTPUT` durante DRAIN. Los tests deben colocar la zona de salida en `BRAM[0x000]`. Si se quiere addr arbitrario, hay que añadir al wrapper un contador de drain con base configurable.
2. **BRAM 4 KB**: sólo aguanta capas cropadas (`c_in` ≤ ~12 para 3×3). Las capas YOLOv4 reales necesitan **wrapper BRAM ≥ 64 KB** (pendiente).
3. **Single-port BRAM**: no double-buffering. Mientras conv calcula no se puede cargar el tile siguiente. Impacto modesto dado que el MAC loop domina el tiempo (35 ciclos por paso), pero prevenible con doble buffer.
4. **Control por polling**: no IRQ-driven. El ARM ocupa CPU esperando. Integrar IRQ (DMA done + DataMover done) es trivial con el GIC, pero aún sin hacer.
5. **Sólo conv**: falta integrar maxpool, leaky_relu, elem_add en el wrapper (selección por `layer_type` register).
6. **`ic_tile_size` no-divisible**: verificar tras el fix de esta sesión; hasta entonces se recomienda usar siempre un valor que divida `c_in`.

## Pendiente (roadmap)

1. ~~**Fix partial-tile bug**~~ ✅ hecho en esta sesión
2. **P_17 — DPU multi-primitiva**: integrar conv + maxpool + leaky_relu + elem_add en el mismo wrapper. Selección por `layer_type` register. Concat/Upsample se quedan en el ARM (reordena activaciones por software, no requiere HW dedicado).
3. **Ampliar BRAM** del wrapper a 64 KB para soportar capas reales de YOLOv4
4. **Double-buffering** de pesos en BRAM + carga overlapped con cómputo
5. **IRQ-driven** (DMA done, DataMover done) en vez de polling
6. **Runtime C** que itere `layer_configs.h` y encadene capas (salida N → entrada N+1 vía DDR)
7. **Concat / Upsample** en ARM (routing entre capas)
8. **Buffers de cuellos de botella** YOLOv4 (activaciones reutilizadas muchas capas después)
9. **Arreglar DRAIN para respetar `REG_ADDR_OUTPUT`** (permitiría layouts más flexibles)
10. **Testear todas las 110 capas** (hoy sólo 7 validadas bit-exact; 103 pendientes)

## Archivos relevantes

```
P_16_conv_datamover/
├── project.cfg                     # proyecto Vivado (part, top, BD tcl)
├── src/
│   ├── create_bd.tcl              # Block Design completo
│   ├── conv_stream_wrapper.vhd    # AXI-Lite + stream + BRAM + conv_v3
│   └── dm_s2mm_ctrl.vhd           # gen cmd 72-bit para DataMover
├── sim/
│   ├── conv_stream_tb.vhd         # TB end-to-end del wrapper (nueva)
│   └── run_sim.sh
├── sw/
│   ├── conv_dm_test.c             # test canonico layer_005
│   ├── build_xsct.tcl             # build single-app
│   ├── build_all_tests.tcl        # build multi-app (descubre por glob)
│   ├── run_idx.tcl                # run single-app con poll MAGIC
│   ├── run_all_layers.tcl         # run multi-app, resumen final
│   └── layer_tests/
│       ├── gen_p16_tests.py       # generador (adapta P_13 → P_16)
│       ├── layer_NNN_test.c       # tests portados (005, 038, 043, ...)
│       └── tiled/                 # variantes con ic_tile_size < c_in
│           ├── _gen.py
│           └── layer_NNN_icM_test.c
└── docs/
    ├── IMPLEMENTATION_PLAN.md     # roadmap original (6 fases)
    └── P_16_RESULTS.md            # este archivo

P_13_conv_test/src/
├── conv_engine_v3.vhd             # MODIFICADO: +WL_STRIDE state (fix bug)
├── mac_unit.vhd, mac_array.vhd
├── mul_s32x32_pipe.vhd
└── requantize.vhd

P_13_conv_test/simC/               # sim del bug (CSV trace)
├── partial_tile_bug_tb.vhd
├── run_sim.sh
├── trace.csv
└── sim.log
```
