# P_18 — Protocolo TCP PC ↔ ZedBoard DPU

## Red

| Parámetro | Valor |
|---|---|
| Board IP | **192.168.1.10** (estática, heredado de P_400) |
| PC IP | configurar adaptador a **192.168.1.100** |
| Puerto TCP control | **7001** (nuevo, bulk binary) |
| Puerto TCP echo | 7 (legacy P_400, para sanity) |
| Puerto UDP debug | 7777 (legacy P_400, single-word read/write) |

## Protocolo TCP bulk (puerto 7001)

Diseñado para cargar hasta 60 MB de pesos YOLOv4 + imagen + leer heads en segundos.

### Encoding

- **Todos los enteros little-endian** (PC x86 y ARM Cortex-A9 little-endian: sin conversión).
- Binario puro, no JSON ni text.
- Cada mensaje tiene un header común + payload.

### Header (8 bytes, común)

```
offset  size  campo         descripción
  0      1    opcode        ver tabla de comandos
  1      1    flags         reservado (0)
  2      2    tag           echo del tag en response (opcional)
  4      4    payload_len   bytes del payload que siguen
```

### Comandos (PC → board)

| opcode | nombre | payload | respuesta |
|:------:|---|---|---|
| 0x01 | `PING` | (none) | `PONG` con 8 bytes "P_18 OK\0" |
| 0x02 | `WRITE_DDR` | `u32 addr` + N bytes | `ACK` con status |
| 0x03 | `READ_DDR` | `u32 addr` + `u32 length` | N bytes de DDR |
| 0x04 | `EXEC_LAYER` | `u32 layer_idx` + `u32 in_addr` + `u32 out_addr` (+ para conv: `u32 w_addr`, `u32 b_addr`; para add: `u32 in_b_addr`) | `ACK` con status + cycles |
| 0x05 | `RUN_NETWORK` | `u32 input_addr` + `u32 head0_addr` + `u32 head1_addr` + `u32 head2_addr` | `ACK` con status + total_cycles |
| 0x06 | `DPU_INIT` | (none) | `ACK` |
| 0x07 | `DPU_RESET` | (none) | `ACK` |
| 0xFF | `CLOSE` | (none) | (cierra conexión) |

### Respuestas (board → PC)

| opcode | nombre | payload |
|:------:|---|---|
| 0x81 | `PONG` | 8 bytes "P_18 OK\0" |
| 0x82 | `ACK` | `u32 status_code` + (opcional) datos extra |
| 0x83 | `DATA` | N bytes (respuesta de READ_DDR) |
| 0x8E | `ERROR` | `u32 error_code` + `u32 aux` |

### Status codes

```
0x00000000  OK
0x00000001  ERR_INVALID_CMD
0x00000002  ERR_INVALID_ADDR
0x00000003  ERR_DPU_TIMEOUT
0x00000004  ERR_DPU_FAULT
0x00000005  ERR_BUFFER_OVERRUN
```

## Flujo típico end-to-end (YOLOv4 completo)

```
1. PC  → WRITE_DDR(addr=0x12000000, weights_blob)   # ~60 MB pesos
2. PC  → WRITE_DDR(addr=0x10000000, input_image)    # 519 KB
3. PC  → RUN_NETWORK(input=0x10000000,
                      head0=0x18000000,
                      head1=0x18100000,
                      head2=0x18200000)
4. BRD → [varios minutos de cómputo]
5. BRD → ACK (status=OK, cycles=N)
6. PC  → READ_DDR(addr=0x18000000, len=3 MB) × 3 heads
7. PC  → draw_bboxes.py on received heads
```

## Mapa DDR reservado (ZedBoard 512 MB total)

```
0x00000000 - 0x0FFFFFFF   (256 MB)  FSBL, vectors, MMU, ELF, heap, stack
0x10000000 - 0x10100000   (1 MB)    DPU_SRC scratch (DMA source)
0x10100000 - 0x10200000   (1 MB)    DPU_DST scratch (DataMover dest)
0x10200000 - 0x10210000   (64 KB)   RESULT mailbox (XSCT legacy)
0x11000000 - 0x11FFFFFF   (16 MB)   Activations pool (intermediate layers)
0x12000000 - 0x15FFFFFF   (64 MB)   Weights blob (YOLOv4 todos los pesos)
0x16000000 - 0x17FFFFFF   (32 MB)   Bias blob + layer_configs en DDR
0x18000000 - 0x183FFFFF   (4 MB)    Head outputs (3 heads, ~3 MB total)
```

## Tamaño esperado de pesos YOLOv4

Suma sobre las 110 QLinearConv layers del modelo. Cada capa:
- weights = c_out × c_in × kh × kw bytes (int8)
- bias = c_out × 4 bytes (int32)

Aproximado:
- Primera capa: 864 B pesos + 128 B bias
- Layer 148: 4.7 MB pesos (capa más grande)
- **Total ~60 MB** entre todas las capas.

A 10 MB/s Ethernet útil, carga completa ~6 s.

## Fases de implementación

| Fase | Cliente | ARM | HW needed |
|---|---|---|---|
| 1 | `yolov4_host.py` + mock | — | ninguno |
| 2 | test cliente vs mock server | — | ninguno |
| 3 | — | ARM eth_server.c extiende P_400 main | ninguno (compila) |
| 4 | — | Block Design fusiona P_400 MAC + P_17 DPU | **sí** (mañana) |
| 5 | smoke test PC → board | lwIP + protocolo | sí |
| 6 | weights load + run + heads | full | sí |
