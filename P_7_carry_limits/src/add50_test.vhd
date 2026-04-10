library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity add50_test is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        a_in      : in  std_logic_vector(49 downto 0);
        b_in      : in  std_logic_vector(49 downto 0);
        valid_in  : in  std_logic;
        result    : out std_logic_vector(50 downto 0);
        valid_out : out std_logic
    );
end entity add50_test;

architecture rtl of add50_test is
    signal a_reg   : unsigned(49 downto 0);
    signal b_reg   : unsigned(49 downto 0);
    signal v_reg   : std_logic;
    signal sum_comb : unsigned(50 downto 0);
begin

    -- Combinational addition (resize to 51 bits)
    sum_comb <= resize(a_reg, 51) + resize(b_reg, 51);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                a_reg     <= (others => '0');
                b_reg     <= (others => '0');
                v_reg     <= '0';
                result    <= (others => '0');
                valid_out <= '0';
            else
                -- Input register stage
                a_reg <= unsigned(a_in);
                b_reg <= unsigned(b_in);
                v_reg <= valid_in;
                -- Output register stage
                result    <= std_logic_vector(sum_comb);
                valid_out <= v_reg;
            end if;
        end if;
    end process;

end architecture rtl;
