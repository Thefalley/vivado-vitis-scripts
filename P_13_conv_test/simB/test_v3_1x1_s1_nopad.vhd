-------------------------------------------------------------------------------
-- test_v3_1x1_s1_nopad.vhd -- Test 3: 1x1 s=1 pad=[0,0,0,0] (regression)
-------------------------------------------------------------------------------
-- Verifies conv_engine_v3 with 1x1 convolution, no padding
-- Config: ksize="00" (1x1), stride='0', pad=[0,0,0,0], c_in=4, c_out=32
-- Input:  3x3x4 = 36 bytes
--   ch0-2: same as layer_005 (27 bytes)
--   ch3:   10, 20, 30, 40, 50, 60, 70, 80, 90
-- Weight: oc=0: {10, 20, 30, 40}; oc=1..31 = 0
-- Bias:   oc=0: 500; oc=1..31 = 0
-- Quant:  x_zp=-128, w_zp=0, M0=656954014, n_shift=37, y_zp=-17
--
-- Expected oc=0 output (9 pixels, row-major, Python-computed):
--   66, 33, 63, 72, 41, 67, 69, 50, 70
-- Expected oc=1..31: all -17
--
-- Generates CSV: test3_ddr_writes.csv
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity test_v3_1x1_s1_nopad is
end;

architecture bench of test_v3_1x1_s1_nopad is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal cfg_c_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out     : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize     : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride    : std_logic := '0';
    signal cfg_pad_top   : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_bottom: unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_left  : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_right : unsigned(1 downto 0) := (others => '0');
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

    -- Debug
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

    constant ADDR_INPUT   : natural := 16#0000#;
    constant ADDR_WEIGHTS : natural := 16#0400#;
    constant ADDR_BIAS    : natural := 16#0800#;
    constant ADDR_OUTPUT  : natural := 16#0C00#;

    signal sim_done : std_logic := '0';

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    uut : entity work.conv_engine_v3
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride,
            cfg_pad_top => cfg_pad_top, cfg_pad_bottom => cfg_pad_bottom,
            cfg_pad_left => cfg_pad_left, cfg_pad_right => cfg_pad_right,
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

        -- Input: 3x3x4 = 36 bytes
        -- ch0-2: same as layer_005, ch3: 10,20,...,90
        type img_t is array(0 to 35) of integer;
        constant img : img_t := (
            -- ch0
            56,-106,21, 50,-102,17, 6,-97,-6,
            -- ch1
            62,-64,39, 59,-57,34, 29,-42,23,
            -- ch2
            65,-40,44, 70,-31,33, 39,-24,31,
            -- ch3
            10, 20, 30, 40, 50, 60, 70, 80, 90
        );

        -- Weight oc=0: {10, 20, 30, 40} (OHWI for 1x1x4)
        type wt_1x1_t is array(0 to 3) of integer;
        constant wt_oc0 : wt_1x1_t := (10, 20, 30, 40);

        constant BIAS_OC0 : integer := 500;

        -- Expected oc=0 output (9 pixels, Python-computed)
        type exp_t is array(0 to 8) of integer;
        constant expected_oc0 : exp_t := (66, 33, 63, 72, 41, 67, 69, 50, 70);
        constant expected_zero : integer := -17;

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;

    begin
        report "==============================================" severity note;
        report "TEST 3: 1x1 s=1 pad=[0,0,0,0] (no padding)" severity note;
        report "  c_in=4, c_out=32, h_in=3, w_in=3" severity note;
        report "==============================================" severity note;

        -- Load DDR: input
        for i in 0 to 35 loop
            ddr_w8(ADDR_INPUT + i, img(i));
        end loop;

        -- Weights: oc=0 = {10, 20, 30, 40}
        for k in 0 to 3 loop
            ddr_w8(ADDR_WEIGHTS + k, wt_oc0(k));
        end loop;

        -- Bias
        ddr_w32(ADDR_BIAS + 0, BIAS_OC0);

        report "DDR loaded" severity note;

        -- Reset
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- Configure
        cfg_c_in         <= to_unsigned(4, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "00";           -- 1x1
        cfg_stride       <= '0';            -- stride=1
        cfg_pad_top      <= "00";           -- no padding
        cfg_pad_bottom   <= "00";
        cfg_pad_left     <= "00";
        cfg_pad_right    <= "00";
        cfg_x_zp         <= to_signed(-128, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(4, 10);

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING conv_engine_v3 (test 3 - 1x1)" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Run: serve DDR
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

        -- Flush remaining writes
        for i in 0 to 19 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -- Verify oc=0 (9 pixels)
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

        -- Verify oc=1 (expect all -17)
        report "CHECKING oc=1 (expect all -17)" severity note;
        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 1*9 + px)));
            if got /= expected_zero then
                errors := errors + 1;
                report "oc1 pixel " & integer'image(px) &
                       " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(expected_zero) severity error;
            end if;
        end loop;

        -- Summary
        report "==============================================" severity note;
        if errors = 0 then
            report "TEST 3 (1x1 s=1 no-pad): PASS" severity note;
        else
            report "TEST 3 (1x1 s=1 no-pad): FAIL (" & integer'image(errors) & " errors)" severity error;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

    -- CSV logger for DDR writes
    p_log : process(clk)
        file f_wr  : text open write_mode is "test3_ddr_writes.csv";
        variable l : line;
        variable cycle_cnt : integer := 0;
        variable header_done : boolean := false;
    begin
        if rising_edge(clk) then
            if not header_done then
                write(l, string'("cycle,addr,data"));
                writeline(f_wr, l);
                header_done := true;
            end if;
            cycle_cnt := cycle_cnt + 1;
            if ddr_wr_en = '1' then
                write(l, cycle_cnt); write(l, string'(","));
                write(l, to_integer(ddr_wr_addr(12 downto 0))); write(l, string'(","));
                write(l, to_integer(signed(ddr_wr_data)));
                writeline(f_wr, l);
            end if;
            if sim_done = '1' then
                file_close(f_wr);
            end if;
        end if;
    end process;

end;
