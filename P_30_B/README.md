# P_30_B — 3 FIFOs (pesos + input + bias) con 3 DMAs

## Contexto

Mismo problema que P_30_A: los pesos no caben en el BRAM de 4 KB. Misma spec (`P_30_A/docs/ESPECIFICACION.md` aplica igual aquí).

## Diferencia vs P_30_A

| | P_30_A | P_30_B |
|---|---|---|
| FIFOs nuevas | 1 (pesos) | 3 (pesos + input + bias) |
| DMAs nuevos | 1 | 2 (total 3) |
| BRAM wrapper | Sube a 8 KB | Se queda en 4 KB (o se elimina) |
| HP ports | 2 de 4 | 3 de 4 |
| Complejidad RTL | Media | Alta |
| Complejidad ARM | Baja | Baja (3 SimpleTransfer en paralelo) |

## Arquitectura

```
                     ┌──────────┐
DDR (pesos) ─DMA_W─▶│ FIFO_W   │──▶ wb_ram 32 KB (dentro de conv_engine)
                     │ (P_102)  │
                     └──────────┘
                     ┌──────────┐
DDR (input) ─DMA_IN▶│ FIFO_IN  │──▶ BRAM 4 KB (acceso aleatorio para ventana k×k)
                     │ (P_102)  │
                     └──────────┘
                     ┌──────────┐
DDR (bias)  ─DMA_B─▶│ FIFO_B   │──▶ bias_buf (128 B, dentro de conv_engine)
                     │ (P_102)  │
                     └──────────┘

                     conv_engine_v4 lee de wb_ram + BRAM + bias_buf
                     escribe output → DataMover S2MM → DDR
```

## Ventaja sobre P_30_A

Nada pasa por el BRAM de 4 KB excepto el input (que necesita acceso aleatorio para la ventana k×k). Bias y pesos tienen su propio path. El BRAM no necesita agrandarse.

Los 3 DMAs trabajan en paralelo:
```c
// ARM: dispara los 3 a la vez
XAxiDma_SimpleTransfer(&dma_w,  w_addr,  w_bytes,  TO_DEVICE);
XAxiDma_SimpleTransfer(&dma_in, in_addr, in_bytes, TO_DEVICE);
XAxiDma_SimpleTransfer(&dma_b,  b_addr,  b_bytes,  TO_DEVICE);
// Las 3 FIFOs absorben datos en paralelo
// El conv consume de cada una cuando la necesita
```

## Secuencia para un ic_tile

```
1. ARM dispara 3 DMAs en paralelo
   DMA_W:  pesos de este ic_tile (c_out × k² × ic_tile_size bytes)
   DMA_IN: input de este ic_tile (ic_tile_size × h_in × w_in bytes)
   DMA_B:  bias (c_out × 4 bytes, solo primer ic_tile)

2. Wrapper FSM orquesta la carga:
   S_LOAD_WEIGHTS: lee FIFO_W → escribe wb_ram secuencialmente
   S_LOAD_INPUT:   lee FIFO_IN → escribe BRAM secuencialmente
   S_LOAD_BIAS:    lee FIFO_B → escribe bias_buf (o BRAM)
   (pueden ser secuenciales o con overlap parcial)

3. S_CONV: conv_engine_v4 trabaja como siempre
   Lee pesos de wb_ram, input de BRAM, bias de bias_buf
   MAC + requantize (o solo MAC si no_requantize=1)

4. S_DRAIN: output → DataMover → DDR (solo en ultimo ic_tile)
```

## Complejidad extra vs P_30_A

- 2 DMAs más (DMA_IN ya existe, pero cambia de rol; DMA_B es nuevo)
- 2 FIFOs más en el wrapper
- Wrapper FSM tiene 3 estados de carga en vez de 1
- Block design más complejo (3 conexiones AXI HP)
- El bias_buf necesita un path de escritura desde FIFO_B

## Cuándo elegir P_30_B sobre P_30_A

- Si el BRAM de 8 KB de P_30_A no es suficiente para capas futuras (redes más grandes)
- Si se quiere máximo paralelismo en la carga de datos
- Si se planea escalar a redes con c_out > 2048 (bias > 8 KB)

Para YOLOv4 actual, P_30_A es suficiente.

## Recursos

| Recurso | P_30_B | Zynq-7020 |
|---|---|---|
| BRAM36 | ~15 (+3 FIFOs, +2 DMAs internos) | 140 |
| DSP48 | 44 (sin cambio) | 220 |
| HP ports | 3 | 4 |
| AXI DMA | 3 | - |

## Plan de implementación

```
Fase 1: conv_engine_v4 (igual que P_30_A: 2 flags + ext_wb)
Fase 2: 3 FIFOs (reusar P_102 pattern × 3)
Fase 3: wrapper_v4 con 3 estados de carga
Fase 4: Block Design (3 DMAs + 3 FIFOs + conexiones HP)
Fase 5: ARM firmware (3 SimpleTransfer en paralelo)
Fase 6: Verificación bit-exact
```

## Archivos

```
P_30_B/
├── src/
│   ├── conv_engine_v4.vhd         ← igual que P_30_A
│   ├── fifo_weights.vhd           ← FIFO P_102 para pesos
│   ├── fifo_input.vhd             ← FIFO P_102 para input
│   ├── fifo_bias.vhd              ← FIFO P_102 para bias
│   ├── dpu_stream_wrapper_v4.vhd  ← wrapper con 3 loads
│   ├── (todos los demás .vhd copiados de P_18/src/)
│   └── create_bd.tcl              ← BD con 3 DMAs
├── sim/
├── sw/
├── docs/
│   └── (reutiliza ESPECIFICACION.md de P_30_A — mismas reglas)
└── README.md
```
