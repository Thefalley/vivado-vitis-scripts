-------------------------------------------------------------------------------
-- mul_s9xu30_pipe.vhd — Multiplicador signed(9) × unsigned(30) pipeline
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Multiplica una activacion shifted (int9, signed) por un multiplicador
--   M0 (unsigned 30 bits) y produce un resultado signed de 40 bits.
--   Es la operacion central de leaky_relu y elem_add.
--
-- POR QUE EXISTE:
--   El DSP48E1 del XC7Z020 tiene un multiplicador de 25×18 bits.
--   M0 tiene 30 bits -> no cabe en un solo DSP.
--   Hay que partir M0 en dos trozos y hacer 2 productos parciales.
--
-- COMO LO HACE (3 etapas de pipeline):
--
--   Descomposicion de M0 (unsigned 30 bits):
--     M0 = M0_high(12 bits) × 2^18  +  M0_low(18 bits)
--
--   ETAPA 1 (ciclo N):
--     P1 = A × signed('0' & M0_low)    -> signed(9) × signed(19) = signed(28)
--     P2 = A × signed('0' & M0_high)   -> signed(9) × signed(13) = signed(22)
--     2 DSP48E1 en paralelo.
--
--   ETAPA 2 (ciclo N+1):
--     result = P1 + (P2 << 18)
--     Suma directa de 40 bits. Carry chain de 40 bits = ~2.8 ns.
--     Cabe sobrado en 10 ns a 100 MHz.
--
--   ETAPA 3 (ciclo N+2):
--     Registrar salida (mantener latencia de 3 ciclos para compatibilidad
--     con pipeline de leaky_relu y elem_add).
--
-- BUG CORREGIDO (2026-04-10):
--   La version anterior usaba ensamblaje por zonas (zona baja, media, alta)
--   con unsigned. Cuando A era negativo, P1 era signed negativo y sus bits
--   [27:18] contenian propagacion de signo. Al convertirlos a unsigned se
--   perdia el signo, causando errores off-by-1 en 4 de 256 valores.
--   Verificado en hardware real (ZedBoard): x=-81,-75,-69,-63 daban +1.
--   FIX: suma directa signed de 40 bits, sin manipulacion de zonas.
--
-- LATENCIA: 3 ciclos.
-- THROUGHPUT: 1 resultado por ciclo (pipeline).
-- RECURSOS: 2 DSP48E1 + ~20 LUTs (carry chain 40 bits) + ~100 FFs.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mul_s9xu30_pipe is
    port (
        clk : in  std_logic;
        a   : in  signed(8 downto 0);      -- 9 bits signed (x_shifted)
        b   : in  unsigned(29 downto 0);    -- 30 bits unsigned (M0)
        p   : out signed(39 downto 0)       -- 40 bits signed (resultado)
    );
end entity;

architecture rtl of mul_s9xu30_pipe is

    -- ETAPA 1: productos parciales (2 DSP48E1)
    signal p1_s1 : signed(27 downto 0);     -- 28 bits: A × M0_low
    signal p2_s1 : signed(21 downto 0);     -- 22 bits: A × M0_high

    -- ETAPA 2: suma directa
    signal p_s2 : signed(39 downto 0);      -- resultado de P1 + (P2 << 18)

    -- ETAPA 3: registro de salida
    signal p_s3 : signed(39 downto 0);

begin

    process(clk)
    begin
        if rising_edge(clk) then

            ----------------------------------------------------------------
            -- ETAPA 1: 2 productos parciales (2 DSP48E1)
            --
            -- M0_low  = b(17 downto 0)  = 18 bits unsigned
            -- M0_high = b(29 downto 18) = 12 bits unsigned
            --
            -- El '0' & convierte cada trozo unsigned a signed positivo.
            -- Sin el '0', si bit 29 de M0 = 1, M0_high se interpretaria
            -- como negativo (en nuestro modelo M0 esta en [2^29, 2^30),
            -- bit 29 = 1 SIEMPRE).
            ----------------------------------------------------------------
            p1_s1 <= a * signed('0' & std_logic_vector(b(17 downto 0)));
            p2_s1 <= a * signed('0' & std_logic_vector(b(29 downto 18)));

            ----------------------------------------------------------------
            -- ETAPA 2: suma directa de 40 bits
            --
            -- result = P1 + (P2 << 18)
            --
            -- resize(P1, 40): sign-extend de 28 a 40 bits
            -- resize(P2, 40): sign-extend de 22 a 40 bits
            -- shift_left(P2, 18): desplazar P2 a su posicion (× 2^18)
            --
            -- La suma es signed, asi el signo se propaga correctamente.
            -- Carry chain de 40 bits = ~2.8 ns. Cabe en 10 ns a 100 MHz.
            ----------------------------------------------------------------
            p_s2 <= resize(p1_s1, 40) + shift_left(resize(p2_s1, 40), 18);

            ----------------------------------------------------------------
            -- ETAPA 3: registrar salida
            -- Mantiene latencia de 3 ciclos para compatibilidad con
            -- el pipeline de leaky_relu.vhd y elem_add.vhd.
            ----------------------------------------------------------------
            p_s3 <= p_s2;

        end if;
    end process;

    p <= p_s3;

end architecture;
