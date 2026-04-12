library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_ctrl_top: AXI-Lite controlled BRAM FIFO wrapper (v2).
--
-- Extends P_101 with hardware occupancy/total counters and AXI-Lite readback.
--
-- AXI-Lite registers:
--   reg0 (0x00) ctrl_cmd:      write 0x01=START_LOAD, 0x02=START_DRAIN,
--                                0x03=STOP, 0x00=NOP/clear
--   reg1 (0x04) n_words:       number of words to load/drain
--   reg2 (0x08) counter_reset: write 0x01 to reset all counters to 0
--   reg3 (0x0C) ctrl_state:    read current FSM state (R)
--   reg4 (0x10) occupancy:     read current words in FIFO (R)
--   reg5-8 (0x14-0x20):        total_in  [127:0] in 4x32 (R)
--   reg9-12 (0x24-0x30):       total_out [127:0] in 4x32 (R)
--
-- FSM states:
--   S_IDLE=00, S_LOAD=01, S_DRAIN=10, S_STOP=11

entity bram_ctrl_top is
    generic (
        DATA_WIDTH  : integer := 32;
        BANK_ADDR_W : integer := 10;
        N_BANKS     : integer := 40
    );
    port (
        clk    : in  std_logic;
        resetn : in  std_logic;

        -- AXI-Lite Slave (configuration, 32 registers, addr 7 bits)
        S_AXI_AWADDR  : in  std_logic_vector(6 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector((DATA_WIDTH/8) - 1 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(6 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic;

        -- AXI-Stream Slave (data in from DMA MM2S)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXI-Stream Master (data out to DMA S2MM)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end bram_ctrl_top;

architecture rtl of bram_ctrl_top is

    -- Commands
    constant CMD_NOP   : std_logic_vector(31 downto 0) := x"00000000";
    constant CMD_LOAD  : std_logic_vector(31 downto 0) := x"00000001";
    constant CMD_DRAIN : std_logic_vector(31 downto 0) := x"00000002";
    constant CMD_STOP  : std_logic_vector(31 downto 0) := x"00000003";

    -- FSM
    type ctrl_state_t is (S_IDLE, S_LOAD, S_DRAIN, S_STOP);
    signal state : ctrl_state_t := S_IDLE;

    -- AXI-Lite register outputs (writable by ARM)
    signal ctrl_cmd      : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- reg0
    signal n_words       : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- reg1
    signal counter_reset : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- reg2

    -- Hardware readback signals (to AXI-Lite read ports)
    signal hw_reg_03 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- ctrl_state
    signal hw_reg_04 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- occupancy
    signal hw_reg_05 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_in_lo
    signal hw_reg_06 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_in_hi
    signal hw_reg_07 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_in_hh
    signal hw_reg_08 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_in_hhh
    signal hw_reg_09 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_out_lo
    signal hw_reg_10 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_out_hi
    signal hw_reg_11 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_out_hh
    signal hw_reg_12 : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- total_out_hhh

    -- Unused register ports (reg13..31)
    signal pnu_13, pnu_14, pnu_15, pnu_16 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_17, pnu_18, pnu_19, pnu_20 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_21, pnu_22, pnu_23, pnu_24 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_25, pnu_26, pnu_27, pnu_28 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_29, pnu_30                 : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- Inner FIFO connections
    signal fi_s_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal fi_s_tlast  : std_logic;
    signal fi_s_tvalid : std_logic;
    signal fi_s_tready : std_logic;

    signal fi_m_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal fi_m_tlast  : std_logic;
    signal fi_m_tvalid : std_logic;
    signal fi_m_tready : std_logic;

    -- Beat counter
    signal beat_count : unsigned(31 downto 0) := (others => '0');
    signal n_words_u  : unsigned(31 downto 0);
    signal use_count  : std_logic;  -- '1' when n_words > 0

    -- Phase-complete detection
    signal load_done  : std_logic;
    signal drain_done : std_logic;

    -- Edge detection for ctrl_cmd
    signal cmd_latched : std_logic := '0';

    -- Counters (P_102 additions)
    signal total_in  : unsigned(127 downto 0) := (others => '0');
    signal total_out : unsigned(127 downto 0) := (others => '0');
    signal occupancy : unsigned(31 downto 0)  := (others => '0');

    -- FSM state encoding for readback
    signal ctrl_state_vec : std_logic_vector(1 downto 0);

begin

    n_words_u <= unsigned(n_words);
    use_count <= '1' when n_words_u /= 0 else '0';

    -- FSM state encoding: 00=IDLE, 01=LOAD, 10=DRAIN, 11=STOP
    ctrl_state_vec <= "00" when state = S_IDLE  else
                      "01" when state = S_LOAD  else
                      "10" when state = S_DRAIN else
                      "11";

    -----------------------------------------------------------------
    -- Hardware readback wiring to AXI-Lite
    -----------------------------------------------------------------
    hw_reg_03 <= (31 downto 2 => '0') & ctrl_state_vec;
    hw_reg_04 <= std_logic_vector(occupancy);
    hw_reg_05 <= std_logic_vector(total_in(31 downto 0));
    hw_reg_06 <= std_logic_vector(total_in(63 downto 32));
    hw_reg_07 <= std_logic_vector(total_in(95 downto 64));
    hw_reg_08 <= std_logic_vector(total_in(127 downto 96));
    hw_reg_09 <= std_logic_vector(total_out(31 downto 0));
    hw_reg_10 <= std_logic_vector(total_out(63 downto 32));
    hw_reg_11 <= std_logic_vector(total_out(95 downto 64));
    hw_reg_12 <= std_logic_vector(total_out(127 downto 96));

    -----------------------------------------------------------------
    -- AXI-Lite register bank (axi_lite_cfg_rw with hw readback)
    -----------------------------------------------------------------
    axil_inst : entity work.axi_lite_cfg_rw
        generic map (
            C_S_AXI_DATA_WIDTH => DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => 7
        )
        port map (
            add_value        => ctrl_cmd,          -- reg0
            port_not_used_01 => n_words,           -- reg1
            port_not_used_02 => counter_reset,     -- reg2
            -- Hardware readback inputs
            hw_reg_03        => hw_reg_03,         -- ctrl_state
            hw_reg_04        => hw_reg_04,         -- occupancy
            hw_reg_05        => hw_reg_05,         -- total_in_lo
            hw_reg_06        => hw_reg_06,         -- total_in_hi
            hw_reg_07        => hw_reg_07,         -- total_in_hh
            hw_reg_08        => hw_reg_08,         -- total_in_hhh
            hw_reg_09        => hw_reg_09,         -- total_out_lo
            hw_reg_10        => hw_reg_10,         -- total_out_hi
            hw_reg_11        => hw_reg_11,         -- total_out_hh
            hw_reg_12        => hw_reg_12,         -- total_out_hhh
            -- Unused writable registers
            port_not_used_13 => pnu_13,
            port_not_used_14 => pnu_14,
            port_not_used_15 => pnu_15,
            port_not_used_16 => pnu_16,
            port_not_used_17 => pnu_17,
            port_not_used_18 => pnu_18,
            port_not_used_19 => pnu_19,
            port_not_used_20 => pnu_20,
            port_not_used_21 => pnu_21,
            port_not_used_22 => pnu_22,
            port_not_used_23 => pnu_23,
            port_not_used_24 => pnu_24,
            port_not_used_25 => pnu_25,
            port_not_used_26 => pnu_26,
            port_not_used_27 => pnu_27,
            port_not_used_28 => pnu_28,
            port_not_used_29 => pnu_29,
            port_not_used_30 => pnu_30,
            S_AXI_ACLK    => clk,
            S_AXI_ARESETN => resetn,
            S_AXI_AWADDR  => S_AXI_AWADDR,
            S_AXI_AWPROT  => S_AXI_AWPROT,
            S_AXI_AWVALID => S_AXI_AWVALID,
            S_AXI_AWREADY => S_AXI_AWREADY,
            S_AXI_WDATA   => S_AXI_WDATA,
            S_AXI_WSTRB   => S_AXI_WSTRB,
            S_AXI_WVALID  => S_AXI_WVALID,
            S_AXI_WREADY  => S_AXI_WREADY,
            S_AXI_BRESP   => S_AXI_BRESP,
            S_AXI_BVALID  => S_AXI_BVALID,
            S_AXI_BREADY  => S_AXI_BREADY,
            S_AXI_ARADDR  => S_AXI_ARADDR,
            S_AXI_ARPROT  => S_AXI_ARPROT,
            S_AXI_ARVALID => S_AXI_ARVALID,
            S_AXI_ARREADY => S_AXI_ARREADY,
            S_AXI_RDATA   => S_AXI_RDATA,
            S_AXI_RRESP   => S_AXI_RRESP,
            S_AXI_RVALID  => S_AXI_RVALID,
            S_AXI_RREADY  => S_AXI_RREADY
        );

    -----------------------------------------------------------------
    -- Inner FIFO instantiation
    -----------------------------------------------------------------
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

    -----------------------------------------------------------------
    -- AXI-Stream gating
    -----------------------------------------------------------------

    -- s_axis -> inner FIFO s_axis (only in S_LOAD)
    fi_s_tdata    <= s_axis_tdata;
    -- AXI-Stream rule: tlast must NOT depend on tready.
    -- Inject synthetic tlast based only on state + beat_count.
    fi_s_tlast    <= '1' when (state = S_LOAD and use_count = '1' and
                               beat_count = n_words_u - 1)
                    else s_axis_tlast when state = S_LOAD
                    else '0';
    fi_s_tvalid   <= s_axis_tvalid when state = S_LOAD else '0';
    s_axis_tready <= fi_s_tready   when state = S_LOAD else '0';

    -- inner FIFO m_axis -> m_axis (only in S_DRAIN)
    m_axis_tdata  <= fi_m_tdata;
    -- Inject synthetic tlast on last DRAIN beat (same pattern as LOAD)
    m_axis_tlast  <= '1' when (state = S_DRAIN and use_count = '1' and
                               beat_count = n_words_u - 1)
                    else fi_m_tlast when state = S_DRAIN
                    else '0';
    m_axis_tvalid <= fi_m_tvalid when state = S_DRAIN else '0';
    fi_m_tready   <= m_axis_tready when state = S_DRAIN else '0';

    -----------------------------------------------------------------
    -- Phase-complete detection
    -----------------------------------------------------------------
    load_done <= '1' when (state = S_LOAD and
                           fi_s_tvalid = '1' and fi_s_tready = '1' and
                           ((use_count = '1' and beat_count = n_words_u - 1) or
                            (use_count = '0' and fi_s_tlast = '1')))
                     else '0';

    drain_done <= '1' when (state = S_DRAIN and
                            fi_m_tvalid = '1' and fi_m_tready = '1' and
                            ((use_count = '1' and beat_count = n_words_u - 1) or
                             (use_count = '0' and fi_m_tlast = '1')))
                      else '0';

    -----------------------------------------------------------------
    -- Control FSM + beat counter + occupancy/total counters
    -----------------------------------------------------------------
    process(clk)
        variable in_hs  : std_logic;
        variable out_hs : std_logic;
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state       <= S_IDLE;
                beat_count  <= (others => '0');
                cmd_latched <= '0';
                total_in    <= (others => '0');
                total_out   <= (others => '0');
                occupancy   <= (others => '0');
            else
                -- Detect handshakes for counter updates
                in_hs  := '0';
                out_hs := '0';

                if state = S_LOAD and fi_s_tvalid = '1' and fi_s_tready = '1' then
                    in_hs := '1';
                end if;
                if state = S_DRAIN and fi_m_tvalid = '1' and fi_m_tready = '1' then
                    out_hs := '1';
                end if;

                -- Counter reset via AXI-Lite register
                if counter_reset = x"00000001" then
                    total_in  <= (others => '0');
                    total_out <= (others => '0');
                    occupancy <= (others => '0');
                else
                    -- Update counters on handshakes
                    if in_hs = '1' then
                        total_in  <= total_in + 1;
                        occupancy <= occupancy + 1;
                    end if;
                    if out_hs = '1' then
                        total_out <= total_out + 1;
                        occupancy <= occupancy - 1;
                    end if;
                end if;

                -- FSM state machine (same as P_101)
                case state is
                    when S_IDLE =>
                        beat_count <= (others => '0');

                        if ctrl_cmd /= CMD_NOP and cmd_latched = '0' then
                            cmd_latched <= '1';

                            if ctrl_cmd = CMD_LOAD then
                                state <= S_LOAD;
                            elsif ctrl_cmd = CMD_DRAIN then
                                state <= S_DRAIN;
                            elsif ctrl_cmd = CMD_STOP then
                                state <= S_STOP;
                            end if;
                        end if;

                        if ctrl_cmd = CMD_NOP then
                            cmd_latched <= '0';
                        end if;

                    when S_LOAD =>
                        if fi_s_tvalid = '1' and fi_s_tready = '1' then
                            beat_count <= beat_count + 1;
                        end if;

                        if load_done = '1' then
                            state      <= S_IDLE;
                            beat_count <= (others => '0');
                        end if;

                        if ctrl_cmd = CMD_STOP and cmd_latched = '0' then
                            cmd_latched <= '1';
                            state       <= S_STOP;
                            beat_count  <= (others => '0');
                        end if;
                        if ctrl_cmd = CMD_NOP then
                            cmd_latched <= '0';
                        end if;

                    when S_DRAIN =>
                        if fi_m_tvalid = '1' and fi_m_tready = '1' then
                            beat_count <= beat_count + 1;
                        end if;

                        if drain_done = '1' then
                            state      <= S_IDLE;
                            beat_count <= (others => '0');
                        end if;

                        if ctrl_cmd = CMD_STOP and cmd_latched = '0' then
                            cmd_latched <= '1';
                            state       <= S_STOP;
                            beat_count  <= (others => '0');
                        end if;
                        if ctrl_cmd = CMD_NOP then
                            cmd_latched <= '0';
                        end if;

                    when S_STOP =>
                        beat_count <= (others => '0');
                        if ctrl_cmd = CMD_NOP then
                            state       <= S_IDLE;
                            cmd_latched <= '0';
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;
