# Bit-exact del DPU — bitácora sesión nocturna

**Fecha:** 2026-04-16 → 2026-04-17 (nocturna)
**Objetivo:** El DPU de YOLOv4 tiene que ser **1:1 con ONNX**. Sin trampas.

---

## 🎉 RESULTADO DE LA SESIÓN

### Layer 0 (primera CONV 3→32, 416×416, k=3 s=1 pad=1)

```
✅✅✅ DPU output CRC NCHW == ONNX expected NCHW CRC
     Primer pipeline CONV real en FPGA BIT-EXACT vs ONNX
     wall time 10.8 s para 5.5 MB de output
```

- CRC output FPGA: `0x8FACA837`
- CRC esperado ONNX: `0x8FACA837`
- **MATCH byte a byte** (5 537 792 bytes)

Reproducible:
```bash
cd C:/project/vivado/P_18_dpu_eth/sw
"C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat" hard_reset.tcl \
  ../build/dpu_eth.runs/impl_1/dpu_eth_bd_wrapper.bit \
  ../vitis_ws/dpu_eth_platform/zynq_fsbl/fsbl.elf \
  ../vitis_ws/dpu_eth_app/Debug/dpu_eth_app.elf
ping -n 30 192.168.1.10 > NUL   # warmup ARP
cd ../host
python test_layer0_bitexact.py
# Espera: "DPU output CRC NCHW == ONNX expected NCHW CRC"
```

---

## 1. Bugs identificados y arreglados esta noche

| # | Archivo | Bug | Fix |
|---:|---|---|---|
| 1 | `sw/dpu_exec.c` L218 | **Doble transpose de pesos**: el blob ya viene OHWI (del extractor Python); el C hacía otra transpose asumiendo OIHW, corrompiendo los pesos en BRAM. | `memcpy(wbuf, weights_ddr, w_bytes)` directo |
| 2 | `sw/dpu_exec.c` L217 | **Cache stale al leer input/weights/bias**: el ARM había escrito el DDR vía lwIP con flush, pero el memcpy luego leía cache stale (zeros). Dump_scratch.py verificó: `IN region 48/64 diff` con bytes en zeros. | `Xil_DCacheInvalidateRange` sobre los 3 buffers fuente (aligned a 64) justo antes del memcpy |
| 3 | `sw/dpu_exec_tiled.c` L127 | Mismo cache stale en el path tiled | Añadido `Xil_DCacheInvalidateRange` antes del memcpy |
| 4 | `sw/dpu_exec_tiled.c` L282 | **Input tiling en NHWC**: el código asumía input channels-last (`src = in_ddr + ((r) * W + c) * Cin`), pero el RTL espera **NCHW** (channels-first, verificado en L829 de conv_engine_v3.vhd). | Reescrito el loop: `for c: for r: memcpy(src + c*H*W + r*W + c_lo, ...)` |
| 5 | `sw/dpu_exec_tiled.c` L313 | **Output composition en NHWC**: mismo bug en la recomposición de sub-tiles al tensor grande. | Reescrito con ordenación NCHW |

---

## 2. Verificaciones progresivas

| Test | Estado |
|---|:---:|
| Python puro reproduce ONNX (numpy int32 + requantize) | ✅ `match: True` |
| XSIM `conv_engine_v3` con vectores layer 0 (4×4) | ✅ **512/512 bytes bit-exact** |
| Board `dpu_exec_conv` fast-path 4×4 (sin tiling) | ✅ **bit-exact** |
| Board `dpu_exec_conv_tiled` 416×416 (con tiling H+W) | ✅ **bit-exact** |

---

## 3. Hallazgos críticos

### 3.1 El RTL NO tenía bug

Los agentes iniciales sospecharon del RTL (porque los P_16 120/120 PASS no eran contra ONNX). Los sospechas eran válidas pero resultaron infundadas.

**Evidencia de que el RTL está bien:**
- XSIM con vectores ONNX reales → 512/512 bit-exact.
- `act_ic_offset += hw_reg` (L829) confirma NCHW channels-first.
- `addr_output = addr + oc*h_out*w_out + oh*w_out + ow` (L901-927) confirma NCHW en el output.

### 3.2 Todos los bugs eran en el runtime ARM

- Transposes sobrantes (bug histórico importado de P_16/P_17).
- Cache invalidates faltantes (típico de DMA path bare-metal Zynq).
- Formato de datos en el tiling: asumía NHWC en un runtime que habla a un RTL NCHW.

### 3.3 El fix del cache stale fue el "game-changer"

Sin ese fix, el ARM leía bytes en cero del DDR aunque el DDR estaba escrito correctamente. La primera pista fue `dump_scratch.py` que mostró `IN region: 48/64 diff (todos zeros)` con WEIGHTS y BIAS correctos.

---

## 4. Reglas de oro (sin trampas)

1. **Nunca asumir el layout** — verificar siempre en el RTL (buscar cómo se incrementan los offsets entre canales/píxeles).
2. **Bit-exact sólo vale si es contra el ONNX real** — no sintético Python local.
3. **Las versiones de tests anteriores pueden tener false positives** — si no se probó contra ONNX, no está verificado vs ONNX.
4. **Dos simulaciones alineadas**: XSIM con vectores ONNX + Python reproduciendo la ecuación → si XSIM y Python coinciden, el RTL es correcto. Cualquier divergencia board vs XSIM = bug en firmware/runtime/DMA.
5. **Cache coherencia en Zynq**: cualquier punto donde el ARM lee DDR que fue escrito por otro path (Ethernet, otro core, DMA externo) necesita `Xil_DCacheInvalidateRange` antes del read.
6. **Alineación de cache line = 64 bytes en Cortex-A9**. Redondear al alza cuando invalides.

---

## 5. Próximos pasos

### 5.1 Intentado esta noche — progreso parcial

**LAYER 1 (LEAKY 32×416×416):**
- Input = `layer_002.bin` (la salida verificada bit-exact de layer 0)
- Output esperado = `layer_003.bin`

**Diagnóstico confirmado**: `AXI DMA` IP en el BD usa default `c_sg_length_width=14` → max 16 KB por transfer. 5.5 MB en un solo shot falla con `DPU_ERR_PARAMS`.

**Fix implementado**: strip-mining del leaky en chunks de 4 KB (`DMA_MAX_CHUNK_BYTES`):
- Programa `N_WORDS = chunk/4` y `DataMover dst = out + offset` por chunk.
- Por cada chunk: `CTRL=0x02` (start) → `SimpleTransfer` → `wait_done_latch` + `wait_dm_done`.

**Resultado actual (2026-04-17 ~02:30):**
- **Primer chunk (primeros 4096 bytes) BIT-EXACT ✅**
- Segundo chunk: diverge → `status=TIMEOUT` (wrapper no arranca de nuevo).

```
dpu[:16]: [-111, -111, -111, -112, -112, -108, -111, -114, -114, -84, -112, -112, -110, -111, -112, -112]
exp[:16]: [-111, -111, -111, -112, -112, -108, -111, -114, -114, -84, -112, -112, -110, -111, -112, -112]
first diff idx=4096   <-- exactamente en la frontera del chunk!
```

**Lo que falta**: el wrapper necesita reset de `done_latch` entre chunks. Entre chunks, el firmware no está limpiando el flag `REG_CTRL bit 0x100`. Por eso el `wait_done_latch` del chunk 2 retorna inmediato (el latch del chunk 1 seguía) o el wrapper no arranca.

**Fix trivial para mañana**: añadir `dpu_write(REG_CTRL, 0)` entre chunks ANTES del `CTRL=0x02`, para limpiar el latch. Una vez eso resuelto, LEAKY debería ser bit-exact (tenemos el primer chunk como prueba).

Después de LEAKY: CONV layer 2 (stride=2, 208×208), y seguir.

### 5.2 Medio plazo

4. LEAKY, MAXPOOL, ADD, CONCAT, RESIZE — verificar las 5 primitivas restantes.
5. **255 layers end-to-end** con comparación CRC contra cada tensor ONNX.
6. Decodificador bboxes en PC.
7. HDMI output (P_19) con la imagen final.

---

## 6. Artifacts útiles para mañana

| Archivo | Rol |
|---|---|
| `host/test_layer0_bitexact.py` | Test oficial layer 0 416×416 |
| `host/test_layer0_4x4_board.py` | Test sub-layer (fast-path) |
| `host/verify_onnx_graph.py` | Reproduce ONNX en Python puro |
| `host/gen_xsim_vectors.py` | Extrae vectores para XSIM |
| `host/dump_scratch.py` | Debug: dumpea scratch del ARM vía mailbox |
| `sim/conv_engine_v3_layer0_tb.vhd` | TB XSIM layer 0 4×4 con vectores reales |
| `sim/run_sim_layer0.sh` | Corre XSIM batch |

---

## 7. Historial de la noche

- **23:50** — Detectado 98.59% diff al ejecutar layer 0 full. Revisamos si era NHWC vs NCHW o layer_001 wrong.
- **00:15** — Python reproduce ONNX bit-exact (verificación base). Datos confirmados correctos.
- **00:25** — XSIM del conv_engine_v3 con vectores reales → **bit-exact**. RTL descartado.
- **00:40** — Identificado bug doble transpose en dpu_exec.c. Arreglado. Mejora a 96% diff.
- **01:00** — `dump_scratch.py` revela INPUT en zeros en scratch → bug de cache stale. Añadido `Xil_DCacheInvalidateRange`.
- **01:15** — Board 4×4 bit-exact (sin tiling). Fast-path ✅.
- **01:30** — Identificados 2 bugs más en `dpu_exec_tiled.c`: input extraction y output composition ambos asumían NHWC en un runtime NCHW.
- **01:45** — 416×416 full bit-exact. **LAYER 0 COMPLETO 1:1 con ONNX.**
- **02:00** — Clean-up del debug dump + re-validación bit-exact mantiene tras limpieza.

---

**Firmado:** Claude Opus 4.6 — sin trampas. Verificado byte a byte contra `onnx_refs/layer_002.bin` (CRC 0x8FACA837).
