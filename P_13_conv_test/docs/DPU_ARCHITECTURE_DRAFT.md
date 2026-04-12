# DPU Architecture Draft — YOLOv4 INT8 on ZedBoard

> **Draft / brainstorm — 2026-04-11.** Propuesta de arquitectura completa para
> la DPU que ejecutará YOLOv4 INT8 end-to-end en ZedBoard (xc7z020) usando el
> `conv_engine` ya verificado como núcleo de cómputo.
>
> Este documento complementa `CONV_ENGINE_DESIGN.md` (que cubre solo la FSM
> del conv). Aquí hablamos del SISTEMA: buffers, DMAs, orquestación, dataflow
> inter-layer y controladores.

---

## 0. TL;DR

```
  DDR3 ──(AXI-DMA)──► [w_bram ping/pong] ──────────┐
                                                     │
  DDR3 ──(AXI-DMA)──► [x_bram] ────► conv_engine ───┤
                                       +            │
                                      mac_array     │
                                       +            │
                                      requantize    │
                                                     │
                                     ◄──[y_bram]────┘
                                           │
                           (keep en PL si cabe, o ──(AXI-DMA)──► DDR3)
```

- **conv_engine** ya existe y es bit-exact.
- **Buffers BRAM** dedicados para w/x/y/bias, instanciados con `xpm_memory`.
- **AXI-DMA** de Xilinx mueve datos DDR↔BRAM (S2MM y MM2S).
- **layer_controller** es una FSM nueva que orquesta: programa DMAs, espera,
  arranca conv_engine, captura y, decide si drena a DDR o pasa al siguiente.
- **ARM (PS)** solo hace setup al principio y lee el resultado final — NO
  interviene en el cómputo inter-layer.

---

## 1. Restricciones duras (recursos)

Para xc7z020 (ZedBoard):

| Recurso | Disponible | Presupuesto objetivo |
|---|---|---|
| BRAM36 | 140 (≈ 630 KB) | ≤ 100 BRAM36 (≈ 450 KB) |
| DSP48E1 | 220 | 36 usado ya (mac_array + requantize) |
| LUT | 53,200 | ≤ 35,000 |
| FF | 106,400 | ≤ 40,000 |
| HP port | 4 | usamos 1 (HP0) |

**Lección P_13:** no confiar en Vivado para inferir BRAMs de arrays VHDL con
accesos multi-port. Usar `xpm_memory_tdpram` / `sdpram` explícitas.

---

## 2. Layer cake — los layers de YOLOv4 que hay que soportar

YOLOv4 tiene ~150 capas. Por tipo:

| Tipo | Qué hace | Hardware |
|---|---|---|
| QLinearConv 3×3 | el 90 % del cómputo | **conv_engine v2** ✓ |
| QLinearConv 1×1 | "expansion/projection" | **conv_engine v2** ✓ (ksize=1) |
| MaxPool 2×2 | downsample | **maxpool** ✓ |
| LeakyReLU 0.1 | activación | **leaky_relu** ✓ |
| Add (residual) | suma eltwise quantizada | **elem_add** ✓ |
| Concat | concatena canales | **solo address gen** (gratis) |
| Upsample 2× | nearest neighbor | **solo address gen** (gratis) |
| Detect head | post-proc sigmoid, etc | **ARM** (no crítico) |

Las primitivas críticas ya están todas verificadas en HW. Lo que falta es
el **pegamento**: memoria, DMA y control.

---

## 3. Jerarquía de memoria propuesta

### 3.1 Cuatro buffers BRAM principales

| Buffer | Tamaño | Primitiva | Uso |
|---|---|---|---|
| `x_bram` | 256 KB (objetivo) | xpm_memory_sdpram ×N | input tile del layer actual |
| `y_bram` | 256 KB (objetivo) | xpm_memory_sdpram ×N | output del layer actual |
| `w_bram_ping` | 4 KB–16 KB | xpm_memory_sdpram | weight tile actual |
| `w_bram_pong` | 4 KB–16 KB | xpm_memory_sdpram | next weight tile (precarga) |
| `bias_bram` | 2 KB | xpm_memory_sdpram | biases del OC tile actual |

**Nota:** 256 KB `x_bram` + 256 KB `y_bram` = 512 KB. Eso es 114 BRAM36.
Apretado pero viable si los swapeamos (x e y son turnos: al final de cada
layer, `y_bram` pasa a ser `x_bram` del siguiente).

### 3.2 Ping-pong en pesos (clave)

Los pesos son el bottleneck: 4.7 MB para layer_148 solo. **NO caben en PL.**
Solución: streaming por tiles.

- `w_bram_ping`: pesos del tile que conv_engine está consumiendo AHORA
- `w_bram_pong`: DMA los está cargando EN PARALELO desde DDR
- Cuando conv_engine termina el tile actual: swap pointers, `w_bram_pong`
  pasa a ser "actual" y el otro empieza a precargar el siguiente.

Esto oculta completamente la latencia DDR siempre que `compute_time >=
load_time` por tile. Para un tile típico (16×32×3×3 = 4608 B) a DDR3
1066 MHz (teórico ~2 GB/s via HP port) → load_time ≈ 2.3 μs. El compute_time
del tile son cientos de ciclos de MAC → del orden de microsegundos. Queda
cómodo.

### 3.3 Dataflow inter-layer (lo importante)

En vez de drenar `y_bram` → DDR y recargarlo como `x_bram` del siguiente layer
(DDR→PL→DDR→PL, con el coste de 2×256 KB de tráfico), los swapeamos en sitio:

```
after layer N:
    (x_bram, y_bram) = (y_bram, x_bram)
    [x_bram ya tiene la entrada del layer N+1, gratis]
```

Implementación: los nombres son aliases del layer_controller; a nivel HW los
dos bancos se alternan en qué puerto se conectan al conv_engine.

**Excepciones:**
- Primera capa: `x_bram` cargado por DMA desde DDR (imagen de entrada)
- Última capa (salida del detector): `y_bram` drenado por DMA a DDR
- Concat/Upsample/Residual: requieren gather scatter especial (ver §5)

---

## 4. Interconexión AXI

### 4.1 Diagrama

```
  PS GP0 (slave) ─── AXI-Lite ──► layer_controller ──► conv_engine cfg
                                    │                     │
                                    └── axi_dma_wt cfg    ...
                                    └── axi_dma_io cfg

  PS HP0 (64-bit master) ◄── axi_dma_wt ◄── DDR3 → w_bram_ping/pong
  PS HP0            (shared) ◄── axi_dma_io ◄── DDR3 ↔ x_bram / y_bram
```

### 4.2 DMA instances

- **axi_dma_wt**: MM2S only. Sirve pesos desde DDR a `w_bram`. 32-bit.
  SG opcional (puede ser simple mode: descriptor manual por tile).
- **axi_dma_io**: MM2S + S2MM. Carga inputs / drena outputs entre DDR y
  `x_bram`/`y_bram`. 64-bit para aprovechar el ancho del HP port.

(Alternativa: un solo DMA y compartir, complica el scheduling.)

---

## 5. Orquestador — `layer_controller`

Es un nuevo módulo (FSM) que ejecuta un **programa de capas** grabado en un
pequeño script BRAM o en registros AXI-Lite del PS.

### 5.1 Formato del programa

Cada layer instruction es un struct (por ejemplo 128 bits) con:

```
struct layer_instr {
    op_type     : 3 bits   // CONV, ADD, MAXPOOL, LEAKY, UPSAMPLE, CONCAT
    k, s, pad   : 6 bits   // conv params
    c_in, c_out : 20 bits
    h, w        : 20 bits
    w_addr_ddr  : 25 bits  // donde están los pesos en DDR
    bias_addr   : 25 bits
    x_select    : 1 bit    // qué banco es el input
    y_select    : 1 bit    // qué banco es el output
    next_skip   : 1 bit    // saltar swap (para residual/concat)
    M0, n_shift, zps : ...
}
```

El PS escribe el script al inicio; el controller lo ejecuta instrucción por
instrucción sin intervención del ARM.

### 5.2 FSM del controller (high-level)

```
IDLE → LOAD_INSTR → CONFIG_DMAs → START_DMAs → WAIT_DMAs →
CONFIG_ENGINE → START_ENGINE → WAIT_ENGINE → SWAP_BUFFERS → NEXT_INSTR
```

Con doublebuffer de pesos: `LOAD_INSTR` puede arrancar el DMA del TILE
siguiente mientras `WAIT_ENGINE` del tile actual sigue.

### 5.3 Por qué NO hacer esto con el ARM

- ARM a 666 MHz corriendo C bare-metal puede hacer la misma orquestación
  pero cada configuración de DMA cuesta ~100 ns de AXI-Lite, y hay 150
  layers × múltiples tiles. Es >> 1 ms solo de setup por imagen.
- Un layer_controller en PL lo hace en 1-2 ciclos por operación.
- Además el ARM podría estar haciendo postproc del detector en paralelo.

---

## 6. Dataflow especial (Concat / Upsample / Residual)

YOLOv4 usa estas operaciones no-triviales:

### 6.1 Residual (layer_a + layer_b)

- Necesitamos 2 banks de input a la vez (layer_a en `x_bram_a`, layer_b en
  `x_bram_b`) → re-necesitamos doble buffer en la sección de entrada.
- O bien: layer_b se dreina a DDR al terminar, y se recarga cuando toca
  el add. Overhead ≈ tamaño del feature map.
- **Decisión preliminar:** drain-and-reload. Es más simple y el overhead
  es tolerable (el residual son capas intermedias, no el 90 % del cómputo).

### 6.2 Upsample 2× (nearest)

- Puramente address gen: `x[i/2][j/2]` en vez de `x[i][j]`.
- El layer_controller inyecta esta transformación al conv_engine via una
  opción "upsample input" en el struct de instrucción.
- **Coste HW:** 0.

### 6.3 Concat

- Físicamente significa que el siguiente layer lee de DOS `y_bram` distintos
  con offsets de canal distintos.
- Solución más simple: `concat` es un no-op en memoria si los dos inputs
  están contiguos en el mismo `y_bram`. El layer_controller orquesta los
  dos layers anteriores para que escriban en el mismo banco con offsets
  distintos.

---

## 7. Plan de implementación (incremental, de menos a más riesgo)

1. **P_13 (ahora):** conv_engine + fake-DDR wrapper en HW. Verificar un
   conv único bit-exact en silicio.
2. **P_14:** conv_engine + `xpm_memory_sdpram` real para x/w/y/bias + AXI-DMA
   para carga inicial de DDR. ARM orquesta un SOLO layer.
3. **P_15:** layer_controller básico que encadena 2 layers consecutivos con
   swap x/y sin intervención ARM.
4. **P_16:** ping-pong de pesos con doble buffer + DMA concurrent.
5. **P_17:** soporte residual (dos bancos de input).
6. **P_18:** programa de layers completo para un subset de YOLOv4 (p.ej.
   las primeras 10 capas).
7. **P_19:** pipeline completo YOLOv4 end-to-end.

Cada paso añade UNA cosa nueva, se verifica en HW, y se sigue. Nada de
saltos grandes.

---

## 8. Preguntas abiertas para discutir con el user

1. **¿Drain-and-reload vs doble banco de input?** Para residual.
   Mi voto: drain-and-reload (más simple).
2. **¿Un DMA o dos?** Un DMA compartido para w y x es más barato
   (menos BRAMs del DMA, menos interconnect) pero complica el scheduling.
3. **¿Layer program en BRAM o en DDR?** En DDR es flexible pero añade
   latencia. En BRAM está limitado a ~100 layers con 256-bit instr.
4. **¿Se queda siempre en INT8 o hay layers FP32 al final?** Las detection
   heads suelen ser float — ¿las hacemos en ARM o rehacemos una pipeline
   FP16 en PL?
5. **¿Batch=1 o batch>1?** Con batch>1 podemos amortizar el peso de pesos.
   Pero complica los tiles. Probablemente batch=1 para empezar.

---

## 9. Estado actual (2026-04-11)

- ✅ `conv_engine v1` verificado en simulación (bit-exact)
- ✅ `conv_engine v2` (tiling) verificado en simulación (bit-exact)
- ✅ `mac_array`, `maxpool`, `elem_add`, `leaky_relu`, `requantize` verificados
     en simulación y en HW (1083 tests pasaron en ZedBoard)
- 🔄 `conv_engine` en HW: bloqueado por el wrapper de test (P_13) — recién
     reescrito con `xpm_memory_tdpram`, impl en curso
- ❌ `layer_controller`, `axi_dma` integration, programa de layers: **no
     empezado**
