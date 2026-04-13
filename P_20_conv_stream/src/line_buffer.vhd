-------------------------------------------------------------------------------
-- line_buffer.vhd -- Buffer circular de K filas para conv streaming
-------------------------------------------------------------------------------
--
-- Almacena K_SIZE filas de activaciones (w_in * c_in bytes cada una) en
-- BRAM, recibidas por AXI-Stream y accesibles via lectura random para el
-- kernel de convolucion.
--
-- ALMACENAMIENTO:
--   K_SIZE bancos de BRAM, cada uno de capacidad MAX_WIDTH * MAX_C_IN bytes.
--   Con tiling de IC, cfg_c_in puede ser mucho menor que MAX_C_IN, asi que
--   solo se usa una fraccion de cada banco.
--
-- ESCRITURA (AXI-Stream):
--   Los datos llegan en orden raster:
--     pixel0_ch0, pixel0_ch1, ..., pixel0_chN, pixel1_ch0, ...
--   El write FSM escribe secuencialmente en el banco actual (determinado
--   por wr_bank_ptr). Al completar w_in * c_in bytes, avanza al siguiente
--   banco circular y actualiza rows_filled.
--
-- LECTURA (acceso random, 1 ciclo de latencia):
--   La FSM del conv_stream_engine presenta (rd_addr_kh, rd_addr_kw, rd_addr_ic)
--   y obtiene rd_data un ciclo despues. El mapeo es:
--     physical_bank = (base_row + rd_addr_kh) mod K_SIZE
--     bram_addr     = rd_addr_kw * cfg_c_in + rd_addr_ic
--
-- AVANCE CIRCULAR:
--   Cuando la FSM pulsa row_done, la fila mas antigua se libera:
--     base_row <= (base_row + stride) mod K_SIZE
--     rows_filled <= rows_filled - stride
--   Y el write FSM puede llenar la(s) fila(s) liberada(s).
--
-- HANDSHAKE:
--   row_ready = '1' cuando rows_filled >= K_SIZE (todas las filas llenas).
--   s_axis_tready = '1' cuando hay al menos un banco libre para escribir.
--
-- BRAM USAGE (ic_tile=32, K=3):
--   Peor caso: 3 * 416 * 32 = 39,936 bytes ~ 10 BRAM36
--   Caso tipico (layer_020): 3 * 26 * 32 = 2,496 bytes ~ 1 BRAM36
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity line_buffer is
    generic (
        MAX_WIDTH : natural := 416;   -- max pixels por fila
        MAX_C_IN  : natural := 512;   -- max canales de entrada por tile
        K_SIZE    : natural := 3      -- filas en el buffer (kernel height)
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- Configuracion (estable durante operacion)
        cfg_w_in   : in unsigned(9 downto 0);   -- ancho real de la fila
        cfg_c_in   : in unsigned(9 downto 0);   -- canales reales (o ic_tile)
        cfg_stride : in std_logic;               -- 0 = stride 1, 1 = stride 2

        -- AXI-Stream slave: activaciones (1 byte por beat)
        s_axis_tdata  : in  std_logic_vector(7 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- Acceso random para el kernel de convolucion
        -- Latencia: 1 ciclo (BRAM registered output)
        rd_addr_kh : in  unsigned(1 downto 0);   -- 0 a K_SIZE-1
        rd_addr_kw : in  unsigned(9 downto 0);   -- 0 a w_in-1 (columna)
        rd_addr_ic : in  unsigned(9 downto 0);   -- 0 a c_in-1 (canal)
        rd_data    : out std_logic_vector(7 downto 0);
        rd_valid   : out std_logic;               -- pulso 1 ciclo despues de rd

        -- Control handshake con la FSM del conv engine
        row_ready  : out std_logic;   -- K filas listas, puedes procesar
        row_done   : in  std_logic    -- termine esta fila de output, avanza
    );
end entity line_buffer;


architecture rtl of line_buffer is

    ---------------------------------------------------------------------------
    -- Constantes derivadas
    ---------------------------------------------------------------------------
    -- Direccion maxima dentro de un banco: MAX_WIDTH * MAX_C_IN - 1
    -- Para MAX_WIDTH=416, MAX_C_IN=512: 213,248 -> 18 bits
    constant BANK_ADDR_W : natural := 18;  -- ceil(log2(MAX_WIDTH * MAX_C_IN))

    ---------------------------------------------------------------------------
    -- BRAM: K_SIZE bancos de single-port BRAM
    ---------------------------------------------------------------------------
    type bank_data_t is array (0 to K_SIZE - 1)
        of std_logic_vector(7 downto 0);

    -- Nota: en implementacion real, cada banco se infiere como BRAM con
    -- generate + atributo ram_style. Aqui se declaran las senales de interfaz.
    signal bank_we   : std_logic_vector(K_SIZE - 1 downto 0);
    signal bank_addr : unsigned(BANK_ADDR_W - 1 downto 0);
    signal bank_din  : std_logic_vector(7 downto 0);
    signal bank_dout : bank_data_t;

    ---------------------------------------------------------------------------
    -- Write FSM
    ---------------------------------------------------------------------------
    type wr_state_t is (WR_IDLE, WR_FILL, WR_WAIT_DRAIN);
    signal wr_state : wr_state_t;

    signal wr_bank_ptr  : unsigned(1 downto 0);  -- banco actual de escritura
    signal wr_byte_cnt  : unsigned(BANK_ADDR_W - 1 downto 0);  -- bytes escritos en fila actual
    signal row_size     : unsigned(BANK_ADDR_W - 1 downto 0);  -- w_in * c_in (precomputado)

    ---------------------------------------------------------------------------
    -- Row management
    ---------------------------------------------------------------------------
    signal base_row     : unsigned(1 downto 0);  -- fila logica 0 del buffer
    signal rows_filled  : unsigned(1 downto 0);  -- filas con datos validos

    ---------------------------------------------------------------------------
    -- Read pipeline (1 ciclo de latencia BRAM)
    ---------------------------------------------------------------------------
    signal rd_bank_sel  : unsigned(1 downto 0);  -- banco fisico a leer
    signal rd_bram_addr : unsigned(BANK_ADDR_W - 1 downto 0);
    signal rd_pending   : std_logic;  -- hay una lectura en vuelo

    ---------------------------------------------------------------------------
    -- Producto w * c_in para calculo de direccion de lectura
    -- Se necesita: rd_addr_kw * cfg_c_in + rd_addr_ic
    -- Para evitar un multiplicador en la ruta critica, se puede usar un
    -- registro pipeline o DSP dedicado. Por ahora se declara la senal.
    ---------------------------------------------------------------------------
    signal rd_offset : unsigned(BANK_ADDR_W - 1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------------
    row_ready <= '1' when rows_filled >= to_unsigned(K_SIZE, 2) else '0';

    s_axis_tready <= '1' when (wr_state = WR_FILL) else '0';

    ---------------------------------------------------------------------------
    -- BRAM instantiation placeholder
    ---------------------------------------------------------------------------
    -- TODO: generate K_SIZE bancos de BRAM (inferred or instantiated)
    -- Cada banco: 2^BANK_ADDR_W x 8 bits, single-port, 1 ciclo latencia.
    --
    -- gen_banks : for i in 0 to K_SIZE - 1 generate
    --     process(clk)
    --     begin
    --         if rising_edge(clk) then
    --             if bank_we(i) = '1' then
    --                 ram(to_integer(bank_addr)) <= bank_din;
    --             end if;
    --             bank_dout(i) <= ram(to_integer(bank_addr));
    --         end if;
    --     end process;
    -- end generate;

    ---------------------------------------------------------------------------
    -- Write FSM
    ---------------------------------------------------------------------------
    -- TODO: Implementar maquina de estados para:
    --   WR_IDLE: esperar start o primera activacion
    --   WR_FILL: recibir bytes por AXI-Stream, escribir en banco wr_bank_ptr
    --            al completar row_size bytes, avanzar wr_bank_ptr, rows_filled++
    --   WR_WAIT_DRAIN: si rows_filled = K_SIZE, esperar row_done para liberar

    ---------------------------------------------------------------------------
    -- Read logic
    ---------------------------------------------------------------------------
    -- TODO: Implementar calculo de direccion y mux de lectura:
    --   rd_bank_sel  <= (base_row + rd_addr_kh) mod K_SIZE
    --   rd_bram_addr <= rd_addr_kw * cfg_c_in + rd_addr_ic
    --   rd_data      <= bank_dout(to_integer(rd_bank_sel))  (1 ciclo despues)

    ---------------------------------------------------------------------------
    -- Row advance on row_done
    ---------------------------------------------------------------------------
    -- TODO: Implementar logica de avance circular:
    --   when row_done = '1':
    --     if cfg_stride = '0': base_row += 1, rows_filled -= 1
    --     if cfg_stride = '1': base_row += 2, rows_filled -= 2

end architecture rtl;
