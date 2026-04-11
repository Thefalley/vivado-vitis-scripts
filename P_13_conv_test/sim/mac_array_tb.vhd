library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity mac_array_tb is
end;

architecture bench of mac_array_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal a_in      : signed(8 downto 0)  := (others => '0');
    signal b_in      : weight_array_t      := (others => (others => '0'));
    signal bias_in   : bias_array_t        := (others => (others => '0'));
    signal valid_in  : std_logic := '0';
    signal load_bias : std_logic := '0';
    signal clear     : std_logic := '0';
    signal acc_out   : acc_array_t;
    signal valid_out : std_logic;

    -- Tipos para datos de test
    type wt_step_t is array(0 to 31) of integer;
    type wt_seq_t  is array(0 to 26) of wt_step_t;
    type bias_t    is array(0 to 31) of integer;
    type ain_t     is array(0 to 26) of integer;
    type exp_t     is array(0 to 31) of integer;

    -- 32 bias (layer_005)
    constant biases : bias_t := (
        1623, 1048, 1258,  232, 1845, 1748, 1300, 1221,
        1861,  123, -859,-1173, 4085, 2515,  659,  825,
        1526, 3951, 1526, 1647, 1409, -616, 1566,  984,
       -6950, 1229,-10249,2056,-8582, 1821, 3756,  814
    );

    -- 27 valores de a_in (broadcast a todos los MACs)
    constant a_vals : ain_t := (
        184, 22, 149, 178, 26, 145, 134, 31, 122,
        190, 64, 167, 187, 71, 162, 157, 86, 151,
        193, 88, 172, 198, 97, 161, 167, 104, 159
    );

    -- 27 steps × 32 weights (uno por filtro)
    constant weights : wt_seq_t := (
        ( -4,-13, -2,  3, -2,  2, -1, 10,  6,-28, -1,  2, -3,  2,-10,  1, -4, -2, -4, 29,  0,-10, -7,  6, -2, -1,  0,  1,  2,-21,  1,  4),
        ( -3, -2, -6, -1,-12, -2,  0, 18, -3,  7, -1,  0, -2, 11,  1,  6, -3, -1, -4,  9,  2,-13,  6,  2, -1,  1,  4,-12,  4,-36, -5,  5),
        ( 10,  4, -9,-14, -1,  2, -2, 12, -9,-27, -7,  0,  1, 11, 12,  2,  4,  3, -1,-21, -1,-14, -6,  3, -2, -2,  4,  2,  0,-31,  1,  8),
        ( -8, -7, -2,  0,  2,  0,  1,  0,  9,  5,  3, -1, -4,  9,-13,  4, -6, -5,-11, 36,  2,  4,  0,  4,  0,  4,  2,-11,  6, -1,  0, -2),
        (-12,  3, -7, -9,-23, -4,  6,  0, -8,127, 10, -8, -3,-46,  2, 20, -2,-48,-15,  4,  2,  5,-14, -4,  5, 18, 11,-32, 17,  1,-48, -6),
        ( 11,  6, -9, -6,  5, -2,  2,  0,-12,  5,-10, -4,  1,  1, 20, 10, -8, 46,  0,-36,  2,  4, -6, -4,  1, -8, 13,-13,  4, -7, -4,  2),
        ( -4,  1,  0,  8,  6,  1, -2,-10, 10,-29,  6,  2,  0,  5,-14,  1, -2, -1, -2, 25,  2,  5, -1,  5, -4,  1,  0,  2,  0, 27, -2, -4),
        ( -5,  5, -1, -2,  9, -3,  1,-18, -1,-13, -4, -6,  1, -2, -3, 10,-12, -4, -4, -3,  4, 10,  2, -2,  2,  0,  6,-18,  6, 44, 55, -5),
        (  7,  0, -4, -6,  8,  0, -1,-11, -3,-27, -8, -2,  4,  9, 11,  5, -9,  5, -4,-38,  3, 10, -5, -9, -1,-14,  5,  0,  1, 31,  5,  0),
        ( -2,-10,  3,  0, -5, -7,  3,  9,  7, 14,  3, -4, -5,  5, -7, -3, -1,  7, -1,-11,  3, -7,  7,  0,  0,  3,  0,  4, -3,  4,  8, -1),
        ( -4, -3, -3,  3, -9, -7,  5, 17, -1,-16,  1, -6,  0,  2, -1, -9,  4,  0,  0, -3,  0, -9, 10, -3, -2,  2, -3,  6,  1, 15,-13, -1),
        (  6,  6,  0,  2, -7, -8,  5, 10, -3, 14, -8, -6,  9,  8,  4, -5,  2,  0, 11,  8,  2, -9, 10, -1, -2,  5, -4,  4, -1, 11,  7, -1),
        ( -6, -9,  3, -6, -2, -6,  4,  0,  6,-11,  7, -6,-10,  5, -8, -6,  4, -5,-12,-11, -2,  1,  3, -2,  0,  1, -2,  6,  0,  0,  1, -4),
        (-12, -1, -7, -7,-16, -7, 10,  0,-10,-18, 10, -9, -4,-30,  3, -9,  9,-60,-19,  2, -7,  3,-31, -8,  4,  4,  3, 24, 14, 10,-60, -7),
        (  6,  5, -2,  9, -5, -8,  7,  0, -9,-17,-13, -8,  8, -4, 13, -9, -8, 53,  6, 21, -1,  1, -1, -5,  0, -6, 10,  8, -2,  2,-10, -4),
        ( -1,  4,  4, -3, -1, -7,  6, -9,  8, 16, 10, -3, -7,  8, -7, -4,  4,  9,  4,-10, -2,  5,  3,  0,  0,  4,  0,  5, -3, -9, -3, -3),
        ( -4,  6,  2, -6,  4, -7,  9,-17, -2,-27, -5, -9, -2, -5,  0,-11, -8, -3,  2, -2, -5,  9, -9, -6,  3, -5, -1,  9,  2,-14, 65, -3),
        (  6,  5,  4,  3, -3, -8,  8,-11,  0, 10,-10, -6,  8,  3,  6, -8,-12,  4,  6, 10, -1,  7,  3, -7,  0, -7, -3,  4, -4,-15,  4, -3),
        (  0, -8,  2,  4,  0,  5, -2,  6,  3, 14,  3,  3, -5,-12, -2,  3, -6,  3, -7,-20,  0, -6,  4,  3, -2, -1, -2, -4, -4, 14,  2,  1),
        ( -2, -7,  1,  7, -3,  8, -6, 12,  0, -6,  1,  9,  1, -1, -1,  0,  2,  0, -1, -7,  0, -7, 17,  2,  0, -4, -7,  0, -2, 28,  1,  1),
        (  0, -5,  4,  3, -1,  5, -4,  7, -1, 16, -8,  4,  9,-14, -1,  4, -2, -2, 10, 12,  2, -6,  9,  3, -4,  2,  2, -5, -5, 22,  3,  0),
        ( -3, -8,  1, -1,  3,  7, -5,  0,  3, -4,  7,  6,-10, -4, -2, -1,  3,  3,-13,-26, -4, -2,  3,  1,  1, -6, -4,  0,  2, -1,  2,  2),
        ( -5, -6, -1, -6, -7, 13,-12,  0, -6,-54, 14, 19, -2, 16,  2, -4, 13,-12,-14, -1, -5,  0,-18, -2, 13, -7,  2, 23, 17,  5,-21,  0),
        (  3, -3,  5,  9,  1, 10, -9,  0, -5, -5, -8, 12,  8, -6,  5, -2, -7, 12, 10, 31, -2,  0,  3,  0,  3, -8, 25,  3, -6,  4, -5,  0),
        ( -1, -1, -1, -2,  3,  6, -4, -6,  3, 14, 10,  2, -9,-11, -2,  4,  7,  4,  2,-12, -4,  4, -4,  3,  1, -4, -4, -6, -2,-17, -3,  2),
        ( -2, -2,  2,-11,  5, 10,-11,-12, -3,  2, -1, 12, -3,  2,  1, -1, -1, -3,  3,  5, -5,  8,-10, -1, 13,-12,-11,  6,  5,-32, 21,  3),
        (  5, -3,  5, -3,  3,  8, -8, -7, -2, 20, -7,  8,  7,-12,  2,  3,-11,  1, 10, 24, -3,  7,  2, -2,  5, -8, -1, -4, -8,-21,  1,  2)
    );

    -- Expected acc_out[0..31] (validado contra ONNX layer_005 pixel(200,200))
    constant expected : exp_t := (
        1750, -7457, 1481, -1701, -537, 3179,  35, 1992,
        2443, -8162,-3019,  589, 2227,  316, 589,-1407,
       -5361, 17484,-1748, 3940,-1184,-2026,1345, -213,
       -4697, -7156,-5384, 5474,-8449, 227, 6471,   84
    );

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.mac_array
        port map (
            clk => clk, rst_n => rst_n,
            a_in => a_in, b_in => b_in, bias_in => bias_in,
            valid_in => valid_in, load_bias => load_bias, clear => clear,
            acc_out => acc_out, valid_out => valid_out
        );

    stim : process
        variable errors : integer := 0;
        variable got    : integer;
    begin
        -- Reset
        rst_n <= '0';
        valid_in <= '0'; load_bias <= '0'; clear <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- ============================================================
        -- 1. CLEAR todos los acumuladores
        -- ============================================================
        report "=== CLEAR ===" severity note;
        clear <= '1';
        wait until rising_edge(clk);
        clear <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- ============================================================
        -- 2. LOAD BIAS (32 valores)
        -- ============================================================
        report "=== LOAD BIAS ===" severity note;
        for i in 0 to 31 loop
            bias_in(i) <= to_signed(biases(i), 32);
        end loop;
        load_bias <= '1';
        wait until rising_edge(clk);
        load_bias <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- ============================================================
        -- 3. 27 MAC STEPS (a_in broadcast, 32 b_in distintos por step)
        -- ============================================================
        report "=== 27 MAC STEPS ===" severity note;
        for step in 0 to 26 loop
            a_in <= to_signed(a_vals(step), 9);
            for i in 0 to 31 loop
                b_in(i) <= to_signed(weights(step)(i), 8);
            end loop;
            valid_in <= '1';
            wait until rising_edge(clk);
        end loop;
        valid_in <= '0';

        -- Drain pipeline (mac_unit tiene 2 etapas)
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- ============================================================
        -- 4. VERIFICAR los 32 acumuladores
        -- ============================================================
        report "=== VERIFICAR ===" severity note;
        for ch in 0 to 31 loop
            got := to_integer(acc_out(ch));
            if got /= expected(ch) then
                errors := errors + 1;
                report "ch=" & integer'image(ch) &
                       " FAIL got=" & integer'image(got) &
                       " exp=" & integer'image(expected(ch)) severity error;
            else
                report "ch=" & integer'image(ch) & " OK acc=" & integer'image(got) severity note;
            end if;
        end loop;

        wait for CLK_PERIOD * 5;
        report "==============================" severity note;
        if errors = 0 then
            report "ALL 32 CHANNELS PASSED" severity note;
        else
            report "FAILED: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==============================" severity note;
        wait;
    end process;

end;
