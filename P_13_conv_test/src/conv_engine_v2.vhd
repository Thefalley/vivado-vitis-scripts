-------------------------------------------------------------------------------
-- conv_engine_v2.vhd — Motor de convolucion con TILING (capas grandes)
-------------------------------------------------------------------------------
--
-- DIFERENCIA vs v1 (conv_engine.vhd):
--   v1 carga TODOS los pesos de la capa en weight_buf (32 KB) antes de
--   empezar. Esto funciona para capas pequeñas (layer_005, 864 B) pero
--   revienta para layer_148 (4.7 MB). v2 procesa la convolucion por
--   TILES: carga solo los pesos del tile actual al weight_buf.
--
-- DISEÑO DE TILING (acordado con el usuario):
--
--   oc_tile_size = N_MAC = 32  (fijo, no configurable)
--   ic_tile_size              (configurable via cfg_ic_tile_size)
--
-- LOOP STRUCTURE:
--
--   para cada oc_tile_base in 0, 32, 64, ..., c_out:
--     para cada pixel (oh, ow):
--       clear MAC array
--       load bias[oc_tile_base..oc_tile_base+31]
--       para cada ic_tile_base in 0, ic_tile_size, ..., c_in:
--         cargar pesos del tile (32 oc × ic_tile_size × kh × kw bytes)
--         para cada (kh, kw):
--           para cada ic dentro del tile (0..ic_tile_size-1):
--             leer activacion x[ic_tile_base+ic][ih][iw]
--             pulsar MAC (acumula sobre los 32 oc en paralelo)
--       requantize 32 acc → escribir 32 bytes a DDR
--
-- CLAVE: el mac_array NO se limpia entre ic_tiles del MISMO pixel,
-- asi los acumuladores retienen la suma parcial de tiles anteriores.
-- No hace falta scratch DDR para acc parciales.
--
-- LAYOUT DE LOS PESOS EN DDR (CRITICO):
--
--   v1 trata los pesos como layout OHWI:
--     weights[oc][kh][kw][ic]
--   (el addr avanza ic → kw → kh dentro de cada filtro oc,
--    y cada filtro oc ocupa c_in × kh × kw bytes contiguos)
--
--   v2 mantiene EXACTAMENTE el mismo layout OHWI en DDR para
--   compatibilidad con los binarios que ya usa el pipeline Python
--   y el testbench de v1. El tiling NO cambia el layout externo:
--   solo cambia QUE rango de bytes leemos en cada pasada.
--
--   Direccion de inicio del tile (oc_tile_base, ic_tile_base):
--     byte_0 = cfg_addr_weights
--            + oc_tile_base × (c_in × kh × kw)          (filtro base)
--            + 0 × (c_in × kh × kw)                     (primer oc del tile)
--            + 0 × kw × c_in                            (kh=0)
--            + 0 × c_in                                 (kw=0)
--            + ic_tile_base                             (primer ic del tile)
--
--   Los pesos del tile se leen en ORDEN (i, kh, kw, j) donde
--     i = 0..31       (oc dentro del tile)
--     kh = 0..kh_size-1
--     kw = 0..kw_size-1
--     j  = 0..ic_tile_size-1
--   Cada lectura sucesiva avanza j (stride 1 en DDR), al terminar un
--   kw saltamos (c_in - ic_tile_size) para ir al siguiente kw, etc.
--
--   Dentro de weight_buf el tile se guarda COMPACTO en el mismo orden
--   (i, kh, kw, j), lo que hace el MAC loop igual de barato que v1:
--     filter_stride = ic_tile_size × kh × kw
--     w_base_idx avanza +1 por paso MAC
--     mac_b(i) = weight_buf(w_base + i × filter_stride)
--
-- REGLAS RESPETADAS (igual que v1):
--   1. Reset sincrono dentro de rising_edge
--   2. Maximo 1 multiplicacion por ciclo (contadores incrementales)
--   3. Carry chains < 30 bits por etapa
--   4. Sin cadenas combinacionales mult+add
--   5. Interfaz DDR de 1 ciclo de latencia (EMIT→WAIT→CAPTURE)
--   6. Reusa mac_array y requantize sin tocarlos
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity conv_engine_v2 is
    generic (
        WB_SIZE : natural := 32768
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- Configuracion de la capa (igual que v1)
        cfg_c_in        : in  unsigned(9 downto 0);
        cfg_c_out       : in  unsigned(9 downto 0);
        cfg_h_in        : in  unsigned(9 downto 0);
        cfg_w_in        : in  unsigned(9 downto 0);
        cfg_ksize       : in  unsigned(1 downto 0);
        cfg_stride      : in  std_logic;
        cfg_pad         : in  std_logic;
        cfg_x_zp        : in  signed(8 downto 0);
        cfg_w_zp        : in  signed(7 downto 0);
        cfg_M0          : in  unsigned(31 downto 0);
        cfg_n_shift     : in  unsigned(5 downto 0);
        cfg_y_zp        : in  signed(7 downto 0);
        cfg_addr_input  : in  unsigned(24 downto 0);
        cfg_addr_weights: in  unsigned(24 downto 0);
        cfg_addr_bias   : in  unsigned(24 downto 0);
        cfg_addr_output : in  unsigned(24 downto 0);

        -- NUEVO: tamaño del tile de canales de entrada
        -- Restriccion: ic_tile_size × kh × kw × N_MAC ≤ WB_SIZE
        -- Ejemplo: WB_SIZE=32768, kh=kw=3, N_MAC=32 → ic_tile_size ≤ 113
        cfg_ic_tile_size : in  unsigned(9 downto 0);

        -- Control
        start     : in  std_logic;
        done      : out std_logic;
        busy      : out std_logic;

        -- Interfaz DDR (latencia 1 ciclo, igual que v1)
        ddr_rd_addr : out unsigned(24 downto 0);
        ddr_rd_data : in  std_logic_vector(7 downto 0);
        ddr_rd_en   : out std_logic;
        ddr_wr_addr : out unsigned(24 downto 0);
        ddr_wr_data : out std_logic_vector(7 downto 0);
        ddr_wr_en   : out std_logic;

        -- DEBUG (similar a v1, ampliado con tile counters)
        dbg_state       : out integer range 0 to 63;
        dbg_oh          : out unsigned(9 downto 0);
        dbg_ow          : out unsigned(9 downto 0);
        dbg_kh          : out unsigned(9 downto 0);
        dbg_kw          : out unsigned(9 downto 0);
        dbg_ic          : out unsigned(9 downto 0);
        dbg_oc_tile_base: out unsigned(9 downto 0);
        dbg_ic_tile_base: out unsigned(9 downto 0);
        dbg_w_base      : out unsigned(19 downto 0);
        dbg_mac_a       : out signed(8 downto 0);
        dbg_mac_b       : out weight_array_t;
        dbg_mac_bi      : out bias_array_t;
        dbg_mac_acc     : out acc_array_t;
        dbg_mac_vi      : out std_logic;
        dbg_mac_clr     : out std_logic;
        dbg_mac_lb      : out std_logic;
        dbg_pad         : out std_logic;
        dbg_act_addr    : out unsigned(24 downto 0)
    );
end entity conv_engine_v2;

architecture rtl of conv_engine_v2 is

    type state_t is (
        IDLE,
        -- Pre-computo (1 vez por capa, 1 mult max por estado)
        CALC_KK,           -- kk_reg = kh × kw
        CALC_HOUT_1,       -- h_dim, w_dim = h_in + 2*pad - k (sumas)
        CALC_HOUT_2,       -- h_out = dim/stride + 1 (shift + sum)
        CALC_HW,           -- hw_reg = h_in × w_in
        CALC_HW_OUT,       -- hw_out_reg = h_out × w_out
        CALC_W_FILTER,     -- w_per_filter = c_in × kk_reg  (stride del filtro en DDR)
        CALC_TILE_STRIDE,  -- tile_filter_stride = ic_tile_size × kk_reg  (stride en buf)
        CALC_KW_CIN,       -- kw_cin_reg = kw_size × c_in  (para saltar kh en DDR)
        -- Bucle por tile de oc
        OC_TILE_START,     -- inicializar oc_tile_base, addr_bias del tile
        -- Cargar bias del oc_tile (32 palabras int32 = 128 bytes)
        BL_EMIT, BL_WAIT, BL_CAPTURE,
        -- Bucle pixel (dentro del oc_tile)
        INIT_ROW,
        INIT_PIXEL_1,      -- clear MAC, temp_oh_w, ih_base, iw_base
        INIT_PIXEL_2,      -- temp_ihb_w = ih_base × w_in, rq_wr_base
        INIT_PIXEL_3,      -- act_pixel_base, reset offsets, reset ic_tile_base
        BIAS_LOAD,
        -- Cargar pesos del tile (oc_tile, ic_tile) al weight_buf
        WL_NEXT,           -- chequea si hay mas bytes del tile a cargar
        WL_EMIT, WL_WAIT, WL_CAPTURE,
        -- MAC loop (dentro del ic_tile)
        MAC_PAD_REG,       -- padding check + act_addr + init wload
        MAC_WLOAD,         -- 1 peso/ciclo del weight_buf (32 ciclos)
        MAC_EMIT, MAC_WAIT_DDR, MAC_CAPTURE, MAC_FIRE,
        -- Avanzar ic_tile o terminar pixel
        IC_TILE_ADV,       -- siguiente ic_tile del MISMO pixel (sin clear)
        -- Drain pipeline MAC
        MAC_DONE_WAIT, MAC_DONE_WAIT2,
        -- Requantize + escritura DDR
        RQ_EMIT, RQ_CAPTURE,
        -- Final
        NEXT_PIXEL,
        OC_TILE_ADV,       -- siguiente oc_tile
        DONE_ST
    );
    signal state : state_t;

    ---------------------------------------------------------------------------
    -- Dimensiones combinacionales (mux, 0 mults)
    ---------------------------------------------------------------------------
    signal kh_size, kw_size, pad_val, stride_val : unsigned(9 downto 0);

    ---------------------------------------------------------------------------
    -- Constantes de capa (pre-computadas una vez)
    ---------------------------------------------------------------------------
    signal kk_reg            : unsigned(19 downto 0);  -- kh × kw
    signal hw_reg            : unsigned(19 downto 0);  -- h_in × w_in
    signal hw_out_reg        : unsigned(19 downto 0);  -- h_out × w_out
    signal h_out_reg         : unsigned(9 downto 0);
    signal w_out_reg         : unsigned(9 downto 0);
    signal h_dim_r           : unsigned(9 downto 0);
    signal w_dim_r           : unsigned(9 downto 0);
    signal w_per_filter_full : unsigned(19 downto 0);  -- c_in × kh × kw (stride en DDR de un filtro completo)
    signal tile_filter_stride: unsigned(19 downto 0);  -- ic_tile_size × kh × kw (stride dentro del buf)
    signal kw_cin_reg        : unsigned(19 downto 0);  -- kw_size × c_in (stride para saltar kh en DDR, informativo)

    ---------------------------------------------------------------------------
    -- Contadores pixel / kernel / ic
    ---------------------------------------------------------------------------
    signal oh, ow, kh, kw, ic : unsigned(9 downto 0);

    ---------------------------------------------------------------------------
    -- Contadores de TILING
    ---------------------------------------------------------------------------
    signal oc_tile_base : unsigned(9 downto 0);   -- 0, 32, 64, ...
    signal ic_tile_base : unsigned(9 downto 0);   -- 0, ic_tile_size, 2*ic_tile_size, ...
    signal ic_in_tile_limit : unsigned(9 downto 0); -- min(ic_tile_size, c_in - ic_tile_base)

    ---------------------------------------------------------------------------
    -- Carga de pesos del tile (WL_*)
    ---------------------------------------------------------------------------
    -- wl_i  : 0..N_MAC-1   (oc dentro del tile)
    -- wl_kh : 0..kh_size-1
    -- wl_kw : 0..kw_size-1
    -- wl_j  : 0..ic_in_tile_limit-1
    signal wl_i          : unsigned(5 downto 0);
    signal wl_kh         : unsigned(9 downto 0);
    signal wl_kw         : unsigned(9 downto 0);
    signal wl_j          : unsigned(9 downto 0);
    signal wl_ddr_addr   : unsigned(24 downto 0);  -- direccion DDR actual
    signal wl_buf_addr   : unsigned(19 downto 0);  -- indice dentro del weight_buf
    signal wl_oc_base_addr: unsigned(24 downto 0); -- base en DDR del filtro oc_tile_base+wl_i

    ---------------------------------------------------------------------------
    -- Bias DMA del oc_tile actual
    ---------------------------------------------------------------------------
    signal bias_word_idx  : unsigned(9 downto 0);
    signal bias_byte_idx  : unsigned(1 downto 0);
    signal bias_shift_reg : std_logic_vector(31 downto 0);
    signal bias_addr_r    : unsigned(24 downto 0);

    ---------------------------------------------------------------------------
    -- Direccion de activacion (contadores incrementales)
    -- act_addr = act_pixel_base + act_ic_offset + act_kh_offset + kw
    ---------------------------------------------------------------------------
    signal ih_base_r      : signed(10 downto 0);
    signal iw_base_r      : signed(10 downto 0);
    signal temp_ihb_w     : unsigned(19 downto 0);
    signal temp_oh_w      : unsigned(19 downto 0);
    signal act_pixel_base : unsigned(24 downto 0);
    signal act_tile_base  : unsigned(24 downto 0);  -- +hw_reg × ic_tile_base (base del ic_tile)
    signal act_ic_offset  : unsigned(24 downto 0);
    signal act_kh_offset  : unsigned(24 downto 0);
    signal act_addr_r     : unsigned(24 downto 0);

    ---------------------------------------------------------------------------
    -- Contador de peso en MAC loop (avanza +1 por paso MAC)
    ---------------------------------------------------------------------------
    signal w_base_idx_r : unsigned(19 downto 0);

    ---------------------------------------------------------------------------
    -- Carga secuencial de mac_b desde weight_buf (32 ciclos por paso MAC)
    ---------------------------------------------------------------------------
    signal wload_cnt    : unsigned(5 downto 0);
    signal wload_addr_r : unsigned(19 downto 0);

    ---------------------------------------------------------------------------
    -- Padding flag
    ---------------------------------------------------------------------------
    signal pad_saved : std_logic;

    ---------------------------------------------------------------------------
    -- Requantize: escritura incremental
    ---------------------------------------------------------------------------
    signal rq_ch        : unsigned(9 downto 0);
    signal rq_wr_addr_r : unsigned(24 downto 0);

    ---------------------------------------------------------------------------
    -- Buffers
    ---------------------------------------------------------------------------
    type weight_mem_t is array(0 to WB_SIZE-1) of signed(7 downto 0);
    signal weight_buf : weight_mem_t;
    signal bias_buf   : bias_array_t;

    ---------------------------------------------------------------------------
    -- MAC array
    ---------------------------------------------------------------------------
    signal mac_a   : signed(8 downto 0);
    signal mac_b   : weight_array_t;
    signal mac_bi  : bias_array_t;
    signal mac_vi, mac_lb, mac_clr : std_logic;
    signal mac_acc : acc_array_t;

    ---------------------------------------------------------------------------
    -- Requantize
    ---------------------------------------------------------------------------
    signal rq_acc_in : signed(31 downto 0);
    signal rq_vi     : std_logic;
    signal rq_out    : signed(7 downto 0);
    signal rq_vo     : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Decodificacion de cfg_ksize / cfg_pad / cfg_stride (mux puro)
    ---------------------------------------------------------------------------
    kh_size    <= to_unsigned(1, 10) when cfg_ksize = "00" else to_unsigned(3, 10);
    kw_size    <= to_unsigned(1, 10) when cfg_ksize = "00" else to_unsigned(3, 10);
    pad_val    <= to_unsigned(1, 10) when cfg_pad = '1'    else to_unsigned(0, 10);
    stride_val <= to_unsigned(2, 10) when cfg_stride = '1' else to_unsigned(1, 10);

    ---------------------------------------------------------------------------
    -- Instancias reusadas de v1 (NO se tocan)
    ---------------------------------------------------------------------------
    u_mac : entity work.mac_array
        port map (clk=>clk, rst_n=>rst_n, a_in=>mac_a, b_in=>mac_b,
                  bias_in=>mac_bi, valid_in=>mac_vi, load_bias=>mac_lb,
                  clear=>mac_clr, acc_out=>mac_acc, valid_out=>open);

    u_rq : entity work.requantize
        port map (clk=>clk, rst_n=>rst_n, acc_in=>rq_acc_in, valid_in=>rq_vi,
                  M0=>cfg_M0, n_shift=>cfg_n_shift, y_zp=>cfg_y_zp,
                  y_out=>rq_out, valid_out=>rq_vo);

    ---------------------------------------------------------------------------
    -- DEBUG (combinacional)
    ---------------------------------------------------------------------------
    dbg_state        <= state_t'pos(state);
    dbg_oh           <= oh;
    dbg_ow           <= ow;
    dbg_kh           <= kh;
    dbg_kw           <= kw;
    dbg_ic           <= ic;
    dbg_oc_tile_base <= oc_tile_base;
    dbg_ic_tile_base <= ic_tile_base;
    dbg_w_base       <= w_base_idx_r;
    dbg_mac_a        <= mac_a;
    dbg_mac_b        <= mac_b;
    dbg_mac_bi       <= mac_bi;
    dbg_mac_acc      <= mac_acc;
    dbg_mac_vi       <= mac_vi;
    dbg_mac_clr      <= mac_clr;
    dbg_mac_lb       <= mac_lb;
    dbg_pad          <= pad_saved;
    dbg_act_addr     <= act_addr_r;

    ---------------------------------------------------------------------------
    -- FSM PRINCIPAL
    ---------------------------------------------------------------------------
    p_fsm : process(clk)
        variable v_ih       : signed(10 downto 0);
        variable v_iw       : signed(10 downto 0);
        variable v_h_dim    : signed(10 downto 0);
        variable v_w_dim    : signed(10 downto 0);
        variable v_limit    : unsigned(9 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state <= IDLE;
                done <= '0'; busy <= '0';
                ddr_rd_addr <= (others=>'0'); ddr_rd_en <= '0';
                ddr_wr_addr <= (others=>'0'); ddr_wr_data <= (others=>'0'); ddr_wr_en <= '0';
                mac_a <= (others=>'0'); mac_b <= (others=>(others=>'0'));
                mac_bi <= (others=>(others=>'0'));
                mac_vi <= '0'; mac_lb <= '0'; mac_clr <= '0';
                rq_acc_in <= (others=>'0'); rq_vi <= '0';
                kk_reg <= (others=>'0'); hw_reg <= (others=>'0');
                hw_out_reg <= (others=>'0');
                h_out_reg <= (others=>'0'); w_out_reg <= (others=>'0');
                h_dim_r <= (others=>'0'); w_dim_r <= (others=>'0');
                w_per_filter_full <= (others=>'0');
                tile_filter_stride <= (others=>'0');
                kw_cin_reg <= (others=>'0');
                oc_tile_base <= (others=>'0');
                ic_tile_base <= (others=>'0');
                ic_in_tile_limit <= (others=>'0');
                wl_i <= (others=>'0'); wl_kh <= (others=>'0');
                wl_kw <= (others=>'0'); wl_j <= (others=>'0');
                wl_ddr_addr <= (others=>'0'); wl_buf_addr <= (others=>'0');
                wl_oc_base_addr <= (others=>'0');
                bias_word_idx <= (others=>'0'); bias_byte_idx <= (others=>'0');
                bias_shift_reg <= (others=>'0'); bias_addr_r <= (others=>'0');
                oh <= (others=>'0'); ow <= (others=>'0');
                kh <= (others=>'0'); kw <= (others=>'0'); ic <= (others=>'0');
                rq_ch <= (others=>'0'); rq_wr_addr_r <= (others=>'0');
                pad_saved <= '0';
                ih_base_r <= (others=>'0'); iw_base_r <= (others=>'0');
                temp_ihb_w <= (others=>'0'); temp_oh_w <= (others=>'0');
                act_pixel_base <= (others=>'0');
                act_tile_base <= (others=>'0');
                act_ic_offset <= (others=>'0'); act_kh_offset <= (others=>'0');
                act_addr_r <= (others=>'0'); w_base_idx_r <= (others=>'0');
                wload_cnt <= (others=>'0'); wload_addr_r <= (others=>'0');
            else
                -- Defaults de un solo pulso
                ddr_rd_en <= '0'; ddr_wr_en <= '0';
                mac_vi <= '0'; mac_lb <= '0'; mac_clr <= '0';
                rq_vi <= '0'; done <= '0';

                case state is

                when IDLE =>
                    busy <= '0';
                    if start = '1' then
                        busy  <= '1';
                        state <= CALC_KK;
                    end if;

                ---------------------------------------------------------------
                -- PRE-COMPUTO (1 vez por capa)
                ---------------------------------------------------------------
                when CALC_KK =>
                    kk_reg <= resize(kh_size * kw_size, 20);
                    state  <= CALC_HOUT_1;

                when CALC_HOUT_1 =>
                    v_h_dim := signed('0' & std_logic_vector(cfg_h_in))
                             + signed('0' & std_logic_vector(shift_left(pad_val, 1)))
                             - signed('0' & std_logic_vector(kh_size));
                    v_w_dim := signed('0' & std_logic_vector(cfg_w_in))
                             + signed('0' & std_logic_vector(shift_left(pad_val, 1)))
                             - signed('0' & std_logic_vector(kw_size));
                    h_dim_r <= unsigned(v_h_dim(9 downto 0));
                    w_dim_r <= unsigned(v_w_dim(9 downto 0));
                    state   <= CALC_HOUT_2;

                when CALC_HOUT_2 =>
                    if cfg_stride = '1' then
                        h_out_reg <= shift_right(h_dim_r, 1) + 1;
                        w_out_reg <= shift_right(w_dim_r, 1) + 1;
                    else
                        h_out_reg <= h_dim_r + 1;
                        w_out_reg <= w_dim_r + 1;
                    end if;
                    state <= CALC_HW;

                when CALC_HW =>
                    hw_reg <= resize(cfg_h_in * cfg_w_in, 20);
                    state  <= CALC_HW_OUT;

                when CALC_HW_OUT =>
                    hw_out_reg <= resize(h_out_reg * w_out_reg, 20);
                    state      <= CALC_W_FILTER;

                -- stride de un filtro completo en DDR (para saltar de un oc al siguiente)
                when CALC_W_FILTER =>
                    w_per_filter_full <= resize(cfg_c_in * kk_reg, 20);
                    state             <= CALC_TILE_STRIDE;

                -- stride de un filtro dentro del weight_buf (solo el tile)
                when CALC_TILE_STRIDE =>
                    tile_filter_stride <= resize(cfg_ic_tile_size * kk_reg, 20);
                    state              <= CALC_KW_CIN;

                -- kw_size × c_in (para saltar de un kh al siguiente en DDR,
                -- informativo: no se usa directamente porque el salto entre
                -- kw y kh del tile se hace con (c_in - ic_in_tile_limit))
                when CALC_KW_CIN =>
                    kw_cin_reg   <= resize(kw_size * cfg_c_in, 20);
                    oc_tile_base <= (others => '0');
                    state        <= OC_TILE_START;

                ---------------------------------------------------------------
                -- INICIO DE UN OC_TILE
                -- Cargar bias[oc_tile_base..oc_tile_base+31] (128 bytes)
                ---------------------------------------------------------------
                when OC_TILE_START =>
                    bias_word_idx  <= (others => '0');
                    bias_byte_idx  <= (others => '0');
                    bias_shift_reg <= (others => '0');
                    -- addr_bias_tile = cfg_addr_bias + oc_tile_base * 4
                    -- (shift_left por 2 = ×4, no DSP)
                    bias_addr_r    <= cfg_addr_bias
                                    + resize(shift_left(oc_tile_base, 2), 25);
                    state          <= BL_EMIT;

                when BL_EMIT =>
                    if bias_word_idx < to_unsigned(N_MAC, 10) then
                        ddr_rd_addr <= bias_addr_r;
                        ddr_rd_en   <= '1';
                        state       <= BL_WAIT;
                    else
                        oh    <= (others => '0');
                        state <= INIT_ROW;
                    end if;

                when BL_WAIT =>
                    state <= BL_CAPTURE;

                when BL_CAPTURE =>
                    bias_shift_reg <= ddr_rd_data & bias_shift_reg(31 downto 8);
                    bias_addr_r    <= bias_addr_r + 1;
                    if bias_byte_idx = "11" then
                        bias_buf(to_integer(bias_word_idx)) <=
                            signed(ddr_rd_data & bias_shift_reg(31 downto 8));
                        bias_byte_idx <= (others => '0');
                        bias_word_idx <= bias_word_idx + 1;
                    else
                        bias_byte_idx <= bias_byte_idx + 1;
                    end if;
                    state <= BL_EMIT;

                ---------------------------------------------------------------
                -- PIXEL (dentro del oc_tile)
                ---------------------------------------------------------------
                when INIT_ROW =>
                    ow    <= (others => '0');
                    state <= INIT_PIXEL_1;

                -- INIT_PIXEL_1: clear MAC + bases
                -- 1 mult: oh × w_out_reg
                when INIT_PIXEL_1 =>
                    mac_clr <= '1';
                    kh <= (others => '0');
                    kw <= (others => '0');
                    ic <= (others => '0');
                    mac_bi <= bias_buf;
                    w_base_idx_r <= (others => '0');
                    ic_tile_base <= (others => '0');

                    temp_oh_w <= resize(oh * w_out_reg, 20);

                    if cfg_stride = '1' then
                        ih_base_r <= signed('0' & std_logic_vector(shift_left(oh, 1)))
                                   - signed('0' & std_logic_vector(pad_val));
                        iw_base_r <= signed('0' & std_logic_vector(shift_left(ow, 1)))
                                   - signed('0' & std_logic_vector(pad_val));
                    else
                        ih_base_r <= signed('0' & std_logic_vector(oh))
                                   - signed('0' & std_logic_vector(pad_val));
                        iw_base_r <= signed('0' & std_logic_vector(ow))
                                   - signed('0' & std_logic_vector(pad_val));
                    end if;

                    state <= INIT_PIXEL_2;

                -- INIT_PIXEL_2: mult para act base + sumas para RQ base
                -- 1 mult: ih_base × w_in
                when INIT_PIXEL_2 =>
                    temp_ihb_w <= resize(unsigned(ih_base_r(9 downto 0)) * cfg_w_in, 20);
                    -- rq_wr_base = cfg_addr_output
                    --            + oc_tile_base × hw_out_reg     (desplazamiento oc_tile)
                    --            + temp_oh_w + ow
                    -- Usamos act_tile_base como scratch temporal para
                    -- guardar oc_tile_base × hw_out_reg (via un incremento
                    -- posterior, pero aqui basta con la suma directa en RQ).
                    rq_wr_addr_r <= cfg_addr_output
                        + resize(temp_oh_w, 25) + resize(ow, 25);
                    state <= INIT_PIXEL_3;

                -- INIT_PIXEL_3: ensamblar act_pixel_base + reset offsets
                when INIT_PIXEL_3 =>
                    act_pixel_base <= cfg_addr_input
                        + resize(temp_ihb_w, 25)
                        + resize(unsigned(iw_base_r(9 downto 0)), 25);

                    act_tile_base <= (others => '0');
                    act_ic_offset <= (others => '0');
                    act_kh_offset <= (others => '0');

                    state <= BIAS_LOAD;

                when BIAS_LOAD =>
                    mac_lb <= '1';
                    -- Arrancar la carga de pesos del primer ic_tile
                    state  <= WL_NEXT;

                ---------------------------------------------------------------
                -- CARGA DE PESOS DEL TILE (oc_tile, ic_tile) AL weight_buf
                --
                -- Para cada i in 0..N_MAC-1 (oc dentro del tile):
                --   addr_DDR del filtro = cfg_addr_weights
                --                       + (oc_tile_base + i) × w_per_filter_full
                --   para cada kh, kw, j (j in 0..ic_in_tile_limit-1):
                --     DDR[base + kh*kw*c_in + kw*c_in + ic_tile_base + j]
                --     → weight_buf[i*tile_filter_stride + kh*kw*ic_tile_size + kw*ic_tile_size + j]
                --
                -- Implementacion con 4 contadores incrementales.
                -- Avance de wl_ddr_addr:
                --   +1 en cada byte del mismo kw
                --   +ic_skip_reg al terminar un kw (saltar c_in-ic_tile_size)
                --   (al terminar un kh, el salto ya esta implicito: se
                --    queda la suma acumulada, no hace falta skip extra)
                --   al cambiar de i, se recalcula desde wl_oc_base_addr
                --
                -- Avance de wl_buf_addr:
                --   +1 por cada byte escrito
                --   al terminar un filtro i, se reinicia a (i+1)*tile_filter_stride
                --   → mas facil: mantener un contador separado wl_buf_addr += 1
                --     y resetearlo a (i+1)*tile_filter_stride cuando cambiamos
                --     de filtro. O simplemente avanzar siempre +1 porque el
                --     layout en buf es compacto (i, kh, kw, j) ⇒ stride 1.
                --     Esto funciona porque tile_filter_stride = ic_tile_size*kk
                --     y recorremos exactamente eso por filtro.
                ---------------------------------------------------------------

                when WL_NEXT =>
                    -- Inicializacion al entrar en un nuevo tile
                    -- (viene de BIAS_LOAD o de IC_TILE_ADV)
                    -- ic_in_tile_limit = min(ic_tile_size, c_in - ic_tile_base)
                    if (cfg_c_in - ic_tile_base) < cfg_ic_tile_size then
                        v_limit := cfg_c_in - ic_tile_base;
                    else
                        v_limit := cfg_ic_tile_size(9 downto 0);
                    end if;
                    ic_in_tile_limit <= v_limit;

                    -- Direccion base en DDR del oc_tile_base (filtro 0 del tile)
                    -- wl_oc_base_addr = cfg_addr_weights
                    --                 + oc_tile_base × w_per_filter_full
                    -- (1 mult, solo 1 vez por oc_tile; NO depende de ic_tile
                    --  asi que en realidad bastaria con calcularlo en
                    --  OC_TILE_START, pero aqui es inocuo y lo hace mas legible)
                    wl_oc_base_addr <= cfg_addr_weights
                        + resize(oc_tile_base * w_per_filter_full, 25);

                    -- Arrancar contadores de carga
                    wl_i        <= (others => '0');
                    wl_kh       <= (others => '0');
                    wl_kw       <= (others => '0');
                    wl_j        <= (others => '0');
                    wl_buf_addr <= (others => '0');

                    -- Direccion DDR del primer byte del tile:
                    --   wl_oc_base_addr (se asigna en este mismo ciclo) aun
                    --   no esta disponible aqui. Lo calculamos en paralelo.
                    -- NOTA: el mult oc_tile_base × w_per_filter_full se hace
                    -- arriba Y abajo → serian 2 mults en este ciclo. Para
                    -- evitarlo, pasamos por un estado intermedio: WL_NEXT solo
                    -- lanza el calculo base, y WL_EMIT inicializa wl_ddr_addr
                    -- en el primer ciclo. Aqui solo marcamos el arranque.
                    state <= WL_EMIT;

                when WL_EMIT =>
                    if wl_i < to_unsigned(N_MAC, 6) then
                        -- Primera lectura del tile: inicializar wl_ddr_addr
                        -- (usa wl_oc_base_addr ya registrado de WL_NEXT)
                        if wl_kh = 0 and wl_kw = 0 and wl_j = 0 and wl_i = 0 then
                            wl_ddr_addr <= wl_oc_base_addr + resize(ic_tile_base, 25);
                            ddr_rd_addr <= wl_oc_base_addr + resize(ic_tile_base, 25);
                        else
                            ddr_rd_addr <= wl_ddr_addr;
                        end if;
                        ddr_rd_en <= '1';
                        state     <= WL_WAIT;
                    else
                        -- Tile cargado al buf: arrancar MAC loop
                        kh <= (others => '0');
                        kw <= (others => '0');
                        ic <= (others => '0');
                        w_base_idx_r <= (others => '0');
                        -- act_ic_offset ya refleja el ic_tile_base via act_tile_base
                        act_ic_offset <= act_tile_base;
                        act_kh_offset <= (others => '0');
                        state <= MAC_PAD_REG;
                    end if;

                when WL_WAIT =>
                    state <= WL_CAPTURE;

                when WL_CAPTURE =>
                    weight_buf(to_integer(wl_buf_addr)) <= signed(ddr_rd_data);
                    wl_buf_addr <= wl_buf_addr + 1;

                    -- Avance de contadores (j → kw → kh → i)
                    -- Solo 1 suma de 25 bits en cada rama (no mult).
                    if wl_j < ic_in_tile_limit - 1 then
                        wl_j        <= wl_j + 1;
                        wl_ddr_addr <= wl_ddr_addr + 1;
                    elsif wl_kw < kw_size - 1 then
                        wl_j        <= (others => '0');
                        wl_kw       <= wl_kw + 1;
                        -- Saltar los ic fuera del tile: +(c_in - ic_tile_size) + 1
                        -- El +1 del final de j se incluye saltando (c_in - limit + 1)
                        wl_ddr_addr <= wl_ddr_addr + 1
                                     + resize(cfg_c_in - ic_in_tile_limit, 25);
                    elsif wl_kh < kh_size - 1 then
                        wl_j        <= (others => '0');
                        wl_kw       <= (others => '0');
                        wl_kh       <= wl_kh + 1;
                        wl_ddr_addr <= wl_ddr_addr + 1
                                     + resize(cfg_c_in - ic_in_tile_limit, 25);
                    else
                        -- Cambiar de filtro i: nueva base = old_oc_base + (i+1)*w_per_filter
                        -- Usamos incremento: wl_oc_base_addr += w_per_filter_full
                        wl_j  <= (others => '0');
                        wl_kw <= (others => '0');
                        wl_kh <= (others => '0');
                        wl_i  <= wl_i + 1;
                        wl_oc_base_addr <= wl_oc_base_addr + resize(w_per_filter_full, 25);
                        -- reposicionar wl_ddr_addr a base del filtro (i+1) + ic_tile_base
                        wl_ddr_addr <= wl_oc_base_addr + resize(w_per_filter_full, 25)
                                     + resize(ic_tile_base, 25);
                    end if;
                    state <= WL_EMIT;

                ---------------------------------------------------------------
                -- MAC LOOP (igual que v1 pero sobre el ic_tile)
                ---------------------------------------------------------------
                when MAC_PAD_REG =>
                    -- Padding check (sumas de 11 bits)
                    v_ih := ih_base_r + signed('0' & std_logic_vector(kh));
                    v_iw := iw_base_r + signed('0' & std_logic_vector(kw));

                    if v_ih < 0 or v_ih >= signed('0' & std_logic_vector(cfg_h_in))
                       or v_iw < 0 or v_iw >= signed('0' & std_logic_vector(cfg_w_in)) then
                        pad_saved <= '1';
                    else
                        pad_saved <= '0';
                    end if;

                    -- Direccion de activacion: solo sumas (0 mults)
                    act_addr_r <= act_pixel_base
                                + act_ic_offset
                                + act_kh_offset
                                + resize(kw, 25);

                    wload_cnt    <= (others => '0');
                    wload_addr_r <= w_base_idx_r;
                    state        <= MAC_WLOAD;

                when MAC_WLOAD =>
                    -- Peso del filtro i dentro del tile: base + i*tile_filter_stride
                    mac_b(to_integer(wload_cnt)) <= weight_buf(to_integer(wload_addr_r));
                    wload_addr_r <= wload_addr_r + tile_filter_stride;
                    wload_cnt    <= wload_cnt + 1;

                    if wload_cnt = to_unsigned(N_MAC - 1, 6) then
                        state <= MAC_EMIT;
                    end if;

                when MAC_EMIT =>
                    if pad_saved = '0' then
                        ddr_rd_addr <= act_addr_r;
                        ddr_rd_en   <= '1';
                    end if;
                    state <= MAC_WAIT_DDR;

                when MAC_WAIT_DDR =>
                    state <= MAC_CAPTURE;

                when MAC_CAPTURE =>
                    if pad_saved = '1' then
                        mac_a <= (others => '0');
                    else
                        mac_a <= resize(signed(ddr_rd_data), 9) - resize(cfg_x_zp, 9);
                    end if;
                    state <= MAC_FIRE;

                -- MAC_FIRE: pulsar MAC + avanzar contadores
                -- El MAC loop recorre SOLO el tile: ic in [0, ic_in_tile_limit)
                when MAC_FIRE =>
                    mac_vi       <= '1';
                    w_base_idx_r <= w_base_idx_r + 1;

                    if ic < ic_in_tile_limit - 1 then
                        ic            <= ic + 1;
                        act_ic_offset <= act_ic_offset + resize(hw_reg, 25);
                        state         <= MAC_PAD_REG;

                    elsif kw < kw_size - 1 then
                        ic            <= (others => '0');
                        kw            <= kw + 1;
                        -- Reset act_ic_offset al principio del tile (act_tile_base)
                        act_ic_offset <= act_tile_base;
                        state         <= MAC_PAD_REG;

                    elsif kh < kh_size - 1 then
                        ic            <= (others => '0');
                        kw            <= (others => '0');
                        kh            <= kh + 1;
                        act_ic_offset <= act_tile_base;
                        act_kh_offset <= act_kh_offset + resize(cfg_w_in, 25);
                        state         <= MAC_PAD_REG;

                    else
                        -- Tile procesado: avanzar al siguiente ic_tile o requantize
                        state <= IC_TILE_ADV;
                    end if;

                ---------------------------------------------------------------
                -- AVANZAR AL SIGUIENTE IC_TILE (sin clear del MAC array)
                ---------------------------------------------------------------
                when IC_TILE_ADV =>
                    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
                        -- Hay mas ic tiles en este pixel
                        ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
                        -- Actualizar act_tile_base: +ic_tile_size × hw_reg
                        -- 1 mult de 10×20, 1 vez por ic_tile (aceptable)
                        act_tile_base <= act_tile_base
                                       + resize(cfg_ic_tile_size * hw_reg, 25);
                        -- Relanzar carga de pesos del siguiente tile
                        state <= WL_NEXT;
                    else
                        -- Todos los ic_tiles del pixel completados
                        rq_ch <= (others => '0');
                        state <= MAC_DONE_WAIT;
                    end if;

                ---------------------------------------------------------------
                -- DRENAR PIPELINE MAC (2 ciclos)
                ---------------------------------------------------------------
                when MAC_DONE_WAIT =>
                    state <= MAC_DONE_WAIT2;

                when MAC_DONE_WAIT2 =>
                    state <= RQ_EMIT;

                ---------------------------------------------------------------
                -- REQUANTIZE + ESCRITURA DDR
                -- Al ser oc_tile_size = N_MAC = 32, escribimos 32 bytes
                -- contiguos en el plano de canales que empieza en
                -- cfg_addr_output + oc_tile_base × hw_out_reg + pixel_offset
                -- El primer pixel del tile ya tiene rq_wr_addr_r apuntando al
                -- pixel. Falta añadir el oc_tile offset → lo metemos aqui la
                -- primera vez.
                -- Cada incremento entre canales: +hw_out_reg (1 suma).
                ---------------------------------------------------------------
                when RQ_EMIT =>
                    if rq_ch = 0 then
                        -- Añadir al rq_wr_addr_r el offset del oc_tile.
                        -- Esto se hace 1 vez por pixel (al empezar la salida
                        -- del pixel para este oc_tile). Usamos 1 mult aqui
                        -- oc_tile_base × hw_out_reg (10×20, 1 vez por pixel).
                        -- NOTA: reemplazamos rq_wr_addr_r por su valor +offset.
                        -- Como el pipeline MAC ya esta drenado, podemos hacer
                        -- esta asignacion sin afectar la ruta critica.
                        -- Sin embargo para mantener 1 mult/ciclo: la mult se
                        -- hace aqui sola, y el reloj siguiente ya esta listo.
                        rq_wr_addr_r <= rq_wr_addr_r
                                      + resize(oc_tile_base * hw_out_reg, 25);
                        -- No emitimos aun: esperamos 1 ciclo a que la mult
                        -- se registre → forzar estado de paso.
                        -- Para simplificar: en este mismo ciclo emitimos la
                        -- primera requantize con el valor VIEJO de rq_wr_addr_r.
                        -- Pero el write no se hace hasta RQ_CAPTURE, donde
                        -- rq_wr_addr_r ya reflejara el valor sumado.
                        rq_acc_in <= mac_acc(0);
                        rq_vi     <= '1';
                        rq_ch     <= rq_ch + 1;
                        state     <= RQ_CAPTURE;
                    elsif rq_ch < to_unsigned(N_MAC, 10) then
                        rq_acc_in <= mac_acc(to_integer(rq_ch));
                        rq_vi     <= '1';
                        rq_ch     <= rq_ch + 1;
                        state     <= RQ_CAPTURE;
                    else
                        state <= NEXT_PIXEL;
                    end if;

                when RQ_CAPTURE =>
                    if rq_vo = '1' then
                        ddr_wr_addr  <= rq_wr_addr_r;
                        ddr_wr_data  <= std_logic_vector(rq_out);
                        ddr_wr_en    <= '1';
                        rq_wr_addr_r <= rq_wr_addr_r + resize(hw_out_reg, 25);
                        state        <= RQ_EMIT;
                    end if;

                ---------------------------------------------------------------
                -- SIGUIENTE PIXEL (mismo oc_tile) o SIGUIENTE OC_TILE
                ---------------------------------------------------------------
                when NEXT_PIXEL =>
                    if ow < w_out_reg - 1 then
                        ow    <= ow + 1;
                        state <= INIT_PIXEL_1;
                    elsif oh < h_out_reg - 1 then
                        oh    <= oh + 1;
                        state <= INIT_ROW;
                    else
                        state <= OC_TILE_ADV;
                    end if;

                when OC_TILE_ADV =>
                    if (oc_tile_base + N_MAC) < cfg_c_out then
                        oc_tile_base <= oc_tile_base + to_unsigned(N_MAC, 10);
                        state <= OC_TILE_START;
                    else
                        state <= DONE_ST;
                    end if;

                when DONE_ST =>
                    done <= '1';
                    busy <= '0';
                    state <= IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
