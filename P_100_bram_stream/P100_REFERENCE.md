# P_100 BRAM FIFO — Referencia del diseno final

## 1. Jerarquia de modulos

```
bram_ctrl_fifo                          <-- TOP LEVEL (control + buffer)
  |
  +-- fifo_2x40_bram                    <-- buffer store-and-replay (80 BRAMs)
  |     |
  |     +-- HsSkidBuf_dest  (x2)       <-- skid buffer entrada + salida
  |     |
  |     +-- bram_sp  (x40)             <-- Chain A: 40 BRAMs single-port
  |     |
  |     +-- bram_sp  (x40)             <-- Chain B: 40 BRAMs single-port
  |
  (no sub-modulos propios, solo gating combinacional)
```

**Total: 4 ficheros VHDL** para el diseno completo:

| Fichero | Lineas | Funcion |
|---|---:|---|
| `bram_ctrl_fifo.vhd` | ~177 | Wrapper de control (FSM de 4 estados) |
| `fifo_2x40_bram.vhd` | ~230 | Buffer 80-BRAM store-and-replay con ping-pong |
| `bram_sp.vhd` | ~44 | Primitiva BRAM single-port inferible |
| `HsSkidBuf_dest.vhd` | ~137 | Skid buffer AXI-Stream 2-deep |


## 2. Modulo: `bram_ctrl_fifo` (TOP LEVEL)

### Que hace

Envuelve el buffer de 80 BRAMs con una maquina de estados que controla
**cuando** se puede escribir y **cuando** se puede leer. Garantiza que
las dos fases (carga y drenaje) no se mezclen. Pensado para almacenar
pesos de una red neuronal y dosificarlos ("cuentagotas") a una DPU.

### Generics (parametros configurables)

| Generic | Default | Descripcion |
|---|---|---|
| `DATA_WIDTH` | 32 | Ancho de cada palabra en bits |
| `BANK_ADDR_W` | 10 | log2 de la profundidad por BRAM (10 = 1024 words/BRAM) |
| `N_BANKS` | 40 | Numero de BRAMs por chain. Total BRAMs = 2 * N_BANKS |

**Capacidad total** = 2 * N_BANKS * 2^BANK_ADDR_W = 2 * 40 * 1024 = **81920 palabras** = **320 KB** a 32 bits.

Para cambiar la capacidad basta con modificar N_BANKS:
- N_BANKS = 20 -> 40 BRAMs, 40960 words, 160 KB
- N_BANKS = 40 -> 80 BRAMs, 81920 words, 320 KB (default)
- N_BANKS = 64 -> 128 BRAMs, 131072 words, 512 KB (cerca del limite del xc7z020: 140 RAMB36)

### Interfaces

```
                    +---------------------------+
   ctrl_load  ---->|                           |
   ctrl_drain ---->|     bram_ctrl_fifo        |
   ctrl_stop  ---->|                           |
   ctrl_state <----|  (FSM: IDLE/LOAD/DRAIN/   |
                    |        STOP)              |
                    |                           |
   s_axis_tdata -->|  AXI-Stream    AXI-Stream |---> m_axis_tdata
   s_axis_tlast -->|  Slave         Master     |---> m_axis_tlast
   s_axis_tvalid-->|  (entrada)     (salida)   |---> m_axis_tvalid
   s_axis_tready<--|                           |<--- m_axis_tready
                    |                           |
   clk        ---->|                           |
   resetn     ---->|                           |
                    +---------------------------+
```

#### Puertos AXI-Stream (entrada — slave)

| Puerto | Dir | Ancho | Descripcion |
|---|---|---|---|
| `s_axis_tdata` | in | DATA_WIDTH | Dato de entrada (32 bits por defecto) |
| `s_axis_tlast` | in | 1 | Marca de fin de paquete. Cuando llega, la fase S_LOAD termina automaticamente |
| `s_axis_tvalid` | in | 1 | El productor tiene dato listo |
| `s_axis_tready` | out | 1 | El buffer puede aceptar dato. Solo='1' en estado S_LOAD |

#### Puertos AXI-Stream (salida — master)

| Puerto | Dir | Ancho | Descripcion |
|---|---|---|---|
| `m_axis_tdata` | out | DATA_WIDTH | Dato de salida |
| `m_axis_tlast` | out | 1 | Marca de fin de paquete. Cuando sale, la fase S_DRAIN termina automaticamente |
| `m_axis_tvalid` | out | 1 | El buffer tiene dato disponible. Solo='1' en estado S_DRAIN |
| `m_axis_tready` | in | 1 | El consumidor puede recibir dato |

#### Puertos de control

| Puerto | Dir | Ancho | Descripcion |
|---|---|---|---|
| `ctrl_load` | in | 1 | **Pulso** (1 ciclo): inicia la fase de carga. S_IDLE -> S_LOAD |
| `ctrl_drain` | in | 1 | **Pulso** (1 ciclo): inicia la fase de drenaje. S_IDLE -> S_DRAIN |
| `ctrl_stop` | in | 1 | **Nivel**: mientras='1', todo bloqueado (S_STOP). Al bajar, vuelve a S_IDLE |
| `ctrl_state` | out | 2 | Estado actual: 00=IDLE, 01=LOAD, 10=DRAIN, 11=STOP |

### Maquina de estados

```
                    ctrl_load
         +--------+ pulse    +--------+
         |        |--------->|        |
  reset->| S_IDLE |          | S_LOAD |---> acepta s_axis
         |  (00)  |<---------|  (01)  |     bloquea m_axis
         +--------+ tlast    +--------+
              |    accepted       |
              |                   | ctrl_stop
    ctrl_drain|                   v
     pulse    |              +--------+
              |              |        |
              +------------->| S_STOP |---> todo bloqueado
              |              |  (11)  |
              |              +--------+
              |                   ^
              v                   | ctrl_stop
         +--------+              |
         |        |--------------+
         |S_DRAIN |
         | (10)   |---> bloquea s_axis
         |        |     emite m_axis
         +--------+
              |
              | tlast emitted -> S_IDLE
```

**Transiciones automaticas:**
- S_LOAD -> S_IDLE: cuando el FIFO acepta un beat con `tlast='1'`
- S_DRAIN -> S_IDLE: cuando el FIFO emite un beat con `tlast='1'`
- S_STOP -> S_IDLE: cuando `ctrl_stop` baja a '0'

**Transiciones manuales (por pulso):**
- S_IDLE -> S_LOAD: pulso en `ctrl_load`
- S_IDLE -> S_DRAIN: pulso en `ctrl_drain`
- Cualquiera -> S_STOP: `ctrl_stop='1'` (prioridad maxima)


## 3. Modulo: `fifo_2x40_bram` (buffer interno)

### Que hace

Buffer de almacenamiento masivo con arquitectura ping-pong para lograr
**1 palabra por ciclo** en la salida. Funciona en dos fases:

1. **S_WRITE**: acepta palabras por s_axis. Las distribuye alternando
   entre Chain A (indices pares) y Chain B (indices impares). Cada chain
   tiene 40 BRAMs de 1024 words cada uno, almacenando hasta 40960 words
   por chain.

2. **S_PRIME + S_PUMP**: tras recibir tlast, una pausa de 1 ciclo (prime)
   carga los primeros datos en los registros de salida. Luego la fase
   pump emite las palabras almacenadas en el orden exacto de entrada, a
   **1 word/ciclo** gracias al ping-pong.

### Arquitectura interna

```
                   wr_chain_sel alternates 0/1
                          |
s_axis --> [skid_in] --> FSM
                          |
              +-----------+-----------+
              |                       |
         Chain A (even)          Chain B (odd)
         bram_sp[0]              bram_sp[0]
         bram_sp[1]              bram_sp[1]
         ...                     ...
         bram_sp[39]             bram_sp[39]
              |                       |
              +-----------+-----------+
                          |
                    rd_count(0) selects A or B
                          |
                     [skid_out] --> m_axis
```

### Distribucion de datos en memoria

```
Palabra 0  -> Chain A, banco 0, offset 0
Palabra 1  -> Chain B, banco 0, offset 0
Palabra 2  -> Chain A, banco 0, offset 1
Palabra 3  -> Chain B, banco 0, offset 1
...
Palabra 2046 -> Chain A, banco 0, offset 1023
Palabra 2047 -> Chain B, banco 0, offset 1023
Palabra 2048 -> Chain A, banco 1, offset 0     <-- siguiente banco
Palabra 2049 -> Chain B, banco 1, offset 0
...
Palabra 81918 -> Chain A, banco 39, offset 1023
Palabra 81919 -> Chain B, banco 39, offset 1023  <-- maximo
```

### Latencia

| Metrica | Valor |
|---|---|
| Latencia write-to-first-read | N + 2 ciclos (N = total palabras del batch) |
| Throughput de escritura | 1 word/ciclo |
| Throughput de lectura (pump) | 1 word/ciclo (continuo, sin huecos) |
| Latencia del prime (entre write y pump) | 1 ciclo |

Nota: la latencia write-to-first-read es alta porque es **batch**: hay que
esperar a que todo el batch se escriba (hasta tlast) antes de empezar a
leer. Esto es correcto para el caso de uso de "cargar pesos y luego
alimentar la DPU".


## 4. Modulo: `bram_sp` (primitiva BRAM)

### Que hace

Bloque de memoria de **1024 x 32 bits** (configurable) que Vivado infiere
como un **RAMB36E1** (Block RAM real en silicio, no LUT RAM). Un solo
puerto compartido para lectura y escritura.

### Patron de inferencia

```vhdl
type ram_type is array (0 to DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
signal ram : ram_type;
attribute ram_style of ram : signal is "block";

process(clk)
begin
    if rising_edge(clk) then
        if we = '1' then
            ram(addr) <= din;       -- escritura sincrona
        end if;
        dout <= ram(addr);          -- lectura sincrona (1 ciclo de latencia)
    end if;
end process;
```

Claves para que Vivado infiera BRAM (no LUTRAM):
- **Lectura sincrona** (dentro de `rising_edge`). Asincronaica genera LUTRAM.
- **`ram_style = "block"`**: fuerza Block RAM explicitamente.
- **Profundidad >= 64 words**: por debajo, Vivado puede elegir LUTRAM.

### Interfaces

| Puerto | Dir | Ancho | Descripcion |
|---|---|---|---|
| `clk` | in | 1 | Reloj |
| `we` | in | 1 | Write enable |
| `addr` | in | ADDR_WIDTH | Direccion (compartida rd/wr) |
| `din` | in | DATA_WIDTH | Dato de entrada |
| `dout` | out | DATA_WIDTH | Dato de salida (1 ciclo de latencia) |


## 5. Modulo: `HsSkidBuf_dest` (skid buffer)

### Que hace

Registro de 2 posiciones (skid buffer) que rompe caminos combinacionales
en las senales `tvalid`/`tready` del handshake AXI-Stream. Sin el, el
timing entre el DMA y el BRAM dependeria de rutas combinacionales largas.

### Como funciona

```
         s_hs_*                    m_hs_*
  ------>[input]--->[output reg]--->[salida]
                \                 /
                 \-->[skid reg]--/
                    (backup slot)
```

- Si el consumidor esta listo (`m_hs_tready=1`): dato pasa directo del
  input al output reg en 1 ciclo.
- Si el consumidor se bloquea (`m_hs_tready=0`): el dato en transito se
  guarda en el skid reg (segunda posicion). Cuando el consumidor se
  desbloquea, el skid reg se vacica primero (FIFO order).
- Capacidad total: 2 slots.

### Interfaces

| Puerto | Dir | Ancho | Descripcion |
|---|---|---|---|
| `s_hs_tdata` | in | HS_TDATA_WIDTH | Dato de entrada |
| `s_hs_tdest` | in | DEST_WIDTH | Destino (no usado, se ata a "00") |
| `s_hs_tlast` | in | 1 | Marca de fin |
| `s_hs_tvalid` | in | 1 | Dato listo en entrada |
| `s_hs_tready` | out | 1 | Puede aceptar |
| `m_hs_tdata` | out | HS_TDATA_WIDTH | Dato de salida |
| `m_hs_tdest` | out | DEST_WIDTH | Destino pasado |
| `m_hs_tlast` | out | 1 | Marca de fin pasada |
| `m_hs_tvalid` | out | 1 | Dato disponible |
| `m_hs_tready` | in | 1 | Consumidor listo |


## 6. Recursos en FPGA (xc7z020, post-synth)

| Recurso | Usado | Disponible | Uso% |
|---|---:|---:|---:|
| **Block RAM Tile** | **80** | 140 | **57.1%** |
| RAMB36E1 | 80 | — | — |
| LUT as Memory | 0 | 17400 | 0.0% |
| Slice LUTs | ~300 | 53200 | ~0.6% |
| Slice Registers | ~700 | 106400 | ~0.7% |
| DSPs | 0 | 220 | 0.0% |


## 7. Flujo de uso tipico (ejemplo: cargar pesos para DPU)

```
   Tiempo -->

   ctrl_load  __|^^^^|___________________________________
   ctrl_drain __________________|^^^^|___________________
   ctrl_stop  ___________________________________________|
   ctrl_state   IDLE  | LOAD |  IDLE | DRAIN |   IDLE

   s_axis      -------[W0 W1 W2 ... WN-1 tlast]--------
   s_tready    _______|^^^^^^^^^^^^^^^^^^^^^^^^^^^^|_____
   s_tvalid    _______|^^^^^^^^^^^^^^^^^^^^^^^^^^^^|_____

   m_axis      --------------------------[W0 W1 ... WN-1 tlast]--
   m_tvalid    __________________________|^^^^^^^^^^^^^^^^^^^^^^^^^|
   m_tready    __________________________|^^^^^^^^^^^^^^^^^^^^^^^^^|
```

Secuencia:
1. Pulsar `ctrl_load`. Estado pasa a S_LOAD.
2. El productor (DMA, PS, etc.) envia N palabras por s_axis. La ultima
   lleva `tlast='1'`.
3. Al aceptar tlast, el modulo vuelve a S_IDLE automaticamente.
4. Pulsar `ctrl_drain`. Estado pasa a S_DRAIN.
5. El consumidor (DPU) recibe las N palabras por m_axis a 1 word/ciclo.
   La ultima lleva `tlast='1'`.
6. Al emitir tlast, vuelve a S_IDLE. Listo para otra carga.

Parada de emergencia: `ctrl_stop='1'` en cualquier momento congela
todo el trafico. Al soltar, vuelve a S_IDLE.


## 8. Verificaciones realizadas

| Test | Resultado |
|---|---|
| Synth `bram_ctrl_fifo` | **80 RAMB36E1**, 0 errors, 0 critical warnings |
| Sim stress: 28 beats bursty (1+2+4+1+20 con gaps variados) | **PASS** |
| Sim: drain con backpressure (tready 2on/1off) | **PASS**, 0 data loss |
| Sim: S_STOP mid-drain (10 ciclos parado) | **0 beats leaked** |
| Sim: drain resume post-stop | **PASS**, completados los 17 beats restantes |
| Sim: tlast propagation (entrada y salida) | **OK** en ambas direcciones |
| Sim total: 1605 ns, 0 errores | **PASS** |
