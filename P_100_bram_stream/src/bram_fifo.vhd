library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_fifo: AXI-Stream FIFO backed by a simple dual-port BRAM.
--
-- Unlike bram_stream (which is a batch store-and-replay), this is a
-- classic pointer-based FIFO: writes and reads are independent and
-- concurrent. A word pushed on s_axis becomes visible on m_axis as
-- soon as the read pipeline has caught up to it (no wait for tlast).
--
-- Depth = 2**ADDR_WIDTH entries. Each entry stores tdata + tlast in
-- a single (DATA_WIDTH+1)-wide BRAM row, so the internal bram_sdp is
-- instantiated with DATA_WIDTH+1 bits of width.
--
-- Full/empty detection uses wrap-bit pointers (MSB toggles each time
-- the pointer wraps around) — the classic "pointer + wrap bit" trick:
--   empty : wr_ptr == rd_ptr
--   full  : wr_ptr[MSB] != rd_ptr[MSB] && wr_ptr[MSB-1:0] == rd_ptr[MSB-1:0]
--
-- Read throughput is 1 beat every 2 cycles (the R_IDLE/R_WAIT FSM
-- absorbs the 1-cycle BRAM read latency simply; the output HsSkidBuf
-- smooths the pulsed tvalid into a well-behaved AXI-Stream master).
-- Write throughput is 1 beat/cycle when not full. This is enough for
-- a proof-of-concept FIFO; full-throughput reads would need a 2-deep
-- pipeline between BRAM and the skid buffer, which is a localised
-- refactor on the read-side FSM only.

entity bram_fifo is
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
end bram_fifo;

architecture rtl of bram_fifo is
    constant W : integer := DATA_WIDTH + 1;  -- +1 bit for tlast

    signal wr_ptr : unsigned(ADDR_WIDTH downto 0) := (others => '0');
    signal rd_ptr : unsigned(ADDR_WIDTH downto 0) := (others => '0');

    signal fifo_full  : std_logic;
    signal fifo_empty : std_logic;

    -- BRAM interface (width = DATA_WIDTH + 1 to carry tlast alongside tdata)
    signal bram_we      : std_logic;
    signal bram_addr_wr : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal bram_addr_rd : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal bram_din     : std_logic_vector(W - 1 downto 0);
    signal bram_dout    : std_logic_vector(W - 1 downto 0);

    -- Output skid buffer (to drive m_axis cleanly)
    signal skid_s_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal skid_s_tlast  : std_logic := '0';
    signal skid_s_tvalid : std_logic := '0';
    signal skid_s_tready : std_logic;
    signal zero_dest     : std_logic_vector(1 downto 0) := (others => '0');
    signal open_dest_out : std_logic_vector(1 downto 0);

    -- Read FSM
    type rstate_t is (R_IDLE, R_WAIT);
    signal rstate : rstate_t := R_IDLE;

    signal s_accept : std_logic;
begin
    --------------------------------------------------------------------
    -- Full / empty flags
    --------------------------------------------------------------------
    fifo_full <= '1' when (wr_ptr(ADDR_WIDTH) /= rd_ptr(ADDR_WIDTH))
                      and (wr_ptr(ADDR_WIDTH - 1 downto 0) =
                           rd_ptr(ADDR_WIDTH - 1 downto 0))
                 else '0';
    fifo_empty <= '1' when wr_ptr = rd_ptr else '0';

    --------------------------------------------------------------------
    -- Write side (full throughput)
    --------------------------------------------------------------------
    s_axis_tready <= not fifo_full;
    s_accept      <= s_axis_tvalid and (not fifo_full);

    bram_we       <= s_accept;
    bram_addr_wr  <= std_logic_vector(wr_ptr(ADDR_WIDTH - 1 downto 0));
    bram_din      <= s_axis_tlast & s_axis_tdata;

    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                wr_ptr <= (others => '0');
            elsif s_accept = '1' then
                wr_ptr <= wr_ptr + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- BRAM
    --------------------------------------------------------------------
    bram_inst : entity work.bram_sdp
        generic map (
            DATA_WIDTH => W,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk     => clk,
            we      => bram_we,
            addr_wr => bram_addr_wr,
            din     => bram_din,
            addr_rd => bram_addr_rd,
            dout    => bram_dout
        );

    --------------------------------------------------------------------
    -- Read FSM: issue one read, wait a cycle, push to skid
    --------------------------------------------------------------------
    bram_addr_rd <= std_logic_vector(rd_ptr(ADDR_WIDTH - 1 downto 0));

    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                rstate        <= R_IDLE;
                rd_ptr        <= (others => '0');
                skid_s_tvalid <= '0';
            else
                case rstate is
                    when R_IDLE =>
                        skid_s_tvalid <= '0';
                        if fifo_empty = '0' and skid_s_tready = '1' then
                            rstate <= R_WAIT;
                        end if;

                    when R_WAIT =>
                        -- bram_dout is now the word at rd_ptr (BRAM
                        -- read took 1 cycle). Push it into the skid
                        -- buffer; since skid_s_tready was 1 last cycle
                        -- and we did not push then, at least one slot
                        -- is still free (2-deep buffer).
                        skid_s_tdata  <= bram_dout(DATA_WIDTH - 1 downto 0);
                        skid_s_tlast  <= bram_dout(DATA_WIDTH);
                        skid_s_tvalid <= '1';
                        rd_ptr        <= rd_ptr + 1;
                        rstate        <= R_IDLE;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Output skid buffer -> m_axis
    --------------------------------------------------------------------
    skid_out_inst : entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH => DATA_WIDTH,
            DEST_WIDTH     => 2
        )
        port map (
            clk         => clk,
            s_hs_tdata  => skid_s_tdata,
            s_hs_tdest  => zero_dest,
            s_hs_tlast  => skid_s_tlast,
            s_hs_tvalid => skid_s_tvalid,
            s_hs_tready => skid_s_tready,
            m_hs_tdata  => m_axis_tdata,
            m_hs_tdest  => open_dest_out,
            m_hs_tlast  => m_axis_tlast,
            m_hs_tvalid => m_axis_tvalid,
            m_hs_tready => m_axis_tready
        );
end rtl;
