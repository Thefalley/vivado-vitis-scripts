-------------------------------------------------------------------------------
-- partial_tile_bug_tb.vhd
--
-- Minimal reproducer for the conv_engine_v3 partial-tile bug.
--
-- Config:
--   c_in=3, c_out=32, h_in=w_in=1, kernel=1x1, stride=1, no padding.
--   ic_tile_size=2  => tile 0 covers ic=0..1 (full), tile 1 covers ic=2 (partial).
--   Identity-ish requantize: x_zp=0, w_zp=0, y_zp=0, M0=2^30, n_shift=30.
--   (M0 * 2^(-n_shift) = 1.0, so requantize(x) = sat(x, -128, 127).)
--
-- Weights (OHWI), one output pixel, kernel=1x1 => per-filter weight layout is
-- just [ic=0, ic=1, ic=2]:
--   filter 0 : [10, 20, 30]        -> expected 1*10+2*20+3*30 = 140 -> sat 127
--   filter 1 : [ 1,  1,  1]        -> expected                   6
--   filter 2 : [ 0,  0,  1]        -> expected                   3   (only ic=2)
--   filter 3 : [ 1,  0,  0]        -> expected                   1   (only ic=0)
--   filter 4 : [ 0,  1,  0]        -> expected                   2   (only ic=1)
--   filters 5..31 : zeros          -> expected                   0
--
-- Filter 2 is the key diagnostic: with the suspected bug, the partial tile
-- (tile 1, ic=2) reads mac_b(2) from the wrong offset in weight_buf, so
-- its contribution becomes 0 (instead of 3).
--
-- CSV: writes trace.csv with one row per clock cycle while busy.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity partial_tile_bug_tb is
end;

architecture bench of partial_tile_bug_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal cfg_c_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out     : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize     : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride    : std_logic := '0';
    signal cfg_pad_top     : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_bottom  : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_left    : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_right   : unsigned(1 downto 0) := (others => '0');
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

    -- Debug ports from conv_engine_v3
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

    -- DDR address map (flat, BRAM-backed)
    constant ADDR_INPUT   : natural := 16#0000#;
    constant ADDR_WEIGHTS : natural := 16#0100#;
    constant ADDR_BIAS    : natural := 16#0400#;
    constant ADDR_OUTPUT  : natural := 16#0600#;

    signal sim_done : std_logic := '0';
    signal cycle_cnt : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    p_cnt : process(clk)
    begin
        if rising_edge(clk) then
            cycle_cnt <= cycle_cnt + 1;
        end if;
    end process;

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
    -- CSV logger: one row per clock cycle while busy (or done pulse).
    --
    -- Columns dump the externally-visible debug signals plus the DDR handshake
    -- and the five mac_b / mac_acc slots that we care about (filters 0..4).
    -- Internal WL_* / wb_* / wload_* signals are pulled via hierarchical
    -- references (xsim supports << signal .. name >>) so the RTL stays
    -- untouched.
    ---------------------------------------------------------------------------
    p_csv : process(clk)
        file csv_file    : text;
        variable csv_line    : line;
        variable file_opened : boolean := false;

        -- Hierarchical references into the DUT (xsim external names).
        alias a_wl_i        is << signal .partial_tile_bug_tb.uut.wl_i        : unsigned(5 downto 0) >>;
        alias a_wl_kh       is << signal .partial_tile_bug_tb.uut.wl_kh       : unsigned(9 downto 0) >>;
        alias a_wl_kw       is << signal .partial_tile_bug_tb.uut.wl_kw       : unsigned(9 downto 0) >>;
        alias a_wl_j        is << signal .partial_tile_bug_tb.uut.wl_j        : unsigned(9 downto 0) >>;
        alias a_wl_buf_addr is << signal .partial_tile_bug_tb.uut.wl_buf_addr : unsigned(19 downto 0) >>;
        alias a_wl_ddr_addr is << signal .partial_tile_bug_tb.uut.wl_ddr_addr : unsigned(24 downto 0) >>;
        alias a_wb_we       is << signal .partial_tile_bug_tb.uut.wb_we       : std_logic >>;
        alias a_wb_addr     is << signal .partial_tile_bug_tb.uut.wb_addr     : unsigned(14 downto 0) >>;
        alias a_wb_din      is << signal .partial_tile_bug_tb.uut.wb_din      : std_logic_vector(7 downto 0) >>;
        alias a_wb_dout     is << signal .partial_tile_bug_tb.uut.wb_dout     : signed(7 downto 0) >>;
        alias a_wload_cnt   is << signal .partial_tile_bug_tb.uut.wload_cnt   : unsigned(5 downto 0) >>;
        alias a_wload_addr  is << signal .partial_tile_bug_tb.uut.wload_addr_r: unsigned(19 downto 0) >>;
        alias a_tile_stride is << signal .partial_tile_bug_tb.uut.tile_filter_stride : unsigned(19 downto 0) >>;
        alias a_ic_limit    is << signal .partial_tile_bug_tb.uut.ic_in_tile_limit    : unsigned(9 downto 0) >>;
    begin
        if rising_edge(clk) then
            if busy = '1' or done = '1' then
                if not file_opened then
                    file_open(csv_file, "trace.csv", write_mode);
                    write(csv_line, string'(
                      "cycle,time_ns,state,oc_tile_base,ic_tile_base,ic_in_tile_limit,tile_filter_stride,"
                    & "wl_i,wl_kh,wl_kw,wl_j,wl_buf_addr,wl_ddr_addr,"
                    & "ddr_rd_en,ddr_rd_addr,ddr_rd_data,"
                    & "wb_we,wb_addr,wb_din,wb_dout,"
                    & "oh,ow,kh,kw,ic,w_base_idx,wload_cnt,wload_addr,"
                    & "mac_a,mac_b_0,mac_b_1,mac_b_2,mac_b_3,mac_b_4,"
                    & "mac_acc_0,mac_acc_1,mac_acc_2,mac_acc_3,mac_acc_4,"
                    & "mac_vi,mac_clr,mac_lb,pad,act_addr,"
                    & "ddr_wr_en,ddr_wr_addr,ddr_wr_data"));
                    writeline(csv_file, csv_line);
                    file_opened := true;
                end if;

                write(csv_line, integer'image(cycle_cnt));                                   write(csv_line, string'(","));
                write(csv_line, integer'image(now / 1 ns));                                  write(csv_line, string'(","));
                write(csv_line, integer'image(dbg_state));                                   write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oc_tile_base)));                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic_tile_base)));                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_ic_limit)));                      write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_tile_stride)));                   write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_i)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_kh)));                         write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_kw)));                         write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_j)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_buf_addr)));                   write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_ddr_addr)));                   write(csv_line, string'(","));
                if ddr_rd_en = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_rd_addr)));                     write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(ddr_rd_data))));             write(csv_line, string'(","));
                if a_wb_we = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wb_addr)));                       write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(a_wb_din))));                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wb_dout)));                       write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oh)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ow)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kh)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kw)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_w_base)));                      write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wload_cnt)));                     write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wload_addr)));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_a)));                       write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(0))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(1))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(2))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(3))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(4))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(0))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(1))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(2))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(3))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(4))));                  write(csv_line, string'(","));
                if dbg_mac_vi = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                if dbg_mac_clr = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                if dbg_mac_lb = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                if dbg_pad = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_act_addr)));                    write(csv_line, string'(","));
                if ddr_wr_en = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_wr_addr)));                     write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(ddr_wr_data))));
                writeline(csv_file, csv_line);

                if done = '1' then
                    file_close(csv_file);
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus + DDR model
    ---------------------------------------------------------------------------
    p_main : process
        type ddr_t is array(0 to 2047) of std_logic_vector(7 downto 0);
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

        -- OHWI layout for kh=kw=1: per-filter 3 bytes [ic=0, ic=1, ic=2].
        type f_t is array(0 to 2) of integer;
        constant F0 : f_t := (10, 20, 30);   -- expected 140 -> sat 127
        constant F1 : f_t := ( 1,  1,  1);   -- expected 6
        constant F2 : f_t := ( 0,  0,  1);   -- expected 3   (DISCRIMINATOR)
        constant F3 : f_t := ( 1,  0,  0);   -- expected 1
        constant F4 : f_t := ( 0,  1,  0);   -- expected 2

        type exp_t is array(0 to 31) of integer;
        -- Expected output per filter (one pixel each).
        constant expected : exp_t := (
            127,   6,   3,   1,   2,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0);

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;

    begin
        report "=============================================="            severity note;
        report "partial_tile_bug_tb : c_in=3, ic_tile_size=2"              severity note;
        report "  tile 0 covers ic=0..1 (2 ch), tile 1 covers ic=2 (1 ch)" severity note;
        report "=============================================="            severity note;

        -- Input: x[0]=1, x[1]=2, x[2]=3 (h_in=w_in=1 so layout is trivial)
        ddr_w8(ADDR_INPUT + 0, 1);
        ddr_w8(ADDR_INPUT + 1, 2);
        ddr_w8(ADDR_INPUT + 2, 3);

        -- Weights (OHWI): filter 0..31, each 3 bytes (kh=kw=1, c_in=3).
        for ic in 0 to 2 loop
            ddr_w8(ADDR_WEIGHTS + 0*3 + ic, F0(ic));
            ddr_w8(ADDR_WEIGHTS + 1*3 + ic, F1(ic));
            ddr_w8(ADDR_WEIGHTS + 2*3 + ic, F2(ic));
            ddr_w8(ADDR_WEIGHTS + 3*3 + ic, F3(ic));
            ddr_w8(ADDR_WEIGHTS + 4*3 + ic, F4(ic));
        end loop;
        -- Filters 5..31: already 0 from DDR init.

        -- Bias: 32 words of 0 (already 0 from init).

        -- Reset
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- Configure
        cfg_c_in         <= to_unsigned( 3, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned( 1, 10);
        cfg_w_in         <= to_unsigned( 1, 10);
        cfg_ksize        <= "00";           -- 1x1
        cfg_stride       <= '0';
        cfg_pad_top      <= "00";
        cfg_pad_bottom   <= "00";
        cfg_pad_left     <= "00";
        cfg_pad_right    <= "00";
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1073741824, 32);   -- 2^30
        cfg_n_shift      <= to_unsigned(30, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT,   25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS,    25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT,  25);
        cfg_ic_tile_size <= to_unsigned(2, 10);            -- PARTIAL LAST TILE

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING conv_engine_v3 (ic_tile_size=2, c_in=3 -> partial last tile)" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Service DDR until done
        timeout := 0;
        while done /= '1' and timeout < 200000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(10 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(10 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 200000 then
            report "TIMEOUT waiting for done" severity failure;
        end if;

        report "DONE after " & integer'image(timeout) & " cycles" severity note;

        -- Flush residual writes
        for i in 0 to 29 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(10 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -- Verify: one output pixel per oc (hw_out=1 -> out[oc] = addr_out+oc)
        report "==============================================" severity note;
        report "Result (one pixel, oc=0..31):"                   severity note;
        for oc in 0 to 31 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + oc)));
            if got /= expected(oc) then
                errors := errors + 1;
                report "oc=" & integer'image(oc) &
                       " FAIL  got=" & integer'image(got) &
                       " exp="       & integer'image(expected(oc)) severity error;
            else
                report "oc=" & integer'image(oc) &
                       " PASS y=" & integer'image(got) severity note;
            end if;
        end loop;

        report "==============================================" severity note;
        if errors = 0 then
            report "partial_tile_bug_tb : ALL PASSED (no bug visible?)" severity note;
        else
            report "partial_tile_bug_tb : BUG REPRODUCED, " &
                   integer'image(errors) & " mismatches" severity note;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
