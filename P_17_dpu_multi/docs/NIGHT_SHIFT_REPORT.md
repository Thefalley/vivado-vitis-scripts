# P_17 — Turno de noche 2026-04-14 → 2026-04-15

Reporte masivo del trabajo nocturno. Se actualiza a medida que termina cada agente y cada build.

---

## 0. Estado de partida (heredado de la jornada)

### P_16 — CERRADO
- ✅ Commit `7bb7408`, tag `p_16_verified`
- ✅ **120/120 PASS bit-exact** (110 capas YOLOv4 baseline + 10 variantes IC tiling)
- ✅ Fix partial-tile bug en conv_engine_v3 validado HW (4/4 non-divisible PASS tras fix)
- ✅ JTAG degradation resuelto con `rst -system` loop
- ✅ Docs `P_16_RESULTS.md`, `VARIABLES_AUDIT.md`

### P_17 — ARRANCADO
- ✅ Commit `de7c964`: skeleton + arquitectura
- ✅ `P_17_ARCHITECTURE.md` con plan en 6 fases
- ✅ `PRIMITIVE_REUSE_REPORT.md`: decisión de NO tocar primitivas core, re-escribir wrappers
- 🔄 Fase 1 en build (synth+impl+bit)

---

## 1. Objetivo de la noche

**Meta principal:** montar el DPU multi-primitiva y **ejecutar YOLOv4 completo end-to-end** en la ZedBoard con bit-exactitud vs ONNX, incluyendo:
- Las 4 primitivas HW (conv, leaky_relu, maxpool, elem_add)
- Concat / Upsample orquestados desde ARM
- Dump final de los 3 heads + decodificación bboxes + imagen de salida
- (Extra) HDMI output con bboxes dibujadas

**Supervisión:** 5 agentes paralelos + RTL principal.

---

## 2. Agentes paralelos lanzados

| ID | Tarea | Estado |
|---|---|---|
| `adb233bd38fc55745` | Extraer ONNX golden tensors por capa (255 layers) + meta.json | 🔄 running |
| `a8efb004c8ba8e8ab` | CSV sim de 3 configs conv críticas (stride-2 asim, max tiling, partial tile) | 🔄 running |
| `a75bd7b84e7d4932e` | Diseño runtime ARM: `yolov4_runtime.c`, dpu_api.h, README | 🔄 running |
| `a72db75b286a339b3` | Post-process YOLOv4: input_image.png + draw_bboxes.py + reference_onnx_output.png | 🔄 running |
| `a8ce9542dae7d7da0` | Investigación P_401 HDMI + plan integración (extra) | 🔄 running |

Cada agente tiene un reporte final que se insertará abajo cuando termine.

---

## 3. Fases RTL P_17

### Fase 1 — Skeleton + REG_LAYER_TYPE (en curso)

Cambios aplicados al wrapper `dpu_stream_wrapper.vhd` vs `conv_stream_wrapper.vhd` de P_16:

```diff
- entity conv_stream_wrapper
+ entity dpu_stream_wrapper
- s_axi_awaddr : in std_logic_vector(6 downto 0)
+ s_axi_awaddr : in std_logic_vector(7 downto 0)    ; ampliado a 8 bits para 0x54..0x64
- s_axi_araddr : in std_logic_vector(6 downto 0)
+ s_axi_araddr : in std_logic_vector(7 downto 0)

+ signal reg_layer_type  : std_logic_vector(31 downto 0);  ; nuevo @ 0x54
+ signal reg_M0_neg      : std_logic_vector(31 downto 0);  ; @ 0x58
+ signal reg_n_neg       : std_logic_vector(31 downto 0);  ; @ 0x5C
+ signal reg_b_zp        : std_logic_vector(31 downto 0);  ; @ 0x60
+ signal reg_M0_b        : std_logic_vector(31 downto 0);  ; @ 0x64

; En el switch de write: añadido when 0x54..0x64
; En el switch de read:  añadido when 0x54..0x64 para readback
```

Para layer_type=0 (CONV), el comportamiento es **idéntico** al wrapper de P_16 — cero riesgo de regresión en los 120 tests que ya pasaron.

`create_bd.tcl`:
- `conv_stream_wrapper` → `dpu_stream_wrapper` (21 sustituciones)
- `conv_dm_bd` → `dpu_multi_bd`

**Verificación pendiente de la noche:** build + correr layer_005_test en placa con `layer_type=0`, expect 41/41 PASS.

### Fase 2 — Integración leaky_relu (pendiente)

Plan de implementación (por desarrollar durante la noche):

1. **Instanciar** `leaky_relu` (P_9/src/leaky_relu.vhd) dentro del wrapper
2. **Conectar params** a registros AXI-Lite existentes:
   - `x_zp` → `reg_x_zp(7:0)`
   - `y_zp` → `reg_y_zp(7:0)`
   - `M0_pos` → `reg_M0`
   - `n_pos` → `reg_n_shift(5:0)`
   - `M0_neg` → `reg_M0_neg` (nuevo)
   - `n_neg` → `reg_n_neg(5:0)` (nuevo)
3. **Añadir** estado `S_STREAM` al FSM principal
4. **SERDES 32→8→32**: 
   - Shift register input: recibe word, emite 4 bytes a `lr_x_in`
   - Shift register output: acumula 4 bytes de `lr_y_out`, emite 1 word
   - Throughput: 1 word I/O cada 4 ciclos = 25% del ancho de banda (igual que leaky_relu_stream P_9, acceptable)
5. **Transición FSM**:
   - S_IDLE + cmd_start + layer_type=2 → S_STREAM
   - S_STREAM procesa bytes hasta `tlast` de s_axis → S_IDLE

**Regresión necesaria:** verificar que con layer_type=0 el CONV sigue funcionando.

### Fase 3 — Integración maxpool (pendiente)

- Instanciar `maxpool_unit` (P_12)
- Dos sub-estados del S_STREAM:
  - Acumular 4 bytes con `valid_in=1` en cada uno, `clear` al primero
  - Leer `max_out` tras el 4º `valid_in`
- El ARM pre-ordena los 4 bytes de cada ventana 2×2 en secuencia consecutiva

### Fase 4 — Integración elem_add (pendiente)

- Instanciar `elem_add` (P_11)
- Añadir estado `S_ELEM_ADD` (o sub-modo de S_LOAD → S_ELEM_ADD)
- LOAD fase 1: cargar input A en BRAM
- RUN fase 2: stream B por s_axis + lectura A del BRAM en paralelo → elem_add → m_axis

---

## 4. Infraestructura end-to-end

### Runtime ARM (`yolov4_runtime.c`, en diseño por agente)

**Flujo esperado:**
```c
// 1. Leer imagen quantizada (ya pre-procesada fuera del board o en _init)
u8 *dpu_ddr_image = (u8 *)CALIBRATION_DDR_ADDR;

// 2. Iterar 255 capas de layer_configs.h
for (int i = 0; i < NUM_LAYERS; i++) {
    layer_config_t L = layers[i];
    switch (L.op_type) {
        case OP_CONV:      dpu_exec_conv(&L);       break;
        case OP_LEAKY:     dpu_exec_leaky(&L);      break;
        case OP_MAXPOOL:   dpu_exec_pool(&L);       break;
        case OP_ELEM_ADD:  dpu_exec_add(&L);        break;
        case OP_CONCAT:    arm_concat(&L);          break;  // ARM software
        case OP_UPSAMPLE:  arm_upsample(&L);        break;  // ARM software
    }
}

// 3. Después de la última layer: 3 output heads en DDR
// 4. ARM decodifica bboxes + NMS, escribe a RESULT_ADDR
// 5. XSCT / HDMI lee y muestra
```

### Dump + post-process

**Dump:** ARM termina con 3 tensores en DDR a direcciones conocidas:
- `head_13x13`: stride-32 output (13×13 × 255 canales)
- `head_26x26`: stride-16 output (26×26 × 255)
- `head_52x52`: stride-8 output (52×52 × 255)

**Host-side post-process** (`draw_bboxes.py`, en desarrollo por agente):
- XSCT hace `mrd` de los 3 tensores, salva a binarios
- Script Python decodifica anchor-based: para cada celda, cada anchor → (x, y, w, h, objectness, 80 class scores)
- NMS (IoU 0.45, conf 0.25)
- Dibuja sobre `input_image.png` → `dpu_output.png`

Comparación final: `diff dpu_output.png reference_onnx_output.png` debería dar cero pixeles diferentes si todo es bit-exact.

---

## 5. Reportes de los agentes (se insertarán cuando terminen)

### Agent A — ONNX golden extraction ✅ COMPLETADO

**Status:** done.

**Deliverables:**
- `C:/project/vitis-ai/workspace/c_dpu/gen_golden_full_network.py` — extractor
- `C:/project/vitis-ai/workspace/c_dpu/golden_full_network/` — 545 `.bin` files + `meta.json` + `README.md`
- Per layer: `layer_NNN_input.bin`, `layer_NNN_output.bin`; multi-input ops incluyen `layer_NNN_input_inB.bin` (Add) o `_inK.bin` (Concat)

**Stats:**
- 255 layers extraídos (coinciden 1:1 con `LAYERS[]` de `layer_configs.h`)
- Op breakdown: 110 CONV, 107 LEAKY, 23 ADD, 10 CONCAT, 3 POOL, 2 RESIZE
- Layout on-disk: **NCHW** (runtime ARM debe permutar a HWC)
- Total: **257 MB** en disco
- Tensor más grande: **5.28 MB** (layer 0/1/15, early-stage 416×416×32 o 208×208×128)
- Ninguna supera el budget de 100 MB
- Zero-image input → capa 0 input = todos bytes `-128` (x_zp=-128 del model)
- Inference one-shot ~7 s

**DPU vs routing:**
- Producidas por DPU: 243 (CONV + LEAKY + POOL + ADD)
- Routing-only (ARM): 12 (10 CONCAT + 2 RESIZE)

Para regenerar con imagen real: `python gen_golden_full_network.py --input img.npy` (float32, [1,416,416,3]).

### Agent B — CSV sim conv crítico ✅ COMPLETADO

**Status:** 3/3 configs PASS bit-exact vs Python golden.

| Cfg | Descripción | Ciclos | Resultado | Final acc_0(0,0) HW vs Python |
|---|---|---:|:---:|---|
| **A** | stride=2, asym pad [1,0,1,0], c_in=3, 1 tile completo | 76,993 | PASS 512/512 | 2302 == 2302 |
| **B** | max tiling c_in=9 ic_tile=1 (9 tiles full) | 220,066 | PASS 512/512 | 4286 == 4286 |
| **C** | partial tile c_in=5 ic_tile=2 → (2,2,1) | 124,642 | PASS 512/512 | 2290 == 2290 |

**Observación clave (Config C):**
> `tile_filter_stride` toggles entre **18** (ic_in_tile_limit=2, tiles 0 y 1) y **9** (ic_in_tile_limit=1, último parcial). WL_STRIDE recalcula en cada tile. **El fix del partial-tile bug se observa directamente en el CSV.**

**Descubrimiento secundario:**
Layout de salida en DDR es **CHW** (no pixel-major como asumía al inicio): `out[oc][oh][ow] = ADDR_OUT + oc*hw_out + oh*w_out + ow`. RQ_CAPTURE avanza `+hw_out_reg` entre canales. Se corrigió en los TBs. Relevante para el runtime ARM.

**Handling del padding** verificado: pad=1 genera `mac_a=0` manteniendo el ciclo activo pero sin sumar.

**Deliverables (en `C:/project/vivado/P_13_conv_test/simC/`):**
- `critical_{A,B,C}_tb.vhd` — TBs con external CSV logger
- `run_critical_{A,B,C}.sh` — batch xvhdl+xelab+xsim
- `trace_{A,B,C}.csv` — 47 cols, full cycle trace (10 MB / 28 MB / 16 MB)
- `sim_{A,B,C}.log` — transcripts
- `compute_golden.py` — Python bit-exact de requantize.vhd (reusable)

**Para P_17 wrapper regression:** `bash run_critical_X.sh` y comparar CSV row-by-row (o banner PASS/FAIL). Infraestructura lista para diff cada vez que tocamos RTL.

### Agent C — ARM runtime design ✅ COMPLETADO

**Status:** esqueleto completo, stubs en dpu_exec_* + mem_pool allocator.

**Deliverables:**
- `C:/project/vivado/P_17_dpu_multi/sw/runtime/yolov4_runtime.c` — top-level loop, refcount precompute, dispatch por op_type, pool alloc/release, profiling
- `C:/project/vivado/P_17_dpu_multi/sw/runtime/dpu_api.h` — API: `dpu_init`, `dpu_exec_{conv,leaky,pool,add}`, `arm_{concat,upsample}`, `mem_pool_t`
- `C:/project/vivado/P_17_dpu_multi/sw/runtime/README.md` — build (reusa xsct P_16), XSCT run sequence, memory map, tiling strategy

**Diseño clave:**
- **Activation memory pool:** 224 MB @ `0x14100000`, bump-and-recycle por refcount. Refcounts precomputados en 1 pasada sobre `LAYERS[].input_a_idx/input_b_idx`. Release inmediato tras último consumer. Los 3 detection heads reciben +1 refcount para sobrevivir.
- **Footprint DDR total ~290 MB de 512 MB** (ZedBoard).
- **Skip connections:** implícitas por refcount (layer 6 output vive hasta layer 12 concat).
- **Concat:** ARM `memcpy` por spatial cell NHWC.
- **Upsample 2×:** nested loop, 4× `memcpy(dst, src, C)` por source cell.
- **Tiling (la parte dura):** ARM splits H → W → ic_tile_size. Interior tiles PAD=0, edge tiles PAD según capa original. Capa peor (3×3 @ 416×416 IC=32) ≈ 5,400 sub-tiles.
- **Polling, no IRQ.** Mismo patrón que P_16.
- **Profiling:** `dpu_prof_t` por capa (load/compute/drain/total cycles + tile count), XTime_GetTime wall-clock.

**Budget runtime:**
- Activations peak ~80 MB (de 224 MB pool, 3× headroom)
- 60 GOP total / 3.2 GOPS peak @ 100 MHz → **lower bound 19 s/frame**, realista **30 s – 2 min/frame** con overhead

**Stubs por implementar en la noche:** `dpu_init`, `dpu_reset`, `dpu_exec_*` (HW-touching, siguen el LOAD→START→poll→DRAIN de P_16 con `REG_LAYER_TYPE=0x54` seleccionando primitiva), `mem_pool.c`.

### Agent D — Post-process + images ✅ COMPLETADO

**Status:** end-to-end ONNX reference funcionando, 20 detecciones NMS, draw_bboxes.py CLI probado.

**Imagen elegida:** `cache_personas_calle.jpg` (COCO 000000080340) — escena callejera con 4 personas + suitcase + chair + table + cups + wine glass + tie. Ejercita bien YOLOv4.

**Deliverables:**
| Archivo | Uso |
|---|---|
| `C:/project/vitis-ai/workspace/c_dpu/demo/input_image.png` (246 KB) | 416×416 letterboxed RGB, para mostrar |
| `C:/project/vitis-ai/workspace/c_dpu/demo/input_int8.bin` (519,168 B) | HWC int8 = H*W*C, lo que el DPU ingiere |
| `C:/project/vitis-ai/workspace/c_dpu/demo/head_{52,26,13}.bin` | Golden ONNX fp32 NHWC (fuera repo) |
| `C:/project/vivado/P_17_dpu_multi/docs/reference_onnx_output.png` (233 KB) | Overlay post-NMS de referencia |
| `C:/project/vivado/P_17_dpu_multi/sw/runtime/draw_bboxes.py` (12 KB) | CLI + lib importable |
| `C:/project/vitis-ai/workspace/c_dpu/demo/prepare_demo.py` | Script reproducible |

**Cuantización de entrada:** `x_scale=1/255`, `x_zero_point=-128` (int8). Equivalente a `int8 = pixel - 128`. Letterbox padding 128 → 0 en int8.

**Decoder:** sigmoid xy/obj/cls, `exp(wh)*anchor/416`, per-class greedy NMS (conf=0.25, IoU=0.45). Auto-ordena heads por grid size.

**Validación:** ONNXRT 1.24.4, ~seg cada inferencia. **20 detecciones, top-1 person 0.995**. Visual OK, bboxes bien sobre personas+suitcase.

**Listo para integrar:** el CLI replay solo con `head_*.bin` reproduce las mismas 20 detecciones. `draw_bboxes.py` queda listo para consumir los dumps reales del DPU cuando la ZedBoard termine la inferencia.

### Agent E — HDMI integration (extra) ✅ COMPLETADO

**Status:** plan escrito, 0 implementación.

**Deliverable:** `C:/project/vivado/P_17_dpu_multi/docs/HDMI_INTEGRATION_PLAN.md`

**Findings clave:**
- P_401 **HW-verified** (12-Apr-2026), 720p@60 visible. ADV7511 sobre PL-side I2C (31 regs), MMCM 74.2268 MHz, ~200 LUT. Sin power-cycle especial.
- P_17 usa sólo HP0 → HP1/HP2/HP3 libres. VDMA para HDMI en HP1 sin contention. BW: 720p24bpp@60=165 MB/s vs HP1 peak=800 MB/s, margen grande.
- **Recomendado: Opción C** — bitstream unificado, framebuffer en DDR, ARM compone con bboxes. PL solo escanea frame; re-inferir = reescribir buffer + DCacheFlush.
- Rechazadas: (A) bitstream separado pierde DPU, (B) concurrente no aporta vs C.

**Budget extra** (sobre P_17): ~3.5k LUT, ~3.9k FF, 6 BRAM, 4 DSP, 1 MMCM, 1 ODDR. Cabe en Z-7020.

**Framebuffer:** 2.76 MB (1280×720×3) — solo DDR, BRAM no llega.

**Riesgos:**
1. P_401 actual envía solo R+G (bus 16-bit, blue perdido). Fix 24-bit: 0.5-1 día extra
2. Cache: `Xil_DCacheFlushRange` obligatorio en framebuffer
3. Sin conflicto PS (I2C PL-only)

**Effort:** ~4 días focused. Marcado nice-to-have, no bloquea nada.

---

## 6. Riesgos / abiertos

| Riesgo | Impacto | Mitigación |
|---|:--:|---|
| Resynth P_17 falla por timing (mult adicional en path crítico) | alto | Monitorear WNS; si <0, añadir registro en path leaky_relu |
| 4 primitivas no caben en xc7z020 | medio | Check util tras Fase 4; si supera, refactor shared datapath |
| BRAM 4 KB insuficiente para capas YOLOv4 reales (no crops) | alto | Runtime en ARM debe hacer tiling multi-pass por capa grande |
| JTAG se atasca durante 255-layer sweep | medio | `rst -system` + batch 30-50 layers por sesión |
| ONNX decode bboxes no matchea exactamente | medio | Validar draw_bboxes.py standalone primero |
| HDMI integración requiere bitstream separado | bajo (extra) | Aceptable — P_17 + P_401 separadas |
| Dudas sobre layout HWC vs CHW en ONNX dumps | medio | Confirmar con el agente de golden extraction |

---

## 7. Checklist del reporte mañana

- [ ] P_17 Fase 1: build OK (WNS ≥ 0), HW test regresión 41/41 PASS layer_005
- [ ] Fase 2 leaky_relu: sim + HW test
- [ ] Fase 3 maxpool: sim + HW test
- [ ] Fase 4 elem_add: sim + HW test
- [ ] ONNX golden dataset completo (255 layers)
- [ ] ARM runtime yolov4_runtime.c esqueleto + compila
- [ ] draw_bboxes.py funciona stand-alone con salida ONNX de referencia
- [ ] (Stretch) End-to-end network run en ZedBoard
- [ ] (Stretch) dpu_output.png matches reference_onnx_output.png
- [ ] (Extra) HDMI integration plan escrito

---

## 8. Commits planificados

| # | Mensaje | Cuando |
|---|---|---|
| de7c964 | ✅ P_17 dpu_multi: skeleton + arquitectura (hecho) | completado |
| TBD #1 | P_17 Fase 1: wrapper passthrough + REG_LAYER_TYPE | tras HW regresión |
| TBD #2 | P_17 Fase 2: leaky_relu integrado | tras HW test leaky |
| TBD #3 | P_17 Fase 3: maxpool integrado | tras HW test pool |
| TBD #4 | P_17 Fase 4: elem_add integrado | tras HW test add |
| TBD #5 | P_17 runtime ARM + post-process + golden | tras infra lista |
| TBD #6 | P_17 end-to-end YOLOv4 validado HW | si sale perfecto |

---

*Última actualización: inicio de turno de noche.*
