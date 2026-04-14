# P_17 — DPU multi-primitiva

Sucesor de P_16 que permite ejecutar conv, maxpool, leaky_relu y elem_add sobre la misma infraestructura DMA + BRAM + DataMover, seleccionados por un registro.

## Objetivo

- 4 tipos de layer ejecutables por el mismo HW:
  - `conv` (reutiliza `conv_engine_v3` de P_13)
  - `maxpool` (reutiliza `maxpool_unit` de P_12)
  - `leaky_relu` (reutiliza `leaky_relu` de P_9)
  - `elem_add` (reutiliza `elem_add` de P_11)
- Selección por registro AXI-Lite `REG_LAYER_TYPE`
- Concat / Upsample / Routing: **en ARM**, no llegan al DPU (se hace reordenando direcciones DDR entre capas)

## Diferencias con P_16

| Aspecto | P_16 | P_17 |
|---|---|---|
| Primitiva | solo `conv_engine_v3` | 4 primitivas seleccionables |
| Wrapper | `conv_stream_wrapper` | `dpu_stream_wrapper` (nombre nuevo) |
| Reg `layer_type` | no existe | **0x54 (nuevo)** |
| Registros config | 21 (conv only) | unión de config de las 4 primitivas |
| Input BRAM | 1 (ent/pesos/bias/out) | idéntico |
| Output path | DataMover S2MM | idéntico |
| elem_add necesita 2 inputs | n/a | A ocupa la 1ª mitad BRAM, B la 2ª mitad |

## Arquitectura RTL

**IMPORTANTE:** las primitivas no-conv de P_9/P_11/P_12 son **datapath stream puros**:
- `maxpool_unit`: `x_in` (signed 8) + `valid_in` + `clear` → `max_out`, `valid_out`
- `leaky_relu`: `x_in` + `valid_in` + params (M0_pos/neg, n_pos/neg, zps) → `y_out` + `valid_out`
- `elem_add`: `a_in, b_in` + `valid_in` + params → `y_out` + `valid_out`

Ninguna accede a memoria; operan byte-a-byte. Solo `conv_engine_v3` tiene interfaz DDR propia (accesos random).

Esto implica que el wrapper necesita **dos modos de datapath**:

```
                    AXI-Lite GP0
                         │
                         ▼
                ┌─────────────────────┐
                │   reg file          │  REG_LAYER_TYPE
                └──────┬──────────────┘
                       │
                       ▼
                ┌─────────────────────┐
                │  FSM top            │  LOAD → COMPUTE → DRAIN
                │                     │
                │  COMPUTE:            │
                │   if layer_type==CONV:
                │     conv_engine.start; wait done  (usa BRAM random)
                │   else:
                │     stream_engine.start;           (usa BRAM secuencial
                │     wait done                       + feeds primitiva byte-a-byte)
                └──────┬──────────────┘
                       │
      ┌────────────────┴─────────────────────┐
      ▼                                      ▼
  ┌────────────────┐                  ┌─────────────────────────┐
  │ conv_engine_v3 │                  │  stream_engine_i        │
  │ (random BRAM   │                  │  - reads BRAM seq byte   │
  │  accesor)      │                  │  - feeds active prim     │
  │                │                  │  - captures y_out        │
  │                │                  │  - writes BRAM seq out   │
  │                │                  │                          │
  │                │                  │  primitivas dentro:      │
  │                │                  │  ┌──────┐ ┌──────────┐  │
  │                │                  │  │maxp. │ │leaky_relu│  │
  │                │                  │  │unit  │ │          │  │
  │                │                  │  └──────┘ └──────────┘  │
  │                │                  │       ┌──────────┐      │
  │                │                  │       │elem_add  │      │
  │                │                  │       └──────────┘      │
  └───────┬────────┘                  └────────────┬────────────┘
          │ ddr_rd/wr                               │ ddr_rd/wr
          └───────────────────┬─────────────────────┘
                              │
                              ▼  (mux por layer_type+busy)
                     ┌──────────────┐
                     │  BRAM 4 KB   │
                     └──────┬───────┘
                            │
                            ▼ m_axis + tkeep
                     ┌──────────────┐
                     │  DataMover   │  (idéntico P_16)
                     │   S2MM       │
                     └──────────────┘
```

El `stream_engine_i` es un FSM pequeño que:
1. Lee BRAM secuencialmente a partir de `addr_input` hasta `n_words × 4 - 1`
2. Para cada byte emite `valid_in=1, x_in=byte` (o `a_in/b_in` para elem_add con dos lecturas alternadas)
3. Espera `valid_out=1` de la primitiva
4. Escribe `y_out` en BRAM a partir de `addr_output`
5. Termina al consumir todo el input
6. Señaliza `done` al FSM top

Para elem_add: lee 2 bytes (A[i], B[i]) por pulse `valid_in`, output 1 byte.
Para maxpool: lee 4 bytes (ventana 2×2) con `clear` al inicio de cada ventana.
Para leaky_relu: 1 byte in → 1 byte out, trivial.

## Layout BRAM por tipo de layer

### CONV (igual P_16)
```
0x000: output (conv escribe)
0x200: input activations
0x300: weights OHWI
0x6C0: bias (int32)
```

### MAXPOOL
```
0x000: output
0x200: input activations
(no pesos, no bias)
```

### LEAKY_RELU
```
(si BRAM BYPASS: DMA directo al modulo, no hay mapping en BRAM)
Regs necesarios: x_zp, y_zp, M0_pos, n_pos, M0_neg, n_neg
                 (dos n DIFERENTES — cada rama tiene su propio shift)
```

### ELEM_ADD (dual input)
```
0x000: output
0x000..0x7FF: input A (cargado en BRAM via LOAD phase)
(input B entra via s_axis stream mientras se lee A del BRAM)
Regs necesarios: a_zp, b_zp, y_zp, M0_a, M0_b, n_shift
                 (una sola n, el elem_add de P_11 usa shift comun
                  n = min(n_a, n_b) ya pre-computado desde Python)
```

## Register map tentativo

Mantenemos los de P_16 (0x00-0x50) y añadimos:

| Offset | Nombre | Uso |
|---:|---|---|
| 0x00-0x50 | (igual P_16) | ctrl, n_words, c_in/out, h/w, ksp, x_zp, w_zp, M0, n_shift, y_zp, addr_*, ic_tile_size, pad_* |
| **0x54** | **layer_type** | **0=CONV, 1=MAXPOOL, 2=LEAKY_RELU, 3=ELEM_ADD** |
| 0x58 | M0_neg | LeakyRelu: multiplier rama negativa (M0_pos reusa REG_M0 @ 0x24) |
| 0x5C | n_neg | LeakyRelu: shift rama negativa (n_pos reusa REG_N_SHIFT @ 0x28) |
| 0x60 | b_zp | Elem_add: zero-point input B (a_zp reusa REG_X_ZP @ 0x1C) |
| 0x64 | M0_b | Elem_add: multiplier input B (M0_a reusa REG_M0 @ 0x24) |

Para maxpool no hay regs extra (usa c_in, h_in, w_in, pool_size implícito 2x2).
Reuso de regs existentes:
- `REG_X_ZP (0x1C)` = x_zp para leaky / a_zp para elem_add
- `REG_M0 (0x24)` = M0_pos para leaky / M0_a para elem_add
- `REG_N_SHIFT (0x28)` = n_pos para leaky / n_shift común para elem_add
- `REG_Y_ZP (0x2C)` = y_zp para todas las primitivas

## Flujo de ejecución

Idéntico a P_16 para el ARM, solo añade `conv_write(REG_LAYER_TYPE, TYPE)` antes del `cmd_start`:

```c
conv_write(REG_LAYER_TYPE, LAYER_TYPE_LEAKY_RELU);
conv_write(REG_C_IN,       c_in);
// ... otros regs según primitiva
conv_write(REG_ADDR_INPUT, 0x200);
conv_write(REG_ADDR_OUTPUT, 0x000);
// LOAD via DMA (igual P_16)
// START → la FSM del wrapper selecciona qué primitiva arranca
```

## Plan de implementación

### Fase 1: skeleton + REG_LAYER_TYPE + conv passthrough (~2h)
- Crear P_17 dir (✓)
- Copiar `create_bd.tcl`, `dm_s2mm_ctrl.vhd` de P_16
- Crear `dpu_stream_wrapper.vhd` añadiendo REG_LAYER_TYPE + mux mínimo
- Solo rama CONV activa (passthrough, equivalente a P_16)
- Sim + HW verify: layer_005 debe pasar con layer_type=0

### Fase 2: integrar leaky_relu (~2h)
- Añadir instance de `leaky_relu` del P_9
- Mux ddr_* del leaky_relu al BRAM
- Mux start/done
- Regs nuevos: M0_neg, n_neg
- Test: layer_006 (leaky_relu puro de YOLOv4)

### Fase 3: integrar maxpool (~1h)
- Añadir `maxpool_unit` de P_12
- Similar integración
- Test: layer con maxpool 2×2

### Fase 4: integrar elem_add (~2h)
- Añadir `elem_add` de P_11
- Requiere 2 regions en BRAM (A y B)
- Regs nuevos: b_zp, M0_b, addr_input_b
- Test: layer con residual connection

### Fase 5: regression + timing (~1h)
- Re-correr las 110 capas P_16 en P_17 (deben seguir passing con layer_type=0)
- Verificar timing WNS ≥ 0
- Verificar utilización aceptable

### Fase 6: tests multi-primitiva (~2h)
- Sweep de layers de los 4 tipos
- Mini-pipeline: conv → leaky_relu → maxpool (3 ejecuciones seriadas desde ARM)

**Total estimado:** ~10h = 1 día largo.

## Riesgos identificados

1. **Recursos del PL**: 4 primitivas simultáneas pueden no caber
   - Mitigación: las 4 no ejecutan al mismo tiempo, pero Vivado las sintetiza todas. Si revienta, consider refactor a single-engine configurable.
2. **Interfaces ddr_* incompatibles**: cada primitiva fue diseñada standalone, puede tener signals diferentes
   - Revisar antes de instanciar
3. **Timing**: más lógica = más fan-out en la BRAM
   - Plan de mitigación: registro de pipeline en el mux si WNS peligra

## Lo que NO se hace en P_17

- Concat / Upsample (en ARM, no HW)
- Double-buffering de pesos
- Ampliación de BRAM (sigue en 4 KB)
- Runtime C que encadene capas (se deja para P_18)
- IRQ-driven (sigue polling)
