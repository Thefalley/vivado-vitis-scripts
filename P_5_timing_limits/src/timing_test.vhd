library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- timing_test: Registro -> Operacion combinacional -> Registro
-- Sin trampas: el resultado tiene el ancho REAL de la operacion.
--
-- OP_MODE:
--   0 = ADD         (A + B)           -> resultado: DATA_WIDTH + 1 bits
--   1 = MULT        (A * B)           -> resultado: 2 * DATA_WIDTH bits
--   2 = SHIFT_VAR   (A << B(4..0))    -> resultado: DATA_WIDTH bits
--   3 = MAC         (A * B + C)       -> resultado: 2 * DATA_WIDTH + 1 bits
--
-- RESULT_WIDTH se calcula segun OP_MODE para no perder bits.

entity timing_test is
    generic (
        DATA_WIDTH   : integer := 32;
        OP_MODE      : integer := 0;
        -- RESULT_WIDTH: caller must set this to match the operation
        -- ADD:       DATA_WIDTH + 1
        -- MULT:      2 * DATA_WIDTH
        -- SHIFT_VAR: DATA_WIDTH
        -- MAC:       2 * DATA_WIDTH + 1
        RESULT_WIDTH : integer := 33
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        valid_in  : in  std_logic;
        a_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        b_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        c_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out : out std_logic;
        result    : out std_logic_vector(RESULT_WIDTH - 1 downto 0)
    );
end timing_test;

architecture rtl of timing_test is

    -- Input registers
    signal a_reg     : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal b_reg     : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal c_reg     : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal valid_reg : std_logic := '0';

    -- Combinational result (full width, no truncation)
    signal comb_result : signed(RESULT_WIDTH - 1 downto 0);

begin

    -- Input register stage
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                a_reg     <= (others => '0');
                b_reg     <= (others => '0');
                c_reg     <= (others => '0');
                valid_reg <= '0';
            else
                valid_reg <= valid_in;
                if valid_in = '1' then
                    a_reg <= signed(a_in);
                    b_reg <= signed(b_in);
                    c_reg <= signed(c_in);
                end if;
            end if;
        end if;
    end process;

    -- Combinational operation (full precision, no resize/truncate)
    gen_add: if OP_MODE = 0 generate
        -- N + N = N+1 bits
        comb_result <= resize(a_reg, RESULT_WIDTH) + resize(b_reg, RESULT_WIDTH);
    end generate;

    gen_mult: if OP_MODE = 1 generate
        -- N * N = 2N bits (full multiply, all bits kept)
        comb_result <= a_reg * b_reg;
    end generate;

    gen_shift: if OP_MODE = 2 generate
        -- barrel shifter, N bits
        comb_result <= resize(shift_left(a_reg, to_integer(unsigned(b_reg(4 downto 0)))), RESULT_WIDTH);
    end generate;

    gen_mac: if OP_MODE = 3 generate
        -- N * N + N = 2N+1 bits (multiply-accumulate, single stage)
        comb_result <= resize(a_reg * b_reg, RESULT_WIDTH) + resize(c_reg, RESULT_WIDTH);
    end generate;

    -- Output register stage (full width, no bits lost)
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
