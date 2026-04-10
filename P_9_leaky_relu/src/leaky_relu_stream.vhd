library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- leaky_relu_stream: Wrapper AXI-Stream para leaky_relu
--
-- Parametros hardcoded como generics (layer_006 YOLOv4).
-- Stream 32 bits: x_in en bits [7:0], y_out en bits [7:0].
-- Pipeline valid/tlast de 8 ciclos (latencia leaky_relu).

entity leaky_relu_stream is
    generic (
        X_ZP   : integer  := -17;
        Y_ZP   : integer  := -110;
        M0_POS : natural  := 881676063;
        M0_NEG : natural  := 705340861;
        N_POS  : natural  := 29;
        N_NEG  : natural  := 32
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

architecture rtl of leaky_relu_stream is

    constant PIPE_DEPTH : integer := 8;

    signal valid_pipe : std_logic_vector(PIPE_DEPTH - 1 downto 0) := (others => '0');
    signal tlast_pipe : std_logic_vector(PIPE_DEPTH - 1 downto 0) := (others => '0');

    signal x_in  : signed(7 downto 0);
    signal y_out : signed(7 downto 0);

begin

    s_axis_tready <= '1';

    x_in <= signed(s_axis_tdata(7 downto 0));

    u_lr : entity work.leaky_relu
        port map (
            clk       => clk,
            rst_n     => resetn,
            x_in      => x_in,
            valid_in  => s_axis_tvalid,
            x_zp      => to_signed(X_ZP, 8),
            y_zp      => to_signed(Y_ZP, 8),
            M0_pos    => to_unsigned(M0_POS, 32),
            n_pos     => to_unsigned(N_POS, 6),
            M0_neg    => to_unsigned(M0_NEG, 32),
            n_neg     => to_unsigned(N_NEG, 6),
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
