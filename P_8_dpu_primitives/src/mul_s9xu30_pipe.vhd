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
--   M0 tiene 30 bits → no cabe en el puerto A (25 bits) ni en B (18 bits).
--   Hay que partir M0 en dos trozos y hacer 2 productos parciales.
--
-- COMO LO HACE (3 etapas de pipeline):
--
--   Descomposicion de M0 (unsigned 30 bits):
--     M0 = M0_high(12 bits) × 2^18  +  M0_low(18 bits)
--
--     M0_low  = M0(17 downto 0)  = 18 bits unsigned
--     M0_high = M0(29 downto 18) = 12 bits unsigned
--
--   ETAPA 1 (ciclo N):
--     P1 = A × signed('0' & M0_low)    → signed(9) × signed(19) = signed(28)
--     P2 = A × signed('0' & M0_high)   → signed(9) × signed(13) = signed(22)
--     El '0' convierte cada trozo unsigned en signed positivo.
--     IMPORTANTE: sin el '0', M0_high se interpretaria como signed
--     y si bit 29 de M0 = 1 (que es siempre en nuestro modelo,
--     porque M0 esta en [2^29, 2^30)), el producto parcial tendria
--     signo invertido. El '0' evita este bug.
--     2 DSP48E1: P1 cabe en 9×19 ≤ 25×18, P2 cabe en 9×13 ≤ 25×18.
--
--   ETAPA 2 (ciclo N+1):
--     Ensamblar por zonas:
--     Zona baja [17:0]:  = P1[17:0] (sin suma, copiar directo)
--     Zona media [27:18]: = P1[27:18] + P2[9:0] (suma de 10 bits + carry)
--     El carry (1 bit) se propaga a zona alta.
--     Se guarda P2_high = P2[21:10] para la etapa siguiente.
--
--   ETAPA 3 (ciclo N+2):
--     Zona alta [39:28]: = P2[21:10] + carry (suma de 12 bits + 1 bit)
--     Ensamblado final: {zona_alta, zona_media, zona_baja} = 40 bits.
--
-- LATENCIA: 3 ciclos.
-- THROUGHPUT: 1 resultado por ciclo (pipeline).
--
-- ANCHOS:
--   a:       signed 9 bits (x_shifted = x - x_zp, rango -255..255)
--   b:       unsigned 30 bits (M0, rango [2^29, 2^30), siempre positivo)
--   P1:      signed 28 bits (A × M0_low con '0')
--   P2:      signed 22 bits (A × M0_high con '0')
--   p:       signed 40 bits (resultado: 9+30+1 = 40 bits para signed)
--
-- RECURSOS:
--   DSP48E1: 2 (uno por producto parcial)
--   LUTs: ~30 (sumas de zona media y alta + carry)
--   FFs: ~100 (registros de pipeline)
--
-- NOTA: el resultado de 40 bits se extiende a 64 bits (sign-extend)
-- en los modulos que lo usan (leaky_relu, elem_add) para las etapas
-- posteriores de redondeo y shift.
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

    ---------------------------------------------------------------------------
    -- ETAPA 1: productos parciales (2 DSP48E1)
    --
    -- P1 = A(9 signed) × signed('0' & B_low(18 unsigned))
    --    = signed(9) × signed(19) = signed(28)
    --    Cabe en 1 DSP48E1 (9 ≤ 18, 19 ≤ 25)
    --
    -- P2 = A(9 signed) × signed('0' & B_high(12 unsigned))
    --    = signed(9) × signed(13) = signed(22)
    --    Cabe en 1 DSP48E1 (9 ≤ 18, 13 ≤ 25)
    ---------------------------------------------------------------------------
    signal p1_s1 : signed(27 downto 0);     -- 28 bits: A × B_low
    signal p2_s1 : signed(21 downto 0);     -- 22 bits: A × B_high

    ---------------------------------------------------------------------------
    -- ETAPA 2: zona baja + suma zona media
    --
    -- z0 = P1[17:0]                        (18 bits, sin suma)
    -- z1 = P1[27:18] + P2[9:0]            (10 bits + carry)
    -- p2h = P2[21:10]                      (12 bits, para etapa 3)
    ---------------------------------------------------------------------------
    signal z0_s2   : unsigned(17 downto 0);  -- zona baja: copiar directo
    signal z1_s2   : unsigned(9 downto 0);   -- zona media: resultado suma
    signal c_z1_s2 : std_logic;              -- carry de zona media → alta
    signal p2h_s2  : signed(11 downto 0);    -- P2 high: pendiente para etapa 3

    ---------------------------------------------------------------------------
    -- ETAPA 3: zona alta + ensamblado final
    ---------------------------------------------------------------------------
    signal p_s3 : signed(39 downto 0);       -- resultado ensamblado

begin

    process(clk)
        variable v_z1 : unsigned(10 downto 0);   -- 11 bits para capturar carry
        variable v_z2 : signed(11 downto 0);      -- zona alta con carry
    begin
        if rising_edge(clk) then

            ----------------------------------------------------------------
            -- ETAPA 1: 2 productos parciales (2 DSP48E1)
            --
            -- B_low  = b(17 downto 0)  = 18 bits unsigned
            -- B_high = b(29 downto 18) = 12 bits unsigned
            --
            -- CRITICO: el '0' & convierte unsigned a signed POSITIVO.
            -- Sin el '0', si bit 29 de M0 = 1, B_high se interpretaria
            -- como negativo y el producto parcial tendria signo invertido.
            -- En nuestro modelo, M0 esta siempre en [2^29, 2^30) asi que
            -- bit 29 = 1 SIEMPRE. Sin el '0' el resultado seria INCORRECTO.
            ----------------------------------------------------------------
            p1_s1 <= a * signed('0' & std_logic_vector(b(17 downto 0)));
            p2_s1 <= a * signed('0' & std_logic_vector(b(29 downto 18)));

            ----------------------------------------------------------------
            -- ETAPA 2: ensamblar zona baja + sumar zona media
            --
            -- El resultado final tiene esta estructura:
            --   [39:28] = zona alta  (P2_high + carry)
            --   [27:18] = zona media (P1_high + P2_low)
            --   [17:0]  = zona baja  (P1_low, sin suma)
            --
            -- Zona baja: copiar directo P1[17:0]
            -- Zona media: sumar P1[27:18] + P2[9:0] con carry
            --   La suma es de 10 bits, produce 10 bits + 1 carry.
            --   El carry se propaga a zona alta en etapa 3.
            ----------------------------------------------------------------
            z0_s2 <= unsigned(std_logic_vector(p1_s1(17 downto 0)));

            -- Suma zona media: 10 bits de P1_high + 10 bits de P2_low
            -- Se usa 11 bits para capturar el carry en bit 10
            v_z1 := ('0' & unsigned(std_logic_vector(p1_s1(27 downto 18))))
                  + ('0' & unsigned(std_logic_vector(p2_s1(9 downto 0))));

            z1_s2   <= v_z1(9 downto 0);    -- zona media resultado
            c_z1_s2 <= v_z1(10);             -- carry → zona alta

            -- Guardar P2 high para sumar con carry en etapa 3
            p2h_s2 <= p2_s1(21 downto 10);

            ----------------------------------------------------------------
            -- ETAPA 3: zona alta + ensamblado
            --
            -- Zona alta = P2[21:10] + carry de zona media
            -- P2[21:10] es signed(12 bits). El carry es 0 o 1.
            -- Luego ensamblar: {zona_alta, zona_media, zona_baja}
            ----------------------------------------------------------------
            v_z2 := p2h_s2;
            if c_z1_s2 = '1' then
                v_z2 := v_z2 + 1;
            end if;

            -- Ensamblar las 3 zonas en el resultado final de 40 bits
            -- v_z2     = bits [39:28] (12 bits signed = zona alta)
            -- z1_s2    = bits [27:18] (10 bits = zona media)
            -- z0_s2    = bits [17:0]  (18 bits = zona baja)
            p_s3 <= v_z2
                  & signed(std_logic_vector(z1_s2))
                  & signed(std_logic_vector(z0_s2));

        end if;
    end process;

    -- Salida: cable directo al registro de etapa 3
    p <= p_s3;

end architecture;
