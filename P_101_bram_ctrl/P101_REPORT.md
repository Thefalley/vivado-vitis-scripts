# P_101 BRAM CTRL — Reporte completo

**Fecha:** 2026-04-12
**Target:** ZedBoard (xc7z020clg484-1), Vivado 2025.2.1
**Verificado en HW:** SI — 256/256 words PASS via JTAG

---

## 1. Que es P_101

Un **buffer de memoria masivo controlado por software** implementado
en la FPGA. El ARM (Zynq PS) controla el flujo de datos mediante
registros AXI-Lite: decide CUANDO cargar datos, CUANTOS cargar, y
CUANDO drenarlos hacia un consumidor (como una DPU).

El sistema utiliza **85 Block RAMs** del xc7z020 (60.7% del chip) para
almacenar hasta **81920 palabras (320 KB)** en un buffer de
store-and-replay con arquitectura ping-pong que entrega datos a
**1 palabra por ciclo** durante la fase de drenaje.

Caso de uso principal: **almacen de pesos** para una DPU (Deep Processing
Unit). El ARM carga los pesos via DMA, luego los dosifica al
acelerador cuando este los necesita — como un "cuentagotas".

---

## 2. Arquitectura del sistema completo

```
  Zynq PS (ARM Cortex-A9)
    |                         |
    | M_AXI_GP0              | S_AXI_HP0
    v                         ^
  +----------+              +----------+
  | AXI IC   |              | AXI IC   |
  | GP0      |              | HP0      |
  +----+-----+              +----+-----+
       |    |                     ^    ^
       v    v                     |    |
  +----+ +--------+         +----+----+---+
  |DMA | |bram_   |         |    DMA      |
  |ctrl| |ctrl_top|         | M_AXI_MM2S  |
  |    | |        |         | M_AXI_S2MM  |
  +----+ +--------+         +------+------+
              |    |                |    |
              |    |     DDR <-----+----+
              |    |     (source + dest buffers)
              |    |
         s_axis  m_axis
              |    |
              v    |
         +-----------+
         | fifo_     |
         | 2x40_bram |  <-- 80 BRAMs (40 chain A + 40 chain B)
         +-----------+
```

### Mapa de direcciones

| Periferico | Direccion base | Acceso |
|---|---|---|
| `bram_ctrl_top` S_AXI | `0x4000_0000` | AXI-Lite (config FSM) |
| `axi_dma_0` S_AXI_LITE | `0x4040_0000` | AXI-Lite (control DMA) |
| DDR | `0x0000_0000` — `0x1FFF_FFFF` | 512 MB via HP0 |

---

## 3. Jerarquia de modulos

```
bram_ctrl_top                        <-- TOP (AXI-Lite + FSM + gating)
  |
  +-- axi_lite_cfg                   <-- banco de 32 registros AXI-Lite
  |
  +-- fifo_2x40_bram                 <-- buffer store-and-replay (80 BRAMs)
        |
        +-- HsSkidBuf_dest  (x2)    <-- skid buffer entrada + salida
        |
        +-- bram_sp  (x40)          <-- Chain A: 40 BRAMs single-port
        |
        +-- bram_sp  (x40)          <-- Chain B: 40 BRAMs single-port
```

**Ficheros VHDL definitivos (6 en total):**

| Fichero | Funcion |
|---|---|
| `bram_ctrl_top.vhd` | Top-level: AXI-Lite + FSM control + gating |
| `axi_lite_cfg.vhd` | Banco de registros AXI-Lite (32 regs x 32 bits) |
| `fifo_2x40_bram.vhd` | Buffer 80-BRAM store-and-replay ping-pong |
| `bram_sp.vhd` | Primitiva BRAM single-port inferible |
| `HsSkidBuf_dest.vhd` | Skid buffer AXI-Stream 2-deep |
| `create_bd.tcl` | Script de Block Design para Vivado |

---

## 4. Registros AXI-Lite (mapa de control)

El ARM controla el modulo escribiendo en los registros via AXI-Lite
en la direccion base `0x4000_0000`:

| Offset | Nombre | R/W | Descripcion |
|---|---|---|---|
| `0x00` | `ctrl_cmd` | W | Comando de control |
| `0x04` | `n_words` | W | Numero de palabras por fase |
| `0x08`—`0x7C` | — | — | Reservados (32 registros totales) |

### Registro `ctrl_cmd` (offset 0x00)

| Valor | Comando | Efecto |
|---|---|---|
| `0x00` | NOP | Sin efecto / clear del comando anterior |
| `0x01` | LOAD | Inicia fase de carga (s_axis abierto, m_axis bloqueado) |
| `0x02` | DRAIN | Inicia fase de drenaje (s_axis bloqueado, m_axis abierto) |
| `0x03` | STOP | Parada de emergencia (todo bloqueado) |

**Protocolo de escritura:** el ARM escribe el comando (ej. `0x01`), y
luego escribe `0x00` (NOP) para limpiar. La FSM detecta el flanco
(edge-sensitive) y solo actua una vez por comando.

```c
// Ejemplo: iniciar carga
Xil_Out32(0x40000000, 0x01);   // CMD_LOAD
Xil_Out32(0x40000000, 0x00);   // NOP (clear)
```

### Registro `n_words` (offset 0x04)

| Valor | Comportamiento |
|---|---|
| `0` | Usa `tlast` como senal de fin (modo automatico) |
| `N > 0` | Cuenta N beats aceptados/emitidos y auto-stop (modo conteo) |

**Modo conteo** es el mas interesante: el ARM decide exactamente cuantos
datos pasan en cada fase. Ejemplo:

```c
Xil_Out32(0x40000004, 40);     // n_words = 40
Xil_Out32(0x40000000, 0x01);   // CMD_LOAD -> acepta 40 y para
```

---

## 5. Maquina de estados (FSM)

```
                     ctrl_cmd = LOAD
          +--------+              +--------+
          |        |------------->|        |
   reset->| S_IDLE |              | S_LOAD |---> s_axis abierto
          |  (00)  |<-------------|  (01)  |     m_axis bloqueado
          +--------+  count=N     +--------+     cuenta beats
               |      o tlast          |
               |                       | CMD_STOP
     CMD_DRAIN |                       v
               |                 +--------+
               |                 | S_STOP |---> todo bloqueado
               +---------------->|  (11)  |
               |                 +--------+
               |                       ^
               v                       | CMD_STOP
          +--------+                   |
          |S_DRAIN |-------------------+
          | (10)   |---> s_axis bloqueado
          |        |     m_axis abierto
          +--------+     cuenta beats
               |
               | count=N o tlast -> S_IDLE
```

### Transiciones automaticas (sin intervencion del ARM)

- **S_LOAD -> S_IDLE**: cuando `beat_count` alcanza `n_words` (si `n_words > 0`) O cuando llega `tlast` (si `n_words = 0`)
- **S_DRAIN -> S_IDLE**: misma logica, aplicada a beats emitidos

### Transiciones manuales (ARM escribe registro)

- **S_IDLE -> S_LOAD**: ARM escribe `0x01` en `ctrl_cmd`
- **S_IDLE -> S_DRAIN**: ARM escribe `0x02`
- **Cualquiera -> S_STOP**: ARM escribe `0x03` (prioridad maxima)
- **S_STOP -> S_IDLE**: ARM escribe `0x00` (NOP)

### Contador de beats

El `beat_count` (32 bits) se resetea al entrar en cada fase. Cuenta
handshakes (tvalid AND tready = 1) durante la fase activa. Cuando
alcanza `n_words`, la FSM auto-retorna a S_IDLE.

---

## 6. Configurabilidad

### Generics del modulo

| Generic | Default | Que cambia |
|---|---|---|
| `DATA_WIDTH` | 32 | Ancho de palabra (bits) |
| `BANK_ADDR_W` | 10 | Profundidad por BRAM: 2^10 = 1024 words |
| `N_BANKS` | 40 | BRAMs por chain. Total = 2 * N_BANKS |

### Tabla de configuraciones

| N_BANKS | Total BRAMs | Capacidad (words) | Capacidad (KB) | % xc7z020 |
|---:|---:|---:|---:|---:|
| 4 | 8 | 8192 | 32 | 5.7% |
| 10 | 20 | 20480 | 80 | 14.3% |
| 20 | 40 | 40960 | 160 | 28.6% |
| **40** | **80** | **81920** | **320** | **57.1%** |
| 64 | 128 | 131072 | 512 | 91.4% |

### Posibilidad de multiples FIFOs en paralelo

El modulo es instanciable multiples veces. Para una DPU real se
podrian tener **dos instancias independientes**:

```
+-------------------+        +-------------------+
| bram_ctrl_top     |        | bram_ctrl_top     |
| "FIFO_PESOS"     |        | "FIFO_ACTIVACION" |
| N_BANKS = 30      |        | N_BANKS = 20      |
| 60 BRAMs, 60K w  |        | 40 BRAMs, 40K w   |
| AXI-Lite @0x4000  |        | AXI-Lite @0x4200  |
+-------------------+        +-------------------+
         |                            |
    pesos al MAC               activaciones al MAC
         |                            |
         +---------> DPU <-----------+
```

**Total: 100 BRAMs (71% del chip)**, dejando 40 BRAMs libres para
el DMA y otros perifericos.

Cada FIFO tiene su propio `ctrl_cmd` y `n_words`, asi que el ARM
controla independientemente cuando cargar los pesos y cuando cargar
las activaciones. Pueden funcionar en paralelo (una cargando mientras
la otra drena).

Para implementar esto:
1. Instanciar `bram_ctrl_top` dos veces en el Block Design
2. Conectar cada una al mismo DMA (con un AXI-Stream switch) o a DMAs separados
3. Asignar direcciones AXI-Lite distintas (ej. `0x4000_0000` y `0x4200_0000`)
4. En el C, controlar cada FIFO por separado

---

## 7. Recursos FPGA (post-implementacion)

| Recurso | Usado | Disponible | % |
|---|---:|---:|---:|
| **Block RAM Tiles** | **85** | 140 | **60.7%** |
| RAMB36E1 | 84 | — | — |
| RAMB18E1 | 2 | — | — |
| Slice LUTs | 4324 | 53200 | 8.1% |
| Slice Registers | 5168 | 106400 | 4.9% |
| DSPs | 0 | 220 | 0.0% |
| Bonded IOB | 130 | 200 | 65.0% |
| BUFG | 1 | 32 | 3.1% |

De los 85 BRAM tiles:
- **80 RAMB36**: nuestro fifo_2x40_bram (40 chain A + 40 chain B)
- **4 RAMB36 + 2 RAMB18**: FIFOs internos del AXI DMA

---

## 8. Verificacion en hardware (PASS)

### Test 1: carga y drenaje basico (256 words)

```
Configuracion:
  n_words = 256
  Patron = 0xBEEF0000 + i  (i = 0..255)

Secuencia:
  1. ARM escribe n_words=256, CMD_LOAD
  2. DMA MM2S envia 256 words
  3. FSM cuenta 256 beats, auto-stop
  4. ARM escribe CMD_DRAIN
  5. DMA S2MM recibe 256 words
  6. JTAG lee DDR y compara

Resultado:
  Word 0: src=0xBEEF0000 dst=0xBEEF0000 OK
  Word 1: src=0xBEEF0001 dst=0xBEEF0001 OK
  ...
  Word 255: src=0xBEEF00FF dst=0xBEEF00FF OK

  RESULTADO: PASS (256/256 words OK)
```

### Test 2: control de flujo incremental (PENDIENTE)

Este test valida que `n_words` realmente controla el flujo en
trozos:

```
Configuracion:
  DMA envia 260 words de golpe
  FSM configurada con n_words=40 por iteracion

Secuencia:
  Iteracion 1: CMD_LOAD (n=40), CMD_DRAIN (n=40) -> words 0..39
  Iteracion 2: CMD_LOAD (n=40), CMD_DRAIN (n=40) -> words 40..79
  ...
  Iteracion 6: CMD_LOAD (n=40), CMD_DRAIN (n=40) -> words 200..239
  Iteracion 7: CMD_LOAD (n=20), CMD_DRAIN (n=20) -> words 240..259

  Verificar: DMA MM2S completa despues de iter 7
  Verificar: dst[0..259] == src[0..259]
  Verificar: FSM no dejo pasar mas de 40 por fase
```

---

## 9. App bare-metal (sw/bram_ctrl_test.c)

```c
// Flujo principal
Xil_Out32(CTRL_BASE + REG_NWORDS, NUM_WORDS);   // cuantos por fase
Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);        // abrir entrada
Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);          // limpiar

XAxiDma_SimpleTransfer(&dma, src, N*4, DMA_TO_DEVICE);  // DMA envia
while (XAxiDma_Busy(&dma, DMA_TO_DEVICE));               // esperar

Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);       // abrir salida
Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

XAxiDma_SimpleTransfer(&dma, dst, N*4, DEVICE_TO_DMA);  // DMA recibe
while (XAxiDma_Busy(&dma, DEVICE_TO_DMA));

// Verificar dst[i] == patron[i]
```

---

## 10. Iteraciones del desarrollo

| Iter | Modulo | BRAMs | Resultado | Aporte |
|---|---|---:|---|---|
| 1 | `bram_stream` | 1 | Synth+Sim PASS | Patron inferencia BRAM |
| 2 | `bram_chain` | 2 | Synth PASS | 2 BRAMs en serie |
| 3 | `bram_fifo` | 1 | Synth+Sim PASS | True FIFO con SDP |
| 4 | `bram_stream_pp` | 2 | Synth+Sim PASS | Ping-pong 1 word/ciclo |
| 5 | `fifo_2x40_bram` | 80 | Synth+Sim PASS | Store-and-replay masivo |
| 6 | `bram_ctrl_fifo` | 80 | Synth+Sim PASS | Wrapper ctrl (sin AXI-Lite) |
| **7** | **`bram_ctrl_top`** | **80** | **Synth+Impl+HW PASS** | **AXI-Lite + FSM + n_words + HW real** |

---

## 11. Ficheros del proyecto P_101

```
P_101_bram_ctrl/
├── src/
│   ├── bram_ctrl_top.vhd        (top-level: AXI-Lite + FSM)
│   ├── axi_lite_cfg.vhd         (banco de registros, copiado de P_3)
│   ├── fifo_2x40_bram.vhd       (buffer 80-BRAM store-and-replay)
│   ├── bram_sp.vhd              (primitiva BRAM)
│   ├── HsSkidBuf_dest.vhd       (skid buffer)
│   └── create_bd.tcl            (Block Design: Zynq+DMA+bram_ctrl_top)
├── sw/
│   ├── bram_ctrl_test.c          (app bare-metal: 256 words round-trip)
│   ├── create_vitis.py           (script creacion workspace Vitis)
│   └── run.tcl                   (xsct: program + JTAG verify)
├── build/
│   ├── bit/bram_ctrl_bd_wrapper.bit  (bitstream 4.0 MB)
│   └── elf/
│       ├── bram_ctrl_test.elf    (app 38 KB)
│       └── fsbl.elf              (FSBL 254 KB)
├── project.cfg
└── P101_REPORT.md                (este fichero)
```
