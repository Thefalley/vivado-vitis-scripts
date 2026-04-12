# Layer Controller -- Especificacion de Diseno

> **Fecha:** 2026-04-11
> **Proyecto:** P_14_conv_dma
> **Target:** xc7z020 (ZedBoard)
> **Objetivo:** Orquestar la ejecucion layer-by-layer de YOLOv4 INT8 usando
> las primitivas verificadas (conv_engine_v2, maxpool_unit, leaky_relu, elem_add)
> con DMA hacia DDR3 via PS HP0.

---

## 0. Principios de diseno

1. **KISS:** empezar con un controller que ejecute 1 sola capa CONV
   controlada por ARM, luego expandir.
2. **ARM configura, PL ejecuta:** ARM escribe registros, pulsa RUN,
   espera DONE (poll o IRQ). El controller hace TODO el trabajo.
3. **Reuso de primitivas existentes:** conv_engine_v2, maxpool_unit,
   leaky_relu y elem_add se instancian tal cual, sin modificar sus fuentes.
4. **Sin modificar los DMAs de Xilinx:** usamos AXI DMA IP en modo
   Simple Transfer (sin Scatter-Gather), controlado por el layer_controller
   escribiendo sus registros via AXI-Lite.

---

## 1. Diagrama de bloques

```
  PS ARM (AXI GP0)
    |
    | AXI-Lite (32-bit, slave)
    v
+-----------------------------------------------------------+
|                    layer_controller                        |
|                                                           |
|  +------------------+   +-----------+   +-------------+   |
|  | AXI-Lite slave   |-->| Reg file  |-->| Main FSM    |   |
|  | (S_AXI_*)        |   | (config)  |   |             |   |
|  +------------------+   +-----------+   +------+------+   |
|                                                |          |
|  ..............................................|.......   |
|  :  Data path (mux/demux segun layer_type)     v      :   |
|  :                                                    :   |
|  :  +-----------+  +----------+  +---------+          :   |
|  :  | conv_     |  | leaky_   |  | maxpool |          :   |
|  :  | engine_v2 |  | relu     |  | _unit   |          :   |
|  :  +-----------+  +----------+  +---------+          :   |
|  :                                                    :   |
|  :  +-----------+                                     :   |
|  :  | elem_add  |                                     :   |
|  :  +-----------+                                     :   |
|  :........................................................:   |
|                                                           |
|  +------------------+   +------------------+              |
|  | DMA ctrl: MM2S   |   | DMA ctrl: S2MM   |              |
|  | (weight + input) |   | (output)          |              |
|  +--------+---------+   +--------+---------+              |
+-----------|------------------------|-----------------------+
            |                        |
            v                        v
     +-----------+            +-----------+
     | AXI DMA   |            | AXI DMA   |
     | (Xilinx)  |            | (Xilinx)  |
     +-----+-----+            +-----+-----+
           |  AXI MM (HP0)          |
           v                        v
     +--------------------------------------+
     |              DDR3 (512 MB)            |
     +--------------------------------------+

  BRAM buffers (internos al datapath):
    x_buf:  input tile    (parametrizable, ~8-64 KB)
    w_buf:  weight tile   (32 KB, ping-pong futuro)
    y_buf:  output tile   (parametrizable, ~8-64 KB)
    b_buf:  bias          (128 B por oc_tile)
```

---

## 2. Interface del layer_controller (puertos VHDL)

### 2.1 Reloj y reset

| Puerto   | Dir | Ancho | Descripcion                      |
|----------|-----|-------|----------------------------------|
| clk      | in  | 1     | Reloj de sistema (100 MHz)       |
| rst_n    | in  | 1     | Reset activo bajo, sincrono      |

### 2.2 AXI-Lite slave (configuracion desde ARM)

Puerto standard AXI4-Lite de 32 bits de datos, 6+ bits de address.
Se implementa como un modulo `axi_lite_regs` separado que expone
los registros como senales planas al FSM principal.

| Puerto         | Dir | Ancho | Descripcion                   |
|----------------|-----|-------|-------------------------------|
| s_axi_aclk     | in  | 1     | (= clk)                      |
| s_axi_aresetn   | in  | 1     | (= rst_n)                    |
| s_axi_awaddr    | in  | 8     | Write address                 |
| s_axi_awvalid   | in  | 1     |                               |
| s_axi_awready   | out | 1     |                               |
| s_axi_wdata     | in  | 32    | Write data                    |
| s_axi_wstrb     | in  | 4     | Byte strobes                  |
| s_axi_wvalid    | in  | 1     |                               |
| s_axi_wready    | out | 1     |                               |
| s_axi_bresp     | out | 2     | Write response                |
| s_axi_bvalid    | out | 1     |                               |
| s_axi_bready    | in  | 1     |                               |
| s_axi_araddr    | in  | 8     | Read address                  |
| s_axi_arvalid   | in  | 1     |                               |
| s_axi_arready   | out | 1     |                               |
| s_axi_rdata     | out | 32    | Read data                     |
| s_axi_rresp     | out | 2     | Read response                 |
| s_axi_rvalid    | out | 1     |                               |
| s_axi_rready    | in  | 1     |                               |

### 2.3 Puertos hacia conv_engine_v2

El layer_controller instancia `conv_engine_v2` directamente. Las senales
de configuracion se conectan desde el register file; los puertos DDR
se rutenan hacia los BRAMs locales (x_buf, w_buf, y_buf) a traves de
un mux controlado por el FSM.

```
conv_engine_v2 ports (resumen):
  cfg_c_in, cfg_c_out       : unsigned(9 downto 0)
  cfg_h_in, cfg_w_in        : unsigned(9 downto 0)
  cfg_ksize                 : unsigned(1 downto 0)   -- 1 o 3
  cfg_stride                : std_logic              -- '0'=1, '1'=2
  cfg_pad                   : std_logic
  cfg_x_zp                  : signed(8 downto 0)
  cfg_w_zp                  : signed(7 downto 0)
  cfg_M0                    : unsigned(31 downto 0)
  cfg_n_shift               : unsigned(5 downto 0)
  cfg_y_zp                  : signed(7 downto 0)
  cfg_addr_input            : unsigned(24 downto 0)  -- base en buf local
  cfg_addr_weights          : unsigned(24 downto 0)  -- base en buf local
  cfg_addr_bias             : unsigned(24 downto 0)  -- base en buf local
  cfg_addr_output           : unsigned(24 downto 0)  -- base en buf local
  cfg_ic_tile_size          : unsigned(9 downto 0)
  start, done, busy         : control
  ddr_rd_addr/data/en       : lectura a BRAM local (NO DDR directo)
  ddr_wr_addr/data/en       : escritura a BRAM local
```

**Nota critica:** Los puertos `ddr_rd_*` y `ddr_wr_*` del conv_engine NO
van a DDR. Van a los BRAMs locales (x_buf, w_buf, b_buf para lectura;
y_buf para escritura). El conv_engine "cree" que habla con DDR pero
realmente habla con BRAM rapida. El DMA llena/drena esos BRAMs
antes/despues.

### 2.4 Puertos hacia las otras primitivas

Estas primitivas se instancian internamente. El FSM las alimenta
leyendo datos de x_buf (y opcionalmente de un segundo buffer para
elem_add) y escribiendo resultados a y_buf.

**maxpool_unit:**
```
  x_in      : signed(7 downto 0)   -- dato de x_buf
  valid_in  : std_logic
  clear     : std_logic             -- reset a -128 al inicio de ventana
  max_out   : signed(7 downto 0)   -- resultado
  valid_out : std_logic
```

**leaky_relu:**
```
  x_in      : signed(7 downto 0)   -- dato de x_buf
  valid_in  : std_logic
  x_zp, y_zp         : signed(7 downto 0)
  M0_pos, M0_neg     : unsigned(31 downto 0)
  n_pos, n_neg        : unsigned(5 downto 0)
  y_out     : signed(7 downto 0)   -- resultado
  valid_out : std_logic
```

**elem_add:**
```
  a_in, b_in : signed(7 downto 0)  -- dos datos de x_buf (offsets distintos)
  valid_in   : std_logic
  a_zp, b_zp, y_zp   : signed(7 downto 0)
  M0_a, M0_b         : unsigned(31 downto 0)
  n_shift             : unsigned(5 downto 0)
  y_out      : signed(7 downto 0)  -- resultado
  valid_out  : std_logic
```

### 2.5 Puertos de control DMA

El layer_controller no tiene puertos AXI-MM propios. Controla los
AXI DMA de Xilinx escribiendo sus registros de control via un
puerto AXI-Lite master dedicado (o alternativamente, via senales
directas al DMA si se hace custom).

**Opcion elegida (simplest):** El layer_controller tiene un puerto
AXI-Lite MASTER pequeno que se conecta al register space de los DMAs:

| Puerto          | Dir | Ancho | Descripcion                       |
|-----------------|-----|-------|-----------------------------------|
| m_axi_awaddr    | out | 32    | Address del registro DMA a escribir |
| m_axi_awvalid   | out | 1     |                                   |
| m_axi_awready   | in  | 1     |                                   |
| m_axi_wdata     | out | 32    | Dato a escribir                   |
| m_axi_wvalid    | out | 1     |                                   |
| m_axi_wready    | in  | 1     |                                   |
| m_axi_bresp     | in  | 2     |                                   |
| m_axi_bvalid    | in  | 1     |                                   |
| m_axi_bready    | out | 1     |                                   |
| m_axi_araddr    | out | 32    | Address del registro DMA a leer   |
| m_axi_arvalid   | out | 1     |                                   |
| m_axi_arready   | in  | 1     |                                   |
| m_axi_rdata     | in  | 32    | Dato leido                        |
| m_axi_rvalid    | in  | 1     |                                   |
| m_axi_rready    | out | 1     |                                   |

**Alternativa mas simple para Paso 1:** en vez de AXI-Lite master, usar
senales directas al AXI-Stream del DMA. El DMA tiene puertos S2MM y MM2S
como AXI-Stream. El layer_controller solo necesita:

| Puerto          | Dir  | Ancho | Descripcion                      |
|-----------------|------|-------|----------------------------------|
| dma_mm2s_tdata  | in   | 32    | Datos que llegan del DMA (DDR->PL) |
| dma_mm2s_tvalid | in   | 1     |                                  |
| dma_mm2s_tready | out  | 1     |                                  |
| dma_mm2s_tlast  | in   | 1     |                                  |
| dma_s2mm_tdata  | out  | 32    | Datos hacia el DMA (PL->DDR)     |
| dma_s2mm_tvalid | out  | 1     |                                  |
| dma_s2mm_tready | in   | 1     |                                  |
| dma_s2mm_tlast  | out  | 1     |                                  |

En esta variante, el ARM programa los DMAs (source addr, dest addr, length)
y luego pulsa RUN en el layer_controller. Los datos fluyen via AXI-Stream.
**Esta es la opcion recomendada para el Paso 1** -- es mas simple y no
requiere que el PL sea master de AXI-Lite.

### 2.6 Puerto de interrupcion (opcional)

| Puerto   | Dir | Ancho | Descripcion                          |
|----------|-----|-------|--------------------------------------|
| irq      | out | 1     | Pulso de 1 ciclo cuando layer termina |

---

## 3. Mapa de registros AXI-Lite

8 bits de address -> 64 registros de 32 bits (suficiente para todo).
Los registros se agrupan por funcion.

### 3.1 Control y status (0x00 - 0x0C)

| Offset | Nombre      | R/W | Bits | Descripcion                              |
|--------|-------------|-----|------|------------------------------------------|
| 0x00   | CTRL        | W   | [0]  | RUN: escribir '1' para arrancar          |
|        |             |     | [1]  | STOP: escribir '1' para abortar (futuro) |
|        |             |     | [31:8] | Reservado                              |
| 0x04   | STATUS      | R   | [0]  | BUSY: '1' mientras ejecuta               |
|        |             |     | [1]  | DONE: '1' cuando termina (clear on read) |
|        |             |     | [2]  | ERROR: '1' si ocurrio un error           |
|        |             |     | [7:4] | FSM state (debug)                       |
|        |             |     | [31:8] | Reservado                              |
| 0x08   | LAYER_TYPE  | W   | [3:0]| Tipo de layer (ver tabla 3.2)            |
|        |             |     | [31:4] | Reservado                              |
| 0x0C   | LAYER_COUNT | W   | [7:0]| Numero total de pixels a procesar        |
|        |             |     |      | (para maxpool/relu/add: H*W*C /4)        |

### 3.2 Codigos de LAYER_TYPE

| Codigo | Nombre       | Primitiva usada        |
|--------|--------------|------------------------|
| 0x0    | CONV_3x3     | conv_engine_v2 (k=3)   |
| 0x1    | CONV_1x1     | conv_engine_v2 (k=1)   |
| 0x2    | MAXPOOL_2x2  | maxpool_unit           |
| 0x3    | LEAKY_RELU   | leaky_relu             |
| 0x4    | ELEM_ADD     | elem_add               |
| 0x5    | CONCAT       | solo address gen       |
| 0x6    | UPSAMPLE_2X  | solo address gen       |
| 0x7-0xF| Reservado    |                        |

### 3.3 Configuracion CONV (0x10 - 0x3C)

| Offset | Nombre         | R/W | Bits     | Descripcion                         |
|--------|----------------|-----|----------|-------------------------------------|
| 0x10   | CONV_C_IN      | W   | [9:0]   | Canales de entrada (1..1024)        |
| 0x14   | CONV_C_OUT     | W   | [9:0]   | Canales de salida (1..1024)         |
| 0x18   | CONV_H_IN      | W   | [9:0]   | Altura de entrada                   |
| 0x1C   | CONV_W_IN      | W   | [9:0]   | Anchura de entrada                  |
| 0x20   | CONV_PARAMS    | W   | [1:0]   | ksize (1 o 3)                       |
|        |                |     | [2]     | stride ('0'=1, '1'=2)              |
|        |                |     | [3]     | pad ('0'=no, '1'=si)               |
| 0x24   | CONV_X_ZP      | W   | [8:0]   | Zero point de activaciones (signed) |
| 0x28   | CONV_W_ZP      | W   | [7:0]   | Zero point de pesos (signed)        |
| 0x2C   | CONV_M0        | W   | [31:0]  | Multiplicador de requantize         |
| 0x30   | CONV_N_SHIFT   | W   | [5:0]   | Shift de requantize                 |
| 0x34   | CONV_Y_ZP      | W   | [7:0]   | Zero point de salida (signed)       |
| 0x38   | CONV_IC_TILE   | W   | [9:0]   | Tamano del ic_tile (configurable)   |
| 0x3C   | (reservado)    |     |         |                                     |

### 3.4 Configuracion LEAKY_RELU (0x40 - 0x58)

| Offset | Nombre       | R/W | Bits     | Descripcion                          |
|--------|--------------|-----|----------|--------------------------------------|
| 0x40   | LR_X_ZP      | W   | [7:0]   | Zero point de entrada (signed)       |
| 0x44   | LR_Y_ZP      | W   | [7:0]   | Zero point de salida (signed)        |
| 0x48   | LR_M0_POS    | W   | [31:0]  | Multiplicador rama positiva          |
| 0x4C   | LR_N_POS     | W   | [5:0]   | Shift rama positiva                  |
| 0x50   | LR_M0_NEG    | W   | [31:0]  | Multiplicador rama negativa          |
| 0x54   | LR_N_NEG     | W   | [5:0]   | Shift rama negativa                  |
| 0x58   | LR_COUNT     | W   | [19:0]  | Numero total de elementos (H*W*C)    |

### 3.5 Configuracion ELEM_ADD (0x60 - 0x7C)

| Offset | Nombre       | R/W | Bits     | Descripcion                          |
|--------|--------------|-----|----------|--------------------------------------|
| 0x60   | EA_A_ZP      | W   | [7:0]   | Zero point de entrada A (signed)     |
| 0x64   | EA_B_ZP      | W   | [7:0]   | Zero point de entrada B (signed)     |
| 0x68   | EA_Y_ZP      | W   | [7:0]   | Zero point de salida (signed)        |
| 0x6C   | EA_M0_A      | W   | [31:0]  | Multiplicador de A                   |
| 0x70   | EA_M0_B      | W   | [31:0]  | Multiplicador de B                   |
| 0x74   | EA_N_SHIFT   | W   | [5:0]   | Shift comun                          |
| 0x78   | EA_COUNT     | W   | [19:0]  | Numero total de elementos (H*W*C)    |

### 3.6 Configuracion MAXPOOL (0x80 - 0x8C)

| Offset | Nombre       | R/W | Bits     | Descripcion                          |
|--------|--------------|-----|----------|--------------------------------------|
| 0x80   | MP_H_IN      | W   | [9:0]   | Altura de entrada                    |
| 0x84   | MP_W_IN      | W   | [9:0]   | Anchura de entrada                   |
| 0x88   | MP_C         | W   | [9:0]   | Canales                              |
| 0x8C   | (reservado)  |     |         |                                      |

### 3.7 Direcciones DDR (0x90 - 0xA4)

| Offset | Nombre       | R/W | Bits     | Descripcion                          |
|--------|--------------|-----|----------|--------------------------------------|
| 0x90   | ADDR_INPUT   | W   | [31:0]  | Direccion DDR del input              |
| 0x94   | ADDR_WEIGHTS | W   | [31:0]  | Direccion DDR de los pesos           |
| 0x98   | ADDR_BIAS    | W   | [31:0]  | Direccion DDR del bias               |
| 0x9C   | ADDR_OUTPUT  | W   | [31:0]  | Direccion DDR del output             |
| 0xA0   | ADDR_INPUT_B | W   | [31:0]  | DDR de segunda entrada (elem_add)    |
| 0xA4   | XFER_LEN_IN  | W   | [23:0]  | Bytes a transferir input (DMA len)   |
| 0xA8   | XFER_LEN_WT  | W   | [23:0]  | Bytes a transferir weights (DMA len) |
| 0xAC   | XFER_LEN_OUT | W   | [23:0]  | Bytes a transferir output (DMA len)  |

### 3.8 Configuracion UPSAMPLE / CONCAT (0xB0 - 0xBC, futuro)

| Offset | Nombre       | R/W | Bits     | Descripcion                          |
|--------|--------------|-----|----------|--------------------------------------|
| 0xB0   | UP_H_IN      | W   | [9:0]   | Altura entrada (upsample)            |
| 0xB4   | UP_W_IN      | W   | [9:0]   | Anchura entrada (upsample)           |
| 0xB8   | UP_C         | W   | [9:0]   | Canales (upsample/concat)            |
| 0xBC   | CAT_OFFSET   | W   | [23:0]  | Offset de canal para concat          |

---

## 4. FSM principal del layer_controller

### 4.1 Diagrama de estados (Paso 1: solo CONV con ARM controlando DMAs)

En el Paso 1, el ARM programa los DMAs directamente y el layer_controller
solo orquesta la ejecucion del engine con datos que ya estan en BRAM.

```
                     +------+
                     | IDLE |<-----------------------------------+
                     +--+---+                                    |
                        | ARM escribe registros + pulsa RUN      |
                        v                                        |
                  +------------+                                 |
                  | LOAD_CONFIG|  Copia registros AXI-Lite a     |
                  | (1 ciclo)  |  senales internas del engine    |
                  +-----+------+                                 |
                        |                                        |
                        v                                        |
                  +------------+                                 |
                  | WAIT_DMA_IN|  Espera que ARM haya completado |
                  |            |  las transferencias DMA de      |
                  |            |  weights + input a BRAM         |
                  +-----+------+  (ARM senaliza via reg 0x00)   |
                        |                                        |
                        v                                        |
                  +------------+                                 |
                  | RUN_ENGINE |  Segun LAYER_TYPE:               |
                  |            |  - CONV: start conv_engine_v2   |
                  |            |  - MAXPOOL: FSM de maxpool loop |
                  |            |  - RELU: FSM de relu stream     |
                  |            |  - ADD: FSM de add stream       |
                  +-----+------+                                 |
                        |                                        |
                        v                                        |
                  +------------+                                 |
                  | WAIT_ENGINE|  Espera done del engine activo   |
                  +-----+------+                                 |
                        |                                        |
                        v                                        |
                  +-----+------+                                 |
                  |    DONE    |  STATUS.DONE = '1'              |
                  |            |  irq = '1' (pulso)              |
                  +-----+------+                                 |
                        |                                        |
                        +----------------------------------------+
                          ARM lee STATUS, limpia DONE
```

### 4.2 FSM completa (Paso 2+: controller maneja DMAs)

```
                     +------+
                     | IDLE |<-------------------------------------+
                     +--+---+                                      |
                        | RUN                                      |
                        v                                          |
                  +------------+                                   |
                  | LOAD_CONFIG|                                   |
                  +-----+------+                                   |
                        |                                          |
                        v                                          |
                  +-------------+                                  |
                  | LOAD_WEIGHTS|  Programa DMA MM2S:              |
                  |             |  src = ADDR_WEIGHTS              |
                  |             |  dst = w_buf base                |
                  |             |  len = XFER_LEN_WT              |
                  +------+------+                                  |
                         |                                         |
                         v                                         |
                  +-------------+                                  |
                  | WAIT_WT_DMA |  Poll DMA status register        |
                  +------+------+  hasta transfer complete         |
                         |                                         |
                         v                                         |
                  +------------+                                   |
                  | LOAD_INPUT |  Programa DMA MM2S:               |
                  |            |  src = ADDR_INPUT                 |
                  |            |  dst = x_buf base                 |
                  |            |  len = XFER_LEN_IN               |
                  +-----+------+                                   |
                        |                                          |
                        v                                          |
                  +-------------+                                  |
                  | WAIT_IN_DMA |                                  |
                  +------+------+                                  |
                         |                                         |
                         v                                         |
                  +------------+                                   |
                  | RUN_ENGINE |                                   |
                  +-----+------+                                   |
                        |                                          |
                        v                                          |
                  +-------------+                                  |
                  | WAIT_ENGINE |                                  |
                  +------+------+                                  |
                         |                                         |
                         v                                         |
                  +--------------+                                 |
                  | STORE_OUTPUT |  Programa DMA S2MM:             |
                  |              |  src = y_buf base               |
                  |              |  dst = ADDR_OUTPUT              |
                  |              |  len = XFER_LEN_OUT            |
                  +------+-------+                                 |
                         |                                         |
                         v                                         |
                  +--------------+                                 |
                  | WAIT_OUT_DMA |                                 |
                  +------+-------+                                 |
                         |                                         |
                         v                                         |
                  +------+------+                                  |
                  |    DONE     |                                  |
                  +------+------+                                  |
                         |                                         |
                         +-----------------------------------------+
```

### 4.3 Detalle de cada estado

**IDLE:**
- `STATUS.BUSY = '0'`, `STATUS.DONE` refleja resultado anterior.
- Espera que ARM escriba `CTRL.RUN = '1'`.
- Al detectar RUN: captura todos los registros de config en flip-flops
  internos (snapshot) y transiciona a LOAD_CONFIG.

**LOAD_CONFIG:**
- 1 ciclo. Conecta los registros capturados a las senales cfg_* del
  engine seleccionado por LAYER_TYPE.
- Para CONV: cfg_c_in, cfg_c_out, cfg_h_in, cfg_w_in, etc.
  Las direcciones cfg_addr_* se setean a 0 (base del BRAM local).
- Para LEAKY_RELU: conecta x_zp, y_zp, M0_pos/neg, n_pos/neg.
- Para MAXPOOL: h_in, w_in, c.
- Para ELEM_ADD: a_zp, b_zp, y_zp, M0_a, M0_b, n_shift.
- Transiciona a LOAD_WEIGHTS (si CONV) o LOAD_INPUT (si otros).

**LOAD_WEIGHTS (solo CONV):**
- Inicia transferencia DMA: escribe source address (ADDR_WEIGHTS) y
  length (XFER_LEN_WT) en los registros del DMA MM2S.
- El DMA lee de DDR y escribe en w_buf via AXI-Stream.
- Transiciona a WAIT_WT_DMA.

**WAIT_WT_DMA:**
- Lee el registro de status del DMA. Espera hasta que bit IOC
  (transfer complete) este activo.
- Transiciona a LOAD_INPUT cuando complete.

**LOAD_INPUT:**
- Inicia transferencia DMA para cargar el input tile.
- Para CONV: carga activaciones en x_buf.
- Para ELEM_ADD: carga ambas entradas (A en x_buf, B en la segunda
  mitad de x_buf o en un buffer separado). Se pueden hacer 2 DMA
  transfers secuenciales.
- Para MAXPOOL/RELU: carga datos en x_buf.
- Transiciona a WAIT_IN_DMA.

**WAIT_IN_DMA:**
- Igual que WAIT_WT_DMA pero para el DMA de input.
- Transiciona a RUN_ENGINE.

**RUN_ENGINE:**
- Segun LAYER_TYPE:
  - **CONV_3x3 / CONV_1x1:** Pulsa `start` del conv_engine_v2.
    El engine lee de x_buf y w_buf, escribe resultado en y_buf.
    Transiciona a WAIT_ENGINE.
  - **MAXPOOL_2x2:** Activa sub-FSM de maxpool. Lee pixeles de x_buf
    en el orden correcto (ventana 2x2 con stride 2), alimenta
    maxpool_unit (clear + 4 values + capture), escribe resultado
    en y_buf. El sub-FSM genera las direcciones y el sequencing.
  - **LEAKY_RELU:** Activa sub-FSM de relu. Lee pixel de x_buf,
    alimenta leaky_relu, espera 8 ciclos de pipeline, escribe
    resultado en y_buf. Pipeline: el throughput es 1 por ciclo
    una vez lleno.
  - **ELEM_ADD:** Activa sub-FSM de add. Lee A de x_buf[0..N-1],
    B de x_buf[N..2N-1], alimenta elem_add, escribe resultado
    en y_buf. Pipeline de 8 ciclos, throughput 1/ciclo.
- Transiciona a WAIT_ENGINE.

**WAIT_ENGINE:**
- Para CONV: espera `done = '1'` del conv_engine_v2.
- Para otros: espera que el sub-FSM correspondiente termine
  (todos los pixeles procesados).
- Transiciona a STORE_OUTPUT.

**STORE_OUTPUT:**
- Inicia transferencia DMA S2MM para drenar y_buf a DDR.
- Source: y_buf (via AXI-Stream desde PL).
- Dest: ADDR_OUTPUT en DDR.
- Length: XFER_LEN_OUT.
- Transiciona a WAIT_OUT_DMA.

**WAIT_OUT_DMA:**
- Espera transfer complete del DMA S2MM.
- Transiciona a DONE.

**DONE:**
- `STATUS.DONE = '1'`, `STATUS.BUSY = '0'`.
- Genera pulso de 1 ciclo en `irq`.
- Permanece en DONE hasta que ARM lea STATUS (clear-on-read de DONE)
  o hasta un nuevo RUN.

---

## 5. Sub-FSMs para primitivas simples

### 5.1 Sub-FSM MAXPOOL

MaxPool 2x2 con stride 2. Para cada pixel de salida (oh, ow, oc):

```
Para oc = 0 .. C-1:
  Para oh = 0 .. H_out-1:        (H_out = H_in / 2)
    Para ow = 0 .. W_out-1:      (W_out = W_in / 2)
      clear maxpool_unit
      Para dy = 0, 1:
        Para dx = 0, 1:
          ih = oh*2 + dy
          iw = ow*2 + dx
          addr = oc * H_in * W_in + ih * W_in + iw
          read x_buf[addr], feed to maxpool_unit
      capture max_out, write to y_buf[oc * H_out * W_out + oh * W_out + ow]
```

Latencia: 6 ciclos por pixel de salida (clear + 4 reads + 1 write).
Total: C * H_out * W_out * 6 ciclos.

**Layout en memoria:** Se asume NCHW para las activaciones en BRAM, que es
lo mismo que usa el conv_engine. El oc itera como loop externo para
mantener localidad.

### 5.2 Sub-FSM LEAKY_RELU

```
addr_rd = 0
addr_wr = 0
count = LR_COUNT (= H * W * C)
pipeline_fill = 8

Para i = 0 .. count-1:
  read x_buf[addr_rd++], feed x_in, valid_in='1'

// Despues de 8 ciclos, empiezan a salir resultados:
Cuando valid_out = '1':
  write y_buf[addr_wr++] = y_out
```

Throughput: 1 resultado/ciclo despues de 8 ciclos de llenado.
Total: count + 8 ciclos.

### 5.3 Sub-FSM ELEM_ADD

```
addr_a = 0                      (input A en x_buf[0..N-1])
addr_b = EA_COUNT               (input B en x_buf[N..2N-1])
addr_wr = 0
count = EA_COUNT

Para i = 0 .. count-1:
  read x_buf[addr_a++] -> a_in
  read x_buf[addr_b++] -> b_in (puerto B del BRAM, o ciclo alterno)
  valid_in = '1'

Cuando valid_out = '1':
  write y_buf[addr_wr++] = y_out
```

**Nota:** elem_add necesita leer dos valores por ciclo. Dos opciones:
1. BRAM true-dual-port: read A por puerto A, read B por puerto B.
   Throughput: 1/ciclo.
2. Dos ciclos por dato: read A, read B, fire. Throughput: 1/2 ciclo.
   (Mas simple, acceptable dado que elem_add NO es el cuello de botella.)

**Decision:** Opcion 2 para Paso 1 (simpler). Opcion 1 como optimizacion.

### 5.4 Sub-FSM CONCAT (futuro)

Concat no es una operacion de datos -- es una operacion de direcciones.
El controller simplemente configura dos capas previas para que escriban
sus outputs en regiones contiguas del mismo y_buf:

- Capa A escribe en ADDR_OUTPUT + 0
- Capa B escribe en ADDR_OUTPUT + (C_A * H * W)

No requiere hardware dedicado ni sub-FSM.

### 5.5 Sub-FSM UPSAMPLE 2x (futuro)

Nearest-neighbor upsample: cada pixel de entrada se replica 2x2.

```
Para oc = 0 .. C-1:
  Para oh = 0 .. H_out-1:       (H_out = H_in * 2)
    Para ow = 0 .. W_out-1:     (W_out = W_in * 2)
      ih = oh / 2
      iw = ow / 2
      addr_rd = oc * H_in * W_in + ih * W_in + iw
      addr_wr = oc * H_out * W_out + oh * W_out + ow
      y_buf[addr_wr] = x_buf[addr_rd]
```

Pura copia con generacion de direcciones distinta. 1 ciclo por pixel
de salida. Total: C * H_out * W_out ciclos.

---

## 6. Tiling strategy

### 6.1 Tiling del conv_engine_v2 (ya implementado)

El conv_engine_v2 ya soporta tiling en dos dimensiones:

- **oc_tile:** fijo a 32 (= N_MAC). El engine procesa 32 output channels
  en paralelo. Si c_out > 32, itera oc_tile_base.
- **ic_tile:** configurable via cfg_ic_tile_size. Limita cuantos input
  channels caben en w_buf por pasada. El engine itera ic_tile_base.

Restriccion: `ic_tile_size * kh * kw * 32 <= WB_SIZE (32768 bytes)`.
Para k=3: ic_tile_size <= 113. Para k=1: ic_tile_size <= 1024.

### 6.2 Spatial tiling (para input grandes)

Cuando el input tile (H_in * W_in * C_in bytes) no cabe en x_buf:

```
Buffer size = X_BUF_SIZE bytes
Tile height H_TILE = floor(X_BUF_SIZE / (W_in * C_in))
// Ajustar para que H_TILE sea multiplo de stride y permita overlap del kernel

Para cada h_tile_base = 0, H_TILE-overlap, 2*(H_TILE-overlap), ...:
  h_start = max(0, h_tile_base - pad)
  h_end   = min(H_in, h_tile_base + H_TILE + pad)
  DMA load x[h_start:h_end][0:W_in][0:C_in] -> x_buf
  Configurar conv_engine con h_in = h_end - h_start, cfg_pad ajustado
  Ejecutar conv_engine
  DMA store y -> DDR en la region correspondiente
```

**Overlap:** Para conv 3x3 con pad=1, cada tile necesita 1 fila de
contexto arriba y 1 abajo (excepto bordes). El overlap es k-1 = 2 filas.

**Para Paso 1:** no implementar spatial tiling. Limitar a capas cuyo
input quepa en x_buf. Esto funciona para las primeras capas de YOLOv4
(imagen 416x416 con pocos canales = 416*416*3 = 519 KB... no cabe en
x_buf tipico). **Solucion:** procesar por canales, no por spatial.
O aumentar x_buf. Ver seccion 7 para el analisis de BRAM.

**Realidad practica para ZedBoard:** Las capas tempranas tienen
spatial grande pero pocos canales. Las tardias tienen spatial pequeno
pero muchos canales. Para las tempranas, el ARM tendra que trocear
el input en tiles espaciales y ejecutar el layer_controller multiples
veces con offsets distintos. Esto es acceptable para Paso 1.

### 6.3 Overlap de carga (ping-pong, futuro Paso 4)

En el futuro, con dos bancos de w_buf:

```
w_buf_ping: pesos del tile actual (engine los consume)
w_buf_pong: DMA cargando pesos del siguiente tile

Cuando engine termina tile N:
  swap(ping, pong)
  engine arranca tile N+1 (consume el ex-pong)
  DMA arranca carga de tile N+2 en el ex-ping
```

Esto oculta la latencia DDR del DMA de pesos. Requisito: duplicar
w_buf (32 KB -> 64 KB = 36 BRAM18 adicionales).

---

## 7. Resource estimate

### 7.1 BRAM

| Buffer      | Tamano propuesto | BRAM18 | BRAM36 | Notas                    |
|-------------|------------------|--------|--------|--------------------------|
| x_buf       | 32 KB            | 18     | 9      | 1 tile de activaciones   |
| y_buf       | 32 KB            | 18     | 9      | 1 tile de output         |
| w_buf       | 32 KB            | 18     | 9      | Pesos (1 banco)          |
| b_buf       | 128 B            | 1      | 0.5    | 32 biases x 4 bytes     |
| **Total**   | **~96 KB**       | **55** | **28** |                          |

Con ping-pong de pesos (futuro): w_buf_pong = +32 KB = +18 BRAM18 = +9 BRAM36.
Total con ping-pong: ~128 KB, 37 BRAM36.

**Presupuesto total en xc7z020:**
- 140 BRAM36 disponibles
- 28 BRAM36 para buffers (sin ping-pong)
- ~8 BRAM36 para conv_engine internals (weight_buf interno)
- ~2 BRAM36 para DMA FIFOs (Xilinx DMA IP)
- Total: ~38 BRAM36 (27% del chip). **Viable con margen.**

**Nota sobre x_buf de 32 KB:** Con 32 KB, el tile de activaciones
soporta hasta 32768 / C_in bytes. Para C_in=3 (primera capa):
32768/3 = 10922 pixeles = ~104x104 pixeles. La imagen de 416x416x3
(519 KB) no cabe, pero un tile de 104x416x3 (130 KB) tampoco cabe en
32 KB. **Solucion:** Para la primera capa, el ARM trocea la imagen
en strips de ~26 filas (26*416*3 = 32 KB) y ejecuta el controller
una vez por strip. Para capas intermedias con C_in=64: 32768/64 = 512
pixeles = ~22x22, que cubre un feature map de 52x52 parcialmente
(necesita ~4 tiles). Es manejable.

**Si se quiere mas holgura:** aumentar x_buf y y_buf a 64 KB cada uno
(+18 BRAM36 = total 56 BRAM36, 40% del chip). Sigue viable.

### 7.2 DSP48E1

| Componente     | DSPs | Notas                              |
|----------------|------|------------------------------------|
| mac_array      | 32   | 32 MACs en paralelo (dentro del conv_engine) |
| requantize     | 4    | Dentro del conv_engine             |
| leaky_relu     | 4    | 2 x mul_s9xu30_pipe                |
| elem_add       | 4    | 2 x mul_s9xu30_pipe                |
| maxpool_unit   | 0    | Solo comparacion                   |
| layer_ctrl FSM | 0    | Sin multiplicaciones               |
| **Total**      | **44** | De 220 disponibles (20%)         |

### 7.3 LUTs y FFs

| Componente     | LUTs (est.) | FFs (est.) | Notas                      |
|----------------|-------------|------------|----------------------------|
| conv_engine_v2 | ~4,000      | ~3,000     | FSM grande + contadores    |
| mac_array      | ~3,000      | ~4,000     | 32 acumuladores de 32 bits |
| requantize     | ~800        | ~600       | Pipeline shift+clamp       |
| leaky_relu     | ~860        | ~800       | 2 barrel shifters + muxes  |
| elem_add       | ~500        | ~600       | 1 barrel shifter + sumas   |
| maxpool_unit   | ~8          | ~9         | Trivial                    |
| layer_ctrl FSM | ~1,500      | ~1,500     | FSM + address gen + muxes  |
| AXI-Lite slave | ~500        | ~600       | Register file              |
| AXI DMA (x2)   | ~4,000      | ~4,000     | Xilinx IP (estimacion)     |
| AXI interconnect| ~3,000     | ~2,000     | Xilinx IP                  |
| xpm_memory     | ~200        | ~100       | Wrappers                   |
| **Total**      | **~18,400** | **~17,200**|                            |

De 53,200 LUTs disponibles: 35% utilizado. **Viable con margen.**

### 7.4 DMAs necesarios

**Opcion recomendada: 1 AXI DMA con MM2S + S2MM.**

Justificacion:
- Con 1 DMA compartido, las transferencias de weights, input y output
  son secuenciales (nunca simultaneas en Paso 1-3).
- Ahorra BRAM (el DMA tiene FIFOs internos) y ahorra interconnect.
- Para el futuro (Paso 4, ping-pong): se puede anadir un 2do DMA
  dedicado solo para pesos, que corra en paralelo con el engine.

El DMA se configura con:
- MM2S: 32-bit data width (compatible con AXI-Stream del controller)
- S2MM: 32-bit data width
- Buffer length register: 23 bits (hasta 8 MB por transfer)
- Sin Scatter-Gather (modo Simple/Direct)

---

## 8. Flujo de datos end-to-end (ejemplo: 1 capa CONV)

```
Tiempo -->

ARM:
  1. Escribe pesos + input + bias en DDR (via memcpy o DMA previo)
  2. Escribe registros AXI-Lite del layer_controller:
     LAYER_TYPE = CONV_3x3
     CONV_C_IN = 32, CONV_C_OUT = 64, CONV_H_IN = 52, CONV_W_IN = 52
     CONV_PARAMS: ksize=3, stride=1, pad=1
     CONV_X_ZP, CONV_W_ZP, CONV_M0, CONV_N_SHIFT, CONV_Y_ZP = ...
     CONV_IC_TILE = 32
     ADDR_INPUT = 0x10000000, ADDR_WEIGHTS = 0x10100000
     ADDR_BIAS = 0x10200000, ADDR_OUTPUT = 0x10300000
     XFER_LEN_IN = 52*52*32 = 86528
     XFER_LEN_WT = 64*32*3*3 = 18432
     XFER_LEN_OUT = 52*52*64 = 173056
  3. Escribe CTRL.RUN = 1
  4. Poll STATUS.DONE o espera IRQ

Layer controller:
  IDLE -> LOAD_CONFIG -> LOAD_WEIGHTS -> WAIT_WT_DMA ->
  LOAD_INPUT -> WAIT_IN_DMA -> RUN_ENGINE -> WAIT_ENGINE ->
  STORE_OUTPUT -> WAIT_OUT_DMA -> DONE

  Tiempos estimados (100 MHz, DDR3 1066):
    LOAD_WEIGHTS: 18432 bytes / 4 bytes/ciclo = 4608 ciclos = 46 us
    LOAD_INPUT:   86528 bytes / 4 bytes/ciclo = 21632 ciclos = 216 us
    RUN_ENGINE:   ~52*52*3*3*32*2 ciclos (conservador) = ~3.1M ciclos = 31 ms
    STORE_OUTPUT: 173056 bytes / 4 bytes/ciclo = 43264 ciclos = 433 us
    Total estimado: ~32 ms por capa (dominado por compute)

ARM:
  5. Lee STATUS.DONE = 1
  6. Lee resultado de DDR en ADDR_OUTPUT
```

---

## 9. Interfaz de software (API en C bare-metal)

```c
// Direccion base del layer_controller en el memory map
#define LC_BASE     0x43C00000

// Offsets de registros
#define LC_CTRL          0x00
#define LC_STATUS        0x04
#define LC_LAYER_TYPE    0x08
#define LC_CONV_C_IN     0x10
#define LC_CONV_C_OUT    0x14
#define LC_CONV_H_IN     0x18
#define LC_CONV_W_IN     0x1C
#define LC_CONV_PARAMS   0x20
#define LC_CONV_X_ZP     0x24
#define LC_CONV_W_ZP     0x28
#define LC_CONV_M0       0x2C
#define LC_CONV_N_SHIFT  0x30
#define LC_CONV_Y_ZP     0x34
#define LC_CONV_IC_TILE  0x38
#define LC_ADDR_INPUT    0x90
#define LC_ADDR_WEIGHTS  0x94
#define LC_ADDR_BIAS     0x98
#define LC_ADDR_OUTPUT   0x9C
#define LC_XFER_LEN_IN   0xA4
#define LC_XFER_LEN_WT   0xA8
#define LC_XFER_LEN_OUT  0xAC

// Helpers
#define LC_WR(off, val)  Xil_Out32(LC_BASE + (off), (val))
#define LC_RD(off)       Xil_In32(LC_BASE + (off))

// Ejemplo: ejecutar 1 capa conv
void run_conv_layer(uint32_t c_in, uint32_t c_out,
                    uint32_t h, uint32_t w,
                    uint32_t ksize, uint32_t stride, uint32_t pad,
                    int32_t x_zp, int32_t w_zp,
                    uint32_t M0, uint32_t n_shift, int32_t y_zp,
                    uint32_t ic_tile,
                    uint32_t addr_in, uint32_t addr_wt,
                    uint32_t addr_bias, uint32_t addr_out)
{
    LC_WR(LC_LAYER_TYPE, 0x0);  // CONV_3x3 (o 0x1 para 1x1)
    LC_WR(LC_CONV_C_IN, c_in);
    LC_WR(LC_CONV_C_OUT, c_out);
    LC_WR(LC_CONV_H_IN, h);
    LC_WR(LC_CONV_W_IN, w);
    LC_WR(LC_CONV_PARAMS, (ksize & 0x3) | ((stride & 0x1) << 2)
                          | ((pad & 0x1) << 3));
    LC_WR(LC_CONV_X_ZP, (uint32_t)(x_zp & 0x1FF));
    LC_WR(LC_CONV_W_ZP, (uint32_t)(w_zp & 0xFF));
    LC_WR(LC_CONV_M0, M0);
    LC_WR(LC_CONV_N_SHIFT, n_shift);
    LC_WR(LC_CONV_Y_ZP, (uint32_t)(y_zp & 0xFF));
    LC_WR(LC_CONV_IC_TILE, ic_tile);
    LC_WR(LC_ADDR_INPUT, addr_in);
    LC_WR(LC_ADDR_WEIGHTS, addr_wt);
    LC_WR(LC_ADDR_BIAS, addr_bias);
    LC_WR(LC_ADDR_OUTPUT, addr_out);
    LC_WR(LC_XFER_LEN_IN, h * w * c_in);
    LC_WR(LC_XFER_LEN_WT, c_out * c_in * ksize * ksize);
    LC_WR(LC_XFER_LEN_OUT, /* h_out * w_out * c_out, calcular */0);

    // Arrancar
    LC_WR(LC_CTRL, 0x1);

    // Esperar
    while ((LC_RD(LC_STATUS) & 0x2) == 0)
        ;  // poll DONE bit

    // Limpiar (STATUS es clear-on-read para DONE)
}
```

---

## 10. Multi-layer execution (futuro, Paso 3+)

### 10.1 Tabla de layers en DDR

El ARM prepara un array de structs `layer_desc` en DDR:

```c
typedef struct {
    uint8_t  layer_type;       // CONV_3x3, MAXPOOL, etc.
    uint8_t  ksize;
    uint8_t  stride;
    uint8_t  pad;
    uint16_t c_in, c_out;
    uint16_t h_in, w_in;
    uint16_t ic_tile;
    int8_t   x_zp, w_zp, y_zp;
    uint32_t M0;
    uint8_t  n_shift;
    // Leaky ReLU params (if applicable)
    uint32_t M0_pos, M0_neg;
    uint8_t  n_pos, n_neg;
    // Elem add params (if applicable)
    int8_t   a_zp, b_zp;
    uint32_t M0_a, M0_b;
    uint8_t  n_shift_add;
    // Addresses
    uint32_t addr_input;
    uint32_t addr_weights;
    uint32_t addr_bias;
    uint32_t addr_output;
    uint32_t addr_input_b;     // For elem_add
    // Flags
    uint8_t  swap_buffers;     // Swap x<->y after this layer
    uint8_t  reserved[3];
} layer_desc;  // ~64 bytes, alineado
```

El ARM escribe:
1. La tabla en DDR (e.g., en 0x10000000)
2. El numero de layers en un registro
3. La direccion base de la tabla en un registro
4. Pulsa RUN

El layer_controller:
1. Lee la tabla entry por entry via DMA (64 bytes cada una)
2. Configura y ejecuta cada layer
3. Swap x_buf <-> y_buf entre layers (solo intercambia punteros internos)
4. Al terminar todas las layers: DONE

### 10.2 Buffer swapping

Despues de cada layer (excepto concat/residual), los roles de x_buf
e y_buf se intercambian:

```
layer N:   input = x_buf, output = y_buf
layer N+1: input = y_buf, output = x_buf  (y_buf del layer N es el input)
```

Implementacion: un bit `buf_select` que alterna entre layers. Los muxes
de address del datapath usan este bit para decidir que BRAM es input
y cual es output.

Esto evita tener que copiar datos de y_buf a x_buf entre layers.

### 10.3 Residual connections

Para elem_add, necesitamos dos inputs. El "residual" viene de una capa
anterior que ya fue sobrescrita en el buffer normal.

Solucion (drain-and-reload):
1. Cuando una capa produce un output que sera usado como residual mas
   tarde, el controller lo drena a DDR (STORE_OUTPUT normal).
2. Cuando llega el elem_add, el controller carga ambos inputs desde DDR:
   - Input A: el output de la capa inmediatamente anterior (ya en x_buf)
   - Input B: el residual guardado en DDR (se carga en segunda mitad de x_buf)

Esto es simple y funciona. El overhead es 1 DMA extra por residual
connection (~200 us por 100 KB de feature map).

---

## 11. Plan de implementacion incremental

### Paso 1: Controller para 1 sola capa CONV (2-3 dias)

**Alcance:**
- `layer_controller` con FSM minima: IDLE -> LOAD_CONFIG -> RUN_ENGINE -> WAIT_ENGINE -> DONE
- Solo soporta LAYER_TYPE = CONV_3x3 y CONV_1x1
- El ARM programa los DMAs directamente (el controller NO controla DMAs)
- El ARM carga weights + input en BRAM via DMA antes de pulsar RUN
- El ARM drena output de BRAM via DMA despues de DONE
- AXI-Lite slave con registros de CONV + CTRL/STATUS + ADDR_*

**Archivos a crear:**
- `src/layer_controller.vhd` (FSM + register file + conv_engine instance)
- `src/axi_lite_regs.vhd` (modulo AXI-Lite slave generico)
- `src/bram_dp.vhd` (wrapper xpm_memory para x_buf, w_buf, y_buf)

**Verificacion:**
- Testbench VHDL: escribe registros via AXI-Lite, precarga BRAMs,
  ejecuta conv, compara output vs golden
- En HW: ARM C bare-metal programa DMA + controller, ejecuta 1 capa,
  compara resultado vs Python

**Riesgo principal:** La interfaz DDR del conv_engine (rd/wr de 8 bits,
1 ciclo de latencia) se debe adaptar a BRAM (que es 32 o 36 bits de
ancho). Solucion: wrapper que hace byte-select del word BRAM.

### Paso 2: Anadir MAXPOOL y RELU (1-2 dias)

**Alcance:**
- Anadir sub-FSMs de maxpool y leaky_relu al layer_controller
- LAYER_TYPE decode para elegir el engine
- Instanciar maxpool_unit y leaky_relu como sub-modulos
- Los registros de config de maxpool (MP_*) y leaky_relu (LR_*) ya
  estan en el mapa pero inicialmente desconectados

**Verificacion:**
- Testbench: ejecutar CONV -> RELU -> MAXPOOL secuencialmente
  (cada uno como 1 run independiente, ARM en el medio)
- En HW: las 3 primeras capas de YOLOv4 (conv + relu + maxpool)

### Paso 3: ELEM_ADD + Multi-layer con tabla (3-5 dias)

**Alcance:**
- Anadir sub-FSM de elem_add
- Implementar buffer swapping (buf_select bit)
- El controller lee tabla de layers de DDR y las ejecuta en secuencia
- El controller maneja los DMAs directamente (AXI-Lite master hacia DMA)
- No necesita intervencion del ARM entre layers

**Verificacion:**
- Ejecutar un bloque residual completo de YOLOv4:
  conv -> relu -> conv -> relu -> add (5 layers sin ARM)
- Verificar bit-exact contra Python

### Paso 4: Optimizaciones -- overlap y ping-pong (2-3 dias)

**Alcance:**
- Ping-pong de w_buf: DMA precarga mientras engine computa
- Overlap DMA de input con engine de tile anterior
- Profiling: medir ciclos de cada estado y optimizar cuello de botella

**Verificacion:**
- Medir throughput real vs teorico
- Ejecutar 10+ layers consecutivos sin intervension ARM
- Verificar que no hay corrupcion de datos por overlap

### Paso 5 (futuro): Pipeline completo YOLOv4

- Concat y Upsample
- Todas las ~150 capas
- Detection heads en ARM
- End-to-end: imagen de entrada -> bounding boxes de salida

---

## 12. Preguntas abiertas

1. **Tamano de x_buf y y_buf:** 32 KB es conservador y ahorra BRAM, pero
   requiere mas tiling espacial (mas intervenciones del ARM en Paso 1).
   64 KB es mas comodo pero usa 18 BRAM36 mas. Recomendacion: empezar
   con 32 KB, subir a 64 KB si el tiling es demasiado doloroso.

2. **Ancho de la interfaz BRAM <-> conv_engine:** El conv_engine lee/escribe
   1 byte por ciclo (8 bits). La BRAM es de 32 bits. Opciones:
   a) Wrapper con byte-select (desperdicia 3/4 del ancho de BRAM). Simple.
   b) Cambiar conv_engine para leer/escribir 4 bytes por ciclo. Complejo.
   c) Dejar BRAM de 8 bits de ancho (1 BRAM18 = 2048 bytes). Gasta mas BRAMs.
   Recomendacion: opcion (a) para Paso 1 (KISS), optimizar despues.

3. **DMA data width:** El AXI-Stream del DMA puede ser 32 o 64 bits.
   Con HP0 de 64 bits, usar DMA de 64 bits maximiza throughput DDR.
   Pero el conv_engine es de 8 bits. Solucion: un width converter
   (Xilinx AXI DataWidth Converter IP) entre DMA y BRAMs.

4. **Reloj:** Todo el diseno corre a un solo dominio (100 MHz del PS
   FCLK0). No hay CDC issues. El HP port opera a este mismo reloj.

5. **Latencia real del DMA:** El AXI DMA de Xilinx tiene overhead de
   setup (~20-50 ciclos por transfer). Para transfers pequenos (<1 KB)
   este overhead es significativo. Para Paso 1 no es critico porque
   los transfers son de decenas de KB.
