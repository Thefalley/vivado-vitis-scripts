library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- fifo_2x40_bram: store-and-replay AXI-Stream buffer with two parallel
-- chains of N_BANKS BRAMs each (default 40), for a total of 2 * 40 = 80
-- RAMB36E1 on xc7z020.
--
-- This is NOT a concurrent rd/wr FIFO: it is a BATCH loader. The
-- behaviour is two strictly alternating phases:
--
--   phase 1 (S_WRITE): s_axis accepts beats until tlast. During this
--     phase m_axis is silent (tvalid='0'). The beats are distributed
--     via ping-pong between chain A and chain B (even index -> A,
--     odd index -> B) so that replay can later emit 1 word/cycle.
--
--   phase 2 (S_PRIME + S_PUMP): after tlast the module enters a
--     1-cycle prime followed by a pump phase where m_axis emits the
--     stored beats in the exact order they came in, at 1 word/cycle
--     (thanks to ping-pong between A and B). s_axis is closed during
--     this phase (tready='0').
--
-- Effective per-batch capacity = 2 * N_BANKS * 2^BANK_ADDR_W
--                              = 2 * 40 * 1024 = 81920 words.
--
-- Top-level architecture:
--
--   s_axis -> skid_in -> FSM -> chain A: bram_a[0..39] -\
--                                                        > mux -> skid_out -> m_axis
--                             -> chain B: bram_b[0..39] -/
--
-- Within a chain, words are laid out sequentially: position p lives
-- in bank = p / BANK_DEPTH at offset p mod BANK_DEPTH. Only the bank
-- matching the current position has we=1 during writes, and its dout
-- is selected via a N_BANKS:1 mux during reads.
--
-- Ping-pong:
--   write: beats alternate A and B, wr_chain_sel toggles
--   read:  beats emit A and B alternately, rd_count(0) selects the
--          chain; because each chain issues 1 read every 2 cycles and
--          the two chains are naturally 1 cycle out of phase, the
--          aggregate output is 1 word/cycle with m_axis_tvalid held
--          continuously through the replay.
--
-- Suited for the "drip feed" use case: load N words of weights,
-- then on demand drain them out to a downstream consumer (DPU).
-- A thin control wrapper can gate s_axis and m_axis to enforce
-- load / drain phasing externally.

entity fifo_2x40_bram is
    generic (
        DATA_WIDTH  : integer := 32;
        BANK_ADDR_W : integer := 10;
        N_BANKS     : integer := 40
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
end fifo_2x40_bram;

architecture rtl of fifo_2x40_bram is
    constant BANK_SEL_W  : integer := 6;
    constant POS_WIDTH   : integer := BANK_SEL_W + BANK_ADDR_W;
    constant TOTAL_WIDTH : integer := POS_WIDTH + 1;

    type bank_data_t is array (0 to N_BANKS - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);

    signal a_bank_dout : bank_data_t;
    signal a_we_vec    : std_logic_vector(N_BANKS - 1 downto 0);
    signal a_addr      : std_logic_vector(BANK_ADDR_W - 1 downto 0);
    signal a_din       : std_logic_vector(DATA_WIDTH - 1 downto 0);

    signal b_bank_dout : bank_data_t;
    signal b_we_vec    : std_logic_vector(N_BANKS - 1 downto 0);
    signal b_addr      : std_logic_vector(BANK_ADDR_W - 1 downto 0);
    signal b_din       : std_logic_vector(DATA_WIDTH - 1 downto 0);

    signal win_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal win_tlast  : std_logic;
    signal win_tvalid : std_logic;
    signal win_tready : std_logic;

    signal wout_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal wout_tlast  : std_logic;
    signal wout_tvalid : std_logic;
    signal wout_tready : std_logic;

    signal zero_dest     : std_logic_vector(1 downto 0) := (others => '0');
    signal open_dest_in  : std_logic_vector(1 downto 0);
    signal open_dest_out : std_logic_vector(1 downto 0);

    signal a_wr_pos : unsigned(POS_WIDTH - 1 downto 0) := (others => '0');
    signal b_wr_pos : unsigned(POS_WIDTH - 1 downto 0) := (others => '0');
    signal a_rd_pos : unsigned(POS_WIDTH - 1 downto 0) := (others => '0');
    signal b_rd_pos : unsigned(POS_WIDTH - 1 downto 0) := (others => '0');

    signal a_wr_bank   : unsigned(BANK_SEL_W - 1 downto 0);
    signal a_wr_addr_s : unsigned(BANK_ADDR_W - 1 downto 0);
    signal a_rd_bank   : unsigned(BANK_SEL_W - 1 downto 0);
    signal a_rd_addr_s : unsigned(BANK_ADDR_W - 1 downto 0);
    signal b_wr_bank   : unsigned(BANK_SEL_W - 1 downto 0);
    signal b_wr_addr_s : unsigned(BANK_ADDR_W - 1 downto 0);
    signal b_rd_bank   : unsigned(BANK_SEL_W - 1 downto 0);
    signal b_rd_addr_s : unsigned(BANK_ADDR_W - 1 downto 0);

    signal rd_count    : unsigned(TOTAL_WIDTH - 1 downto 0) := (others => '0');
    signal count_total : unsigned(TOTAL_WIDTH - 1 downto 0) := (others => '0');

    type state_t is (S_WRITE, S_PRIME, S_PUMP);
    signal state : state_t := S_WRITE;

    signal wr_chain_sel : std_logic := '0';
    signal handshake    : std_logic;
begin
    ------------------------------------------------------------------
    -- Input skid buffer
    ------------------------------------------------------------------
    skid_in_inst : entity work.HsSkidBuf_dest
        generic map (HS_TDATA_WIDTH => DATA_WIDTH, DEST_WIDTH => 2)
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
    -- Output skid buffer
    ------------------------------------------------------------------
    skid_out_inst : entity work.HsSkidBuf_dest
        generic map (HS_TDATA_WIDTH => DATA_WIDTH, DEST_WIDTH => 2)
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
    -- Generate 80 bram_sp instances
    ------------------------------------------------------------------
    gen_a : for i in 0 to N_BANKS - 1 generate
        bram_ai : entity work.bram_sp
            generic map (DATA_WIDTH => DATA_WIDTH, ADDR_WIDTH => BANK_ADDR_W)
            port map (clk => clk, we => a_we_vec(i), addr => a_addr, din => a_din, dout => a_bank_dout(i));
    end generate;
    gen_b : for i in 0 to N_BANKS - 1 generate
        bram_bi : entity work.bram_sp
            generic map (DATA_WIDTH => DATA_WIDTH, ADDR_WIDTH => BANK_ADDR_W)
            port map (clk => clk, we => b_we_vec(i), addr => b_addr, din => b_din, dout => b_bank_dout(i));
    end generate;

    ------------------------------------------------------------------
    -- Pointer slicing
    ------------------------------------------------------------------
    a_wr_bank   <= a_wr_pos(POS_WIDTH - 1 downto BANK_ADDR_W);
    a_wr_addr_s <= a_wr_pos(BANK_ADDR_W - 1 downto 0);
    a_rd_bank   <= a_rd_pos(POS_WIDTH - 1 downto BANK_ADDR_W);
    a_rd_addr_s <= a_rd_pos(BANK_ADDR_W - 1 downto 0);
    b_wr_bank   <= b_wr_pos(POS_WIDTH - 1 downto BANK_ADDR_W);
    b_wr_addr_s <= b_wr_pos(BANK_ADDR_W - 1 downto 0);
    b_rd_bank   <= b_rd_pos(POS_WIDTH - 1 downto BANK_ADDR_W);
    b_rd_addr_s <= b_rd_pos(BANK_ADDR_W - 1 downto 0);

    ------------------------------------------------------------------
    -- Combinational control
    ------------------------------------------------------------------
    win_tready <= '1' when state = S_WRITE else '0';

    a_addr <= std_logic_vector(a_wr_addr_s) when state = S_WRITE
              else std_logic_vector(a_rd_addr_s);
    b_addr <= std_logic_vector(b_wr_addr_s) when state = S_WRITE
              else std_logic_vector(b_rd_addr_s);

    a_din <= win_tdata;
    b_din <= win_tdata;

    we_gen : process(state, win_tvalid, wr_chain_sel, a_wr_bank, b_wr_bank)
    begin
        a_we_vec <= (others => '0');
        b_we_vec <= (others => '0');
        if state = S_WRITE and win_tvalid = '1' then
            if wr_chain_sel = '0' then
                a_we_vec(to_integer(a_wr_bank)) <= '1';
            else
                b_we_vec(to_integer(b_wr_bank)) <= '1';
            end if;
        end if;
    end process;

    wout_tdata  <= a_bank_dout(to_integer(a_rd_bank)) when rd_count(0) = '0'
                   else b_bank_dout(to_integer(b_rd_bank));
    wout_tvalid <= '1' when state = S_PUMP else '0';
    wout_tlast  <= '1' when (state = S_PUMP and
                             count_total > 0 and
                             rd_count = count_total - 1) else '0';

    handshake <= '1' when (state = S_PUMP and wout_tready = '1') else '0';

    ------------------------------------------------------------------
    -- FSM
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state        <= S_WRITE;
                a_wr_pos     <= (others => '0');
                b_wr_pos     <= (others => '0');
                a_rd_pos     <= (others => '0');
                b_rd_pos     <= (others => '0');
                rd_count     <= (others => '0');
                count_total  <= (others => '0');
                wr_chain_sel <= '0';
            else
                case state is
                    when S_WRITE =>
                        if win_tvalid = '1' and win_tready = '1' then
                            if win_tlast = '1' then
                                count_total <=
                                    resize(a_wr_pos, TOTAL_WIDTH) +
                                    resize(b_wr_pos, TOTAL_WIDTH) + 1;
                                a_wr_pos     <= (others => '0');
                                b_wr_pos     <= (others => '0');
                                a_rd_pos     <= (others => '0');
                                b_rd_pos     <= (others => '0');
                                rd_count     <= (others => '0');
                                wr_chain_sel <= '0';
                                state        <= S_PRIME;
                            else
                                if wr_chain_sel = '0' then
                                    a_wr_pos <= a_wr_pos + 1;
                                else
                                    b_wr_pos <= b_wr_pos + 1;
                                end if;
                                wr_chain_sel <= not wr_chain_sel;
                            end if;
                        end if;

                    when S_PRIME =>
                        state <= S_PUMP;

                    when S_PUMP =>
                        if handshake = '1' then
                            if rd_count = count_total - 1 then
                                state  <= S_WRITE;
                                wr_chain_sel <= '0';
                            else
                                rd_count <= rd_count + 1;
                                if rd_count(0) = '0' then
                                    a_rd_pos <= a_rd_pos + 1;
                                else
                                    b_rd_pos <= b_rd_pos + 1;
                                end if;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end rtl;
