library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

-- Test exhaustivo del conv_engine con valores EXTREMOS
-- Estresa todos los rangos para verificar:
--   1. Sign extension correcta
--   2. Sin overflow en mac_a, product, acc
--   3. Sign-correct en multiplicacion
--   4. Saturate correcto en requantize (clamp -128/127)
--   5. Bias signed funciona
--
-- Compara contra Python (simulado en VHDL como referencia bit-exacta).

entity conv_engine_extreme_tb is
end;

architecture bench of conv_engine_extreme_tb is
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

    -- Puertos debug (no usados pero necesarios para conectar)
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
    constant ADDR_WEIGHTS : natural := 16#400#;
    constant ADDR_BIAS    : natural := 16#800#;
    constant ADDR_OUTPUT  : natural := 16#C00#;

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

        -- Funcion de referencia: simula exactamente lo que conv_engine debe hacer
        type img_arr is array(0 to 26) of integer;
        type wt_arr  is array(0 to 31, 0 to 26) of integer;
        type bias_arr is array(0 to 31) of integer;
        type exp_arr  is array(0 to 31) of integer;

        function ref_conv(
            img : img_arr;
            w   : wt_arr;
            b   : bias_arr;
            x_zp : integer;
            M0   : integer;
            n_sh : integer;
            y_zp : integer;
            oh, ow, oc : integer
        ) return integer is
            variable acc : integer := b(oc);
            variable step : integer := 0;
            variable ih, iw, x : integer;
            variable val_64, round_val : integer;
            variable shifted, with_zp, y : integer;
        begin
            for kh in 0 to 2 loop
                for kw in 0 to 2 loop
                    for ic in 0 to 2 loop
                        ih := oh + kh - 1;
                        iw := ow + kw - 1;
                        if ih >= 0 and ih < 3 and iw >= 0 and iw < 3 then
                            x := img(ic*9 + ih*3 + iw) - x_zp;
                        else
                            x := 0;
                        end if;
                        acc := acc + x * w(oc, step);
                        step := step + 1;
                    end loop;
                end loop;
            end loop;

            -- Requantize: ((acc * M0 + 2^(n-1)) >> n) + y_zp, clamp(-128, 127)
            -- Usamos integer (32 bits) - puede haber overflow para acc*M0
            -- Para test rapido: simplificacion (asume rango razonable)
            -- En la vida real seria int64
            -- Por seguridad usamos division, no shift
            round_val := 0;
            if n_sh > 0 then
                round_val := 2**(n_sh - 1);
            end if;

            -- Shift derecho (signed) sin overflow:
            -- Hacemos division entera por 2^n_sh aprox.
            -- Nota: integer puede no tener suficientes bits, usamos un numero
            -- pequeño en M0/n_sh para evitar overflow.
            shifted := (acc * M0 + round_val) / (2**n_sh);
            with_zp := shifted + y_zp;
            if with_zp > 127 then
                y := 127;
            elsif with_zp < -128 then
                y := -128;
            else
                y := with_zp;
            end if;
            return y;
        end function;

        -- Datos de TEST EXTREMO
        variable img : img_arr;
        variable wt  : wt_arr;
        variable bias_v : bias_arr;
        variable expected : exp_arr;
        variable got : integer;

        -- Configuracion del test
        constant T_X_ZP   : integer := -128;
        constant T_M0     : integer := 256;
        constant T_N_SHIFT : integer := 18;
        constant T_Y_ZP   : integer := -17;

        -- Expected calculados con Python (precision infinita)
        -- para este conjunto especifico de img/wt/bias/M0/n_shift/y_zp
        constant py_expected : exp_arr := (
            127,-128,127,-18,-19,-108,-126,-96,-99,-114,-86,-89,
            -102,-77,-79,-90,-67,-70,-78,-57,-60,-66,-48,-50,-54,
            -38,-41,-43,-28,-31,-31,-19
        );

        variable errors  : integer := 0;
        variable timeout : integer;

    begin
        report "==============================================" severity note;
        report "TEST EXTREMO: valores limite +/- 127" severity note;
        report "==============================================" severity note;

        -- ============================================================
        -- TEST CASE: pixels y pesos en valores extremos
        -- Imagen 3x3x3 con valores +/- 127 alternados
        -- ============================================================
        img := ( 127,-128, 127,
                -128, 127,-128,
                 127,-128, 127,
                -127, 126,-127,
                 126,-127, 126,
                -127, 126,-127,
                 100,-100,  50,
                 -50,  75,-75 ,
                  25, -25,   0);

        -- Pesos extremos: 32 filtros con patrones distintos
        for oc in 0 to 31 loop
            for k in 0 to 26 loop
                if oc = 0 then
                    -- todo +127
                    wt(oc, k) := 127;
                elsif oc = 1 then
                    -- todo -128
                    wt(oc, k) := -128;
                elsif oc = 2 then
                    -- alternante
                    if (k mod 2) = 0 then
                        wt(oc, k) := 127;
                    else
                        wt(oc, k) := -128;
                    end if;
                elsif oc = 3 then
                    -- ceros
                    wt(oc, k) := 0;
                elsif oc = 4 then
                    -- ramp
                    wt(oc, k) := k - 13;  -- de -13 a 13
                else
                    -- mezcla
                    if ((oc + k) mod 3) = 0 then
                        wt(oc, k) := -100 + (oc * 3);
                    elsif ((oc + k) mod 3) = 1 then
                        wt(oc, k) := 50 - oc;
                    else
                        wt(oc, k) := -50 + oc;
                    end if;
                end if;
            end loop;
        end loop;

        -- Bias: extremos
        for oc in 0 to 31 loop
            if oc = 0 then
                bias_v(oc) := 1000000;   -- bias grande positivo
            elsif oc = 1 then
                bias_v(oc) := -1000000;  -- bias grande negativo
            elsif oc = 2 then
                bias_v(oc) := 0;
            else
                bias_v(oc) := (oc - 16) * 100;  -- variado
            end if;
        end loop;

        -- ============================================================
        -- Cargar DDR
        -- ============================================================
        for i in 0 to 26 loop
            ddr_w8(ADDR_INPUT + i, img(i));
        end loop;
        for oc in 0 to 31 loop
            for k in 0 to 26 loop
                ddr_w8(ADDR_WEIGHTS + oc*27 + k, wt(oc, k));
            end loop;
        end loop;
        for oc in 0 to 31 loop
            ddr_w32(ADDR_BIAS + oc*4, bias_v(oc));
        end loop;

        report "DDR cargada con valores extremos" severity note;

        -- ============================================================
        -- Usar expected pre-calculados con Python (mas seguros que la
        -- funcion ref_conv que puede overflowear con integer 32 bits)
        -- ============================================================
        expected := py_expected;

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
        cfg_x_zp        <= to_signed(T_X_ZP, 9);
        cfg_w_zp        <= to_signed(0, 8);
        cfg_M0          <= to_unsigned(T_M0, 32);
        cfg_n_shift     <= to_unsigned(T_N_SHIFT, 6);
        cfg_y_zp        <= to_signed(T_Y_ZP, 8);
        cfg_addr_input  <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights<= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias   <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output <= to_unsigned(ADDR_OUTPUT, 25);
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- START
        report "STARTING extreme test" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Loop esperando done + servir DDR
        timeout := 0;
        while done /= '1' and timeout < 200000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(11 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 200000 then
            report "TIMEOUT" severity failure;
        end if;

        for i in 0 to 4 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -- Verificar pixel(1,1) de los 32 canales
        report "==============================================" severity note;
        report "VERIFICANDO 32 CANALES (extreme test)" severity note;
        report "==============================================" severity note;
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
            report "ALL 32 CHANNELS PASSED (extreme test)" severity note;
        else
            report "FAILED: " & integer'image(errors) & " errors (extreme test)" severity error;
        end if;
        report "==============================================" severity note;

        wait;
    end process;

end;
