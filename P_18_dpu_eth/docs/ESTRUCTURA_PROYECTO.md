# P_18 DPU Ethernet — Estructura del proyecto

Proyecto de alto nivel: correr la red **YOLOv4 cuantizada (INT8)** en el DPU propio que hemos construido sobre ZedBoard (Zynq-7020), y **verificar bit-exact capa por capa contra ONNX**.

El objetivo final es: input → 255 capas ejecutadas en FPGA → heads YOLO decodificados → bboxes por HDMI.

---

## 1. Piezas del proyecto

```
P_18_dpu_eth/
├── hw/                        ← Hardware/RTL ya existente (NO se toca aquí)
├── build/                     ← Carpeta de síntesis Vivado, contiene el .bit
├── src/                       ← Fuentes VHDL del BD (wrapper, DPU, DMA, ETH)
├── sw/                        ← Firmware bare-metal (corre en el ARM)
├── host/                      ← Software del PC (cliente, tests, orquestador)
├── vitis_ws/                  ← Workspace Vitis (BSP + ELF compilado)
└── docs/                      ← Documentos y specs
```

### 1.1 Hardware (resumen, ya está hecho)

Vive en `src/` y se sintetiza con Vivado a un bitstream `build/.../dpu_eth_bd_wrapper.bit`.

| Bloque | Rol |
|---|---|
| Zynq PS (ARM Cortex-A9) | Corre el firmware bare-metal. Es el "orquestador dentro del chip". |
| GEM Ethernet (PS) | Interfaz Ethernet conectada al PHY Marvell del ZedBoard → cable → PC. |
| AXI DMA MM2S | Lee bytes de DDR y los empuja al wrapper del DPU como AXI-Stream. |
| AXI DataMover S2MM | Recoge bytes de salida del wrapper del DPU y los escribe en DDR. |
| `dpu_stream_wrapper` | Mux FSM que envía los bytes recibidos a una primitiva u otra, según el registro de config. Primitivas conectadas: conv_engine_v3, leaky_relu, maxpool_2x2, elem_add. |
| BRAM 4 KB | Buffer compartido dentro del wrapper — time-muxed entre LOAD / CONV / DRAIN. |

El firmware habla con el HW por **AXI-Lite GP0** (registros MMIO de control) + **AXI4 HP0** (DMA/DataMover para datos).

### 1.2 Firmware ARM bare-metal (`sw/`)

Corre en el procesador ARM, sin sistema operativo. Le llega el ELF por JTAG (Vitis `dow`). Implementa:

- **Stack TCP/IP con lwIP** sobre el GEM → habla por puerto 7001 con el PC.
- **Servidor de comandos** binario: WRITE_DDR, READ_DDR, EXEC_LAYER, etc.
- **Dispatch al DPU**: cuando recibe EXEC_LAYER, programa los registros MMIO del wrapper, arranca el DMA, espera done, recoge la salida.

Ficheros clave:

| Archivo | Qué hace |
|---|---|
| `main.c` | Inicializa caches, GIC, SCU timer, CRC32, lwIP, arranca el server y entra al main loop. |
| `platform_eth.c/h` | Setup de GIC + SCU timer + ISR que levanta los flags `TcpFastTmrFlag` / `TcpSlowTmrFlag`. |
| `eth_server.c` | Estado de conexión TCP, parse del protocolo binario, dispatch de cada opcode. |
| `eth_protocol.h` | Contrato del protocolo: opcodes, structs packed, `layer_cfg_t`. **Espejo de `host/p18eth/proto.py`**. |
| `crc32.c` | Tabla IEEE 802.3, inicializada eagerly en `main()`. |
| `dpu_api.h` + `dpu_exec.c` | API del runtime DPU: `dpu_exec_conv`, `dpu_exec_leaky`, `dpu_exec_pool`, `dpu_exec_add`. |
| `mem_pool.c` | Allocator por capa (por ahora el PC gestiona memoria, no el ARM). |
| `program_eth.tcl`, `hard_reset.tcl` | Scripts XSCT para programar y resetear el board por JTAG. |

### 1.3 Software del PC (`host/`)

Gobierna toda la inferencia. El ARM es solo el "ejecutor"; el PC decide qué se escribe dónde, cuándo ejecutar cada capa, y compara resultados contra ONNX.

| Archivo / módulo | Qué hace |
|---|---|
| `p18eth/` | Librería Python del protocolo. |
| `p18eth/proto.py` | Fuente única de verdad: opcodes, structs, CRC32, asserts de tamaños. |
| `p18eth/client.py` | `DpuHost` — alto nivel: `hello`, `write_*`, `exec_layer`, `read_activation`. |
| `p18eth/mock_server.py` | Simula el ARM en Python puro (para tests sin board). |
| `p18eth/tests/run_tests.py` | 31 tests unittest, client ↔ mock por TCP loopback. |
| `yolov4_host.py` | Cliente V0 legacy (PING, WRITE_DDR, READ_DDR, EXEC_LAYER). Aún usado. |
| `gen_onnx_refs.py` | Corre el ONNX con onnxruntime, dumpea las 263 activaciones intermedias + sus CRC32. Ground truth. |
| `uart_capture.py` | Captura UART USB para debug (en desarrollo). |
| `test_exec_layer_v0ext.py` | Test integración: write_ddr cfg + EXEC_LAYER real + verificar CRC. |
| `onnx_refs/` | 263 tensores int8/float32 + `manifest.json` con CRCs (132 MB total). |

### 1.4 Documentos (`docs/`)

| Archivo | Contenido |
|---|---|
| `ETH_PROTOCOL.md` | V0 (legacy): opcodes simples WRITE_DDR / READ_DDR / EXEC_LAYER sin semántica. |
| `ETH_PROTOCOL_V1.md` | V1 (spec completa, 16 secciones): header + data_hdr + layer_cfg + state machine + mock-first. Es el **contrato** del protocolo. |
| `ESTRUCTURA_PROYECTO.md` | Este documento. |

---

## 2. Mapa de memoria DDR (512 MB de la ZedBoard)

El PC es la autoridad — asigna direcciones. El ARM solo obedece. Macros espejo en `proto.py` y `eth_protocol.h`.

```
0x0010_0000 ─┐
             │ FSBL + ELF + heap/stack ARM (unos MB)
0x0FFF_FFFF ─┘

0x1000_0000 ─┐ INPUT imagen 416×416×3 (519 KB)
0x1000_FFFF ─┘

0x1010_0000 ─┐ MAILBOX / scratch (debug buffers del firmware)
0x102F_FFFF ─┘

0x1100_0000 ─┐ ARRAY de 255 × layer_cfg_t (18 KB)
0x110F_FFFF ─┘   El PC los escribe antes de EXEC_LAYER.

0x1200_0000 ─┐ WEIGHTS BLOB — 61.45 MB (todos los pesos CONV)
0x15FF_FFFF ─┘

0x1600_0000 ─┐ ACTIVATIONS — pool de ~96 MB
             │ Gestión por el PC con bump+release (libera cuando una
0x1BFF_FFFF ─┘ activación ya no tiene consumidores pendientes).

0x1C00_0000 ─┐ Reservado (framebuffer HDMI futuro)
0x1FFF_FFFF ─┘
```

---

## 3. Protocolo Ethernet (resumen)

Todo mensaje PC↔ARM empieza con un header de 8 bytes:

```
offset  size  campo
  0      1    opcode
  1      1    flags
  2      2    tag          ← identificador único del request (eco en la respuesta)
  4      4    payload_len
```

Opcodes principales:

| Opcode | Nombre | Payload | Respuesta |
|:---:|---|---|---|
| 0x01 | PING | — | RSP_PONG "P_18 OK" |
| 0x02 | WRITE_DDR | `u32 addr` + N bytes | ACK |
| 0x03 | READ_DDR | `u32 addr, u32 len` | N bytes |
| 0x04 | EXEC_LAYER | `u16 layer_idx, u16 flags` | ACK{cycles, out_crc, out_bytes} |
| 0x06 | DPU_INIT | — | ACK |
| 0x07 | DPU_RESET | — | ACK |
| 0xFF | CLOSE | — | (cierra conexión) |

---

## 4. Flujo de una inferencia (concepto)

```
PC (Python)                                     ARM (bare-metal)

[preparación — una vez por sesión]
write_ddr(0x12000000, weights_blob 61MB) ───▶   DMA → DDR
write_ddr(0x10000000, input_imagen)       ───▶   DMA → DDR
write_ddr(0x11000000, cfgs[255]×72B)      ───▶   DMA → DDR

[loop por capa i = 0..254]
exec_layer(i)                             ───▶   lee cfg[i] de DDR
                                                  dispatch → dpu_exec_*
                                                  calcula CRC32 del output
                                          ◀───   ACK{cycles, out_crc, out_bytes}

  if out_crc == onnx_ref[i].crc32:              ✅ layer bit-exact
  else:
      read_ddr(out_addr, out_bytes)     ───▶    bytes de la activación
                                          ◀───  
      diff vs onnx_ref → primer índice
      divergente → diagnóstico detallado

[final — 3 heads]
read_ddr(head_addr, head_bytes) × 3       ───▶  → decode NMS en PC → bboxes
```

---

## 5. Estado actual (bitácora de sesión)

| Pieza | Estado |
|---|:---:|
| Ethernet básico (PING + WRITE/READ DDR, 28-51 MB/s, bit-exact) | ✅ Estable |
| Librería Python `p18eth/` + 31 tests unittest | ✅ Verde |
| Documento protocolo V1 | ✅ Escrito |
| ONNX refs (263 tensores, 132 MB) + manifest | ✅ Generado |
| EXEC_LAYER nuevo (V0-extendido, lee cfg de DDR) | 🔨 En test ahora |
| Dispatch real a `dpu_exec_conv/leaky/pool/add` | ⏳ Siguiente paso (stub devuelve zeros por ahora) |
| Firmware V1 completo (con data_hdr + CRC en streaming) | ❌ Inestable — bug identificado (CRC en on_recv causa CPU starvation) |

---

## 6. Lecciones aprendidas

1. **Nunca hacer trabajo pesado en `on_recv`**. El callback de lwIP lo invoca `xemacif_input` sincrónicamente. Si el callback tarda mucho, los pbufs RX se llenan y el GEM descarta paquetes (ICMP + TCP ACKs). V1 caía por esto; V0 no hace CRC en el callback y vuela.

2. **El board acumula estado raro** tras múltiples re-programaciones por JTAG sin power cycle. `rst -srst` (system reset vía JTAG) resuelve, a veces hay que aplicarlo dos veces seguidas.

3. **`init_platform()` antes de `lwip_init`**. Sin eso, el SCU timer no dispara y `TcpFastTmrFlag` nunca se levanta → lwIP no procesa ARP ni TCP.

4. **Contract-test con mock > contract-test con board**. 31 tests Python corren en 0.23 s contra un MockServer, y son los mismos asserts que ejercerán luego el firmware C. Bisect del bug V1 se habría hecho en minutos si hubiera empezado por ahí.

5. **JTAG es lento para datos** (142 s para 61 MB). Ethernet en 1.2 s. **SD también serviría** (~2-4 s, one-shot) pero Ethernet gana para debug interactivo porque permite leer/escribir DDR mientras el firmware corre.

---

## 7. Siguientes pasos inmediatos

1. Validar el EXEC_LAYER V0-extendido en board real (test running).
2. Bridge `layer_cfg_t` → `layer_config_t` del runtime antiguo para llamar `dpu_exec_conv/leaky/pool/add` reales.
3. Orquestador Python que itera 255 capas y compara CRC con ONNX refs.
4. Primer barrido: identificar en qué capa se rompe el bit-exact (y por qué).

---

## 8. Referencias cruzadas

- **ONNX original**: `C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx`
- **Protocolo V1**: `docs/ETH_PROTOCOL_V1.md`
- **Mapa de memoria autoridad**: `host/p18eth/proto.py` (macros `ADDR_*`)
- **BD ZedBoard actual**: `build/dpu_eth.runs/impl_1/dpu_eth_bd_wrapper.bit`
- **Firmware ELF actual**: `vitis_ws/dpu_eth_app/Debug/dpu_eth_app.elf`
