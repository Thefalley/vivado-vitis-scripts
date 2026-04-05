library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- mult_4dsp_fast: Multiplicacion 32x30 con 4 DSPs + suma por zonas
--
-- Los productos parciales NO se solapan completamente.
-- Partimos el resultado de 62 bits en 3 zonas y sumamos por separado:
--
--   Posicion de bits:
--         [61 ......... 36][35 ......... 18][17 .......... 0]
--   P1:                     [   P1_H (18)  ][   P1_L (18)  ]
--   P2<<18:   [ P2_H (12) ][   P2_L (18)  ]
--   P3<<18: [  P3_H (14)  ][   P3_L (18)  ]
--   P4<<36:[    P4 (26)    ]
--
--   Zona BAJA  [17: 0] = P1_L                         -> SIN SUMA
--   Zona MEDIA [35:18] = P1_H + P2_L + P3_L           -> carry 20 bits
--   Zona ALTA  [61:36] = P2_H + P3_H + P4 + carry_mid -> carry 27 bits
--
-- Maximo carry chain: 27 bits (vs 62 en cascada, vs 62 en tree)
--
-- Pipeline:
--   Stage 1: split inputs
--   Stage 2: 4 DSP multiplications
--   Stage 3: zone LOW (direct) + zone MID (20-bit add) + register highs
--   Stage 4: zone HIGH (27-bit add, combinacional) -> register result
--
-- Latencia: 4 ciclos
-- Throughput: 1 resultado/ciclo (fully pipelined)
-- Recursos: 4 DSP48E1, pocas LUTs (carries cortos)

entity mult_4dsp_fast is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        valid_in  : in  std_logic;
        a_in      : in  std_logic_vector(31 downto 0);
        b_in      : in  std_logic_vector(29 downto 0);
        ready     : out std_logic;
        valid_out : out std_logic;
        result    : out std_logic_vector(61 downto 0)
    );
end mult_4dsp_fast;

architecture rtl of mult_4dsp_fast is

    -- Stage 1: input registers (split)
    signal a_l : unsigned(17 downto 0);
    signal a_h : unsigned(13 downto 0);
    signal b_l : unsigned(17 downto 0);
    signal b_h : unsigned(11 downto 0);
    signal v1  : std_logic := '0';

    -- Stage 2: partial products (4 DSPs)
    signal p1 : unsigned(35 downto 0);  -- A_L x B_L (18x18 = 36b)
    signal p2 : unsigned(29 downto 0);  -- A_L x B_H (18x12 = 30b)
    signal p3 : unsigned(31 downto 0);  -- A_H x B_L (14x18 = 32b)
    signal p4 : unsigned(25 downto 0);  -- A_H x B_H (14x12 = 26b)
    signal v2 : std_logic := '0';

    -- Stage 3: zone sums (registered)
    signal zone_low  : unsigned(17 downto 0);   -- result[17:0] = P1[17:0]
    signal zone_mid  : unsigned(19 downto 0);   -- P1_H + P2_L + P3_L (20b carry)
    signal p2_h_reg  : unsigned(11 downto 0);   -- P2[29:18]
    signal p3_h_reg  : unsigned(13 downto 0);   -- P3[31:18]
    signal p4_reg    : unsigned(25 downto 0);   -- P4 entero
    signal v3        : std_logic := '0';

    -- Stage 4: combinational high zone + registered output
    signal zone_high_comb : unsigned(26 downto 0);  -- 27b combinacional
    signal v4             : std_logic := '0';

begin

    ready <= '1';

    -- Stage 1: register + split
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v1 <= '0';
            else
                v1 <= valid_in;
                a_l <= unsigned(a_in(17 downto 0));
                a_h <= unsigned(a_in(31 downto 18));
                b_l <= unsigned(b_in(17 downto 0));
                b_h <= unsigned(b_in(29 downto 18));
            end if;
        end if;
    end process;

    -- Stage 2: 4 multiplicaciones en paralelo (4 DSP48E1)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v2 <= '0';
            else
                v2 <= v1;
                p1 <= a_l * b_l;
                p2 <= a_l * b_h;
                p3 <= a_h * b_l;
                p4 <= a_h * b_h;
            end if;
        end if;
    end process;

    -- Stage 3: sumas por zonas
    --   Zona BAJA:  P1[17:0] directo (0 logica)
    --   Zona MEDIA: P1[35:18] + P2[17:0] + P3[17:0] -> carry chain 20 bits
    --   Pass-through de partes altas
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v3 <= '0';
            else
                v3 <= v2;
                zone_low <= p1(17 downto 0);
                zone_mid <= resize(p1(35 downto 18), 20)
                          + resize(p2(17 downto 0), 20)
                          + resize(p3(17 downto 0), 20);
                p2_h_reg <= p2(29 downto 18);
                p3_h_reg <= p3(31 downto 18);
                p4_reg   <= p4;
            end if;
        end if;
    end process;

    -- Zona ALTA combinacional: carry chain 27 bits
    -- Entradas todas registradas (stage 3) -> salida a registro (stage 4)
    zone_high_comb <= resize(p2_h_reg, 27)
                    + resize(p3_h_reg, 27)
                    + resize(p4_reg, 27)
                    + resize(zone_mid(19 downto 18), 27);

    -- Stage 4: ensamblar resultado {ALTA[25:0], MEDIA[17:0], BAJA[17:0]}
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v4     <= '0';
                result <= (others => '0');
            else
                v4 <= v3;
                result(17 downto  0) <= std_logic_vector(zone_low);
                result(35 downto 18) <= std_logic_vector(zone_mid(17 downto 0));
                result(61 downto 36) <= std_logic_vector(zone_high_comb(25 downto 0));
            end if;
        end if;
    end process;

    valid_out <= v4;

end rtl;
