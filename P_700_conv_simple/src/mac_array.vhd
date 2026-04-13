-------------------------------------------------------------------------------
-- mac_array.vhd — Array de 32 MACs en paralelo (Output Channel Parallelism)
-- COPIA EXACTA de P_13 (verificado en HW)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mac_array_pkg is
    constant N_MAC : natural := 32;
    type weight_array_t is array(0 to N_MAC-1) of signed(7 downto 0);
    type bias_array_t   is array(0 to N_MAC-1) of signed(31 downto 0);
    type acc_array_t    is array(0 to N_MAC-1) of signed(31 downto 0);
end package mac_array_pkg;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity mac_array is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        a_in      : in  signed(8 downto 0);
        b_in      : in  weight_array_t;
        bias_in   : in  bias_array_t;
        valid_in  : in  std_logic;
        load_bias : in  std_logic;
        clear     : in  std_logic;
        acc_out   : out acc_array_t;
        valid_out : out std_logic
    );
end entity mac_array;

architecture rtl of mac_array is
    type valid_array_t is array(0 to N_MAC-1) of std_logic;
    signal valid_arr : valid_array_t;
begin

    gen_macs : for i in 0 to N_MAC-1 generate
        u_mac : entity work.mac_unit
            port map (
                clk       => clk,
                rst_n     => rst_n,
                a_in      => a_in,
                b_in      => b_in(i),
                bias_in   => bias_in(i),
                valid_in  => valid_in,
                load_bias => load_bias,
                clear     => clear,
                acc_out   => acc_out(i),
                valid_out => valid_arr(i)
            );
    end generate gen_macs;

    valid_out <= valid_arr(0);

end architecture rtl;
