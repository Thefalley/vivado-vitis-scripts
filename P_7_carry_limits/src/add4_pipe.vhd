library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- add4_pipe: Sumador de 4 valores signed de N bits, pipelineado por etapas
--
-- R = A + B + C + D (signed)
--
-- Si lo haces en 1 ciclo: carry chain de N+2 bits (3 sumas cascada) -> falla
-- Solucion: pipeline en 2 etapas
--
--   Stage 1 (paralelo):
--     S_AB = A + B    (N+1 bits, carry chain N+1)
--     S_CD = C + D    (N+1 bits, carry chain N+1)
--
--   Stage 2:
--     R = S_AB + S_CD (N+2 bits, carry chain N+2)
--
-- Carry chain max: N+2 bits (misma profundidad que una sola suma de N+2)
-- Pero el throughput es 1/ciclo (pipelined)
--
-- Genericos:
--   DATA_WIDTH = ancho de cada operando (A, B, C, D)
--
-- Resultado: DATA_WIDTH + 2 bits (sin perder precision)
-- Latencia: 3 ciclos (input reg + stage1 + stage2)
-- Throughput: 1/ciclo

entity add4_pipe is
    generic (
        DATA_WIDTH : integer := 32
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        valid_in  : in  std_logic;
        a_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        b_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        c_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        d_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out : out std_logic;
        result    : out std_logic_vector(DATA_WIDTH + 1 downto 0)
    );
end add4_pipe;

architecture rtl of add4_pipe is

    constant RW : integer := DATA_WIDTH + 2;

    -- Stage 0: input registers
    signal a_reg, b_reg, c_reg, d_reg : signed(DATA_WIDTH - 1 downto 0);
    signal v0 : std_logic := '0';

    -- Stage 1: sumas paralelas (A+B) y (C+D)
    signal s_ab : signed(DATA_WIDTH downto 0);  -- N+1 bits
    signal s_cd : signed(DATA_WIDTH downto 0);  -- N+1 bits
    signal v1   : std_logic := '0';

    -- Stage 2: suma final
    signal v2 : std_logic := '0';

begin

    -- Stage 0: register inputs
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v0 <= '0';
            else
                v0 <= valid_in;
                a_reg <= signed(a_in);
                b_reg <= signed(b_in);
                c_reg <= signed(c_in);
                d_reg <= signed(d_in);
            end if;
        end if;
    end process;

    -- Stage 1: dos sumas en PARALELO
    -- Carry chain = N+1 bits cada una (independientes, no cascada)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v1 <= '0';
            else
                v1 <= v0;
                s_ab <= resize(a_reg, DATA_WIDTH + 1) + resize(b_reg, DATA_WIDTH + 1);
                s_cd <= resize(c_reg, DATA_WIDTH + 1) + resize(d_reg, DATA_WIDTH + 1);
            end if;
        end if;
    end process;

    -- Stage 2: suma final
    -- Carry chain = N+2 bits
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v2     <= '0';
                result <= (others => '0');
            else
                v2 <= v1;
                result <= std_logic_vector(
                    resize(s_ab, RW) + resize(s_cd, RW)
                );
            end if;
        end if;
    end process;

    valid_out <= v2;

end rtl;
