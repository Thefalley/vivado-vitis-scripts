-------------------------------------------------------------------------------
-- dpu_stream_wrapper.vhd -- DPU wrapper multi-primitiva (P_17)
-------------------------------------------------------------------------------
--
-- P_17_dpu_multi: Extension de P_16 para soportar 4 tipos de layer
-- seleccionados por REG_LAYER_TYPE (offset 0x54):
--   0 = CONV         (reutiliza conv_engine_v3 — Fase 1: IMPLEMENTADO)
--   1 = MAXPOOL      (reutiliza maxpool_unit — Fase 3: pendiente)
--   2 = LEAKY_RELU   (reutiliza leaky_relu — Fase 2: pendiente)
--   3 = ELEM_ADD     (reutiliza elem_add — Fase 4: pendiente)
--
-- Fase 1 (este commit): wrapper pasa-través equivalente a P_16. Solo CONV
-- funcional. El registro layer_type existe pero no cambia comportamiento.
-- Objetivo: verificar que la estructura del proyecto P_17 reproduce
-- bit-exact los 120/120 PASS de P_16 antes de integrar las otras primitivas.
--
-- Architecture:
--   AXI-Lite  (config regs)  -----> [config registers]
--                                        |
--                                        v
--   AXI-Stream slave  -----> [BRAM 4KB] <----> conv_engine_v3
--   (from DMA MM2S)               |
--                                 v
--                        AXI-Stream master ----> (to DataMover S2MM)
--                        (output drain)
--
-- FSM states:
--   IDLE  : waiting for command via AXI-Lite registers
--   LOAD  : accepting AXI-Stream beats, writing 32-bit words to BRAM
--   CONV  : conv_engine_v3 owns the BRAM (random R/W via DDR interface)
--   DRAIN : reading BRAM sequentially, emitting AXI-Stream master beats
--
-- BRAM: 2048 x 32-bit words with per-byte write-enables (P_100 pattern).
--       Single-port, time-division-muxed between conv, stream, and regs.
--
-- Register map (32-bit, offset from base):
--   0x00: ctrl    - bit 0: cmd_load  (W, self-clearing)
--                   bit 1: cmd_start (W, self-clearing)
--                   bit 2: cmd_drain (W, self-clearing)
--                   bit 8: done      (RO, sticky)
--                   bit 9: busy/conv running (RO)
--                   bits[11:10]: fsm_state (RO): 00=IDLE,01=LOAD,10=CONV,11=DRAIN
--   0x04: n_words - number of 32-bit words to load/drain (R/W)
--   0x08: c_in
--   0x0C: c_out
--   0x10: h_in
--   0x14: w_in
--   0x18: ksp      (bits 1:0=ksize, bit2=stride)
--   0x1C: x_zp
--   0x20: w_zp
--   0x24: M0
--   0x28: n_shift
--   0x2C: y_zp
--   0x30: addr_input
--   0x34: addr_weights
--   0x38: addr_bias
--   0x3C: addr_output
--   0x40: ic_tile_size
--   0x44: pad_top
--   0x48: pad_bottom
--   0x4C: pad_left
--   0x50: pad_right
--   0x54: layer_type (P_17): 0=CONV, 1=MAXPOOL, 2=LEAKY, 3=ELEM_ADD
--   0x58: M0_neg         (LEAKY_RELU) — pendiente fase 2
--   0x5C: n_neg          (LEAKY_RELU) — pendiente fase 2
--   0x60: b_zp           (ELEM_ADD)   — pendiente fase 4
--   0x64: M0_b           (ELEM_ADD)   — pendiente fase 4
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpu_stream_wrapper is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -----------------------------------------------------------------------
        -- AXI-Lite Slave (configuration registers — addr ampliado a 8 bits)
        -----------------------------------------------------------------------
        s_axi_awaddr  : in  std_logic_vector(7 downto 0);
        s_axi_awprot  : in  std_logic_vector(2 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;

        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;

        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;

        s_axi_araddr  : in  std_logic_vector(7 downto 0);
        s_axi_arprot  : in  std_logic_vector(2 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;

        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        -----------------------------------------------------------------------
        -- AXI-Stream Slave (data input from DMA MM2S)
        -----------------------------------------------------------------------
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -----------------------------------------------------------------------
        -- AXI-Stream Master (data output to DataMover S2MM)
        -----------------------------------------------------------------------
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;

        -----------------------------------------------------------------------
        -- Keep (required by DataMover S2MM)
        -----------------------------------------------------------------------
        m_axis_tkeep  : out std_logic_vector(3 downto 0);

        -----------------------------------------------------------------------
        -- P_30_A: Weight stream input (from FIFO_W, byte-level)
        -----------------------------------------------------------------------
        w_stream_data_i  : in  std_logic_vector(7 downto 0);
        w_stream_valid_i : in  std_logic;
        w_stream_ready_o : out std_logic
    );
end entity dpu_stream_wrapper;

architecture rtl of dpu_stream_wrapper is

    ---------------------------------------------------------------------------
    -- FSM
    ---------------------------------------------------------------------------
    type state_t is (S_IDLE, S_LOAD, S_CONV, S_DRAIN, S_STREAM_LR, S_STREAM_MP, S_STREAM_EA, S_LOAD_WEIGHTS);
    signal state : state_t := S_IDLE;

    ---------------------------------------------------------------------------
    -- Config registers
    ---------------------------------------------------------------------------
    signal reg_n_words     : unsigned(10 downto 0) := (others => '0');
    signal reg_c_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_c_out       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_h_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_w_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_ksp         : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_x_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_w_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_M0          : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_n_shift     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_y_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_input  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_weights: std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_bias   : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_output : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_ic_tile_size: std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_top     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_bottom  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_left    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_right   : std_logic_vector(31 downto 0) := (others => '0');
    -- P_17 nuevos
    signal reg_layer_type  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_M0_neg      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_n_neg       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_b_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_M0_b        : std_logic_vector(31 downto 0) := (others => '0');

    -- P_30_A new registers
    signal reg_no_clear      : std_logic := '0';
    signal reg_no_requantize : std_logic := '0';
    signal reg_wb_n_bytes    : unsigned(17 downto 0) := (others => '0');  -- max 256 KB

    -- Command bits (self-clearing pulses)
    signal cmd_load    : std_logic := '0';
    signal cmd_start   : std_logic := '0';
    signal cmd_drain   : std_logic := '0';
    signal cmd_load_weights : std_logic := '0';  -- bit 3 of REG_CTRL
    signal done_latch  : std_logic := '0';

    -- P_30_A: external wb_ram write signals (to conv_engine_v4)
    signal ext_wb_addr : unsigned(14 downto 0) := (others => '0');
    signal ext_wb_data : signed(7 downto 0) := (others => '0');
    signal ext_wb_we   : std_logic := '0';
    signal wb_load_count : unsigned(17 downto 0) := (others => '0');

    -- P_30_A: weight stream — connect entity ports to internal signals
    signal w_stream_ready : std_logic := '0';

    ---------------------------------------------------------------------------
    -- conv_engine_v3 signals
    ---------------------------------------------------------------------------
    signal ce_start     : std_logic := '0';
    signal ce_done      : std_logic;
    signal ce_busy      : std_logic;
    signal ddr_rd_addr  : unsigned(24 downto 0);
    signal ddr_rd_data  : std_logic_vector(7 downto 0);
    signal ddr_rd_en    : std_logic;
    signal ddr_wr_addr  : unsigned(24 downto 0);
    signal ddr_wr_data  : std_logic_vector(7 downto 0);
    signal ddr_wr_en    : std_logic;

    ---------------------------------------------------------------------------
    -- P_17 Fase 2: leaky_relu instance signals
    ---------------------------------------------------------------------------
    signal lr_x_in      : signed(7 downto 0) := (others => '0');
    signal lr_valid_in  : std_logic := '0';
    signal lr_y_out     : signed(7 downto 0);
    signal lr_valid_out : std_logic;

    ---------------------------------------------------------------------------
    -- P_17 Fase 3: maxpool_unit instance signals
    ---------------------------------------------------------------------------
    signal mp_x_in      : signed(7 downto 0) := (others => '0');
    signal mp_valid_in  : std_logic := '0';
    signal mp_clear     : std_logic := '0';
    signal mp_max_out   : signed(7 downto 0);
    signal mp_valid_out : std_logic;
    -- Capture timing: capturar max_out 2 ciclos despues de alimentar byte 3,
    -- que es cuando max_r (registrado dentro de maxpool_unit) refleja ya
    -- el ultimo byte de la ventana.
    signal mp_fed_b3_d1 : std_logic := '0';
    signal mp_fed_b3_d2 : std_logic := '0';

    ---------------------------------------------------------------------------
    -- P_17 Fase 4: elem_add instance signals
    -- Patron: A desde BRAM @ addr_A, B desde BRAM @ addr_B.
    -- Ambos cargados via S_LOAD en un solo DMA: ARM concatena A+B en DDR.
    ---------------------------------------------------------------------------
    signal ea_a_in      : signed(7 downto 0) := (others => '0');
    signal ea_b_in      : signed(7 downto 0) := (others => '0');
    signal ea_valid_in  : std_logic := '0';
    signal ea_y_out     : signed(7 downto 0);
    signal ea_valid_out : std_logic;

    -- Sub-FSM para ciclos por word: 0..5 (6 fases por 4 bytes output).
    signal ea_phase    : unsigned(2 downto 0) := (others => '0');
    signal ea_word_idx : unsigned(10 downto 0) := (others => '0');
    signal a_word_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal b_word_reg  : std_logic_vector(31 downto 0) := (others => '0');

    -- BRAM control desde EA (lectura sequencial A, luego B)
    signal ea_bram_en   : std_logic := '0';
    signal ea_bram_addr : unsigned(10 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- P_17 Fase 2: SERDES 32->8->32 para modos stream
    ---------------------------------------------------------------------------
    -- Input side: captura 1 word y emite 4 bytes en ciclos consecutivos
    signal stream_word_in  : std_logic_vector(31 downto 0) := (others => '0');
    signal stream_byte_sel : unsigned(1 downto 0) := "00";
    signal stream_word_loaded : std_logic := '0';
    signal stream_in_done  : std_logic := '0';  -- se han aceptado ya todos los words
    signal stream_in_last  : std_logic := '0';  -- ultima word ya capturada

    -- Output side: acumula 4 bytes y emite 1 word
    signal stream_out_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal stream_out_cnt  : unsigned(1 downto 0) := "00";
    signal stream_out_valid : std_logic := '0';
    signal stream_out_last  : std_logic := '0';
    signal stream_out_count : unsigned(11 downto 0) := (others => '0');  -- words emitidos

    -- Contadores de progreso
    signal stream_in_words  : unsigned(11 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- 8 KB BRAM: 2048 words x 32 bits (P_30_A: doubled for bias c_out=1024)
    ---------------------------------------------------------------------------
    constant BRAM_DEPTH : natural := 2048;
    type ram_t is array (0 to BRAM_DEPTH-1) of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

    -- Single-port signals (time-division muxed by FSM state)
    signal bram_en    : std_logic;
    signal bram_we    : std_logic_vector(3 downto 0);
    signal bram_addr  : unsigned(10 downto 0);
    signal bram_din   : std_logic_vector(31 downto 0);
    signal bram_dout  : std_logic_vector(31 downto 0) := (others => '0');

    -- Conv-side byte selection (pipelined for BRAM read latency)
    signal conv_byte_sel   : unsigned(1 downto 0);
    signal conv_byte_sel_d : unsigned(1 downto 0) := "00";

    -- Conv -> BRAM
    signal conv_bram_en   : std_logic;
    signal conv_bram_we   : std_logic_vector(3 downto 0);
    signal conv_bram_addr : unsigned(10 downto 0);
    signal conv_bram_din  : std_logic_vector(31 downto 0);

    -- Stream LOAD -> BRAM
    signal load_bram_en   : std_logic;
    signal load_bram_we   : std_logic_vector(3 downto 0);
    signal load_bram_addr : unsigned(10 downto 0);
    signal load_bram_din  : std_logic_vector(31 downto 0);

    -- Stream DRAIN <- BRAM
    signal drain_bram_en   : std_logic;
    signal drain_bram_addr : unsigned(10 downto 0);

    -- Load/Drain counters
    signal load_addr   : unsigned(10 downto 0) := (others => '0');
    signal drain_addr  : unsigned(10 downto 0) := (others => '0');
    signal drain_count : unsigned(10 downto 0) := (others => '0');

    -- Drain pipeline: BRAM has 1-cycle read latency
    signal drain_valid_pipe : std_logic := '0';
    signal drain_last_pipe  : std_logic := '0';
    signal drain_active     : std_logic := '0';
    signal drain_stall      : std_logic := '0';

    ---------------------------------------------------------------------------
    -- AXI-Lite state machines
    ---------------------------------------------------------------------------
    signal axi_awready_r : std_logic := '0';
    signal axi_wready_r  : std_logic := '0';
    signal axi_bvalid_r  : std_logic := '0';

    type rd_state_t is (RD_IDLE, RD_WAIT, RD_VALID);
    signal rd_state      : rd_state_t := RD_IDLE;
    signal axi_arready_r : std_logic := '0';
    signal axi_rvalid_r  : std_logic := '0';
    signal axi_rdata_r   : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rd_data   : std_logic_vector(31 downto 0) := (others => '0');

    -- FSM state encoding for status register
    signal fsm_code : std_logic_vector(1 downto 0);

begin

    -- P_30_A: weight stream port connections
    w_stream_ready_o <= w_stream_ready;

    ---------------------------------------------------------------------------
    -- Output assignments
    ---------------------------------------------------------------------------
    s_axi_awready <= axi_awready_r;
    s_axi_wready  <= axi_wready_r;
    s_axi_bresp   <= "00";
    s_axi_bvalid  <= axi_bvalid_r;

    s_axi_arready <= axi_arready_r;
    s_axi_rdata   <= axi_rdata_r;
    s_axi_rresp   <= "00";
    s_axi_rvalid  <= axi_rvalid_r;

    -- FSM state for status register (2 bits, states stream comparten codigo con DRAIN)
    fsm_code <= "00" when state = S_IDLE  else
                "01" when state = S_LOAD  else
                "10" when state = S_CONV  else
                "11";  -- S_DRAIN / S_STREAM_LR / S_STREAM_MP

    -- m_axis_tkeep: all bytes valid during drain o stream
    m_axis_tkeep <= "1111" when (drain_valid_pipe = '1' or stream_out_valid = '1')
                    else "0000";

    ---------------------------------------------------------------------------
    -- conv_engine_v3 instance (asymmetric padding)
    ---------------------------------------------------------------------------
    u_conv : entity work.conv_engine_v4
        port map (
            clk              => clk,
            rst_n            => rst_n,
            cfg_c_in         => unsigned(reg_c_in(9 downto 0)),
            cfg_c_out        => unsigned(reg_c_out(9 downto 0)),
            cfg_h_in         => unsigned(reg_h_in(9 downto 0)),
            cfg_w_in         => unsigned(reg_w_in(9 downto 0)),
            cfg_ksize        => unsigned(reg_ksp(1 downto 0)),
            cfg_stride       => reg_ksp(2),
            cfg_pad_top      => unsigned(reg_pad_top(1 downto 0)),
            cfg_pad_bottom   => unsigned(reg_pad_bottom(1 downto 0)),
            cfg_pad_left     => unsigned(reg_pad_left(1 downto 0)),
            cfg_pad_right    => unsigned(reg_pad_right(1 downto 0)),
            cfg_x_zp         => signed(reg_x_zp(8 downto 0)),
            cfg_w_zp         => signed(reg_w_zp(7 downto 0)),
            cfg_M0           => unsigned(reg_M0),
            cfg_n_shift      => unsigned(reg_n_shift(5 downto 0)),
            cfg_y_zp         => signed(reg_y_zp(7 downto 0)),
            cfg_addr_input   => unsigned(reg_addr_input(24 downto 0)),
            cfg_addr_weights => unsigned(reg_addr_weights(24 downto 0)),
            cfg_addr_bias    => unsigned(reg_addr_bias(24 downto 0)),
            cfg_addr_output  => unsigned(reg_addr_output(24 downto 0)),
            cfg_ic_tile_size => unsigned(reg_ic_tile_size(9 downto 0)),
            start            => ce_start,
            done             => ce_done,
            busy             => ce_busy,
            ddr_rd_addr      => ddr_rd_addr,
            ddr_rd_data      => ddr_rd_data,
            ddr_rd_en        => ddr_rd_en,
            ddr_wr_addr      => ddr_wr_addr,
            ddr_wr_data      => ddr_wr_data,
            ddr_wr_en        => ddr_wr_en,
            dbg_state        => open,
            dbg_oh           => open,
            dbg_ow           => open,
            dbg_kh           => open,
            dbg_kw           => open,
            dbg_ic           => open,
            dbg_oc_tile_base => open,
            dbg_ic_tile_base => open,
            dbg_w_base       => open,
            dbg_mac_a        => open,
            dbg_mac_b        => open,
            dbg_mac_bi       => open,
            dbg_mac_acc      => open,
            dbg_mac_vi       => open,
            dbg_mac_clr      => open,
            dbg_mac_lb       => open,
            dbg_pad          => open,
            dbg_act_addr     => open,
            -- P_30_A v4 ports
            cfg_no_clear      => reg_no_clear,
            cfg_no_requantize => reg_no_requantize,
            ext_wb_addr       => ext_wb_addr,
            ext_wb_data       => ext_wb_data,
            ext_wb_we         => ext_wb_we
        );

    ---------------------------------------------------------------------------
    -- P_17 Fase 2: leaky_relu instance (reutiliza P_9/src/leaky_relu.vhd)
    -- Params desde registros AXI-Lite runtime (NO generics como el wrapper
    -- _stream de P_9). Runtime-reconfigurable por capa.
    ---------------------------------------------------------------------------
    u_lr : entity work.leaky_relu
        port map (
            clk       => clk,
            rst_n     => rst_n,
            x_in      => lr_x_in,
            valid_in  => lr_valid_in,
            x_zp      => signed(reg_x_zp(7 downto 0)),
            y_zp      => signed(reg_y_zp(7 downto 0)),
            M0_pos    => unsigned(reg_M0),
            n_pos     => unsigned(reg_n_shift(5 downto 0)),
            M0_neg    => unsigned(reg_M0_neg),
            n_neg     => unsigned(reg_n_neg(5 downto 0)),
            y_out     => lr_y_out,
            valid_out => lr_valid_out
        );

    ---------------------------------------------------------------------------
    -- P_17 Fase 3: maxpool_unit instance (reutiliza P_12/src/maxpool_unit.vhd)
    -- Sin params (el maxpool no requantiza). Ventana 2×2 asumida: cada word
    -- = 4 bytes consecutivos de una ventana, pre-ordenados por el ARM.
    ---------------------------------------------------------------------------
    u_mp : entity work.maxpool_unit
        port map (
            clk       => clk,
            rst_n     => rst_n,
            x_in      => mp_x_in,
            valid_in  => mp_valid_in,
            clear     => mp_clear,
            max_out   => mp_max_out,
            valid_out => mp_valid_out
        );

    ---------------------------------------------------------------------------
    -- P_17 Fase 4: elem_add instance (reutiliza P_11/src/elem_add.vhd)
    -- Params runtime desde AXI-Lite:
    --   a_zp = reg_x_zp[7:0]          (input A zero-point)
    --   b_zp = reg_b_zp[7:0]          (input B zero-point)
    --   y_zp = reg_y_zp[7:0]          (output zero-point)
    --   M0_a = reg_M0                  (multiplier A)
    --   M0_b = reg_M0_b                (multiplier B)
    --   n_shift = reg_n_shift[5:0]     (common shift)
    ---------------------------------------------------------------------------
    u_ea : entity work.elem_add
        port map (
            clk       => clk,
            rst_n     => rst_n,
            a_in      => ea_a_in,
            b_in      => ea_b_in,
            valid_in  => ea_valid_in,
            a_zp      => signed(reg_x_zp(7 downto 0)),
            b_zp      => signed(reg_b_zp(7 downto 0)),
            y_zp      => signed(reg_y_zp(7 downto 0)),
            M0_a      => unsigned(reg_M0),
            M0_b      => unsigned(reg_M0_b),
            n_shift   => unsigned(reg_n_shift(5 downto 0)),
            y_out     => ea_y_out,
            valid_out => ea_valid_out
        );

    ---------------------------------------------------------------------------
    -- Conv -> BRAM adapter (byte-addressed -> word-addressed, same as P_13)
    ---------------------------------------------------------------------------
    conv_byte_sel <= ddr_rd_addr(1 downto 0) when ddr_wr_en = '0'
                     else ddr_wr_addr(1 downto 0);

    conv_bram_en   <= ddr_rd_en or ddr_wr_en;
    conv_bram_addr <= ddr_wr_addr(12 downto 2) when ddr_wr_en = '1'
                      else ddr_rd_addr(12 downto 2);
    conv_bram_din  <= ddr_wr_data & ddr_wr_data & ddr_wr_data & ddr_wr_data;

    conv_bram_we <= "0001" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "00") else
                    "0010" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "01") else
                    "0100" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "10") else
                    "1000" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "11") else
                    "0000";

    -- Conv read path: delay byte selector 1 cycle to match BRAM latency
    p_conv_rd_pipe : process(clk)
    begin
        if rising_edge(clk) then
            if ddr_rd_en = '1' then
                conv_byte_sel_d <= conv_byte_sel;
            end if;
        end if;
    end process;

    with conv_byte_sel_d select
        ddr_rd_data <= bram_dout(7 downto 0)   when "00",
                       bram_dout(15 downto 8)  when "01",
                       bram_dout(23 downto 16) when "10",
                       bram_dout(31 downto 24) when others;

    ---------------------------------------------------------------------------
    -- Stream LOAD -> BRAM: write full 32-bit words sequentially
    ---------------------------------------------------------------------------
    load_bram_en   <= '1'    when (state = S_LOAD and s_axis_tvalid = '1') else '0';
    load_bram_we   <= "1111" when (state = S_LOAD and s_axis_tvalid = '1') else "0000";
    load_bram_addr <= load_addr;
    load_bram_din  <= s_axis_tdata;

    -- P_17: s_axis_tready admite stream en S_LOAD (ancho word) y en los
    -- S_STREAM_* cuando la SERDES está libre para aceptar siguiente word.
    -- S_STREAM_EA NO consume stream (A y B ya en BRAM tras S_LOAD).
    s_axis_tready <= '1' when (state = S_LOAD)
                     else '1' when ((state = S_STREAM_LR or state = S_STREAM_MP)
                                    and stream_word_loaded = '0'
                                    and stream_in_last = '0')
                     else '0';

    ---------------------------------------------------------------------------
    -- Stream DRAIN <- BRAM: read full 32-bit words sequentially
    ---------------------------------------------------------------------------
    drain_bram_en   <= drain_active and (not drain_stall);
    drain_bram_addr <= drain_addr;

    -- Stall when downstream is not ready and we already have valid data
    drain_stall <= drain_valid_pipe and (not m_axis_tready);

    -- P_17: m_axis mux segun modo (conv DRAIN usa bram_dout, stream modes
    -- usan el registro de salida de la primitiva)
    m_axis_tdata  <= stream_out_reg
                        when (state = S_STREAM_LR or state = S_STREAM_MP
                              or state = S_STREAM_EA)
                        else bram_dout;
    m_axis_tvalid <= stream_out_valid
                        when (state = S_STREAM_LR or state = S_STREAM_MP
                              or state = S_STREAM_EA)
                        else drain_valid_pipe;
    m_axis_tlast  <= stream_out_last
                        when (state = S_STREAM_LR or state = S_STREAM_MP
                              or state = S_STREAM_EA)
                        else drain_last_pipe;

    ---------------------------------------------------------------------------
    -- BRAM port mux: who owns the port depends on FSM state
    ---------------------------------------------------------------------------
    bram_en   <= conv_bram_en    when state = S_CONV      else
                 load_bram_en    when state = S_LOAD      else
                 drain_bram_en   when state = S_DRAIN     else
                 ea_bram_en      when state = S_STREAM_EA else
                 '0';

    bram_we   <= conv_bram_we    when state = S_CONV      else
                 load_bram_we    when state = S_LOAD      else
                 "0000";  -- DRAIN / IDLE / stream modes: read-only

    bram_addr <= conv_bram_addr  when state = S_CONV      else
                 load_bram_addr  when state = S_LOAD      else
                 drain_bram_addr when state = S_DRAIN     else
                 ea_bram_addr    when state = S_STREAM_EA else
                 (others => '0');

    bram_din  <= conv_bram_din   when state = S_CONV      else
                 load_bram_din   when state = S_LOAD      else
                 (others => '0');

    ---------------------------------------------------------------------------
    -- BRAM process (P_100 inference pattern: sync read + byte-write-enables)
    ---------------------------------------------------------------------------
    p_bram : process(clk)
    begin
        if rising_edge(clk) then
            if bram_en = '1' then
                if bram_we(0) = '1' then
                    ram(to_integer(bram_addr))( 7 downto  0) <= bram_din( 7 downto  0);
                end if;
                if bram_we(1) = '1' then
                    ram(to_integer(bram_addr))(15 downto  8) <= bram_din(15 downto  8);
                end if;
                if bram_we(2) = '1' then
                    ram(to_integer(bram_addr))(23 downto 16) <= bram_din(23 downto 16);
                end if;
                if bram_we(3) = '1' then
                    ram(to_integer(bram_addr))(31 downto 24) <= bram_din(31 downto 24);
                end if;
                bram_dout <= ram(to_integer(bram_addr));
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main FSM
    ---------------------------------------------------------------------------
    p_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state           <= S_IDLE;
                load_addr       <= (others => '0');
                drain_addr      <= (others => '0');
                drain_count     <= (others => '0');
                drain_valid_pipe <= '0';
                drain_last_pipe  <= '0';
                drain_active     <= '0';
                ce_start         <= '0';
                done_latch       <= '0';
                -- P_17 Fase 2: SERDES resets
                lr_valid_in         <= '0';
                lr_x_in             <= (others => '0');
                -- P_17 Fase 3: maxpool resets
                mp_valid_in         <= '0';
                mp_clear            <= '0';
                mp_x_in             <= (others => '0');
                mp_fed_b3_d1        <= '0';
                mp_fed_b3_d2        <= '0';
                -- P_17 Fase 4: elem_add resets
                ea_valid_in         <= '0';
                ea_a_in             <= (others => '0');
                ea_b_in             <= (others => '0');
                ea_phase            <= "000";
                ea_word_idx         <= (others => '0');
                ea_bram_en          <= '0';
                ea_bram_addr        <= (others => '0');
                a_word_reg          <= (others => '0');
                b_word_reg          <= (others => '0');
                stream_word_loaded  <= '0';
                stream_byte_sel     <= "00";
                stream_in_last      <= '0';
                stream_in_words     <= (others => '0');
                stream_out_reg      <= (others => '0');
                stream_out_cnt      <= "00";
                stream_out_valid    <= '0';
                stream_out_last     <= '0';
                stream_out_count    <= (others => '0');
            else
                -- Default: single-cycle pulse
                ce_start <= '0';
                -- P_17 Fase 2: lr_valid_in es pulso (alto solo mientras alimentamos byte)
                lr_valid_in <= '0';
                -- P_17 Fase 3: mp_valid_in / mp_clear tambien pulsos
                mp_valid_in <= '0';
                mp_clear    <= '0';
                -- Capture delay pipeline
                mp_fed_b3_d1 <= '0';
                mp_fed_b3_d2 <= mp_fed_b3_d1;
                -- P_17 Fase 4: ea_valid_in tambien pulso, ea_bram_en solo en fases 0,1
                ea_valid_in <= '0';
                ea_bram_en  <= '0';

                case state is
                    when S_IDLE =>
                        drain_valid_pipe <= '0';
                        drain_last_pipe  <= '0';
                        drain_active     <= '0';
                        -- Reset SERDES flags al volver a IDLE
                        stream_word_loaded <= '0';
                        stream_byte_sel    <= "00";
                        stream_out_cnt     <= "00";
                        stream_out_valid   <= '0';
                        stream_out_last    <= '0';
                        stream_in_last     <= '0';
                        stream_in_words    <= (others => '0');
                        stream_out_count   <= (others => '0');

                        if cmd_load = '1' then
                            state     <= S_LOAD;
                            load_addr <= (others => '0');
                        elsif cmd_start = '1' then
                            -- P_17: dispatch segun layer_type (0x54)
                            done_latch <= '0';
                            case reg_layer_type(3 downto 0) is
                                when x"1" =>
                                    -- MAXPOOL: modo stream bypass BRAM
                                    state <= S_STREAM_MP;
                                when x"2" =>
                                    -- LEAKY_RELU: modo stream bypass BRAM
                                    state <= S_STREAM_LR;
                                when x"3" =>
                                    -- ELEM_ADD: A+B en BRAM (cargados por S_LOAD
                                    -- previo), EA lee ambos + feeds + DM output
                                    state       <= S_STREAM_EA;
                                    ea_phase    <= "000";
                                    ea_word_idx <= (others => '0');
                                when others =>
                                    -- CONV (default, layer_type = 0)
                                    state    <= S_CONV;
                                    ce_start <= '1';
                            end case;
                        elsif cmd_drain = '1' then
                            state       <= S_DRAIN;
                            drain_addr  <= (others => '0');
                            drain_count <= (others => '0');
                            drain_active <= '1';
                        elsif cmd_load_weights = '1' then
                            -- P_30_A: cargar pesos via weight stream → wb_ram
                            state <= S_LOAD_WEIGHTS;
                            wb_load_count <= (others => '0');
                            done_latch <= '0';
                        end if;

                    when S_LOAD =>
                        -- Accept stream beats, write to BRAM word-by-word
                        if s_axis_tvalid = '1' then
                            load_addr <= load_addr + 1;
                            if s_axis_tlast = '1' or
                               (reg_n_words /= 0 and load_addr = reg_n_words - 1) then
                                state <= S_IDLE;
                            end if;
                        end if;

                    when S_CONV =>
                        -- Wait for conv_engine to finish
                        if ce_done = '1' then
                            done_latch <= '1';
                            state      <= S_IDLE;
                        end if;

                    when S_DRAIN =>
                        -- Pipeline: issue BRAM read -> 1 cycle later data valid
                        if drain_stall = '0' then
                            if drain_active = '1' then
                                drain_valid_pipe <= '1';
                                if reg_n_words /= 0 and drain_count = reg_n_words - 1 then
                                    drain_last_pipe <= '1';
                                else
                                    drain_last_pipe <= '0';
                                end if;

                                drain_addr  <= drain_addr + 1;
                                drain_count <= drain_count + 1;

                                if reg_n_words /= 0 and drain_count = reg_n_words - 1 then
                                    drain_active <= '0';
                                end if;
                            else
                                drain_valid_pipe <= '0';
                                drain_last_pipe  <= '0';
                            end if;
                        end if;

                        -- Transition back to idle when last beat is consumed
                        if drain_valid_pipe = '1' and drain_last_pipe = '1'
                           and m_axis_tready = '1' then
                            state            <= S_IDLE;
                            drain_valid_pipe <= '0';
                            drain_last_pipe  <= '0';
                            drain_active     <= '0';
                        end if;

                    ---------------------------------------------------------
                    -- S_STREAM_LR: LEAKY_RELU en modo stream bypass BRAM
                    --   INPUT  SERDES 32 bit -> 8 bit: captura 1 word en
                    --     4 ciclos, alimenta 1 byte/ciclo a leaky_relu.
                    --   OUTPUT SERDES 8 bit -> 32 bit: acumula 4 bytes en
                    --     stream_out_reg, emite tvalid cuando tiene word.
                    --   Backpressure de m_axis: si tready='0' cuando hay
                    --     word listo, se queda esperando sin perder datos.
                    ---------------------------------------------------------
                    when S_STREAM_LR =>
                        -------------------------
                        -- INPUT SIDE (SERDES)
                        -------------------------
                        if stream_word_loaded = '0' then
                            -- Necesitamos un word nuevo
                            if s_axis_tvalid = '1' and stream_in_last = '0' then
                                stream_word_in     <= s_axis_tdata;
                                stream_word_loaded <= '1';
                                stream_byte_sel    <= "00";
                                stream_in_words    <= stream_in_words + 1;
                                if s_axis_tlast = '1' then
                                    stream_in_last <= '1';
                                end if;
                            end if;
                        else
                            -- Tenemos word; alimentar byte actual a leaky_relu
                            lr_valid_in <= '1';
                            case stream_byte_sel is
                                when "00" =>
                                    lr_x_in <= signed(stream_word_in( 7 downto  0));
                                when "01" =>
                                    lr_x_in <= signed(stream_word_in(15 downto  8));
                                when "10" =>
                                    lr_x_in <= signed(stream_word_in(23 downto 16));
                                when others =>
                                    lr_x_in <= signed(stream_word_in(31 downto 24));
                            end case;

                            if stream_byte_sel = "11" then
                                -- Terminado este word, pedir siguiente
                                stream_word_loaded <= '0';
                                stream_byte_sel    <= "00";
                            else
                                stream_byte_sel <= stream_byte_sel + 1;
                            end if;
                        end if;

                        -------------------------
                        -- OUTPUT SIDE
                        -- Capturar bytes que salen de leaky_relu y acumular.
                        -- Emitir word cada 4 bytes.
                        -------------------------
                        if lr_valid_out = '1' then
                            case stream_out_cnt is
                                when "00" =>
                                    stream_out_reg( 7 downto  0) <= std_logic_vector(lr_y_out);
                                when "01" =>
                                    stream_out_reg(15 downto  8) <= std_logic_vector(lr_y_out);
                                when "10" =>
                                    stream_out_reg(23 downto 16) <= std_logic_vector(lr_y_out);
                                when others =>
                                    stream_out_reg(31 downto 24) <= std_logic_vector(lr_y_out);
                            end case;

                            if stream_out_cnt = "11" then
                                -- Word completo, elevar tvalid
                                stream_out_valid <= '1';
                                stream_out_cnt   <= "00";
                                if reg_n_words /= 0 and
                                   stream_out_count = resize(reg_n_words, 12) - 1 then
                                    stream_out_last <= '1';
                                end if;
                            else
                                stream_out_cnt <= stream_out_cnt + 1;
                            end if;
                        end if;

                        -- Handshake m_axis: cuando consumido, bajar tvalid y
                        -- contar words emitidos
                        if stream_out_valid = '1' and m_axis_tready = '1' then
                            stream_out_valid <= '0';
                            stream_out_count <= stream_out_count + 1;

                            if stream_out_last = '1' then
                                -- Ultimo word consumido -> done
                                stream_out_last <= '0';
                                done_latch      <= '1';
                                state           <= S_IDLE;
                            end if;
                        end if;

                    ---------------------------------------------------------
                    -- S_STREAM_MP: MAXPOOL 2x2 stream bypass BRAM
                    --   ARM pre-ordena ventanas 2x2 contiguas: cada word
                    --   son 4 bytes de 1 ventana. byte 0 es clear+value,
                    --   bytes 1,2,3 solo value. Tras byte 3, max_out
                    --   contiene el maximo de la ventana -> se captura en
                    --   el output SERDES.
                    --
                    --   Ratio: 4 input bytes (1 word) -> 1 output byte.
                    --          4 output bytes -> 1 output word.
                    --   Es decir: 4 input words -> 1 output word.
                    ---------------------------------------------------------
                    when S_STREAM_MP =>
                        -------------------------
                        -- INPUT SIDE
                        --
                        -- Secuencia por ventana (5 ciclos fetch):
                        --   cycle 0: capture word  -> asserta mp_clear (no feed)
                        --   cycle 1: feed byte 0   -> mp_valid_in=1, mp_clear=0
                        --   cycle 2: feed byte 1
                        --   cycle 3: feed byte 2
                        --   cycle 4: feed byte 3   -> marca mp_fed_b3_d1=1 para capture
                        --
                        -- maxpool_unit tiene prioridad clear > valid_in. Por eso
                        -- el clear se pre-asserta el ciclo anterior al byte 0.
                        -------------------------
                        if stream_word_loaded = '0' then
                            if s_axis_tvalid = '1' and stream_in_last = '0' then
                                stream_word_in     <= s_axis_tdata;
                                stream_word_loaded <= '1';
                                stream_byte_sel    <= "00";
                                stream_in_words    <= stream_in_words + 1;
                                if s_axis_tlast = '1' then
                                    stream_in_last <= '1';
                                end if;
                                -- Pre-assert clear (sin feed), visible cuando se
                                -- empiece a alimentar byte 0 el proximo ciclo
                                mp_clear <= '1';
                            end if;
                        else
                            -- Alimentar byte actual a maxpool (clear=0)
                            mp_valid_in <= '1';
                            mp_clear    <= '0';
                            case stream_byte_sel is
                                when "00" =>
                                    mp_x_in <= signed(stream_word_in( 7 downto  0));
                                when "01" =>
                                    mp_x_in <= signed(stream_word_in(15 downto  8));
                                when "10" =>
                                    mp_x_in <= signed(stream_word_in(23 downto 16));
                                when others =>
                                    mp_x_in <= signed(stream_word_in(31 downto 24));
                            end case;

                            if stream_byte_sel = "11" then
                                -- Alimentando byte 3: marcar para capture
                                -- 2 ciclos despues (max_r refleja b3 en cycle+2)
                                mp_fed_b3_d1       <= '1';
                                stream_word_loaded <= '0';
                                stream_byte_sel    <= "00";
                            else
                                stream_byte_sel <= stream_byte_sel + 1;
                            end if;
                        end if;

                        -------------------------
                        -- OUTPUT SIDE
                        -- mp_valid_out=1 en cada ciclo que alimentamos,
                        -- pero solo el ULTIMO (byte 3 del word) tiene el
                        -- max final de la ventana. Lo capturamos 1 ciclo
                        -- despues (maxpool_unit tiene 1 ciclo latencia).
                        --
                        -- Usamos un flag de 1 ciclo: mp_window_done_d
                        -- que se setea cuando byte_sel acaba de ser "11"
                        -- con valid_in, indicando que el proximo ciclo
                        -- tendremos valid_out con el max final.
                        -------------------------
                        -- Capturar max_out al ciclo DESPUES de feed byte 3
                        -- (mp_valid_out sigue alto; usamos byte_sel='00' y
                        --  stream_word_loaded='0' como proxy de "acabamos
                        --  de cerrar una ventana").
                        --
                        -- Mejor: registramos una flag mp_capture_next de 1 ciclo
                        -- (pulso tras alimentar byte 3).
                        if stream_word_loaded = '1' and stream_byte_sel = "11" then
                            -- Este ciclo alimenta byte 3; en el proximo ciclo
                            -- capturamos max_out. Lo hacemos YA aqui pues el
                            -- comparador maxpool_unit es combinacional en max
                            -- (update se registra dentro). mp_max_out reflejara
                            -- el nuevo max al proximo flanco.
                            -- → setear flag para capturar en siguiente ciclo.
                            null;  -- el capture real se hace abajo con mp_valid_out
                        end if;

                        -- Capture fire: 2 ciclos despues de alimentar byte 3
                        -- mp_fed_b3_d2 va alto justo cuando max_r ya contiene
                        -- el max de los 4 bytes de la ventana.
                        if mp_fed_b3_d2 = '1' then
                            -- Final del window: acumular max
                            case stream_out_cnt is
                                when "00" =>
                                    stream_out_reg( 7 downto  0) <= std_logic_vector(mp_max_out);
                                when "01" =>
                                    stream_out_reg(15 downto  8) <= std_logic_vector(mp_max_out);
                                when "10" =>
                                    stream_out_reg(23 downto 16) <= std_logic_vector(mp_max_out);
                                when others =>
                                    stream_out_reg(31 downto 24) <= std_logic_vector(mp_max_out);
                            end case;

                            if stream_out_cnt = "11" then
                                stream_out_valid <= '1';
                                stream_out_cnt   <= "00";
                                if reg_n_words /= 0 and
                                   stream_out_count = resize(shift_right(reg_n_words, 2), 12) - 1 then
                                    -- reg_n_words/4 output words (MP: 4 in words = 1 out word)
                                    stream_out_last <= '1';
                                end if;
                            else
                                stream_out_cnt <= stream_out_cnt + 1;
                            end if;
                        end if;

                        -- Handshake m_axis identico al LR
                        if stream_out_valid = '1' and m_axis_tready = '1' then
                            stream_out_valid <= '0';
                            stream_out_count <= stream_out_count + 1;

                            if stream_out_last = '1' then
                                stream_out_last <= '0';
                                done_latch      <= '1';
                                state           <= S_IDLE;
                            end if;
                        end if;

                    ---------------------------------------------------------
                    -- S_STREAM_EA: ELEM_ADD con A y B en BRAM
                    --   A cargado @ reg_addr_input, B @ reg_addr_weights.
                    --   reg_n_words = TOTAL LOAD words = 2*N; N output words.
                    --   Sub-FSM 6 fases por ciclo de 4 bytes output:
                    --     0: issue read A[word_idx]
                    --     1: capture A, issue read B[word_idx]
                    --     2: capture B, feed byte 0 (a_reg, bram_dout)
                    --     3: feed byte 1 (a_reg, b_reg)
                    --     4: feed byte 2
                    --     5: feed byte 3, advance word_idx
                    ---------------------------------------------------------
                    when S_STREAM_EA =>
                        -- BRAM read latency = 1 ciclo: el dato leido por
                        -- bram_en='1' en ciclo K aparece en bram_dout en K+1.
                        -- Por eso necesitamos 7 fases (2 setup + 1 capture + 4 feed).
                        case to_integer(ea_phase) is
                            when 0 =>
                                if stream_in_last = '1' then
                                    ea_bram_en <= '0';
                                else
                                    -- Issue A read (llega en phase 2)
                                    ea_bram_en   <= '1';
                                    ea_bram_addr <= unsigned(reg_addr_input(12 downto 2))
                                                    + ea_word_idx;
                                    ea_phase     <= "001";
                                end if;

                            when 1 =>
                                -- Issue B read (llega en phase 3). Nota: BRAM
                                -- sigue cargando A este ciclo, bram_dout aun stale.
                                ea_bram_en   <= '1';
                                ea_bram_addr <= unsigned(reg_addr_weights(12 downto 2))
                                                + ea_word_idx;
                                ea_phase     <= "010";

                            when 2 =>
                                -- bram_dout = A word (llegada de phase 1). Capturar.
                                a_word_reg <= bram_dout;
                                ea_bram_en <= '0';
                                ea_phase   <= "011";

                            when 3 =>
                                -- bram_dout = B word. Capturar, feed byte 0 (a0,b0)
                                b_word_reg  <= bram_dout;
                                ea_a_in     <= signed(a_word_reg( 7 downto  0));
                                ea_b_in     <= signed(bram_dout( 7 downto  0));
                                ea_valid_in <= '1';
                                ea_phase    <= "100";

                            when 4 =>
                                ea_a_in     <= signed(a_word_reg(15 downto  8));
                                ea_b_in     <= signed(b_word_reg(15 downto  8));
                                ea_valid_in <= '1';
                                ea_phase    <= "101";

                            when 5 =>
                                ea_a_in     <= signed(a_word_reg(23 downto 16));
                                ea_b_in     <= signed(b_word_reg(23 downto 16));
                                ea_valid_in <= '1';
                                ea_phase    <= "110";

                            when 6 =>
                                ea_a_in     <= signed(a_word_reg(31 downto 24));
                                ea_b_in     <= signed(b_word_reg(31 downto 24));
                                ea_valid_in <= '1';
                                if ea_word_idx = resize(shift_right(reg_n_words, 1), 11) - 1 then
                                    stream_in_last <= '1';
                                    ea_phase       <= "000";
                                else
                                    ea_word_idx <= ea_word_idx + 1;
                                    ea_phase    <= "000";
                                end if;

                            when others =>
                                ea_phase <= "000";
                        end case;

                        -------------------------
                        -- OUTPUT SIDE (SERDES)
                        -- elem_add.vhd pipeline 8 ciclos. valid_out pulso alto
                        -- por cada valid_in (offset 8). Acumulamos 4 bytes,
                        -- emitimos word.
                        -------------------------
                        if ea_valid_out = '1' then
                            case stream_out_cnt is
                                when "00" =>
                                    stream_out_reg( 7 downto  0) <= std_logic_vector(ea_y_out);
                                when "01" =>
                                    stream_out_reg(15 downto  8) <= std_logic_vector(ea_y_out);
                                when "10" =>
                                    stream_out_reg(23 downto 16) <= std_logic_vector(ea_y_out);
                                when others =>
                                    stream_out_reg(31 downto 24) <= std_logic_vector(ea_y_out);
                            end case;

                            if stream_out_cnt = "11" then
                                stream_out_valid <= '1';
                                stream_out_cnt   <= "00";
                                -- Ultimo output word cuando count = N-1
                                if reg_n_words /= 0 and
                                   stream_out_count = resize(shift_right(reg_n_words, 1), 12) - 1 then
                                    stream_out_last <= '1';
                                end if;
                            else
                                stream_out_cnt <= stream_out_cnt + 1;
                            end if;
                        end if;

                        if stream_out_valid = '1' and m_axis_tready = '1' then
                            stream_out_valid <= '0';
                            stream_out_count <= stream_out_count + 1;

                            if stream_out_last = '1' then
                                stream_out_last <= '0';
                                done_latch      <= '1';
                                state           <= S_IDLE;
                            end if;
                        end if;
                    ---------------------------------------------------------------
                    -- P_30_A: S_LOAD_WEIGHTS — streams bytes from weight input
                    -- to conv_engine_v4 ext_wb_* (writes to wb_ram directly)
                    ---------------------------------------------------------------
                    when S_LOAD_WEIGHTS =>
                        ext_wb_we <= '0';
                        w_stream_ready <= '0';
                        if wb_load_count >= reg_wb_n_bytes then
                            done_latch <= '1';
                            state <= S_IDLE;
                        elsif w_stream_valid_i = '1' then
                            ext_wb_addr <= wb_load_count(14 downto 0);
                            ext_wb_data <= signed(w_stream_data_i);
                            ext_wb_we   <= '1';
                            w_stream_ready <= '1';
                            wb_load_count <= wb_load_count + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite Write Channel
    ---------------------------------------------------------------------------
    p_axi_wr : process(clk)
        variable v_addr : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                axi_awready_r <= '0';
                axi_wready_r  <= '0';
                axi_bvalid_r  <= '0';
                cmd_load       <= '0';
                cmd_start      <= '0';
                cmd_drain      <= '0';
                cmd_load_weights <= '0';
            else
                axi_awready_r <= '0';
                axi_wready_r  <= '0';

                -- Self-clearing command pulses
                cmd_load  <= '0';
                cmd_start <= '0';
                cmd_drain <= '0';
                cmd_load_weights <= '0';

                if s_axi_awvalid = '1' and s_axi_wvalid = '1'
                   and axi_awready_r = '0' and axi_bvalid_r = '0' then

                    axi_awready_r <= '1';
                    axi_wready_r  <= '1';
                    axi_bvalid_r  <= '1';

                    v_addr := unsigned(s_axi_awaddr);

                    case to_integer(v_addr) is
                        when 16#00# =>
                            cmd_load  <= s_axi_wdata(0);
                            cmd_start <= s_axi_wdata(1);
                            cmd_drain <= s_axi_wdata(2);
                            cmd_load_weights <= s_axi_wdata(3);  -- P_30_A: bit 3
                        when 16#04# => reg_n_words      <= unsigned(s_axi_wdata(10 downto 0));
                        when 16#08# => reg_c_in          <= s_axi_wdata;
                        when 16#0C# => reg_c_out         <= s_axi_wdata;
                        when 16#10# => reg_h_in          <= s_axi_wdata;
                        when 16#14# => reg_w_in          <= s_axi_wdata;
                        when 16#18# => reg_ksp           <= s_axi_wdata;
                        when 16#1C# => reg_x_zp          <= s_axi_wdata;
                        when 16#20# => reg_w_zp          <= s_axi_wdata;
                        when 16#24# => reg_M0            <= s_axi_wdata;
                        when 16#28# => reg_n_shift       <= s_axi_wdata;
                        when 16#2C# => reg_y_zp          <= s_axi_wdata;
                        when 16#30# => reg_addr_input    <= s_axi_wdata;
                        when 16#34# => reg_addr_weights  <= s_axi_wdata;
                        when 16#38# => reg_addr_bias     <= s_axi_wdata;
                        when 16#3C# => reg_addr_output   <= s_axi_wdata;
                        when 16#40# => reg_ic_tile_size  <= s_axi_wdata;
                        when 16#44# => reg_pad_top       <= s_axi_wdata;
                        when 16#48# => reg_pad_bottom    <= s_axi_wdata;
                        when 16#4C# => reg_pad_left      <= s_axi_wdata;
                        when 16#50# => reg_pad_right     <= s_axi_wdata;
                        -- P_17 nuevos
                        when 16#54# => reg_layer_type    <= s_axi_wdata;
                        when 16#58# => reg_M0_neg        <= s_axi_wdata;
                        when 16#5C# => reg_n_neg         <= s_axi_wdata;
                        when 16#60# => reg_b_zp          <= s_axi_wdata;
                        when 16#64# => reg_M0_b          <= s_axi_wdata;
                        -- P_30_A nuevos
                        when 16#68# => reg_no_clear      <= s_axi_wdata(0);
                        when 16#6C# => reg_no_requantize <= s_axi_wdata(0);
                        when 16#70# => reg_wb_n_bytes    <= unsigned(s_axi_wdata(17 downto 0));
                        when others => null;
                    end case;
                end if;

                if axi_bvalid_r = '1' and s_axi_bready = '1' then
                    axi_bvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite Read Channel (1-cycle wait to keep it simple)
    ---------------------------------------------------------------------------
    p_axi_rd : process(clk)
        variable v_addr : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rd_state      <= RD_IDLE;
                axi_arready_r <= '0';
                axi_rvalid_r  <= '0';
                axi_rdata_r   <= (others => '0');
            else
                axi_arready_r <= '0';

                case rd_state is
                    when RD_IDLE =>
                        if s_axi_arvalid = '1' and axi_rvalid_r = '0' then
                            axi_arready_r <= '1';
                            v_addr := unsigned(s_axi_araddr);

                            case to_integer(v_addr) is
                                when 16#00# =>
                                    reg_rd_data <= (others => '0');
                                    reg_rd_data(8)           <= done_latch;
                                    reg_rd_data(9)           <= ce_busy;
                                    reg_rd_data(11 downto 10) <= fsm_code;
                                when 16#04# =>
                                    reg_rd_data <= (others => '0');
                                    reg_rd_data(10 downto 0) <= std_logic_vector(reg_n_words);
                                when 16#08# => reg_rd_data <= reg_c_in;
                                when 16#0C# => reg_rd_data <= reg_c_out;
                                when 16#10# => reg_rd_data <= reg_h_in;
                                when 16#14# => reg_rd_data <= reg_w_in;
                                when 16#18# => reg_rd_data <= reg_ksp;
                                when 16#1C# => reg_rd_data <= reg_x_zp;
                                when 16#20# => reg_rd_data <= reg_w_zp;
                                when 16#24# => reg_rd_data <= reg_M0;
                                when 16#28# => reg_rd_data <= reg_n_shift;
                                when 16#2C# => reg_rd_data <= reg_y_zp;
                                when 16#30# => reg_rd_data <= reg_addr_input;
                                when 16#34# => reg_rd_data <= reg_addr_weights;
                                when 16#38# => reg_rd_data <= reg_addr_bias;
                                when 16#3C# => reg_rd_data <= reg_addr_output;
                                when 16#40# => reg_rd_data <= reg_ic_tile_size;
                                when 16#44# => reg_rd_data <= reg_pad_top;
                                when 16#48# => reg_rd_data <= reg_pad_bottom;
                                when 16#4C# => reg_rd_data <= reg_pad_left;
                                when 16#50# => reg_rd_data <= reg_pad_right;
                                -- P_17 nuevos
                                when 16#54# => reg_rd_data <= reg_layer_type;
                                when 16#58# => reg_rd_data <= reg_M0_neg;
                                when 16#5C# => reg_rd_data <= reg_n_neg;
                                when 16#60# => reg_rd_data <= reg_b_zp;
                                when 16#64# => reg_rd_data <= reg_M0_b;
                                when others => reg_rd_data <= (others => '0');
                            end case;

                            rd_state <= RD_WAIT;
                        end if;

                    when RD_WAIT =>
                        axi_rdata_r  <= reg_rd_data;
                        axi_rvalid_r <= '1';
                        rd_state     <= RD_VALID;

                    when RD_VALID =>
                        if s_axi_rready = '1' then
                            axi_rvalid_r <= '0';
                            rd_state     <= RD_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
