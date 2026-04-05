library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- mult_4dsp: Multiplicacion 32x30 con 4 productos parciales en paralelo
--
-- Descomposicion:
--   A(32) = A_H(14) * 2^18 + A_L(18)
--   B(30) = B_H(12) * 2^18 + B_L(18)
--
--   P1 = A_L x B_L   (18x18 -> 36b)   1 DSP
--   P2 = A_L x B_H   (18x12 -> 30b)   1 DSP
--   P3 = A_H x B_L   (14x18 -> 32b)   1 DSP
--   P4 = A_H x B_H   (14x12 -> 26b)   1 DSP
--
--   Result(62b) = P1 + (P2 + P3) << 18 + P4 << 36
--
-- Pipeline: reg_in -> mult (x4) -> sum -> reg_out
-- Latencia: 3 ciclos
-- Throughput: 1 resultado/ciclo
-- Recursos esperados: 4 DSP48E1

entity mult_4dsp is
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
end mult_4dsp;

architecture rtl of mult_4dsp is

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

    -- Stage 3: output
    signal v3 : std_logic := '0';

begin

    -- Siempre listo (fully pipelined)
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

    -- Stage 2: 4 multiplicaciones en paralelo (Vivado -> 4 DSP48E1)
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

    -- Stage 3: shift + add + output register
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v3     <= '0';
                result <= (others => '0');
            else
                v3 <= v2;
                result <= std_logic_vector(
                    resize(p1, 62)
                  + shift_left(resize(p2, 62), 18)
                  + shift_left(resize(p3, 62), 18)
                  + shift_left(resize(p4, 62), 36)
                );
            end if;
        end if;
    end process;

    valid_out <= v3;

end rtl;
