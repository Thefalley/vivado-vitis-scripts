library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_ctrl_fifo: control wrapper around fifo_2x40_bram.
--
-- Adds a state machine that gates the AXI-Stream interfaces to enforce
-- explicit load/drain phasing via control pulses.
--
-- States:
--   S_IDLE  (00): both s_axis and m_axis blocked.
--   S_LOAD  (01): s_axis forwarded to inner FIFO (producer writes).
--                  m_axis blocked. When inner FIFO receives tlast the
--                  wrapper automatically returns to S_IDLE.
--   S_DRAIN (10): m_axis forwarded from inner FIFO (consumer reads).
--                  s_axis blocked. When inner FIFO emits tlast on
--                  m_axis the wrapper automatically returns to S_IDLE.
--   S_STOP  (11): everything blocked. Returns to S_IDLE when ctrl_stop
--                  is deasserted.
--
-- The inner fifo_2x40_bram is a batch store-and-replay buffer with 80
-- BRAMs (2 chains x 40 banks).

entity bram_ctrl_fifo is
    generic (
        DATA_WIDTH  : integer := 32;
        BANK_ADDR_W : integer := 10;
        N_BANKS     : integer := 40
    );
    port (
        clk    : in  std_logic;
        resetn : in  std_logic;

        -- AXI-Stream slave (data in)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXI-Stream master (data out)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;

        -- Control signals
        ctrl_load  : in  std_logic;   -- pulse: S_IDLE -> S_LOAD
        ctrl_drain : in  std_logic;   -- pulse: S_IDLE -> S_DRAIN
        ctrl_stop  : in  std_logic;   -- level: any -> S_STOP; release -> S_IDLE
        ctrl_state : out std_logic_vector(1 downto 0)  -- current state readback
    );
end bram_ctrl_fifo;

architecture rtl of bram_ctrl_fifo is

    type ctrl_state_t is (S_IDLE, S_LOAD, S_DRAIN, S_STOP);
    signal state : ctrl_state_t := S_IDLE;

    -- Inner FIFO connections
    signal fi_s_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal fi_s_tlast  : std_logic;
    signal fi_s_tvalid : std_logic;
    signal fi_s_tready : std_logic;

    signal fi_m_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal fi_m_tlast  : std_logic;
    signal fi_m_tvalid : std_logic;
    signal fi_m_tready : std_logic;

    -- Detect handshakes with tlast
    signal load_done  : std_logic;
    signal drain_done : std_logic;

begin

    ----------------------------------------------------------------
    -- Inner FIFO instantiation
    ----------------------------------------------------------------
    fifo_inst : entity work.fifo_2x40_bram
        generic map (
            DATA_WIDTH  => DATA_WIDTH,
            BANK_ADDR_W => BANK_ADDR_W,
            N_BANKS     => N_BANKS
        )
        port map (
            clk           => clk,
            resetn        => resetn,
            s_axis_tdata  => fi_s_tdata,
            s_axis_tlast  => fi_s_tlast,
            s_axis_tvalid => fi_s_tvalid,
            s_axis_tready => fi_s_tready,
            m_axis_tdata  => fi_m_tdata,
            m_axis_tlast  => fi_m_tlast,
            m_axis_tvalid => fi_m_tvalid,
            m_axis_tready => fi_m_tready
        );

    ----------------------------------------------------------------
    -- AXI-Stream gating
    ----------------------------------------------------------------

    -- s_axis -> inner FIFO s_axis (only in S_LOAD)
    fi_s_tdata  <= s_axis_tdata;
    fi_s_tlast  <= s_axis_tlast when state = S_LOAD else '0';
    fi_s_tvalid <= s_axis_tvalid when state = S_LOAD else '0';
    s_axis_tready <= fi_s_tready when state = S_LOAD else '0';

    -- inner FIFO m_axis -> m_axis (only in S_DRAIN)
    m_axis_tdata  <= fi_m_tdata;
    m_axis_tlast  <= fi_m_tlast when state = S_DRAIN else '0';
    m_axis_tvalid <= fi_m_tvalid when state = S_DRAIN else '0';
    fi_m_tready   <= m_axis_tready when state = S_DRAIN else '0';

    ----------------------------------------------------------------
    -- Phase-complete detection
    ----------------------------------------------------------------
    -- Load is done when the inner FIFO accepts the beat with tlast
    load_done  <= '1' when (state = S_LOAD and
                            fi_s_tvalid = '1' and fi_s_tready = '1' and
                            fi_s_tlast = '1') else '0';

    -- Drain is done when the output emits the beat with tlast
    drain_done <= '1' when (state = S_DRAIN and
                            fi_m_tvalid = '1' and fi_m_tready = '1' and
                            fi_m_tlast = '1') else '0';

    ----------------------------------------------------------------
    -- State encoding for readback
    ----------------------------------------------------------------
    ctrl_state <= "00" when state = S_IDLE  else
                  "01" when state = S_LOAD  else
                  "10" when state = S_DRAIN else
                  "11"; -- S_STOP

    ----------------------------------------------------------------
    -- Control FSM
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state <= S_IDLE;
            else
                case state is
                    when S_IDLE =>
                        if ctrl_stop = '1' then
                            state <= S_STOP;
                        elsif ctrl_load = '1' then
                            state <= S_LOAD;
                        elsif ctrl_drain = '1' then
                            state <= S_DRAIN;
                        end if;

                    when S_LOAD =>
                        if ctrl_stop = '1' then
                            state <= S_STOP;
                        elsif load_done = '1' then
                            state <= S_IDLE;
                        end if;

                    when S_DRAIN =>
                        if ctrl_stop = '1' then
                            state <= S_STOP;
                        elsif drain_done = '1' then
                            state <= S_IDLE;
                        end if;

                    when S_STOP =>
                        if ctrl_stop = '0' then
                            state <= S_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;
