-------------------------------------------------------------------------------
-- requantize.vhd — Requantizacion INT32 -> INT8 (pipeline 8 etapas)
-- COPIA EXACTA de P_13 (verificado en HW: 1,025,696 tests, 0 errores)
-- Formula: y = clamp( ((acc * M0) + 2^(n-1)) >> n + y_zp, -128, 127 )
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity requantize is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        acc_in    : in  signed(31 downto 0);
        valid_in  : in  std_logic;
        M0        : in  unsigned(31 downto 0);
        n_shift   : in  unsigned(5 downto 0);
        y_zp      : in  signed(7 downto 0);
        y_out     : out signed(7 downto 0);
        valid_out : out std_logic
    );
end entity requantize;

architecture rtl of requantize is

    function make_round_val(n : unsigned(5 downto 0)) return signed is
        variable result : signed(63 downto 0) := (others => '0');
        variable pos    : natural;
    begin
        if unsigned(n) > 0 then
            pos := to_integer(n) - 1;
            result(pos) := '1';
        end if;
        return result;
    end function;

    signal m0_as_signed : signed(31 downto 0);
    signal mult_result : signed(63 downto 0);

    type pipe_n_array   is array(0 to 4) of unsigned(5 downto 0);
    type pipe_yzp_array is array(0 to 4) of signed(7 downto 0);

    signal mp_n     : pipe_n_array;
    signal mp_yzp   : pipe_yzp_array;
    signal mp_valid : std_logic_vector(4 downto 0);

    signal s6_rounded : signed(63 downto 0);
    signal s6_n       : unsigned(5 downto 0);
    signal s6_yzp     : signed(7 downto 0);
    signal s6_valid   : std_logic;

    signal s7_shifted : signed(31 downto 0);
    signal s7_yzp     : signed(7 downto 0);
    signal s7_valid   : std_logic;

begin

    m0_as_signed <= signed(std_logic_vector(M0));

    -- synthesis translate_off
    p_assert_m0 : process(M0)
    begin
        assert M0(31) = '0'
            report "requantize: M0 bit 31 != 0"
            severity error;
    end process p_assert_m0;
    -- synthesis translate_on

    u_mult : entity work.mul_s32x32_pipe
        port map (
            clk => clk,
            a   => acc_in,
            b   => m0_as_signed,
            p   => mult_result
        );

    p_param_pipe : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            mp_n     <= (others => (others => '0'));
            mp_yzp   <= (others => (others => '0'));
            mp_valid <= (others => '0');
        else
            mp_n(0)     <= n_shift;
            mp_yzp(0)   <= y_zp;
            mp_valid(0) <= valid_in;
            for i in 1 to 4 loop
                mp_n(i)     <= mp_n(i-1);
                mp_yzp(i)   <= mp_yzp(i-1);
                mp_valid(i) <= mp_valid(i-1);
            end loop;
        end if;
        end if;
    end process p_param_pipe;

    p_etapa6 : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s6_rounded <= (others => '0');
            s6_n       <= (others => '0');
            s6_yzp     <= (others => '0');
            s6_valid   <= '0';
        else
            s6_rounded <= mult_result + make_round_val(mp_n(4));
            s6_n       <= mp_n(4);
            s6_yzp     <= mp_yzp(4);
            s6_valid   <= mp_valid(4);
        end if;
        end if;
    end process p_etapa6;

    p_etapa7 : process(clk)
        variable shift_amount : natural;
        variable shifted_full : signed(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            s7_shifted <= (others => '0');
            s7_yzp     <= (others => '0');
            s7_valid   <= '0';
        else
            shift_amount := to_integer(s6_n);
            shifted_full := shift_right(s6_rounded, shift_amount);
            s7_shifted   <= shifted_full(31 downto 0);
            s7_yzp       <= s6_yzp;
            s7_valid     <= s6_valid;
        end if;
        end if;
    end process p_etapa7;

    p_etapa8 : process(clk)
        variable with_zp : signed(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            y_out     <= (others => '0');
            valid_out <= '0';
        else
            with_zp := s7_shifted + resize(s7_yzp, 32);
            if with_zp > to_signed(127, 32) then
                y_out <= to_signed(127, 8);
            elsif with_zp < to_signed(-128, 32) then
                y_out <= to_signed(-128, 8);
            else
                y_out <= with_zp(7 downto 0);
            end if;
            valid_out <= s7_valid;
        end if;
        end if;
    end process p_etapa8;

end architecture rtl;
