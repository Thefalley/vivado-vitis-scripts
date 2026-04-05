library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mul_s32x32_pipe is
    port (
        clk : in  std_logic;
        a   : in  signed(31 downto 0);
        b   : in  signed(31 downto 0);
        p   : out signed(63 downto 0)
    );
end entity;

architecture rtl of mul_s32x32_pipe is

    ----------------------------------------------------------------------------
    -- ETAPA 1: productos parciales
    ----------------------------------------------------------------------------
    -- P1 = unsigned(A_L) * unsigned(B_L)          -> 18x18 = 36 bits
    -- P2 = signed(0&A_L) * signed(B_H)            -> 19x14 = 33 bits
    -- P3 = signed(A_H) * signed(0&B_L)            -> 14x19 = 33 bits
    -- P4 = signed(A_H) * signed(B_H)              -> 14x14 = 28 bits
    ----------------------------------------------------------------------------
    signal p1_s1 : unsigned(35 downto 0);
    signal p2_s1 : signed(32 downto 0);
    signal p3_s1 : signed(32 downto 0);
    signal p4_s1 : signed(27 downto 0);

    ----------------------------------------------------------------------------
    -- ETAPA 2
    -- z0 = bits [17:0]
    -- primera suma de zona media: P1_H + P2_L
    ----------------------------------------------------------------------------
    signal z0_s2       : unsigned(17 downto 0);
    signal z1a_lo_s2   : unsigned(17 downto 0);
    signal z1a_c_s2    : std_logic;

    signal p3l_s2      : unsigned(17 downto 0);

    -- contribuciones ya preparadas para la zona alta [63:36]
    signal p2h_z2_s2   : unsigned(27 downto 0);
    signal p3h_z2_s2   : unsigned(27 downto 0);
    signal p4_z2_s2    : unsigned(27 downto 0);

    ----------------------------------------------------------------------------
    -- ETAPA 3
    -- segunda suma de zona media: z1a_lo + P3_L
    -- carry explícito hacia la zona alta
    -- primera suma de zona alta: P4 + P2_H_ext
    ----------------------------------------------------------------------------
    signal z0_s3          : unsigned(17 downto 0);
    signal z1_s3          : unsigned(17 downto 0);
    signal c_z1_to_z2_s3  : unsigned(1 downto 0);

    signal z2a_s3         : unsigned(27 downto 0);
    signal p3h_z2_s3      : unsigned(27 downto 0);

    ----------------------------------------------------------------------------
    -- ETAPA 4
    -- segunda suma de zona alta: z2a + P3_H_ext
    ----------------------------------------------------------------------------
    signal z0_s4          : unsigned(17 downto 0);
    signal z1_s4          : unsigned(17 downto 0);
    signal c_z1_to_z2_s4  : unsigned(1 downto 0);

    signal z2b_s4         : unsigned(27 downto 0);

    ----------------------------------------------------------------------------
    -- ETAPA 5
    -- tercera suma de zona alta: z2b + carry_z1_to_z2
    -- ensamblado final
    ----------------------------------------------------------------------------
    signal p_s5 : signed(63 downto 0);

begin

    process(clk)
        variable v_z1a      : unsigned(18 downto 0);
        variable v_z1b      : unsigned(18 downto 0);
        variable v_carry12  : unsigned(1 downto 0);

        variable v_z2a      : unsigned(28 downto 0);
        variable v_z2b      : unsigned(28 downto 0);
        variable v_z2c      : unsigned(28 downto 0);
    begin
        if rising_edge(clk) then

            --------------------------------------------------------------------
            -- ETAPA 1: productos parciales
            --
            -- Nota:
            -- Los bajos A_L y B_L se toman como magnitud positiva:
            --   unsigned(a(17 downto 0))
            -- Para las cross terms se les antepone '0' y se tratan como signed
            -- positivo de 19 bits.
            --------------------------------------------------------------------
            p1_s1 <= unsigned(a(17 downto 0)) * unsigned(b(17 downto 0));

            p2_s1 <= signed('0' & std_logic_vector(a(17 downto 0))) * b(31 downto 18);

            p3_s1 <= a(31 downto 18) * signed('0' & std_logic_vector(b(17 downto 0)));

            p4_s1 <= a(31 downto 18) * b(31 downto 18);

            --------------------------------------------------------------------
            -- ETAPA 2
            --
            -- Zona baja:
            --   [17:0] = P1[17:0]
            --
            -- Zona media, primera suma corta:
            --   P1[35:18] + P2[17:0]
            --
            -- Ojo: aquí se suman PATRONES DE BITS de 18 bits.
            -- El carry sale explícitamente y se reenviará a la zona alta.
            --------------------------------------------------------------------
            z0_s2 <= p1_s1(17 downto 0);

            v_z1a := ('0' & p1_s1(35 downto 18))
                   + ('0' & unsigned(std_logic_vector(p2_s1(17 downto 0))));
            z1a_lo_s2 <= v_z1a(17 downto 0);
            z1a_c_s2  <= v_z1a(18);

            p3l_s2 <= unsigned(std_logic_vector(p3_s1(17 downto 0)));

            -- Parte alta de P2 y P3, ya sign-extendida a 28 bits para la zona [63:36]
            p2h_z2_s2 <= unsigned(std_logic_vector(resize(p2_s1(32 downto 18), 28)));
            p3h_z2_s2 <= unsigned(std_logic_vector(resize(p3_s1(32 downto 18), 28)));

            -- P4 ya ocupa directamente la zona alta
            p4_z2_s2  <= unsigned(std_logic_vector(p4_s1));

            --------------------------------------------------------------------
            -- ETAPA 3
            --
            -- Segunda suma corta de zona media:
            --   z1a_lo + P3[17:0]
            --
            -- Carry explícito entre zonas:
            --   carry_total = carry(z1a) + carry(z1b)
            --
            -- Primera suma de zona alta:
            --   P4 + P2_H_ext
            --------------------------------------------------------------------
            z0_s3 <= z0_s2;

            v_z1b := ('0' & z1a_lo_s2) + ('0' & p3l_s2);
            z1_s3 <= v_z1b(17 downto 0);

            v_carry12 := (others => '0');
            if z1a_c_s2 = '1' then
                v_carry12 := v_carry12 + 1;
            end if;
            if v_z1b(18) = '1' then
                v_carry12 := v_carry12 + 1;
            end if;
            c_z1_to_z2_s3 <= v_carry12;

            v_z2a := ('0' & p4_z2_s2) + ('0' & p2h_z2_s2);
            z2a_s3 <= v_z2a(27 downto 0);

            p3h_z2_s3 <= p3h_z2_s2;

            --------------------------------------------------------------------
            -- ETAPA 4
            --
            -- Segunda suma de zona alta:
            --   z2a + P3_H_ext
            --------------------------------------------------------------------
            z0_s4         <= z0_s3;
            z1_s4         <= z1_s3;
            c_z1_to_z2_s4 <= c_z1_to_z2_s3;

            v_z2b := ('0' & z2a_s3) + ('0' & p3h_z2_s3);
            z2b_s4 <= v_z2b(27 downto 0);

            --------------------------------------------------------------------
            -- ETAPA 5
            --
            -- Tercera suma de zona alta:
            --   z2b + carry_z1_to_z2
            --
            -- Ese carry es EXPLÍCITO y entra aquí como dato de 2 bits.
            --------------------------------------------------------------------
            v_z2c := ('0' & z2b_s4)
                   + ("000000000000000000000000000" & c_z1_to_z2_s4);

            -- Ensamblado final:
            -- [63:36] = z2c
            -- [35:18] = z1
            -- [17:0]  = z0
            p_s5 <= signed(std_logic_vector(v_z2c(27 downto 0) & z1_s4 & z0_s4));

        end if;
    end process;

    p <= p_s5;

end architecture;