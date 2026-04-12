# Arquitectura FIFO para conv_engine — Diseño P_14

## Problema

El `conv_engine` actual usa un `weight_buf` LUTRAM (6144 LUTs) que falla en HW
con patrones sparse. Necesitamos reemplazarlo con BRAMs reales usando el patrón
P_101 (fifo_2x40_bram) que está verificado en HW.

## Restricción clave

El FIFO es **secuencial** (emite datos en orden, 1/ciclo). Pero el conv_engine
actual hace **acceso random** al weight_buf:

```
MAC_WLOAD lee: weight_buf[base + 0*stride], weight_buf[base + 1*stride], ...
              donde stride = c_in * k*k (ej: 27 para 3IC 3x3)
```

Esto es un acceso STRIDED — salta de 27 en 27 para cargar 1 peso por OC.

## Solución: 2 niveles

```
DDR ──(DMA)──► [FIFO weights] ──drain──► [weight_scratchpad BRAM] ──random──► conv MAC
DDR ──(DMA)──► [FIFO activations] ──drain──► conv MAC (secuencial)
ARM ──(AXI-Lite)──► [bias regs] ──► conv MAC
conv MAC ──► [output FIFO] ──drain──► (DMA) ──► DDR
```

### Nivel 1: FIFO (transporte DMA → PL)
- Usa `fifo_2x40_bram` de P_101 con N_BANKS reducido
- Interfaz AXI-Stream, 32 bits, compatible con axi_dma
- Garantiza 1 word/ciclo en la salida (ping-pong)

### Nivel 2: Scratchpad BRAM (acceso random para conv)
- Usa `bram_sp` de P_101 instanciado como array
- El conv_engine lee con acceso random (stride pattern)
- Tamaño: 8 BRAMs × 1024 words = 32 KB (cabe un weight tile completo)

## Flujo de datos detallado

### Pesos (weight path)
```
1. ARM configura DMA MM2S con addr=DDR_weights, len=n_weights
2. ARM escribe LOAD al bram_ctrl → FIFO acepta n_weights via s_axis
3. FIFO almacena en ping-pong BRAMs (A/B alternando)
4. ARM escribe DRAIN → FIFO emite a 1 word/ciclo via m_axis
5. Un adapter module recibe m_axis y escribe en weight_scratchpad BRAM
6. conv_engine lee weight_scratchpad[addr] durante MAC_WLOAD
```

### Activaciones (activation path)
```
1. ARM configura DMA MM2S con addr=DDR_activations
2. Activaciones entran via FIFO (o directo si caben en BRAM)
3. conv_engine consume secuencialmente (1 byte por tap)
```

Para activaciones hay 2 opciones:
- **Opción A (simple):** cargar todo el input tile a BRAM scratchpad, conv lee random
- **Opción B (streaming):** conv consume activaciones del FIFO en scan order

Opción A es más simple y compatible con el conv_engine actual.

### Bias (simple)
- 32 × int32 = 128 bytes. Cabe en registros AXI-Lite o un mini BRAM.
- No necesita FIFO — se carga via AXI-Lite directamente.

### Output (result path)
```
1. conv_engine produce 1 byte por output pixel
2. Bytes se acumulan en un output buffer BRAM
3. Al terminar, DMA S2MM drena el buffer a DDR
```

## Recursos estimados (xc7z020)

| Componente | BRAMs | Capacity | Notas |
|---|---|---|---|
| Weight FIFO (N_BANKS=4) | 8 | 8192 words (32 KB) | Para weight tile |
| Weight scratchpad | 8 | 32 KB | Random access para MAC |
| Activation scratchpad | 8 | 32 KB | Input tile completo |
| Output buffer | 4 | 16 KB | Output parcial |
| Bias | 0 | 128 B | Registros AXI-Lite |
| **TOTAL** | **28** | **~112 KB** | **20% del xc7z020** |

Quedan 112 BRAMs (80%) libres para futuros buffers o doble-buffering.

## Cambios al conv_engine

### Mínimos (fix directo)
1. Reemplazar `weight_buf` LUTRAM → instancia de `bram_sp` (8 BRAMs, 32 KB)
2. Añadir 1 ciclo extra a MAC_WLOAD (BRAM tiene latencia 1 vs LUTRAM latencia 0)
3. Cambiar WL_CAPTURE para escribir al scratchpad BRAM en vez de signal array

### Para integración FIFO (P_14)
1. Añadir puerto AXI-Stream para recibir weights del FIFO
2. FSM: LOAD_WEIGHTS (drena FIFO → scratchpad) antes de START
3. Añadir puerto AXI-Stream para recibir activaciones
4. Cambiar DDR read path → activation scratchpad read
5. Añadir output buffer + AXI-Stream output

## Plan de implementación

### Paso 1: Fix inmediato (reemplazar LUTRAM)
- Modificar `conv_engine.vhd`: weight_buf → bram_sp
- Añadir estado MAC_WLOAD_WAIT para latencia BRAM
- Mantener wrapper actual (fake-DDR via AXI-Lite)
- **Objetivo:** 41/41 PASS en ZedBoard

### Paso 2: Integrar FIFO de weights (P_14)
- Instanciar fifo_2x40_bram(N_BANKS=4) en wrapper
- DMA carga weights → FIFO → scratchpad
- conv_engine lee scratchpad en vez de fake-DDR

### Paso 3: FIFO activaciones + output
- Segunda instancia de fifo para activaciones
- Buffer de salida con DMA drain
- ARM solo hace setup, no interviene en compute

### Paso 4: Layer controller
- FSM que encadena múltiples layers sin ARM
- Swap buffers entre layers (input ↔ output)
