-------------------------------------------------------------------------------
-- test_stride2_tb.vhd -- Verify conv_engine_v2 with 3x3 conv, stride=2, pad=1
-------------------------------------------------------------------------------
-- Config: ksize="10" (3x3), stride='1' (stride=2), pad='1', c_in=3, c_out=32*
-- Input:  5x5x3 = 75 bytes (values 1..75, CHW layout)
-- Weight: 27 bytes for filter 0 = all ones; filters 1..31 = 0
-- Bias:   1000 for filter 0; 0 for filters 1..31
-- Quant:  x_zp=-128, w_zp=0, M0=656954014, n_shift=37, y_zp=-17
--
-- h_out = (5 + 2*1 - 3)/2 + 1 = 3, w_out = 3
--
-- Expected oc=0 output (9 pixels, row-major):
--   -3, 1, -3, 2, 9, 2, -2, 3, -2
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.mac_array_pkg.all;

entity test_stride2_tb is
end;

architecture bench of test_stride2_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal cfg_c_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out     : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize     : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride    : std_logic := '0';
    signal cfg_pad       : std_logic := '0';
    signal cfg_x_zp      : signed(8 downto 0) := (others => '0');
    signal cfg_w_zp      : signed(7 downto 0) := (others => '0');
    signal cfg_M0        : unsigned(31 downto 0) := (others => '0');
    signal cfg_n_shift   : unsigned(5 downto 0) := (others => '0');
    signal cfg_y_zp      : signed(7 downto 0) := (others => '0');
    signal cfg_addr_input   : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_weights : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_bias    : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_output  : unsigned(24 downto 0) := (others => '0');
    signal cfg_ic_tile_size : unsigned(9 downto 0) := (others => '0');
    signal start         : std_logic := '0';
    signal done          : std_logic;
    signal busy          : std_logic;
    signal ddr_rd_addr   : unsigned(24 downto 0);
    signal ddr_rd_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en     : std_logic;
    signal ddr_wr_addr   : unsigned(24 downto 0);
    signal ddr_wr_data   : std_logic_vector(7 downto 0);
    signal ddr_wr_en     : std_logic;

    -- Debug (mandatory ports)
    signal dbg_state    : integer range 0 to 63;
    signal dbg_oh, dbg_ow, dbg_kh, dbg_kw, dbg_ic : unsigned(9 downto 0);
    signal dbg_oc_tile_base, dbg_ic_tile_base : unsigned(9 downto 0);
    signal dbg_w_base   : unsigned(19 downto 0);
    signal dbg_mac_a    : signed(8 downto 0);
    signal dbg_mac_b    : weight_array_t;
    signal dbg_mac_bi   : bias_array_t;
    signal dbg_mac_acc  : acc_array_t;
    signal dbg_mac_vi, dbg_mac_clr, dbg_mac_lb, dbg_pad : std_logic;
    signal dbg_act_addr : unsigned(24 downto 0);

    -- DDR address map
    constant ADDR_INPUT   : natural := 16#0000#;
    constant ADDR_WEIGHTS : natural := 16#0400#;
    constant ADDR_BIAS    : natural := 16#0800#;
    constant ADDR_OUTPUT  : natural := 16#0C00#;

    signal sim_done : std_logic := '0';

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    uut : entity work.conv_engine_v2
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride, cfg_pad => cfg_pad,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data,
            ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data,
            ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_oc_tile_base => dbg_oc_tile_base, dbg_ic_tile_base => dbg_ic_tile_base,
            dbg_w_base => dbg_w_base,
            dbg_mac_a => dbg_mac_a, dbg_mac_b => dbg_mac_b, dbg_mac_bi => dbg_mac_bi,
            dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr, dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr
        );

    p_main : process
        type ddr_t is array(0 to 8191) of std_logic_vector(7 downto 0);
        variable ddr : ddr_t := (others => (others => '0'));

        procedure ddr_w8(addr : natural; val : integer) is
        begin
            ddr(addr) := std_logic_vector(to_signed(val, 8));
        end procedure;

        procedure ddr_w32(addr : natural; val : integer) is
            variable v : std_logic_vector(31 downto 0);
        begin
            v := std_logic_vector(to_signed(val, 32));
            ddr(addr + 0) := v( 7 downto  0);
            ddr(addr + 1) := v(15 downto  8);
            ddr(addr + 2) := v(23 downto 16);
            ddr(addr + 3) := v(31 downto 24);
        end procedure;

        -- Input: 5x5x3 = 75 bytes, values 1..75, CHW layout
        -- ch0: addr 0..24 (values 1..25)
        -- ch1: addr 25..49 (values 26..50)
        -- ch2: addr 50..74 (values 51..75)

        -- Weight: OHWI layout for 3x3.  Filter stride = c_in*kh*kw = 3*3*3 = 27
        -- oc=0: 27 bytes, all = 1
        -- oc=1..31: all zeros (already 0 in DDR init)

        -- Bias: oc=0 = 1000, oc=1..31 = 0
        constant BIAS_OC0 : integer := 1000;

        -- Expected output for oc=0 (9 pixels, row-major)
        type exp_t is array(0 to 8) of integer;
        constant expected_oc0 : exp_t := (-3, 1, -3, 2, 9, 2, -2, 3, -2);

        -- Expected for oc=1..31: requant(0) = -17
        constant expected_zero : integer := -17;

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;

    begin
        report "==============================================" severity note;
        report "TEST 2: conv 3x3, stride=2, pad=1" severity note;
        report "  c_in=3, c_out=32, h_in=5, w_in=5" severity note;
        report "  ksize=10 (3x3), stride=1 (s=2), pad=1" severity note;
        report "  ic_tile_size=3" severity note;
        report "==============================================" severity note;

        -----------------------------------------------------------------
        -- Load DDR
        -----------------------------------------------------------------
        -- Input: values 1..75 at ADDR_INPUT
        for i in 0 to 74 loop
            ddr_w8(ADDR_INPUT + i, i + 1);
        end loop;

        -- Weights at ADDR_WEIGHTS
        -- OHWI for 3x3: oc=0 has 27 bytes, all = 1
        -- Layout: w[0][kh][kw][ic] for kh=0..2, kw=0..2, ic=0..2
        for k in 0 to 26 loop
            ddr_w8(ADDR_WEIGHTS + k, 1);
        end loop;
        -- oc=1..31: already zero from init

        -- Bias at ADDR_BIAS (32 words x 4 bytes = 128 bytes)
        ddr_w32(ADDR_BIAS + 0, BIAS_OC0);   -- bias[0] = 1000
        -- bias[1..31] = 0 (already zero)

        report "DDR loaded" severity note;

        -----------------------------------------------------------------
        -- Reset
        -----------------------------------------------------------------
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -----------------------------------------------------------------
        -- Configure
        -----------------------------------------------------------------
        cfg_c_in         <= to_unsigned(3, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(5, 10);
        cfg_w_in         <= to_unsigned(5, 10);
        cfg_ksize        <= "10";          -- 3x3
        cfg_stride       <= '1';           -- stride=2
        cfg_pad          <= '1';           -- padding=1
        cfg_x_zp         <= to_signed(-128, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(3, 10);

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING conv_engine_v2 (stride=2 test)" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -----------------------------------------------------------------
        -- Run: serve DDR reads/writes
        -----------------------------------------------------------------
        timeout := 0;
        while done /= '1' and timeout < 500000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(12 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 500000 then
            report "TIMEOUT waiting for done" severity failure;
        end if;

        report "DONE at cycle " & integer'image(timeout) severity note;

        -- Flush any remaining writes
        for i in 0 to 19 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Verify oc=0 (9 pixels)
        -- Output layout: out[oc][oh*w_out+ow]
        -- hw_out = 3*3 = 9
        -- oc=0: ADDR_OUTPUT + 0*9 + pixel
        -----------------------------------------------------------------
        report "==============================================" severity note;
        report "CHECKING oc=0 (9 pixels)" severity note;

        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 0*9 + px)));
            if got /= expected_oc0(px) then
                errors := errors + 1;
                report "pixel " & integer'image(px) &
                       " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(expected_oc0(px)) severity error;
            else
                report "pixel " & integer'image(px) &
                       " OK: y=" & integer'image(got) severity note;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Verify oc=1 (should all be -17)
        -----------------------------------------------------------------
        report "CHECKING oc=1 (expect all -17)" severity note;
        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 1*9 + px)));
            if got /= expected_zero then
                errors := errors + 1;
                report "oc1 pixel " & integer'image(px) &
                       " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(expected_zero) severity error;
            else
                report "oc1 pixel " & integer'image(px) &
                       " OK: y=" & integer'image(got) severity note;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------
        report "==============================================" severity note;
        if errors = 0 then
            report "TEST stride=2 PASSED (all pixels correct)" severity note;
        else
            report "TEST stride=2 FAILED: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
