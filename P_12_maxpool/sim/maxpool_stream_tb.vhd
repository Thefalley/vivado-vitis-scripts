library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity maxpool_stream_tb is
end;

architecture bench of maxpool_stream_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal resetn        : std_logic := '0';
    signal s_axis_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tlast  : std_logic := '0';
    signal m_axis_tdata  : std_logic_vector(31 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';
    signal m_axis_tlast  : std_logic;

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.maxpool_stream
        port map (
            clk => clk, resetn => resetn,
            s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready, s_axis_tlast => s_axis_tlast,
            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast
        );

    stim : process
        -- Envia 1 word por stream (espera tready)
        procedure send(data : std_logic_vector(31 downto 0); last : std_logic := '0') is
        begin
            s_axis_tdata  <= data;
            s_axis_tvalid <= '1';
            s_axis_tlast  <= last;
            wait until rising_edge(clk) and s_axis_tready = '1';
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end procedure;

        -- Envia int8 como dato normal
        procedure send_val(v : integer) is
        begin
            send(std_logic_vector(to_unsigned(v mod 256, 32)));
        end procedure;

        -- Envia clear command (bit 8 = 1)
        procedure send_clear is
        begin
            send(x"00000100");
        end procedure;

        -- Envia read command (bit 9 = 1), con tlast opcional
        procedure send_read(last : std_logic := '0') is
        begin
            send(x"00000200", last);
        end procedure;

        variable got : signed(7 downto 0);

        -- Pixel 0 del test: oh=0, ow=0
        -- Ventana 5x5 con padding (-128), max esperado = -80
        type win_t is array(0 to 24) of integer;
        constant win0 : win_t := (
            -128,-128,-128,-128,-128,
            -128,-128,-128,-128,-128,
            -128,-128, -89, -80, -93,
            -128,-128,-109,-119,-117,
            -128,-128,-115,-118,-119
        );
        constant expected0 : integer := -80;

        -- Pixel 1: oh=0, ow=1, max = -80
        constant win1 : win_t := (
            -128,-128,-128,-128,-128,
            -128,-128,-128,-128,-128,
            -128, -89, -80, -93,-106,
            -128,-109,-119,-117,-118,
            -128,-115,-118,-119,-119
        );
        constant expected1 : integer := -80;

        -- Pixel simple: todos positivos, max = 127
        constant win2 : win_t := (
              10,  20,  30,  40,  50,
              60,  70,  80,  90, 100,
             110, 120, 127, 126, 125,
               1,   2,   3,   4,   5,
              -1,  -2,  -3,  -4,  -5
        );
        constant expected2 : integer := 127;

    begin
        -- Reset
        resetn <= '0';
        wait for CLK_PERIOD * 5;
        resetn <= '1';
        wait for CLK_PERIOD * 2;

        -- ========= PIXEL 0 =========
        report "PIXEL 0: sending clear + 25 values + read" severity note;
        send_clear;
        for i in 0 to 24 loop
            send_val(win0(i));
        end loop;
        send_read;

        -- Esperar resultado
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        got := signed(m_axis_tdata(7 downto 0));
        assert got = to_signed(expected0, 8)
            report "PIXEL 0 FAIL: got=" & integer'image(to_integer(got)) &
                   " exp=" & integer'image(expected0) severity error;
        if got = to_signed(expected0, 8) then
            report "PIXEL 0 OK: max=" & integer'image(to_integer(got)) severity note;
        end if;
        wait until rising_edge(clk);

        -- ========= PIXEL 1 =========
        report "PIXEL 1: sending clear + 25 values + read" severity note;
        send_clear;
        for i in 0 to 24 loop
            send_val(win1(i));
        end loop;
        send_read;

        wait until rising_edge(clk) and m_axis_tvalid = '1';
        got := signed(m_axis_tdata(7 downto 0));
        assert got = to_signed(expected1, 8)
            report "PIXEL 1 FAIL: got=" & integer'image(to_integer(got)) &
                   " exp=" & integer'image(expected1) severity error;
        if got = to_signed(expected1, 8) then
            report "PIXEL 1 OK: max=" & integer'image(to_integer(got)) severity note;
        end if;
        wait until rising_edge(clk);

        -- ========= PIXEL 2 (con TLAST) =========
        report "PIXEL 2: sending clear + 25 values + read(tlast)" severity note;
        send_clear;
        for i in 0 to 24 loop
            send_val(win2(i));
        end loop;
        send_read('1');  -- tlast en el read

        wait until rising_edge(clk) and m_axis_tvalid = '1';
        got := signed(m_axis_tdata(7 downto 0));
        assert got = to_signed(expected2, 8)
            report "PIXEL 2 FAIL: got=" & integer'image(to_integer(got)) &
                   " exp=" & integer'image(expected2) severity error;
        if got = to_signed(expected2, 8) then
            report "PIXEL 2 OK: max=" & integer'image(to_integer(got)) severity note;
        end if;

        -- Verificar tlast en output
        assert m_axis_tlast = '1'
            report "PIXEL 2: tlast not asserted on last output!" severity error;

        wait for CLK_PERIOD * 5;
        report "=== ALL PIXELS DONE ===" severity note;
        wait;
    end process;

end;
