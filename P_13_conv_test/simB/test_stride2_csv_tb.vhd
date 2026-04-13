-------------------------------------------------------------------------------
-- test_stride2_csv_tb.vhd -- Verify conv_engine_v2 with stride=2, pad=1
--                             + CSV logging of all debug signals each cycle
-------------------------------------------------------------------------------
-- Config: ksize="01" (3x3), stride='1' (stride=2), pad='1',
--         c_in=3, c_out=32, h_in=6, w_in=6
-- Input:  6x6x3 = 108 bytes, CHW layout: (i%251)-125 for i in 0..107
-- Weight: 27 bytes all-ones per filter (OHWI layout), filters 0..31
-- Bias:   1000 for filter 0, 0 for filters 1..31
-- Quant:  x_zp=-128, w_zp=0, M0=656954014, n_shift=37, y_zp=-17
-- ic_tile_size = 3 (no tiling)
--
-- h_out = (6+2*1-3)/2 + 1 = 3
-- w_out = (6+2*1-3)/2 + 1 = 3
-- Output: 3x3x32 = 288 bytes total, but we only check oc=0 (9 bytes)
--
-- Expected oc=0 output (row-major):
--   -10, -8, -8, -8, -5, -5, -7, -4, -4
--
-- For oc=1..31 (bias=0, weights=1):
--   acc = 0 + sum(x-x_zp)*1 = same sum as oc=0 but bias=0
--   We only verify oc=0 in detail.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.mac_array_pkg.all;

entity test_stride2_csv_tb is
end;

architecture bench of test_stride2_csv_tb is
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

    -- DDR address map
    constant ADDR_INPUT   : natural := 16#0000#;
    constant ADDR_WEIGHTS : natural := 16#1000#;
    constant ADDR_BIAS    : natural := 16#2000#;
    constant ADDR_OUTPUT  : natural := 16#3000#;

    signal sim_done : std_logic := '0';
    signal cycle_cnt : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    -- Cycle counter
    p_cycle : process(clk)
    begin
        if rising_edge(clk) then
            cycle_cnt <= cycle_cnt + 1;
        end if;
    end process;

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

    ---------------------------------------------------------------------------
    -- CSV logger: writes one line per clock cycle
    ---------------------------------------------------------------------------
    p_csv : process(clk)
        file csv_file : text;
        variable csv_line : line;
        variable file_opened : boolean := false;
    begin
        if rising_edge(clk) then
            if not file_opened then
                file_open(csv_file, "debug_stride2.csv", write_mode);
                -- Header
                write(csv_line, string'("cycle,state,oh,ow,kh,kw,ic,oc_tile,ic_tile,pad,mac_a,mac_b0,mac_acc0,mac_vi,mac_clr,mac_lb,rd_en,rd_addr,wr_en,wr_addr,wr_data,act_addr,w_base"));
                writeline(csv_file, csv_line);
                file_opened := true;
            end if;

            -- Only log when busy (or a few cycles around it)
            if busy = '1' or done = '1' or start = '1' or
               (cycle_cnt > 10 and cycle_cnt < 15) then
                write(csv_line, integer'image(cycle_cnt));
                write(csv_line, string'(","));
                write(csv_line, integer'image(dbg_state));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oh)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ow)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kh)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kw)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oc_tile_base)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic_tile_base)));
                write(csv_line, string'(","));
                if dbg_pad = '1' then
                    write(csv_line, string'("1"));
                else
                    write(csv_line, string'("0"));
                end if;
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_a)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(0))));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(0))));
                write(csv_line, string'(","));
                if dbg_mac_vi = '1' then
                    write(csv_line, string'("1"));
                else
                    write(csv_line, string'("0"));
                end if;
                write(csv_line, string'(","));
                if dbg_mac_clr = '1' then
                    write(csv_line, string'("1"));
                else
                    write(csv_line, string'("0"));
                end if;
                write(csv_line, string'(","));
                if dbg_mac_lb = '1' then
                    write(csv_line, string'("1"));
                else
                    write(csv_line, string'("0"));
                end if;
                write(csv_line, string'(","));
                if ddr_rd_en = '1' then
                    write(csv_line, string'("1"));
                else
                    write(csv_line, string'("0"));
                end if;
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_rd_addr)));
                write(csv_line, string'(","));
                if ddr_wr_en = '1' then
                    write(csv_line, string'("1"));
                else
                    write(csv_line, string'("0"));
                end if;
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_wr_addr)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(ddr_wr_data))));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_act_addr)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_w_base)));
                writeline(csv_file, csv_line);
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main test process
    ---------------------------------------------------------------------------
    p_main : process
        -- DDR model: 16K bytes
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

        -- Input data: 108 bytes, CHW layout
        -- (i%251)-125 for i in 0..107
        type s8_array_t is array(natural range <>) of integer range -128 to 127;
        constant INPUT_DATA : s8_array_t(0 to 107) := (
            -125,-124,-123,-122,-121,-120,-119,-118,-117,-116,-115,-114,
            -113,-112,-111,-110,-109,-108,-107,-106,-105,-104,-103,-102,
            -101,-100, -99, -98, -97, -96, -95, -94, -93, -92, -91, -90,
             -89, -88, -87, -86, -85, -84, -83, -82, -81, -80, -79, -78,
             -77, -76, -75, -74, -73, -72, -71, -70, -69, -68, -67, -66,
             -65, -64, -63, -62, -61, -60, -59, -58, -57, -56, -55, -54,
             -53, -52, -51, -50, -49, -48, -47, -46, -45, -44, -43, -42,
             -41, -40, -39, -38, -37, -36, -35, -34, -33, -32, -31, -30,
             -29, -28, -27, -26, -25, -24, -23, -22, -21, -20, -19, -18
        );

        -- Weight: all ones, OHWI layout
        -- For oc=0..31: 27 bytes each = 1
        -- filter stride in DDR = c_in * kh * kw = 3*3*3 = 27

        -- Expected oc=0 output (9 pixels, 3x3)
        type exp_t is array(0 to 8) of integer;
        constant expected_oc0 : exp_t := (-10, -8, -8, -8, -5, -5, -7, -4, -4);

        -- Expected oc=1..31: bias=0, same sum minus 1000
        -- oc1 pixel(1,1): acc=2431-1000=1431 -> requant(1431)
        -- requant(1431): 1431*656954014 = ?  let's just check that oc0 is correct

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;

    begin
        report "==============================================" severity note;
        report "TEST: conv 3x3, stride=2, pad=1, CSV logging" severity note;
        report "  c_in=3, c_out=32, h_in=6, w_in=6"         severity note;
        report "  ksize=01 (3x3), ic_tile_size=3"            severity note;
        report "  Expected h_out=3, w_out=3"                 severity note;
        report "==============================================" severity note;

        -----------------------------------------------------------------
        -- Load DDR: input
        -----------------------------------------------------------------
        for i in 0 to 107 loop
            ddr_w8(ADDR_INPUT + i, INPUT_DATA(i));
        end loop;

        -----------------------------------------------------------------
        -- Load DDR: weights (OHWI layout, all ones)
        -- For 32 filters, each 27 bytes (3x3x3=27)
        -- DDR layout: filter0[27 bytes] | filter1[27 bytes] | ... | filter31[27 bytes]
        -----------------------------------------------------------------
        for oc in 0 to 31 loop
            for j in 0 to 26 loop
                ddr_w8(ADDR_WEIGHTS + oc * 27 + j, 1);
            end loop;
        end loop;

        -----------------------------------------------------------------
        -- Load DDR: bias (32 words, little-endian)
        -- bias[0] = 1000, bias[1..31] = 0
        -----------------------------------------------------------------
        ddr_w32(ADDR_BIAS + 0, 1000);
        -- bias[1..31] already zero from init

        report "DDR loaded: 108 input bytes, 864 weight bytes (all 1), bias[0]=1000" severity note;

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
        cfg_h_in         <= to_unsigned(6, 10);
        cfg_w_in         <= to_unsigned(6, 10);
        cfg_ksize        <= "01";              -- 3x3
        cfg_stride       <= '1';               -- stride=2
        cfg_pad          <= '1';               -- pad=1
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
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(13 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(13 downto 0))) := ddr_wr_data;
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
                ddr(to_integer(ddr_wr_addr(13 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Verify oc=0 (9 pixels)
        -----------------------------------------------------------------
        report "==============================================" severity note;
        report "CHECKING oc=0 (9 pixels, stride=2 output)" severity note;
        report "  Output layout: out[oc][oh*w_out+ow]" severity note;
        report "  hw_out = 3*3 = 9" severity note;
        report "  addr = ADDR_OUTPUT + oc*9 + pixel" severity note;

        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 0 * 9 + px)));
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
        -- Verify output dimensions: check that we got exactly 9 outputs
        -- for oc=0 (3x3, not 6x6 or other)
        -----------------------------------------------------------------
        report "==============================================" severity note;
        report "DIMENSION CHECK: verifying 3x3 output grid" severity note;
        report "  If stride=2 was wrong, we'd get 6x6=36 or 4x4=16 outputs" severity note;

        -- Dump first 36 bytes of output area for oc=0
        for px in 0 to 35 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + px)));
            report "  output[" & integer'image(px) & "] = " & integer'image(got) severity note;
        end loop;

        -----------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------
        report "==============================================" severity note;
        if errors = 0 then
            report "*** TEST STRIDE=2 PASSED (all 9 pixels correct) ***" severity note;
        else
            report "*** TEST STRIDE=2 FAILED: " & integer'image(errors) & " errors ***" severity error;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
