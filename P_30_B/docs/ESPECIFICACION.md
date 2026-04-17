# P_30_A — Especificación técnica

---

## 1. Requisito absoluto (no negociable)

**La salida de cada capa del DPU tiene que ser idéntica byte a byte a la salida de ONNX Runtime ejecutando `yolov4_int8_qop.onnx`.**

- Modelo ONNX: `C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx`
- Activaciones de referencia: `C:/project/vivado/P_18_dpu_eth/host/onnx_refs/` (263 tensores con CRC32)
- Mapping: `FPGA[i] output = manifest.tensors[LAYERS[i].layer_id - 3]`
- Verificación: CRC32 IEEE 802.3 (`zlib.crc32` en Python, `p18_crc32` en C)

**No se acepta:**
- Diferencias de 1 bit ("casi bit-exact")
- Match solo para algunas capas
- Match con input sintético pero no con input real del ONNX
- Match en simulación pero no en hardware

**Sí se acepta:**
- Bit-exact verificado en XSIM Y en ZedBoard real
- CRC del DPU == CRC del tensor ONNX para las 255 capas

---

## 2. Qué ya está verificado (punto de partida)

| Verificación | Archivo de prueba | Resultado |
|---|---|---|
| Python reproduce ONNX bit-exact | `host/verify_onnx_graph.py` | `match: True` |
| XSIM conv_engine_v3 bit-exact | `sim/conv_engine_v3_layer0_tb.vhd` | 512/512 bytes OK |
| Board layer 0 CONV (416×416) | `host/test_layer0_bitexact.py` | CRC 0x8FACA837 == ONNX |
| Board layer 1 LEAKY (416×416) | `host/test_layer01_chain.py` | CRC 0xF51B4D0C == ONNX |
| Ethernet PC↔Board bit-exact | `host/test_exec_layer_v0ext.py` | 8 MB roundtrip idéntico |

Estos resultados están en el commit `d38284b` del repo `Thefalley/vivado-vitis-scripts`.

**Estos tests DEBEN seguir pasando** después de P_30_A. Si alguno se rompe, la implementación es incorrecta.

---

## 3. Qué NO funciona hoy (lo que P_30_A resuelve)

Las capas 2-254 fallan con `DPU_ERR_TILING` porque los pesos no caben en el BRAM de 4 KB.

```
Capas probadas:
  Layer 0 (CONV 3→32):     OK bit-exact (pesos 864 B < 4 KB)
  Layer 1 (LEAKY 32→32):   OK bit-exact
  Layer 2 (CONV 32→64):    FAIL DPU_ERR_TILING (pesos 18432 B > 4 KB)
  Layer 3+ :               FAIL (cascada del error anterior)

Resumen: 2/255 OK, 253 FAIL
Objetivo P_30_A: 255/255 OK
```

---

## 4. Formato de datos (verificado, NO cambiar)

### 4.1 Activaciones (input/output)

- **Layout**: NCHW (channels-first)
- **Verificado en RTL**: `conv_engine_v3.vhd` línea 829: `act_ic_offset += hw_reg` (salta H×W por canal)
- **Verificado en RTL**: salida escrita como `addr = addr_output + oc*h_out*w_out + oh*w_out + ow`
- **Tipo**: int8 (signed, rango -128 a 127)

### 4.2 Pesos

- **Layout**: OHWI (output-channel, height, width, input-channel)
- **Verificado**: `extract_weights_blob.py` transpone OIHW→OHWI
- **Verificado**: XSIM bit-exact usa `weights_ohwi.hex` generado con este layout
- **Tipo**: int8
- **Blob completo**: `C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin` (64 MB)
- **Offsets por capa**: `host/weights_manifest.json`

**CUIDADO**: `dpu_exec.c` línea 218 tenía un doble transpose que corrompía los pesos. Ya arreglado (memcpy directo). No reintroducir.

### 4.3 Bias

- **Tipo**: int32 little-endian
- **Layout**: array de c_out valores, 4 bytes cada uno
- **Offset en blob**: ver `weights_manifest.json` campo `b_off`

### 4.4 Parámetros de cuantización

Vienen del firmware (`LAYERS[]` en `layer_configs.h`), NO del PC:
- `x_zp`: zero-point del input (int8, típicamente -128)
- `w_zp`: zero-point de pesos (siempre 0 en este modelo)
- `y_zp`: zero-point del output (int8)
- `M0`: multiplicador de requantize (uint32, max ~2^30)
- `n_shift`: shift del requantize (uint6)
- Para LEAKY: `M0_neg`, `n_neg` (rama negativa)
- Para ADD: `b_zp`, `M0_b` (segundo operando)

---

## 5. Cosas que NO se pueden hacer

### 5.1 NO cambiar el cálculo del conv_engine

La fórmula que el RTL implementa es:

```
y[oc, oh, ow] = clamp(
    round( (Σ_{ic,kh,kw} (x[ic,ih+kh,iw+kw] - x_zp) × w[oc,kh,kw,ic] + bias[oc]) × M0 >> n_shift )
    + y_zp,
    -128, 127
)
```

Verificada bit-exact contra ONNX. NO tocar el mac_unit, mac_array, requantize ni el loop MAC/requantize del conv_engine.

### 5.2 NO usar shared variables en RTL sintetizable

Solo en testbenches de simulación. El RTL usa solo signals y variables locales de process.

### 5.3 NO asumir NHWC

El RTL trabaja en NCHW. Todos los buffers de activaciones deben estar en NCHW. Error histórico corregido en P_18 (bugs 4 y 5).

### 5.4 NO olvidar cache coherence

Cualquier dato que el ARM lea de DDR después de que otro master lo haya escrito (DMA, Ethernet, DPU) necesita `Xil_DCacheInvalidateRange` ANTES del read. Error histórico corregido en P_18 (bug 2).

### 5.5 NO hacer tests solo con datos sintéticos

Los tests DEBEN usar tensores reales del ONNX (`onnx_refs/layer_NNN.bin`). Los tests de P_13/P_16 con datos sintéticos dieron 120/120 PASS pero no detectaban errores reales contra ONNX.

### 5.6 NO confiar en simulación sin hardware

XSIM bit-exact + Board bit-exact. Los dos. Si uno pasa y el otro no, hay bug (típicamente cache stale o formato de datos).

---

## 6. Cosas que SÍ se pueden hacer

### 6.1 Modificar el conv_engine para añadir puertos

Se pueden añadir puertos nuevos (ext_wb_*, cfg_no_clear, cfg_no_requantize) siempre que:
- No cambien el comportamiento cuando los flags están en 0 (backward compatible)
- Se verifique bit-exact en XSIM con los mismos vectores de P_18

### 6.2 Modificar el wrapper

Se puede cambiar la FSM del wrapper (añadir estados, registros, mux) porque:
- Es glue logic, no cálculo aritmético
- Se verifica en XSIM end-to-end

### 6.3 Cambiar el tamaño del BRAM

De 4 KB a 8 KB (o más). Solo cambia el tamaño del array. El conv_engine usa offsets relativos, no absolutos.

### 6.4 Añadir DMAs al block design

Zynq-7020 tiene 4 HP ports. Usamos 1 ahora. Podemos añadir hasta 3 DMAs más.

### 6.5 Reusar módulos de P_102

El patrón de FIFO con handshake (valid/ready, AND gate para control de flujo) de `P_102_bram_ctrl_v2` es reutilizable.

---

## 7. Criterios de aceptación de P_30_A

### Test 1: XSIM bit-exact layer 2

```bash
cd P_30_A/sim
bash run_sim_layer2.sh
# Esperado: "RESULT: XXX/XXX bytes OK, 0 mismatches"
```

Usa vectores de `onnx_refs/layer_003.bin` (input) y `onnx_refs/layer_004.bin` (expected output). Layer 2 es la primera CONV que falla hoy (c_in=32, c_out=64, k=3, stride=2).

### Test 2: Board bit-exact layers 0-10

```bash
cd P_18_dpu_eth/host
python run_all_layers.py 10
# Esperado: "RESULT: 10/10 OK, 0 FAIL"
```

Incluye: 5 CONVs, 4 LEAKYs, 1 ADD. Con pesos que van de 864 B a 18 KB.

### Test 3: Board bit-exact 255 capas completas

```bash
python run_all_layers.py 255
# Esperado: "RESULT: 255/255 OK, 0 FAIL"
```

### Test 4: Regresión layers 0 y 1

Los tests existentes de P_18 siguen pasando:
```bash
python test_layer0_bitexact.py     # CRC 0x8FACA837
python test_layer01_chain.py       # Layer 0 + Layer 1 bit-exact
```

---

## 8. Archivos de referencia (rutas absolutas)

| Archivo | Qué es |
|---|---|
| `C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx` | Modelo ONNX fuente de verdad |
| `C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin` | Blob de pesos extraídos (OHWI, 64 MB) |
| `C:/project/vivado/P_18_dpu_eth/host/onnx_refs/manifest.json` | 263 tensores con CRC32 |
| `C:/project/vivado/P_18_dpu_eth/host/onnx_refs/layer_NNN.bin` | Activaciones individuales |
| `C:/project/vivado/P_18_dpu_eth/sw/layer_configs.h` | LAYERS[255] del firmware |
| `C:/project/vivado/P_18_dpu_eth/host/weights_manifest.json` | Offsets de pesos por capa |
| `C:/project/vivado/P_18_dpu_eth/host/layer_configs.json` | LAYERS parseado a JSON |
| `C:/project/vivado/P_18_dpu_eth/src/conv_engine_v3.vhd` | RTL verificado bit-exact |
| `C:/project/vivado/P_18_dpu_eth/sim/conv_engine_v3_layer0_tb.vhd` | TB XSIM que da 512/512 OK |
| `C:/project/vivado/P_102_bram_ctrl_v2/src/` | Patrón FIFO con handshake |

---

## 9. Errores históricos (lecciones aprendidas, NO repetir)

| # | Error | Dónde | Cómo evitarlo |
|---|---|---|---|
| 1 | Doble transpose de pesos | `dpu_exec.c` L218 | Pesos en blob ya son OHWI. Copiar directo, NUNCA transponer |
| 2 | Cache stale al leer DDR | `dpu_exec.c`, `dpu_exec_tiled.c` | `Xil_DCacheInvalidateRange` ANTES de cada memcpy de DDR |
| 3 | Tiling asume NHWC | `dpu_exec_tiled.c` L282, L313 | RTL es NCHW. Extraer/componer canal por canal |
| 4 | reg_n_words overflow 10 bits | `dpu_exec.c` chunking | Max 1023 words = 4092 bytes por chunk stream |
| 5 | Board degrada tras re-programaciones | JTAG | Usar `hard_reset.tcl` con `rst -srst` |
| 6 | CRC en callback lwIP | `eth_server.c` V1 | NUNCA hacer trabajo pesado en on_recv. CRC fuera del callback |
| 7 | Tests con datos sintéticos | P_13/P_16 | Verificar SIEMPRE contra tensores reales del ONNX |

---

## 10. Reglas del proyecto

### 10.1 Código autocontenido

Cada proyecto (P_30_A, P_30_B) tiene que tener **todo lo necesario para buildear** dentro de su propia carpeta. No puede depender de archivos en P_13, P_9, P_11, P_12 ni P_18. Si necesita un .vhd de otro proyecto, se copia a `src/`.

```
P_30_A/
├── src/               ← TODO el RTL aquí (copiar de P_18/src/ como base)
│   ├── conv_engine_v4.vhd
│   ├── mac_unit.vhd
│   ├── mac_array.vhd
│   ├── mul_s32x32_pipe.vhd
│   ├── mul_s9xu30_pipe.vhd
│   ├── requantize.vhd
│   ├── leaky_relu.vhd
│   ├── maxpool_unit.vhd
│   ├── elem_add.vhd
│   ├── fifo_weights.vhd     ← NUEVO
│   ├── dpu_stream_wrapper_v4.vhd  ← MODIFICADO
│   ├── dm_s2mm_ctrl.vhd
│   └── create_bd.tcl         ← TODAS las rutas son $src_dir/archivo.vhd
├── sim/               ← testbenches + run_sim.sh
├── sw/                ← firmware ARM
├── docs/              ← especificación + diagramas
└── README.md
```

**Prohibido**: rutas como `../../P_13_conv_test/src/mac_unit.vhd` en `create_bd.tcl`.

### 10.2 Entorno de ejecución

| Tarea | Dónde se ejecuta | Herramienta |
|---|---|---|
| Síntesis + Implementación | **Servidor remoto** (SSH a jce03@100.73.144.105) | Vivado 2025.2 en E:/vivado-instalado/2025.2.1 |
| Simulación XSIM | **Servidor remoto** o **PC local** (AMDDesignTools en C:/AMDDesignTools/2025.2) | xvhdl + xelab + xsim |
| Compilación firmware ARM | **PC local** | arm-none-eabi-gcc (C:/AMDDesignTools/2025.2/gnu/aarch32) |
| Programación JTAG | **PC local** | xsct.bat (C:/AMDDesignTools/2025.2/Vitis/bin) |
| Tests Python + Ethernet | **PC local** | Python 3.14 + yolov4_host.py |
| Board físico | **PC local** | ZedBoard conectada por USB-JTAG + cable Ethernet |

Vivado NO está en el PC local (solo Vitis/xsct/xsim). Para síntesis hay que usar el servidor.

### 10.3 Comunicación PC ↔ ARM (Ethernet)

Los datos se cargan en la DDR del ZedBoard mediante un **servidor TCP** que corre en el ARM (bare-metal, lwIP, puerto 7001) y un **cliente Python** en el PC.

```
PC (Python)                              ARM (bare-metal)
───────────                              ────────────────
yolov4_host.py                           eth_server.c
  │                                        │
  ├── write_ddr(addr, bytes)  ──TCP──▶    memcpy a DDR[addr]
  ├── read_ddr(addr, len)     ──TCP──▶    lee DDR[addr] → bytes
  ├── exec_layer(idx)         ──TCP──▶    dispatch a dpu_exec_*
  └── ping()                  ──TCP──▶    "P_18 OK"
```

**El PC es el cerebro.** Decide qué va en cada dirección de DDR. El ARM solo obedece.

### 10.4 Mapa de memoria DDR (lo que el PC escribe)

```
Dirección        Contenido                    Quién lo escribe
──────────────── ──────────────────────────── ─────────────────
0x1000_0000      Input imagen (519 KB)        PC via write_ddr
0x1010_0000      Mailbox / scratch debug       ARM
0x1100_0000      Array 255 × layer_cfg_t       PC via write_ddr
0x1200_0000      Weights blob (64 MB)          PC via write_ddr
0x1600_0000      Pool activaciones (96 MB)     DPU escribe / PC lee
```

El ARM sabe qué datos usar porque el PC le pasa un `layer_cfg_t` (72 bytes) por cada capa con las direcciones DDR exactas:

```c
typedef struct {
    uint32_t in_addr;      // DDR del input de esta capa
    uint32_t out_addr;     // DDR donde escribir el output
    uint32_t w_addr;       // DDR de los pesos de esta capa
    uint32_t b_addr;       // DDR del bias de esta capa
    uint16_t c_in, c_out;  // dimensiones
    ...                    // pads, kernel, stride, etc.
} layer_cfg_t;  // 72 bytes, sincronizado C ↔ Python
```

### 10.5 Reglas VHDL para RTL sintetizable

**PROHIBIDO en ficheros de `src/` (RTL que se sintetiza):**

| Prohibido | Por qué |
|---|---|
| `shared variable` | No determinismo en síntesis, race conditions |
| `variable` a nivel de architecture (fuera de process) | No sintetizable |
| `wait for X ns` | Solo vale en testbenches, no es hardware |
| `assert` con `severity failure` | Solo para simulación |
| Lógica dependiente de `'U'` o `'X'` | No existe en hardware real |
| `after X ns` en asignaciones | Solo para simulación |
| `real` / `float` / `time` tipos | No sintetizables |
| Lectura de ficheros (`textio`) | Solo para testbenches |

**PERMITIDO:**

| Permitido | Notas |
|---|---|
| `variable` DENTRO de un process | Para intermedios combinacionales (se sintetiza como wire) |
| `signal` | Base de toda la lógica RTL |
| `type array` para RAM | Vivado infiere BRAM automáticamente |
| `attribute` para DSP/BRAM hints | `dont_touch`, `ram_style`, etc. |
| `generic` para parametrizar | Tamaños de buffer, N_MAC, etc. |
| `generate` para instanciar en bucle | mac_array usa esto |

**En ficheros de `sim/` (testbenches): todo vale** — shared variables, wait for, textio, assert failure, etc. No se sintetizan.

### 10.6 Reglas de verificación

1. **Cada módulo RTL nuevo** debe tener un testbench en `sim/` que lo verifica standalone
2. **Cada test compara contra datos ONNX reales**, no sintéticos
3. **Simulación XSIM pasa** antes de sintetizar
4. **Board pasa** antes de declarar éxito
5. **Los tests de P_18 (layers 0 y 1) siguen pasando** (regresión)
6. **CRC32 es la medida**: si `crc_dpu != crc_onnx`, es FAIL aunque 99.99% de bytes coincidan

### 10.7 Velocidad de Ethernet (referencia)

```
WRITE 64 MB (pesos):     1.4 s @ 44 MB/s
WRITE 519 KB (input):    12 ms
READ 5.5 MB (activación): 200 ms @ 28 MB/s
EXEC_LAYER (CONV 416²):  10.8 s
EXEC_LAYER (LEAKY 416²): 0.3 s
Ping estabilidad:         20/20 tras hard_reset.tcl
```

Board necesita `hard_reset.tcl` (con `rst -srst`) tras re-programaciones. Esperar ~30 pings de ARP warmup.

## 11. Compromiso

> Cada capa del DPU produce exactamente los mismos bytes que ONNX Runtime.
> Verificado con CRC32 byte a byte, con tensores reales, tanto en simulación como en hardware.
> Sin trampas. Sin falsos positivos.
