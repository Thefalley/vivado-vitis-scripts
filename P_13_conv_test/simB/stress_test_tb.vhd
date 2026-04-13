-------------------------------------------------------------------------------
-- stress_test_tb.vhd -- Maximum-effort stress tests for conv_engine_v3
-------------------------------------------------------------------------------
-- 7 destructive tests: overflow, negative extremes, identity, minimal,
-- extreme tiling (ic_tile=1), large dimensions (16x16), asymmetric padding.
--
-- Each test uses a DDR model, configures conv_engine_v3, runs to completion,
-- and checks outputs bit-exact against Python-precomputed expected values.
--
-- The goal is to BREAK the engine, not confirm it works.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.mac_array_pkg.all;

entity stress_test_tb is
end;

architecture bench of stress_test_tb is
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

    signal sim_done : boolean := false;

    -- DDR memory: 128 KB (enough for all tests)
    constant DDR_SIZE : natural := 131072;
    type ddr_t is array(0 to DDR_SIZE-1) of std_logic_vector(7 downto 0);
    shared variable ddr : ddr_t := (others => (others => '0'));

    -- Result log file
    file results_file : text;

    -- Global error counters
    signal total_errors : integer := 0;
    signal test_errors  : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done;

    ---------------------------------------------------------------------------
    -- UUT: conv_engine_v3
    ---------------------------------------------------------------------------
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

    ---------------------------------------------------------------------------
    -- DDR model: 1-cycle latency reads, immediate writes
    ---------------------------------------------------------------------------
    p_ddr : process(clk)
    begin
        if rising_edge(clk) then
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr)) := ddr_wr_data;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- MAIN TEST PROCESS
    ---------------------------------------------------------------------------
    p_main : process

        -- Helpers
        procedure ddr_w8(addr : natural; val : integer) is
        begin
            ddr(addr) := std_logic_vector(to_signed(val, 8));
        end;

        procedure ddr_w32(addr : natural; val : integer) is
            variable v : std_logic_vector(31 downto 0);
        begin
            v := std_logic_vector(to_signed(val, 32));
            ddr(addr + 0) := v( 7 downto  0);
            ddr(addr + 1) := v(15 downto  8);
            ddr(addr + 2) := v(23 downto 16);
            ddr(addr + 3) := v(31 downto 24);
        end;

        procedure ddr_clear is
        begin
            for i in 0 to DDR_SIZE-1 loop
                ddr(i) := (others => '0');
            end loop;
        end;

        function ddr_r8(addr : natural) return integer is
        begin
            return to_integer(signed(ddr(addr)));
        end;

        procedure do_reset is
        begin
            rst_n <= '0';
            for i in 0 to 9 loop
                wait until rising_edge(clk);
            end loop;
            rst_n <= '1';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end;

        procedure run_engine(timeout_limit : integer := 2000000) is
            variable timeout : integer := 0;
        begin
            wait until rising_edge(clk);
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';
            while done /= '1' and timeout < timeout_limit loop
                wait until rising_edge(clk);
                timeout := timeout + 1;
            end loop;
            if timeout >= timeout_limit then
                report "TIMEOUT at cycle " & integer'image(timeout) severity error;
            end if;
            -- Flush remaining writes
            for i in 0 to 29 loop
                wait until rising_edge(clk);
            end loop;
        end;

        variable errors : integer;
        variable got    : integer;
        variable exp    : integer;

        -- Address constants (per-test, we shift base addresses)
        variable ADDR_IN  : natural;
        variable ADDR_W   : natural;
        variable ADDR_B   : natural;
        variable ADDR_OUT : natural;

        variable L : line;

        -- Expected-value arrays (must be in declarative region)
        type exp5_t is array(0 to 4) of integer;
        type exp4_t is array(0 to 3) of integer;

    begin

        file_open(results_file, "STRESS_TEST_RESULTS.txt", write_mode);

        write(L, string'("STRESS TEST RESULTS -- conv_engine_v3"));
        writeline(results_file, L);
        write(L, string'("====================================="));
        writeline(results_file, L);

        -----------------------------------------------------------------------
        -- TEST 1: OVERFLOW ACCUMULATOR
        -- c_in=32, c_out=32, h=3, w=3, k=3x3, pad=[1,1,1,1], stride=1
        -- Input=127, Weight=127, x_zp=-128, Bias=MAX_INT32
        -- M0=2147483647, n_shift=37, y_zp=0
        -----------------------------------------------------------------------
        report "============ TEST 1: Overflow accumulator ============" severity note;
        ddr_clear;
        errors := 0;

        ADDR_IN  := 16#0000#;
        ADDR_W   := 16#2000#;
        ADDR_B   := 16#6000#;
        ADDR_OUT := 16#7000#;

        -- Input: h_in=3, w_in=3, c_in=32 -> 288 bytes, all=127
        -- Layout: CHW (c * h_in * w_in + h * w_in + w)
        for c in 0 to 31 loop
            for h in 0 to 2 loop
                for w in 0 to 2 loop
                    ddr_w8(ADDR_IN + c * 9 + h * 3 + w, 127);
                end loop;
            end loop;
        end loop;

        -- Weights: OHWI layout, c_out=32, kh=3, kw=3, c_in=32
        -- All = 127
        -- weight[oc][kh][kw][ic] at oc*(c_in*kh*kw) + kh*(kw*c_in) + kw*c_in + ic
        for oc in 0 to 31 loop
            for kkh in 0 to 2 loop
                for kkw in 0 to 2 loop
                    for ic in 0 to 31 loop
                        ddr_w8(ADDR_W + oc * 288 + kkh * 96 + kkw * 32 + ic, 127);
                    end loop;
                end loop;
            end loop;
        end loop;

        -- Bias: 32 words, all = 2147483647
        for i in 0 to 31 loop
            ddr_w32(ADDR_B + i * 4, 2147483647);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(32, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "01";          -- 3x3
        cfg_stride       <= '0';
        cfg_pad_top      <= "01";
        cfg_pad_bottom   <= "01";
        cfg_pad_left     <= "01";
        cfg_pad_right    <= "01";
        cfg_x_zp         <= to_signed(-128, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(2147483647, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(32, 10);

        run_engine;

        -- Expected: ALL pixels of ALL channels = -128 (overflow wraps acc negative)
        -- Output layout: out[oc][oh*w_out+ow]
        -- hw_out = 3*3 = 9
        for oc in 0 to 31 loop
            for px in 0 to 8 loop
                got := ddr_r8(ADDR_OUT + oc * 9 + px);
                exp := -128;
                if got /= exp then
                    errors := errors + 1;
                    if errors <= 10 then
                        report "T1 FAIL oc=" & integer'image(oc) & " px=" & integer'image(px)
                            & " got=" & integer'image(got) & " exp=" & integer'image(exp)
                            severity error;
                    end if;
                end if;
            end loop;
        end loop;

        write(L, string'("Test 1 (overflow acc): "));
        if errors = 0 then
            write(L, string'("PASS -- all 288 outputs = -128 (32-bit wraps to negative, saturates)"));
            report "TEST 1: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 1: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- TEST 2: NEGATIVE EXTREMES
        -- c_in=32, c_out=32, h=3, w=3, k=3x3, pad=[1,1,1,1]
        -- Input=-128, Weight=-128, x_zp=0
        -- Bias=-2147483648 (MIN_INT32)
        -- M0=656954014, n_shift=37, y_zp=-17
        -----------------------------------------------------------------------
        report "============ TEST 2: Negative extremes ============" severity note;
        ddr_clear;
        errors := 0;

        -- Input: all = -128
        for i in 0 to 287 loop
            ddr_w8(ADDR_IN + i, -128);
        end loop;

        -- Weights: all = -128
        for oc in 0 to 31 loop
            for j in 0 to 287 loop
                ddr_w8(ADDR_W + oc * 288 + j, -128);
            end loop;
        end loop;

        -- Bias: all = -2147483648
        for i in 0 to 31 loop
            ddr_w32(ADDR_B + i * 4, -2147483648);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(32, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "01";
        cfg_stride       <= '0';
        cfg_pad_top      <= "01";
        cfg_pad_bottom   <= "01";
        cfg_pad_left     <= "01";
        cfg_pad_right    <= "01";
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(32, 10);

        run_engine;

        -- Expected: all outputs = -128 (large negative acc saturates)
        for oc in 0 to 31 loop
            for px in 0 to 8 loop
                got := ddr_r8(ADDR_OUT + oc * 9 + px);
                exp := -128;
                if got /= exp then
                    errors := errors + 1;
                    if errors <= 10 then
                        report "T2 FAIL oc=" & integer'image(oc) & " px=" & integer'image(px)
                            & " got=" & integer'image(got) & " exp=" & integer'image(exp)
                            severity error;
                    end if;
                end if;
            end loop;
        end loop;

        write(L, string'("Test 2 (negative extreme): "));
        if errors = 0 then
            write(L, string'("PASS -- all 288 outputs = -128"));
            report "TEST 2: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 2: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- TEST 3: x_zp=0 IDENTITY (pass-through test)
        -- c_in=1, c_out=32, h=1, w=5, k=1x1, pad=[0,0,0,0]
        -- Input = [0, 1, -1, 127, -128]
        -- Weight: oc0=1, oc1=-1, oc2..31=0
        -- Bias: all 0
        -- x_zp=0, M0=1073741824 (2^30), n_shift=30, y_zp=0
        -----------------------------------------------------------------------
        report "============ TEST 3: x_zp=0 identity ============" severity note;
        ddr_clear;
        errors := 0;

        ADDR_IN  := 16#0000#;
        ADDR_W   := 16#0100#;
        ADDR_B   := 16#0200#;
        ADDR_OUT := 16#0300#;

        -- Input: 1 channel, h=1, w=5 => 5 bytes
        ddr_w8(ADDR_IN + 0, 0);
        ddr_w8(ADDR_IN + 1, 1);
        ddr_w8(ADDR_IN + 2, -1);
        ddr_w8(ADDR_IN + 3, 127);
        ddr_w8(ADDR_IN + 4, -128);

        -- Weights OHWI: 1x1 kernel, c_in=1 => 1 byte per filter
        -- oc=0: weight=1, oc=1: weight=-1, rest=0
        ddr_w8(ADDR_W + 0, 1);     -- oc=0
        ddr_w8(ADDR_W + 1, -1);    -- oc=1
        -- oc=2..31: already 0

        -- Bias: all 0
        for i in 0 to 31 loop
            ddr_w32(ADDR_B + i * 4, 0);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(1, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(1, 10);
        cfg_w_in         <= to_unsigned(5, 10);
        cfg_ksize        <= "00";          -- 1x1
        cfg_stride       <= '0';
        cfg_pad_top      <= "00";
        cfg_pad_bottom   <= "00";
        cfg_pad_left     <= "00";
        cfg_pad_right    <= "00";
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1073741824, 32);
        cfg_n_shift      <= to_unsigned(30, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(1, 10);

        run_engine;

        -- Expected values:
        -- Output layout: out[oc][pixel], hw_out = 1*5 = 5
        -- oc=0 (w=1):  [0, 1, -1, 127, -128]
        -- oc=1 (w=-1): [0, -1, 1, -127, 127]   (note: -(-128) -> 128 -> clamp 127)
        -- oc=2..31 (w=0): [0, 0, 0, 0, 0]

        -- Expected for oc=0: [0, 1, -1, 127, -128]
        -- Expected for oc=1: [0, -1, 1, -127, 127]
        for px in 0 to 4 loop
            got := ddr_r8(ADDR_OUT + 0 * 5 + px);
            case px is
                when 0 => exp := 0;
                when 1 => exp := 1;
                when 2 => exp := -1;
                when 3 => exp := 127;
                when others => exp := -128;
            end case;
            if got /= exp then
                errors := errors + 1;
                report "T3 oc0 px=" & integer'image(px)
                    & " FAIL got=" & integer'image(got)
                    & " exp=" & integer'image(exp) severity error;
            end if;
        end loop;

        for px in 0 to 4 loop
            got := ddr_r8(ADDR_OUT + 1 * 5 + px);
            case px is
                when 0 => exp := 0;
                when 1 => exp := -1;
                when 2 => exp := 1;
                when 3 => exp := -127;
                when others => exp := 127;
            end case;
            if got /= exp then
                errors := errors + 1;
                report "T3 oc1 px=" & integer'image(px)
                    & " FAIL got=" & integer'image(got)
                    & " exp=" & integer'image(exp) severity error;
            end if;
        end loop;

        -- oc=2..31: all 0
        for oc in 2 to 31 loop
            for px in 0 to 4 loop
                got := ddr_r8(ADDR_OUT + oc * 5 + px);
                if got /= 0 then
                    errors := errors + 1;
                    if errors <= 20 then
                        report "T3 oc=" & integer'image(oc) & " px=" & integer'image(px)
                            & " FAIL got=" & integer'image(got) & " exp=0" severity error;
                    end if;
                end if;
            end loop;
        end loop;

        write(L, string'("Test 3 (x_zp=0): "));
        if errors = 0 then
            write(L, string'("PASS -- identity pass-through, clamp at extremes correct"));
            report "TEST 3: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 3: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- TEST 4: MINIMAL 1x1x1 (single pixel, single channel)
        -- c_in=1, c_out=32, h=1, w=1, k=1x1, pad=[0,0,0,0]
        -- Input=42, Weight(oc0)=10, Bias(oc0)=100
        -- x_zp=-128, M0=656954014, n_shift=37, y_zp=-17
        -- acc = 100 + (42+128)*10 = 1800
        -- rq = -8
        -----------------------------------------------------------------------
        report "============ TEST 4: Minimal 1x1x1 ============" severity note;
        ddr_clear;
        errors := 0;

        ADDR_IN  := 16#0000#;
        ADDR_W   := 16#0100#;
        ADDR_B   := 16#0200#;
        ADDR_OUT := 16#0300#;

        -- Input: 1 byte
        ddr_w8(ADDR_IN, 42);

        -- Weights: oc=0 has weight=10, oc=1..31=0
        ddr_w8(ADDR_W + 0, 10);   -- oc=0, k=0, ic=0

        -- Bias: oc=0 = 100, rest = 0
        ddr_w32(ADDR_B + 0, 100);
        for i in 1 to 31 loop
            ddr_w32(ADDR_B + i * 4, 0);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(1, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(1, 10);
        cfg_w_in         <= to_unsigned(1, 10);
        cfg_ksize        <= "00";
        cfg_stride       <= '0';
        cfg_pad_top      <= "00";
        cfg_pad_bottom   <= "00";
        cfg_pad_left     <= "00";
        cfg_pad_right    <= "00";
        cfg_x_zp         <= to_signed(-128, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(1, 10);

        run_engine;

        -- Expected: oc=0 -> -8, oc=1..31 -> -17
        got := ddr_r8(ADDR_OUT + 0);
        if got /= -8 then
            errors := errors + 1;
            report "T4 oc0 FAIL got=" & integer'image(got) & " exp=-8" severity error;
        end if;

        for oc in 1 to 31 loop
            got := ddr_r8(ADDR_OUT + oc * 1);
            if got /= -17 then
                errors := errors + 1;
                report "T4 oc=" & integer'image(oc)
                    & " FAIL got=" & integer'image(got) & " exp=-17" severity error;
            end if;
        end loop;

        write(L, string'("Test 4 (minimal 1x1x1): "));
        if errors = 0 then
            write(L, string'("PASS -- single pixel exact: oc0=-8, rest=-17"));
            report "TEST 4: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 4: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- TEST 5: EXTREME TILING (ic_tile=1, c_in=32)
        -- c_in=32, c_out=32, h=1, w=2, k=1x1, pad=[0,0,0,0]
        -- ic_tile_size=1 -> 32 tile passes per pixel!
        -- Input: pixel0 all=5, pixel1 all=10
        -- Weight oc0: all=3, rest=0
        -- Bias oc0: 100, rest=0
        -- x_zp=-10
        -- M0=656954014, n_shift=37, y_zp=-17
        -- pixel0: mac_a = 5-(-10)=15, acc = 100+32*15*3 = 1540, rq=-10
        -- pixel1: mac_a = 10-(-10)=20, acc = 100+32*20*3 = 2020, rq=-7
        -----------------------------------------------------------------------
        report "============ TEST 5: Extreme tiling ic_tile=1 ============" severity note;
        ddr_clear;
        errors := 0;

        -- Weights: 32 oc * 32 ic * 1 kk = 1024 bytes
        -- Must space: input=64B, weights=1024B, bias=128B, output=64B
        ADDR_IN  := 16#0000#;  -- 0x000..0x03F (64 bytes)
        ADDR_W   := 16#0100#;  -- 0x100..0x4FF (1024 bytes)
        ADDR_B   := 16#0600#;  -- 0x600..0x67F (128 bytes)
        ADDR_OUT := 16#0700#;  -- 0x700..0x73F (64 bytes)

        -- Input: c_in=32, h=1, w=2 -> 64 bytes
        -- Layout CHW: channel c, pixel p -> addr = c * hw + p
        -- hw = 1*2 = 2
        for c in 0 to 31 loop
            ddr_w8(ADDR_IN + c * 2 + 0, 5);   -- pixel 0
            ddr_w8(ADDR_IN + c * 2 + 1, 10);  -- pixel 1
        end loop;

        -- Weights OHWI: 1x1, c_in=32 -> 32 bytes per oc
        -- oc=0: all weights = 3
        for ic in 0 to 31 loop
            ddr_w8(ADDR_W + 0 * 32 + ic, 3);  -- oc=0
        end loop;
        -- oc=1..31: all 0 (already cleared)

        -- Bias: oc=0 = 100, rest = 0
        ddr_w32(ADDR_B + 0, 100);
        for i in 1 to 31 loop
            ddr_w32(ADDR_B + i * 4, 0);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(32, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(1, 10);
        cfg_w_in         <= to_unsigned(2, 10);
        cfg_ksize        <= "00";          -- 1x1
        cfg_stride       <= '0';
        cfg_pad_top      <= "00";
        cfg_pad_bottom   <= "00";
        cfg_pad_left     <= "00";
        cfg_pad_right    <= "00";
        cfg_x_zp         <= to_signed(-10, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(1, 10);  -- EXTREME: 1 channel per tile

        run_engine;

        -- hw_out = 1*2 = 2
        -- Expected: oc0 pixel0 = -10, oc0 pixel1 = -7
        got := ddr_r8(ADDR_OUT + 0 * 2 + 0);
        if got /= -10 then
            errors := errors + 1;
            report "T5 oc0 px0 FAIL got=" & integer'image(got) & " exp=-10" severity error;
        else
            report "T5 oc0 px0 OK: " & integer'image(got) severity note;
        end if;

        got := ddr_r8(ADDR_OUT + 0 * 2 + 1);
        if got /= -7 then
            errors := errors + 1;
            report "T5 oc0 px1 FAIL got=" & integer'image(got) & " exp=-7" severity error;
        else
            report "T5 oc0 px1 OK: " & integer'image(got) severity note;
        end if;

        -- oc=1..31 (weight=0, bias=0): acc=0 -> rq=-17
        for oc in 1 to 31 loop
            for px in 0 to 1 loop
                got := ddr_r8(ADDR_OUT + oc * 2 + px);
                if got /= -17 then
                    errors := errors + 1;
                    if errors <= 10 then
                        report "T5 oc=" & integer'image(oc) & " px=" & integer'image(px)
                            & " FAIL got=" & integer'image(got) & " exp=-17" severity error;
                    end if;
                end if;
            end loop;
        end loop;

        write(L, string'("Test 5 (tiling ic_tile=1): "));
        if errors = 0 then
            write(L, string'("PASS -- 32 tile passes accumulated correctly"));
            report "TEST 5: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 5: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- TEST 6: LARGE DIMENSIONS (16x16)
        -- c_in=1, c_out=32, h=16, w=16, k=3x3, pad=[1,1,1,1], stride=1
        -- h_out=16, w_out=16 -> 256 output pixels per channel
        -- Input: all=10, Weight oc0: all=1, Bias=0
        -- x_zp=0, M0=1073741824 (2^30), n_shift=30, y_zp=0
        -- Corner: 4*10=40, Edge: 6*10=60, Center: 9*10=90
        -----------------------------------------------------------------------
        report "============ TEST 6: Large 16x16 ============" severity note;
        ddr_clear;
        errors := 0;

        ADDR_IN  := 16#0000#;
        ADDR_W   := 16#0200#;
        ADDR_B   := 16#0400#;
        ADDR_OUT := 16#0500#;

        -- Input: 16x16x1 = 256 bytes, all = 10
        for i in 0 to 255 loop
            ddr_w8(ADDR_IN + i, 10);
        end loop;

        -- Weights: oc=0 has 9 weights = 1 (3x3x1 OHWI)
        for i in 0 to 8 loop
            ddr_w8(ADDR_W + i, 1);  -- oc=0
        end loop;
        -- oc=1..31: 0 (already cleared)

        -- Bias: all 0
        for i in 0 to 31 loop
            ddr_w32(ADDR_B + i * 4, 0);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(1, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(16, 10);
        cfg_w_in         <= to_unsigned(16, 10);
        cfg_ksize        <= "01";          -- 3x3
        cfg_stride       <= '0';
        cfg_pad_top      <= "01";
        cfg_pad_bottom   <= "01";
        cfg_pad_left     <= "01";
        cfg_pad_right    <= "01";
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1073741824, 32);
        cfg_n_shift      <= to_unsigned(30, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(1, 10);

        run_engine;

        -- Verify all 256 oc=0 outputs
        -- hw_out = 16*16 = 256
        for oh in 0 to 15 loop
            for ow_v in 0 to 15 loop
                -- Count valid taps
                exp := 0;
                for kkh in 0 to 2 loop
                    for kkw in 0 to 2 loop
                        if (oh - 1 + kkh) >= 0 and (oh - 1 + kkh) < 16
                           and (ow_v - 1 + kkw) >= 0 and (ow_v - 1 + kkw) < 16 then
                            exp := exp + 10;
                        end if;
                    end loop;
                end loop;

                got := ddr_r8(ADDR_OUT + 0 * 256 + oh * 16 + ow_v);
                if got /= exp then
                    errors := errors + 1;
                    if errors <= 20 then
                        report "T6 oc0 (" & integer'image(oh) & "," & integer'image(ow_v)
                            & ") FAIL got=" & integer'image(got)
                            & " exp=" & integer'image(exp) severity error;
                    end if;
                end if;
            end loop;
        end loop;

        -- Spot-check oc=1 (should be 0 everywhere: bias=0, weight=0, M0*0 >> n + 0 = 0)
        for px in 0 to 255 loop
            got := ddr_r8(ADDR_OUT + 1 * 256 + px);
            if got /= 0 then
                errors := errors + 1;
                if errors <= 25 then
                    report "T6 oc1 px=" & integer'image(px)
                        & " FAIL got=" & integer'image(got) & " exp=0" severity error;
                end if;
            end if;
        end loop;

        write(L, string'("Test 6 (16x16 large): "));
        if errors = 0 then
            write(L, string'("PASS -- all 256 oc0 pixels correct (corners/edges/center)"));
            report "TEST 6: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 6: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- TEST 7: ASYMMETRIC PADDING [1,0,1,0]
        -- pad_top=1, pad_bottom=0, pad_left=1, pad_right=0
        -- c_in=1, c_out=32, h=3, w=3, k=3x3, stride=1
        -- h_out = 3+1+0-3+1 = 2, w_out = 3+1+0-3+1 = 2
        -- Input: all=10, Weight oc0: all=1, Bias=0, x_zp=0
        -- M0=1073741824, n_shift=30, y_zp=0
        -- (0,0): 4 taps -> 40
        -- (0,1): 6 taps -> 60
        -- (1,0): 6 taps -> 60
        -- (1,1): 9 taps -> 90
        -----------------------------------------------------------------------
        report "============ TEST 7: Asymmetric pad [1,0,1,0] ============" severity note;
        ddr_clear;
        errors := 0;

        ADDR_IN  := 16#0000#;
        ADDR_W   := 16#0100#;
        ADDR_B   := 16#0200#;
        ADDR_OUT := 16#0300#;

        -- Input: 3x3x1 = 9 bytes, all=10
        for i in 0 to 8 loop
            ddr_w8(ADDR_IN + i, 10);
        end loop;

        -- Weights: oc=0 has 9 weights = 1
        for i in 0 to 8 loop
            ddr_w8(ADDR_W + i, 1);
        end loop;

        -- Bias: all 0
        for i in 0 to 31 loop
            ddr_w32(ADDR_B + i * 4, 0);
        end loop;

        do_reset;

        cfg_c_in         <= to_unsigned(1, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "01";          -- 3x3
        cfg_stride       <= '0';
        cfg_pad_top      <= "01";          -- pad top = 1
        cfg_pad_bottom   <= "00";          -- pad bottom = 0
        cfg_pad_left     <= "01";          -- pad left = 1
        cfg_pad_right    <= "00";          -- pad right = 0
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1073741824, 32);
        cfg_n_shift      <= to_unsigned(30, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_IN, 25);
        cfg_addr_weights <= to_unsigned(ADDR_W, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_B, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUT, 25);
        cfg_ic_tile_size <= to_unsigned(1, 10);

        run_engine;

        -- hw_out = 2*2 = 4
        -- Expected oc=0:
        -- (0,0)=40, (0,1)=60, (1,0)=60, (1,1)=90
        for px in 0 to 3 loop
            got := ddr_r8(ADDR_OUT + 0 * 4 + px);
            case px is
                when 0 => exp := 40;
                when 1 => exp := 60;
                when 2 => exp := 60;
                when others => exp := 90;
            end case;
            if got /= exp then
                errors := errors + 1;
                report "T7 oc0 px=" & integer'image(px)
                    & " FAIL got=" & integer'image(got)
                    & " exp=" & integer'image(exp) severity error;
            else
                report "T7 oc0 px=" & integer'image(px) & " OK: " & integer'image(got) severity note;
            end if;
        end loop;

        -- oc=1..31: all 0
        for oc in 1 to 31 loop
            for px in 0 to 3 loop
                got := ddr_r8(ADDR_OUT + oc * 4 + px);
                if got /= 0 then
                    errors := errors + 1;
                    if errors <= 10 then
                        report "T7 oc=" & integer'image(oc) & " px=" & integer'image(px)
                            & " FAIL got=" & integer'image(got) & " exp=0" severity error;
                    end if;
                end if;
            end loop;
        end loop;

        write(L, string'("Test 7 (asym pad [1,0,1,0]): "));
        if errors = 0 then
            write(L, string'("PASS -- asymmetric padding produces correct 2x2 output"));
            report "TEST 7: PASS" severity note;
        else
            write(L, string'("FAIL -- ") & integer'image(errors) & string'(" mismatches"));
            report "TEST 7: FAIL with " & integer'image(errors) & " errors" severity error;
        end if;
        writeline(results_file, L);
        total_errors <= total_errors + errors;

        -----------------------------------------------------------------------
        -- SUMMARY
        -----------------------------------------------------------------------
        write(L, string'("====================================="));
        writeline(results_file, L);
        write(L, string'("Total errors across all tests: ") & integer'image(total_errors));
        writeline(results_file, L);
        if total_errors = 0 then
            write(L, string'("ALL 7 STRESS TESTS PASSED"));
        else
            write(L, string'("SOME TESTS FAILED -- see details above"));
        end if;
        writeline(results_file, L);

        file_close(results_file);

        report "====================================================" severity note;
        report "ALL 7 STRESS TESTS COMPLETE" severity note;
        report "====================================================" severity note;

        sim_done <= true;
        wait;
    end process;

end architecture bench;
