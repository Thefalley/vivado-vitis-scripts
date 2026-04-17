-------------------------------------------------------------------------------
-- requantize.vhd — Requantizacion INT32 → INT8 (pipeline 8 etapas)
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Convierte el acumulador int32 de la convolucion en un valor int8.
--   Es la operacion "multiply_shift" que usamos en Python y C.
--
-- FORMULA:
--   resultado = clamp( ((acc * M0) + 2^(n-1)) >> n  +  y_zp,  -128, 127 )
--
-- COMO LO HACE (8 etapas de pipeline):
--
--   ETAPAS 1-5 (ciclos N..N+4):
--     mult_result = acc × M0
--     Usa el multiplicador verificado mul_s32x32_pipe (4 DSP48E1).
--     acc es signed 32 bits, M0 es unsigned 30 bits (reinterpretado
--     como signed 32 bits — seguro porque M0 < 2^31, bit 31 siempre 0).
--     El multiplicador parte 32×32 en 4 productos parciales de 18 bits
--     y los suma por zonas con carry explicito en 5 etapas.
--     VERIFICADO EN HARDWARE: 1,025,696 tests, 0 errores.
--     Timing: WNS = +1.989 ns @ 100 MHz. Carry chain max: 28 bits.
--
--   ETAPA 6 (ciclo N+5):
--     rounded = mult_result + 2^(n-1)
--     Suma de 64 bits. Sumar "medio bit" para redondear (no truncar).
--
--   ETAPA 7 (ciclo N+6):
--     shifted = rounded >> n
--     Shift aritmetico a la derecha de n posiciones (barrel shifter 64b).
--     Resultado: ~22 bits utiles (en contenedor de 32).
--
--   ETAPA 8 (ciclo N+7):
--     result = shifted + y_zp
--     Saturar a [-128, 127]
--     Salida: int8
--
-- LATENCIA: 8 ciclos desde valid_in hasta valid_out.
-- THROUGHPUT: 1 resultado por ciclo (pipeline).
--
-- ANCHOS:
--   acc_in:      signed 32 bits (acumulador de la conv)
--   M0:          unsigned 32 bits (max ~2^30, bit 31 siempre 0)
--   n_shift:     unsigned 6 bits (rango 0..63, tipicamente 37-40)
--   y_zp:        signed 8 bits (zero point de salida)
--   mult_result: signed 64 bits (acc × M0, del multiplicador pipeline)
--   rounded:     signed 64 bits (mult + redondeo)
--   shifted:     signed 32 bits (tras shift, ~22 bits utiles)
--   y_out:       signed 8 bits (resultado final)
--
-- RECURSOS:
--   DSP48E1: 4 (del mul_s32x32_pipe)
--   LUTs: ~400 (barrel shifter 64b) + 77 (multiplicador) = ~480
--   FFs: ~300 (pipeline) + 166 (multiplicador) = ~470
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity requantize is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- Entrada
        acc_in    : in  signed(31 downto 0);    -- acumulador de la conv
        valid_in  : in  std_logic;

        -- Parametros (constantes durante toda la capa)
        M0        : in  unsigned(31 downto 0);  -- multiplicador (~2^30)
        n_shift   : in  unsigned(5 downto 0);   -- bits a desplazar (37-40)
        y_zp      : in  signed(7 downto 0);     -- zero point salida

        -- Salida
        y_out     : out signed(7 downto 0);     -- resultado int8
        valid_out : out std_logic
    );
end entity requantize;

architecture rtl of requantize is

    ---------------------------------------------------------------------------
    -- Funcion auxiliar: genera el valor de redondeo 2^(n-1)
    ---------------------------------------------------------------------------
    function make_round_val(n : unsigned(5 downto 0)) return signed is
        variable result : signed(63 downto 0) := (others => '0');
        variable pos    : natural;
    begin
        if unsigned(n) > 0 then
            pos := to_integer(n) - 1;
            result(pos) := '1';
        end if;
        return result;
    end function;

    ---------------------------------------------------------------------------
    -- Conversion de M0: unsigned(32) → signed(32)
    -- Seguro porque M0 < 2^31 siempre (max ~2^30 en nuestro modelo).
    -- El bit 31 es siempre 0, asi que signed y unsigned son lo mismo.
    ---------------------------------------------------------------------------
    signal m0_as_signed : signed(31 downto 0);

    ---------------------------------------------------------------------------
    -- Salida del multiplicador pipeline (5 etapas internas)
    -- Llega 5 ciclos despues de que acc_in y M0 estan en los puertos.
    ---------------------------------------------------------------------------
    signal mult_result : signed(63 downto 0);

    ---------------------------------------------------------------------------
    -- Pipeline de parametros: retardar n_shift, y_zp, valid_in por 5 ciclos
    -- para que lleguen alineados con la salida del multiplicador.
    --
    -- mp_n(0) se carga en ciclo 0, mp_n(4) sale en ciclo 5.
    -- Asi mp_n(4) esta sincronizado con mult_result.
    ---------------------------------------------------------------------------
    type pipe_n_array   is array(0 to 4) of unsigned(5 downto 0);
    type pipe_yzp_array is array(0 to 4) of signed(7 downto 0);

    signal mp_n     : pipe_n_array;
    signal mp_yzp   : pipe_yzp_array;
    signal mp_valid : std_logic_vector(4 downto 0);

    ---------------------------------------------------------------------------
    -- ETAPA 6: registros de redondeo
    ---------------------------------------------------------------------------
    signal s6_rounded : signed(63 downto 0);
    signal s6_n       : unsigned(5 downto 0);
    signal s6_yzp     : signed(7 downto 0);
    signal s6_valid   : std_logic;

    ---------------------------------------------------------------------------
    -- ETAPA 7: registros de shift
    ---------------------------------------------------------------------------
    signal s7_shifted : signed(31 downto 0);
    signal s7_yzp     : signed(7 downto 0);
    signal s7_valid   : std_logic;

begin

    ---------------------------------------------------------------------------
    -- CONVERSION DE M0
    --
    -- M0 es unsigned(32) en el puerto, pero el multiplicador necesita
    -- signed(32). Como M0 max es ~2^30, el bit 31 siempre es 0.
    -- Reinterpretar los bits: unsigned → std_logic_vector → signed.
    -- El valor numerico no cambia.
    ---------------------------------------------------------------------------
    m0_as_signed <= signed(std_logic_vector(M0));

    ---------------------------------------------------------------------------
    -- ASSERT: verificar que M0 cabe en signed(32) (bit 31 debe ser 0)
    -- Solo activo en simulacion, Vivado lo ignora en sintesis.
    ---------------------------------------------------------------------------
    -- synthesis translate_off
    p_assert_m0 : process(M0)
    begin
        assert M0(31) = '0'
            report "requantize: M0 bit 31 != 0, valor no cabe en signed(32). " &
                   "M0 debe ser < 2^31 (max ~2^30 en nuestro modelo)."
            severity error;
    end process p_assert_m0;
    -- synthesis translate_on

    ---------------------------------------------------------------------------
    -- ETAPAS 1-5: MULTIPLICACION (mul_s32x32_pipe)
    --
    -- Instancia del multiplicador verificado en hardware.
    -- Entrada: acc_in (signed 32) × m0_as_signed (signed 32)
    -- Salida:  mult_result (signed 64), 5 ciclos despues.
    --
    -- Internamente usa 4 DSP48E1 y suma por zonas:
    --   Etapa 1: 4 productos parciales (P1=AL×BL, P2=AL×BH, P3=AH×BL, P4=AH×BH)
    --   Etapa 2: zona baja + primera suma zona media
    --   Etapa 3: segunda suma zona media + carry explicito
    --   Etapa 4: segunda suma zona alta
    --   Etapa 5: tercera suma zona alta + ensamblado final
    --
    -- El multiplicador NO tiene reset (no lo necesita: los primeros
    -- 5 ciclos de basura se ignoran porque mp_valid es '0').
    ---------------------------------------------------------------------------
    u_mult : entity work.mul_s32x32_pipe
        port map (
            clk => clk,
            a   => acc_in,
            b   => m0_as_signed,
            p   => mult_result
        );

    ---------------------------------------------------------------------------
    -- PIPELINE DE PARAMETROS (5 etapas)
    --
    -- Retardar n_shift, y_zp y valid_in por 5 ciclos para que lleguen
    -- al mismo tiempo que mult_result.
    --
    -- Es un shift register: en cada ciclo, todo avanza una posicion.
    --   Ciclo 0: mp_*(0) ← entrada
    --   Ciclo 1: mp_*(1) ← mp_*(0)
    --   ...
    --   Ciclo 4: mp_*(4) ← mp_*(3)   ← esta es la salida alineada
    --
    -- El reset pone todo a cero. Los 5 ciclos despues de reset,
    -- mp_valid(4) = '0', asi que las etapas posteriores no procesan nada.
    ---------------------------------------------------------------------------
    p_param_pipe : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            mp_n     <= (others => (others => '0'));
            mp_yzp   <= (others => (others => '0'));
            mp_valid <= (others => '0');
        else
            -- Entrada del pipeline
            mp_n(0)     <= n_shift;
            mp_yzp(0)   <= y_zp;
            mp_valid(0) <= valid_in;
            -- Shift register: avanzar una posicion por ciclo
            for i in 1 to 4 loop
                mp_n(i)     <= mp_n(i-1);
                mp_yzp(i)   <= mp_yzp(i-1);
                mp_valid(i) <= mp_valid(i-1);
            end loop;
        end if;
        end if;
    end process p_param_pipe;

    ---------------------------------------------------------------------------
    -- ETAPA 6: REDONDEO
    --
    -- rounded = mult_result + 2^(n_shift - 1)
    -- Sumar "medio bit" para que el shift posterior redondee.
    -- 1 suma de 64 bits (~4 ns carry chain).
    --
    -- Lee de: mult_result (salida del multiplicador, ciclo 5)
    --         mp_n(4), mp_yzp(4), mp_valid(4) (pipeline alineado)
    ---------------------------------------------------------------------------
    p_etapa6 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s6_rounded <= (others => '0');
            s6_n       <= (others => '0');
            s6_yzp     <= (others => '0');
            s6_valid   <= '0';
        else
            s6_rounded <= mult_result + make_round_val(mp_n(4));
            s6_n       <= mp_n(4);
            s6_yzp     <= mp_yzp(4);
            s6_valid   <= mp_valid(4);
        end if;
        end if;
    end process p_etapa6;

    ---------------------------------------------------------------------------
    -- ETAPA 7: SHIFT ARITMETICO
    --
    -- shifted = rounded >> n
    -- Barrel shifter de 64 bits con 6 bits de control.
    -- shift_right() de ieee.numeric_std es aritmetico para signed.
    -- Resultado: ~22 bits utiles en contenedor de 32.
    ---------------------------------------------------------------------------
    p_etapa7 : process(clk)
        variable shift_amount : natural;
        variable shifted_full : signed(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s7_shifted <= (others => '0');
            s7_yzp     <= (others => '0');
            s7_valid   <= '0';
        else
            shift_amount := to_integer(s6_n);
            shifted_full := shift_right(s6_rounded, shift_amount);
            s7_shifted   <= shifted_full(31 downto 0);
            s7_yzp       <= s6_yzp;
            s7_valid     <= s6_valid;
        end if;
        end if;
    end process p_etapa7;

    ---------------------------------------------------------------------------
    -- ETAPA 8: SUMAR Y_ZP + SATURAR
    --
    -- with_zp = shifted + y_zp (sign-extend 8 → 32)
    -- Saturar a [-128, 127].
    ---------------------------------------------------------------------------
    p_etapa8 : process(clk)
        variable with_zp : signed(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            y_out     <= (others => '0');
            valid_out <= '0';
        else
            with_zp := s7_shifted + resize(s7_yzp, 32);
            if with_zp > to_signed(127, 32) then
                y_out <= to_signed(127, 8);
            elsif with_zp < to_signed(-128, 32) then
                y_out <= to_signed(-128, 8);
            else
                y_out <= with_zp(7 downto 0);
            end if;
            valid_out <= s7_valid;
        end if;
        end if;
    end process p_etapa8;

end architecture rtl;
