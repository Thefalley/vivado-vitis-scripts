library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library STD;
use STD.env.all;

-- bram_ctrl_fifo_tb: stress testbench for the bram_ctrl_fifo wrapper.
--
-- Exercises:
--   1. Load with bursty traffic (varied burst/gap pattern), 28 words total.
--   2. Drain with toggling m_axis_tready (2 on, 1 off).
--   3. S_STOP mid-drain: verify output freezes, then release and resume.
--   4. Final data/order verification, PASS/FAIL report.

entity bram_ctrl_fifo_tb is
end bram_ctrl_fifo_tb;

architecture sim of bram_ctrl_fifo_tb is
    constant DATA_WIDTH  : integer := 32;
    constant BANK_ADDR_W : integer := 10;
    constant N_BANKS     : integer := 40;
    constant N_WORDS     : integer := 28;
    constant CLK_PERIOD  : time    := 10 ns;

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

    signal ctrl_load  : std_logic := '0';
    signal ctrl_drain : std_logic := '0';
    signal ctrl_stop  : std_logic := '0';
    signal ctrl_state : std_logic_vector(1 downto 0);

    -- Capture array
    type word_array is array (natural range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal captured  : word_array(0 to N_WORDS - 1) := (others => (others => '0'));
    signal cap_idx   : integer := 0;
    signal cap_last  : std_logic := '0';

    -- S_STOP verification
    signal stop_freeze_ok : boolean := false;

    function pattern(i : integer) return std_logic_vector is
        variable v : unsigned(DATA_WIDTH - 1 downto 0);
    begin
        v := unsigned'(x"BEEF0000") + to_unsigned(i, DATA_WIDTH);
        return std_logic_vector(v);
    end function;

    -- Helper: send one burst of 'count' words starting at index 'start_idx',
    -- with tlast on the absolute last word (idx = N_WORDS-1).
    procedure send_burst(
        signal   clk_s        : in    std_logic;
        signal   s_tdata      : out   std_logic_vector(DATA_WIDTH - 1 downto 0);
        signal   s_tlast      : out   std_logic;
        signal   s_tvalid     : out   std_logic;
        signal   s_tready     : in    std_logic;
        constant start_idx    : in    integer;
        constant count        : in    integer;
        constant total_words  : in    integer
    ) is
    begin
        for k in 0 to count - 1 loop
            s_tdata  <= pattern(start_idx + k);
            s_tvalid <= '1';
            if start_idx + k = total_words - 1 then
                s_tlast <= '1';
            else
                s_tlast <= '0';
            end if;
            loop
                wait until rising_edge(clk_s);
                exit when s_tready = '1';
            end loop;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';
    end procedure;

    -- Helper: idle for 'n' clock cycles
    procedure idle_cycles(
        signal   clk_s : in std_logic;
        constant n     : in integer
    ) is
    begin
        for k in 1 to n loop
            wait until rising_edge(clk_s);
        end loop;
    end procedure;

begin

    ----------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------
    dut : entity work.bram_ctrl_fifo
        generic map (
            DATA_WIDTH  => DATA_WIDTH,
            BANK_ADDR_W => BANK_ADDR_W,
            N_BANKS     => N_BANKS
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
            m_axis_tready => m_axis_tready,
            ctrl_load     => ctrl_load,
            ctrl_drain    => ctrl_drain,
            ctrl_stop     => ctrl_stop,
            ctrl_state    => ctrl_state
        );

    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------
    -- Watchdog: 50 us hard timeout
    ----------------------------------------------------------------
    watchdog : process
    begin
        wait for 50 us;
        report "WATCHDOG: sim exceeded 50 us, forcing stop" severity warning;
        report "cap_idx = " & integer'image(cap_idx) severity note;
        report "SIM FAIL (watchdog)" severity error;
        finish;
    end process;

    ----------------------------------------------------------------
    -- Capture process: record output beats
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                report "BEAT " & integer'image(cap_idx) &
                       " tdata=0x" & to_hstring(m_axis_tdata) &
                       " tlast=" & std_logic'image(m_axis_tlast)
                       severity note;
                if cap_idx < N_WORDS then
                    captured(cap_idx) <= m_axis_tdata;
                    cap_idx <= cap_idx + 1;
                end if;
                if m_axis_tlast = '1' then
                    cap_last <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- m_axis_tready toggling: 2 on, 1 off pattern during drain
    -- (driven by main stimulus below via direct assignment)
    ----------------------------------------------------------------

    ----------------------------------------------------------------
    -- Main stimulus
    ----------------------------------------------------------------
    process
        variable errors       : integer := 0;
        variable exp_v        : std_logic_vector(DATA_WIDTH - 1 downto 0);
        variable word_idx     : integer := 0;
        variable ready_cycle  : integer := 0;
        variable beat_before_stop : integer := 0;
        variable freeze_count : integer := 0;
    begin
        --------------------------------------------------------
        -- Reset
        --------------------------------------------------------
        resetn <= '0';
        wait for 5 * CLK_PERIOD;
        resetn <= '1';
        wait for 2 * CLK_PERIOD;
        wait until rising_edge(clk);

        -- Verify idle state
        assert ctrl_state = "00"
            report "ERROR: not in S_IDLE after reset" severity error;

        --------------------------------------------------------
        -- Phase 1: LOAD with bursty traffic
        -- Burst pattern: 1, gap 3, 2, gap 5, 4, gap 10, 1, gap 20, 20+tlast
        -- Total = 1 + 2 + 4 + 1 + 20 = 28 words
        --------------------------------------------------------
        report "=== Phase 1: LOAD ===" severity note;

        -- Pulse ctrl_load for 1 cycle
        ctrl_load <= '1';
        wait until rising_edge(clk);
        ctrl_load <= '0';
        wait until rising_edge(clk);

        assert ctrl_state = "01"
            report "ERROR: not in S_LOAD after ctrl_load pulse" severity error;

        word_idx := 0;

        -- Burst 1: 1 word
        send_burst(clk, s_axis_tdata, s_axis_tlast, s_axis_tvalid, s_axis_tready,
                   word_idx, 1, N_WORDS);
        word_idx := word_idx + 1;
        idle_cycles(clk, 3);

        -- Burst 2: 2 words
        send_burst(clk, s_axis_tdata, s_axis_tlast, s_axis_tvalid, s_axis_tready,
                   word_idx, 2, N_WORDS);
        word_idx := word_idx + 2;
        idle_cycles(clk, 5);

        -- Burst 3: 4 words
        send_burst(clk, s_axis_tdata, s_axis_tlast, s_axis_tvalid, s_axis_tready,
                   word_idx, 4, N_WORDS);
        word_idx := word_idx + 4;
        idle_cycles(clk, 10);

        -- Burst 4: 1 word
        send_burst(clk, s_axis_tdata, s_axis_tlast, s_axis_tvalid, s_axis_tready,
                   word_idx, 1, N_WORDS);
        word_idx := word_idx + 1;
        idle_cycles(clk, 20);

        -- Burst 5: 20 words (includes tlast on last word)
        send_burst(clk, s_axis_tdata, s_axis_tlast, s_axis_tvalid, s_axis_tready,
                   word_idx, 20, N_WORDS);
        word_idx := word_idx + 20;

        -- Wait for state to return to S_IDLE (load_done fires on tlast acceptance)
        -- Give a few cycles for the registered FSM
        for i in 1 to 10 loop
            wait until rising_edge(clk);
            exit when ctrl_state = "00";
        end loop;

        assert ctrl_state = "00"
            report "ERROR: did not return to S_IDLE after load" severity error;
        report "Load complete, " & integer'image(word_idx) & " words sent" severity note;

        --------------------------------------------------------
        -- Phase 2: DRAIN with toggling tready (2 on, 1 off)
        -- But first drain only ~10 beats, then test S_STOP.
        --------------------------------------------------------
        report "=== Phase 2: DRAIN (partial, then STOP test) ===" severity note;

        -- Pulse ctrl_drain
        ctrl_drain <= '1';
        wait until rising_edge(clk);
        ctrl_drain <= '0';

        -- Wait one cycle for state to register
        wait until rising_edge(clk);
        assert ctrl_state = "10"
            report "ERROR: not in S_DRAIN after ctrl_drain pulse" severity error;

        -- Drive tready with 2-on-1-off pattern, drain ~10 beats then stop
        ready_cycle := 0;
        while cap_idx < 10 loop
            if ready_cycle mod 3 < 2 then
                m_axis_tready <= '1';
            else
                m_axis_tready <= '0';
            end if;
            ready_cycle := ready_cycle + 1;
            wait until rising_edge(clk);
        end loop;

        -- Record how many beats captured before stop
        beat_before_stop := cap_idx;
        report "Beats before stop: " & integer'image(beat_before_stop) severity note;

        --------------------------------------------------------
        -- Phase 3: S_STOP test mid-drain
        --------------------------------------------------------
        report "=== Phase 3: S_STOP test ===" severity note;

        m_axis_tready <= '0';
        ctrl_stop <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        assert ctrl_state = "11"
            report "ERROR: not in S_STOP after ctrl_stop" severity error;

        -- Hold stop for 10 cycles, verify m_axis stays quiet
        m_axis_tready <= '1';  -- ready is high but should not matter
        freeze_count := 0;
        for i in 1 to 10 loop
            wait until rising_edge(clk);
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                freeze_count := freeze_count + 1;
            end if;
        end loop;

        if freeze_count = 0 then
            stop_freeze_ok <= true;
            report "S_STOP freeze verified: 0 beats during stop" severity note;
        else
            report "ERROR: " & integer'image(freeze_count) &
                   " beats leaked during S_STOP" severity error;
        end if;

        -- Release stop
        ctrl_stop <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        assert ctrl_state = "00"
            report "ERROR: not in S_IDLE after stop release" severity error;

        --------------------------------------------------------
        -- Phase 4: Resume drain to completion
        --------------------------------------------------------
        report "=== Phase 4: Resume drain ===" severity note;

        ctrl_drain <= '1';
        wait until rising_edge(clk);
        ctrl_drain <= '0';
        wait until rising_edge(clk);

        assert ctrl_state = "10"
            report "ERROR: not in S_DRAIN after second ctrl_drain pulse" severity error;

        -- Continue draining with 2-on-1-off tready until all beats received
        ready_cycle := 0;
        while cap_last = '0' loop
            if ready_cycle mod 3 < 2 then
                m_axis_tready <= '1';
            else
                m_axis_tready <= '0';
            end if;
            ready_cycle := ready_cycle + 1;
            wait until rising_edge(clk);
        end loop;

        -- Let pipeline flush
        m_axis_tready <= '1';
        wait for 10 * CLK_PERIOD;

        -- Wait for state to return to S_IDLE
        for i in 1 to 10 loop
            wait until rising_edge(clk);
            exit when ctrl_state = "00";
        end loop;

        --------------------------------------------------------
        -- Phase 5: Verify all data
        --------------------------------------------------------
        report "=== Phase 5: Verification ===" severity note;
        report "Total captured beats: " & integer'image(cap_idx) severity note;

        -- Check beat count
        if cap_idx /= N_WORDS then
            errors := errors + 1;
            report "ERROR: expected " & integer'image(N_WORDS) &
                   " beats, got " & integer'image(cap_idx) severity error;
        end if;

        -- Check each word
        for i in 0 to N_WORDS - 1 loop
            exp_v := pattern(i);
            if i < cap_idx and captured(i) /= exp_v then
                errors := errors + 1;
                report "MISMATCH word " & integer'image(i) &
                       ": got 0x" & to_hstring(captured(i)) &
                       " expected 0x" & to_hstring(exp_v)
                       severity warning;
            end if;
        end loop;

        -- Check tlast
        if cap_last /= '1' then
            errors := errors + 1;
            report "ERROR: never saw tlast on output" severity error;
        end if;

        -- Check S_STOP worked
        if not stop_freeze_ok then
            errors := errors + 1;
            report "ERROR: S_STOP freeze test failed" severity error;
        end if;

        --------------------------------------------------------
        -- Report
        --------------------------------------------------------
        report "==========================================" severity note;
        report "bram_ctrl_fifo_tb results:" severity note;
        report "  total errors   = " & integer'image(errors) severity note;
        report "  beats captured = " & integer'image(cap_idx) severity note;
        report "  tlast received = " & std_logic'image(cap_last) severity note;
        report "  stop freeze OK = " & boolean'image(stop_freeze_ok) severity note;

        if errors = 0 then
            report "SIM PASS" severity note;
        else
            report "SIM FAIL: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==========================================" severity note;

        finish;
    end process;

end sim;
