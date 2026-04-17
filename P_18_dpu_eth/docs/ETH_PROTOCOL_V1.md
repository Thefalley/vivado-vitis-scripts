# Protocolo ETH V1 — PC ↔ ZedBoard (DPU YOLOv4)

> **Estado:** propuesta congelada para implementación.
> **Reemplaza a:** `ETH_PROTOCOL.md` (V0, sólo WRITE_DDR / READ_DDR genéricos).
> **Objetivo:** cargar pesos + input, ejecutar las 255 capas de YOLOv4 layer a layer y verificar cada activación contra ONNX bit-exact, sin que PC y ARM se desincronicen silenciosamente.

---

## 1. Filosofía de diseño

**El PC es el cerebro. El ARM es el ejecutor.**

| | PC (Python, cliente) | ARM (bare-metal, server) |
|---|---|---|
| Conoce mapa de memoria DDR | **Sí, autoridad única** | No — sólo obedece direcciones que le dan |
| Gestiona allocations | Sí | No — nunca decide dónde va algo |
| Orquesta orden de ejecución | Sí | No |
| Valida prerequisitos | Sí (antes de mandar) | Sí (doble check defensivo) |
| Ejecuta primitivas DPU | No | **Sí (único que toca MMIO)** |
| Guarda estado de la red | Sí (ground truth) | Sólo libro de registros para diagnóstico |

Consecuencia: si algún día el PC decide cambiar el layout DDR, **no toca firmware**. Sólo manda direcciones distintas.

---

## 2. Capa de transporte

| Parámetro | Valor |
|---|---|
| Protocolo | TCP (raw lwIP en ARM, `socket` estándar en Python) |
| IP board | `192.168.1.10` (estática) |
| IP PC (cable) | `192.168.1.100` (estática) |
| Puerto control | **7001** |
| Endianness | Little-endian en ambos lados — sin conversión |
| Encoding | Binario puro, structs packed |
| Conexión | Una sola a la vez (no concurrencia) |
| TCP_NODELAY | Habilitado en el cliente — baja latencia para comandos pequeños |

---

## 3. ¿Cabe todo en RAM?

ZedBoard tiene **512 MB de DDR3**. Lo estático (pesos + input + cfg) son ~62 MB, cabe sobrado.

Lo que **no cabe** simultáneamente es todas las activaciones intermedias vivas (sumadas pasan de 300 MB). Por eso el **PC aplica liberación agresiva**: cada activación vive sólo hasta que sus consumidores la han leído. El PC calcula el plan de memoria leyendo el ONNX antes de empezar y emite `out_addr[255]` reutilizando slots de DDR.

| Tipo | Tamaño | ¿Persiste? |
|---|---:|---|
| Pesos (110 CONV) | ~61 MB | Sí, toda la inferencia |
| Bias (110 CONV) | ~480 KB | Sí |
| Input imagen | 519 KB | Sí |
| Config capas | 18 KB | Sí |
| Activaciones intermedias | pico **~30 MB** con liberación | Sólo mientras tengan consumidores pendientes |
| Activaciones "skip" (PANet, residuals) | ~10 MB extra | Viven decenas de capas |

**Heurística liberación**:
- Activación normal: liberada en el bump allocator tras ejecutar la capa siguiente.
- Activación skip/residual: marcada en el plan del PC con `last_use_layer`, liberada en esa capa.
- Decisiones del PC → reflejadas en `out_addr` del cfg. El ARM no gestiona memoria, sólo obedece.

## 4. Mapa de memoria DDR (autoridad: PC)

Definido por el cliente, escrito literalmente en `yolov4_host.py` como constantes. El ARM **no hardcodea ninguna dirección de datos**.

```
0x0010_0000 ─┐
             │  (reservado para FSBL + ELF + stack + heap ARM)
0x0FFF_FFFF ─┘

0x1000_0000 ─┐  INPUT (imagen 416x416x3 cuantizada) — 519 168 B
0x1000_FFFF ─┘
0x1010_0000 ─┐  MAILBOX runtime (status table, debug scratch)
0x102F_FFFF ─┘
0x1100_0000 ─┐  LAYER_CFG array (255 × 72 B = 18 360 B, alineado)
0x110F_FFFF ─┘
0x1200_0000 ─┐
             │  WEIGHTS BLOB — 61.45 MB (todos los pesos CONV pre-extraídos)
0x15FF_FFFF ─┘
0x1600_0000 ─┐
             │  ACTIVATIONS pool — ~96 MB, gestionado por el PC con bump allocator
0x1BFF_FFFF ─┘
0x1C00_0000 ─┐
             │  reservado / framebuffer HDMI futuro
0x1FFF_FFFF ─┘
```

El ARM acepta escrituras dentro de estos rangos (ver `eth_addr_is_safe()`), rechaza fuera.

---

## 4. Header común (8 bytes)

Todo mensaje PC→ARM y ARM→PC empieza con este header:

```
 offset  size  campo         descripción
   0      1    opcode        ver §6
   1      1    flags         bit0 = HAS_DATA_HDR (el payload empieza con data_hdr_t)
                             bit1 = EXPECT_CRC    (comparar crc32 tras los bytes)
                             bit2..7 reservado (0)
   2      2    tag           identificador único del request (el ARM lo devuelve en la rsp)
   4      4    payload_len   bytes del payload que siguen
```

`tag`: lo genera el PC como contador que se incrementa con cada request. El ARM lo copia tal cual en la respuesta. Si el PC recibe un tag que no esperaba → error de sincronización, cierra conexión.

---

## 5. Sub-header de datos (`data_hdr_t`, 16 bytes)

Cuando el payload transporta un bloque de datos (pesos, bias, activación, cfg, input), va precedido por este sub-header. Es el "etiquetado" que pediste: el ARM valida que lo que recibe tiene sentido **antes** de escribirlo a DDR.

```c
typedef struct __attribute__((packed)) {
    uint16_t layer_idx;     /* 0..254 — qué layer (0xFFFF si no aplica, p.ej. INPUT global) */
    uint8_t  kind;          /* tipo de dato, ver tabla abajo */
    uint8_t  dtype;         /* 0=int8, 1=int32, 2=uint8 */
    uint32_t ddr_addr;      /* dirección absoluta donde escribir */
    uint32_t expected_len;  /* bytes de datos que siguen (debe = payload_len - 16) */
    uint32_t crc32;         /* CRC32 (IEEE 802.3) de los expected_len bytes que siguen */
} data_hdr_t;               /* total: 16 bytes */
```

### Tabla de `kind`

| valor | nombre | significado |
|:---:|---|---|
| 0 | `KIND_NONE` | payload genérico sin semántica (raw WRITE_DDR) |
| 1 | `KIND_WEIGHTS` | pesos de una capa CONV |
| 2 | `KIND_BIAS` | bias de una capa CONV |
| 3 | `KIND_INPUT` | imagen de entrada (una vez, layer 0 input) |
| 4 | `KIND_ACTIVATION_IN` | activación intermedia inyectada (debug: cortocircuitar capas) |
| 5 | `KIND_LAYER_CFG` | struct `layer_cfg_t` de 72 B (§8) |
| 6 | `KIND_ACTIVATION_OUT` | sólo ARM→PC: activación producida tras ejecutar |

### Validación en el ARM (antes de escribir un solo byte)

```
1. layer_idx ≤ 254 o 0xFFFF    → sino ERR_BAD_LAYER
2. kind ∈ {1..6}                → sino ERR_BAD_KIND
3. dtype ∈ {0, 1, 2}            → sino ERR_BAD_DTYPE
4. ddr_addr + expected_len dentro de rango DDR_SAFE → sino ERR_BAD_ADDR
5. expected_len == hdr.payload_len - 16            → sino ERR_LEN_MISMATCH
6. kind coherente con el opcode (p.ej. CMD_WRITE_WEIGHTS exige kind=1) → sino ERR_KIND_MISMATCH
```

Y después de escribir:

```
7. CRC32 calculado = crc32 del header → sino ERR_CRC (ARM reporta pero NO deshace la escritura)
```

---

## 6. Opcodes

### 6.1 Comandos (PC → ARM)

| opcode | nombre | payload | semántica |
|:---:|---|---|---|
| `0x00` | `CMD_HELLO` | `u32 proto_ver=1`, `u32 layer_cfg_size=72`, `u32 data_hdr_size=16`, `u32 flags` | Handshake. ARM responde `ACK` con sus constantes. Si mismatch → cierra conexión. |
| `0x01` | `CMD_PING` | — | Sanity check. ARM responde `PONG`. |
| `0x02` | `CMD_WRITE_RAW` | `u32 addr` + N bytes | WRITE_DDR genérico sin kind. Para bring-up o escrituras sin semántica. Compatible con V0. |
| `0x03` | `CMD_READ_RAW` | `u32 addr`, `u32 len` | READ_DDR genérico. ARM responde `RSP_DATA`. |
| `0x10` | `CMD_WRITE_INPUT` | `data_hdr_t{kind=3}` + bytes | Escribe imagen. Marca `g_state.input_loaded=1`. |
| `0x11` | `CMD_WRITE_WEIGHTS` | `data_hdr_t{kind=1, layer_idx=i}` + bytes | Marca `g_state.layer[i].w_loaded=1`. |
| `0x12` | `CMD_WRITE_BIAS` | `data_hdr_t{kind=2, layer_idx=i}` + bytes | Marca `g_state.layer[i].b_loaded=1`. |
| `0x13` | `CMD_WRITE_ACTIVATION_IN` | `data_hdr_t{kind=4, layer_idx=i}` + bytes | Inyectar activación para debug (forzar la entrada de una capa). |
| `0x14` | `CMD_WRITE_CFG` | `data_hdr_t{kind=5, layer_idx=i}` + `layer_cfg_t` | Marca `g_state.layer[i].cfg_set=1`. |
| `0x20` | `CMD_EXEC_LAYER` | `u16 layer_idx`, `u16 flags` | Valida prereqs → despacha según `op_type` → responde ACK con `{status, cycles, out_crc}`. |
| `0x21` | `CMD_RUN_RANGE` | `u16 first`, `u16 last` | Ejecuta capas [first..last] en orden sin comunicación intermedia. ACK final. |
| `0x30` | `CMD_READ_ACTIVATION` | `u32 ddr_addr`, `u32 len` | Lee activación. Response = header `RSP_DATA` + `data_hdr_t{kind=6}` + bytes. |
| `0x40` | `CMD_GET_STATE` | — | Devuelve el `g_state` completo (libro de registros, §10). |
| `0x41` | `CMD_RESET_STATE` | — | Limpia `g_state` (no toca DDR, sólo flags). |
| `0x42` | `CMD_DPU_INIT` | — | `dpu_init()` (init AXI DMA). |
| `0x43` | `CMD_DPU_RESET` | — | `dpu_reset()` (pulso de reset al wrapper). |
| `0xFF` | `CMD_CLOSE` | — | Cierra conexión. |

### 6.2 Respuestas (ARM → PC)

| opcode | nombre | payload |
|:---:|---|---|
| `0x81` | `RSP_PONG` | 8 bytes ASCII `"P_18 OK\0"` |
| `0x82` | `RSP_ACK` | `u32 status` + extra según comando (ver §7) |
| `0x83` | `RSP_DATA` | `data_hdr_t{kind=6}` + bytes (para READ_ACTIVATION) **o** bytes crudos (para CMD_READ_RAW) |
| `0x8E` | `RSP_ERROR` | `u32 err_code` + `u32 aux` (ver §9) |

---

## 7. Extras del `RSP_ACK` por comando

| Comando que disparó | Extra tras `u32 status` |
|---|---|
| `CMD_HELLO` | `u32 proto_ver`, `u32 layer_cfg_size`, `u32 data_hdr_size`, `u32 capabilities` |
| `CMD_WRITE_*` | `u32 bytes_written`, `u32 crc_echo` (si flag `EXPECT_CRC`) |
| `CMD_EXEC_LAYER` | `u32 cycles`, `u32 out_crc32`, `u32 out_bytes` |
| `CMD_GET_STATE` | `u32 n_layers`, seguido de `layer_state_t × n_layers` |
| Resto | (vacío) |

**`out_crc32` clave**: el ARM calcula CRC de la activación justo tras producirla. El PC lo compara con el CRC del tensor ONNX de referencia. Si coincide → bit-exact confirmado **sin transferir la activación**. Ahorra ~10× tiempo en el barrido.

---

## 8. Struct `layer_cfg_t` (72 bytes)

```c
typedef struct __attribute__((packed)) {
    /* ---- 12 bytes: header semántico ---- */
    uint8_t  op_type;          /* 0=CONV 1=LEAKY 2=POOL_MAX 3=ELEM_ADD 4=CONCAT 5=RESIZE */
    uint8_t  act_type;         /* 0=NONE 1=LEAKY (fusionado) — sólo para op_type=CONV */
    uint16_t layer_idx;        /* redundante (info + debug) */
    uint32_t in_addr;          /* DDR operando principal */
    uint32_t in_b_addr;        /* DDR operando B (ADD, CONCAT) / 0 */

    /* ---- 8 bytes ---- */
    uint32_t out_addr;         /* DDR destino */
    uint32_t w_addr;           /* DDR pesos (CONV) / 0 */

    /* ---- 8 bytes ---- */
    uint32_t b_addr;           /* DDR bias (CONV) / 0 */
    uint16_t c_in;             /* canales entrada */
    uint16_t c_out;            /* canales salida */

    /* ---- 8 bytes: dimensiones espaciales ---- */
    uint16_t h_in;
    uint16_t w_in;
    uint16_t h_out;
    uint16_t w_out;

    /* ---- 8 bytes: conv-específico ---- */
    uint8_t  kh, kw;
    uint8_t  stride_h, stride_w;
    uint8_t  pad_top, pad_bottom, pad_left, pad_right;

    /* ---- 4 bytes: tiling + requantize ---- */
    uint8_t  ic_tile_size;     /* 0 = sin IC tiling; si >0, el ARM hace strip-mining */
    uint8_t  post_shift;       /* shift amount tras MAC */
    int16_t  leaky_alpha_q;    /* slope cuantizada Q15 (fused LEAKY en CONV) */

    /* ---- 12 bytes: quantization (ELEM_ADD y requantize) ---- */
    int32_t  a_scale_m;        /* multiplicador fixed-point operando A */
    int32_t  b_scale_m;        /* multiplicador fixed-point operando B */
    int8_t   a_scale_s;        /* shift operando A */
    int8_t   b_scale_s;        /* shift operando B */
    int8_t   out_zp;           /* zero-point salida */
    int8_t   out_scale_s;      /* shift salida */

    /* ---- 12 bytes: reserved para ampliación ---- */
    uint32_t reserved[3];
} layer_cfg_t;  /* total: 72 bytes */

_Static_assert(sizeof(layer_cfg_t) == 72, "layer_cfg_t must be 72 bytes");
```

### Mapping `op_type` → llamada en el ARM

| op_type | Nombre | Función runtime |
|:---:|---|---|
| 0 | `OP_CONV` | `dpu_exec_conv(cfg)` — incluye LEAKY fusionada si `act_type=1` |
| 1 | `OP_LEAKY` | `dpu_exec_leaky(cfg)` — standalone (raro en YOLOv4) |
| 2 | `OP_POOL_MAX` | `dpu_exec_pool(cfg)` |
| 3 | `OP_ELEM_ADD` | `dpu_exec_add(cfg)` |
| 4 | `OP_CONCAT` | copia plana `in_addr` + `in_b_addr` → `out_addr` (sin DPU) |
| 5 | `OP_RESIZE` | upsample 2× nearest (sin DPU, loop ARM) |

---

## 9. Códigos de error

| err_code | nombre | significado | aux |
|:---:|---|---|---|
| `0x00` | `STATUS_OK` | éxito | — |
| `0x01` | `ERR_INVALID_CMD` | opcode desconocido | 0 |
| `0x02` | `ERR_BAD_ADDR` | dirección fuera de rango seguro | ddr_addr |
| `0x03` | `ERR_DPU_TIMEOUT` | wrapper stall | layer_idx |
| `0x04` | `ERR_DPU_FAULT` | DMA/DataMover fault | fault_reg |
| `0x05` | `ERR_BUFFER_OVERRUN` | payload > buffer ARM | payload_len |
| `0x10` | `ERR_BAD_LAYER` | layer_idx > 254 | layer_idx recibido |
| `0x11` | `ERR_BAD_KIND` | kind no reconocido | kind recibido |
| `0x12` | `ERR_BAD_DTYPE` | dtype no soportado | dtype |
| `0x13` | `ERR_LEN_MISMATCH` | `expected_len` != `payload_len - 16` | diferencia |
| `0x14` | `ERR_KIND_MISMATCH` | kind no coincide con opcode | opcode |
| `0x15` | `ERR_CRC` | CRC32 incorrecto | crc_calculado |
| `0x20` | `ERR_NOT_CONFIGURED` | EXEC_LAYER sin CMD_WRITE_CFG previo | layer_idx |
| `0x21` | `ERR_MISSING_DATA` | falta weights/bias/input antes de EXEC | mask con bits faltantes |
| `0x22` | `ERR_DEP_NOT_READY` | ELEM_ADD con operando B no ejecutado | layer_idx dependencia |
| `0x30` | `ERR_PROTO_VERSION` | HELLO mismatch | versión ARM |

---

## 10. Estado interno del ARM (`g_state`)

Libro de registros de lo que el PC ha mandado. El ARM lo consulta en cada EXEC_LAYER para validar prerrequisitos, y lo expone por `CMD_GET_STATE`.

```c
typedef struct {
    uint8_t cfg_set    : 1;   /* se recibió CMD_WRITE_CFG */
    uint8_t w_loaded   : 1;   /* se recibió CMD_WRITE_WEIGHTS */
    uint8_t b_loaded   : 1;   /* se recibió CMD_WRITE_BIAS */
    uint8_t input_ok   : 1;   /* input del layer ready (sea CMD_WRITE_INPUT o layer anterior) */
    uint8_t executed   : 1;   /* ya corrió exec, output disponible */
    uint8_t last_err   : 3;   /* último err_code del layer, 0 = OK */
} layer_state_t;  /* 1 byte */

typedef struct {
    uint32_t proto_ver;
    uint8_t  dpu_initialized;
    uint8_t  input_loaded;
    uint16_t _pad;
    uint32_t total_bytes_written;
    uint32_t total_crc_errors;
    layer_state_t layer[255];
} global_state_t;  /* ~272 bytes */

extern global_state_t g_state;
```

### Validación en `CMD_EXEC_LAYER`

```c
err_t handle_cmd_exec_layer(uint16_t idx) {
    if (!g_state.layer[idx].cfg_set) return ERR_NOT_CONFIGURED;

    layer_cfg_t *cfg = &g_cfgs[idx];   /* cargada de DDR @ 0x11000000 + idx*72 */

    switch (cfg->op_type) {
    case OP_CONV:
        uint8_t missing = 0;
        if (!g_state.layer[idx].w_loaded)  missing |= 0x01;
        if (!g_state.layer[idx].b_loaded)  missing |= 0x02;
        if (!g_state.layer[idx].input_ok)  missing |= 0x04;
        if (missing) return ERR_MISSING_DATA_aux(missing);
        break;
    case OP_ELEM_ADD:
        /* verifica que la dependencia (otra layer) ya se ejecutó */
        uint16_t dep = layer_dep_of(idx);
        if (!g_state.layer[dep].executed) return ERR_DEP_NOT_READY_aux(dep);
        break;
    /* ... */
    }

    uint32_t cycles, out_crc;
    err_t r = dispatch(cfg, &cycles, &out_crc);
    if (r == STATUS_OK) {
        g_state.layer[idx].executed = 1;
        /* La layer siguiente que use esta salida como input ya tendrá input_ok=1 */
    }
    return ack_exec(r, cycles, out_crc);
}
```

---

## 11. Diagrama de flujo — ejemplo real (layer 0: CONV 3×3 s=1, 3→32)

```
PC                                                       ARM
──                                                       ───
[conexión TCP a 192.168.1.10:7001]

CMD_HELLO{proto=1, cfg_size=72, hdr_size=16}    ────▶
                                                 ◀────   RSP_ACK{status=0, proto=1, ...}

CMD_DPU_INIT                                    ────▶    dpu_init()
                                                 ◀────   RSP_ACK{status=0}

[una vez: INPUT]
CMD_WRITE_INPUT
  header{op=0x10, len=519184}
  data_hdr_t{layer=0xFFFF, kind=3, dtype=2,
             ddr=0x10000000, len=519168, crc=0xA1B2...}
  + 519168 bytes imagen                         ────▶    valida, copia a DDR, crc OK
                                                         g_state.input_loaded=1
                                                 ◀────   RSP_ACK{status=0, bytes=519168, crc_echo=0xA1B2...}

[una vez: WEIGHTS blob completo — 61 MB en chunks de 1 MB]
CMD_WRITE_WEIGHTS
  header{op=0x11, len=16 + 864}
  data_hdr_t{layer=0, kind=1, dtype=0,
             ddr=0x12000000, len=864, crc=0x...}
  + 864 bytes pesos layer 0                     ────▶    valida kind=1, layer=0, copia, crc OK
                                                         g_state.layer[0].w_loaded=1
                                                 ◀────   RSP_ACK{status=0, ...}
... (repetir por las 110 capas CONV) ...

[una vez: BIAS blobs, análogo a WEIGHTS]

[una vez: CFG array completo — 255 × 72 B = 18 360 B]
CMD_WRITE_CFG
  header{op=0x14, len=16 + 18360}
  data_hdr_t{layer=0xFFFF, kind=5, dtype=1,
             ddr=0x11000000, len=18360, crc=0x...}
  + 18360 bytes (layer_cfg_t × 255)             ────▶    copia, marca cfg_set para todos
                                                 ◀────   RSP_ACK{status=0, ...}

[bucle por layer i = 0..254]
CMD_EXEC_LAYER{layer_idx=0}                     ────▶    lee cfg de 0x11000000
                                                         valida prereqs: w_loaded ✓ b_loaded ✓
                                                           input_ok ✓ (viene de INPUT global)
                                                         dpu_exec_conv(cfg)
                                                         calcula crc32 de out_addr..out_addr+5_537_792
                                                 ◀────   RSP_ACK{status=0, cycles=842133, out_crc=0xDEAD1234}

[PC compara]
crc_onnx = 0xDEAD1234?                                   ✅ bit-exact, siguiente layer
crc_onnx = 0xBADCODE?                                    ❌ pide la activación:
  CMD_READ_ACTIVATION{addr=out_addr, len=5_537_792} ──▶
                                                 ◀────   RSP_DATA + bytes
  diff con ONNX ref → primer índice divergente → diagnóstico
  stop
```

---

## 12. Versionado y reglas de compatibilidad

- Versión actual: **1**.
- Toda modificación de `layer_cfg_t`, `data_hdr_t`, opcode set o err_code set incrementa la versión mayor.
- Adición de opcodes nuevos sin tocar los existentes → misma versión, con `capabilities` bitmap en HELLO.
- Nunca se reusan valores numéricos retirados.
- **Contrato de tamaño**: `_Static_assert(sizeof(layer_cfg_t)==72)` en C, `assert struct.calcsize(LAYER_CFG_FMT)==72` en Python al importar el módulo.

---

## 13. Implementación — archivos afectados

### Lado ARM (C)

| Archivo | Cambio |
|---|---|
| `sw/eth_protocol.h` | añadir `data_hdr_t`, `layer_cfg_t`, `global_state_t`, err codes 0x10-0x30, opcodes 0x00/0x10-0x43 |
| `sw/eth_server.c` | `handle_cmd_hello`, `handle_cmd_write_typed` (parsea `data_hdr_t`, valida, dispatch al CRC + escritura), `handle_cmd_exec_layer` con state check real, `handle_cmd_get_state` |
| `sw/dpu_api.h` | añadir `dpu_dispatch(layer_cfg_t *cfg, uint32_t *cycles, uint32_t *out_crc)` |
| `sw/dpu_exec.c` | llamar CRC32 post-ejecución |
| `sw/main.c` | inicializar `g_state` a ceros |

### Lado PC (Python)

| Archivo | Cambio |
|---|---|
| `host/eth_protocol.py` | nuevo — espejo de `eth_protocol.h` (opcodes, kind, err codes, `LAYER_CFG_FMT`, `DATA_HDR_FMT`, `calcsize` asserts) |
| `host/yolov4_host.py` | añadir `hello()`, `write_typed(kind, layer_idx, addr, bytes)`, `exec_layer(idx)`, `read_activation(addr, len)`, `get_state()` |
| `host/orchestrator.py` | nuevo — loop bit-exact layer-by-layer |
| `host/onnx_refs.py` | nuevo — cargador de activaciones ONNX con CRC pre-computados |

---

## 14. Estrategia de validación — mock-first

Antes de tocar firmware C se valida el protocolo completo en **Python puro sobre TCP loopback**. El ciclo de debug baja de 30 s (recompilar + programar board) a milisegundos (correr pytest).

### Arquitectura

```
host/p18eth/                            ← librería Python reutilizable
    __init__.py
    proto.py          ← fuente única de verdad: opcodes, structs, CRC32
                         Contiene asserts: sizeof(layer_cfg_t)==72, etc.
    client.py         ← DpuHost: API alto nivel (hello, write_weights, exec_layer...)
    mock_server.py    ← simula al ARM, mantiene g_state en Python, loguea todo
    tests/
        test_proto.py       ← serialización/deserialización de structs
        test_mock_client.py ← client ↔ mock end-to-end por TCP loopback
        test_error_paths.py ← kind mismatch, CRC corrupto, EXEC sin cfg, etc.
        test_full_network.py← 255 layers simuladas, comprobando orden y estado
```

### MockServer: qué simula

| Operación | Comportamiento mock |
|---|---|
| `CMD_HELLO` | Responde con su versión (igual a la del cliente → OK) |
| `CMD_WRITE_*` | Escribe en un `dict[addr] = bytes` interno; verifica kind, crc, longitud |
| `CMD_WRITE_CFG` | Guarda `layer_cfg_t` parseado en `cfgs[idx]` |
| `CMD_EXEC_LAYER` | Valida prereqs (mismo código que el ARM real); "ejecuta" devolviendo: **(a)** zeros, **(b)** onnx_ref si se pasó el path del ONNX al construir el mock, o **(c)** ruido seeded para tests determinísticos |
| `CMD_READ_ACTIVATION` | Devuelve los bytes del mock |
| Cualquier error de protocolo | Mismo err_code que el ARM real |

### Flujo de trabajo

1. **Ciclo corto (minutos)**: cambio `proto.py` o `client.py` → `pytest` → verde → commit.
2. **Ciclo medio (horas)**: con todo verde contra mock, port del server a C (`eth_server.c`). El cliente NO cambia.
3. **Integration test**: mismo `DpuHost` apuntando a `192.168.1.10` en vez de `127.0.0.1:7001`. Si el mock pasaba y el board falla → el bug está en el firmware C, no en el protocolo.

### Criterios de aceptación antes de tocar firmware

- [ ] 100% cobertura de opcodes en tests mock
- [ ] Tests de error paths: kind/crc/len/dep mismatch todos detectados
- [ ] Simulación de las 255 capas completa sin desincronización
- [ ] `struct.calcsize(LAYER_CFG_FMT) == 72` en test al import
- [ ] Benchmark: ¿cuántos EXEC/s sostiene el cliente contra mock? (ayuda a dimensionar buffers reales)

### Después del firmware C

- `eth_protocol.h` se genera (o se compara) contra `proto.py` con un generator script — nunca dos fuentes de verdad a mano.
- El mismo suite de tests se puede correr contra el board (flag `--host 192.168.1.10`). Si alguno falla en board pero no en mock → bug en C aislado al instante.

## 15. Qué NO cubre V1 (futuro)

- Transferencia comprimida (zstd en pesos repetidos).
- Multi-cliente (requerirá refactor; ahora 1 conexión a la vez).
- Streaming de activaciones en tiempo real (para HDMI).
- CMD_SUBSCRIBE_EVENTS (notificar al PC fin de exec sin polling).
- Recovery sin reset: ahora, un error de protocolo cierra la conexión; el PC reconecta y reintenta.

---

## 16. Glosario

| Término | Significado |
|---|---|
| **tag** | Contador u16 del PC para correlacionar request↔response |
| **kind** | Tipo semántico del payload (weights, bias, activación, cfg…) |
| **data_hdr** | Sub-header 16 B que acompaña a cualquier bloque de datos |
| **layer_cfg** | Struct 72 B con toda la config de una capa |
| **out_crc** | CRC32 de la activación producida — atajo para verificar bit-exact |
| **g_state** | Libro de registros en el ARM con qué ha recibido/ejecutado |
| **CRC32** | Polinomio IEEE 802.3 (mismo que Ethernet), implementación table-driven |

---

**Autoridad del documento:** este markdown es el contrato. `eth_protocol.h` y `eth_protocol.py` derivan de aquí. Si hay desacuerdo entre código y doc, gana el doc — y se corrige el código.
