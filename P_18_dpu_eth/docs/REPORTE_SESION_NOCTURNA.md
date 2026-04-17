# Reporte sesión nocturna 2026-04-16/17

## Resultado principal

```
[  0] OK   CONV    crc=0x8FACA837 == ONNX    (10.8 s)
[  1] OK   LEAKY   crc=0xF51B4D0C == ONNX    (0.3 s)
[  2] ERR  CONV    DPU_ERR_TILING  ← pesos 18 KB > 4 KB BRAM (IC tiling pendiente)
```

**2/255 capas bit-exact 1:1 con ONNX.** Las capas que CABEN en BRAM son correctas. Las que no caben necesitan IC tiling en el runtime ARM.

---

## Verificación sin trampas

Tres vías independientes confirman que el RTL es correcto:

| Método | Resultado |
|---|---|
| Python puro (numpy int32 + requantize) vs ONNX | `match: True` |
| XSIM conv_engine_v3 con vectores reales ONNX (4×4) | `512/512 bytes OK` |
| Board real (416×416 con tiling H+W, via Ethernet) | `CRC 0x8FACA837 == ONNX` |

---

## Bugs encontrados y arreglados (6 totales)

| # | Bug | Archivo | Fix |
|---:|---|---|---|
| 1 | Doble transpose de pesos (blob ya OHWI, C hacía otra transpose) | `dpu_exec.c` L218 | `memcpy` directo |
| 2 | Cache stale al leer input/weights/bias del DDR (ARM D-cache) | `dpu_exec.c` | `Xil_DCacheInvalidateRange` antes del memcpy |
| 3 | Mismo cache stale en path tiled | `dpu_exec_tiled.c` | Misma fix |
| 4 | Input tiling asumía NHWC, RTL espera NCHW | `dpu_exec_tiled.c` L282 | Loop: `for c: for r: memcpy(src + c*H*W + r*W)` |
| 5 | Output tiling asumía NHWC | `dpu_exec_tiled.c` L313 | Mismo fix NCHW |
| 6 | Leaky chunk 4096 bytes = 1024 words overflow `reg_n_words` 10 bits (max 1023) | `dpu_exec.c` | Chunk 4092 bytes (1023 words) como P_17 |

---

## Infraestructura Ethernet (operativa)

| Operación | Velocidad | Estado |
|---|---|---|
| WRITE_DDR 64 MB (pesos blob) | 44 MB/s | ✅ |
| READ_DDR 5.5 MB (activación) | 27 MB/s | ✅ |
| Ping estabilidad | 20/20 tras hard_reset | ✅ |
| Librería Python `p18eth/` + 31 tests | ✅ | ✅ |

---

## Bloqueador actual: IC tiling

A partir de layer 2 (CONV 32→64, k=3), los pesos son 18432 bytes > 4096 bytes BRAM. El runtime actual NO implementa IC tiling — solo H+W tiling.

**El RTL SÍ soporta IC tiling** (`cfg_ic_tile_size` en `conv_engine_v3`). Falta implementar la lógica en el ARM:
1. Dividir `c_in` en sub-tiles de `ic_tile_size` canales (max que quepa con pesos+bias+input_tile en 4 KB).
2. Para cada `(h_tile, w_tile)` sub-tile espacial, iterar por `ic_tile`:
   - Cargar pesos parciales (oc × kh × kw × ic_tile_size bytes) + input parcial + bias.
   - Ejecutar con `cfg_ic_tile_size = ic_tile_size` → el RTL acumula sin limpiar entre ic_tiles.
3. Requantize solo al final del último ic_tile.

Estimación: ~2 h de trabajo en `dpu_exec_tiled.c`.

---

## Mapping ONNX → FPGA (verificado)

`FPGA[i] output = onnx_refs/manifest.tensors[i + 2]`

Secuencial sin saltos. Verificado para las 20 primeras capas — shapes y node_names coinciden.

---

## Archivos clave

```
sw/dpu_exec.c           ← runtime conv (fast-path con fix) + leaky (chunking 4092)
sw/dpu_exec_tiled.c     ← tiling H+W NCHW (fix del NHWC)
sw/eth_server.c         ← dispatch EXEC_LAYER con cfg override
host/run_all_layers.py  ← orquestador 255 capas con allocator DDR
host/layer_configs.json ← 255 LAYERS parseados del firmware
host/weights_manifest.json ← offsets pesos/bias por capa
sim/conv_engine_v3_layer0_tb.vhd ← XSIM testbench bit-exact
docs/DEBUG_LAYER0_BITEXACT.md    ← bitácora completa de la noche
```

---

## Commits

```
P_18 Ethernet + CONV + LEAKY bit-exact 1:1 vs ONNX YOLOv4
```

---

## Plan mañana (priorizado)

1. **IC tiling** en `dpu_exec_tiled.c` (~2 h) → desbloquea layers 2-254 (las 110 CONV).
2. **Maxpool ARM pre-reorder** (el RTL necesita ventanas 2×2 contiguas, hay que reordenar desde NCHW).
3. **Add con dos operandos** (cache invalidate del segundo operando, escalas distintas).
4. **Concat en ARM** (copia plana de 2 tensores NCHW).
5. **Resize en ARM** (nearest 2× — ya verificado en test_exec_layer).
6. **Barrido de las 255 capas** → target: ≥200/255 OK.
