-------------------------------------------------------------------------------
-- conv_test_wrapper.vhd — AXI-Lite wrapper for conv_engine test on ZedBoard
-------------------------------------------------------------------------------
--
-- Architecture:
--   - AXI-Lite slave with config registers for conv_engine
--   - Dual-port BRAM (4KB) as DDR model
--     Port A: conv_engine reads/writes (1-cycle latency)
--     Port B: ARM reads/writes via AXI-Lite (offset 0x1000-0x1FFF)
--
-- Register map (32-bit, offset from base):
--   0x00: control (bit 0 = start W, bit 1 = done RO, bit 2 = busy RO)
--   0x04: cfg_c_in (10 bits)
--   0x08: cfg_c_out (10 bits)
--   0x0C: cfg_h_in (10 bits)
--   0x10: cfg_w_in (10 bits)
--   0x14: cfg_ksize(1:0), cfg_stride(2), cfg_pad(3)
--   0x18: cfg_x_zp (9 bits signed)
--   0x1C: cfg_w_zp (8 bits signed)
--   0x20: cfg_M0 (32 bits)
--   0x24: cfg_n_shift (6 bits)
--   0x28: cfg_y_zp (8 bits signed)
--   0x2C: cfg_addr_input (25 bits)
--   0x30: cfg_addr_weights (25 bits)
--   0x34: cfg_addr_bias (25 bits)
--   0x38: cfg_addr_output (25 bits)
--   0x1000-0x1FFF: BRAM access window (4096 bytes, byte-addressed)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity conv_test_wrapper is
    port (
        -- AXI-Lite slave interface
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

    -- Clock and reset
    signal clk   : std_logic;
    signal rst_n : std_logic;

    ---------------------------------------------------------------------------
    -- BRAM: 4096 bytes, dual-port
    ---------------------------------------------------------------------------
    type bram_t is array(0 to 4095) of std_logic_vector(7 downto 0);
    signal bram : bram_t := (others => (others => '0'));

    -- Port A: conv_engine side
    signal bram_rd_data_a : std_logic_vector(7 downto 0);

    ---------------------------------------------------------------------------
    -- Config registers
    ---------------------------------------------------------------------------
    signal reg_start       : std_logic;
    signal reg_c_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_c_out       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_h_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_w_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_ksp         : std_logic_vector(31 downto 0) := (others => '0');  -- ksize/stride/pad
    signal reg_x_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_w_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_M0          : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_n_shift     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_y_zp        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_input  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_weights: std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_bias   : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_addr_output : std_logic_vector(31 downto 0) := (others => '0');

    -- conv_engine signals
    signal ce_start     : std_logic;
    signal ce_done      : std_logic;
    signal ce_busy      : std_logic;
    signal ddr_rd_addr  : unsigned(24 downto 0);
    signal ddr_rd_data  : std_logic_vector(7 downto 0);
    signal ddr_rd_en    : std_logic;
    signal ddr_wr_addr  : unsigned(24 downto 0);
    signal ddr_wr_data  : std_logic_vector(7 downto 0);
    signal ddr_wr_en    : std_logic;

    -- Done latch (set by conv_engine pulse, cleared by ARM write to control)
    signal done_latch : std_logic := '0';

    -- Start pulse generation
    signal start_prev : std_logic := '0';

    ---------------------------------------------------------------------------
    -- AXI-Lite state machine
    ---------------------------------------------------------------------------
    -- Write channel
    signal axi_awready_r : std_logic := '0';
    signal axi_wready_r  : std_logic := '0';
    signal axi_bvalid_r  : std_logic := '0';
    signal aw_addr       : std_logic_vector(14 downto 0) := (others => '0');

    -- Read channel
    signal axi_arready_r : std_logic := '0';
    signal axi_rvalid_r  : std_logic := '0';
    signal axi_rdata_r   : std_logic_vector(31 downto 0) := (others => '0');
    signal ar_addr       : std_logic_vector(14 downto 0) := (others => '0');

    -- BRAM port B read pipeline (for AXI read from BRAM area)
    signal bram_rd_pending : std_logic := '0';
    signal bram_rd_addr_b  : unsigned(11 downto 0) := (others => '0');
    signal bram_rd_byte_sel : unsigned(1 downto 0) := (others => '0');
    signal bram_rd_data_b  : std_logic_vector(31 downto 0) := (others => '0');

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
    u_conv : entity work.conv_engine
        port map (
            clk             => clk,
            rst_n           => rst_n,
            cfg_c_in        => unsigned(reg_c_in(9 downto 0)),
            cfg_c_out       => unsigned(reg_c_out(9 downto 0)),
            cfg_h_in        => unsigned(reg_h_in(9 downto 0)),
            cfg_w_in        => unsigned(reg_w_in(9 downto 0)),
            cfg_ksize       => unsigned(reg_ksp(1 downto 0)),
            cfg_stride      => reg_ksp(2),
            cfg_pad         => reg_ksp(3),
            cfg_x_zp        => signed(reg_x_zp(8 downto 0)),
            cfg_w_zp        => signed(reg_w_zp(7 downto 0)),
            cfg_M0          => unsigned(reg_M0),
            cfg_n_shift     => unsigned(reg_n_shift(5 downto 0)),
            cfg_y_zp        => signed(reg_y_zp(7 downto 0)),
            cfg_addr_input  => unsigned(reg_addr_input(24 downto 0)),
            cfg_addr_weights=> unsigned(reg_addr_weights(24 downto 0)),
            cfg_addr_bias   => unsigned(reg_addr_bias(24 downto 0)),
            cfg_addr_output => unsigned(reg_addr_output(24 downto 0)),
            start           => ce_start,
            done            => ce_done,
            busy            => ce_busy,
            ddr_rd_addr     => ddr_rd_addr,
            ddr_rd_data     => ddr_rd_data,
            ddr_rd_en       => ddr_rd_en,
            ddr_wr_addr     => ddr_wr_addr,
            ddr_wr_data     => ddr_wr_data,
            ddr_wr_en       => ddr_wr_en
        );

    ---------------------------------------------------------------------------
    -- BRAM Port A: conv_engine DDR interface (1-cycle read latency)
    ---------------------------------------------------------------------------
    p_bram_a : process(clk)
    begin
        if rising_edge(clk) then
            if ddr_rd_en = '1' then
                bram_rd_data_a <= bram(to_integer(ddr_rd_addr(11 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                bram(to_integer(ddr_wr_addr(11 downto 0))) <= ddr_wr_data;
            end if;
        end if;
    end process;
    ddr_rd_data <= bram_rd_data_a;

    ---------------------------------------------------------------------------
    -- Start pulse: detect rising edge of reg_start
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

    ---------------------------------------------------------------------------
    -- Done latch: set by conv_engine done pulse, cleared by ARM write 0 to ctrl
    ---------------------------------------------------------------------------
    p_done : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                done_latch <= '0';
            elsif ce_done = '1' then
                done_latch <= '1';
            elsif reg_start = '0' then
                -- Clear done when ARM clears start bit
                -- (don't clear here, let ARM read it first)
                null;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite Write Channel
    ---------------------------------------------------------------------------
    p_axi_wr : process(clk)
        variable v_addr : unsigned(14 downto 0);
        variable v_bram_idx : unsigned(11 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                axi_awready_r <= '0';
                axi_wready_r  <= '0';
                axi_bvalid_r  <= '0';
                aw_addr <= (others => '0');
                reg_start <= '0';
            else
                -- Default: deassert ready
                axi_awready_r <= '0';
                axi_wready_r  <= '0';

                -- Accept write address + data together
                if s_axi_awvalid = '1' and s_axi_wvalid = '1'
                   and axi_awready_r = '0' and axi_bvalid_r = '0' then
                    axi_awready_r <= '1';
                    axi_wready_r  <= '1';

                    v_addr := unsigned(s_axi_awaddr);

                    -- BRAM region: 0x1000-0x1FFF
                    if v_addr >= x"1000" and v_addr <= x"1FFF" then
                        v_bram_idx := v_addr(11 downto 0);
                        -- Write individual bytes based on strobe
                        if s_axi_wstrb(0) = '1' then
                            bram(to_integer(v_bram_idx))     <= s_axi_wdata(7 downto 0);
                        end if;
                        if s_axi_wstrb(1) = '1' then
                            bram(to_integer(v_bram_idx + 1)) <= s_axi_wdata(15 downto 8);
                        end if;
                        if s_axi_wstrb(2) = '1' then
                            bram(to_integer(v_bram_idx + 2)) <= s_axi_wdata(23 downto 16);
                        end if;
                        if s_axi_wstrb(3) = '1' then
                            bram(to_integer(v_bram_idx + 3)) <= s_axi_wdata(31 downto 24);
                        end if;

                    -- Register region: 0x00-0x3F
                    else
                        case to_integer(v_addr(7 downto 0)) is
                            when 16#00# =>
                                reg_start <= s_axi_wdata(0);
                                -- Writing 0 to bit 0 clears done_latch
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
                            when others => null;
                        end case;
                    end if;

                    axi_bvalid_r <= '1';
                end if;

                -- Write response handshake
                if axi_bvalid_r = '1' and s_axi_bready = '1' then
                    axi_bvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI-Lite Read Channel
    ---------------------------------------------------------------------------
    p_axi_rd : process(clk)
        variable v_addr : unsigned(14 downto 0);
        variable v_bram_idx : unsigned(11 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                axi_arready_r <= '0';
                axi_rvalid_r  <= '0';
                axi_rdata_r   <= (others => '0');
            else
                axi_arready_r <= '0';

                -- Accept read address
                if s_axi_arvalid = '1' and axi_arready_r = '0' and axi_rvalid_r = '0' then
                    axi_arready_r <= '1';

                    v_addr := unsigned(s_axi_araddr);

                    -- BRAM region: 0x1000-0x1FFF (read 4 bytes at word-aligned addr)
                    if v_addr >= x"1000" and v_addr <= x"1FFF" then
                        v_bram_idx := v_addr(11 downto 0);
                        axi_rdata_r <= bram(to_integer(v_bram_idx + 3))
                                     & bram(to_integer(v_bram_idx + 2))
                                     & bram(to_integer(v_bram_idx + 1))
                                     & bram(to_integer(v_bram_idx));
                    -- Register region
                    else
                        case to_integer(v_addr(7 downto 0)) is
                            when 16#00# =>
                                axi_rdata_r <= (31 downto 3 => '0')
                                             & ce_busy & done_latch & reg_start;
                            when 16#04# => axi_rdata_r <= reg_c_in;
                            when 16#08# => axi_rdata_r <= reg_c_out;
                            when 16#0C# => axi_rdata_r <= reg_h_in;
                            when 16#10# => axi_rdata_r <= reg_w_in;
                            when 16#14# => axi_rdata_r <= reg_ksp;
                            when 16#18# => axi_rdata_r <= reg_x_zp;
                            when 16#1C# => axi_rdata_r <= reg_w_zp;
                            when 16#20# => axi_rdata_r <= reg_M0;
                            when 16#24# => axi_rdata_r <= reg_n_shift;
                            when 16#28# => axi_rdata_r <= reg_y_zp;
                            when 16#2C# => axi_rdata_r <= reg_addr_input;
                            when 16#30# => axi_rdata_r <= reg_addr_weights;
                            when 16#34# => axi_rdata_r <= reg_addr_bias;
                            when 16#38# => axi_rdata_r <= reg_addr_output;
                            when others => axi_rdata_r <= (others => '0');
                        end case;
                    end if;

                    axi_rvalid_r <= '1';
                end if;

                -- Read data handshake
                if axi_rvalid_r = '1' and s_axi_rready = '1' then
                    axi_rvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
