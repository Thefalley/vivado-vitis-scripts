# BRAM Controller — Primitiva de almacenamiento para DPU

## Que es

Un **buffer de memoria masivo controlable por software** implementado
en la FPGA. Permite al procesador ARM (Zynq PS) cargar datos en la
FPGA, almacenarlos en Block RAM, y liberarlos bajo demanda hacia un
consumidor (DPU, acelerador, etc.) mediante un flujo controlado.

Piensa en el como un **deposito de agua con grifo**: el ARM llena el
deposito (fase LOAD), y cuando el acelerador necesita datos, el ARM
abre el grifo (fase DRAIN). El grifo tiene un contador que cierra
automaticamente despues de N litros.

```
                ARM (software)
                    |
              escribe registros
              AXI-Lite (control)
                    |
                    v
  DMA -----> [ BRAM CTRL ] ------> DPU / acelerador
  (DDR)      [ 80 BRAMs  ]         (consumidor)
             [ 320 KB     ]
```

---

## Por que es importante

En un acelerador de redes neuronales (DPU), necesitas alimentar dos
tipos de datos al hardware:

1. **Pesos** — se cargan una vez por capa, se consumen multiples veces
2. **Activaciones** — fluyen continuamente entre capas

Este modulo resuelve el problema de los **pesos**: los precargas en
Block RAM via DMA, y luego los dosificas al MAC/convolutor cuando los
necesita. Sin este buffer, el acelerador tendria que ir a DDR cada vez
que necesita un peso — mucho mas lento y con latencia impredecible.

### Ventajas sobre acceso directo a DDR

| | Acceso DDR | BRAM Controller |
|---|---|---|
| Latencia | ~50-100 ns (variable) | ~4 ciclos = 40 ns (fija) |
| Throughput | compartido con CPU | **1 word/ciclo dedicado** |
| Determinismo | no (arbitraje) | **si** (recursos dedicados) |
| Control de flujo | no | **si** (N words exactos) |

---

## Arquitectura

### Vista general

```
  +----------------------------------------------------------+
  |  bram_ctrl_top                                           |
  |                                                          |
  |  +----------------+     +----------------------------+   |
  |  | axi_lite_cfg   |     |     fifo_2x40_bram         |   |
  |  | (32 registros) |     |                            |   |
  |  |                |     |  Chain A: 40 x bram_sp     |   |
  |  | reg0: ctrl_cmd |     |  [0][1][2]...[39]          |   |
  |  | reg1: n_words  |     |                            |   |
  |  +-------+--------+     |  Chain B: 40 x bram_sp     |   |
  |          |               |  [0][1][2]...[39]          |   |
  |          v               |                            |   |
  |     +---------+          |  Ping-pong: 1 word/ciclo   |   |
  |     |  FSM    |          +----------------------------+   |
  |     | IDLE    |                    ^          |           |
  |     | LOAD    |-----> gate ------->|          |           |
  |     | DRAIN   |                              v           |
  |     | STOP    |<---- gate <------------------+           |
  |     +---------+                                          |
  |          ^                                               |
  +----------|-----------------------------------------------+
             |
     s_axis  |  m_axis
     (in)    |  (out)
```

### Jerarquia de modulos

```
bram_ctrl_top                           <-- top level
  +-- axi_lite_cfg                      <-- 32 registros AXI-Lite
  +-- fifo_2x40_bram                    <-- buffer 80-BRAM
        +-- HsSkidBuf_dest (x2)        <-- skid buffers AXI-Stream
        +-- bram_sp (x40)              <-- Chain A
        +-- bram_sp (x40)              <-- Chain B
```

**6 ficheros VHDL** en total. Ninguna IP de Xilinx custom — todo
inferido desde VHDL puro.

---

## Interfaces

### AXI-Stream Slave (entrada de datos)

```
s_axis_tdata  [31:0]  in   Dato de entrada (32 bits)
s_axis_tlast          in   Fin de paquete (opcional, ver n_words)
s_axis_tvalid         in   Dato disponible
s_axis_tready         out  Buffer puede aceptar
```

Solo acepta datos cuando la FSM esta en **S_LOAD**. En cualquier otro
estado, `tready = 0` (backpressure total).

### AXI-Stream Master (salida de datos)

```
m_axis_tdata  [31:0]  out  Dato de salida
m_axis_tlast          out  Fin de paquete
m_axis_tvalid         out  Dato disponible
m_axis_tready         in   Consumidor puede recibir
```

Solo emite datos cuando la FSM esta en **S_DRAIN**. En cualquier otro
estado, `tvalid = 0`.

**Throughput de salida: 1 palabra por ciclo** (continuo, sin huecos)
gracias a la arquitectura ping-pong entre Chain A y Chain B.

### AXI-Lite Slave (control desde ARM)

```
S_AXI_*                    Bus AXI-Lite completo (7-bit addr)
                           32 registros x 32 bits = 128 bytes
```

Direccion base tipica en ZedBoard: `0x4000_0000`.

---

## Registros de control

### reg0 — `ctrl_cmd` (offset 0x00)

El ARM escribe aqui para controlar la maquina de estados.

| Valor | Nombre | Efecto |
|---|---|---|
| `0x00` | NOP | Limpia el comando anterior |
| `0x01` | LOAD | Abre la entrada. Datos fluyen del DMA al BRAM |
| `0x02` | DRAIN | Abre la salida. Datos fluyen del BRAM al consumidor |
| `0x03` | STOP | Para todo inmediatamente |

**Protocolo**: escribir el comando, esperar ~1 us, escribir `0x00` (NOP).
La FSM detecta el flanco (primera vez que ve != 0) y actua una sola vez.

```c
Xil_Out32(BASE + 0x00, 0x01);   // CMD_LOAD
wait_us(1);                      // dejar que la FSM lo sample
Xil_Out32(BASE + 0x00, 0x00);   // NOP (limpiar)
```

### reg1 — `n_words` (offset 0x04)

Configura **cuantas palabras** puede procesar en cada fase.

| Valor | Comportamiento |
|---|---|
| `0` | Modo tlast: la fase termina cuando llega `tlast` del DMA |
| `N > 0` | Modo conteo: la fase termina exactamente despues de N handshakes |

**Modo conteo** es el mas util: el ARM decide exactamente cuantos datos
pasan. Ejemplo para cargar 40 pesos:

```c
Xil_Out32(BASE + 0x04, 40);     // n_words = 40
Xil_Out32(BASE + 0x00, 0x01);   // CMD_LOAD
wait_us(1);
Xil_Out32(BASE + 0x00, 0x00);   // NOP
```

En modo conteo, el wrapper inyecta un `tlast` sintetico en el ultimo
beat para que el FIFO interno cambie de modo escritura a modo lectura.
El DMA no necesita generar tlast — lo hace el hardware automaticamente.

---

## Maquina de estados

```
                     CMD_LOAD (0x01)
          +--------+                  +--------+
          |        |----------------->|        |
   reset->| S_IDLE |                  | S_LOAD |
          |        |<-----------------|        |
          +--------+  auto (N beats   +--------+
               |       o tlast)            |
               |                           |
     CMD_DRAIN |                  CMD_STOP |
      (0x02)   |                   (0x03)  |
               v                           v
          +--------+                  +--------+
          |S_DRAIN |                  | S_STOP |
          |        |----------------->|        |
          +--------+  CMD_STOP        +--------+
               |                           |
               | auto (N beats             | CMD_NOP
               |  o tlast)                 |  (0x00)
               +-------> S_IDLE <----------+
```

### S_IDLE — reposo

- Entrada bloqueada (`s_axis_tready = 0`)
- Salida bloqueada (`m_axis_tvalid = 0`)
- Espera un comando del ARM
- El contador de beats se resetea a 0

### S_LOAD — fase de carga

- Entrada **abierta**: datos fluyen del DMA al BRAM
- Salida bloqueada
- El contador cuenta cada handshake (`tvalid AND tready`)
- **Termina automaticamente** cuando:
  - `beat_count = n_words - 1` (modo conteo), O
  - `tlast = 1` en la entrada (modo tlast)
- Al terminar: vuelve a S_IDLE

### S_DRAIN — fase de drenaje

- Entrada bloqueada
- Salida **abierta**: datos fluyen del BRAM al consumidor
- El contador cuenta cada handshake de salida
- **Termina automaticamente** cuando:
  - `beat_count = n_words - 1` (modo conteo), O
  - `tlast = 1` en la salida (modo tlast)
- Al terminar: vuelve a S_IDLE
- **Throughput: 1 word/ciclo continuo** (ping-pong)

### S_STOP — parada de emergencia

- Todo bloqueado
- Se activa con `CMD_STOP` desde cualquier estado
- Vuelve a S_IDLE cuando el ARM escribe `CMD_NOP` (0x00)

---

## Buffer interno: fifo_2x40_bram

### Arquitectura ping-pong

El buffer divide los datos entre dos cadenas (A y B) alternando:

```
Palabra 0  --> Chain A, banco 0, pos 0
Palabra 1  --> Chain B, banco 0, pos 0
Palabra 2  --> Chain A, banco 0, pos 1
Palabra 3  --> Chain B, banco 0, pos 1
...
Palabra 2047 --> Chain B, banco 0, pos 1023
Palabra 2048 --> Chain A, banco 1, pos 0     (siguiente banco)
...
```

Cada chain tiene **40 bancos** de 1024 palabras cada uno (un bram_sp
por banco). Total por chain: 40960 palabras. Total del buffer:
**81920 palabras = 320 KB**.

### Por que ping-pong

La BRAM tiene **1 ciclo de latencia** en lectura: si pides el dato en
el ciclo N, lo tienes en el ciclo N+1. Con un solo BRAM, eso limita
la salida a 1 word cada 2 ciclos (50% throughput).

Con ping-pong, mientras Chain A entrega la palabra par, Chain B ya
esta preparando la impar. Resultado: **1 word por ciclo** continuo
en la salida. El consumidor ve `tvalid` permanentemente alto durante
toda la fase de drenaje.

```
Ciclo:  0     1     2     3     4     5
A:     [w0]        [w2]        [w4]
B:           [w1]        [w3]        [w5]
Out:   [w0]  [w1]  [w2]  [w3]  [w4]  [w5]   <-- 1/ciclo
```

### Primitiva bram_sp

Cada banco es una instancia de `bram_sp`:

```vhdl
-- Patron canonico de inferencia de Block RAM en Xilinx
type ram_type is array (0 to 1023) of std_logic_vector(31 downto 0);
signal ram : ram_type;
attribute ram_style of ram : signal is "block";

process(clk)
begin
    if rising_edge(clk) then
        if we = '1' then
            ram(addr) <= din;        -- escritura sincrona
        end if;
        dout <= ram(addr);           -- lectura sincrona (1 ciclo)
    end if;
end process;
```

Claves para que Vivado infiera BRAM real (no LUTRAM):
- Lectura **sincrona** (dentro de `rising_edge`)
- Atributo `ram_style = "block"` explicito
- Profundidad >= 64 (1024 esta muy por encima)

---

## Configurabilidad

### Generics del modulo

| Generic | Default | Que cambia |
|---|---|---|
| `DATA_WIDTH` | 32 | Ancho de palabra |
| `BANK_ADDR_W` | 10 | Profundidad por BRAM (2^10 = 1024) |
| `N_BANKS` | 40 | BRAMs por chain |

### Ejemplos de configuracion

| N_BANKS | BRAMs totales | Capacidad | % del xc7z020 |
|---:|---:|---|---:|
| 4 | 8 | 8K words = 32 KB | 5.7% |
| 10 | 20 | 20K words = 80 KB | 14.3% |
| 20 | 40 | 40K words = 160 KB | 28.6% |
| **40** | **80** | **81K words = 320 KB** | **57.1%** |
| 64 | 128 | 131K words = 512 KB | 91.4% |

Cambiar capacidad = cambiar **un solo numero** en el generic map:

```vhdl
fifo_inst : entity work.fifo_2x40_bram
    generic map (N_BANKS => 20)   -- 40 BRAMs, 160 KB
```

---

## Uso tipico: multiples instancias para DPU

Para una DPU real se necesitan al menos **dos buffers**:

```
  DDR                                       DPU
   |                                         |
   |  DMA_pesos                              |
   +---------> [ BRAM CTRL "pesos"  ] ------>+ MAC input A
   |            N_BANKS=30, 60 BRAMs         |
   |            192 KB                       |
   |                                         |
   |  DMA_act                                |
   +---------> [ BRAM CTRL "activ"  ] ------>+ MAC input B
                N_BANKS=20, 40 BRAMs         |
                128 KB                       |
                                             |
                Total: 100 BRAMs (71%)       v
                                          resultado
```

Cada instancia tiene su propia direccion AXI-Lite y sus propios
registros `ctrl_cmd` / `n_words`. El ARM controla ambas independiente-
mente: puede cargar pesos mientras drena activaciones (o viceversa).

```c
// Cargar pesos de la capa 3 (192 pesos de 32 bits)
Xil_Out32(PESOS_BASE + REG_NWORDS, 192);
Xil_Out32(PESOS_BASE + REG_CMD, CMD_LOAD);

// Mientras tanto, drenar activaciones de la capa anterior
Xil_Out32(ACTIV_BASE + REG_NWORDS, 1024);
Xil_Out32(ACTIV_BASE + REG_CMD, CMD_DRAIN);
```

---

## Flujo de uso detallado (bare-metal C)

### Paso 1: inicializar DMA

```c
XAxiDma_Config *cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
XAxiDma_CfgInitialize(&dma, cfg);
XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
```

### Paso 2: cargar datos (LOAD)

```c
// Preparar buffer en DDR
u32 *weights = (u32 *)0x01000000;
for (int i = 0; i < N; i++) weights[i] = peso[i];
Xil_DCacheFlushRange((UINTPTR)weights, N * 4);

// Configurar cuantos datos
Xil_Out32(CTRL_BASE + REG_NWORDS, N);

// Abrir la entrada
Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
wait_us(1);
Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

// Lanzar DMA (envia N words de DDR a la FPGA)
XAxiDma_SimpleTransfer(&dma, (UINTPTR)weights,
                       N * 4, XAXIDMA_DMA_TO_DEVICE);

// Esperar a que DMA termine
while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));
```

Cuando la FSM acepta N beats, vuelve automaticamente a S_IDLE.
Los datos quedan almacenados en los 80 BRAMs.

### Paso 3: drenar datos (DRAIN)

```c
// Preparar buffer de recepcion
u32 *output = (u32 *)0x01100000;
Xil_DCacheFlushRange((UINTPTR)output, N * 4);

// Preparar DMA para recibir ANTES de abrir el grifo
XAxiDma_SimpleTransfer(&dma, (UINTPTR)output,
                       N * 4, XAXIDMA_DEVICE_TO_DMA);

// Abrir la salida
Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
wait_us(1);
Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

// Esperar
while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));
Xil_DCacheInvalidateRange((UINTPTR)output, N * 4);
```

### Paso 4: verificar (opcional)

```c
for (int i = 0; i < N; i++) {
    if (output[i] != peso[i]) errors++;
}
```

### Flujo incremental (chunks)

Para procesar mas datos de los que caben o para dosificar:

```c
int processed = 0;
while (processed < TOTAL) {
    int chunk = min(CHUNK_SIZE, TOTAL - processed);

    // LOAD chunk
    Xil_Out32(CTRL_BASE + REG_NWORDS, chunk);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
    wait_us(1);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);
    DMA_MM2S(src + processed, chunk * 4);
    wait_DMA();

    wait_us(100);  // FSM settling

    // DRAIN chunk
    DMA_S2MM(dst + processed, chunk * 4);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
    wait_us(1);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);
    wait_DMA();

    processed += chunk;
}
```

**Verificado en HW real: 260 words en 7 iteraciones de 40, PASS.**

---

## Consideraciones importantes

### Cache

El Zynq ARM tiene cache L1/L2. Los buffers DMA en DDR DEBEN
sincronizarse:

```c
// ANTES de DMA write (ARM -> FPGA):
Xil_DCacheFlushRange(addr, size);    // escribe cache a DDR

// DESPUES de DMA read (FPGA -> ARM):
Xil_DCacheInvalidateRange(addr, size);  // descarta cache, lee DDR
```

Sin esto, el DMA lee datos viejos del cache o el ARM lee datos
viejos del cache despues de que el DMA escriba.

### Timing entre comandos AXI-Lite

El registro `ctrl_cmd` necesita ~1 us entre la escritura del
comando y la escritura de NOP. Sin este delay, la FSM puede no
ver el comando (edge detection falla):

```c
Xil_Out32(BASE, CMD_LOAD);    // escribir comando
wait_us(1);                    // CRITICO: dejar que FSM lo sample
Xil_Out32(BASE, CMD_NOP);     // limpiar
```

### S2MM antes de DRAIN

El DMA S2MM debe estar configurado y listo **ANTES** de abrir el
drenaje. Si abres el drenaje primero, los primeros beats se pierden
porque S2MM no esta escuchando:

```c
// CORRECTO:
XAxiDma_SimpleTransfer(&dma, dst, N*4, DEVICE_TO_DMA);  // S2MM listo
Xil_Out32(BASE, CMD_DRAIN);                               // ahora abre

// INCORRECTO:
Xil_Out32(BASE, CMD_DRAIN);                               // datos salen
XAxiDma_SimpleTransfer(&dma, dst, N*4, DEVICE_TO_DMA);  // tarde!
```

---

## Recursos FPGA (xc7z020, post-impl)

| Recurso | Usado | Disponible | % |
|---|---:|---:|---:|
| **Block RAM Tiles** | **85** | 140 | **60.7%** |
| RAMB36E1 | 84 | — | — |
| RAMB18E1 | 2 | — | — |
| Slice LUTs | 4324 | 53200 | 8.1% |
| Slice Registers | 5168 | 106400 | 4.9% |
| DSPs | 0 | 220 | 0.0% |

De los 85 BRAM tiles:
- 80 RAMB36: fifo_2x40_bram (nuestro buffer)
- 4 RAMB36 + 2 RAMB18: FIFOs internos del AXI DMA

---

## Verificaciones realizadas en HW real

| Test | Descripcion | Resultado |
|---|---|---|
| Basic 256 | 256 words, single load/drain | **PASS** |
| Basic 40 | 40 words, n_words=40 | **PASS** |
| Incremental 260 | 260 words en 7 chunks de 40+20 | **PASS** |
| S_STOP mid-drain | Parada de emergencia durante drenaje | **PASS** (0 leaks) |
| Drain resume | Reanudar tras S_STOP | **PASS** |
| Backpressure | tready toggling 2on/1off | **PASS** (sim) |
| Synth BRAM count | 80 RAMB36E1 inferidos | **PASS** |
| Timing 100 MHz | Place & route completo | **PASS** |

---

## Ficheros del proyecto P_101

```
P_101_bram_ctrl/
+-- src/
|   +-- bram_ctrl_top.vhd          top-level con AXI-Lite + FSM
|   +-- axi_lite_cfg.vhd           banco registros (de P_3)
|   +-- fifo_2x40_bram.vhd         buffer 80-BRAM ping-pong
|   +-- bram_sp.vhd                primitiva BRAM
|   +-- HsSkidBuf_dest.vhd         skid buffer
|   +-- create_bd.tcl              Block Design Zynq+DMA
+-- sw/
|   +-- basic40.c                  test minimo 40 words
|   +-- incremental_test_v2.c      test incremental 260 words
|   +-- create_vitis.py            script Vitis
|   +-- run_basic40.tcl            xsct para basic40
|   +-- run_incremental_v2.tcl     xsct para incremental
|   +-- probe.tcl                  diagnostico de placa
+-- build/
|   +-- bit/bram_ctrl_bd_wrapper.bit
|   +-- elf/bram_ctrl_test.elf
|   +-- elf/fsbl.elf
+-- project.cfg
+-- P101_REPORT.md                 reporte tecnico
+-- BRAM_CTRL_PRIMITIVA.md         este documento
```
