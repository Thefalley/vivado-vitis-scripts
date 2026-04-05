library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- mult_tb: Testbench para las 3 variantes de multiplicador 32x30
-- Envia los mismos vectores a las 3 y compara contra referencia.

entity mult_tb is
end mult_tb;

architecture sim of mult_tb is

    constant CLK_PERIOD : time := 10 ns;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';

    -- Entradas compartidas
    signal a_in : std_logic_vector(31 downto 0) := (others => '0');
    signal b_in : std_logic_vector(29 downto 0) := (others => '0');

    -- 4 DSP fast (zone split)
    signal vf_in, vf_out, rdyf : std_logic;
    signal rf : std_logic_vector(61 downto 0);

    -- 4 DSP tree
    signal vt_in, vt_out, rdyt : std_logic;
    signal rt : std_logic_vector(61 downto 0);

    -- 4 DSP
    signal v4_in, v4_out, rdy4 : std_logic;
    signal r4 : std_logic_vector(61 downto 0);

    -- 2 DSP
    signal v2_in, v2_out, rdy2 : std_logic;
    signal r2 : std_logic_vector(61 downto 0);

    -- 1 DSP
    signal v1_in, v1_out, rdy1 : std_logic;
    signal r1 : std_logic_vector(61 downto 0);

    -- Contadores de tests
    signal tests_ok   : integer := 0;
    signal tests_fail : integer := 0;

    -- Funcion para convertir slv a string hex (sin to_integer)
    function to_hstring(v : std_logic_vector) return string is
        variable result : string(1 to (v'length + 3) / 4);
        variable tmp    : std_logic_vector(v'length - 1 downto 0) := v;
        variable nibble : std_logic_vector(3 downto 0);
        constant hex_chars : string(1 to 16) := "0123456789ABCDEF";
        variable idx    : integer;
    begin
        for i in result'range loop
            idx := v'length - i * 4;
            if idx >= 0 then
                nibble := tmp(idx + 3 downto idx);
            else
                nibble := (others => '0');
                nibble(3 downto 3 + idx) := tmp(3 + idx downto 0);
            end if;
            result(result'length - i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2;

    -- Instanciar las 5 variantes
    uut_4dsp_fast: entity work.mult_4dsp_fast
        port map (clk, rst, vf_in, a_in, b_in, rdyf, vf_out, rf);

    uut_4dsp_tree: entity work.mult_4dsp_tree
        port map (clk, rst, vt_in, a_in, b_in, rdyt, vt_out, rt);

    uut_4dsp: entity work.mult_4dsp
        port map (clk, rst, v4_in, a_in, b_in, rdy4, v4_out, r4);

    uut_2dsp: entity work.mult_2dsp
        port map (clk, rst, v2_in, a_in, b_in, rdy2, v2_out, r2);

    uut_1dsp: entity work.mult_1dsp
        port map (clk, rst, v1_in, a_in, b_in, rdy1, v1_out, r1);

    stim: process

        variable expected : unsigned(61 downto 0);
        variable exp_slv  : std_logic_vector(61 downto 0);
        variable test_num : integer := 0;
        variable all_match : boolean;

        procedure test_mult(
            a : in unsigned;
            b : in unsigned
        ) is
            variable got_f, got_t, got_4, got_2, got_1 : boolean := false;
            variable ok_f, ok_t, ok_4, ok_2, ok_1     : boolean := false;
        begin
            test_num := test_num + 1;
            expected := resize(a, 32) * resize(b, 30);
            exp_slv  := std_logic_vector(expected);

            a_in <= std_logic_vector(resize(a, 32));
            b_in <= std_logic_vector(resize(b, 30));

            vf_in <= '1';
            vt_in <= '1';
            v4_in <= '1';
            v2_in <= '1';
            v1_in <= '1';
            wait until rising_edge(clk);
            vf_in <= '0';
            vt_in <= '0';
            v4_in <= '0';
            v2_in <= '0';
            v1_in <= '0';

            for i in 0 to 20 loop
                wait until rising_edge(clk);

                if vf_out = '1' and not got_f then
                    got_f := true;
                    ok_f  := (rf = exp_slv);
                    if not ok_f then
                        report "TEST " & integer'image(test_num) &
                               " FAIL 4DSP_FAST" severity error;
                    end if;
                end if;

                if vt_out = '1' and not got_t then
                    got_t := true;
                    ok_t  := (rt = exp_slv);
                    if not ok_t then
                        report "TEST " & integer'image(test_num) &
                               " FAIL 4DSP_TREE" severity error;
                    end if;
                end if;

                if v4_out = '1' and not got_4 then
                    got_4 := true;
                    ok_4  := (r4 = exp_slv);
                    if not ok_4 then
                        report "TEST " & integer'image(test_num) &
                               " FAIL 4DSP" severity error;
                    end if;
                end if;

                if v2_out = '1' and not got_2 then
                    got_2 := true;
                    ok_2  := (r2 = exp_slv);
                    if not ok_2 then
                        report "TEST " & integer'image(test_num) &
                               " FAIL 2DSP" severity error;
                    end if;
                end if;

                if v1_out = '1' and not got_1 then
                    got_1 := true;
                    ok_1  := (r1 = exp_slv);
                    if not ok_1 then
                        report "TEST " & integer'image(test_num) &
                               " FAIL 1DSP" severity error;
                    end if;
                end if;

                exit when got_f and got_t and got_4 and got_2 and got_1;
            end loop;

            all_match := got_f and got_t and got_4 and got_2 and got_1
                     and ok_f and ok_t and ok_4 and ok_2 and ok_1;

            if all_match then
                tests_ok <= tests_ok + 1;
                report "TEST " & integer'image(test_num) & " OK" severity note;
            else
                tests_fail <= tests_fail + 1;
                if not (got_f and got_t and got_4 and got_2 and got_1) then
                    report "TEST " & integer'image(test_num) & " TIMEOUT" severity error;
                end if;
            end if;

            -- Esperar a que los modulos secuenciales esten ready
            for i in 0 to 10 loop
                exit when rdy2 = '1' and rdy1 = '1';
                wait until rising_edge(clk);
            end loop;
            wait until rising_edge(clk);

        end procedure;

    begin
        rst <= '1';
        vf_in <= '0'; vt_in <= '0'; v4_in <= '0'; v2_in <= '0'; v1_in <= '0';
        wait for CLK_PERIOD * 5;
        rst <= '0';
        wait for CLK_PERIOD * 2;

        -- Test 1: 0 x 0
        test_mult(to_unsigned(0, 32), to_unsigned(0, 30));

        -- Test 2: 1 x 1
        test_mult(to_unsigned(1, 32), to_unsigned(1, 30));

        -- Test 3: 1000 x 500
        test_mult(to_unsigned(1000, 32), to_unsigned(500, 30));

        -- Test 4: max 18-bit x max 18-bit (solo parte baja)
        test_mult(to_unsigned(262143, 32), to_unsigned(262143, 30));

        -- Test 5: potencia de 2 (2^18 x 2^18 = 2^36)
        test_mult(to_unsigned(262144, 32), to_unsigned(262144, 30));

        -- Test 6: solo parte alta
        test_mult(unsigned'(x"FFFC0000"), unsigned'("11" & x"FC00000"));

        -- Test 7: patron alternante
        test_mult(unsigned'(x"AAAAAAAA"), unsigned'("10" & x"AAAAAAA"));

        -- Test 8: A grande x B=1
        test_mult(unsigned'(x"FFFFFFFF"), to_unsigned(1, 30));

        -- Test 9: A=1 x B grande
        test_mult(to_unsigned(1, 32), unsigned'("11" & x"FFFFFFF"));

        -- Test 10: casi maximo
        test_mult(unsigned'(x"FFFFFFFE"), unsigned'("11" & x"FFFFFFE"));

        -- Test 11: maximo x maximo
        test_mult(unsigned'(x"FFFFFFFF"), unsigned'("11" & x"FFFFFFF"));

        -- Test 12: carry entre partes baja y alta
        test_mult(unsigned'(x"0003FFFF"), to_unsigned(262144, 30));

        -- Resultado final
        wait for CLK_PERIOD * 5;
        report "============================================" severity note;
        report "TESTS OK:   " & integer'image(tests_ok) severity note;
        report "TESTS FAIL: " & integer'image(tests_fail) severity note;
        report "============================================" severity note;

        if tests_fail = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity failure;
        end if;

        wait;
    end process;

end sim;
