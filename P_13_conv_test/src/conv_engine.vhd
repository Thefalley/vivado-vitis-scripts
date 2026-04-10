-------------------------------------------------------------------------------
-- conv_engine.vhd — Motor de convolucion con FSM
-------------------------------------------------------------------------------
--
-- REGLA: maximo 1 multiplicacion por ciclo por path serial.
-- Todas las direcciones del loop MAC usan contadores incrementales
-- (solo sumas de 25 bits, 0 multiplicaciones).
-- Las constantes de capa se pre-computan en CALC_* al inicio (1 mult cada).
-- Los pesos se leen secuencialmente (1 por ciclo, 1 BRAM port).
--
-- LATENCIA POR PIXEL (layer_005, 3×3×3 kernel, 32 filtros):
--   INIT:   3 ciclos (INIT_PIXEL_1 + _2 + _3)
--   BIAS:   1 ciclo
--   MAC:    27 × (1 + 32 + 4) = 27 × 37 = 999 ciclos
--           (MAC_PAD_REG + 32×MAC_WLOAD + EMIT+WAIT+CAPTURE+FIRE)
--   DRAIN:  2 ciclos
--   RQ:     32 × ~10 = 320 ciclos
--   Total:  ~1325 ciclos por pixel
--
-- DDR: latencia 1 ciclo. EMIT → WAIT → CAPTURE.
-- RESET: sincrono.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity conv_engine is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
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
        start     : in  std_logic;
        done      : out std_logic;
        busy      : out std_logic;
        ddr_rd_addr : out unsigned(24 downto 0);
        ddr_rd_data : in  std_logic_vector(7 downto 0);
        ddr_rd_en   : out std_logic;
        ddr_wr_addr : out unsigned(24 downto 0);
        ddr_wr_data : out std_logic_vector(7 downto 0);
        ddr_wr_en   : out std_logic
    );
end entity conv_engine;

architecture rtl of conv_engine is

    constant WB_SIZE : natural := 32768;

    type state_t is (
        IDLE,
        -- Pre-computo (1 mult max por estado, 1 vez por capa)
        CALC_KK,        -- kk_reg = kh_size × kw_size
        CALC_HOUT_1,    -- h_dim, w_dim = h_in + 2*pad - kh (sumas, 0 mults)
        CALC_HOUT_2,    -- h_out = shift + add (0 mults, 0 divisiones)
        CALC_HW,        -- hw_reg = cfg_h_in × cfg_w_in
        CALC_HW_OUT,    -- hw_out_reg = h_out_reg × w_out_reg
        CALC_STRIDE,    -- w_stride = cfg_c_in × kk_reg
        CALC_TOTAL,     -- w_total = cfg_c_out × w_stride
        -- Pesos
        WL_EMIT, WL_WAIT, WL_CAPTURE,
        -- Bias (contador incremental)
        BL_EMIT, BL_WAIT, BL_CAPTURE,
        -- Pixel
        INIT_ROW,
        INIT_PIXEL_1,   -- clear MAC, ih/iw base, temp_oh_w (1 mult)
        INIT_PIXEL_2,   -- temp_ihb_w = ih_base × w_in (1 mult), rq_wr_base (sumas)
        INIT_PIXEL_3,   -- act_pixel_base (sumas), reset offsets
        BIAS_LOAD,
        -- MAC loop (0 multiplicaciones — solo sumas e incrementos)
        MAC_PAD_REG,    -- padding check + act_addr (sumas), init wload
        MAC_WLOAD,      -- 1 peso/ciclo del weight_buf (32 ciclos)
        MAC_EMIT, MAC_WAIT_DDR, MAC_CAPTURE, MAC_FIRE,
        -- MAC drain
        MAC_DONE_WAIT, MAC_DONE_WAIT2,
        -- Requantize (contador incremental)
        RQ_EMIT, RQ_CAPTURE,
        -- Final
        NEXT_PIXEL, DONE_ST
    );
    signal state : state_t;

    -- Dimensiones combinacionales (mux, 0 mults)
    signal kh_size, kw_size, pad_val, stride_val : unsigned(9 downto 0);

    -- Constantes pre-computadas (CALC_*)
    signal kk_reg      : unsigned(19 downto 0);
    signal hw_reg      : unsigned(19 downto 0);
    signal hw_out_reg  : unsigned(19 downto 0);
    signal h_out_reg   : unsigned(9 downto 0);
    signal w_out_reg   : unsigned(9 downto 0);
    signal h_dim_r     : unsigned(9 downto 0);   -- h_in + 2*pad - kh (registrado)
    signal w_dim_r     : unsigned(9 downto 0);   -- w_in + 2*pad - kw (registrado)
    signal w_stride_per_filter : unsigned(19 downto 0);
    signal w_idx, w_total : unsigned(19 downto 0);

    -- Contadores pixel/kernel
    signal oh, ow, kh, kw, ic : unsigned(9 downto 0);

    -- Bias DMA (contador incremental)
    signal bias_word_idx  : unsigned(9 downto 0);
    signal bias_byte_idx  : unsigned(1 downto 0);
    signal bias_shift_reg : std_logic_vector(31 downto 0);
    signal bias_addr_r    : unsigned(24 downto 0);

    -- Direccion activacion: contadores incrementales
    -- act_pixel_base: base del pixel (cfg_addr_input + ih_base*w_in + iw_base)
    -- act_ic_offset:  se incrementa +hw_reg cuando ic avanza
    -- act_kh_offset:  se incrementa +cfg_w_in cuando kh avanza
    -- act_addr_r = act_pixel_base + act_ic_offset + act_kh_offset + kw
    signal ih_base_r      : signed(10 downto 0);   -- oh*stride - pad
    signal iw_base_r      : signed(10 downto 0);   -- ow*stride - pad
    signal temp_ihb_w     : unsigned(19 downto 0);  -- |ih_base| × cfg_w_in
    signal temp_oh_w      : unsigned(19 downto 0);  -- oh × w_out (para RQ)
    signal act_pixel_base : unsigned(24 downto 0);
    signal act_ic_offset  : unsigned(24 downto 0);
    signal act_kh_offset  : unsigned(24 downto 0);
    signal act_addr_r     : unsigned(24 downto 0);

    -- Peso: contador incremental (+1 por paso MAC)
    signal w_base_idx_r : unsigned(19 downto 0);

    -- Carga secuencial de pesos
    signal wload_cnt    : unsigned(5 downto 0);
    signal wload_addr_r : unsigned(19 downto 0);

    -- Padding
    signal pad_saved : std_logic;

    -- Requantize: escritura incremental
    signal rq_ch        : unsigned(9 downto 0);
    signal rq_wr_addr_r : unsigned(24 downto 0);

    -- Buffers
    type weight_mem_t is array(0 to WB_SIZE-1) of signed(7 downto 0);
    signal weight_buf : weight_mem_t;
    signal bias_buf   : bias_array_t;

    -- MAC array
    signal mac_a   : signed(8 downto 0);
    signal mac_b   : weight_array_t;
    signal mac_bi  : bias_array_t;
    signal mac_vi, mac_lb, mac_clr : std_logic;
    signal mac_acc : acc_array_t;

    -- Requantize
    signal rq_acc_in : signed(31 downto 0);
    signal rq_vi     : std_logic;
    signal rq_out    : signed(7 downto 0);
    signal rq_vo     : std_logic;

begin

    kh_size    <= to_unsigned(1, 10) when cfg_ksize = "00" else to_unsigned(3, 10);
    kw_size    <= to_unsigned(1, 10) when cfg_ksize = "00" else to_unsigned(3, 10);
    pad_val    <= to_unsigned(1, 10) when cfg_pad = '1'    else to_unsigned(0, 10);
    stride_val <= to_unsigned(2, 10) when cfg_stride = '1' else to_unsigned(1, 10);

    u_mac : entity work.mac_array
        port map (clk=>clk, rst_n=>rst_n, a_in=>mac_a, b_in=>mac_b,
                  bias_in=>mac_bi, valid_in=>mac_vi, load_bias=>mac_lb,
                  clear=>mac_clr, acc_out=>mac_acc, valid_out=>open);

    u_rq : entity work.requantize
        port map (clk=>clk, rst_n=>rst_n, acc_in=>rq_acc_in, valid_in=>rq_vi,
                  M0=>cfg_M0, n_shift=>cfg_n_shift, y_zp=>cfg_y_zp,
                  y_out=>rq_out, valid_out=>rq_vo);

    p_fsm : process(clk)
        variable v_ih : signed(10 downto 0);
        variable v_iw : signed(10 downto 0);
        variable v_h_dim : signed(10 downto 0);
        variable v_w_dim : signed(10 downto 0);
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
                w_idx <= (others=>'0'); w_total <= (others=>'0');
                w_stride_per_filter <= (others=>'0');
                kk_reg <= (others=>'0'); hw_reg <= (others=>'0');
                hw_out_reg <= (others=>'0');
                h_out_reg <= (others=>'0'); w_out_reg <= (others=>'0');
                h_dim_r <= (others=>'0'); w_dim_r <= (others=>'0');
                bias_word_idx <= (others=>'0'); bias_byte_idx <= (others=>'0');
                bias_shift_reg <= (others=>'0'); bias_addr_r <= (others=>'0');
                oh <= (others=>'0'); ow <= (others=>'0');
                kh <= (others=>'0'); kw <= (others=>'0'); ic <= (others=>'0');
                rq_ch <= (others=>'0'); rq_wr_addr_r <= (others=>'0');
                pad_saved <= '0';
                ih_base_r <= (others=>'0'); iw_base_r <= (others=>'0');
                temp_ihb_w <= (others=>'0'); temp_oh_w <= (others=>'0');
                act_pixel_base <= (others=>'0');
                act_ic_offset <= (others=>'0'); act_kh_offset <= (others=>'0');
                act_addr_r <= (others=>'0'); w_base_idx_r <= (others=>'0');
                wload_cnt <= (others=>'0'); wload_addr_r <= (others=>'0');
            else
                ddr_rd_en <= '0'; ddr_wr_en <= '0';
                mac_vi <= '0'; mac_lb <= '0'; mac_clr <= '0';
                rq_vi <= '0'; done <= '0';

                case state is

                when IDLE =>
                    busy <= '0';
                    if start = '1' then
                        busy  <= '1';
                        w_idx <= (others => '0');
                        state <= CALC_KK;
                    end if;

                ---------------------------------------------------------------
                -- PRE-COMPUTO (1 vez por capa)
                ---------------------------------------------------------------

                -- CALC_KK: solo kk_reg (1 mult: 10×10)
                when CALC_KK =>
                    kk_reg <= resize(kh_size * kw_size, 20);
                    state  <= CALC_HOUT_1;

                -- CALC_HOUT_1: dim = h_in + 2*pad - kh_size (sumas, 0 mults)
                -- Usa signed para evitar underflow unsigned.
                -- '2*pad' se hace con shift_left (no multiplicador).
                when CALC_HOUT_1 =>
                    v_h_dim := signed('0' & std_logic_vector(cfg_h_in))
                             + signed('0' & std_logic_vector(shift_left(pad_val, 1)))
                             - signed('0' & std_logic_vector(kh_size));
                    v_w_dim := signed('0' & std_logic_vector(cfg_w_in))
                             + signed('0' & std_logic_vector(shift_left(pad_val, 1)))
                             - signed('0' & std_logic_vector(kw_size));
                    -- Registrar para usar en CALC_HOUT_2
                    h_dim_r <= unsigned(v_h_dim(9 downto 0));
                    w_dim_r <= unsigned(v_w_dim(9 downto 0));
                    state   <= CALC_HOUT_2;

                -- CALC_HOUT_2: h_out = dim/stride + 1 (shift + sum, 0 mults, 0 divisiones)
                -- shift_right(x, 1) es shift aritmetico → divide por 2 sin divisor HW.
                when CALC_HOUT_2 =>
                    if cfg_stride = '1' then
                        h_out_reg <= shift_right(h_dim_r, 1) + 1;
                        w_out_reg <= shift_right(w_dim_r, 1) + 1;
                    else
                        h_out_reg <= h_dim_r + 1;
                        w_out_reg <= w_dim_r + 1;
                    end if;
                    state <= CALC_HW;

                -- CALC_HW: hw_reg = h_in × w_in (1 mult: 10×10)
                when CALC_HW =>
                    hw_reg <= resize(cfg_h_in * cfg_w_in, 20);
                    state  <= CALC_HW_OUT;

                -- CALC_HW_OUT: hw_out_reg = h_out × w_out (1 mult: 10×10)
                when CALC_HW_OUT =>
                    hw_out_reg <= resize(h_out_reg * w_out_reg, 20);
                    state      <= CALC_STRIDE;

                -- CALC_STRIDE: w_stride = c_in × kk_reg (1 mult: 10×20)
                when CALC_STRIDE =>
                    w_stride_per_filter <= resize(cfg_c_in * kk_reg, 20);
                    state               <= CALC_TOTAL;

                -- CALC_TOTAL: w_total = c_out × w_stride (1 mult: 10×20)
                when CALC_TOTAL =>
                    w_total <= resize(cfg_c_out * w_stride_per_filter, 20);
                    state   <= WL_EMIT;

                ---------------------------------------------------------------
                -- CARGAR PESOS (0 multiplicaciones)
                ---------------------------------------------------------------
                when WL_EMIT =>
                    if w_idx < w_total then
                        ddr_rd_addr <= cfg_addr_weights + resize(w_idx, 25);
                        ddr_rd_en   <= '1';
                        state       <= WL_WAIT;
                    else
                        bias_word_idx  <= (others => '0');
                        bias_byte_idx  <= (others => '0');
                        bias_shift_reg <= (others => '0');
                        bias_addr_r    <= cfg_addr_bias;
                        state          <= BL_EMIT;
                    end if;

                when WL_WAIT =>
                    state <= WL_CAPTURE;

                when WL_CAPTURE =>
                    weight_buf(to_integer(w_idx)) <= signed(ddr_rd_data);
                    w_idx <= w_idx + 1;
                    state <= WL_EMIT;

                ---------------------------------------------------------------
                -- CARGAR BIAS (contador incremental, 0 mults)
                ---------------------------------------------------------------
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
                -- PIXEL
                ---------------------------------------------------------------
                when INIT_ROW =>
                    ow    <= (others => '0');
                    state <= INIT_PIXEL_1;

                -- INIT_PIXEL_1: clear MAC + calcular bases del pixel
                -- 1 mult: oh × w_out_reg (para RQ write addr)
                -- ih_base, iw_base: stride es 1 o 2 → shift+sub, no DSP
                when INIT_PIXEL_1 =>
                    mac_clr <= '1';
                    kh <= (others => '0');
                    kw <= (others => '0');
                    ic <= (others => '0');
                    mac_bi <= bias_buf;
                    w_base_idx_r <= (others => '0');

                    -- 1 mult para RQ
                    temp_oh_w <= resize(oh * w_out_reg, 20);

                    -- ih_base = oh*stride - pad (stride=1 o 2 → trivial)
                    -- iw_base = ow*stride - pad
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
                -- 1 mult: |ih_base| × cfg_w_in (10×10)
                -- Sumas (path independiente): rq_wr_addr_r = base + temp_oh_w + ow
                when INIT_PIXEL_2 =>
                    -- 1 mult: ih_base × w_in (para la base de activacion)
                    temp_ihb_w <= resize(unsigned(ih_base_r(9 downto 0)) * cfg_w_in, 20);

                    -- Sumas en path independiente: base de escritura RQ
                    rq_wr_addr_r <= cfg_addr_output
                        + resize(temp_oh_w, 25) + resize(ow, 25);

                    state <= INIT_PIXEL_3;

                -- INIT_PIXEL_3: ensamblar act_pixel_base (sumas) + reset offsets
                when INIT_PIXEL_3 =>
                    -- Base de activacion para este pixel (kh=0, kw=0, ic=0)
                    act_pixel_base <= cfg_addr_input
                        + resize(temp_ihb_w, 25)
                        + resize(unsigned(iw_base_r(9 downto 0)), 25);

                    -- Reset contadores incrementales
                    act_ic_offset  <= (others => '0');
                    act_kh_offset  <= (others => '0');

                    state <= BIAS_LOAD;

                when BIAS_LOAD =>
                    mac_lb <= '1';
                    state  <= MAC_PAD_REG;

                ---------------------------------------------------------------
                -- MAC LOOP: 0 MULTIPLICACIONES
                -- Todas las direcciones se calculan con sumas incrementales.
                ---------------------------------------------------------------

                -- MAC_PAD_REG: padding check + act_addr + iniciar carga pesos
                -- 0 mults. Sumas de 25 bits (carry chain ~4.5 ns, OK a 100 MHz).
                when MAC_PAD_REG =>
                    -- Padding: ih = ih_base + kh, iw = iw_base + kw
                    -- Solo sumas de 11 bits + comparaciones
                    v_ih := ih_base_r + signed('0' & std_logic_vector(kh));
                    v_iw := iw_base_r + signed('0' & std_logic_vector(kw));

                    if v_ih < 0 or v_ih >= signed('0' & std_logic_vector(cfg_h_in))
                       or v_iw < 0 or v_iw >= signed('0' & std_logic_vector(cfg_w_in)) then
                        pad_saved <= '1';
                    else
                        pad_saved <= '0';
                    end if;

                    -- Direccion activacion: solo sumas (0 mults!)
                    act_addr_r <= act_pixel_base
                        + act_ic_offset
                        + act_kh_offset
                        + resize(kw, 25);

                    -- Iniciar carga secuencial de pesos
                    wload_cnt    <= (others => '0');
                    wload_addr_r <= w_base_idx_r;
                    state        <= MAC_WLOAD;

                -- MAC_WLOAD: 1 peso por ciclo del weight_buf (32 ciclos)
                -- Usa 1 BRAM read port. Solo 1 suma por ciclo (incremental).
                when MAC_WLOAD =>
                    mac_b(to_integer(wload_cnt)) <= weight_buf(to_integer(wload_addr_r));
                    wload_addr_r <= wload_addr_r + w_stride_per_filter;
                    wload_cnt    <= wload_cnt + 1;

                    if wload_cnt = to_unsigned(N_MAC - 1, 6) then
                        state <= MAC_EMIT;
                    end if;

                -- MAC_EMIT: emitir lectura DDR de activacion
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
                        mac_a <= signed('0' & ddr_rd_data) - cfg_x_zp;
                    end if;
                    state <= MAC_FIRE;

                -- MAC_FIRE: pulsar MAC + actualizar contadores incrementales
                -- Cada rama tiene maximo 1 suma de 25 bits.
                when MAC_FIRE =>
                    mac_vi       <= '1';
                    w_base_idx_r <= w_base_idx_r + 1;  -- peso: siempre +1

                    if ic < cfg_c_in - 1 then
                        -- ic avanza: act_ic_offset += hw_reg
                        ic            <= ic + 1;
                        act_ic_offset <= act_ic_offset + resize(hw_reg, 25);
                        state         <= MAC_PAD_REG;

                    elsif kw < kw_size - 1 then
                        -- kw avanza, ic reset: act_ic_offset = 0
                        ic            <= (others => '0');
                        kw            <= kw + 1;
                        act_ic_offset <= (others => '0');
                        state         <= MAC_PAD_REG;

                    elsif kh < kh_size - 1 then
                        -- kh avanza, ic+kw reset: offsets reset/increment
                        ic            <= (others => '0');
                        kw            <= (others => '0');
                        kh            <= kh + 1;
                        act_ic_offset <= (others => '0');
                        -- kh++: siguiente fila = +cfg_w_in
                        act_kh_offset <= act_kh_offset + resize(cfg_w_in, 25);
                        state         <= MAC_PAD_REG;

                    else
                        -- Todo el kernel procesado
                        rq_ch <= (others => '0');
                        state <= MAC_DONE_WAIT;
                    end if;

                ---------------------------------------------------------------
                -- ESPERAR PIPELINE MAC (2 etapas)
                ---------------------------------------------------------------
                when MAC_DONE_WAIT =>
                    state <= MAC_DONE_WAIT2;

                when MAC_DONE_WAIT2 =>
                    state <= RQ_EMIT;

                ---------------------------------------------------------------
                -- REQUANTIZE (contador incremental, 0 mults)
                ---------------------------------------------------------------
                when RQ_EMIT =>
                    if rq_ch < to_unsigned(N_MAC, 10) then
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
                        -- Incrementar para siguiente canal (1 suma)
                        rq_wr_addr_r <= rq_wr_addr_r + resize(hw_out_reg, 25);
                        state        <= RQ_EMIT;
                    end if;

                ---------------------------------------------------------------
                when NEXT_PIXEL =>
                    if ow < w_out_reg - 1 then
                        ow    <= ow + 1;
                        state <= INIT_PIXEL_1;
                    elsif oh < h_out_reg - 1 then
                        oh    <= oh + 1;
                        state <= INIT_ROW;
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
