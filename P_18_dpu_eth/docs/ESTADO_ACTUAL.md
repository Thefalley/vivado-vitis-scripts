# P_18 — Estado actual de la sesión

Fecha: 2026-04-16
Objetivo: correr YOLOv4 INT8 bit-exact layer-by-layer en ZedBoard DPU, control por Ethernet.

---

## 1. TL;DR — qué funciona HOY

- Ethernet PC↔ZedBoard estable (20/20 ping, 28-51 MB/s TCP, bit-exact roundtrip 8 MB).
- Protocolo V0 extendido con `EXEC_LAYER` real:
  - PC escribe `layer_cfg_t` (72 B) en DDR.
  - ARM lee el cfg, despacha según `op_type`, calcula CRC32 del output, responde `{cycles, out_crc, out_bytes}`.
- Dispatch parcial: RESIZE + CONCAT en ARM (bit-exact verificado); CONV/LEAKY/POOL/ADD en **stub** (zeros) hasta que se conecte al runtime DPU real.
- Librería Python `p18eth/` con MockServer, 31 tests verdes.
- 263 tensores ONNX de referencia dumpeados (132 MB) con CRC32 — ground truth listo.
- Documento protocolo V1 completo en `docs/ETH_PROTOCOL_V1.md`.
- Documento estructura general en `docs/ESTRUCTURA_PROYECTO.md`.

---

## 2. Validaciones end-to-end realizadas

### 2.1 Infraestructura Ethernet

```
PING        → 20/20 (0% loss)
WRITE 8 MB  → 0.16 s    = 51.7 MB/s   ~120× más rápido que JTAG
READ  8 MB  → 0.25 s    = 33.6 MB/s
cmp         → bit-exact
```

### 2.2 EXEC_LAYER real

**Test 1 — CONV stub (zeros 5.5 MB):**
```
out_crc  = 0x19FC2063
expected = 0x19FC2063   ✅ MATCH
tiempo   = 168.9 ms
```

**Test 2 — RESIZE 2× (ejecución ARM real, 13×13×4 → 26×26×4):**
```
out_crc                    = 0x5FAED37A
expected (np.repeat×2)     = 0x5FAED37A   ✅ MATCH
read_ddr vs expected bytes  bit-exact       ✅ MATCH
```

### 2.3 Tests Python (contra MockServer por TCP loopback)

```
31/31 OK en 0.23 s
```

Cubren: HELLO, PING, WRITE_RAW/READ_RAW 1 MB, WRITE_INPUT/WEIGHTS/BIAS, CRC
corruption, KIND mismatch, EXEC sin cfg, CONV happy path, 255 layers simuladas,
exec_hook custom, reset_state.

---

## 3. Arquitectura del protocolo (V0 extendido, estable)

### Header común (8 B)

```
offset size  campo
  0     1    opcode
  1     1    flags
  2     2    tag
  4     4    payload_len
```

### Opcodes implementados en firmware

| Opcode | Nombre | Payload | Respuesta |
|:---:|---|---|---|
| `0x01` | PING | — | `RSP_PONG` "P_18 OK\0" |
| `0x02` | WRITE_DDR | `u32 addr` + N bytes | `RSP_ACK{status}` |
| `0x03` | READ_DDR | `u32 addr, u32 len` | `RSP_DATA` + N bytes |
| `0x04` | EXEC_LAYER | `u16 layer_idx, u16 flags` | `RSP_ACK{status, cycles, out_crc, out_bytes}` |
| `0x06` | DPU_INIT | — | `RSP_ACK` |
| `0x07` | DPU_RESET | — | `RSP_ACK` |
| `0xFF` | CLOSE | — | cierra conexión |

### layer_cfg_t (72 B) — spec actual

```c
typedef struct __attribute__((packed)) {
    uint8_t  op_type;          /* 0=CONV 1=LEAKY 2=POOL 3=ADD 4=CONCAT 5=RESIZE */
    uint8_t  act_type;
    uint16_t layer_idx;
    uint32_t in_addr, in_b_addr, out_addr, w_addr, b_addr;
    uint16_t c_in, c_out, h_in, w_in, h_out, w_out;
    uint8_t  kh, kw, stride_h, stride_w;
    uint8_t  pad_top, pad_bottom, pad_left, pad_right;
    uint8_t  ic_tile_size, post_shift;
    int16_t  leaky_alpha_q;
    int32_t  a_scale_m, b_scale_m;
    int8_t   a_scale_s, b_scale_s, out_zp, out_scale_s;
    uint32_t reserved[3];
} layer_cfg_t;  /* 72 bytes */
```

`_Static_assert(sizeof(layer_cfg_t) == 72)` en C y `struct.calcsize(LAYER_CFG_FMT) == 72` en Python garantizan que nunca divergen por accidente.

---

## 4. Mapa de memoria DDR

Autoridad: el PC (Python), reflejado en `p18eth/proto.py` y `eth_protocol.h`.

```
0x0010_0000 ─┐ FSBL + ELF + heap/stack ARM
0x0FFF_FFFF ─┘

0x1000_0000 ─┐ INPUT imagen 416×416×3
0x1000_FFFF ─┘

0x1010_0000 ─┐ MAILBOX / scratch
0x102F_FFFF ─┘

0x1100_0000 ─┐ ARRAY 255 × layer_cfg_t (18 KB)
0x110F_FFFF ─┘

0x1200_0000 ─┐ WEIGHTS BLOB 61.45 MB
0x15FF_FFFF ─┘

0x1600_0000 ─┐ ACTIVATIONS pool ~96 MB
0x1BFF_FFFF ─┘

0x1C00_0000 ─┐ Reservado (HDMI futuro)
0x1FFF_FFFF ─┘
```

---

## 5. Diagnóstico del firmware V1 (inestable)

### Síntomas

- V0 estable: 20/20 ping + TCP OK.
- V1 (con data_hdr + CRC en streaming): ~50 % packet loss ICMP, TCP timeouts.
- Mismo HW, mismo FSBL, mismo bitstream, mismo BSP. Solo cambia `eth_server.c`.

### Investigación — 3 agentes en paralelo

**Agent 1 — state machine:** ranked hipótesis H1 (BSS overflow) y H2 (CRC32 en callback).

**Agent 2 — memory/linker (descarta H1):**
- `.bss` real = 3.03 MB (dominado por `emac_bd_space` 1 MB + PBUF pool 230 KB).
- Los 19 KB nuevos (`g_cfgs[255]` + `g_state`) son ruido frente a 506 MB libres de DDR.
- Heap lwIP (`MEM_SIZE=131072`) es estático en `.bss`, no compite con `g_cfgs`.
- **Veredicto: NO es memoria.**

**Agent 3 — main loop + checksum offload:**
- Main loop idéntico V0↔V1 (solo `xemacif_input` + flags de timer).
- `lwipopts.h` idéntico; si el offload fuese el problema, V0 también fallaría.
- **Veredicto: es CPU starvation en `on_recv`, no offload.**

### Causa raíz confirmada

```
V1.on_recv (callback lwIP) ejecuta p18_crc32_update(payload) síncrono
      │
      └─> bloquea el callback ~decenas de ms por MB
              │
              └─> xemacif_input no drena cola RX del GEM
                      │
                      └─> cola RX se llena, GEM descarta frames (rx_overrun)
                              │
                              └─> ICMP echo perdido + TCP ACKs perdidos
                                    │
                                    └─> 50 % packet loss observado
```

### Fix para mañana

Tres opciones, de menos a más invasiva:

1. **No calcular CRC en el callback**. Devolver CRC=0 en WRITE_* tipados, confiar en TCP checksum del GEM.
2. **CRC diferido**: almacenar `{addr, len}` tras WRITE, el main loop calcula CRC entre ticks de `xemacif_input`, y el PC hace un `CMD_GET_LAST_CRC` después.
3. **CRC incremental real**: dividir el loop de CRC en chunks pequeños (~4 KB) e intercalar `xemacif_input()` entre cada chunk. Complejo pero preserva la semántica V1.

Recomendación: **opción 1**, suficiente en una red local fiable. Si hace falta integridad, se añade CRC solo a los EXEC_LAYER outputs (que van en el ACK, fuera de streaming).

---

## 6. Lecciones aprendidas

1. **No hacer trabajo pesado en `on_recv`**. Es un callback síncrono del driver Ethernet. Cada ms que tarda es un ms en que la cola RX del GEM no se drena. Regla: memcpy+flags sí, CRC/compresión/validación pesada no.

2. **`init_platform()` (SCU timer + GIC) ANTES de `lwip_init`**. Sin SCU timer, `TcpFastTmrFlag` no se levanta y lwIP no procesa ARP/TCP. Fallo silencioso.

3. **El board acumula estado raro tras múltiples re-programaciones**. Si la red empieza a ir intermitente, `rst -srst` (system reset via JTAG) limpia. A veces hace falta dos veces.

4. **Contract-test mock-first > bring-up directo**. 31 tests contra `MockServer` en 0.23 s me dieron confianza total en el protocolo antes de tocar C. Si el firmware hubiera sido mock-first desde el principio, el bug V1 se hubiera visto en los tests (con `MEASURE_CALLBACK_TIME` o similar).

5. **Ethernet es el camino correcto para debug interactivo**. SD sirve para carga masiva de pesos pero no para leer DDR en vivo durante la ejecución.

6. **Buffer de envío de lwIP es pequeño (~2-4 KB)**. Para respuestas grandes (READ_DDR de MB) hay que implementar `tcp_sent` callback con `pending_ptr/pending_len` que continúa enviando cuando el stack libera espacio. Sin eso, `eth_send_raw` abandona a mitad.

---

## 7. Estructura de archivos del proyecto (referencia rápida)

```
P_18_dpu_eth/
├── build/                                       ← Vivado synth+impl
│   └── dpu_eth.runs/impl_1/
│       └── dpu_eth_bd_wrapper.bit               ← bitstream actual
│
├── sw/                                          ← Firmware bare-metal ARM
│   ├── eth_protocol.h                           ← protocolo (espejo de proto.py)
│   ├── eth_server.c                             ← server TCP, V0-extendido estable
│   ├── crc32.c                                  ← tabla IEEE 802.3 eager-init
│   ├── main.c                                   ← init_platform + crc32_init + lwip + mainloop
│   ├── platform_eth.c/h                         ← GIC + SCU timer
│   ├── dpu_api.h + dpu_exec.c                   ← runtime DPU (conv/leaky/pool/add)
│   ├── mem_pool.c                               ← allocator (no usado aún)
│   ├── program_eth.tcl, hard_reset.tcl          ← scripts XSCT
│   ├── diag_pc.tcl, diag_eth.tcl                ← debug JTAG
│   ├── eth_server_v1.c.bak                      ← V1 firmware (inestable) para referencia
│   └── eth_protocol_v1.h.bak                    ← V1 header para referencia
│
├── host/                                        ← Software PC
│   ├── p18eth/                                  ← librería canónica V1
│   │   ├── proto.py                             ← fuente única de verdad
│   │   ├── client.py                            ← DpuHost (V1)
│   │   ├── mock_server.py                       ← simulador ARM en Python
│   │   └── tests/run_tests.py                   ← 31 tests unittest
│   ├── yolov4_host.py                           ← cliente V0 legacy (aún en uso)
│   ├── gen_onnx_refs.py                         ← dumpea las 263 activaciones ONNX
│   ├── test_exec_layer_v0ext.py                 ← test integración V0-ext + board real
│   ├── uart_capture.py                          ← UART debug (no usable aún)
│   └── onnx_refs/                               ← 263 tensores + manifest.json (132 MB)
│
├── vitis_ws/                                    ← workspace Vitis
│   ├── dpu_eth_platform/                        ← BSP con lwip220
│   └── dpu_eth_app/Debug/
│       └── dpu_eth_app.elf                      ← ELF actual (V0-extendido)
│
└── docs/
    ├── ETH_PROTOCOL.md                          ← spec V0 (legacy)
    ├── ETH_PROTOCOL_V1.md                       ← spec V1 (contrato completo, 16 secciones)
    ├── ESTRUCTURA_PROYECTO.md                   ← overview del proyecto
    └── ESTADO_ACTUAL.md                         ← este archivo
```

---

## 8. Siguientes pasos

### Inmediato (~1 h)

1. **Bridge `layer_cfg_t → layer_config_t`** del runtime antiguo. Una función `cfg_to_runtime(layer_cfg_t *src, layer_config_t *dst)` que copia los campos equivalentes.
2. **Reemplazar los stubs** `memset(zeros)` en `handle_cmd_exec_layer` por:
   - `dpu_exec_conv(runtime_cfg, in_ddr, w_ddr, b_ddr, out_ddr, prof)` para CONV
   - `dpu_exec_leaky(...)` para LEAKY
   - `dpu_exec_pool(...)` para POOL
   - `dpu_exec_add(...)` para ADD
3. **Test bit-exact con una capa CONV** contra ONNX ref (layer 2: primera CONV 3→32).

### Corto (~1 día)

4. **Orquestador Python** `run_network.py` que itera 255 capas:
   - Carga pesos blob (WRITE_DDR 61 MB)
   - Carga input imagen
   - Escribe los 255 layer_cfg_t en DDR
   - Loop: `exec_layer(i)` → compara `out_crc` con `onnx_refs/layer_i.json.crc32`
   - Si discrepa: `read_ddr` del output → diff bytewise con tensor ONNX → log del primer índice divergente
5. **Fix V1 proper** siguiendo opción 1 del fix: mover CRC fuera del `on_recv`.

### Medio (~1 semana)

6. Decodificador YOLOv4 + NMS en el PC (o ARM) → bboxes.
7. HDMI output de las bboxes (proyecto P_19 existente).
8. Persistir pesos en SD card para acelerar arranque (ahorra 1.2 s por boot).

---

## 9. Comandos de arranque rápido

### Programar el board
```bash
cd C:/project/vivado/P_18_dpu_eth/sw
"C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat" hard_reset.tcl \
  ../build/dpu_eth.runs/impl_1/dpu_eth_bd_wrapper.bit \
  ../vitis_ws/dpu_eth_platform/zynq_fsbl/fsbl.elf \
  ../vitis_ws/dpu_eth_app/Debug/dpu_eth_app.elf
```

### Compilar el firmware
```bash
export PATH="/c/AMDDesignTools/2025.2/gnu/aarch32/nt/gcc-arm-none-eabi/bin:$PATH"
cd C:/project/vivado/P_18_dpu_eth/vitis_ws/dpu_eth_app/Debug
make dpu_eth_app.elf
```

### Correr los tests Python
```bash
cd C:/project/vivado/P_18_dpu_eth/host
python -m p18eth.tests.run_tests    # 31 tests contra MockServer
python test_exec_layer_v0ext.py     # integración contra board real
```

### Generar refs ONNX (una vez)
```bash
python host/gen_onnx_refs.py --out host/onnx_refs
```

---

## 10. Qué buscar mañana si algo se rompe

- **Red intermitente**: primero `hard_reset.tcl` dos veces, luego esperar ~3 s por ARP.
- **TCP timeouts en READ grande**: verifica que `eth_server.c` tiene `tcp_sent(pcb, on_sent)` y el `eth_send_raw_async` con pending buffer.
- **Bit-exact mismatch CONV**: comparar el primer 8-byte pattern del output con el tensor ONNX en numpy — suele delatar orden NHWC vs OIHW, endianness, o offset.
- **31 tests Python en rojo**: el protocolo se desincronizó; revisa `_Static_assert` en C (no debe compilar si `sizeof(layer_cfg_t) != 72`).
