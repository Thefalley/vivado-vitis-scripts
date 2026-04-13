-------------------------------------------------------------------------------
-- stress_t5_debug_tb.vhd -- Debug version of Test 5 (ic_tile=1)
-- Dumps CSV of internal signals to diagnose the weight-buffer aliasing bug.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.mac_array_pkg.all;

entity stress_t5_debug_tb is
end;

architecture bench of stress_t5_debug_tb is
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
    signal cycle_cnt : integer := 0;

    constant DDR_SIZE : natural := 8192;
    type ddr_t is array(0 to DDR_SIZE-1) of std_logic_vector(7 downto 0);
    shared variable ddr : ddr_t := (others => (others => '0'));

    file csv_file : text;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done;

    process(clk) begin
        if rising_edge(clk) then cycle_cnt <= cycle_cnt + 1; end if;
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

    -- DDR model
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

    -- CSV logger: dump internal signals when MAC fires or weight loads
    p_csv : process(clk)
        variable L : line;
    begin
        if rising_edge(clk) then
            if cycle_cnt = 0 then
                file_open(csv_file, "debug_t5_tiling.csv", write_mode);
                write(L, string'("cycle,state,oc_tile,ic_tile,oh,ow,kh,kw,ic,w_base,mac_a,mac_b0,mac_b8,mac_b16,mac_b17,mac_vi,mac_clr,mac_lb,pad,acc0,acc8,acc16,acc17,wr_en,wr_addr,wr_data"));
                writeline(csv_file, L);
            end if;

            -- Log on mac_vi, mac_clr, mac_lb, or ddr_wr_en
            if dbg_mac_vi = '1' or dbg_mac_clr = '1' or dbg_mac_lb = '1' or ddr_wr_en = '1' then
                write(L, integer'image(cycle_cnt));
                write(L, string'(",") & integer'image(dbg_state));
                write(L, string'(",") & integer'image(to_integer(dbg_oc_tile_base)));
                write(L, string'(",") & integer'image(to_integer(dbg_ic_tile_base)));
                write(L, string'(",") & integer'image(to_integer(dbg_oh)));
                write(L, string'(",") & integer'image(to_integer(dbg_ow)));
                write(L, string'(",") & integer'image(to_integer(dbg_kh)));
                write(L, string'(",") & integer'image(to_integer(dbg_kw)));
                write(L, string'(",") & integer'image(to_integer(dbg_ic)));
                write(L, string'(",") & integer'image(to_integer(dbg_w_base)));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_a)));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_b(0))));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_b(8))));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_b(16))));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_b(17))));
                write(L, string'(",") & std_logic'image(dbg_mac_vi));
                write(L, string'(",") & std_logic'image(dbg_mac_clr));
                write(L, string'(",") & std_logic'image(dbg_mac_lb));
                write(L, string'(",") & std_logic'image(dbg_pad));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_acc(0))));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_acc(8))));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_acc(16))));
                write(L, string'(",") & integer'image(to_integer(dbg_mac_acc(17))));
                write(L, string'(",") & std_logic'image(ddr_wr_en));
                write(L, string'(",") & integer'image(to_integer(ddr_wr_addr)));
                write(L, string'(",") & integer'image(to_integer(signed(ddr_wr_data))));
                writeline(csv_file, L);
            end if;
        end if;
    end process;

    p_main : process
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

        constant ADDR_IN  : natural := 16#0000#;
        constant ADDR_W   : natural := 16#0100#;
        constant ADDR_B   : natural := 16#0200#;
        constant ADDR_OUT : natural := 16#0300#;

        variable got : integer;
        variable timeout : integer;
    begin
        -- Load DDR
        -- Input: c_in=32, h=1, w=2 -> 64 bytes
        for c in 0 to 31 loop
            ddr_w8(ADDR_IN + c * 2 + 0, 5);
            ddr_w8(ADDR_IN + c * 2 + 1, 10);
        end loop;

        -- Weights OHWI: 1x1, c_in=32 -> 32 bytes per oc
        -- oc=0: all = 3, rest = 0
        for ic in 0 to 31 loop
            ddr_w8(ADDR_W + 0 * 32 + ic, 3);
        end loop;

        -- Bias: oc=0 = 100, rest = 0
        ddr_w32(ADDR_B + 0, 100);
        for i in 1 to 31 loop
            ddr_w32(ADDR_B + i * 4, 0);
        end loop;

        -- Reset
        rst_n <= '0';
        for i in 0 to 9 loop wait until rising_edge(clk); end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- Configure
        cfg_c_in         <= to_unsigned(32, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(1, 10);
        cfg_w_in         <= to_unsigned(2, 10);
        cfg_ksize        <= "00";
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
        cfg_ic_tile_size <= to_unsigned(1, 10);

        wait until rising_edge(clk);
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        timeout := 0;
        while done /= '1' and timeout < 2000000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
        end loop;

        for i in 0 to 29 loop wait until rising_edge(clk); end loop;

        -- Dump all output bytes
        report "OUTPUT DUMP:" severity note;
        for oc in 0 to 31 loop
            for px in 0 to 1 loop
                got := to_integer(signed(ddr(ADDR_OUT + oc * 2 + px)));
                report "  oc=" & integer'image(oc) & " px=" & integer'image(px)
                    & " val=" & integer'image(got) severity note;
            end loop;
        end loop;

        file_close(csv_file);
        sim_done <= true;
        wait;
    end process;

end architecture bench;
