-------------------------------------------------------------------------------
-- leaky_relu.vhd — QLinearLeakyRelu INT8 (pipeline 8 etapas)
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Aplica la funcion LeakyRelu cuantizada en INT8.
--   Tiene DOS ramas: una para valores positivos y otra para negativos.
--   Cada rama tiene su propia escala (M0, n_shift) distinta.
--
-- FORMULA:
--   Si x >= x_zp (positivo):
--     y = clamp( ((x_shifted * M0_pos) + 2^(n_pos-1)) >> n_pos + y_zp, -128, 127)
--   Si x <  x_zp (negativo):
--     y = clamp( ((x_shifted * M0_neg) + 2^(n_neg-1)) >> n_neg + y_zp, -128, 127)
--   Donde: x_shifted = x - x_zp (int9, rango -255..255)
--
-- COMO LO HACE (8 etapas de pipeline):
--
--   ETAPA 1 (ciclo N):
--     x_shifted = x_in - x_zp (9 bits reales)
--     is_positive = (x_in >= x_zp)
--     1 resta de 9 bits + 1 comparacion de 8 bits.
--
--   ETAPAS 2-4 (ciclos N+1..N+3):
--     mult_pos = x_shifted × M0_pos (via mul_s9xu30_pipe, 2 DSPs)
--     mult_neg = x_shifted × M0_neg (via mul_s9xu30_pipe, 2 DSPs)
--     Dos multiplicadores en paralelo, 3 ciclos cada uno.
--     Resultado: signed(40 bits), sign-extended a 64 para etapas posteriores.
--
--   ETAPA 5 (ciclo N+4):
--     round_pos = mult_pos + 2^(n_pos - 1)
--     round_neg = mult_neg + 2^(n_neg - 1)
--     2 sumas de 64 bits en paralelo.
--
--   ETAPA 6 (ciclo N+5):
--     val_pos = round_pos >> n_pos, val_neg = round_neg >> n_neg
--     2 barrel shifters de 64 bits en paralelo.
--
--   ETAPA 7 (ciclo N+6):
--     Mux: seleccionar val_pos o val_neg segun is_positive
--     Sumar y_zp (sign-extend 8 → 32 bits)
--
--   ETAPA 8 (ciclo N+7):
--     Saturar a [-128, 127]
--
-- LATENCIA: 8 ciclos desde valid_in hasta valid_out.
-- THROUGHPUT: 1 resultado por ciclo (pipeline).
--
-- RECURSOS:
--   DSP48E1: 4 (2 por mul_s9xu30_pipe × 2 ramas)
--   LUTs: ~860 (2 barrel shifters + sumas + muxes + 2×~30 multiplicadores)
--   FFs: ~800 (registros de pipeline + 2×~100 multiplicadores)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity leaky_relu is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- Entrada
        x_in      : in  signed(7 downto 0);     -- activacion int8
        valid_in  : in  std_logic;

        -- Parametros (constantes durante toda la capa)
        x_zp      : in  signed(7 downto 0);     -- zero point de entrada
        y_zp      : in  signed(7 downto 0);     -- zero point de salida
        M0_pos    : in  unsigned(31 downto 0);   -- multiplicador rama positiva
        n_pos     : in  unsigned(5 downto 0);    -- shift rama positiva
        M0_neg    : in  unsigned(31 downto 0);   -- multiplicador rama negativa
        n_neg     : in  unsigned(5 downto 0);    -- shift rama negativa

        -- Salida
        y_out     : out signed(7 downto 0);      -- resultado int8
        valid_out : out std_logic
    );
end entity leaky_relu;

architecture rtl of leaky_relu is

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
    -- ETAPA 1: registros de resta + deteccion de signo
    ---------------------------------------------------------------------------
    signal s1_shifted : signed(8 downto 0);    -- x_in - x_zp (9 bits reales)
    signal s1_is_pos  : std_logic;             -- '1' si x_in >= x_zp
    signal s1_npos    : unsigned(5 downto 0);
    signal s1_nneg    : unsigned(5 downto 0);
    signal s1_yzp     : signed(7 downto 0);
    signal s1_valid   : std_logic;

    ---------------------------------------------------------------------------
    -- Salidas de los multiplicadores (signed 40 bits, 3 ciclos despues de E1)
    ---------------------------------------------------------------------------
    signal mult_pos_raw : signed(39 downto 0);
    signal mult_neg_raw : signed(39 downto 0);

    ---------------------------------------------------------------------------
    -- Pipeline de parametros a traves del multiplicador (3 etapas)
    -- Para alinear is_pos, npos, nneg, yzp, valid con la salida del mult.
    ---------------------------------------------------------------------------
    type pipe_u6_array  is array(0 to 2) of unsigned(5 downto 0);
    type pipe_s8_array  is array(0 to 2) of signed(7 downto 0);

    signal mp_is_pos : std_logic_vector(2 downto 0);
    signal mp_npos   : pipe_u6_array;
    signal mp_nneg   : pipe_u6_array;
    signal mp_yzp    : pipe_s8_array;
    signal mp_valid  : std_logic_vector(2 downto 0);

    ---------------------------------------------------------------------------
    -- ETAPA 5: registros de redondeo (ambas ramas)
    ---------------------------------------------------------------------------
    signal s5_round_pos : signed(63 downto 0);
    signal s5_round_neg : signed(63 downto 0);
    signal s5_is_pos    : std_logic;
    signal s5_npos      : unsigned(5 downto 0);
    signal s5_nneg      : unsigned(5 downto 0);
    signal s5_yzp       : signed(7 downto 0);
    signal s5_valid     : std_logic;

    ---------------------------------------------------------------------------
    -- ETAPA 6: registros de shift (ambas ramas)
    ---------------------------------------------------------------------------
    signal s6_val_pos : signed(31 downto 0);
    signal s6_val_neg : signed(31 downto 0);
    signal s6_is_pos  : std_logic;
    signal s6_yzp     : signed(7 downto 0);
    signal s6_valid   : std_logic;

    ---------------------------------------------------------------------------
    -- ETAPA 7: registro de mux + y_zp
    ---------------------------------------------------------------------------
    signal s7_with_zp : signed(31 downto 0);
    signal s7_valid   : std_logic;

begin

    ---------------------------------------------------------------------------
    -- ETAPA 1: RESTAR ZERO POINT + DETECTAR SIGNO
    ---------------------------------------------------------------------------
    p_etapa1 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s1_shifted <= (others => '0');
            s1_is_pos  <= '0';
            s1_npos    <= (others => '0');
            s1_nneg    <= (others => '0');
            s1_yzp     <= (others => '0');
            s1_valid   <= '0';
        else
            -- Resta: int8 - int8 = int9. resize de 8 a 9 bits (sign-extend).
            s1_shifted <= resize(x_in, 9) - resize(x_zp, 9);

            -- Detectar signo para el mux de etapa 7
            if x_in >= x_zp then
                s1_is_pos <= '1';
            else
                s1_is_pos <= '0';
            end if;

            s1_npos  <= n_pos;
            s1_nneg  <= n_neg;
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
    p_assert_m0 : process(M0_pos, M0_neg)
    begin
        assert M0_pos(31 downto 30) = "00"
            report "leaky_relu: M0_pos bits 31:30 != 00, valor excede 30 bits unsigned. " &
                   "M0 debe ser < 2^30."
            severity error;
        assert M0_neg(31 downto 30) = "00"
            report "leaky_relu: M0_neg bits 31:30 != 00, valor excede 30 bits unsigned. " &
                   "M0 debe ser < 2^30."
            severity error;
    end process p_assert_m0;
    -- synthesis translate_on

    ---------------------------------------------------------------------------
    -- ETAPAS 2-4: MULTIPLICACION (2× mul_s9xu30_pipe, 3 ciclos)
    --
    -- Rama positiva: s1_shifted(9 signed) × M0_pos(30 unsigned) → 40 signed
    -- Rama negativa: s1_shifted(9 signed) × M0_neg(30 unsigned) → 40 signed
    --
    -- M0 en el puerto es unsigned(31 downto 0) pero max ~2^30,
    -- asi que los bits 31:30 son siempre 0. Pasamos M0(29 downto 0)
    -- al multiplicador.
    --
    -- 2 instancias en paralelo = 4 DSP48E1 total.
    ---------------------------------------------------------------------------
    u_mult_pos : entity work.mul_s9xu30_pipe
        port map (
            clk => clk,
            a   => s1_shifted,
            b   => M0_pos(29 downto 0),
            p   => mult_pos_raw
        );

    u_mult_neg : entity work.mul_s9xu30_pipe
        port map (
            clk => clk,
            a   => s1_shifted,
            b   => M0_neg(29 downto 0),
            p   => mult_neg_raw
        );

    ---------------------------------------------------------------------------
    -- PIPELINE DE PARAMETROS (3 etapas, alineado con multiplicador)
    ---------------------------------------------------------------------------
    p_mult_pipe : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            mp_is_pos <= (others => '0');
            mp_npos   <= (others => (others => '0'));
            mp_nneg   <= (others => (others => '0'));
            mp_yzp    <= (others => (others => '0'));
            mp_valid  <= (others => '0');
        else
            -- Entrada (sincronizado con s1_* que entra al multiplicador)
            mp_is_pos(0) <= s1_is_pos;
            mp_npos(0)   <= s1_npos;
            mp_nneg(0)   <= s1_nneg;
            mp_yzp(0)    <= s1_yzp;
            mp_valid(0)  <= s1_valid;
            -- Shift register
            for i in 1 to 2 loop
                mp_is_pos(i) <= mp_is_pos(i-1);
                mp_npos(i)   <= mp_npos(i-1);
                mp_nneg(i)   <= mp_nneg(i-1);
                mp_yzp(i)    <= mp_yzp(i-1);
                mp_valid(i)  <= mp_valid(i-1);
            end loop;
        end if;
        end if;
    end process p_mult_pipe;

    ---------------------------------------------------------------------------
    -- ETAPA 5: REDONDEO (ambas ramas)
    --
    -- Sign-extend mult resultado de 40 a 64 bits, luego sumar 2^(n-1).
    ---------------------------------------------------------------------------
    p_etapa5 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s5_round_pos <= (others => '0');
            s5_round_neg <= (others => '0');
            s5_is_pos    <= '0';
            s5_npos      <= (others => '0');
            s5_nneg      <= (others => '0');
            s5_yzp       <= (others => '0');
            s5_valid     <= '0';
        else
            -- Sign-extend 40→64 y sumar valor de redondeo
            s5_round_pos <= resize(mult_pos_raw, 64) + make_round_val(mp_npos(2));
            s5_round_neg <= resize(mult_neg_raw, 64) + make_round_val(mp_nneg(2));

            s5_is_pos <= mp_is_pos(2);
            s5_npos   <= mp_npos(2);
            s5_nneg   <= mp_nneg(2);
            s5_yzp    <= mp_yzp(2);
            s5_valid  <= mp_valid(2);
        end if;
        end if;
    end process p_etapa5;

    ---------------------------------------------------------------------------
    -- ETAPA 6: SHIFT ARITMETICO (ambas ramas)
    ---------------------------------------------------------------------------
    p_etapa6 : process(clk)
        variable shifted_pos : signed(63 downto 0);
        variable shifted_neg : signed(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s6_val_pos <= (others => '0');
            s6_val_neg <= (others => '0');
            s6_is_pos  <= '0';
            s6_yzp     <= (others => '0');
            s6_valid   <= '0';
        else
            shifted_pos := shift_right(s5_round_pos, to_integer(s5_npos));
            s6_val_pos  <= shifted_pos(31 downto 0);

            shifted_neg := shift_right(s5_round_neg, to_integer(s5_nneg));
            s6_val_neg  <= shifted_neg(31 downto 0);

            s6_is_pos <= s5_is_pos;
            s6_yzp    <= s5_yzp;
            s6_valid  <= s5_valid;
        end if;
        end if;
    end process p_etapa6;

    ---------------------------------------------------------------------------
    -- ETAPA 7: MUX + SUMAR Y_ZP
    ---------------------------------------------------------------------------
    p_etapa7 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s7_with_zp <= (others => '0');
            s7_valid   <= '0';
        else
            if s6_is_pos = '1' then
                s7_with_zp <= s6_val_pos + resize(s6_yzp, 32);
            else
                s7_with_zp <= s6_val_neg + resize(s6_yzp, 32);
            end if;
            s7_valid <= s6_valid;
        end if;
        end if;
    end process p_etapa7;

    ---------------------------------------------------------------------------
    -- ETAPA 8: SATURAR A INT8
    ---------------------------------------------------------------------------
    p_etapa8 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            y_out     <= (others => '0');
            valid_out <= '0';
        else
            if s7_with_zp > to_signed(127, 32) then
                y_out <= to_signed(127, 8);
            elsif s7_with_zp < to_signed(-128, 32) then
                y_out <= to_signed(-128, 8);
            else
                y_out <= s7_with_zp(7 downto 0);
            end if;
            valid_out <= s7_valid;
        end if;
        end if;
    end process p_etapa8;

end architecture rtl;
