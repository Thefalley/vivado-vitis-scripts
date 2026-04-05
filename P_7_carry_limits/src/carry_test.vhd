library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- carry_test: Modulo parametrico para medir limites de carry chains
--
-- Reg -> Operacion combinacional -> Reg
-- Sin trampas: resultado con ancho REAL
--
-- OP_MODE:
--   0 = ADD_UNSIGNED    A + B                -> N+1 bits
--   1 = ADD_SIGNED      signed(A) + signed(B) -> N+1 bits
--   2 = ADD_3WAY        A + B + C             -> N+2 bits (simula zona media)
--   3 = ADD_CASCADE     (A + B) + (C + D)     -> N+2 bits (tree de 4 inputs)
--   4 = SHIFT_VAR       A << B(log2(N)-1..0)  -> N bits (barrel shifter)
--   5 = ADD_WITH_CARRY  {cout,S} = A + B + cin -> N+1 bits (carry in desde registro)
--
-- Para medir: sintetizar con distintos DATA_WIDTH y ver WNS

entity carry_test is
    generic (
        DATA_WIDTH   : integer := 32;
        OP_MODE      : integer := 0;
        RESULT_WIDTH : integer := 33
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
        result    : out std_logic_vector(RESULT_WIDTH - 1 downto 0)
    );
end carry_test;

architecture rtl of carry_test is

    signal a_reg, b_reg, c_reg, d_reg : unsigned(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal valid_reg : std_logic := '0';

    signal comb_result : unsigned(RESULT_WIDTH - 1 downto 0);

    -- Intermedios para ADD_4TREE (OP_MODE=3)
    signal sum_ab : unsigned(DATA_WIDTH downto 0);
    signal sum_cd : unsigned(DATA_WIDTH downto 0);

begin

    -- Input register stage
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                a_reg     <= (others => '0');
                b_reg     <= (others => '0');
                c_reg     <= (others => '0');
                d_reg     <= (others => '0');
                valid_reg <= '0';
            else
                valid_reg <= valid_in;
                if valid_in = '1' then
                    a_reg <= unsigned(a_in);
                    b_reg <= unsigned(b_in);
                    c_reg <= unsigned(c_in);
                    d_reg <= unsigned(d_in);
                end if;
            end if;
        end if;
    end process;

    -- ADD unsigned: A + B = N+1 bits
    gen_add: if OP_MODE = 0 generate
        comb_result <= resize(a_reg, RESULT_WIDTH) + resize(b_reg, RESULT_WIDTH);
    end generate;

    -- ADD signed: signed(A) + signed(B) = N+1 bits
    gen_add_s: if OP_MODE = 1 generate
        comb_result <= unsigned(
            std_logic_vector(
                resize(signed(std_logic_vector(a_reg)), RESULT_WIDTH)
              + resize(signed(std_logic_vector(b_reg)), RESULT_WIDTH)
            )
        );
    end generate;

    -- ADD 3-way: A + B + C = N+2 bits (simula zona media del multiplicador)
    gen_add3: if OP_MODE = 2 generate
        comb_result <= resize(a_reg, RESULT_WIDTH)
                     + resize(b_reg, RESULT_WIDTH)
                     + resize(c_reg, RESULT_WIDTH);
    end generate;

    -- ADD cascade (tree): (A + B) + (C + D) = N+2 bits
    gen_add4: if OP_MODE = 3 generate
        sum_ab <= resize(a_reg, DATA_WIDTH + 1) + resize(b_reg, DATA_WIDTH + 1);
        sum_cd <= resize(c_reg, DATA_WIDTH + 1) + resize(d_reg, DATA_WIDTH + 1);
        comb_result <= resize(sum_ab, RESULT_WIDTH) + resize(sum_cd, RESULT_WIDTH);
    end generate;

    -- SHIFT variable: A << B(5..0) = N bits (max shift 63)
    gen_shift: if OP_MODE = 4 generate
        comb_result <= resize(
            shift_left(a_reg, to_integer(b_reg(5 downto 0))),
            RESULT_WIDTH
        );
    end generate;

    -- ADD with carry-in: A + B + carry_from_prev_stage
    gen_addc: if OP_MODE = 5 generate
        comb_result <= resize(a_reg, RESULT_WIDTH)
                     + resize(b_reg, RESULT_WIDTH)
                     + resize(c_reg(0 downto 0), RESULT_WIDTH);
    end generate;

    -- Output register stage
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                result    <= (others => '0');
                valid_out <= '0';
            else
                valid_out <= valid_reg;
                if valid_reg = '1' then
                    result <= std_logic_vector(comb_result);
                end if;
            end if;
        end if;
    end process;

end rtl;
