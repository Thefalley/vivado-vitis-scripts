library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_sp: single-port BRAM inferrable module.
-- Canonical pattern: array + synchronous write + synchronous read with
-- read-before-write behavior. ram_style attribute forces Block RAM
-- inference (so Vivado cannot collapse it into distributed LUTRAM).
--
-- With DEPTH = 2**ADDR_WIDTH (default 1024) and DATA_WIDTH = 32 it fits
-- exactly in one RAMB36E1 (or two RAMB18E1) on the xc7z020.

entity bram_sp is
    generic (
        DATA_WIDTH : integer := 32;
        ADDR_WIDTH : integer := 10
    );
    port (
        clk  : in  std_logic;
        we   : in  std_logic;
        addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        din  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        dout : out std_logic_vector(DATA_WIDTH - 1 downto 0)
    );
end bram_sp;

architecture rtl of bram_sp is
    type ram_type is array (0 to (2**ADDR_WIDTH) - 1) of
        std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal ram : ram_type := (others => (others => '0'));

    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                ram(to_integer(unsigned(addr))) <= din;
            end if;
            dout <= ram(to_integer(unsigned(addr)));
        end if;
    end process;
end rtl;
