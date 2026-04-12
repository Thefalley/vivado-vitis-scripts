-------------------------------------------------------------------------------
-- conv_engine_bram_tb.vhd -- Verify conv_engine with BRAM weight buffer
-------------------------------------------------------------------------------
-- Three tests with pad=0 (no negative ih_base) to cleanly verify that
-- the BRAM weight pipeline (MAC_WLOAD -> MAC_WLOAD_CAP) works correctly.
--
-- TEST 1: All-ones weights, varied input   -> verifies basic BRAM read
-- TEST 2: Varied weights, constant input   -> verifies BRAM ordering
-- TEST 3: Varied weights + varied input    -> verifies both paths
--
-- NOTE: pad=1 tests expose a PRE-EXISTING address computation bug in
-- conv_engine (unsigned truncation of negative ih_base before multiply),
-- which is unrelated to the BRAM change. pad=0 avoids this entirely.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity conv_engine_bram_tb is
end;

architecture bench of conv_engine_bram_tb is
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
    signal start         : std_logic := '0';
    signal done          : std_logic;
    signal busy          : std_logic;
    signal ddr_rd_addr   : unsigned(24 downto 0);
    signal ddr_rd_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en     : std_logic;
    signal ddr_wr_addr   : unsigned(24 downto 0);
    signal ddr_wr_data   : std_logic_vector(7 downto 0);
    signal ddr_wr_en     : std_logic;

    -- Debug signals (match conv_engine v1 ports)
    signal dbg_state    : integer range 0 to 31;
    signal dbg_oh, dbg_ow, dbg_kh, dbg_kw, dbg_ic : unsigned(9 downto 0);
    signal dbg_w_base   : unsigned(19 downto 0);
    signal dbg_mac_a    : signed(8 downto 0);
    signal dbg_mac_b    : weight_array_t;
    signal dbg_mac_bi   : bias_array_t;
    signal dbg_mac_acc  : acc_array_t;
    signal dbg_mac_vi, dbg_mac_clr, dbg_mac_lb, dbg_pad : std_logic;
    signal dbg_act_addr : unsigned(24 downto 0);

    constant ADDR_INPUT   : natural := 16#000#;
    constant ADDR_WEIGHTS : natural := 16#100#;
    constant ADDR_BIAS    : natural := 16#200#;
    constant ADDR_OUTPUT  : natural := 16#300#;

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.conv_engine
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride, cfg_pad => cfg_pad,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data,
            ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data,
            ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_w_base => dbg_w_base,
            dbg_mac_a => dbg_mac_a, dbg_mac_b => dbg_mac_b,
            dbg_mac_bi => dbg_mac_bi, dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr,
            dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr
        );

    p_main : process
        type ddr_t is array(0 to 4095) of std_logic_vector(7 downto 0);
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

        variable errors_total : integer := 0;
        variable errors_test  : integer := 0;
        variable got          : integer;
        variable timeout      : integer;

        -- Run DDR server until done or timeout
        procedure serve_ddr(timeout_max : integer) is
        begin
            timeout := 0;
            while done /= '1' and timeout < timeout_max loop
                wait until rising_edge(clk);
                timeout := timeout + 1;
                if ddr_rd_en = '1' then
                    ddr_rd_data <= ddr(to_integer(ddr_rd_addr(11 downto 0)));
                end if;
                if ddr_wr_en = '1' then
                    ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
                end if;
            end loop;
            -- Drain writes after done
            for i in 0 to 20 loop
                wait until rising_edge(clk);
                if ddr_wr_en = '1' then
                    ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
                end if;
            end loop;
        end procedure;

        -- Reset + configure common parameters
        procedure reset_and_configure is
        begin
            rst_n <= '0';
            for i in 0 to 9 loop wait until rising_edge(clk); end loop;
            rst_n <= '1';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            cfg_c_in        <= to_unsigned(1, 10);
            cfg_c_out       <= to_unsigned(1, 10);
            cfg_h_in        <= to_unsigned(3, 10);
            cfg_w_in        <= to_unsigned(3, 10);
            cfg_ksize       <= "10";           -- 3x3
            cfg_stride      <= '0';            -- stride=1
            cfg_pad         <= '0';            -- NO padding
            cfg_x_zp        <= to_signed(-128, 9);
            cfg_w_zp        <= to_signed(0, 8);
            cfg_M0          <= to_unsigned(656954014, 32);
            cfg_n_shift     <= to_unsigned(37, 6);
            cfg_y_zp        <= to_signed(-17, 8);
            cfg_addr_input  <= to_unsigned(ADDR_INPUT, 25);
            cfg_addr_weights<= to_unsigned(ADDR_WEIGHTS, 25);
            cfg_addr_bias   <= to_unsigned(ADDR_BIAS, 25);
            cfg_addr_output <= to_unsigned(ADDR_OUTPUT, 25);
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end procedure;

        procedure do_start is
        begin
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';
        end procedure;

    begin
        ---------------------------------------------------------------
        -- TEST 1: All-ones weights, varied input
        -- Input: {1,2,3,4,5,6,7,8,9}, Weight: all 1, Bias: 1000
        -- acc = 1000 + sum((i+128)*1 for i=1..9) = 1000 + 1197 = 2197
        -- rq(2197) = -6
        ---------------------------------------------------------------
        report "==============================================" severity note;
        report "TEST 1: all-ones weights, varied input, pad=0" severity note;
        report "==============================================" severity note;

        ddr := (others => (others => '0'));
        for i in 0 to 8 loop ddr_w8(ADDR_INPUT + i, i + 1); end loop;
        for i in 0 to 8 loop ddr_w8(ADDR_WEIGHTS + i, 1); end loop;
        ddr_w32(ADDR_BIAS + 0, 1000);

        reset_and_configure;
        do_start;
        serve_ddr(500000);

        if timeout >= 500000 then
            report "TEST1 TIMEOUT!" severity failure;
        end if;
        report "TEST1 done at cycle " & integer'image(timeout) severity note;

        got := to_integer(signed(ddr(ADDR_OUTPUT)));
        errors_test := 0;
        if got /= -6 then
            errors_test := 1;
            report "FAIL: got=" & integer'image(got) & " expected=-6" severity error;
        else
            report "OK:   got=" & integer'image(got) & " expected=-6" severity note;
        end if;
        errors_total := errors_total + errors_test;

        if errors_test = 0 then
            report "TEST 1 PASSED" severity note;
        else
            report "TEST 1 FAILED" severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 2: Varied weights, constant input
        -- Input: all 1, Weight: {1,2,...,9}, Bias: 500
        -- act = 1-(-128) = 129 for all taps
        -- acc = 500 + 129*(1+2+...+9) = 500 + 129*45 = 500+5805 = 6305
        -- rq(6305) = 13
        ---------------------------------------------------------------
        report "==============================================" severity note;
        report "TEST 2: varied weights, constant input, pad=0" severity note;
        report "==============================================" severity note;

        ddr := (others => (others => '0'));
        for i in 0 to 8 loop ddr_w8(ADDR_INPUT + i, 1); end loop;
        for i in 0 to 8 loop ddr_w8(ADDR_WEIGHTS + i, i + 1); end loop;
        ddr_w32(ADDR_BIAS + 0, 500);

        reset_and_configure;
        do_start;
        serve_ddr(500000);

        if timeout >= 500000 then
            report "TEST2 TIMEOUT!" severity failure;
        end if;
        report "TEST2 done at cycle " & integer'image(timeout) severity note;

        got := to_integer(signed(ddr(ADDR_OUTPUT)));
        errors_test := 0;
        if got /= 13 then
            errors_test := 1;
            report "FAIL: got=" & integer'image(got) & " expected=13" severity error;
        else
            report "OK:   got=" & integer'image(got) & " expected=13" severity note;
        end if;
        errors_total := errors_total + errors_test;

        if errors_test = 0 then
            report "TEST 2 PASSED" severity note;
        else
            report "TEST 2 FAILED" severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 3: Varied weights + varied input
        -- Input: {1,2,...,9}, Weight: {1,2,...,9}, Bias: 1000
        -- acc = 1000 + sum((i+128)*(i) for i=1..9)
        --     = 1000 + 129*1+130*2+131*3+132*4+133*5+134*6+135*7+136*8+137*9
        --     = 1000 + 129+260+393+528+665+804+945+1088+1233
        --     = 1000 + 6045 = 7045
        -- rq(7045) = 17
        ---------------------------------------------------------------
        report "==============================================" severity note;
        report "TEST 3: varied weights + varied input, pad=0" severity note;
        report "==============================================" severity note;

        ddr := (others => (others => '0'));
        for i in 0 to 8 loop ddr_w8(ADDR_INPUT + i, i + 1); end loop;
        for i in 0 to 8 loop ddr_w8(ADDR_WEIGHTS + i, i + 1); end loop;
        ddr_w32(ADDR_BIAS + 0, 1000);

        reset_and_configure;
        do_start;
        serve_ddr(500000);

        if timeout >= 500000 then
            report "TEST3 TIMEOUT!" severity failure;
        end if;
        report "TEST3 done at cycle " & integer'image(timeout) severity note;

        got := to_integer(signed(ddr(ADDR_OUTPUT)));
        errors_test := 0;
        if got /= 17 then
            errors_test := 1;
            report "FAIL: got=" & integer'image(got) & " expected=17" severity error;
        else
            report "OK:   got=" & integer'image(got) & " expected=17" severity note;
        end if;
        errors_total := errors_total + errors_test;

        if errors_test = 0 then
            report "TEST 3 PASSED" severity note;
        else
            report "TEST 3 FAILED" severity error;
        end if;

        ---------------------------------------------------------------
        -- FINAL SUMMARY
        ---------------------------------------------------------------
        report "==============================================" severity note;
        report "==============================================" severity note;
        if errors_total = 0 then
            report "*** ALL 3 TESTS PASSED -- BRAM weight buffer OK ***" severity note;
        else
            report "*** FAILED: " & integer'image(errors_total) & " test(s) ***" severity error;
        end if;
        report "==============================================" severity note;

        wait;
    end process;

end bench;
