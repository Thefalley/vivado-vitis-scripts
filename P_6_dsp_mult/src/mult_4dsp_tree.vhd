library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- mult_4dsp_tree: Multiplicacion 32x30 con 4 DSPs + suma en arbol
--
-- Misma descomposicion que mult_4dsp, pero la suma final se hace
-- en arbol pipelineado en vez de cascada:
--
--   Stage 1: reg_in + split (A_L, A_H, B_L, B_H)
--   Stage 2: 4 multiplicaciones en paralelo (4 DSP48E1)
--   Stage 3: S1 = P1 + (P2 << 18)       <- 2 sumas en PARALELO
--            S2 = (P3 << 18) + (P4 << 36)
--   Stage 4: Result = S1 + S2            <- 1 suma final
--
-- El shift por constante es solo cableado (coste 0 en logica).
-- Cada suma es de 62 bits max = 1 carry chain.
-- En la version sin arbol habia 3 sumas en cascada = 3 carry chains.
--
-- Latencia: 4 ciclos (1 mas que mult_4dsp)
-- Throughput: 1 resultado/ciclo (fully pipelined)
-- Recursos esperados: 4 DSP48E1, mas LUTs por sumas pero mejor timing

entity mult_4dsp_tree is
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
end mult_4dsp_tree;

architecture rtl of mult_4dsp_tree is

    -- Stage 1: input registers (split)
    signal a_l : unsigned(17 downto 0);
    signal a_h : unsigned(13 downto 0);
    signal b_l : unsigned(17 downto 0);
    signal b_h : unsigned(11 downto 0);
    signal v1  : std_logic := '0';

    -- Stage 2: partial products (4 DSPs)
    signal p1 : unsigned(35 downto 0);  -- 18x18
    signal p2 : unsigned(29 downto 0);  -- 18x12
    signal p3 : unsigned(31 downto 0);  -- 14x18
    signal p4 : unsigned(25 downto 0);  -- 14x12
    signal v2 : std_logic := '0';

    -- Stage 3: tree sums (2 sumas en paralelo)
    signal s1 : unsigned(61 downto 0);  -- P1 + (P2 << 18)
    signal s2 : unsigned(61 downto 0);  -- (P3 << 18) + (P4 << 36)
    signal v3 : std_logic := '0';

    -- Stage 4: final sum
    signal v4 : std_logic := '0';

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

    -- Stage 3: tree sums - 2 sumas en PARALELO
    -- Cada una es 1 carry chain de 62 bits (en vez de 3 en cascada)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v3 <= '0';
            else
                v3 <= v2;
                -- Suma izquierda: P1 + (P2 << 18)
                s1 <= resize(p1, 62) + shift_left(resize(p2, 62), 18);
                -- Suma derecha: (P3 << 18) + (P4 << 36)
                s2 <= shift_left(resize(p3, 62), 18) + shift_left(resize(p4, 62), 36);
            end if;
        end if;
    end process;

    -- Stage 4: suma final + output register
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v4     <= '0';
                result <= (others => '0');
            else
                v4     <= v3;
                result <= std_logic_vector(s1 + s2);
            end if;
        end if;
    end process;

    valid_out <= v4;

end rtl;
