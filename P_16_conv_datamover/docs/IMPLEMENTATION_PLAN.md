# P_16 Implementation Plan — DPU con DataMover

## Arquitectura acordada

```
DDR ──(DMA_weights MM2S)──► [weight_buf 64KB] ──┐
DDR ──(DMA_act MM2S)──────► [act_buf 32KB] ─────┤──► conv_v3 / maxpool / relu
DDR ──(DMA_act MM2S)──────► [add_buf 32KB] ─────┤──► elem_add
                                                 │
                         [out_buf 4KB] ◄─────────┘
                              │
                         DataMover S2MM ──► DDR
                              │
                         IRQ (done/error) → ARM
```

- ARM controla DMAs (Opción A — más simple)
- Controller PL solo ejecuta conv cuando ARM dice "go"
- Concat/Upsample en ARM
- 33 BRAMs (24%), 44 DSPs (20%)

## Plan de implementación

### Paso 1: P_16 Block Design (1-2 días)
- Zynq PS7 + 2×DMA + DataMover S2MM + conv_stream_wrapper_v3
- GP0: 4 slaves (DMA_wt, DMA_act, wrapper, dm_ctrl)
- HP0: 4 masters (DMA_wt MM2S, DMA_act MM2S, DataMover S2MM, DataMover cmd)
- IRQ: DMA_wt done, DMA_act done, DataMover done/error
- 100 MHz

### Paso 2: conv_stream_wrapper_v3 (1 día)
- Actualizar conv_stream_wrapper de P_14 para usar conv_engine_v3
- Añadir 4 registros de pad asimétrico
- Aumentar BRAM a 64 KB (para weight tiles grandes)
- Sim verificación

### Paso 3: Test básico bare-metal (1 día)
- ARM carga 1 layer (layer_005) via DMA
- Conv procesa
- DataMover drena output a DDR
- Verificar 41/41 bit-exact

### Paso 4: Test multi-tile (1 día)
- Layer con c_in=64: ARM hace 2 ic_tiles
- ARM orquesta: load_wt → load_act → conv → load_wt → load_act → conv → drain
- Verificar bit-exact

### Paso 5: Test multi-layer (2 días)
- ARM ejecuta 3 layers consecutivos: conv → relu → conv
- Output de layer N → input de layer N+1 (via DDR)
- Verificar against ONNX

### Paso 6: Todas las primitivas (2 días)
- Integrar maxpool, leaky_relu, elem_add como módulos seleccionables
- layer_type register selecciona qué primitiva ejecutar
- Test: conv → relu → maxpool → conv

## Decisiones tomadas
- ARM controla DMAs (no el PL)
- Concat/Upsample en ARM
- 2 DMAs dedicados (weights + activaciones)
- DataMover para output (con IRQ + error flags)
- BRAM buffers single-port (no double buffering por ahora)
- Strip tiling para feature maps grandes (3 filas para 3×3 conv)
