-------------------------------------------------------------------------------
-- test_1x1_csv_tb.vhd -- Conv 1x1 with CSV debug log
-------------------------------------------------------------------------------
-- Config: ksize="00" (1x1), stride='0', pad='0', c_in=4, c_out=1(+31 padding)
-- Input:  3x3x4 = 36 bytes {1,2,...,36} in CHW layout
-- Weight: OHWI layout, oc=0: {10,-5,3,-2}, oc=1..31: 0
-- Bias:   oc=0 = 500, oc=1..31 = 0
-- Quant:  x_zp=-128, w_zp=0, M0=656954014, n_shift=37, y_zp=-17
-- ic_tile_size=4 (no tiling)
--
-- Expected output for oc=0 (9 pixels, all = -11):
--   pixel(oh,ow): acc=1229..1277, y=-11
--
-- Generates sim_1x1_log.csv with per-cycle debug data.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.mac_array_pkg.all;

entity test_1x1_csv_tb is
end;

architecture bench of test_1x1_csv_tb is
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

    -- Debug ports
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

    -- CSV file
    file csv_file : text open write_mode is "sim_1x1_log.csv";

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    -------------------------------------------------------------------------
    -- UUT
    -------------------------------------------------------------------------
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

    -------------------------------------------------------------------------
    -- CSV logger process - writes one row per rising_edge after reset
    -------------------------------------------------------------------------
    p_csv : process
        variable line_buf : line;
        variable cycle_cnt : integer := 0;
    begin
        -- Write header
        write(line_buf, string'("cycle,state,oh,ow,kh,kw,ic,oc_tile,ic_tile,pad,mac_a,mac_b0,mac_acc0,mac_vi,mac_clr,mac_lb,rd_en,rd_addr,rd_data,wr_en,wr_addr,wr_data,w_base,act_addr"));
        writeline(csv_file, line_buf);

        -- Wait for reset release
        wait until rst_n = '1';

        loop
            wait until rising_edge(clk);
            exit when sim_done = '1';

            write(line_buf, integer'image(cycle_cnt));
            write(line_buf, string'(","));
            write(line_buf, integer'image(dbg_state));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_oh)));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_ow)));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_kh)));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_kw)));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_ic)));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_oc_tile_base)));
            write(line_buf, string'(","));
            write(line_buf, integer'image(to_integer(dbg_ic_tile_base)));
            write(line_buf, string'(","));
            -- pad
            if dbg_pad = '1' then
                write(line_buf, string'("1"));
            else
                write(line_buf, string'("0"));
            end if;
            write(line_buf, string'(","));
            -- mac_a (signed 9 bit)
            write(line_buf, integer'image(to_integer(dbg_mac_a)));
            write(line_buf, string'(","));
            -- mac_b(0) (signed 8 bit)
            write(line_buf, integer'image(to_integer(dbg_mac_b(0))));
            write(line_buf, string'(","));
            -- mac_acc(0) (signed 32 bit)
            write(line_buf, integer'image(to_integer(dbg_mac_acc(0))));
            write(line_buf, string'(","));
            -- mac_vi
            if dbg_mac_vi = '1' then
                write(line_buf, string'("1"));
            else
                write(line_buf, string'("0"));
            end if;
            write(line_buf, string'(","));
            -- mac_clr
            if dbg_mac_clr = '1' then
                write(line_buf, string'("1"));
            else
                write(line_buf, string'("0"));
            end if;
            write(line_buf, string'(","));
            -- mac_lb
            if dbg_mac_lb = '1' then
                write(line_buf, string'("1"));
            else
                write(line_buf, string'("0"));
            end if;
            write(line_buf, string'(","));
            -- rd_en
            if ddr_rd_en = '1' then
                write(line_buf, string'("1"));
            else
                write(line_buf, string'("0"));
            end if;
            write(line_buf, string'(","));
            -- rd_addr
            write(line_buf, integer'image(to_integer(ddr_rd_addr)));
            write(line_buf, string'(","));
            -- rd_data
            write(line_buf, integer'image(to_integer(signed(ddr_rd_data))));
            write(line_buf, string'(","));
            -- wr_en
            if ddr_wr_en = '1' then
                write(line_buf, string'("1"));
            else
                write(line_buf, string'("0"));
            end if;
            write(line_buf, string'(","));
            -- wr_addr
            write(line_buf, integer'image(to_integer(ddr_wr_addr)));
            write(line_buf, string'(","));
            -- wr_data (signed)
            write(line_buf, integer'image(to_integer(signed(ddr_wr_data))));
            write(line_buf, string'(","));
            -- w_base
            write(line_buf, integer'image(to_integer(dbg_w_base)));
            write(line_buf, string'(","));
            -- act_addr
            write(line_buf, integer'image(to_integer(dbg_act_addr)));

            writeline(csv_file, line_buf);
            cycle_cnt := cycle_cnt + 1;
        end loop;

        wait;
    end process;

    -------------------------------------------------------------------------
    -- Main stimulus + DDR model + checker
    -------------------------------------------------------------------------
    p_main : process
        type ddr_t is array(0 to 16383) of std_logic_vector(7 downto 0);
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

        -- Input: 3x3x4 = 36 bytes {1..36} in CHW layout
        -- ic=0: 1..9,  ic=1: 10..18,  ic=2: 19..27,  ic=3: 28..36
        -- Weight: OHWI, oc=0: {10,-5,3,-2}, oc=1..31: 0
        -- Bias: oc=0 = 500, rest = 0

        -- Expected outputs for oc=0 (all 9 pixels = -11)
        type exp_t is array(0 to 8) of integer;
        constant expected_oc0 : exp_t := (-11, -11, -11, -11, -11, -11, -11, -11, -11);

        -- Expected for oc=1..31 (bias=0, w=0): requant(0) = y_zp = -17
        constant expected_zero : integer := -17;

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;
        variable mac_vi_cnt : integer := 0;

    begin
        report "==============================================" severity note;
        report "TEST 1x1 CSV: conv 1x1, stride=1, no-pad" severity note;
        report "  c_in=4, c_out=32, h_in=3, w_in=3" severity note;
        report "  ksize=00 (1x1), ic_tile_size=4" severity note;
        report "==============================================" severity note;

        -----------------------------------------------------------------
        -- Load DDR: input 1..36
        -----------------------------------------------------------------
        for i in 0 to 35 loop
            -- Store unsigned byte values 1..36
            -- Values 1..36 fit in unsigned byte [0,255] and also in signed
            -- byte [-128,127] since 36 < 128.
            ddr(ADDR_INPUT + i) := std_logic_vector(to_unsigned(i + 1, 8));
        end loop;

        -- Weights at ADDR_WEIGHTS: OHWI for 1x1
        -- filter stride = c_in * 1 * 1 = 4
        -- oc=0: bytes 0..3 = {10, -5, 3, -2}
        ddr_w8(ADDR_WEIGHTS + 0,  10);
        ddr_w8(ADDR_WEIGHTS + 1,  -5);
        ddr_w8(ADDR_WEIGHTS + 2,   3);
        ddr_w8(ADDR_WEIGHTS + 3,  -2);
        -- oc=1..31: already zero

        -- Bias at ADDR_BIAS (32 words x 4 bytes = 128 bytes)
        ddr_w32(ADDR_BIAS + 0, 500);   -- bias[0] = 500
        -- bias[1..31] = 0 (already zero)

        report "DDR loaded (input={1..36}, weights={10,-5,3,-2}, bias=500)" severity note;

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
        -- Configure (c_out=32 because engine always does N_MAC=32)
        -----------------------------------------------------------------
        cfg_c_in         <= to_unsigned(4, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "00";          -- 1x1
        cfg_stride       <= '0';           -- stride=1
        cfg_pad          <= '0';           -- no padding
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

        report "STARTING conv_engine_v2 (1x1 CSV test)" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -----------------------------------------------------------------
        -- Run: serve DDR reads/writes + count mac_vi pulses
        -----------------------------------------------------------------
        timeout := 0;
        while done /= '1' and timeout < 500000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(13 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(13 downto 0))) := ddr_wr_data;
            end if;
            if dbg_mac_vi = '1' then
                mac_vi_cnt := mac_vi_cnt + 1;
            end if;
        end loop;

        if timeout >= 500000 then
            report "TIMEOUT waiting for done" severity failure;
        end if;

        report "DONE at cycle " & integer'image(timeout) severity note;
        report "Total mac_vi pulses = " & integer'image(mac_vi_cnt)
             & " (expected = 9 pixels x 4 taps = 36)" severity note;

        -- Flush remaining writes
        for i in 0 to 19 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(13 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Verify oc=0 (9 pixels)
        -----------------------------------------------------------------
        report "==============================================" severity note;
        report "CHECKING oc=0 (9 pixels, expect all = -11)" severity note;

        -- Output layout: out[oc][oh*w_out+ow]
        -- addr = ADDR_OUTPUT + oc * hw_out + pixel
        -- hw_out = 3*3 = 9
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
        -- Verify oc=1 (should be -17)
        -----------------------------------------------------------------
        report "CHECKING oc=1 (expect all = -17)" severity note;
        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 1*9 + px)));
            if got /= expected_zero then
                errors := errors + 1;
                report "oc1 pixel " & integer'image(px) &
                       " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(expected_zero) severity error;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- mac_vi pulse count check
        -----------------------------------------------------------------
        -- 9 pixels x 4 ic taps per pixel = 36 expected mac_vi pulses
        if mac_vi_cnt /= 36 then
            errors := errors + 1;
            report "mac_vi count FAIL: got=" & integer'image(mac_vi_cnt) &
                   " exp=36" severity error;
        else
            report "mac_vi count OK: 36" severity note;
        end if;

        -----------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------
        report "==============================================" severity note;
        if errors = 0 then
            report "TEST 1x1 CSV PASSED (all pixels correct)" severity note;
        else
            report "TEST 1x1 CSV FAILED: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
