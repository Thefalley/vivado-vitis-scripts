# P_20: Conv Stream Engine -- Documento de Diseno

## 1. Motivacion

El `conv_engine_v3` accede a activaciones y pesos via DDR con latencia 1 ciclo
(interfaz BRAM-like). Esto acopla el engine directamente a la memoria y no
permite pipeline entre capas. El objetivo de P_20 es reemplazar ese acceso
directo por interfaces AXI-Stream con handshake tvalid/tready, permitiendo:

- Pipeline inter-capa (la salida de una capa alimenta directamente la siguiente).
- Uso de DMA estandar de Xilinx para mover datos desde/hacia DDR.
- Composicion modular: cada bloque habla AXI-Stream, se conectan con FIFOs.

## 2. Diagrama de Bloques

```
                     +--------------------------------------------------+
                     |           conv_stream_engine                      |
                     |                                                  |
  s_axis_act ------->| skid_in_act --> LINE BUFFER (K filas)            |
  (8b, tvalid/ready) |                    |                             |
                     |                    | rd_data (acceso random)     |
                     |                    v                             |
  s_axis_weight ---->| skid_in_wt --> WEIGHT BUF (32 KB BRAM)          |
  (8b, tvalid/ready) |                    |                             |
                     |                    v                             |
                     |              CONV FSM                            |
                     |              (pixel loop, MAC, requantize)       |
                     |                    |                             |
                     |                    v                             |
                     |              skid_out --> m_axis_out             |
                     +--------------------------------------------------+
                                                       (8b, tvalid/ready)

  cfg_* ------------> (senales directas, NO AXI-Lite)
  start/done -------> (control)
```

### Flujo de datos:

1. **Activaciones** llegan por `s_axis_act` en orden raster (fila por fila,
   canal por canal). El **line buffer** almacena K filas (tipicamente 3 para
   conv 3x3) y ofrece acceso random al ventana KxK actual.

2. **Pesos** llegan por `s_axis_weight` en el mismo orden que v3 los lee de DDR
   (tile-order: i, kh, kw, j). Se almacenan en un weight buffer BRAM interno.

3. La **FSM** procesa todos los pixels de una fila de output antes de avanzar.
   Para cada pixel calcula la ventana KxK x ic_tile, acumula en el MAC array,
   y cuando termina todos los ic_tiles, requantiza y emite el resultado.

4. **Output** se emite por `m_axis_out` en orden raster de la feature map de
   salida.


## 3. Entity: line_buffer

```vhdl
entity line_buffer is
    generic (
        MAX_WIDTH : natural := 416;   -- max pixels por fila
        MAX_C_IN  : natural := 512;   -- max canales de entrada
        K_SIZE    : natural := 3      -- filas en el buffer (kernel height)
    );
    port (
        clk, rst_n : in std_logic;

        -- Configuracion (cargada antes de start, estable durante operacion)
        cfg_w_in  : in unsigned(9 downto 0);  -- ancho real de la fila
        cfg_c_in  : in unsigned(9 downto 0);  -- canales reales

        -- AXI-Stream input (1 byte por beat)
        s_axis_tdata  : in  std_logic_vector(7 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- Acceso random para el kernel de convolucion
        rd_addr_kh : in  unsigned(1 downto 0);   -- 0 a K_SIZE-1
        rd_addr_kw : in  unsigned(9 downto 0);   -- 0 a w_in-1 (columna)
        rd_addr_ic : in  unsigned(9 downto 0);   -- 0 a c_in-1 (canal)
        rd_data    : out std_logic_vector(7 downto 0);
        rd_valid   : out std_logic;               -- dato valido 1 ciclo despues

        -- Control handshake con la FSM
        row_ready  : out std_logic;   -- "K filas listas, puedes procesar"
        row_done   : in  std_logic    -- "termine esta fila de output, avanza"
    );
end entity;
```

### Arquitectura interna del line buffer

```
  s_axis --> [write FSM] --> BRAM bank 0 (fila circular 0)
                         --> BRAM bank 1 (fila circular 1)
                         --> BRAM bank 2 (fila circular 2)
                                |
                         [read mux] --> rd_data
```

**Almacenamiento:** K bancos de BRAM, cada uno de MAX_WIDTH x MAX_C_IN bytes.
Con tiling de IC (ic_tile <= 32), cada banco almacena `w_in * ic_tile` bytes.

**Escritura:** Los datos llegan en orden raster (pixel0_ch0, pixel0_ch1, ...,
pixel0_chN, pixel1_ch0, ...). El write FSM escribe secuencialmente en el banco
actual. Cuando completa una fila (w_in * c_in bytes), avanza al siguiente banco
circular.

**Lectura:** El rd_addr se mapea como:
```
  bank = (base_row + rd_addr_kh) mod K_SIZE
  addr = rd_addr_kw * cfg_c_in + rd_addr_ic
```
Latencia de lectura: 1 ciclo (BRAM registered output).

**Logica circular:** Un registro `base_row` indica cual banco BRAM corresponde
a la fila mas antigua del buffer. Cuando la FSM pulsa `row_done`:
- `base_row` avanza +1 (mod K_SIZE)
- El banco liberado se convierte en destino de la siguiente fila de escritura
- `row_ready` baja hasta que la nueva fila se llene

**row_ready:** Se levanta cuando las K filas necesarias para la primera fila de
output estan disponibles. Para la primera fila de output (oh=0 con pad_top),
basta con K-pad_top filas reales. Para filas subsecuentes, siempre se necesitan
K filas reales (pero una ya estaba del ciclo anterior, solo hay que llenar 1 o
stride nuevas).


## 4. Entity: conv_stream_engine

```vhdl
entity conv_stream_engine is
    generic (
        N_MAC    : natural := 32;     -- MACs en paralelo (= oc_tile_size)
        WB_SIZE  : natural := 32768;  -- weight buffer size (bytes)
        LB_WIDTH : natural := 416;    -- line buffer max width
        LB_C_IN  : natural := 32;     -- line buffer max c_in (= ic_tile max)
        K_SIZE   : natural := 3       -- kernel height/width max
    );
    port (
        clk    : in std_logic;
        rst_n  : in std_logic;

        -- Configuracion de la capa (identica a conv_engine_v3)
        cfg_c_in         : in unsigned(9 downto 0);
        cfg_c_out        : in unsigned(9 downto 0);
        cfg_h_in         : in unsigned(9 downto 0);
        cfg_w_in         : in unsigned(9 downto 0);
        cfg_ksize        : in unsigned(1 downto 0);  -- 1 o 3
        cfg_stride       : in std_logic;             -- 0=stride1, 1=stride2
        cfg_pad_top      : in unsigned(1 downto 0);
        cfg_pad_bottom   : in unsigned(1 downto 0);
        cfg_pad_left     : in unsigned(1 downto 0);
        cfg_pad_right    : in unsigned(1 downto 0);
        cfg_x_zp         : in signed(8 downto 0);
        cfg_w_zp         : in signed(7 downto 0);
        cfg_M0           : in unsigned(31 downto 0);
        cfg_n_shift      : in unsigned(5 downto 0);
        cfg_y_zp         : in signed(7 downto 0);
        cfg_ic_tile_size : in unsigned(9 downto 0);

        -- Control
        start : in  std_logic;
        done  : out std_logic;
        busy  : out std_logic;

        -- AXI-Stream slave: activaciones (uint8, 1 byte/beat)
        s_axis_act_tdata  : in  std_logic_vector(7 downto 0);
        s_axis_act_tvalid : in  std_logic;
        s_axis_act_tready : out std_logic;
        s_axis_act_tlast  : in  std_logic;

        -- AXI-Stream slave: pesos (uint8, 1 byte/beat)
        s_axis_wt_tdata   : in  std_logic_vector(7 downto 0);
        s_axis_wt_tvalid  : in  std_logic;
        s_axis_wt_tready  : out std_logic;
        s_axis_wt_tlast   : in  std_logic;

        -- AXI-Stream master: output (uint8, 1 byte/beat)
        m_axis_out_tdata  : out std_logic_vector(7 downto 0);
        m_axis_out_tvalid : out std_logic;
        m_axis_out_tready : in  std_logic;
        m_axis_out_tlast  : out std_logic
    );
end entity;
```

### Diferencias clave vs conv_engine_v3

| Aspecto | conv_engine_v3 | conv_stream_engine |
|---------|-----------------|---------------------|
| Activaciones | DDR rd_addr/rd_data | s_axis_act + line buffer |
| Pesos | DDR rd_addr/rd_data | s_axis_wt + weight buf |
| Output | DDR wr_addr/wr_data | m_axis_out |
| Bias | DDR rd_addr/rd_data | s_axis_wt (preload) |
| Direcciones DDR | Calculadas internamente | Responsabilidad del wrapper/DMA |
| Tiling IC | Loop interno + addr calc | Igual, pero datos llegan por stream |
| Tiling OC | Loop interno + addr calc | Igual, wrapper reenvía pesos |


## 5. Analisis de BRAM para Line Buffer (YOLOv4-tiny)

### Formula

```
BRAM_bytes = K_SIZE * w_in * ic_tile
BRAM36_count = ceil(BRAM_bytes / 4096)   -- BRAM36 = 4 KB util (36Kb)
```

xc7z020 (ZedBoard): 140 BRAM36 disponibles.
xck26 (KV260): 144 BRAM36 disponibles.

### Sin tiling de IC (peor caso)

| Capa | w_in | c_in | K | Bytes | BRAM36 | Viable? |
|------|------|------|---|-------|--------|---------|
| layer_000 (conv1) | 416 | 3 | 3 | 3,744 | 1 | SI |
| layer_005 | 208 | 32 | 3 | 19,968 | 5 | SI |
| layer_010 | 104 | 64 | 3 | 19,968 | 5 | SI |
| layer_015 | 52 | 128 | 3 | 19,968 | 5 | SI |
| layer_020 | 26 | 256 | 3 | 19,968 | 5 | SI |
| layer_025 | 13 | 512 | 3 | 19,968 | 5 | SI |
| Max teorico | 416 | 512 | 3 | 639,744 | 157 | NO |

**Observacion:** Para YOLOv4-tiny, las capas reales nunca superan ~20 KB para
el line buffer porque w_in se reduce cuando c_in crece. Pero para redes con
feature maps grandes y muchos canales, necesitamos tiling de IC.

### Con tiling de IC (ic_tile = 32)

| Capa | w_in | ic_tile | K | Bytes | BRAM36 | Notas |
|------|------|---------|---|-------|--------|-------|
| layer_000 | 416 | 3 | 3 | 3,744 | 1 | c_in=3, no tile |
| layer_005 | 208 | 32 | 3 | 19,968 | 5 | c_in=32, tile completo |
| layer_010 | 104 | 32 | 3 | 9,984 | 3 | 2 tiles de 32 |
| layer_015 | 52 | 32 | 3 | 4,992 | 2 | 4 tiles de 32 |
| layer_020 | 26 | 32 | 3 | 2,496 | 1 | 8 tiles de 32 |
| layer_025 | 13 | 32 | 3 | 1,248 | 1 | 16 tiles de 32 |

**Conclusion:** Con ic_tile=32, el line buffer nunca excede 20 KB (5 BRAM36),
lo cual es perfectamente viable tanto en ZedBoard como en KV260.


## 6. Weight Buffer (ya existente en v3)

El weight buffer de 32 KB (8 BRAM36) se mantiene igual. Almacena
`N_MAC * ic_tile * kh * kw` bytes del tile actual de pesos.

Para ic_tile=32, kh=kw=3: 32 * 32 * 9 = 9,216 bytes (cabe holgado).

**BRAM total por instancia conv_stream_engine:**

| Bloque | BRAM36 | Notas |
|--------|--------|-------|
| Line buffer | 5 | 3 bancos x ~7 KB max |
| Weight buffer | 8 | 32 KB (misma que v3) |
| Bias buffer | 1 | 128 bytes (32 x int32) |
| Skid buffers | 0 | Usan FFs, no BRAM |
| **Total** | **14** | De 140 disponibles en xc7z020 |


## 7. Tiling de IC con Line Buffer: Flujo Detallado

El reto principal: cuando hacemos tiling de IC, la FSM necesita re-leer las
mismas posiciones espaciales del input para cada ic_tile. Con DDR esto es
trivial (acceso random). Con streaming, necesitamos una estrategia:

### Opcion A: Re-stream desde DDR (simple, mas ancho de banda)

Para cada ic_tile, el wrapper DMA re-envia las K filas de activaciones
correspondientes al ic_tile actual. El line buffer se llena K veces por
cada oc_tile (una por ic_tile).

```
for each oc_tile:
  for each ic_tile:
    DMA envia K filas de act[ic_tile] --> line buffer se llena
    DMA envia pesos[oc_tile][ic_tile] --> weight buffer se llena
    FSM procesa todos los pixels de la fila de output
  requantize y emit output
```

**Ventaja:** Line buffer solo necesita almacenar 1 ic_tile.
**Desventaja:** Cada fila de input se lee n_ic_tiles * n_oc_tiles veces.

### Opcion B: Store-and-replay del line buffer (menos BW, mas BRAM)

Almacenar todas las K filas completas (todos los canales) y hacer replay
para cada ic_tile.

**Descartada** para capas grandes por el costo en BRAM (hasta 20 KB solo
para el line buffer, mas weight buffer).

### Opcion C: Hybrid -- Elegida

El line buffer almacena un ic_tile a la vez (ic_tile canales x w_in pixels
x K filas). El wrapper coordina:

```
for each row_group (stride filas de output):
  for each oc_tile:
    load bias[oc_tile]
    for each ic_tile:
      stream act_rows[ic_tile] into line buffer   -- K*w_in*ic_tile bytes
      stream weights[oc_tile][ic_tile] into weight buf
      FSM: for each pixel in output_row:
        MAC += conv(line_buf window, weights)     -- acumula sin clear
    for each pixel in output_row:
      requantize acc --> emit via m_axis_out
  advance line buffer (drop oldest stride rows, load stride new rows)
```

**BW por fila de output:**
- Activaciones: n_oc_tiles * n_ic_tiles * K * w_in * ic_tile bytes
- Pesos: n_oc_tiles * n_ic_tiles * N_MAC * ic_tile * kh * kw bytes

Esto es identico al BW de v3 (que lee de DDR con el mismo patron de acceso).
La unica diferencia es que ahora los datos llegan por stream.


## 8. Manejo del Stride

Para stride=1: cada fila de output consume 1 nueva fila de input.
Cuando la FSM senala `row_done`, el line buffer:
- Descarta la fila mas antigua
- Acepta 1 nueva fila por stream

Para stride=2: cada fila de output consume 2 nuevas filas de input.
Cuando la FSM senala `row_done`, el line buffer:
- Descarta las 2 filas mas antiguas
- Acepta 2 nuevas filas por stream

Esto se maneja con un registro `cfg_stride` en el line buffer.


## 9. Plan de Implementacion

### Fase 1: Line Buffer (P_20a)
1. Implementar `line_buffer.vhd` con escritura stream + lectura random
2. Testbench: verificar escritura de K filas, lectura de ventana 3x3
3. Verificar avance circular con row_done

### Fase 2: Conv Stream Engine esqueleto (P_20b)
1. Copiar FSM de conv_engine_v3
2. Reemplazar DDR read de activaciones por lecturas al line buffer
3. Reemplazar DDR read de pesos por AXI-Stream -> weight buffer
4. Reemplazar DDR write de output por AXI-Stream master
5. Eliminar toda la logica de calculo de direcciones DDR

### Fase 3: Integracion (P_20c)
1. Crear wrapper con AXI-Lite para configuracion
2. Conectar DMA de activaciones y pesos
3. Testbench del sistema completo con datos de YOLOv4-tiny layer_005
4. Verificar en HW (ZedBoard o KV260)

### Fase 4: Optimizacion (P_20d)
1. Pipeline: doble buffer de pesos para solapar carga con computo
2. Pipeline: prefetch de la siguiente fila de act mientras se procesa la actual
3. Wider data path (32 bits) para mayor throughput


## 10. Consideraciones del Skid Buffer

Se reutiliza `HsSkidBuf_dest` de P_102 en las tres interfaces AXI-Stream.
El skid buffer de 2 niveles garantiza que `tready` se puede registrar sin
perder beats, cumpliendo el protocolo AXI-Stream sin stalls combinacionales.

Instancias necesarias:
- `skid_in_act`: entrada de activaciones
- `skid_in_wt`: entrada de pesos
- `skid_out`: salida de resultados
