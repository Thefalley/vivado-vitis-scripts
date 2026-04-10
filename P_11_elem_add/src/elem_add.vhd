-------------------------------------------------------------------------------
-- elem_add.vhd — QLinearAdd INT8 (pipeline 8 etapas)
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Suma dos activaciones INT8 con escalas diferentes.
--   Cada entrada tiene su propia escala (zero point, M0).
--   Las dos entradas se reescalan a un dominio comun, se suman,
--   y el resultado se requantiza a INT8.
--
-- FORMULA:
--   a_shifted = a_in - a_zp          (int9)
--   b_shifted = b_in - b_zp          (int9)
--   temp_a = a_shifted * M0_a        (int40, via mul_s9xu30_pipe)
--   temp_b = b_shifted * M0_b        (int40, via mul_s9xu30_pipe)
--   combined = temp_a + temp_b       (int64, la suma real)
--   rounded = combined + 2^(n-1)     (int64, redondeo)
--   shifted = rounded >> n           (int32)
--   y = clamp(shifted + y_zp, -128, 127)
--
-- COMO LO HACE (8 etapas de pipeline):
--
--   ETAPA 1 (ciclo N):
--     a_shifted = a_in - a_zp, b_shifted = b_in - b_zp (9 bits cada uno)
--
--   ETAPAS 2-4 (ciclos N+1..N+3):
--     temp_a = a_shifted × M0_a (via mul_s9xu30_pipe, 2 DSPs)
--     temp_b = b_shifted × M0_b (via mul_s9xu30_pipe, 2 DSPs)
--     En paralelo, 3 ciclos.
--
--   ETAPA 5 (ciclo N+4):
--     combined = temp_a + temp_b (int64, sign-extend de 40 bits)
--
--   ETAPA 6 (ciclo N+5):
--     rounded = combined + 2^(n_shift - 1) (int64)
--
--   ETAPA 7 (ciclo N+6):
--     shifted = rounded >> n_shift (barrel shifter 64 bits)
--
--   ETAPA 8 (ciclo N+7):
--     y = shifted + y_zp, saturar a [-128, 127]
--
-- LATENCIA: 8 ciclos desde valid_in hasta valid_out.
-- THROUGHPUT: 1 resultado por ciclo (pipeline).
--
-- RECURSOS:
--   DSP48E1: 4 (2 por mul_s9xu30_pipe × 2 ramas)
--   LUTs: ~500 (1 barrel shifter + sumas + logica + 2×~30 multiplicadores)
--   FFs: ~600 (registros de pipeline + 2×~100 multiplicadores)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity elem_add is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- Entradas (dos activaciones)
        a_in      : in  signed(7 downto 0);     -- primera activacion int8
        b_in      : in  signed(7 downto 0);     -- segunda activacion int8
        valid_in  : in  std_logic;

        -- Parametros (constantes durante toda la capa)
        a_zp      : in  signed(7 downto 0);     -- zero point de a
        b_zp      : in  signed(7 downto 0);     -- zero point de b
        y_zp      : in  signed(7 downto 0);     -- zero point de salida
        M0_a      : in  unsigned(31 downto 0);   -- multiplicador de a
        M0_b      : in  unsigned(31 downto 0);   -- multiplicador de b
        n_shift   : in  unsigned(5 downto 0);    -- shift comun (n = min(n_a, n_b))

        -- Salida
        y_out     : out signed(7 downto 0);      -- resultado int8
        valid_out : out std_logic
    );
end entity elem_add;

architecture rtl of elem_add is

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
    -- ETAPA 1: registros de resta de zero points
    ---------------------------------------------------------------------------
    signal s1_a_sh  : signed(8 downto 0);    -- a_in - a_zp (9 bits reales)
    signal s1_b_sh  : signed(8 downto 0);    -- b_in - b_zp (9 bits reales)
    signal s1_n     : unsigned(5 downto 0);
    signal s1_yzp   : signed(7 downto 0);
    signal s1_valid : std_logic;

    ---------------------------------------------------------------------------
    -- Salidas de los multiplicadores (signed 40 bits, 3 ciclos despues de E1)
    ---------------------------------------------------------------------------
    signal mult_a_raw : signed(39 downto 0);
    signal mult_b_raw : signed(39 downto 0);

    ---------------------------------------------------------------------------
    -- Pipeline de parametros a traves del multiplicador (3 etapas)
    ---------------------------------------------------------------------------
    type pipe_u6_array is array(0 to 2) of unsigned(5 downto 0);
    type pipe_s8_array is array(0 to 2) of signed(7 downto 0);

    signal mp_n     : pipe_u6_array;
    signal mp_yzp   : pipe_s8_array;
    signal mp_valid : std_logic_vector(2 downto 0);

    ---------------------------------------------------------------------------
    -- ETAPA 5: registro de suma
    ---------------------------------------------------------------------------
    signal s5_combined : signed(63 downto 0);
    signal s5_n        : unsigned(5 downto 0);
    signal s5_yzp      : signed(7 downto 0);
    signal s5_valid    : std_logic;

    ---------------------------------------------------------------------------
    -- ETAPA 6: registro de redondeo
    ---------------------------------------------------------------------------
    signal s6_rounded : signed(63 downto 0);
    signal s6_n       : unsigned(5 downto 0);
    signal s6_yzp     : signed(7 downto 0);
    signal s6_valid   : std_logic;

    ---------------------------------------------------------------------------
    -- ETAPA 7: registro de shift
    ---------------------------------------------------------------------------
    signal s7_shifted : signed(31 downto 0);
    signal s7_yzp     : signed(7 downto 0);
    signal s7_valid   : std_logic;

begin

    ---------------------------------------------------------------------------
    -- ETAPA 1: RESTAR ZERO POINTS
    ---------------------------------------------------------------------------
    p_etapa1 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s1_a_sh  <= (others => '0');
            s1_b_sh  <= (others => '0');
            s1_n     <= (others => '0');
            s1_yzp   <= (others => '0');
            s1_valid <= '0';
        else
            -- Resta: int8 - int8 = int9. resize de 8 a 9 bits.
            s1_a_sh <= resize(a_in, 9) - resize(a_zp, 9);
            s1_b_sh <= resize(b_in, 9) - resize(b_zp, 9);

            s1_n     <= n_shift;
            s1_yzp   <= y_zp;
            s1_valid <= valid_in;
        end if;
        end if;
    end process p_etapa1;

    ---------------------------------------------------------------------------
    -- ASSERT: verificar que M0 cabe en 30 bits (bits 31:30 deben ser 0)
    -- Solo activo en simulacion, Vivado lo ignora en sintesis.
    ---------------------------------------------------------------------------
    -- synthesis translate_off
    p_assert_m0 : process(M0_a, M0_b)
    begin
        assert M0_a(31 downto 30) = "00"
            report "elem_add: M0_a bits 31:30 != 00, valor excede 30 bits unsigned. " &
                   "M0 debe ser < 2^30."
            severity error;
        assert M0_b(31 downto 30) = "00"
            report "elem_add: M0_b bits 31:30 != 00, valor excede 30 bits unsigned. " &
                   "M0 debe ser < 2^30."
            severity error;
    end process p_assert_m0;
    -- synthesis translate_on

    ---------------------------------------------------------------------------
    -- ETAPAS 2-4: MULTIPLICACION (2× mul_s9xu30_pipe, 3 ciclos)
    --
    -- M0 en puerto es unsigned(31:0), pasamos los 30 bits bajos (bits 31:30 = 0).
    -- 2 instancias en paralelo = 4 DSP48E1 total.
    ---------------------------------------------------------------------------
    u_mult_a : entity work.mul_s9xu30_pipe
        port map (
            clk => clk,
            a   => s1_a_sh,
            b   => M0_a(29 downto 0),
            p   => mult_a_raw
        );

    u_mult_b : entity work.mul_s9xu30_pipe
        port map (
            clk => clk,
            a   => s1_b_sh,
            b   => M0_b(29 downto 0),
            p   => mult_b_raw
        );

    ---------------------------------------------------------------------------
    -- PIPELINE DE PARAMETROS (3 etapas, alineado con multiplicador)
    ---------------------------------------------------------------------------
    p_mult_pipe : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            mp_n     <= (others => (others => '0'));
            mp_yzp   <= (others => (others => '0'));
            mp_valid <= (others => '0');
        else
            mp_n(0)     <= s1_n;
            mp_yzp(0)   <= s1_yzp;
            mp_valid(0) <= s1_valid;
            for i in 1 to 2 loop
                mp_n(i)     <= mp_n(i-1);
                mp_yzp(i)   <= mp_yzp(i-1);
                mp_valid(i) <= mp_valid(i-1);
            end loop;
        end if;
        end if;
    end process p_mult_pipe;

    ---------------------------------------------------------------------------
    -- ETAPA 5: SUMAR LAS DOS RAMAS
    --
    -- Sign-extend mult resultados de 40 a 64 bits, luego sumar.
    ---------------------------------------------------------------------------
    p_etapa5 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s5_combined <= (others => '0');
            s5_n        <= (others => '0');
            s5_yzp      <= (others => '0');
            s5_valid    <= '0';
        else
            s5_combined <= resize(mult_a_raw, 64) + resize(mult_b_raw, 64);

            s5_n     <= mp_n(2);
            s5_yzp   <= mp_yzp(2);
            s5_valid <= mp_valid(2);
        end if;
        end if;
    end process p_etapa5;

    ---------------------------------------------------------------------------
    -- ETAPA 6: REDONDEO
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
            s6_rounded <= s5_combined + make_round_val(s5_n);
            s6_n       <= s5_n;
            s6_yzp     <= s5_yzp;
            s6_valid   <= s5_valid;
        end if;
        end if;
    end process p_etapa6;

    ---------------------------------------------------------------------------
    -- ETAPA 7: SHIFT ARITMETICO
    ---------------------------------------------------------------------------
    p_etapa7 : process(clk)
        variable shifted_full : signed(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s7_shifted <= (others => '0');
            s7_yzp     <= (others => '0');
            s7_valid   <= '0';
        else
            shifted_full := shift_right(s6_rounded, to_integer(s6_n));
            s7_shifted   <= shifted_full(31 downto 0);
            s7_yzp       <= s6_yzp;
            s7_valid     <= s6_valid;
        end if;
        end if;
    end process p_etapa7;

    ---------------------------------------------------------------------------
    -- ETAPA 8: SUMAR Y_ZP + SATURAR A INT8
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
