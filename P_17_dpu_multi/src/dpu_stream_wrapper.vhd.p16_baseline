-------------------------------------------------------------------------------
-- conv_stream_wrapper.vhd -- AXI-Stream + AXI-Lite wrapper for conv_engine_v3
-------------------------------------------------------------------------------
--
-- P_16_conv_datamover: Updated from P_14 to use conv_engine_v3 with
-- asymmetric padding (4 independent pad values: top, bottom, left, right).
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
-- BRAM: 1024 x 32-bit words with per-byte write-enables (P_100 pattern).
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
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity conv_stream_wrapper is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -----------------------------------------------------------------------
        -- AXI-Lite Slave (configuration registers)
        -----------------------------------------------------------------------
        s_axi_awaddr  : in  std_logic_vector(6 downto 0);
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

        s_axi_araddr  : in  std_logic_vector(6 downto 0);
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
        m_axis_tkeep  : out std_logic_vector(3 downto 0)
    );
end entity conv_stream_wrapper;

architecture rtl of conv_stream_wrapper is

    ---------------------------------------------------------------------------
    -- FSM
    ---------------------------------------------------------------------------
    type state_t is (S_IDLE, S_LOAD, S_CONV, S_DRAIN);
    signal state : state_t := S_IDLE;

    ---------------------------------------------------------------------------
    -- Config registers
    ---------------------------------------------------------------------------
    signal reg_n_words     : unsigned(9 downto 0)  := (others => '0');
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

    -- Command bits (self-clearing pulses)
    signal cmd_load    : std_logic := '0';
    signal cmd_start   : std_logic := '0';
    signal cmd_drain   : std_logic := '0';
    signal done_latch  : std_logic := '0';

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
    -- 4 KB BRAM: 1024 words x 32 bits, P_100 inference pattern
    ---------------------------------------------------------------------------
    constant BRAM_DEPTH : natural := 1024;
    type ram_t is array (0 to BRAM_DEPTH-1) of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

    -- Single-port signals (time-division muxed by FSM state)
    signal bram_en    : std_logic;
    signal bram_we    : std_logic_vector(3 downto 0);
    signal bram_addr  : unsigned(9 downto 0);
    signal bram_din   : std_logic_vector(31 downto 0);
    signal bram_dout  : std_logic_vector(31 downto 0) := (others => '0');

    -- Conv-side byte selection (pipelined for BRAM read latency)
    signal conv_byte_sel   : unsigned(1 downto 0);
    signal conv_byte_sel_d : unsigned(1 downto 0) := "00";

    -- Conv -> BRAM
    signal conv_bram_en   : std_logic;
    signal conv_bram_we   : std_logic_vector(3 downto 0);
    signal conv_bram_addr : unsigned(9 downto 0);
    signal conv_bram_din  : std_logic_vector(31 downto 0);

    -- Stream LOAD -> BRAM
    signal load_bram_en   : std_logic;
    signal load_bram_we   : std_logic_vector(3 downto 0);
    signal load_bram_addr : unsigned(9 downto 0);
    signal load_bram_din  : std_logic_vector(31 downto 0);

    -- Stream DRAIN <- BRAM
    signal drain_bram_en   : std_logic;
    signal drain_bram_addr : unsigned(9 downto 0);

    -- Load/Drain counters
    signal load_addr   : unsigned(9 downto 0) := (others => '0');
    signal drain_addr  : unsigned(9 downto 0) := (others => '0');
    signal drain_count : unsigned(9 downto 0) := (others => '0');

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

    -- FSM state for status register
    fsm_code <= "00" when state = S_IDLE  else
                "01" when state = S_LOAD  else
                "10" when state = S_CONV  else
                "11";

    -- m_axis_tkeep: all bytes valid during drain
    m_axis_tkeep <= "1111" when drain_valid_pipe = '1' else "0000";

    ---------------------------------------------------------------------------
    -- conv_engine_v3 instance (asymmetric padding)
    ---------------------------------------------------------------------------
    u_conv : entity work.conv_engine_v3
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
            dbg_act_addr     => open
        );

    ---------------------------------------------------------------------------
    -- Conv -> BRAM adapter (byte-addressed -> word-addressed, same as P_13)
    ---------------------------------------------------------------------------
    conv_byte_sel <= ddr_rd_addr(1 downto 0) when ddr_wr_en = '0'
                     else ddr_wr_addr(1 downto 0);

    conv_bram_en   <= ddr_rd_en or ddr_wr_en;
    conv_bram_addr <= ddr_wr_addr(11 downto 2) when ddr_wr_en = '1'
                      else ddr_rd_addr(11 downto 2);
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

    s_axis_tready <= '1' when (state = S_LOAD) else '0';

    ---------------------------------------------------------------------------
    -- Stream DRAIN <- BRAM: read full 32-bit words sequentially
    ---------------------------------------------------------------------------
    drain_bram_en   <= drain_active and (not drain_stall);
    drain_bram_addr <= drain_addr;

    -- Stall when downstream is not ready and we already have valid data
    drain_stall <= drain_valid_pipe and (not m_axis_tready);

    m_axis_tdata  <= bram_dout;
    m_axis_tvalid <= drain_valid_pipe;
    m_axis_tlast  <= drain_last_pipe;

    ---------------------------------------------------------------------------
    -- BRAM port mux: who owns the port depends on FSM state
    ---------------------------------------------------------------------------
    bram_en   <= conv_bram_en   when state = S_CONV  else
                 load_bram_en   when state = S_LOAD  else
                 drain_bram_en  when state = S_DRAIN else
                 '0';

    bram_we   <= conv_bram_we   when state = S_CONV  else
                 load_bram_we   when state = S_LOAD  else
                 "0000";  -- DRAIN and IDLE: read-only

    bram_addr <= conv_bram_addr when state = S_CONV  else
                 load_bram_addr when state = S_LOAD  else
                 drain_bram_addr when state = S_DRAIN else
                 (others => '0');

    bram_din  <= conv_bram_din  when state = S_CONV  else
                 load_bram_din  when state = S_LOAD  else
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
            else
                -- Default: single-cycle pulse
                ce_start <= '0';

                case state is
                    when S_IDLE =>
                        drain_valid_pipe <= '0';
                        drain_last_pipe  <= '0';
                        drain_active     <= '0';

                        if cmd_load = '1' then
                            state     <= S_LOAD;
                            load_addr <= (others => '0');
                        elsif cmd_start = '1' then
                            state      <= S_CONV;
                            ce_start   <= '1';
                            done_latch <= '0';
                        elsif cmd_drain = '1' then
                            state       <= S_DRAIN;
                            drain_addr  <= (others => '0');
                            drain_count <= (others => '0');
                            drain_active <= '1';
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
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite Write Channel
    ---------------------------------------------------------------------------
    p_axi_wr : process(clk)
        variable v_addr : unsigned(6 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                axi_awready_r <= '0';
                axi_wready_r  <= '0';
                axi_bvalid_r  <= '0';
                cmd_load       <= '0';
                cmd_start      <= '0';
                cmd_drain      <= '0';
            else
                axi_awready_r <= '0';
                axi_wready_r  <= '0';

                -- Self-clearing command pulses
                cmd_load  <= '0';
                cmd_start <= '0';
                cmd_drain <= '0';

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
                        when 16#04# => reg_n_words      <= unsigned(s_axi_wdata(9 downto 0));
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
        variable v_addr : unsigned(6 downto 0);
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
                                    reg_rd_data(9 downto 0) <= std_logic_vector(reg_n_words);
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
