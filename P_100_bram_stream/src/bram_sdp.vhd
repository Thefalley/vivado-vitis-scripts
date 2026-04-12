library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_sdp: simple dual-port BRAM with independent write and read ports,
-- single clock domain. Write port: we + addr_wr + din. Read port: addr_rd
-- + dout (synchronous read, 1-cycle latency). Two separate clocked
-- processes sharing the ram signal is the canonical Xilinx SDP pattern
-- and infers a RAMB36E1/RAMB18E1 in SDP mode on 7-series.

entity bram_sdp is
    generic (
        DATA_WIDTH : integer := 32;
        ADDR_WIDTH : integer := 10
    );
    port (
        clk     : in  std_logic;
        we      : in  std_logic;
        addr_wr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        din     : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        addr_rd : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        dout    : out std_logic_vector(DATA_WIDTH - 1 downto 0)
    );
end bram_sdp;

architecture rtl of bram_sdp is
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
                ram(to_integer(unsigned(addr_wr))) <= din;
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            dout <= ram(to_integer(unsigned(addr_rd)));
        end if;
    end process;
end rtl;
