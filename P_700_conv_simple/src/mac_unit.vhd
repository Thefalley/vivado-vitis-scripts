-------------------------------------------------------------------------------
-- mac_unit.vhd — Unidad MAC (Multiply-Accumulate) para DPU INT8
-- COPIA EXACTA de P_13 (verificado en HW: 1083 tests ZedBoard)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac_unit is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        a_in      : in  signed(8 downto 0);
        b_in      : in  signed(7 downto 0);
        bias_in   : in  signed(31 downto 0);
        valid_in  : in  std_logic;
        load_bias : in  std_logic;
        clear     : in  std_logic;
        acc_out   : out signed(31 downto 0);
        valid_out : out std_logic
    );
end entity mac_unit;

architecture rtl of mac_unit is
    attribute use_dsp : string;
    attribute dont_touch : string;

    signal product_r    : signed(16 downto 0);
    attribute use_dsp of product_r : signal is "yes";
    attribute dont_touch of product_r : signal is "true";

    signal s1_valid     : std_logic;
    signal s1_bias      : std_logic;
    signal s1_clear     : std_logic;
    signal s1_bias_val  : signed(31 downto 0);
    attribute dont_touch of s1_valid    : signal is "true";
    attribute dont_touch of s1_bias     : signal is "true";
    attribute dont_touch of s1_clear    : signal is "true";
    attribute dont_touch of s1_bias_val : signal is "true";

    signal acc_r        : signed(31 downto 0);
    signal valid_r      : std_logic;

begin

    p_etapa1 : process(clk)
    begin
        if rising_edge(clk) then
        if rst_n = '0' then
            product_r   <= (others => '0');
            s1_valid    <= '0';
            s1_bias     <= '0';
            s1_clear    <= '0';
            s1_bias_val <= (others => '0');
        else
            product_r   <= a_in * b_in;
            s1_valid    <= valid_in;
            s1_bias     <= load_bias;
            s1_clear    <= clear;
            s1_bias_val <= bias_in;
        end if;
        end if;
    end process p_etapa1;

    p_etapa2 : process(clk)
    begin
        if rising_edge(clk) then
        if rst_n = '0' then
            acc_r   <= (others => '0');
            valid_r <= '0';
        else
            if s1_clear = '1' then
                acc_r   <= (others => '0');
                valid_r <= '0';
            elsif s1_bias = '1' then
                acc_r   <= s1_bias_val;
                valid_r <= '0';
            elsif s1_valid = '1' then
                acc_r   <= acc_r + resize(product_r, 32);
                valid_r <= '1';
            else
                valid_r <= '0';
            end if;
        end if;
        end if;
    end process p_etapa2;

    acc_out   <= acc_r;
    valid_out <= valid_r;

end architecture rtl;
