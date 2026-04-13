-------------------------------------------------------------------------------
-- conv_simple.vhd — Motor de convolucion INT8, FSM minima
-------------------------------------------------------------------------------
-- P_700: implementacion lo mas simple posible.
-- Reutiliza mac_array (32 MACs, verificado) + requantize (verificado).
--
-- ARQUITECTURA:
--   - Todo en memoria byte-addressable con 1-cycle read latency (BRAM)
--   - Sin tiling, sin optimizaciones: claridad > velocidad
--   - FSM secuencial: 1 pixel a la vez, 32 output channels en paralelo
--   - Patron de lectura BRAM: EMIT(set addr) -> WAIT(latency) -> CAPTURE(read data)
--
-- LOOP ORDER: oh -> ow -> kh -> kw -> ic
--
-- WEIGHT LAYOUT (OIHW): weights[oc][ic][kh][kw]
--   Para un paso (kh, kw, ic), los 32 pesos de cada OC estan a stride w_per_filter
--   w_addr[oc] = base + oc * w_per_filter + kern_offset
--   kern_offset = ic * kk + kh * ksize + kw  (OIHW format)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity conv_simple is
    port (
        clk     : in  std_logic;
        rst_n   : in  std_logic;

        -- Control
        start   : in  std_logic;
        done    : out std_logic;
        busy    : out std_logic;

        -- Layer configuration (estable mientras busy='1')
        cfg_c_in    : in  unsigned(9 downto 0);
        cfg_c_out   : in  unsigned(9 downto 0);
        cfg_h_in    : in  unsigned(9 downto 0);
        cfg_w_in    : in  unsigned(9 downto 0);
        cfg_ksize   : in  unsigned(3 downto 0);
        cfg_stride  : in  unsigned(3 downto 0);
        cfg_pad     : in  unsigned(3 downto 0);
        cfg_x_zp    : in  signed(8 downto 0);
        cfg_M0      : in  unsigned(31 downto 0);
        cfg_n_shift : in  unsigned(5 downto 0);
        cfg_y_zp    : in  signed(7 downto 0);

        -- Direcciones base en memoria
        cfg_addr_input   : in  unsigned(15 downto 0);
        cfg_addr_weights : in  unsigned(15 downto 0);
        cfg_addr_bias    : in  unsigned(15 downto 0);
        cfg_addr_output  : in  unsigned(15 downto 0);

        -- Puerto lectura memoria (1-cycle latency: EMIT -> WAIT -> CAPTURE)
        mem_rd_addr : out unsigned(15 downto 0);
        mem_rd_en   : out std_logic;
        mem_rd_data : in  std_logic_vector(7 downto 0);

        -- Puerto escritura memoria
        mem_wr_addr : out unsigned(15 downto 0);
        mem_wr_data : out std_logic_vector(7 downto 0);
        mem_wr_en   : out std_logic;

        -- Debug
        dbg_state   : out std_logic_vector(4 downto 0);
        dbg_oh      : out unsigned(9 downto 0);
        dbg_ow      : out unsigned(9 downto 0)
    );
end entity conv_simple;

architecture rtl of conv_simple is

    ---------------------------------------------------------------------------
    -- FSM: 23 estados
    ---------------------------------------------------------------------------
    type state_t is (
        S_IDLE,
        S_PRE_1, S_PRE_2, S_PRE_3, S_PRE_4,
        S_BIAS_EMIT, S_BIAS_WAIT, S_BIAS_CAP,
        S_PIX_CLR, S_PIX_BIAS, S_PIX_CALC,
        S_KERN_ADDR,    -- check padding, compute ih*w_in (multiply)
        S_KERN_ADDR2,   -- add offsets to form final address (sums only)
        S_KERN_ACT_E, S_KERN_ACT_C,
        S_KERN_WT_E, S_KERN_WT_W, S_KERN_WT_C,
        S_KERN_FIRE,
        S_DRAIN,
        S_RQ_FEED, S_RQ_FLUSH,
        S_PIX_NEXT,
        S_DONE
    );
    signal state : state_t := S_IDLE;

    -- Precomputed
    signal kk_reg         : unsigned(7 downto 0);
    signal w_per_filter   : unsigned(19 downto 0);
    signal hw_in_reg      : unsigned(19 downto 0);
    signal hw_out_reg     : unsigned(19 downto 0);
    signal h_out_reg      : unsigned(9 downto 0);
    signal w_out_reg      : unsigned(9 downto 0);

    -- Bias
    signal bias_reg       : bias_array_t;
    signal bias_tmp       : std_logic_vector(31 downto 0);
    signal bias_ch        : unsigned(5 downto 0);
    signal bias_byte      : unsigned(1 downto 0);
    signal bias_addr      : unsigned(15 downto 0);

    -- Pixel
    signal oh, ow         : unsigned(9 downto 0);
    signal ih_base        : signed(10 downto 0);
    signal iw_base        : signed(10 downto 0);

    -- Kernel
    signal kh, kw         : unsigned(3 downto 0);
    signal ic             : unsigned(9 downto 0);
    signal kern_offset    : unsigned(19 downto 0);  -- OIHW: ic*kk + kh*ksize + kw
    signal ic_offset      : unsigned(19 downto 0);  -- ic * hw_in (activation addr)
    signal ic_wt_off      : unsigned(19 downto 0);  -- ic * kk (weight addr OIHW)
    signal kh_wt_off      : unsigned(19 downto 0);  -- kh * ksize (weight addr OIHW)

    -- Activation
    signal act_val        : signed(8 downto 0);
    signal ih_x_win       : unsigned(19 downto 0);  -- ih * w_in (pipelined)
    signal iw_reg         : unsigned(9 downto 0);   -- iw latched for addr2

    -- Weights
    signal w_reg          : weight_array_t;
    signal wt_cnt         : unsigned(5 downto 0);
    signal wt_addr        : unsigned(15 downto 0);

    -- Requantize
    signal rq_feed_cnt    : unsigned(5 downto 0);
    signal rq_write_cnt   : unsigned(5 downto 0);
    signal rq_out_addr    : unsigned(15 downto 0);
    signal rq_addr_step   : unsigned(15 downto 0);
    signal rq_acc_in      : signed(31 downto 0);
    signal rq_valid_in    : std_logic;
    signal rq_y_out       : signed(7 downto 0);
    signal rq_valid_out   : std_logic;

    -- MAC
    signal mac_a          : signed(8 downto 0);
    signal mac_b          : weight_array_t;
    signal mac_bi         : bias_array_t;
    signal mac_vi, mac_lb, mac_clr : std_logic;
    signal mac_acc        : acc_array_t;

    -- Misc
    signal drain_cnt      : unsigned(1 downto 0);

begin

    ---------------------------------------------------------------------------
    -- MAC ARRAY (32 MACs paralelos, verificado HW)
    ---------------------------------------------------------------------------
    u_mac : entity work.mac_array
        port map (
            clk => clk, rst_n => rst_n,
            a_in => mac_a, b_in => mac_b, bias_in => mac_bi,
            valid_in => mac_vi, load_bias => mac_lb, clear => mac_clr,
            acc_out => mac_acc, valid_out => open
        );

    ---------------------------------------------------------------------------
    -- REQUANTIZE (INT32 -> INT8, 8-stage pipeline, verificado HW)
    ---------------------------------------------------------------------------
    u_rq : entity work.requantize
        port map (
            clk => clk, rst_n => rst_n,
            acc_in => rq_acc_in, valid_in => rq_valid_in,
            M0 => cfg_M0, n_shift => cfg_n_shift, y_zp => cfg_y_zp,
            y_out => rq_y_out, valid_out => rq_valid_out
        );

    ---------------------------------------------------------------------------
    -- MAIN FSM
    ---------------------------------------------------------------------------
    p_fsm : process(clk)
        variable v_ih : signed(10 downto 0);
        variable v_iw : signed(10 downto 0);
    begin
        if rising_edge(clk) then
        if rst_n = '0' then
            state <= S_IDLE;
            done <= '0'; busy <= '0';
            mem_rd_en <= '0'; mem_wr_en <= '0';
            mac_vi <= '0'; mac_lb <= '0'; mac_clr <= '0';
            rq_valid_in <= '0';
        else
            -- Pulses default off
            mem_rd_en   <= '0';
            mem_wr_en   <= '0';
            mac_vi      <= '0';
            mac_lb      <= '0';
            mac_clr     <= '0';
            rq_valid_in <= '0';

            -- Requantize output: write to memory whenever valid
            if rq_valid_out = '1' and (state = S_RQ_FEED or state = S_RQ_FLUSH) then
                mem_wr_addr  <= rq_out_addr;
                mem_wr_data  <= std_logic_vector(rq_y_out);
                mem_wr_en    <= '1';
                rq_out_addr  <= rq_out_addr + rq_addr_step;
                rq_write_cnt <= rq_write_cnt + 1;
            end if;

            case state is

            -- =============================================================
            -- IDLE
            -- =============================================================
            when S_IDLE =>
                done <= '0'; busy <= '0';
                if start = '1' then
                    busy <= '1'; state <= S_PRE_1;
                end if;

            -- =============================================================
            -- PRECOMPUTE (1 mult por estado, max 4 estados)
            -- =============================================================
            when S_PRE_1 =>
                -- kk = ksize^2, h_out, w_out
                kk_reg    <= resize(cfg_ksize * cfg_ksize, 8);
                -- h_out = (h_in + 2*pad - ksize) / stride + 1
                h_out_reg <= resize(
                    (cfg_h_in + shift_left(resize(cfg_pad, 10), 1) - resize(cfg_ksize, 10))
                    / resize(cfg_stride, 10) + 1, 10);
                w_out_reg <= resize(
                    (cfg_w_in + shift_left(resize(cfg_pad, 10), 1) - resize(cfg_ksize, 10))
                    / resize(cfg_stride, 10) + 1, 10);
                state <= S_PRE_2;

            when S_PRE_2 =>
                w_per_filter <= resize(cfg_c_in * kk_reg, 20);
                state <= S_PRE_3;

            when S_PRE_3 =>
                hw_in_reg <= resize(cfg_h_in * cfg_w_in, 20);
                state <= S_PRE_4;

            when S_PRE_4 =>
                hw_out_reg   <= resize(h_out_reg * w_out_reg, 20);
                rq_addr_step <= resize(h_out_reg * w_out_reg, 16);
                bias_ch      <= (others => '0');
                bias_byte    <= (others => '0');
                bias_addr    <= cfg_addr_bias;
                state        <= S_BIAS_EMIT;

            -- =============================================================
            -- BIAS: leer 32 x int32 = 128 bytes (little-endian)
            -- Patron: EMIT -> WAIT -> CAPTURE (3 ciclos por byte)
            -- =============================================================
            when S_BIAS_EMIT =>
                mem_rd_addr <= bias_addr;
                mem_rd_en   <= '1';
                state       <= S_BIAS_WAIT;

            when S_BIAS_WAIT =>
                state <= S_BIAS_CAP;

            when S_BIAS_CAP =>
                -- Ensamblar byte en posicion correcta
                case bias_byte is
                    when "00" => bias_tmp(7 downto 0)   <= mem_rd_data;
                    when "01" => bias_tmp(15 downto 8)  <= mem_rd_data;
                    when "10" => bias_tmp(23 downto 16) <= mem_rd_data;
                    when others => null;  -- "11" handled below
                end case;

                bias_addr <= bias_addr + 1;

                if bias_byte = "11" then
                    -- 4o byte capturado: ensamblar int32 completo
                    bias_reg(to_integer(bias_ch)) <= signed(
                        mem_rd_data &           -- byte 3 (MSB)
                        bias_tmp(23 downto 16) &  -- byte 2
                        bias_tmp(15 downto 8)  &  -- byte 1
                        bias_tmp(7 downto 0));    -- byte 0 (LSB)
                    bias_byte <= "00";
                    if bias_ch = to_unsigned(N_MAC - 1, 6) then
                        oh <= (others => '0');
                        ow <= (others => '0');
                        state <= S_PIX_CLR;
                    else
                        bias_ch <= bias_ch + 1;
                        state   <= S_BIAS_EMIT;
                    end if;
                else
                    bias_byte <= bias_byte + 1;
                    state     <= S_BIAS_EMIT;
                end if;

            -- =============================================================
            -- PIXEL INIT: clear MACs, load bias, init kernel counters
            -- =============================================================
            when S_PIX_CLR =>
                mac_clr <= '1';
                mac_bi  <= bias_reg;
                ih_base <= resize(
                    signed('0' & oh) * signed('0' & cfg_stride)
                    - signed('0' & cfg_pad), 11);
                iw_base <= resize(
                    signed('0' & ow) * signed('0' & cfg_stride)
                    - signed('0' & cfg_pad), 11);
                state   <= S_PIX_BIAS;

            when S_PIX_BIAS =>
                mac_lb <= '1';
                state  <= S_PIX_CALC;

            when S_PIX_CALC =>
                kh          <= (others => '0');
                kw          <= (others => '0');
                ic          <= (others => '0');
                kern_offset <= (others => '0');
                ic_offset   <= (others => '0');
                ic_wt_off   <= (others => '0');
                kh_wt_off   <= (others => '0');
                state       <= S_KERN_ADDR;

            -- =============================================================
            -- KERNEL LOOP: (kh, kw, ic)
            -- =============================================================
            when S_KERN_ADDR =>
                -- Stage 1: padding check + multiply ih*w_in (DSP)
                -- Sums deferred to ADDR2 to break timing path
                v_ih := ih_base + signed(resize(kh, 11));
                v_iw := iw_base + signed(resize(kw, 11));

                -- OIHW weight offset: ic*kk + kh*ksize + kw
                kern_offset <= ic_wt_off + kh_wt_off + resize(kw, 20);

                -- Pipeline: register multiply + iw for next cycle
                ih_x_win <= resize(unsigned(v_ih(9 downto 0)) * cfg_w_in, 20);
                iw_reg   <= unsigned(v_iw(9 downto 0));

                if v_ih < 0 or v_ih >= signed('0' & cfg_h_in)
                   or v_iw < 0 or v_iw >= signed('0' & cfg_w_in) then
                    -- Padded: x_shifted = 0, skip activation read
                    act_val <= (others => '0');
                    wt_cnt  <= (others => '0');
                    -- wt_addr: sums only (no multiply, timing safe)
                    wt_addr <= resize(cfg_addr_weights
                               + ic_wt_off + kh_wt_off + resize(kw, 20), 16);
                    state   <= S_KERN_WT_E;
                else
                    state <= S_KERN_ADDR2;
                end if;

            when S_KERN_ADDR2 =>
                -- Stage 2: form address from registered values (sums only)
                mem_rd_addr <= resize(
                    cfg_addr_input + ic_offset + ih_x_win
                    + resize(iw_reg, 20), 16);
                mem_rd_en <= '1';
                state     <= S_KERN_ACT_E;

            -- Activation read: EMIT(KERN_ADDR) -> WAIT(ACT_E) -> CAPTURE(ACT_C)
            when S_KERN_ACT_E =>
                state <= S_KERN_ACT_C;

            when S_KERN_ACT_C =>
                act_val <= resize(signed(mem_rd_data), 9) - cfg_x_zp;
                wt_cnt  <= (others => '0');
                -- kern_offset was computed in S_KERN_ADDR (OIHW format)
                wt_addr <= resize(cfg_addr_weights + kern_offset, 16);
                state   <= S_KERN_WT_E;

            -- =============================================================
            -- WEIGHT LOAD: leer 32 bytes (uno por OC)
            -- Patron: EMIT -> WAIT -> CAPTURE, repetir 32 veces
            -- =============================================================
            when S_KERN_WT_E =>
                mem_rd_addr <= wt_addr;
                mem_rd_en   <= '1';
                state       <= S_KERN_WT_W;

            when S_KERN_WT_W =>
                state <= S_KERN_WT_C;

            when S_KERN_WT_C =>
                w_reg(to_integer(wt_cnt)) <= signed(mem_rd_data);
                wt_addr <= wt_addr + resize(w_per_filter, 16);
                if wt_cnt = to_unsigned(N_MAC - 1, 6) then
                    state <= S_KERN_FIRE;
                else
                    wt_cnt <= wt_cnt + 1;
                    state  <= S_KERN_WT_E;
                end if;

            -- =============================================================
            -- FIRE: pulsar MAC, avanzar contadores kernel
            -- =============================================================
            when S_KERN_FIRE =>
                mac_a  <= act_val;
                mac_b  <= w_reg;
                mac_vi <= '1';

                -- Advance kernel counters (kh -> kw -> ic)
                -- Weight layout is OIHW: offset = ic*kk + kh*ksize + kw
                if ic < cfg_c_in - 1 then
                    ic         <= ic + 1;
                    ic_offset  <= ic_offset + hw_in_reg;  -- activation
                    ic_wt_off  <= ic_wt_off + kk_reg;     -- weight OIHW
                    state      <= S_KERN_ADDR;
                elsif kw < cfg_ksize - 1 then
                    ic <= (others => '0');
                    ic_offset  <= (others => '0');
                    ic_wt_off  <= (others => '0');
                    kw <= kw + 1;
                    state <= S_KERN_ADDR;
                elsif kh < cfg_ksize - 1 then
                    ic <= (others => '0');
                    ic_offset  <= (others => '0');
                    ic_wt_off  <= (others => '0');
                    kw <= (others => '0');
                    kh <= kh + 1;
                    kh_wt_off  <= kh_wt_off + resize(cfg_ksize, 20);
                    state <= S_KERN_ADDR;
                else
                    drain_cnt <= "00";
                    state     <= S_DRAIN;
                end if;

            -- =============================================================
            -- DRAIN: esperar 2 ciclos para pipeline MAC
            -- =============================================================
            when S_DRAIN =>
                drain_cnt <= drain_cnt + 1;
                if drain_cnt = "01" then
                    rq_feed_cnt  <= (others => '0');
                    rq_write_cnt <= (others => '0');
                    rq_out_addr  <= resize(
                        cfg_addr_output
                        + resize(oh * w_out_reg, 16)
                        + resize(ow, 16), 16);
                    state <= S_RQ_FEED;
                end if;

            -- =============================================================
            -- REQUANTIZE: alimentar 32 acumuladores, recoger salidas
            -- =============================================================
            when S_RQ_FEED =>
                rq_acc_in   <= mac_acc(to_integer(rq_feed_cnt));
                rq_valid_in <= '1';
                rq_feed_cnt <= rq_feed_cnt + 1;
                if rq_feed_cnt = to_unsigned(N_MAC - 1, 6) then
                    state <= S_RQ_FLUSH;
                end if;

            when S_RQ_FLUSH =>
                if rq_write_cnt >= to_unsigned(N_MAC, 6) then
                    state <= S_PIX_NEXT;
                end if;

            -- =============================================================
            -- PIXEL ADVANCE
            -- =============================================================
            when S_PIX_NEXT =>
                if ow < w_out_reg - 1 then
                    ow <= ow + 1; state <= S_PIX_CLR;
                elsif oh < h_out_reg - 1 then
                    ow <= (others => '0'); oh <= oh + 1; state <= S_PIX_CLR;
                else
                    state <= S_DONE;
                end if;

            -- =============================================================
            -- DONE
            -- =============================================================
            when S_DONE =>
                done <= '1'; busy <= '0';
                if start = '0' then state <= S_IDLE; end if;

            when others =>
                state <= S_IDLE;

            end case;
        end if; -- rst_n
        end if; -- rising_edge
    end process p_fsm;

    -- Debug
    dbg_oh <= oh;
    dbg_ow <= ow;
    with state select dbg_state <=
        "00000" when S_IDLE,      "00001" when S_PRE_1,
        "00010" when S_PRE_2,     "00011" when S_PRE_3,
        "00100" when S_PRE_4,     "00101" when S_BIAS_EMIT,
        "00110" when S_BIAS_WAIT, "00111" when S_BIAS_CAP,
        "01000" when S_PIX_CLR,   "01001" when S_PIX_BIAS,
        "01010" when S_PIX_CALC,  "01011" when S_KERN_ADDR,
        "01100" when S_KERN_ADDR2,"01101" when S_KERN_ACT_E,
        "01111" when S_KERN_WT_E, "10000" when S_KERN_WT_W,
        "10001" when S_KERN_WT_C, "10010" when S_KERN_FIRE,
        "10011" when S_DRAIN,     "10100" when S_RQ_FEED,
        "10101" when S_RQ_FLUSH,  "10110" when S_PIX_NEXT,
        "10111" when S_DONE,
        "11111" when others;

end architecture rtl;
