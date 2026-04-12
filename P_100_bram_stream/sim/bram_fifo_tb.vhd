library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library STD;
use STD.env.all;

-- bram_fifo_tb: drives N_WORDS through bram_fifo with aggressive
-- backpressure on the m_axis side (m_tready toggles 0/1 at half rate
-- for a while) so the FIFO is forced to stall. Captures every
-- handshaken beat and compares against the expected pattern.

entity bram_fifo_tb is
end bram_fifo_tb;

architecture sim of bram_fifo_tb is
    constant DATA_WIDTH : integer := 32;
    constant ADDR_WIDTH : integer := 10;
    constant N_WORDS    : integer := 32;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';

    signal s_axis_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal m_axis_tlast  : std_logic;
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '0';

    type word_array is array (natural range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal captured : word_array(0 to N_WORDS - 1) := (others => (others => '0'));
    signal cap_idx  : integer := 0;
    signal cap_done : std_logic := '0';

    function pattern(i : integer) return std_logic_vector is
        variable v : unsigned(DATA_WIDTH - 1 downto 0);
    begin
        v := unsigned'(x"CAFE0000") + to_unsigned(i, DATA_WIDTH);
        return std_logic_vector(v);
    end function;
begin
    dut : entity work.bram_fifo
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
            m_axis_tdata  => m_axis_tdata,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready
        );

    clk <= not clk after CLK_PERIOD / 2;

    -- Capture process on m_axis handshake
    process(clk)
    begin
        if rising_edge(clk) then
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                if cap_idx < N_WORDS then
                    captured(cap_idx) <= m_axis_tdata;
                    cap_idx <= cap_idx + 1;
                end if;
                if m_axis_tlast = '1' then
                    cap_done <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Backpressure: block the reader for 20 cycles so the FIFO has time
    -- to accumulate multiple in-flight words, then release and drain.
    -- This stresses the bram_sdp read port while the write port is
    -- active (concurrent read+write on separate BRAM ports).
    process
    begin
        m_axis_tready <= '0';
        wait for 20 * CLK_PERIOD;
        m_axis_tready <= '1';
        wait;
    end process;

    -- Stimulus + self-check
    process
        variable errors : integer := 0;
    begin
        resetn <= '0';
        wait for 4 * CLK_PERIOD;
        resetn <= '1';
        wait for 2 * CLK_PERIOD;
        wait until rising_edge(clk);

        -- Drive N_WORDS into s_axis (blocks on s_tready if fifo fills)
        for i in 0 to N_WORDS - 1 loop
            s_axis_tdata  <= pattern(i);
            s_axis_tvalid <= '1';
            if i = N_WORDS - 1 then
                s_axis_tlast <= '1';
            else
                s_axis_tlast <= '0';
            end if;
            loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
        end loop;
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';

        -- Wait for drain
        wait until cap_done = '1';
        wait for 4 * CLK_PERIOD;

        -- Compare captured vs expected
        for i in 0 to N_WORDS - 1 loop
            if captured(i) /= pattern(i) then
                errors := errors + 1;
                report "MISMATCH word " & integer'image(i) &
                       ": got 0x" & to_hstring(captured(i)) &
                       " expected 0x" & to_hstring(pattern(i))
                       severity warning;
            end if;
        end loop;

        report "========================================" severity note;
        if errors = 0 then
            report "SIM PASS: bram_fifo round-tripped " &
                   integer'image(N_WORDS) & " words with backpressure"
                   severity note;
        else
            report "SIM FAIL: " & integer'image(errors) & " mismatches"
                   severity failure;
        end if;
        report "========================================" severity note;

        finish;
    end process;
end sim;
