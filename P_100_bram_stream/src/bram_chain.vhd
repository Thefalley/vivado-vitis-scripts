library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_chain: two bram_stream modules cascaded in series.
--
--   s_axis -> bram_stream_1 -> bram_stream_2 -> m_axis
--
-- Effect: each word that enters s_axis is stored in BRAM1, replayed
-- into BRAM2, and finally replayed on m_axis. End-to-end this behaves
-- as a store-and-replay delay line with a total effective buffer depth
-- of DEPTH1 + DEPTH2, using two independently-inferred Block RAMs.
--
-- Backpressure flows naturally through the chain via the tvalid/tready
-- handshakes: when bram_stream_2 is in read phase (replaying), its
-- s_axis_tready goes low, which stalls bram_stream_1's output, which
-- in turn stalls the upstream s_axis input.

entity bram_chain is
    generic (
        DATA_WIDTH : integer := 32;
        ADDR_WIDTH : integer := 10
    );
    port (
        clk    : in  std_logic;
        resetn : in  std_logic;

        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        m_axis_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end bram_chain;

architecture rtl of bram_chain is
    signal mid_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal mid_tlast  : std_logic;
    signal mid_tvalid : std_logic;
    signal mid_tready : std_logic;
begin
    u1 : entity work.bram_stream
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk           => clk,
            resetn        => resetn,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            m_axis_tdata  => mid_tdata,
            m_axis_tlast  => mid_tlast,
            m_axis_tvalid => mid_tvalid,
            m_axis_tready => mid_tready
        );

    u2 : entity work.bram_stream
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk           => clk,
            resetn        => resetn,
            s_axis_tdata  => mid_tdata,
            s_axis_tlast  => mid_tlast,
            s_axis_tvalid => mid_tvalid,
            s_axis_tready => mid_tready,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready
        );
end rtl;
