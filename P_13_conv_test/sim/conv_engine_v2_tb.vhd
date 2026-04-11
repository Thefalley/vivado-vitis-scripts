library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

-- TB para conv_engine_v2 con TILING ACTIVO
-- Mismo input que v1 (3x3x3 → 32 filtros, layer_005)
-- pero forzamos ic_tile_size = 1 para que haya 3 tiles por pixel
-- Asi en la GUI se puede ver el tiling completo: cargar tile, MAC, cargar
-- siguiente tile, MAC, ..., requantize.

entity conv_engine_v2_tb is
end;

architecture bench of conv_engine_v2_tb is
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

    constant ADDR_INPUT   : natural := 16#000#;
    constant ADDR_WEIGHTS : natural := 16#400#;
    constant ADDR_BIAS    : natural := 16#800#;
    constant ADDR_OUTPUT  : natural := 16#C00#;

    signal sim_done : std_logic := '0';

begin

    clk <= not clk after CLK_PERIOD / 2;

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

        type img_t is array(0 to 26) of integer;
        constant img : img_t := (
            56,-106,21, 50,-102,17, 6,-97,-6,
            62,-64,39, 59,-57,34, 29,-42,23,
            65,-40,44, 70,-31,33, 39,-24,31
        );

        type wt_row_t is array(0 to 26) of integer;
        type wt_t is array(0 to 31) of wt_row_t;
        constant wt : wt_t := (
            ( -4, -3, 10, -8,-12, 11, -4, -5,  7, -2, -4,  6, -6,-12,  6, -1, -4,  6,  0, -2,  0, -3, -5,  3, -1, -2,  5),
            (-13, -2,  4, -7,  3,  6,  1,  5,  0,-10, -3,  6, -9, -1,  5,  4,  6,  5, -8, -7, -5, -8, -6, -3, -1, -2, -3),
            ( -2, -6, -9, -2, -7, -9,  0, -1, -4,  3, -3,  0,  3, -7, -2,  4,  2,  4,  2,  1,  4,  1, -1,  5, -1,  2,  5),
            (  3, -1,-14,  0, -9, -6,  8, -2, -6,  0,  3,  2, -6, -7,  9, -3, -6,  3,  4,  7,  3, -1, -6,  9, -2,-11, -3),
            ( -2,-12, -1,  2,-23,  5,  6,  9,  8, -5, -9, -7, -2,-16, -5, -1,  4, -3,  0, -3, -1,  3, -7,  1,  3,  5,  3),
            (  2, -2,  2,  0, -4, -2,  1, -3,  0, -7, -7, -8, -6, -7, -8, -7, -7, -8,  5,  8,  5,  7, 13, 10,  6, 10,  8),
            ( -1,  0, -2,  1,  6,  2, -2,  1, -1,  3,  5,  5,  4, 10,  7,  6,  9,  8, -2, -6, -4, -5,-12, -9, -4,-11, -8),
            ( 10, 18, 12,  0,  0,  0,-10,-18,-11,  9, 17, 10,  0,  0,  0, -9,-17,-11,  6, 12,  7,  0,  0,  0, -6,-12, -7),
            (  6, -3, -9,  9, -8,-12, 10, -1, -3,  7, -1, -3,  6,-10, -9,  8, -2,  0,  3,  0, -1,  3, -6, -5,  3, -3, -2),
            (-28,  7,-27,  5,127,  5,-29,-13,-27, 14,-16, 14,-11,-18,-17, 16,-27, 10, 14, -6, 16, -4,-54, -5, 14,  2, 20),
            ( -1, -1, -7,  3, 10,-10,  6, -4, -8,  3,  1, -8,  7, 10,-13, 10, -5,-10,  3,  1, -8,  7, 14, -8, 10, -1, -7),
            (  2,  0,  0, -1, -8, -4,  2, -6, -2, -4, -6, -6, -6, -9, -8, -3, -9, -6,  3,  9,  4,  6, 19, 12,  2, 12,  8),
            ( -3, -2,  1, -4, -3,  1,  0,  1,  4, -5,  0,  9,-10, -4,  8, -7, -2,  8, -5,  1,  9,-10, -2,  8, -9, -3,  7),
            (  2, 11, 11,  9,-46,  1,  5, -2,  9,  5,  2,  8,  5,-30, -4,  8, -5,  3,-12, -1,-14, -4, 16, -6,-11,  2,-12),
            (-10,  1, 12,-13,  2, 20,-14, -3, 11, -7, -1,  4, -8,  3, 13, -7,  0,  6, -2, -1, -1, -2,  2,  5, -2,  1,  2),
            (  1,  6,  2,  4, 20, 10,  1, 10,  5, -3, -9, -5, -6, -9, -9, -4,-11, -8,  3,  0,  4, -1, -4, -2,  4, -1,  3),
            ( -4, -3,  4, -6, -2, -8, -2,-12, -9, -1,  4,  2,  4,  9, -8,  4, -8,-12, -6,  2, -2,  3, 13, -7,  7, -1,-11),
            ( -2, -1,  3, -5,-48, 46, -1, -4,  5,  7,  0,  0, -5,-60, 53,  9, -3,  4,  3,  0, -2,  3,-12, 12,  4, -3,  1),
            ( -4, -4, -1,-11,-15,  0, -2, -4, -4, -1,  0, 11,-12,-19,  6,  4,  2,  6, -7, -1, 10,-13,-14, 10,  2,  3, 10),
            ( 29,  9,-21, 36,  4,-36, 25, -3,-38,-11, -3,  8,-11,  2, 21,-10, -2, 10,-20, -7, 12,-26, -1, 31,-12,  5, 24),
            (  0,  2, -1,  2,  2,  2,  2,  4,  3,  3,  0,  2, -2, -7, -1, -2, -5, -1,  0,  0,  2, -4, -5, -2, -4, -5, -3),
            (-10,-13,-14,  4,  5,  4,  5, 10, 10, -7, -9, -9,  1,  3,  1,  5,  9,  7, -6, -7, -6, -2,  0,  0,  4,  8,  7),
            ( -7,  6, -6,  0,-14, -6, -1,  2, -5,  7, 10, 10,  3,-31, -1,  3, -9,  3,  4, 17,  9,  3,-18,  3, -4,-10,  2),
            (  6,  2,  3,  4, -4, -4,  5, -2, -9,  0, -3, -1, -2, -8, -5,  0, -6, -7,  3,  2,  3,  1, -2,  0,  3, -1, -2),
            ( -2, -1, -2,  0,  5,  1, -4,  2, -1,  0, -2, -2,  0,  4,  0,  0,  3,  0, -2,  0, -4,  1, 13,  3,  1, 13,  5),
            ( -1,  1, -2,  4, 18, -8,  1,  0,-14,  3,  2,  5,  1,  4, -6,  4, -5, -7, -1, -4,  2, -6, -7, -8, -4,-12, -8),
            (  0,  4,  4,  2, 11, 13,  0,  6,  5,  0, -3, -4, -2,  3, 10,  0, -1, -3, -2, -7,  2, -4,  2, 25, -4,-11, -1),
            (  1,-12,  2,-11,-32,-13,  2,-18,  0,  4,  6,  4,  6, 24,  8,  5,  9,  4, -4,  0, -5,  0, 23,  3, -6,  6, -4),
            (  2,  4,  0,  6, 17,  4,  0,  6,  1, -3,  1, -1,  0, 14, -2, -3,  2, -4, -4, -2, -5,  2, 17, -6, -2,  5, -8),
            (-21,-36,-31, -1,  1, -7, 27, 44, 31,  4, 15, 11,  0, 10,  2, -9,-14,-15, 14, 28, 22, -1,  5,  4,-17,-32,-21),
            (  1, -5,  1,  0,-48, -4, -2, 55,  5,  8,-13,  7,  1,-60,-10, -3, 65,  4,  2,  1,  3,  2,-21, -5, -3, 21,  1),
            (  4,  5,  8, -2, -6,  2, -4, -5,  0, -1, -1, -1, -4, -7, -4, -3, -3, -3,  1,  1,  0,  2,  0,  0,  2,  3,  2)
        );

        type bias_t is array(0 to 31) of integer;
        constant biases : bias_t := (
            1623,1048,1258,232,1845,1748,1300,1221,
            1861,123,-859,-1173,4085,2515,659,825,
            1526,3951,1526,1647,1409,-616,1566,984,
            -6950,1229,-10249,2056,-8582,1821,3756,814
        );

        type exp_t is array(0 to 31) of integer;
        -- Mismos expected que v1 (calculados con Python para este input)
        constant expected : exp_t := (
            -9,-31,-20,-31,-33,-12,-11,0,-22,-61,-47,-23,12,-11,-2,-16,
            -50,26,-7,1,-16,-36,-6,-25,-39,-47,-48,-4,-49,-6,64,-13
        );

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;

    begin
        report "==============================================" severity note;
        report "TEST conv_engine_v2 con TILING (ic_tile_size=1)" severity note;
        report "c_in=3, ic_tile_size=1, 3 tiles por pixel" severity note;
        report "==============================================" severity note;

        -- Cargar DDR (mismo layout que v1)
        for i in 0 to 26 loop
            ddr_w8(ADDR_INPUT + i, img(i));
        end loop;
        for oc in 0 to 31 loop
            for k in 0 to 26 loop
                ddr_w8(ADDR_WEIGHTS + oc*27 + k, wt(oc)(k));
            end loop;
        end loop;
        for i in 0 to 31 loop
            ddr_w32(ADDR_BIAS + i*4, biases(i));
        end loop;

        report "DDR loaded" severity note;

        -- Reset
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- Configurar
        cfg_c_in        <= to_unsigned(3, 10);
        cfg_c_out       <= to_unsigned(32, 10);
        cfg_h_in        <= to_unsigned(3, 10);
        cfg_w_in        <= to_unsigned(3, 10);
        cfg_ksize       <= "10";
        cfg_stride      <= '0';
        cfg_pad         <= '1';
        cfg_x_zp        <= to_signed(-128, 9);
        cfg_w_zp        <= to_signed(0, 8);
        cfg_M0          <= to_unsigned(656954014, 32);
        cfg_n_shift     <= to_unsigned(37, 6);
        cfg_y_zp        <= to_signed(-17, 8);
        cfg_addr_input  <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights<= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias   <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output <= to_unsigned(ADDR_OUTPUT, 25);
        -- *** TILING ACTIVO: 1 canal por tile (3 tiles por pixel) ***
        cfg_ic_tile_size <= to_unsigned(1, 10);

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING v2 with ic_tile_size=1" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Loop esperando done + servir DDR
        timeout := 0;
        while done /= '1' and timeout < 500000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(11 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 500000 then
            report "TIMEOUT esperando done" severity failure;
        end if;

        report "DONE en ciclo " & integer'image(timeout) severity note;

        for i in 0 to 9 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -- Verificar pixel(1,1) de los 32 canales
        report "==============================================" severity note;
        report "VERIFICANDO 32 CANALES" severity note;
        for oc in 0 to 31 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + oc * 9 + 4)));
            if got /= expected(oc) then
                errors := errors + 1;
                report "oc=" & integer'image(oc) &
                       " FAIL got=" & integer'image(got) &
                       " exp=" & integer'image(expected(oc)) severity error;
            else
                report "oc=" & integer'image(oc) & " OK y=" & integer'image(got) severity note;
            end if;
        end loop;

        report "==============================================" severity note;
        if errors = 0 then
            report "v2 ALL 32 CHANNELS PASSED" severity note;
        else
            report "v2 FAILED: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
