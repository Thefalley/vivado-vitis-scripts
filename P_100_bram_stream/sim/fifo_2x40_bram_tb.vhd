library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library STD;
use STD.env.all;

-- fifo_2x40_bram_tb: exercises the TRUE FIFO variant with
-- back-to-back writes and checks that every beat comes out in order
-- while the writer is still pushing (concurrent read+write).
--
-- For the continuous-tvalid check: once the pipeline is primed the
-- output should stay at tvalid=1 for at least N_WORDS - INIT_LAT
-- cycles (the first ~4-5 cycles have startup latency before the
-- first beat emerges).

entity fifo_2x40_bram_tb is
end fifo_2x40_bram_tb;

architecture sim of fifo_2x40_bram_tb is
    constant DATA_WIDTH  : integer := 32;
    constant BANK_ADDR_W : integer := 10;
    constant N_BANKS     : integer := 40;
    constant N_WORDS     : integer := 32;
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
    signal m_axis_tready : std_logic := '1';

    type word_array is array (natural range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal captured : word_array(0 to N_WORDS - 1) := (others => (others => '0'));
    signal cap_idx  : integer := 0;
    signal cap_last : std_logic := '0';

    signal consec_tvalid : integer := 0;
    signal max_consec    : integer := 0;

    function pattern(i : integer) return std_logic_vector is
        variable v : unsigned(DATA_WIDTH - 1 downto 0);
    begin
        v := unsigned'(x"F1F0F000") + to_unsigned(i, DATA_WIDTH);
        return std_logic_vector(v);
    end function;
begin
    dut : entity work.fifo_2x40_bram
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
            m_axis_tready => m_axis_tready
        );

    clk <= not clk after CLK_PERIOD / 2;

    -- Hard timeout watchdog
    watchdog : process
    begin
        wait for 10 us;
        report "WATCHDOG: sim exceeded 10us, forcing stop" severity warning;
        report "cap_idx = " & integer'image(cap_idx) severity note;
        report "cap_last = " & std_logic'image(cap_last) severity note;
        finish;
    end process;

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

    process(clk)
    begin
        if rising_edge(clk) then
            if m_axis_tvalid = '1' then
                consec_tvalid <= consec_tvalid + 1;
                if consec_tvalid + 1 > max_consec then
                    max_consec <= consec_tvalid + 1;
                end if;
            else
                consec_tvalid <= 0;
            end if;
        end if;
    end process;

    process
        variable errors : integer := 0;
        variable exp_v  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    begin
        resetn <= '0';
        wait for 4 * CLK_PERIOD;
        resetn <= '1';
        wait for 2 * CLK_PERIOD;
        wait until rising_edge(clk);

        -- Back-to-back writes (concurrent reads happen naturally)
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

        wait until cap_last = '1';
        wait for 8 * CLK_PERIOD;

        for i in 0 to N_WORDS - 1 loop
            exp_v := pattern(i);
            if captured(i) /= exp_v then
                errors := errors + 1;
                report "MISMATCH word " & integer'image(i) &
                       ": got 0x" & to_hstring(captured(i)) &
                       " expected 0x" & to_hstring(exp_v)
                       severity warning;
            end if;
        end loop;

        report "========================================" severity note;
        report "fifo_2x40_bram (true FIFO) results:" severity note;
        report "  data errors       = " & integer'image(errors) severity note;
        report "  max consec tvalid = " & integer'image(max_consec) &
               " (target >= " & integer'image(N_WORDS) & ")" severity note;

        if errors = 0 and max_consec >= N_WORDS then
            report "SIM PASS: true FIFO round-trip OK, tvalid continuous after prime"
                   severity note;
        elsif errors = 0 then
            report "SIM WARN: data OK but tvalid had gaps (max_consec="
                   & integer'image(max_consec) & ")" severity warning;
            report "SIM FAIL" severity failure;
        else
            report "SIM FAIL: " & integer'image(errors) & " data mismatches"
                   severity failure;
        end if;
        report "========================================" severity note;

        finish;
    end process;
end sim;
