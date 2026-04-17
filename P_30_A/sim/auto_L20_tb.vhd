library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;
library xpm; use xpm.vcomponents.all;

entity conv_v4_L20_tb is end entity;
architecture sim of conv_v4_L20_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant ADDR_OUTPUT  : natural := 0;
    constant ADDR_INPUT   : natural := 256;
    constant ADDR_WEIGHTS : natural := 768;
    constant ADDR_BIAS    : natural := 8960;
    constant N_INPUT   : natural := 512;
    constant N_WEIGHTS : natural := 8192;
    constant N_BIAS    : natural := 256;
    constant N_OUTPUT  : natural := 256;
    type mem_t is array (0 to 16383) of std_logic_vector(7 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));
    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';
    signal cfg_c_in   : unsigned(9 downto 0) := to_unsigned(128, 10);
    signal cfg_c_out  : unsigned(9 downto 0) := to_unsigned(64, 10);
    signal cfg_h_in   : unsigned(9 downto 0) := to_unsigned(2, 10);
    signal cfg_w_in   : unsigned(9 downto 0) := to_unsigned(2, 10);
    signal cfg_ksize  : unsigned(1 downto 0) := "00";
    signal cfg_stride : std_logic := '0';
    signal cfg_pad_top    : unsigned(1 downto 0) := to_unsigned(0, 2);
    signal cfg_pad_bottom : unsigned(1 downto 0) := to_unsigned(0, 2);
    signal cfg_pad_left   : unsigned(1 downto 0) := to_unsigned(0, 2);
    signal cfg_pad_right  : unsigned(1 downto 0) := to_unsigned(0, 2);
    signal cfg_x_zp       : signed(8 downto 0)  := to_signed(-104, 9);
    signal cfg_w_zp       : signed(7 downto 0)  := to_signed(0, 8);
    signal cfg_M0         : unsigned(31 downto 0) := to_unsigned(661451767, 32);
    signal cfg_n_shift    : unsigned(5 downto 0)  := to_unsigned(37, 6);
    signal cfg_y_zp       : signed(7 downto 0)  := to_signed(60, 8);
    signal cfg_addr_input    : unsigned(24 downto 0) := to_unsigned(ADDR_INPUT, 25);
    signal cfg_addr_weights  : unsigned(24 downto 0) := to_unsigned(ADDR_WEIGHTS, 25);
    signal cfg_addr_bias     : unsigned(24 downto 0) := to_unsigned(ADDR_BIAS, 25);
    signal cfg_addr_output   : unsigned(24 downto 0) := to_unsigned(ADDR_OUTPUT, 25);
    signal cfg_ic_tile_size  : unsigned(9 downto 0) := to_unsigned(128, 10);
    signal start : std_logic := '0';
    signal done, busy : std_logic;
    signal ddr_rd_addr : unsigned(24 downto 0);
    signal ddr_rd_data : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en   : std_logic;
    signal ddr_wr_addr : unsigned(24 downto 0);
    signal ddr_wr_data : std_logic_vector(7 downto 0);
    signal ddr_wr_en   : std_logic;
    signal dbg_state : integer range 0 to 63;
    signal dbg_oh, dbg_ow, dbg_kh, dbg_kw, dbg_ic : unsigned(9 downto 0);
    signal dbg_oc_tile_base, dbg_ic_tile_base : unsigned(9 downto 0);
    signal dbg_w_base : unsigned(19 downto 0);
    signal dbg_mac_a : signed(8 downto 0);
    signal dbg_mac_b : weight_array_t;
    signal dbg_mac_bi : bias_array_t;
    signal dbg_mac_acc : acc_array_t;
    signal dbg_mac_vi, dbg_mac_clr, dbg_mac_lb, dbg_pad : std_logic;
    signal dbg_act_addr : unsigned(24 downto 0);
    signal sim_end : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2;
    u_dut : entity work.conv_engine_v4
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
            cfg_no_clear => '0', cfg_no_requantize => '0',
            ext_wb_addr => (others => '0'), ext_wb_data => (others => '0'), ext_wb_we => '0',
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data, ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data, ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_oc_tile_base => dbg_oc_tile_base, dbg_ic_tile_base => dbg_ic_tile_base,
            dbg_w_base => dbg_w_base, dbg_mac_a => dbg_mac_a,
            dbg_mac_b => dbg_mac_b, dbg_mac_bi => dbg_mac_bi, dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr, dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr);
    p_stim : process
        variable ln : line; variable bv : std_logic_vector(7 downto 0);
        variable i, n_ok, n_fail : integer := 0;
        variable fs : file_open_status;
        file f : text;
        procedure lf(path: string; base: natural; nb: natural) is
            variable ll: line; variable bb: std_logic_vector(7 downto 0); variable j: integer := 0;
            variable ffs: file_open_status; file ff: text;
        begin
            file_open(ffs, ff, path, read_mode);
            while not endfile(ff) and j < nb loop readline(ff,ll); hread(ll,bb); mem(base+j):=bb; j:=j+1; end loop;
            file_close(ff);
        end procedure;
    begin
        rst_n <= '0'; wait for CLK_PERIOD*5;
        lf("C:/project/vivado/P_30_A/sim/vectors_auto/L20/input.hex", ADDR_INPUT, N_INPUT);
        lf("C:/project/vivado/P_30_A/sim/vectors_auto/L20/weights.hex", ADDR_WEIGHTS, N_WEIGHTS);
        lf("C:/project/vivado/P_30_A/sim/vectors_auto/L20/bias.hex", ADDR_BIAS, N_BIAS);
        wait for CLK_PERIOD*5; rst_n <= '1'; wait for CLK_PERIOD*2;
        wait until rising_edge(clk); start <= '1'; wait until rising_edge(clk); start <= '0';
        for t in 0 to 30000000 loop
            wait until rising_edge(clk);
            if ddr_rd_en='1' then ddr_rd_data <= mem(to_integer(ddr_rd_addr)); end if;
            if ddr_wr_en='1' then mem(to_integer(ddr_wr_addr)) := ddr_wr_data; end if;
            if done='1' then exit; end if;
        end loop;
        if done /= '1' then report "TIMEOUT" severity failure; end if;
        wait for CLK_PERIOD*5;
        file_open(fs, f, "C:/project/vivado/P_30_A/sim/vectors_auto/L20/expected.hex", read_mode);
        n_ok := 0; n_fail := 0; i := 0;
        while not endfile(f) and i < N_OUTPUT loop
            readline(f, ln); hread(ln, bv);
            if mem(ADDR_OUTPUT+i) = bv then n_ok := n_ok+1;
            else n_fail := n_fail+1; end if;
            i := i+1;
        end loop;
        file_close(f);
        report "RESULT: " & integer'image(n_ok) & "/" & integer'image(i) & " OK, " & integer'image(n_fail) & " mismatches";
        sim_end <= true; wait for CLK_PERIOD*10;
        assert false report "END" severity failure;
    end process;
end architecture;
