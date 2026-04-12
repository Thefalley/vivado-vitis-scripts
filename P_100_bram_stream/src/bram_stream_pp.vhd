library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_stream_pp: store-and-replay AXI-Stream module with TWO parallel
-- BRAMs ping-ponged to deliver 1 beat per cycle on the read side (vs
-- 1 beat per 2 cycles in plain bram_stream).
--
-- Storage is split by index parity:
--   index 0, 2, 4, ...  ->  bram_a
--   index 1, 3, 5, ...  ->  bram_b
--
-- During replay the FSM advances `q_a` only when outputting from A,
-- and `q_b` only when outputting from B, so both BRAMs see a new
-- address every 2 cycles but their outputs are interleaved 1 cycle
-- apart -- giving a single 1-beat/cycle stream at m_axis.
--
-- A 1-cycle S_PRIME state is inserted between S_WRITE and S_PUMP so
-- that bram_a_dout/bram_b_dout have latched the first two words
-- (ram_a[0]=word 0 and ram_b[0]=word 1) before S_PUMP starts
-- presenting tvalid=1.
--
-- Synthesis expectation on xc7z020 with ADDR_WIDTH=10, DATA_WIDTH=32:
--   - 2 RAMB36E1 (one per bram_sp instance, 1024x32 each)
--   - total effective depth = 2 * 1024 = 2048 words
--
-- Throughput:
--   write side: 1 beat/cycle when not in read phase (same as bram_stream)
--   read  side: 1 beat/cycle continuous (vs 1/2 cycles for bram_stream)

entity bram_stream_pp is
    generic (
        DATA_WIDTH : integer := 32;
        ADDR_WIDTH : integer := 10   -- per-bank; total depth = 2 * 2**ADDR_WIDTH
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
end bram_stream_pp;

architecture rtl of bram_stream_pp is
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

    signal zero_dest     : std_logic_vector(1 downto 0) := (others => '0');
    signal open_dest_in  : std_logic_vector(1 downto 0);
    signal open_dest_out : std_logic_vector(1 downto 0);

    -- BRAM A (even indices)
    signal bram_a_we   : std_logic;
    signal bram_a_addr : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal bram_a_din  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal bram_a_dout : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- BRAM B (odd indices)
    signal bram_b_we   : std_logic;
    signal bram_b_addr : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal bram_b_din  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal bram_b_dout : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- FSM
    type state_t is (S_WRITE, S_PRIME, S_PUMP);
    signal state : state_t := S_WRITE;

    -- wr_idx counts total words written (bit 0 picks bank, bits[top:1]
    -- are the half-address into the selected bank).
    signal wr_idx : unsigned(ADDR_WIDTH downto 0) := (others => '0');

    -- rd_idx counts total words emitted (same encoding as wr_idx).
    signal rd_idx : unsigned(ADDR_WIDTH downto 0) := (others => '0');

    -- Per-bank read pointers, advanced independently.
    signal q_a : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal q_b : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');

    -- count = index of the last word written (= wr_idx at tlast time).
    signal count : unsigned(ADDR_WIDTH downto 0) := (others => '0');

    signal handshake : std_logic;
begin
    ------------------------------------------------------------------
    -- Input skid buffer
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- BRAM A (even indices)
    ------------------------------------------------------------------
    bram_a_inst : entity work.bram_sp
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk  => clk,
            we   => bram_a_we,
            addr => bram_a_addr,
            din  => bram_a_din,
            dout => bram_a_dout
        );

    ------------------------------------------------------------------
    -- BRAM B (odd indices)
    ------------------------------------------------------------------
    bram_b_inst : entity work.bram_sp
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk  => clk,
            we   => bram_b_we,
            addr => bram_b_addr,
            din  => bram_b_din,
            dout => bram_b_dout
        );

    ------------------------------------------------------------------
    -- Output skid buffer
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- Combinational: skid handshakes, BRAM control
    ------------------------------------------------------------------
    win_tready <= '1' when state = S_WRITE else '0';

    -- Write: shared din, bank-specific WE based on wr_idx parity.
    bram_a_we  <= '1' when (state = S_WRITE and win_tvalid = '1' and wr_idx(0) = '0') else '0';
    bram_b_we  <= '1' when (state = S_WRITE and win_tvalid = '1' and wr_idx(0) = '1') else '0';
    bram_a_din <= win_tdata;
    bram_b_din <= win_tdata;

    -- Address mux: both banks use wr_idx[top:1] during writes, or their
    -- own per-bank read pointer during read phases.
    bram_a_addr <= std_logic_vector(wr_idx(ADDR_WIDTH downto 1)) when state = S_WRITE
                   else std_logic_vector(q_a);
    bram_b_addr <= std_logic_vector(wr_idx(ADDR_WIDTH downto 1)) when state = S_WRITE
                   else std_logic_vector(q_b);

    -- Output mux: pick the bank matching rd_idx parity
    wout_tdata  <= bram_a_dout when rd_idx(0) = '0' else bram_b_dout;
    wout_tvalid <= '1' when state = S_PUMP else '0';
    wout_tlast  <= '1' when (state = S_PUMP and rd_idx = count) else '0';

    handshake <= '1' when (state = S_PUMP and wout_tready = '1') else '0';

    ------------------------------------------------------------------
    -- FSM
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state  <= S_WRITE;
                wr_idx <= (others => '0');
                rd_idx <= (others => '0');
                q_a    <= (others => '0');
                q_b    <= (others => '0');
                count  <= (others => '0');
            else
                case state is
                    when S_WRITE =>
                        if win_tvalid = '1' and win_tready = '1' then
                            if win_tlast = '1' then
                                count  <= wr_idx;
                                wr_idx <= (others => '0');
                                rd_idx <= (others => '0');
                                q_a    <= (others => '0');
                                q_b    <= (others => '0');
                                state  <= S_PRIME;
                            else
                                wr_idx <= wr_idx + 1;
                            end if;
                        end if;

                    when S_PRIME =>
                        -- One-cycle warm-up: during this cycle the BRAM
                        -- processes latch bram_a_dout <= ram_a[0] and
                        -- bram_b_dout <= ram_b[0]. They will be stable
                        -- at the start of the first S_PUMP cycle.
                        state <= S_PUMP;

                    when S_PUMP =>
                        if handshake = '1' then
                            if rd_idx = count then
                                state  <= S_WRITE;
                                wr_idx <= (others => '0');
                            else
                                rd_idx <= rd_idx + 1;
                                if rd_idx(0) = '0' then
                                    q_a <= q_a + 1;
                                else
                                    q_b <= q_b + 1;
                                end if;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end rtl;
