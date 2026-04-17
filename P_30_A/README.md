# P_30_A — FIFO de pesos + BRAM 8 KB

## Contexto (para no perder el hilo)

En P_18 tenemos un DPU que ejecuta YOLOv4 capa a capa. Las capas 0 (CONV) y 1 (LEAKY) son **bit-exact contra ONNX** (verificado con CRC byte a byte). Pero a partir de la capa 2, los pesos no caben en el BRAM del wrapper.

### El problema

```
                ┌──────────┐
DDR ──DMA────▶  │ BRAM 4KB │ ← TODO pasa por aquí (input + pesos + bias + output)
                └──────────┘
```

Para capa 2 (c_in=32, c_out=64, k=3):
- Pesos = 64 × 3 × 3 × 32 = 18 432 bytes → NO CABE en 4 KB
- Solo 2 de las 110 CONVs de YOLOv4 caben en 4 KB

### La solución P_30_A

Dos cambios:

**Cambio 1**: FIFO dedicada para pesos. Los pesos van por su propio DMA y FIFO, directo al `wb_ram` (buffer interno de 32 KB que ya existe en el conv_engine_v3). No pasan por el BRAM de 4 KB.

**Cambio 2**: BRAM sube de 4 KB a 8 KB. Porque sin pesos, el BRAM solo tiene input + bias + output. Pero 7 capas con c_out=1024 tienen bias de 4 KB y output de 1 KB = 5 KB > 4 KB. Con 8 KB caben todas.

```
                         ┌──────────┐
DDR (pesos) ──DMA_W────▶│ FIFO_W   │──▶ wb_ram 32 KB
                         └──────────┘    (ya existe dentro de conv_engine)

DDR (input+bias) ──DMA_IN──▶ BRAM 8 KB  (antes 4 KB)
                              conv_engine lee input y bias de aquí

conv_engine_v3: NO CAMBIA la lógica interna.
                Solo se le añade un puerto de escritura al wb_ram.
```

---

## Plataforma

- **Board**: ZedBoard (xc7z020clg484-1)
- **Herramientas**: Vivado 2025.2, Vitis 2025.2
- **Servidor**: SSH a jce03@100.73.144.105 para síntesis (Vivado en E:/vivado-instalado/2025.2.1)
- **PC local**: Windows 10, Python 3.14, Ethernet directo al board

---

## Cómo funciona HOY (P_18, lo que ya está verificado)

### Secuencia de UN tile de convolución

```
ARM prepara un paquete plano en DDR:
  [0x000] OUTPUT zone (zeros)
  [0x200] INPUT (ic_tile_size × h × w bytes, NCHW)
  [0x240] WEIGHTS (c_out × k² × c_in bytes, OHWI)
  [0x5C0] BIAS (c_out × 4 bytes, int32 LE)

ARM programa registros MMIO del wrapper:
  REG_N_WORDS = total_bytes / 4
  REG_C_IN, REG_C_OUT, REG_H_IN, REG_W_IN
  REG_KSP (kernel + stride codificados)
  REG_X_ZP, REG_M0, REG_N_SHIFT, REG_Y_ZP
  REG_ADDR_INPUT = 0x200    ← offset dentro del BRAM
  REG_ADDR_WEIGHTS = 0x240
  REG_ADDR_BIAS = 0x5C0
  REG_ADDR_OUTPUT = 0x000
  REG_IC_TILE_SIZE = c_in   ← HOY pone c_in entero (sin IC tiling)
  REG_PAD_TOP/BOTTOM/LEFT/RIGHT

ARM ejecuta:
  1. LOAD:  DMA MM2S manda el paquete → wrapper lo escribe al BRAM, byte a byte
  2. START: conv_engine_v3 trabaja:
     a. Lee bias del BRAM (BL_EMIT/WAIT/CAPTURE)
     b. Para cada ic_tile:
        - Copia pesos del BRAM al wb_ram interno (WL_EMIT/WAIT/CAPTURE)
        - Para cada pixel: lee input del BRAM (MAC_EMIT/WAIT/CAPTURE/FIRE)
        - Acumula sin limpiar MAC
     c. Requantize → escribe output al BRAM
  3. DRAIN: DataMover S2MM lee output del BRAM → DDR
```

### Por qué falla con capas grandes

En el paso 1, el DMA manda TODO al BRAM. Si pesos = 18 KB, no cabe en 4 KB.
El conv_engine NECESITA los pesos en el BRAM para copiarlos al wb_ram.

---

## Cómo funcionará con P_30_A

### Secuencia de UN tile (nueva)

```
ARM prepara DOS bloques en DDR:

  Bloque A (pesos) en DDR @ addr_pesos:
    [0] Pesos OHWI: c_out × k² × c_in bytes  (puede ser 18 KB, 4.7 MB, lo que sea)

  Bloque B (input+bias+output) en DDR @ addr_tile:
    [0x000] OUTPUT zone (zeros)
    [0x100] INPUT (ic_tile_size × h × w bytes, NCHW)
    [0x200] BIAS (c_out × 4 bytes, int32 LE)
    Total Bloque B ≤ 8 KB ← SIEMPRE cabe

ARM ejecuta:
  1. LOAD_WEIGHTS: DMA_W manda Bloque A por AXI-Stream → FIFO_W → wb_ram
     El wrapper tiene un estado nuevo S_LOAD_WEIGHTS:
       - Lee de FIFO_W un word de 32 bits por ciclo
       - Escribe al wb_ram con un contador: wb_ram[0], wb_ram[1], wb_ram[2], ...
       - Se detiene cuando ha escrito N_W_WORDS words
     Los pesos quedan en wb_ram, listos para que el conv los use.

  2. LOAD: DMA_IN manda Bloque B (como HOY) → BRAM 8 KB
     Solo input + bias + output zone. Sin pesos.

  3. START: conv_engine_v3 trabaja EXACTAMENTE como hoy:
     a. Lee bias del BRAM ← sigue en el BRAM
     b. Para cada ic_tile:
        - Lee pesos del wb_ram ← YA ESTÁN AHÍ (cargados en paso 1)
        - Para cada pixel: lee input del BRAM ← sigue en el BRAM
     c. Requantize → escribe output al BRAM

  4. DRAIN: como hoy, DataMover saca output del BRAM → DDR
```

### La diferencia clave

```
HOY:   pesos van DDR → DMA → BRAM 4KB → conv copia a wb_ram
P_30_A: pesos van DDR → DMA_W → FIFO_W → wb_ram DIRECTO (bypass BRAM)
```

---

## Ejemplo concreto: Layer 2 (c_in=32, c_out=64, k=3, stride=2)

### Cálculos

```
Pesos totales: 64 × 9 × 32 = 18 432 bytes
ic_tile_size máximo para wb_ram 32KB: 32768 / (64 × 9) = 56 → c_in=32 cabe entero
→ Solo 1 ic_tile (toda la capa en una pasada de IC)

Bloque A (pesos): 18 432 bytes → DMA_W → FIFO_W → wb_ram
Bloque B: output + input + bias = 64×t² + 32×in_h² + 256
  Con tile=4: 64×16 + 32×81 + 256 = 1024 + 2592 + 256 = 3872 < 8 KB ✓
```

### Secuencia paso a paso

```
ARM:
  1. XAxiDma_SimpleTransfer(&dma_w, addr_pesos, 18432, TO_DEVICE)
     → DMA_W lee 18432 bytes de DDR y los empuja al stream
     → FIFO_W los bufferiza
     → El wrapper (S_LOAD_WEIGHTS) los escribe: wb_ram[0]=byte0, wb_ram[1]=byte1, ...
     → 18432 bytes = 4608 words de 32 bits → wb_ram[0..4607]

  2. Prepara Bloque B en DDR:
     memset(src, 0, 3872);           // output zone
     memcpy(src+0x100, input, 2592); // input del tile
     memcpy(src+0xB00, bias, 256);   // bias
     XAxiDma_SimpleTransfer(&dma_in, src, 3872, TO_DEVICE)
     → BRAM[0..967] recibe los 3872 bytes

  3. Programa registros:
     REG_ADDR_INPUT = 0x100
     REG_ADDR_BIAS = 0xB00
     REG_ADDR_OUTPUT = 0x000
     REG_IC_TILE_SIZE = 32   ← c_in entero (cabe en wb_ram)
     REG_ADDR_WEIGHTS = 0    ← wb_ram offset 0 (ya cargado por paso 1)

  4. CTRL = START
     conv_engine lee pesos de wb_ram, input de BRAM, calcula...

  5. CTRL = DRAIN
     output → DataMover → DDR
```

### Ejemplo con capa GRANDE: Layer 244 (c_in=512, c_out=1024, k=3)

```
Pesos totales: 1024 × 9 × 512 = 4 718 592 bytes (4.5 MB!)
ic_tile_size para wb_ram 32KB: 32768 / (1024 × 9) = 3
→ 512 / 3 = 171 ic_tiles

El conv_engine_v3 hace IC tiling INTERNAMENTE:
  cfg_c_in = 512
  cfg_ic_tile_size = 3
  El RTL itera: ic_tile_0 (canales 0-2), ic_tile_1 (canales 3-5), ..., ic_tile_170

PERO: los pesos de los 171 ic_tiles = 4.5 MB. wb_ram solo tiene 32 KB.

PROBLEMA: el RTL busca los pesos de ic_tile_1 en wb_ram despues de
procesar ic_tile_0, pero wb_ram solo tiene los de ic_tile_0.

SOLUCION: el ARM hace el IC tile loop explícitamente:
  Para cada ic_tile_base = 0, 3, 6, ..., 510:
    1. DMA_W manda pesos de ESTE ic_tile (1024×9×3=27648 B) → FIFO_W → wb_ram
    2. DMA_IN manda input de ESTE ic_tile (3 canales del tile) → BRAM
    3. cfg_c_in = 3, cfg_ic_tile_size = 3
    4. START
    5. Si no es el ultimo: NO requantize, NO limpiar MAC
    6. Si es el ultimo: requantize + DRAIN

  → Necesita 2 flags nuevos en el conv:
    cfg_no_clear (no limpiar MAC al empezar)
    cfg_no_requantize (no requantize al terminar)
```

---

## Piezas a implementar

### Pieza 1: BRAM 8 KB (1 línea de cambio)

En `dpu_stream_wrapper.vhd`:
```vhdl
-- ANTES:
type bram_t is array (0 to 1023) of std_logic_vector(31 downto 0);  -- 4 KB
-- DESPUÉS:
type bram_t is array (0 to 2047) of std_logic_vector(31 downto 0);  -- 8 KB
```

### Pieza 2: FIFO_W (reusar P_102 pattern)

Módulo: `fifo_weights.vhd`
- Input: AXI-Stream 32 bits (s_axis_tvalid, s_axis_tready, s_axis_tdata)
- Output: valid/ready handshake + 32 bits data → hacia wb_ram
- Profundidad: 512-1024 words (2-4 KB de FIFO, 1 BRAM36)
- Control: registro N_W_WORDS para saber cuándo parar

### Pieza 3: wb_ram write port (exponer desde conv_engine)

El wb_ram actual está DENTRO de conv_engine_v3 (señal interna `wb_ram`).
Para que el wrapper escriba ahí, tenemos DOS opciones:

**Opción 3a**: Sacar un puerto de escritura del conv_engine:
```vhdl
-- Nuevos puertos en conv_engine_v4:
ext_wb_addr : in  unsigned(14 downto 0);
ext_wb_data : in  signed(7 downto 0);
ext_wb_we   : in  std_logic;
```
Y dentro del conv, muxear entre escritura interna (WL_CAPTURE) y externa:
```vhdl
if ext_wb_we = '1' then
    wb_ram(to_integer(ext_wb_addr)) <= ext_wb_data;
elsif wb_we = '1' then
    wb_ram(to_integer(wb_addr)) <= wb_din;
end if;
```

**Opción 3b**: Mover wb_ram FUERA del conv_engine, al wrapper. El conv lee de un puerto, el wrapper escribe desde la FIFO. Más limpio pero más refactoring.

### Pieza 4: Wrapper FSM — estado S_LOAD_WEIGHTS

```vhdl
when S_LOAD_WEIGHTS =>
    if fifo_w_valid = '1' and wb_word_count < n_w_words then
        -- Escribe 4 bytes (1 word) al wb_ram como 4 bytes consecutivos
        ext_wb_addr <= wb_word_count * 4 + byte_idx;
        ext_wb_data <= fifo_w_data(byte_idx*8+7 downto byte_idx*8);
        ext_wb_we   <= '1';
        fifo_w_ready <= '1';  -- consumir de la FIFO
        -- Avanzar contadores
    elsif wb_word_count >= n_w_words then
        done_weights <= '1';
        state <= S_IDLE;
    end if;
```

### Pieza 5: Block Design — DMA_W nuevo

```tcl
# En create_bd.tcl:
set dma_w [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_w]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_mm2s_burst_size {256} \
] $dma_w
# Conectar a HP1
# Stream output → FIFO_W input
```

### Pieza 6: conv_engine_v4 — 2 flags para IC tiling ARM

Solo necesarios para capas donde pesos > 32 KB (80 de las 110 CONVs):
```vhdl
cfg_no_clear      : in std_logic;  -- '1' = no mac_clr al inicio
cfg_no_requantize : in std_logic;  -- '1' = skip requantize+write
```

### Pieza 7: ARM firmware

```c
int dpu_exec_conv_v4(layer_config_t *L, ...) {
    int ic_ts = compute_ic_tile_for_wb(L);  // que quepa en 32 KB wb_ram
    int w_tile_bytes = L->c_out * L->kernel * L->kernel * ic_ts;
    
    for (int ic_base = 0; ic_base < L->c_in; ic_base += ic_ts) {
        int is_first = (ic_base == 0);
        int is_last  = (ic_base + ic_ts >= L->c_in);
        
        // 1. Cargar pesos de este ic_tile via DMA_W → FIFO_W → wb_ram
        XAxiDma_SimpleTransfer(&dma_w, w_addr + ic_base*..., w_tile_bytes, TO_DEVICE);
        wait_weights_loaded();
        
        // 2. Cargar input de este ic_tile + bias(solo first) via DMA_IN → BRAM
        prepare_tile_bram(L, input, ic_base, ic_ts, is_first);
        XAxiDma_SimpleTransfer(&dma_in, tile_buf, tile_bytes, TO_DEVICE);
        wait_bram_loaded();
        
        // 3. Configurar y ejecutar
        dpu_write(REG_NO_CLEAR, is_first ? 0 : 1);
        dpu_write(REG_NO_REQUANTIZE, is_last ? 0 : 1);
        dpu_write(REG_C_IN, ic_ts);
        dpu_write(REG_IC_TILE_SIZE, ic_ts);
        dpu_write(REG_CTRL, CMD_START);
        wait_done();
        
        // 4. Solo DRAIN en el último ic_tile
        if (is_last) {
            dm_configure(out_addr, out_bytes);
            dpu_write(REG_CTRL, CMD_DRAIN);
            wait_dm_done();
        }
    }
}
```

---

## Recursos

| Recurso | P_18 actual | P_30_A | Zynq-7020 |
|---|---|---|---|
| BRAM36 | ~10 | ~13 (+1 BRAM8K, +1 FIFO_W, +1 DMA_W) | 140 |
| DSP48 | 44 | 44 (sin cambio) | 220 |
| HP ports | 1 | 2 (+1 para DMA_W) | 4 |
| AXI DMA | 1 | 2 | - |

---

## Plan de implementación

```
Fase 1: conv_engine_v4 (2 flags + ext_wb_* ports)      sim en XSIM
Fase 2: FIFO_W (P_102 pattern)                          sim standalone
Fase 3: wrapper_v4 (S_LOAD_WEIGHTS + BRAM 8KB)          sim end-to-end
Fase 4: Block Design (DMA_W + conexiones)                síntesis + impl
Fase 5: ARM firmware dpu_exec_v4.c                       test en board
Fase 6: Barrido 255 capas bit-exact vs ONNX             Ethernet
```

---

## Archivos que se crean

```
P_30_A/
├── src/
│   ├── conv_engine_v4.vhd        ← v3 + 2 flags + ext_wb ports
│   ├── fifo_weights.vhd          ← FIFO P_102 style para pesos
│   ├── dpu_stream_wrapper_v4.vhd ← wrapper + S_LOAD_WEIGHTS + BRAM 8KB
│   └── create_bd.tcl             ← BD con 2 DMAs
├── sim/
│   ├── conv_v4_layer2_tb.vhd     ← testbench layer 2 (primera capa que falla hoy)
│   └── run_sim.sh
├── sw/
│   └── dpu_exec_v4.c             ← firmware ARM con IC tiling
├── docs/
│   └── (diagramas de timing, etc.)
└── README.md                     ← este archivo
```
