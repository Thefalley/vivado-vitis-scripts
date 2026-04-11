library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac_unit_tb is
end;

architecture bench of mac_unit_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal a_in      : signed(8 downto 0)  := (others => '0');
    signal b_in      : signed(7 downto 0)  := (others => '0');
    signal bias_in   : signed(31 downto 0) := (others => '0');
    signal valid_in  : std_logic := '0';
    signal load_bias : std_logic := '0';
    signal clear     : std_logic := '0';
    signal acc_out   : signed(31 downto 0);
    signal valid_out : std_logic;

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.mac_unit
        port map (
            clk => clk, rst_n => rst_n,
            a_in => a_in, b_in => b_in, bias_in => bias_in,
            valid_in => valid_in, load_bias => load_bias, clear => clear,
            acc_out => acc_out, valid_out => valid_out
        );

    stim : process
        variable expected : integer;
        variable got : integer;
        variable errors : integer := 0;

        procedure do_mac(a : integer; b : integer) is
        begin
            a_in     <= to_signed(a, 9);
            b_in     <= to_signed(b, 8);
            valid_in <= '1';
            wait until rising_edge(clk);
            valid_in <= '0';
            -- Esperar 2 ciclos (pipeline: mult + acc)
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end procedure;

        procedure check(msg : string; exp : integer) is
        begin
            got := to_integer(acc_out);
            if got /= exp then
                errors := errors + 1;
                report msg & " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(exp) severity error;
            else
                report msg & " OK: acc=" & integer'image(got) severity note;
            end if;
        end procedure;

    begin
        -- Reset
        rst_n <= '0';
        valid_in <= '0'; load_bias <= '0'; clear <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- ======== TEST 1: Clear ========
        report "=== TEST 1: Clear ===" severity note;
        clear <= '1';
        wait until rising_edge(clk);
        clear <= '0';
        wait until rising_edge(clk);  -- pipeline
        wait until rising_edge(clk);
        check("Clear", 0);

        -- ======== TEST 2: Load bias ========
        report "=== TEST 2: Load bias = 1623 ===" severity note;
        bias_in   <= to_signed(1623, 32);
        load_bias <= '1';
        wait until rising_edge(clk);
        load_bias <= '0';
        wait until rising_edge(clk);  -- pipeline
        wait until rising_edge(clk);
        check("Bias", 1623);

        -- ======== TEST 3: Single MAC ========
        -- acc = 1623 + 184 * (-4) = 1623 + (-736) = 887
        report "=== TEST 3: MAC 184 * -4 ===" severity note;
        do_mac(184, -4);
        check("MAC1", 1623 + 184 * (-4));  -- 887

        -- ======== TEST 4: Second MAC ========
        -- acc = 887 + 22 * (-3) = 887 + (-66) = 821
        report "=== TEST 4: MAC 22 * -3 ===" severity note;
        do_mac(22, -3);
        check("MAC2", 887 + 22 * (-3));  -- 821

        -- ======== TEST 5: Third MAC ========
        -- acc = 821 + 149 * 10 = 821 + 1490 = 2311
        report "=== TEST 5: MAC 149 * 10 ===" severity note;
        do_mac(149, 10);
        check("MAC3", 821 + 149 * 10);  -- 2311

        -- ======== TEST 6: Clear + bias + full 27-step MAC (filtro 0) ========
        report "=== TEST 6: Full pixel(200,200) filtro 0 ===" severity note;

        -- Clear
        clear <= '1';
        wait until rising_edge(clk);
        clear <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- Load bias 1623
        bias_in   <= to_signed(1623, 32);
        load_bias <= '1';
        wait until rising_edge(clk);
        load_bias <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- 27 MAC steps para filtro 0 (datos reales layer_005 pixel 200,200)
        -- a_in (broadcast), b_in (filtro 0 weights)
        do_mac(184,  -4);  -- step 0
        do_mac( 22,  -3);  -- step 1
        do_mac(149,  10);  -- step 2
        do_mac(178,  -8);  -- step 3
        do_mac( 26, -12);  -- step 4
        do_mac(145,  11);  -- step 5
        do_mac(134,  -4);  -- step 6
        do_mac( 31,  -5);  -- step 7
        do_mac(122,   7);  -- step 8
        do_mac(190,  -2);  -- step 9
        do_mac( 64,  -4);  -- step 10
        do_mac(167,   6);  -- step 11
        do_mac(187,  -6);  -- step 12
        do_mac( 71, -12);  -- step 13
        do_mac(162,   6);  -- step 14
        do_mac(157,  -1);  -- step 15
        do_mac( 86,  -4);  -- step 16
        do_mac(151,   6);  -- step 17
        do_mac(193,   0);  -- step 18
        do_mac( 88,  -2);  -- step 19
        do_mac(172,   0);  -- step 20
        do_mac(198,  -3);  -- step 21
        do_mac( 97,  -5);  -- step 22
        do_mac(161,   3);  -- step 23
        do_mac(167,  -1);  -- step 24
        do_mac(104,  -2);  -- step 25
        do_mac(159,   5);  -- step 26

        -- Expected acc = 1750 (validado contra ONNX)
        check("Full pixel filtro0", 1750);

        -- ======== RESULTADO ========
        wait for CLK_PERIOD * 5;
        report "==============================" severity note;
        if errors = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "FAILED: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==============================" severity note;
        wait;
    end process;

end;
