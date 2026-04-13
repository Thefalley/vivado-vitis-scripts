-------------------------------------------------------------------------------
-- conv_test_wrapper.vhd — AXI-Lite wrapper for conv_engine test on ZedBoard
-------------------------------------------------------------------------------
--
-- Architecture (post-debug rewrite):
--   - AXI-Lite slave with config registers for conv_engine
--   - 4 KB BRAM (1024 x 32 bits) inferred via P_100 pattern:
--       * ram_style="block" forces BRAM (not LUTRAM)
--       * Single-port with sync read + byte-write-enables
--       * ce_busy muxes the port: conv while running, AXI while idle
--   - Conv reads/writes bytes via address mux + byte extraction from the
--     32-bit word output (1-cycle pipelined to match BRAM read latency)
--
-- The ARM and conv_engine never access the BRAM simultaneously:
--   - ARM writes data, configures regs, pulses start, polls status
--   - During busy, ARM only reads register space (not BRAM)
--   - When busy=0, ARM reads output from BRAM
--
-- Register map (32-bit, offset from base):
--   0x00: control (bit 0 = start W, bit 1 = done RO, bit 2 = busy RO)
--   0x04-0x3C: config registers
--   0x40: cfg_pad_top    (2 bits)
--   0x44: cfg_pad_bottom (2 bits)
--   0x48: cfg_pad_left   (2 bits)
--   0x4C: cfg_pad_right  (2 bits)
--   0x1000-0x1FFF: BRAM access window (4096 bytes, byte-addressed)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity conv_test_wrapper is
    port (
        s_axi_aclk    : in  std_logic;
        s_axi_aresetn : in  std_logic;

        s_axi_awaddr  : in  std_logic_vector(14 downto 0);
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

        s_axi_araddr  : in  std_logic_vector(14 downto 0);
        s_axi_arprot  : in  std_logic_vector(2 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;

        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic
    );
end entity conv_test_wrapper;

architecture rtl of conv_test_wrapper is

    signal clk   : std_logic;
    signal rst_n : std_logic;

    ---------------------------------------------------------------------------
    -- Config registers
    ---------------------------------------------------------------------------
    signal reg_start       : std_logic := '0';
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
    signal reg_pad_top     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_bottom  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_left    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_pad_right   : std_logic_vector(31 downto 0) := (others => '0');

    -- conv_engine signals
    signal ce_start     : std_logic := '0';
    signal ce_done      : std_logic;
    signal ce_busy      : std_logic;
    signal ddr_rd_addr  : unsigned(24 downto 0);
    signal ddr_rd_data  : std_logic_vector(7 downto 0);
    signal ddr_rd_en    : std_logic;
    signal ddr_wr_addr  : unsigned(24 downto 0);
    signal ddr_wr_data  : std_logic_vector(7 downto 0);
    signal ddr_wr_en    : std_logic;

    signal done_latch : std_logic := '0';
    signal start_prev : std_logic := '0';

    ---------------------------------------------------------------------------
    -- 4 KB BRAM: 1024 words x 32 bits, P_100 inference pattern
    ---------------------------------------------------------------------------
    constant BRAM_DEPTH : natural := 1024;
    type ram_t is array (0 to BRAM_DEPTH-1) of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

    -- Single-port signals (muxed by ce_busy)
    signal bram_en    : std_logic;
    signal bram_we    : std_logic_vector(3 downto 0);
    signal bram_addr  : unsigned(9 downto 0);
    signal bram_din   : std_logic_vector(31 downto 0);
    signal bram_dout  : std_logic_vector(31 downto 0) := (others => '0');

    -- Conv-side byte selection (pipelined to match BRAM read latency)
    signal conv_byte_sel   : unsigned(1 downto 0);
    signal conv_byte_sel_d : unsigned(1 downto 0) := "00";

    -- Conv→BRAM combinational signals
    signal conv_bram_en   : std_logic;
    signal conv_bram_we   : std_logic_vector(3 downto 0);
    signal conv_bram_addr : unsigned(9 downto 0);
    signal conv_bram_din  : std_logic_vector(31 downto 0);

    -- AXI→BRAM combinational signals
    signal axi_bram_en   : std_logic;
    signal axi_bram_we   : std_logic_vector(3 downto 0);
    signal axi_bram_addr : unsigned(9 downto 0);
    signal axi_bram_din  : std_logic_vector(31 downto 0);

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
    signal rd_is_bram    : std_logic := '0';
    signal reg_rd_data   : std_logic_vector(31 downto 0) := (others => '0');

begin

    clk   <= s_axi_aclk;
    rst_n <= s_axi_aresetn;

    s_axi_awready <= axi_awready_r;
    s_axi_wready  <= axi_wready_r;
    s_axi_bresp   <= "00";
    s_axi_bvalid  <= axi_bvalid_r;

    s_axi_arready <= axi_arready_r;
    s_axi_rdata   <= axi_rdata_r;
    s_axi_rresp   <= "00";
    s_axi_rvalid  <= axi_rvalid_r;

    ---------------------------------------------------------------------------
    -- conv_engine instance
    ---------------------------------------------------------------------------
    u_conv : entity work.conv_engine_v3
        port map (
            clk             => clk,
            rst_n           => rst_n,
            cfg_c_in        => unsigned(reg_c_in(9 downto 0)),
            cfg_c_out       => unsigned(reg_c_out(9 downto 0)),
            cfg_h_in        => unsigned(reg_h_in(9 downto 0)),
            cfg_w_in        => unsigned(reg_w_in(9 downto 0)),
            cfg_ksize       => unsigned(reg_ksp(1 downto 0)),
            cfg_stride      => reg_ksp(2),
            cfg_pad_top     => unsigned(reg_pad_top(1 downto 0)),
            cfg_pad_bottom  => unsigned(reg_pad_bottom(1 downto 0)),
            cfg_pad_left    => unsigned(reg_pad_left(1 downto 0)),
            cfg_pad_right   => unsigned(reg_pad_right(1 downto 0)),
            cfg_x_zp        => signed(reg_x_zp(8 downto 0)),
            cfg_w_zp        => signed(reg_w_zp(7 downto 0)),
            cfg_M0          => unsigned(reg_M0),
            cfg_n_shift     => unsigned(reg_n_shift(5 downto 0)),
            cfg_y_zp        => signed(reg_y_zp(7 downto 0)),
            cfg_addr_input  => unsigned(reg_addr_input(24 downto 0)),
            cfg_addr_weights=> unsigned(reg_addr_weights(24 downto 0)),
            cfg_addr_bias   => unsigned(reg_addr_bias(24 downto 0)),
            cfg_addr_output => unsigned(reg_addr_output(24 downto 0)),
            cfg_ic_tile_size=> unsigned(reg_ic_tile_size(9 downto 0)),
            start           => ce_start,
            done            => ce_done,
            busy            => ce_busy,
            ddr_rd_addr     => ddr_rd_addr,
            ddr_rd_data     => ddr_rd_data,
            ddr_rd_en       => ddr_rd_en,
            ddr_wr_addr     => ddr_wr_addr,
            ddr_wr_data     => ddr_wr_data,
            ddr_wr_en       => ddr_wr_en,
            dbg_state       => open,
            dbg_oh          => open,
            dbg_ow          => open,
            dbg_kh          => open,
            dbg_kw          => open,
            dbg_ic          => open,
            dbg_oc_tile_base=> open,
            dbg_ic_tile_base=> open,
            dbg_w_base      => open,
            dbg_mac_a       => open,
            dbg_mac_b       => open,
            dbg_mac_bi      => open,
            dbg_mac_acc     => open,
            dbg_mac_vi      => open,
            dbg_mac_clr     => open,
            dbg_mac_lb      => open,
            dbg_pad         => open,
            dbg_act_addr    => open
        );

    ---------------------------------------------------------------------------
    -- Conv→BRAM adapter
    -- The conv sees an 8-bit byte-addressed interface. Map it onto the 32-bit
    -- word-addressed BRAM: extract word addr = byte_addr[11:2], byte lane =
    -- byte_addr[1:0]. For writes, set one byte-enable and replicate the byte
    -- across all 4 lanes (the BE selects which sticks). For reads, delay the
    -- byte selector by 1 cycle to match BRAM read latency, then mux.
    ---------------------------------------------------------------------------
    conv_byte_sel <= ddr_rd_addr(1 downto 0) when ddr_wr_en = '0'
                     else ddr_wr_addr(1 downto 0);

    conv_bram_en   <= ddr_rd_en or ddr_wr_en;
    conv_bram_addr <= ddr_wr_addr(11 downto 2) when ddr_wr_en = '1'
                      else ddr_rd_addr(11 downto 2);
    conv_bram_din  <= ddr_wr_data & ddr_wr_data & ddr_wr_data & ddr_wr_data;

    conv_bram_we   <= "0001" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "00") else
                      "0010" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "01") else
                      "0100" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "10") else
                      "1000" when (ddr_wr_en = '1' and ddr_wr_addr(1 downto 0) = "11") else
                      "0000";

    ---------------------------------------------------------------------------
    -- Port mux: conv owns the BRAM when busy, AXI owns it otherwise
    ---------------------------------------------------------------------------
    bram_en   <= conv_bram_en   when ce_busy = '1' else axi_bram_en;
    bram_we   <= conv_bram_we   when ce_busy = '1' else axi_bram_we;
    bram_addr <= conv_bram_addr when ce_busy = '1' else axi_bram_addr;
    bram_din  <= conv_bram_din  when ce_busy = '1' else axi_bram_din;

    ---------------------------------------------------------------------------
    -- Single BRAM process (P_100 inference pattern)
    -- Sync read + byte-write-enables. Vivado infers this as RAMB36E1 with
    -- the ram_style="block" attribute forcing block RAM.
    ---------------------------------------------------------------------------
    p_bram : process(clk)
    begin
        if rising_edge(clk) then
            if bram_en = '1' then
                if bram_we(0) = '1' then
                    ram(to_integer(bram_addr))(7 downto 0)   <= bram_din(7 downto 0);
                end if;
                if bram_we(1) = '1' then
                    ram(to_integer(bram_addr))(15 downto 8)  <= bram_din(15 downto 8);
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
    -- Conv read path: delay the byte selector 1 cycle to match BRAM latency
    -- then mux the word output down to a byte.
    ---------------------------------------------------------------------------
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
    -- AXI-Lite → BRAM combinational driver (only used while conv is idle)
    ---------------------------------------------------------------------------
    axi_bram_en <= '1' when (s_axi_awvalid = '1' and s_axi_wvalid = '1'
                              and axi_awready_r = '0' and axi_bvalid_r = '0'
                              and unsigned(s_axi_awaddr) >= x"1000"
                              and unsigned(s_axi_awaddr) <= x"1FFF")
                        or (s_axi_arvalid = '1' and rd_state = RD_IDLE
                              and axi_rvalid_r = '0'
                              and unsigned(s_axi_araddr) >= x"1000"
                              and unsigned(s_axi_araddr) <= x"1FFF")
                   else '0';

    axi_bram_we <= s_axi_wstrb when (s_axi_awvalid = '1' and s_axi_wvalid = '1'
                                     and axi_awready_r = '0' and axi_bvalid_r = '0'
                                     and unsigned(s_axi_awaddr) >= x"1000"
                                     and unsigned(s_axi_awaddr) <= x"1FFF")
                   else (others => '0');

    axi_bram_addr <= unsigned(s_axi_awaddr(11 downto 2))
                     when (s_axi_awvalid = '1' and s_axi_wvalid = '1'
                           and axi_awready_r = '0' and axi_bvalid_r = '0'
                           and unsigned(s_axi_awaddr) >= x"1000"
                           and unsigned(s_axi_awaddr) <= x"1FFF")
                     else unsigned(s_axi_araddr(11 downto 2));

    axi_bram_din <= s_axi_wdata;

    ---------------------------------------------------------------------------
    -- AXI-Lite Write Channel (register writes; BRAM writes go via axi_bram_*)
    ---------------------------------------------------------------------------
    p_axi_wr : process(clk)
        variable v_addr : unsigned(14 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                axi_awready_r <= '0';
                axi_wready_r  <= '0';
                axi_bvalid_r  <= '0';
                reg_start     <= '0';
            else
                axi_awready_r <= '0';
                axi_wready_r  <= '0';

                if s_axi_awvalid = '1' and s_axi_wvalid = '1'
                   and axi_awready_r = '0' and axi_bvalid_r = '0' then
                    axi_awready_r <= '1';
                    axi_wready_r  <= '1';

                    v_addr := unsigned(s_axi_awaddr);

                    if v_addr < x"1000" then
                        case to_integer(v_addr(7 downto 0)) is
                            when 16#00# => reg_start        <= s_axi_wdata(0);
                            when 16#04# => reg_c_in         <= s_axi_wdata;
                            when 16#08# => reg_c_out        <= s_axi_wdata;
                            when 16#0C# => reg_h_in         <= s_axi_wdata;
                            when 16#10# => reg_w_in         <= s_axi_wdata;
                            when 16#14# => reg_ksp          <= s_axi_wdata;
                            when 16#18# => reg_x_zp         <= s_axi_wdata;
                            when 16#1C# => reg_w_zp         <= s_axi_wdata;
                            when 16#20# => reg_M0           <= s_axi_wdata;
                            when 16#24# => reg_n_shift      <= s_axi_wdata;
                            when 16#28# => reg_y_zp         <= s_axi_wdata;
                            when 16#2C# => reg_addr_input   <= s_axi_wdata;
                            when 16#30# => reg_addr_weights <= s_axi_wdata;
                            when 16#34# => reg_addr_bias    <= s_axi_wdata;
                            when 16#38# => reg_addr_output  <= s_axi_wdata;
                            when 16#3C# => reg_ic_tile_size <= s_axi_wdata;
                            when 16#40# => reg_pad_top      <= s_axi_wdata;
                            when 16#44# => reg_pad_bottom   <= s_axi_wdata;
                            when 16#48# => reg_pad_left     <= s_axi_wdata;
                            when 16#4C# => reg_pad_right    <= s_axi_wdata;
                            when others => null;
                        end case;
                    end if;

                    axi_bvalid_r <= '1';
                end if;

                if axi_bvalid_r = '1' and s_axi_bready = '1' then
                    axi_bvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite Read Channel (1-cycle pipeline to match BRAM latency)
    ---------------------------------------------------------------------------
    p_axi_rd : process(clk)
        variable v_addr : unsigned(14 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rd_state      <= RD_IDLE;
                axi_arready_r <= '0';
                axi_rvalid_r  <= '0';
                axi_rdata_r   <= (others => '0');
                rd_is_bram    <= '0';
            else
                axi_arready_r <= '0';

                case rd_state is
                    when RD_IDLE =>
                        v_addr := unsigned(s_axi_araddr);
                        if s_axi_arvalid = '1' and axi_rvalid_r = '0' then
                            axi_arready_r <= '1';

                            if v_addr >= x"1000" and v_addr <= x"1FFF" then
                                rd_is_bram <= '1';
                            else
                                rd_is_bram <= '0';
                                case to_integer(v_addr(7 downto 0)) is
                                    when 16#00# =>
                                        reg_rd_data <= (31 downto 3 => '0')
                                                     & ce_busy & done_latch & reg_start;
                                    when 16#04# => reg_rd_data <= reg_c_in;
                                    when 16#08# => reg_rd_data <= reg_c_out;
                                    when 16#0C# => reg_rd_data <= reg_h_in;
                                    when 16#10# => reg_rd_data <= reg_w_in;
                                    when 16#14# => reg_rd_data <= reg_ksp;
                                    when 16#18# => reg_rd_data <= reg_x_zp;
                                    when 16#1C# => reg_rd_data <= reg_w_zp;
                                    when 16#20# => reg_rd_data <= reg_M0;
                                    when 16#24# => reg_rd_data <= reg_n_shift;
                                    when 16#28# => reg_rd_data <= reg_y_zp;
                                    when 16#2C# => reg_rd_data <= reg_addr_input;
                                    when 16#30# => reg_rd_data <= reg_addr_weights;
                                    when 16#34# => reg_rd_data <= reg_addr_bias;
                                    when 16#38# => reg_rd_data <= reg_addr_output;
                                    when 16#3C# => reg_rd_data <= reg_ic_tile_size;
                                    when 16#40# => reg_rd_data <= reg_pad_top;
                                    when 16#44# => reg_rd_data <= reg_pad_bottom;
                                    when 16#48# => reg_rd_data <= reg_pad_left;
                                    when 16#4C# => reg_rd_data <= reg_pad_right;
                                    when others => reg_rd_data <= (others => '0');
                                end case;
                            end if;

                            rd_state <= RD_WAIT;
                        end if;

                    when RD_WAIT =>
                        if rd_is_bram = '1' then
                            axi_rdata_r <= bram_dout;
                        else
                            axi_rdata_r <= reg_rd_data;
                        end if;
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

    ---------------------------------------------------------------------------
    -- Start pulse + done latch
    ---------------------------------------------------------------------------
    p_start : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                start_prev <= '0';
                ce_start   <= '0';
            else
                ce_start   <= reg_start and not start_prev;
                start_prev <= reg_start;
            end if;
        end if;
    end process;

    p_done : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                done_latch <= '0';
            elsif ce_done = '1' then
                done_latch <= '1';
            end if;
        end if;
    end process;

end architecture rtl;
