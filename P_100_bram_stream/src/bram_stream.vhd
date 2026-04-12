library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_stream: AXI-Stream store-and-replay backed by an inferred BRAM.
--
--   s_axis -> [SkidBuf IN] -> [FSM + BRAM] -> [SkidBuf OUT] -> m_axis
--
-- Behaviour:
--   - In WRITE state each accepted s_axis beat is written to BRAM at
--     wr_addr (0, 1, 2, ...). On the beat with tlast='1' the current
--     wr_addr is latched as `count` and the FSM switches to READ.
--   - In READ state the FSM issues BRAM reads at rd_addr = 0..count
--     and streams the data out via m_axis. On the last beat tlast='1'
--     is asserted and the FSM returns to WRITE.
--   - Single-port BRAM is enough because write and read phases are
--     mutually exclusive in time.
--
-- AXI-Stream compliance is provided by HsSkidBuf_dest on both sides
-- (2-deep skid buffer, breaks combinational paths on tvalid/tready).

entity bram_stream is
    generic (
        DATA_WIDTH : integer := 32;
        ADDR_WIDTH : integer := 10
    );
    port (
        clk    : in  std_logic;
        resetn : in  std_logic;

        -- AXI-Stream slave (input)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXI-Stream master (output)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end bram_stream;

architecture rtl of bram_stream is

    -- Input skid buffer (s_axis -> win_*)
    signal win_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal win_tlast  : std_logic;
    signal win_tvalid : std_logic;
    signal win_tready : std_logic;

    -- Output skid buffer (wout_* -> m_axis)
    signal wout_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal wout_tlast  : std_logic;
    signal wout_tvalid : std_logic;
    signal wout_tready : std_logic;

    -- Dummy tdest for HsSkidBuf_dest (generic >0 required)
    signal zero_dest     : std_logic_vector(1 downto 0) := (others => '0');
    signal open_dest_in  : std_logic_vector(1 downto 0);
    signal open_dest_out : std_logic_vector(1 downto 0);

    -- BRAM interface
    signal bram_addr : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal bram_we   : std_logic;
    signal bram_din  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal bram_dout : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- FSM
    type state_t is (S_WRITE, S_READ_ISSUE, S_READ_WAIT);
    signal state : state_t := S_WRITE;

    signal wr_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal rd_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal count   : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');

begin
    --------------------------------------------------------------------
    -- Input skid buffer
    --------------------------------------------------------------------
    skid_in_inst : entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH => DATA_WIDTH,
            DEST_WIDTH     => 2
        )
        port map (
            clk         => clk,
            s_hs_tdata  => s_axis_tdata,
            s_hs_tdest  => zero_dest,
            s_hs_tlast  => s_axis_tlast,
            s_hs_tvalid => s_axis_tvalid,
            s_hs_tready => s_axis_tready,
            m_hs_tdata  => win_tdata,
            m_hs_tdest  => open_dest_in,
            m_hs_tlast  => win_tlast,
            m_hs_tvalid => win_tvalid,
            m_hs_tready => win_tready
        );

    --------------------------------------------------------------------
    -- BRAM instance
    --------------------------------------------------------------------
    bram_inst : entity work.bram_sp
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk  => clk,
            we   => bram_we,
            addr => bram_addr,
            din  => bram_din,
            dout => bram_dout
        );

    --------------------------------------------------------------------
    -- Output skid buffer
    --------------------------------------------------------------------
    skid_out_inst : entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH => DATA_WIDTH,
            DEST_WIDTH     => 2
        )
        port map (
            clk         => clk,
            s_hs_tdata  => wout_tdata,
            s_hs_tdest  => zero_dest,
            s_hs_tlast  => wout_tlast,
            s_hs_tvalid => wout_tvalid,
            s_hs_tready => wout_tready,
            m_hs_tdata  => m_axis_tdata,
            m_hs_tdest  => open_dest_out,
            m_hs_tlast  => m_axis_tlast,
            m_hs_tvalid => m_axis_tvalid,
            m_hs_tready => m_axis_tready
        );

    --------------------------------------------------------------------
    -- FSM: write-then-read control
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state   <= S_WRITE;
                wr_addr <= (others => '0');
                rd_addr <= (others => '0');
                count   <= (others => '0');
            else
                case state is
                    when S_WRITE =>
                        if win_tvalid = '1' and win_tready = '1' then
                            if win_tlast = '1' then
                                count   <= wr_addr;
                                wr_addr <= (others => '0');
                                rd_addr <= (others => '0');
                                state   <= S_READ_ISSUE;
                            else
                                wr_addr <= wr_addr + 1;
                            end if;
                        end if;

                    when S_READ_ISSUE =>
                        -- BRAM read address is presented this cycle via
                        -- the combinational mux below; the registered
                        -- dout becomes valid next cycle.
                        state <= S_READ_WAIT;

                    when S_READ_WAIT =>
                        if wout_tready = '1' then
                            if rd_addr = count then
                                state <= S_WRITE;
                            else
                                rd_addr <= rd_addr + 1;
                                state   <= S_READ_ISSUE;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Combinational: BRAM mux + skid handshakes
    --------------------------------------------------------------------
    win_tready <= '1' when state = S_WRITE else '0';

    bram_we   <= '1' when (state = S_WRITE and win_tvalid = '1') else '0';
    bram_din  <= win_tdata;
    bram_addr <= std_logic_vector(wr_addr) when state = S_WRITE
                 else std_logic_vector(rd_addr);

    wout_tvalid <= '1' when state = S_READ_WAIT else '0';
    wout_tdata  <= bram_dout;
    wout_tlast  <= '1' when (state = S_READ_WAIT and rd_addr = count) else '0';

end rtl;
