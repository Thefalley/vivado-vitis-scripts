library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- mult_stream: Wrapper AXI-Stream para mul_s32x32_pipe
--
-- Entrada (s_axis, 64 bits): A[63:32] | B[31:0]
-- Salida  (m_axis, 64 bits): P[63:0] = signed(A) * signed(B)
--
-- Pipeline de 5 ciclos (hereda del multiplicador).
-- TVALID y TLAST se pasan por un shift register de 5 etapas.
-- TREADY siempre '1' (fully pipelined, no stall).

entity mult_stream is
    port (
        clk           : in  std_logic;
        resetn        : in  std_logic;
        -- AXI-Stream slave (entrada)
        s_axis_tdata  : in  std_logic_vector(63 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        -- AXI-Stream master (salida)
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity;

architecture rtl of mult_stream is

    constant PIPE_DEPTH : integer := 5;

    -- Shift registers para valid y tlast
    signal valid_pipe : std_logic_vector(PIPE_DEPTH - 1 downto 0) := (others => '0');
    signal tlast_pipe : std_logic_vector(PIPE_DEPTH - 1 downto 0) := (others => '0');

    -- Senales internas
    signal a_signed : signed(31 downto 0);
    signal b_signed : signed(31 downto 0);
    signal p_signed : signed(63 downto 0);

begin

    -- Siempre listo (fully pipelined)
    s_axis_tready <= '1';

    -- Extraer operandos del stream
    a_signed <= signed(s_axis_tdata(63 downto 32));
    b_signed <= signed(s_axis_tdata(31 downto 0));

    -- Instanciar multiplicador
    u_mult : entity work.mul_s32x32_pipe
        port map (
            clk => clk,
            a   => a_signed,
            b   => b_signed,
            p   => p_signed
        );

    -- Resultado a stream
    m_axis_tdata <= std_logic_vector(p_signed);

    -- Pipeline de valid y tlast (5 etapas, sincronizado con el multiplicador)
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
