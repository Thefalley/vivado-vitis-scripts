-------------------------------------------------------------------------------
-- conv_stream_engine.vhd -- Motor de convolucion con interfaces AXI-Stream
-------------------------------------------------------------------------------
--
-- Version streaming del conv_engine_v3. Reemplaza el acceso directo a DDR
-- (rd_addr/rd_data, wr_addr/wr_data) por tres interfaces AXI-Stream:
--
--   s_axis_act:    activaciones de entrada (uint8, 1 byte/beat)
--   s_axis_wt:     pesos + bias (uint8/int32, 1 byte/beat)
--   m_axis_out:    activaciones de salida (uint8, 1 byte/beat)
--
-- La configuracion de la capa se mantiene como senales directas (no AXI-Lite),
-- identica a conv_engine_v3. Un wrapper externo puede agregar AXI-Lite.
--
-- INTERNAMENTE:
--   - Activaciones se almacenan en un LINE BUFFER de K filas (line_buffer.vhd)
--   - Pesos se almacenan en un WEIGHT BUFFER de 32 KB (mismo que v3)
--   - Bias se precargan al inicio de cada oc_tile
--   - La FSM es una adaptacion de conv_engine_v3 con la logica de direcciones
--     DDR reemplazada por handshake con los buffers internos
--
-- TILING:
--   - oc_tile_size = N_MAC = 32 (fijo)
--   - ic_tile_size = cfg_ic_tile_size (configurable)
--   - El wrapper DMA es responsable de enviar los datos en el orden correcto
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity conv_stream_engine is
    generic (
        N_MAC    : natural := 32;     -- MACs en paralelo (= oc_tile_size)
        WB_SIZE  : natural := 32768;  -- weight buffer size (bytes)
        LB_WIDTH : natural := 416;    -- line buffer max width
        LB_C_IN  : natural := 32;     -- line buffer max c_in (= ic_tile max)
        K_SIZE   : natural := 3       -- kernel height/width max
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- Configuracion de la capa (identica a conv_engine_v3)
        cfg_c_in         : in unsigned(9 downto 0);
        cfg_c_out        : in unsigned(9 downto 0);
        cfg_h_in         : in unsigned(9 downto 0);
        cfg_w_in         : in unsigned(9 downto 0);
        cfg_ksize        : in unsigned(1 downto 0);   -- 1 o 3
        cfg_stride       : in std_logic;               -- 0=stride1, 1=stride2
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
end entity conv_stream_engine;


architecture rtl of conv_stream_engine is

    ---------------------------------------------------------------------------
    -- FSM states (adapted from conv_engine_v3)
    ---------------------------------------------------------------------------
    type state_t is (
        IDLE,
        -- Pre-computo de dimensiones
        CALC_KK,
        CALC_HOUT_1,
        CALC_HOUT_2,
        CALC_TILE_STRIDE,
        -- Esperar filas iniciales en el line buffer
        WAIT_LB_READY,
        -- Loop por tile de OC
        OC_TILE_START,
        -- Cargar bias via stream (32 x int32 = 128 bytes)
        BIAS_LOAD,
        -- Loop por tile de IC
        IC_TILE_START,
        -- Rellenar line buffer (K * w_in * ic_tile bytes via stream)
        FILL_LB_WAIT,
        -- Cargar pesos del tile via stream al weight buffer
        FILL_WB,
        -- Loop de pixels
        INIT_PIXEL,
        -- MAC loop (para cada posicion del kernel)
        MAC_LOOP,
        MAC_FIRE,
        -- Avanzar ic_tile
        IC_TILE_ADV,
        -- Drain pipeline MAC
        MAC_DRAIN,
        -- Requantize
        RQ_START,
        RQ_EMIT,
        -- Emitir resultado via m_axis_out
        OUT_EMIT,
        -- Siguiente pixel
        NEXT_PIXEL,
        -- Siguiente oc_tile
        OC_TILE_ADV,
        -- Avanzar line buffer (row_done)
        ROW_ADV,
        -- Fin
        DONE_ST
    );
    signal state : state_t;

    ---------------------------------------------------------------------------
    -- Dimensiones pre-computadas
    ---------------------------------------------------------------------------
    signal kh_size, kw_size      : unsigned(9 downto 0);
    signal stride_val            : unsigned(9 downto 0);
    signal h_out_reg, w_out_reg  : unsigned(9 downto 0);
    signal kk_reg                : unsigned(19 downto 0);
    signal tile_filter_stride    : unsigned(19 downto 0);

    ---------------------------------------------------------------------------
    -- Contadores de pixel y kernel
    ---------------------------------------------------------------------------
    signal oh, ow      : unsigned(9 downto 0);
    signal kh, kw, ic  : unsigned(9 downto 0);

    ---------------------------------------------------------------------------
    -- Contadores de tiling
    ---------------------------------------------------------------------------
    signal oc_tile_base    : unsigned(9 downto 0);
    signal ic_tile_base    : unsigned(9 downto 0);
    signal ic_in_tile_limit: unsigned(9 downto 0);

    ---------------------------------------------------------------------------
    -- Line buffer signals
    ---------------------------------------------------------------------------
    signal lb_rd_addr_kh : unsigned(1 downto 0);
    signal lb_rd_addr_kw : unsigned(9 downto 0);
    signal lb_rd_addr_ic : unsigned(9 downto 0);
    signal lb_rd_data    : std_logic_vector(7 downto 0);
    signal lb_rd_valid   : std_logic;
    signal lb_row_ready  : std_logic;
    signal lb_row_done   : std_logic;

    ---------------------------------------------------------------------------
    -- Weight buffer (inferred BRAM, same as v3)
    ---------------------------------------------------------------------------
    type weight_buf_t is array (0 to WB_SIZE - 1)
        of std_logic_vector(7 downto 0);
    signal weight_buf : weight_buf_t;

    signal wb_wr_addr : unsigned(14 downto 0);
    signal wb_wr_data : std_logic_vector(7 downto 0);
    signal wb_wr_en   : std_logic;
    signal wb_rd_addr : unsigned(14 downto 0);
    signal wb_rd_data : std_logic_vector(7 downto 0);

    ---------------------------------------------------------------------------
    -- MAC array signals (reuse mac_array_pkg)
    ---------------------------------------------------------------------------
    signal mac_a      : signed(8 downto 0);
    signal mac_b      : weight_array_t;
    signal mac_bi     : bias_array_t;
    signal mac_acc    : acc_array_t;
    signal mac_valid  : std_logic;
    signal mac_clear  : std_logic;
    signal mac_load_b : std_logic;

    ---------------------------------------------------------------------------
    -- Requantize signals
    ---------------------------------------------------------------------------
    -- (same as v3)

    ---------------------------------------------------------------------------
    -- Output emit
    ---------------------------------------------------------------------------
    signal out_byte_cnt : unsigned(5 downto 0);  -- 0..N_MAC-1

    ---------------------------------------------------------------------------
    -- Skid buffer instances (use HsSkidBuf_dest)
    ---------------------------------------------------------------------------
    -- skid_in_act: s_axis_act -> internal act stream
    -- skid_in_wt:  s_axis_wt  -> internal weight stream
    -- skid_out:    internal out stream -> m_axis_out

begin

    ---------------------------------------------------------------------------
    -- Line buffer instance
    ---------------------------------------------------------------------------
    lb_inst : entity work.line_buffer
        generic map (
            MAX_WIDTH => LB_WIDTH,
            MAX_C_IN  => LB_C_IN,
            K_SIZE    => K_SIZE
        )
        port map (
            clk           => clk,
            rst_n         => rst_n,
            cfg_w_in      => cfg_w_in,
            cfg_c_in      => cfg_ic_tile_size,  -- tile, not full c_in
            cfg_stride    => cfg_stride,
            s_axis_tdata  => s_axis_act_tdata,   -- TODO: connect via skid
            s_axis_tvalid => s_axis_act_tvalid,
            s_axis_tready => s_axis_act_tready,
            rd_addr_kh    => lb_rd_addr_kh,
            rd_addr_kw    => lb_rd_addr_kw,
            rd_addr_ic    => lb_rd_addr_ic,
            rd_data       => lb_rd_data,
            rd_valid      => lb_rd_valid,
            row_ready     => lb_row_ready,
            row_done      => lb_row_done
        );

    ---------------------------------------------------------------------------
    -- FSM (skeleton -- to be implemented based on conv_engine_v3)
    ---------------------------------------------------------------------------
    -- TODO: Implement the full FSM. The structure mirrors conv_engine_v3 but:
    --   1. Activation reads come from line_buffer instead of DDR
    --   2. Weight loading comes from s_axis_wt instead of DDR
    --   3. Output writes go to m_axis_out instead of DDR
    --   4. No DDR address calculation needed
    --   5. Synchronization via row_ready/row_done and tvalid/tready

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state       <= IDLE;
                done        <= '0';
                busy        <= '0';
                lb_row_done <= '0';
            else
                -- Default pulse signals
                lb_row_done <= '0';

                case state is
                    when IDLE =>
                        done <= '0';
                        busy <= '0';
                        if start = '1' then
                            busy  <= '1';
                            state <= CALC_KK;
                        end if;

                    when CALC_KK =>
                        -- TODO: kk_reg <= kh_size * kw_size
                        state <= CALC_HOUT_1;

                    when CALC_HOUT_1 =>
                        -- TODO: compute h_out, w_out
                        state <= CALC_HOUT_2;

                    when CALC_HOUT_2 =>
                        -- TODO: finalize dimensions
                        state <= CALC_TILE_STRIDE;

                    when CALC_TILE_STRIDE =>
                        -- TODO: tile_filter_stride <= ic_tile_size * kk_reg
                        state <= WAIT_LB_READY;

                    when WAIT_LB_READY =>
                        -- Wait until line buffer has K rows ready
                        if lb_row_ready = '1' then
                            state <= OC_TILE_START;
                        end if;

                    when OC_TILE_START =>
                        -- TODO: initialize oc_tile_base
                        state <= BIAS_LOAD;

                    when BIAS_LOAD =>
                        -- TODO: load 128 bytes of bias via s_axis_wt
                        state <= IC_TILE_START;

                    when IC_TILE_START =>
                        -- TODO: initialize ic_tile_base
                        state <= FILL_LB_WAIT;

                    when FILL_LB_WAIT =>
                        -- Line buffer fills from s_axis_act
                        -- Wait until rows are ready
                        if lb_row_ready = '1' then
                            state <= FILL_WB;
                        end if;

                    when FILL_WB =>
                        -- TODO: load weights from s_axis_wt into weight_buf
                        state <= INIT_PIXEL;

                    when INIT_PIXEL =>
                        -- TODO: initialize pixel counters, clear MAC if first ic_tile
                        state <= MAC_LOOP;

                    when MAC_LOOP =>
                        -- TODO: iterate over kh, kw, ic
                        -- Read activation from line buffer
                        -- Read weight from weight buffer
                        state <= MAC_FIRE;

                    when MAC_FIRE =>
                        -- TODO: pulse MAC, advance counters
                        -- If done with kernel: check next ic_tile or requantize
                        state <= MAC_LOOP;

                    when IC_TILE_ADV =>
                        -- TODO: advance ic_tile_base
                        state <= FILL_LB_WAIT;

                    when MAC_DRAIN =>
                        -- TODO: wait for MAC pipeline to flush
                        state <= RQ_START;

                    when RQ_START =>
                        -- TODO: start requantization
                        state <= RQ_EMIT;

                    when RQ_EMIT =>
                        -- TODO: requantize and prepare output bytes
                        state <= OUT_EMIT;

                    when OUT_EMIT =>
                        -- TODO: emit N_MAC bytes via m_axis_out with handshake
                        state <= NEXT_PIXEL;

                    when NEXT_PIXEL =>
                        -- TODO: advance ow, oh
                        -- If row complete: ROW_ADV or OC_TILE_ADV
                        state <= INIT_PIXEL;

                    when OC_TILE_ADV =>
                        -- TODO: advance oc_tile_base
                        -- If all oc_tiles done: ROW_ADV
                        state <= OC_TILE_START;

                    when ROW_ADV =>
                        lb_row_done <= '1';
                        state <= WAIT_LB_READY;

                    when DONE_ST =>
                        done <= '1';
                        busy <= '0';
                        state <= IDLE;

                    when others =>
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
