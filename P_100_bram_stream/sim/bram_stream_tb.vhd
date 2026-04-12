library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library STD;
use STD.env.all;

-- bram_stream_tb: self-checking testbench that stresses the AXI-Stream
-- handshake at the s_axis input with a bursty pattern:
--
--   2 words -> 2 idle cycles -> 3 words -> 4 idle cycles ->
--   3 words -> 1 idle cycle  -> 4 words (last with tlast='1')
--
-- Total: 12 words, several gaps. The bursty tvalid=0 between beats
-- forces the input skid buffer / FSM to honour the handshake correctly
-- (no data silently dropped, no phantom writes when tvalid=0).
-- The testbench captures every m_axis handshake and compares against
-- the expected pattern.

entity bram_stream_tb is
end bram_stream_tb;

architecture sim of bram_stream_tb is
    constant DATA_WIDTH : integer := 32;
    constant ADDR_WIDTH : integer := 10;
    constant N_WORDS    : integer := 12;
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
    signal m_axis_tready : std_logic := '1';

    type word_array is array (natural range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal captured : word_array(0 to N_WORDS - 1) := (others => (others => '0'));
    signal cap_idx  : integer := 0;
    signal cap_last : std_logic := '0';

    function pattern(i : integer) return std_logic_vector is
        variable v : unsigned(DATA_WIDTH - 1 downto 0);
    begin
        v := unsigned'(x"DEAD0000") + to_unsigned(i, DATA_WIDTH);
        return std_logic_vector(v);
    end function;
begin
    dut : entity work.bram_stream
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

    -- Output capture
    process(clk)
    begin
        if rising_edge(clk) then
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
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

    -- Stimulus + self-check: bursty input pattern
    process
        variable errors : integer := 0;
        variable exp_v  : std_logic_vector(DATA_WIDTH - 1 downto 0);

        -- helper: drive a single beat and block until tready=1
        procedure send_word(v : std_logic_vector(DATA_WIDTH - 1 downto 0);
                            is_last : std_logic) is
        begin
            s_axis_tdata  <= v;
            s_axis_tlast  <= is_last;
            s_axis_tvalid <= '1';
            loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
        end procedure;

        -- helper: hold tvalid=0 for n cycles
        procedure idle_cycles(n : integer) is
        begin
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
            for k in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
    begin
        resetn <= '0';
        wait for 4 * CLK_PERIOD;
        resetn <= '1';
        wait for 2 * CLK_PERIOD;
        wait until rising_edge(clk);

        -- Burst 1: 2 words, then 2 idle cycles
        send_word(pattern(0), '0');
        send_word(pattern(1), '0');
        idle_cycles(2);

        -- Burst 2: 3 words, then 4 idle cycles
        send_word(pattern(2), '0');
        send_word(pattern(3), '0');
        send_word(pattern(4), '0');
        idle_cycles(4);

        -- Burst 3: 3 words, then 1 idle cycle
        send_word(pattern(5), '0');
        send_word(pattern(6), '0');
        send_word(pattern(7), '0');
        idle_cycles(1);

        -- Final burst: 4 words, last asserts tlast
        send_word(pattern(8),  '0');
        send_word(pattern(9),  '0');
        send_word(pattern(10), '0');
        send_word(pattern(11), '1');

        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';

        -- Wait for replay to finish on m_axis
        wait until cap_last = '1';
        wait for 8 * CLK_PERIOD;

        -- Compare captured vs expected
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
        if errors = 0 then
            report "SIM PASS: bram_stream " & integer'image(N_WORDS) &
                   " bursty words round-tripped via BRAM" severity note;
        else
            report "SIM FAIL: " & integer'image(errors) & " mismatches"
                   severity failure;
        end if;
        report "========================================" severity note;

        finish;
    end process;
end sim;
