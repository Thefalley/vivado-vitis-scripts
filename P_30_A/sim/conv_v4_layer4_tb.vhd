-------------------------------------------------------------------------------
-- conv_v4_layer4_tb.vhd — layer 4 de YOLOv4 con vectores reales ONNX
--
-- conv_engine_v4: c_in=64, c_out=64, k=1, stride=1, pad=0
-- Tile: 4x4 output, 4x4 input (1x1 conv, no padding)
--
-- Modelo DDR: servido DENTRO del stim process, con ddr_rd_data como signal
-- inicializada a 0 y actualizada combinacionalmente desde memory cada ciclo.
-- Patron de los TBs verificados de P_13/simB y P_18.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity conv_v4_layer4_tb is
end entity;

architecture sim of conv_v4_layer4_tb is

    constant CLK_PERIOD : time := 10 ns;

    constant PATH_INPUT    : string := "../sim/vectors_layer4/input_nchw.hex";
    constant PATH_WEIGHTS  : string := "../sim/vectors_layer4/weights_ohwi.hex";
    constant PATH_BIAS     : string := "../sim/vectors_layer4/bias_int32.hex";
    constant PATH_EXPECTED : string := "../sim/vectors_layer4/expected_out_nchw.hex";

    -- Memory layout (64-byte aligned):
    --   OUT  @ 0x0000  1024 B  (64 x 4 x 4)
    --   IN   @ 0x0400  1024 B  (64 x 4 x 4)
    --   W    @ 0x0800  4096 B  (64 x 1 x 1 x 64)
    --   BIAS @ 0x1800   256 B  (64 x 4)
    constant ADDR_OUTPUT  : natural := 16#0000#;
    constant ADDR_INPUT   : natural := 16#0400#;
    constant ADDR_WEIGHTS : natural := 16#0800#;  -- align64(0x400+1024) = 0x800
    constant ADDR_BIAS    : natural := 16#1800#;  -- align64(0x800+4096) = 0x1800

    constant N_INPUT   : natural := 1024;
    constant N_WEIGHTS : natural := 4096;
    constant N_BIAS    : natural := 256;
    constant N_OUTPUT  : natural := 1024;

    -- DDR simulado 8 KB (suficiente para ~6.4 KB de datos)
    type mem_t is array (0 to 8191) of std_logic_vector(7 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';

    -- CFG: layer 4 parameters
    signal cfg_c_in          : unsigned(9 downto 0) := to_unsigned(64, 10);
    signal cfg_c_out         : unsigned(9 downto 0) := to_unsigned(64, 10);
    signal cfg_h_in          : unsigned(9 downto 0) := to_unsigned(4, 10);   -- 4 real rows
    signal cfg_w_in          : unsigned(9 downto 0) := to_unsigned(4, 10);   -- 4 real cols
    signal cfg_ksize         : unsigned(1 downto 0) := "00";                -- 1x1
    signal cfg_stride        : std_logic := '0';                            -- stride 1
    signal cfg_pad_top       : unsigned(1 downto 0) := "00";               -- no padding
    signal cfg_pad_bottom    : unsigned(1 downto 0) := "00";               -- no padding
    signal cfg_pad_left      : unsigned(1 downto 0) := "00";               -- no padding
    signal cfg_pad_right     : unsigned(1 downto 0) := "00";               -- no padding
    signal cfg_x_zp          : signed(8 downto 0)  := to_signed(-97, 9);
    signal cfg_w_zp          : signed(7 downto 0)  := to_signed(0, 8);
    signal cfg_M0            : unsigned(31 downto 0) := to_unsigned(624082313, 32);
    signal cfg_n_shift       : unsigned(5 downto 0)  := to_unsigned(37, 6);
    signal cfg_y_zp          : signed(7 downto 0)  := to_signed(7, 8);
    signal cfg_addr_input    : unsigned(24 downto 0) := to_unsigned(ADDR_INPUT,   25);
    signal cfg_addr_weights  : unsigned(24 downto 0) := to_unsigned(ADDR_WEIGHTS, 25);
    signal cfg_addr_bias     : unsigned(24 downto 0) := to_unsigned(ADDR_BIAS,    25);
    signal cfg_addr_output   : unsigned(24 downto 0) := to_unsigned(ADDR_OUTPUT,  25);
    signal cfg_ic_tile_size  : unsigned(9 downto 0)  := to_unsigned(64, 10);
    signal cfg_no_clear      : std_logic := '0';
    signal cfg_no_requantize : std_logic := '0';

    signal start : std_logic := '0';
    signal done, busy : std_logic;

    signal ddr_rd_addr : unsigned(24 downto 0);
    signal ddr_rd_data : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en   : std_logic;
    signal ddr_wr_addr : unsigned(24 downto 0);
    signal ddr_wr_data : std_logic_vector(7 downto 0);
    signal ddr_wr_en   : std_logic;

    signal dbg_state       : integer range 0 to 63;
    signal dbg_oh          : unsigned(9 downto 0);
    signal dbg_ow          : unsigned(9 downto 0);
    signal dbg_kh          : unsigned(9 downto 0);
    signal dbg_kw          : unsigned(9 downto 0);
    signal dbg_ic          : unsigned(9 downto 0);
    signal dbg_oc_tile_base: unsigned(9 downto 0);
    signal dbg_ic_tile_base: unsigned(9 downto 0);
    signal dbg_w_base      : unsigned(19 downto 0);
    signal dbg_mac_a       : signed(8 downto 0);
    signal dbg_mac_b       : weight_array_t;
    signal dbg_mac_bi      : bias_array_t;
    signal dbg_mac_acc     : acc_array_t;
    signal dbg_mac_vi      : std_logic;
    signal dbg_mac_clr     : std_logic;
    signal dbg_mac_lb      : std_logic;
    signal dbg_pad         : std_logic;
    signal dbg_act_addr    : unsigned(24 downto 0);

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
            cfg_addr_input => cfg_addr_input,
            cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias,
            cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            cfg_no_clear => cfg_no_clear,
            cfg_no_requantize => cfg_no_requantize,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data, ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data, ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state,
            dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_oc_tile_base => dbg_oc_tile_base,
            dbg_ic_tile_base => dbg_ic_tile_base,
            dbg_w_base => dbg_w_base,
            dbg_mac_a => dbg_mac_a,
            dbg_mac_b => dbg_mac_b, dbg_mac_bi => dbg_mac_bi, dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr, dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr,
            ext_wb_addr => (others => '0'),
            ext_wb_data => (others => '0'),
            ext_wb_we => '0'
        );

    -- Monitor: periodic state dump
    p_mon : process
    begin
        while not sim_end loop
            wait for CLK_PERIOD * 5000;
            report "[mon] t="
                 & " state=" & integer'image(dbg_state)
                 & " oh=" & integer'image(to_integer(dbg_oh))
                 & " ow=" & integer'image(to_integer(dbg_ow))
                 & " oc_tb=" & integer'image(to_integer(dbg_oc_tile_base))
                 & " busy=" & std_logic'image(busy);
        end loop;
        wait;
    end process;

    -- Writes monitor
    p_wr_mon : process(clk)
        variable n : integer := 0;
    begin
        if rising_edge(clk) then
            if ddr_wr_en = '1' then
                n := n + 1;
                if n <= 40 then
                    report "[wr " & integer'image(n) & "] addr=0x"
                         & to_hstring(std_logic_vector(ddr_wr_addr))
                         & " data=0x" & to_hstring(ddr_wr_data);
                end if;
            end if;
        end if;
    end process;

    -- Main stimulus + DDR service
    p_stim : process
        variable line_in : line;
        variable byte_v  : std_logic_vector(7 downto 0);
        variable idx     : integer;
        variable file_status : file_open_status;
        variable n_mismatch  : integer := 0;
        variable n_ok        : integer := 0;
        file f : text;

        procedure load_file(path : string; base : natural; nbytes : natural) is
            variable ln : line;
            variable bv : std_logic_vector(7 downto 0);
            variable i  : integer := 0;
            variable fs : file_open_status;
            file ff : text;
        begin
            file_open(fs, ff, path, read_mode);
            if fs /= open_ok then
                report "Cannot open: " & path severity failure;
            end if;
            while not endfile(ff) and i < nbytes loop
                readline(ff, ln);
                hread(ln, bv);
                mem(base + i) := bv;
                i := i + 1;
            end loop;
            file_close(ff);
            report "Loaded " & integer'image(i) & " B from " & path;
        end procedure;

    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 5;

        load_file(PATH_INPUT,   ADDR_INPUT,   N_INPUT);
        load_file(PATH_WEIGHTS, ADDR_WEIGHTS, N_WEIGHTS);
        load_file(PATH_BIAS,    ADDR_BIAS,    N_BIAS);

        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        report "=== Starting conv_engine_v4 layer 4: "
             & "c_in=64 c_out=64 k=1 stride=1 pad=0 ===";
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- DDR service + wait-for-done (proven pattern)
        for t in 0 to 10000000 loop
            wait until rising_edge(clk);
            if ddr_rd_en = '1' then
                ddr_rd_data <= mem(to_integer(ddr_rd_addr));
            end if;
            if ddr_wr_en = '1' then
                mem(to_integer(ddr_wr_addr)) := ddr_wr_data;
            end if;
            if done = '1' then
                exit;
            end if;
        end loop;

        if done /= '1' then
            report "*** TIMEOUT ***" severity failure;
        end if;

        report "=== DONE! Comparing output ===";
        wait for CLK_PERIOD * 5;

        file_open(file_status, f, PATH_EXPECTED, read_mode);
        if file_status /= open_ok then
            report "Cannot open expected file" severity failure;
        end if;

        idx := 0;
        while not endfile(f) and idx < N_OUTPUT loop
            readline(f, line_in);
            hread(line_in, byte_v);
            if mem(ADDR_OUTPUT + idx) = byte_v then
                n_ok := n_ok + 1;
            else
                n_mismatch := n_mismatch + 1;
                if n_mismatch <= 16 then
                    report "MISMATCH idx=" & integer'image(idx)
                         & " got=0x" & to_hstring(mem(ADDR_OUTPUT + idx))
                         & "(" & integer'image(to_integer(signed(mem(ADDR_OUTPUT + idx)))) & ")"
                         & " exp=0x" & to_hstring(byte_v)
                         & "(" & integer'image(to_integer(signed(byte_v))) & ")"
                         severity warning;
                end if;
            end if;
            idx := idx + 1;
        end loop;
        file_close(f);

        report "=== RESULT: " & integer'image(n_ok) & "/" & integer'image(idx)
             & " bytes OK, " & integer'image(n_mismatch) & " mismatches ===";

        sim_end <= true;
        wait for CLK_PERIOD * 10;
        assert false report "Simulation end" severity failure;
    end process;

end architecture;
