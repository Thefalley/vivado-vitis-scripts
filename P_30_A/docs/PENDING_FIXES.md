# P_30_A: Estado de verificación 18 abril 2026 (final)

## Resultados test aislado (cada layer con input ONNX correcto)

De las primeras 40 layers ejecutadas con el último build:
- **24 BIT-EXACT** (60%)
- **13 ROUNDING +-1** (32.5%) — requantize rounding, no es bug
- **2 FAIL** (5%) — CONCAT layout bug
- **1 CRASH** (2.5%) — CONV IC-tiled grande timeout

## Bugs resueltos hoy (18 abril)

1. **FIFO tlast/tkeep** — DMA AXI-Stream no conectaba sin estos puertos
2. **conv_engine preload machaca pesos** — cfg_skip_wl para saltar preload
3. **XAxiDma_Busy/SimpleTransfer bug** — dma_send directo a registros
4. **Cache invalidation en tile loop** — movida fuera del loop (crasheaba ARM)
5. **BRAM overflow tile hardcoded** — tiling dinámico
6. **OC tile weight offset** — w_base_idx_r = oc_tile_base * tile_filter_stride
7. **DMA chunking** — transfers >16KB divididos en chunks
8. **ADD sin tiling** — chunks de 4092 bytes
9. **reg_n_words 11-bit overflow** — max_chunk = 4092 para ADD
10. **BIAS_LOAD destruye acumuladores** — mac_lb gated por cfg_no_clear
11. **IC+OC tiling architecture** — ARM controla OC groups (32ch) + IC tiles

## Bugs pendientes (para mañana)

### P1: POOL grande (layers 182, 183, 184)
- **Síntoma**: st=0x3 (TIMEOUT), 4.8s
- **Causa**: El POOL chunking se implementó en dpu_exec.c pero puede no
  ejecutarse (la función que se llama puede ser otra, o el wrapper no
  soporta el patrón CMD_START + DMA en chunks para POOL)
- **Impacto**: 3 layers de 255 (1.2%)

### P2: c_out=255 (layers 225, 240, 254)
- **Síntoma**: st=0x1 (INVALID_CMD), instantáneo
- **Causa**: A pesar del fix (force needs_ic_tiling cuando c_out%32!=0),
  el error ocurre antes de llegar a dpu_exec_conv_v4. Puede ser
  eth_server.c rechazando los parámetros, o un overflow en el layer
  config parsing (c_out=255 en un campo de 8 bits?)
- **Impacto**: 3 layers de 255 (1.2%)

### P3: CONCAT layout (layers 15, 36, 87, 140, etc.)
- **Síntoma**: max_diff 65-160, output parcialmente incorrecto
- **Causa**: arm_concat puede tener un bug en el layout NCHW.
  El CONCAT concatena canales: [c_a channels][c_b channels].
  Si el orden o el stride es incorrecto, los datos se mezclan.
- **Impacto**: ~10 layers de 255 (4%)

### P4: CONV IC-tiled grandes crashean (layers 39, 90, 143+)
- **Síntoma**: ARM crash (ConnectionResetError) o timeout
- **Causa**: Con tiles 1x1 y muchos OC groups + IC tiles, el número
  de CMD_STARTs es enorme (>40000). Cada una tarda ~5ms.
  Total >200 segundos. lwIP TCP timeout mata la conexión.
- **Solución futura**: Optimizar IC tiling para tiles > 1x1 usando
  accumulator save/restore via BRAM, o pausar el conv_engine entre
  IC tiles para recargar pesos (requiere RTL change).
- **Impacto**: ~20 layers de 255 (8%)

### P5: Rounding +-1 en requantize (27 layers)
- **Síntoma**: max_diff=1, 0.001% de bytes afectados
- **Causa**: DPU round-half-up vs ONNX round-half-to-even.
  El fix round-half-to-even se implementó pero no tuvo efecto
  (la condición exacta de 0.5 no es la que causa los diffs).
- **Impacto**: cosmético, no afecta funcionalidad
- **Prioridad**: BAJA

## Layers que SÍ funcionan correctamente
- CONV k=3 sin IC tiling: bit-exact (layers 0, 2, 10, 18, 26, ...)
- CONV k=1: bit-exact o rounding +-1
- CONV IC-tiled pequeños: rounding +-1 (layers 47, 52, ...)
- LEAKY: bit-exact
- ADD: bit-exact
- RESIZE: funciona

## Arquitectura de tiling (para referencia)
```
Para cada spatial tile (tile_h × tile_w output pixels):
    Para cada OC group (32 output channels):
        Para cada IC tile (ic_tile_size input channels):
            1. ARM extrae pesos del (oc_group, ic_tile) → wb_ram via FIFO
            2. ARM extrae input del ic_tile → BRAM via DMA
            3. ARM configura: c_out=32, c_in=ic_ts, no_clear, no_requantize
            4. CMD_START → conv_engine procesa (1 OC tile, 1 IC tile)
        5. DRAIN output del OC group (32 × tile_h × tile_w bytes)
        6. ARM copia output al DDR global en posición correcta
```
