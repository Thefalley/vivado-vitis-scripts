library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- elem_add_stream: Wrapper AXI-Stream para elem_add
--
-- Parametros hardcoded como generics (layer_017 YOLOv4).
-- Stream 32 bits: a_in en bits [7:0], b_in en bits [15:8], y_out en bits [7:0].
-- Pipeline valid/tlast de 8 ciclos (latencia elem_add).

entity elem_add_stream is
    generic (
        A_ZP    : integer  := -102;
        B_ZP    : integer  := -97;
        Y_ZP    : integer  := -102;
        M0_A_G  : natural  := 605961470;
        M0_B_G  : natural  := 715593500;
        N_SHIFT : natural  := 30
    );
    port (
        clk           : in  std_logic;
        resetn        : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity;

architecture rtl of elem_add_stream is

    constant PIPE_DEPTH : integer := 8;

    signal valid_pipe : std_logic_vector(PIPE_DEPTH - 1 downto 0) := (others => '0');
    signal tlast_pipe : std_logic_vector(PIPE_DEPTH - 1 downto 0) := (others => '0');

    signal a_in  : signed(7 downto 0);
    signal b_in  : signed(7 downto 0);
    signal y_out : signed(7 downto 0);

begin

    s_axis_tready <= '1';

    a_in <= signed(s_axis_tdata(7 downto 0));
    b_in <= signed(s_axis_tdata(15 downto 8));

    u_ea : entity work.elem_add
        port map (
            clk       => clk,
            rst_n     => resetn,
            a_in      => a_in,
            b_in      => b_in,
            valid_in  => s_axis_tvalid,
            a_zp      => to_signed(A_ZP, 8),
            b_zp      => to_signed(B_ZP, 8),
            y_zp      => to_signed(Y_ZP, 8),
            M0_a      => to_unsigned(M0_A_G, 32),
            M0_b      => to_unsigned(M0_B_G, 32),
            n_shift   => to_unsigned(N_SHIFT, 6),
            y_out     => y_out,
            valid_out => open
        );

    m_axis_tdata <= x"000000" & std_logic_vector(y_out);

    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                valid_pipe <= (others => '0');
                tlast_pipe <= (others => '0');
            else
                valid_pipe <= valid_pipe(PIPE_DEPTH - 2 downto 0) & s_axis_tvalid;
                tlast_pipe <= tlast_pipe(PIPE_DEPTH - 2 downto 0) & s_axis_tlast;
            end if;
        end if;
    end process;

    m_axis_tvalid <= valid_pipe(PIPE_DEPTH - 1);
    m_axis_tlast  <= tlast_pipe(PIPE_DEPTH - 1);

end architecture;
