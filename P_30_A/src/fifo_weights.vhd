library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- fifo_weights: BRAM-based FIFO that accepts 32-bit words from AXI-Stream
-- (DMA MM2S) and outputs one byte at a time for writing into wb_ram.
--
-- Write side: 32-bit words stored in a circular BRAM buffer.
-- Read side:  reads one 32-bit word, deserializes to 4 bytes (LSB first),
--             then fetches the next word.
--
-- Backpressure: s_axis_tready='0' when full, m_valid='0' when empty.
-- BRAM inference: simple dual-port via ram_t array of std_logic_vector.

entity fifo_weights is
    generic (
        DEPTH_LOG2 : natural := 9  -- 2^9 = 512 words = 2 KB FIFO
    );
    port (
        clk    : in  std_logic;
        rst_n  : in  std_logic;

        -- AXI-Stream input (from DMA MM2S)
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- Output to wb_ram write port (byte-by-byte)
        m_data  : out std_logic_vector(7 downto 0);
        m_valid : out std_logic;
        m_ready : in  std_logic;

        -- Status
        empty : out std_logic;
        full  : out std_logic
    );
end entity;

architecture rtl of fifo_weights is

    constant DEPTH : natural := 2 ** DEPTH_LOG2;

    -- BRAM storage (Vivado infers BRAM from this pattern)
    type ram_t is array (0 to DEPTH - 1) of std_logic_vector(31 downto 0);
    signal ram : ram_t;

    -- Write and read pointers (one extra bit for full/empty distinction)
    signal wr_ptr : unsigned(DEPTH_LOG2 downto 0) := (others => '0');
    signal rd_ptr : unsigned(DEPTH_LOG2 downto 0) := (others => '0');

    -- FIFO status
    signal fifo_full  : std_logic;
    signal fifo_empty : std_logic;

    -- Read-side word register and byte selector
    signal word_buf   : std_logic_vector(31 downto 0) := (others => '0');
    signal byte_idx   : unsigned(1 downto 0) := (others => '0');
    signal word_valid : std_logic := '0';  -- '1' when word_buf holds valid data

    -- BRAM read port (1-cycle latency)
    signal rd_addr    : unsigned(DEPTH_LOG2 - 1 downto 0);
    signal ram_dout   : std_logic_vector(31 downto 0);
    signal rd_pending : std_logic := '0';  -- a BRAM read is in flight

begin

    ---------------------------------------------------------------------------
    -- Pointer comparison for full / empty
    ---------------------------------------------------------------------------
    fifo_full  <= '1' when (wr_ptr(DEPTH_LOG2) /= rd_ptr(DEPTH_LOG2)) and
                           (wr_ptr(DEPTH_LOG2 - 1 downto 0) = rd_ptr(DEPTH_LOG2 - 1 downto 0))
                  else '0';
    fifo_empty <= '1' when wr_ptr = rd_ptr else '0';

    full  <= fifo_full;
    empty <= fifo_empty;

    s_axis_tready <= not fifo_full;

    rd_addr <= rd_ptr(DEPTH_LOG2 - 1 downto 0);

    ---------------------------------------------------------------------------
    -- Write side: store 32-bit words into BRAM
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                wr_ptr <= (others => '0');
            else
                if s_axis_tvalid = '1' and fifo_full = '0' then
                    ram(to_integer(wr_ptr(DEPTH_LOG2 - 1 downto 0))) <= s_axis_tdata;
                    wr_ptr <= wr_ptr + 1;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- BRAM read port (1-cycle latency)
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            ram_dout <= ram(to_integer(rd_addr));
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Read side: fetch word from BRAM, deserialize to 4 bytes (LSB first)
    ---------------------------------------------------------------------------
    -- State machine:
    --   word_valid='0', rd_pending='0' : idle, if FIFO not empty -> issue read
    --   word_valid='0', rd_pending='1' : waiting for BRAM latency
    --   word_valid='1'                 : outputting bytes 0..3
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rd_ptr     <= (others => '0');
                word_buf   <= (others => '0');
                byte_idx   <= (others => '0');
                word_valid <= '0';
                rd_pending <= '0';
            else
                -- Default: hold state

                if word_valid = '0' and rd_pending = '0' then
                    -- Need a new word; issue BRAM read if FIFO has data
                    if fifo_empty = '0' then
                        rd_pending <= '1';
                        rd_ptr     <= rd_ptr + 1;  -- advance now; BRAM reads rd_addr combinationally
                    end if;

                elsif word_valid = '0' and rd_pending = '1' then
                    -- BRAM data available this cycle
                    word_buf   <= ram_dout;
                    byte_idx   <= "00";
                    word_valid <= '1';
                    rd_pending <= '0';

                elsif word_valid = '1' then
                    -- Outputting bytes
                    if m_ready = '1' then
                        if byte_idx = "11" then
                            -- Last byte consumed; try to prefetch next word
                            word_valid <= '0';
                            if fifo_empty = '0' then
                                rd_pending <= '1';
                                rd_ptr     <= rd_ptr + 1;
                            end if;
                        else
                            byte_idx <= byte_idx + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output byte mux (LSB first: byte 0 = bits 7..0)
    ---------------------------------------------------------------------------
    process (word_valid, word_buf, byte_idx)
    begin
        m_valid <= word_valid;
        case byte_idx is
            when "00"   => m_data <= word_buf( 7 downto  0);
            when "01"   => m_data <= word_buf(15 downto  8);
            when "10"   => m_data <= word_buf(23 downto 16);
            when others => m_data <= word_buf(31 downto 24);
        end case;
    end process;

end rtl;
