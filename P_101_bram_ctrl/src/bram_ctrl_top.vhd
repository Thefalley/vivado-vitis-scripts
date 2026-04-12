library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- bram_ctrl_top: AXI-Lite controlled BRAM FIFO wrapper.
--
-- Wraps fifo_2x40_bram with AXI-Lite register control (via axi_lite_cfg)
-- to enforce explicit load/drain phasing from the Zynq PS ARM core.
--
-- AXI-Lite registers:
--   reg0 (0x00) ctrl_cmd:  write 0x01=START_LOAD, 0x02=START_DRAIN,
--                           0x03=STOP, 0x00=NOP/clear
--   reg1 (0x04) n_words:   number of words to load/drain. When >0 the
--                           FSM counts accepted beats and auto-stops at N
--                           (ignores tlast). When =0, uses tlast as stop.
--   reg2..31:   unused
--
-- FSM states:
--   S_IDLE  : both interfaces blocked. Waits for ctrl_cmd.
--   S_LOAD  : s_axis open, m_axis blocked. Counts beats or watches tlast.
--   S_DRAIN : s_axis blocked, m_axis open. Counts beats or watches tlast.
--   S_STOP  : everything blocked. Returns to S_IDLE when ctrl_cmd = 0x00.

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

    -- AXI-Lite register outputs
    signal ctrl_cmd  : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- reg0
    signal n_words   : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- reg1

    -- Unused register ports (reg2..31)
    signal pnu_02, pnu_03, pnu_04 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_05, pnu_06, pnu_07, pnu_08 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_09, pnu_10, pnu_11, pnu_12 : std_logic_vector(DATA_WIDTH - 1 downto 0);
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

    -- Edge detection for ctrl_cmd: latch on first non-zero
    signal cmd_latched : std_logic := '0';

begin

    n_words_u <= unsigned(n_words);
    use_count <= '1' when n_words_u /= 0 else '0';

    -----------------------------------------------------------------
    -- AXI-Lite register bank (axi_lite_cfg)
    -----------------------------------------------------------------
    axil_inst : entity work.axi_lite_cfg
        generic map (
            C_S_AXI_DATA_WIDTH => DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => 7
        )
        port map (
            add_value        => ctrl_cmd,       -- reg0
            port_not_used_01 => n_words,        -- reg1
            port_not_used_02 => pnu_02,
            port_not_used_03 => pnu_03,
            port_not_used_04 => pnu_04,
            port_not_used_05 => pnu_05,
            port_not_used_06 => pnu_06,
            port_not_used_07 => pnu_07,
            port_not_used_08 => pnu_08,
            port_not_used_09 => pnu_09,
            port_not_used_10 => pnu_10,
            port_not_used_11 => pnu_11,
            port_not_used_12 => pnu_12,
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
    -- When using n_words mode, inject synthetic tlast on the last beat
    -- so the inner store-and-replay FIFO switches to replay mode.
    fi_s_tdata    <= s_axis_tdata;
    fi_s_tlast    <= '1' when (state = S_LOAD and use_count = '1' and
                               beat_count = n_words_u - 1 and
                               s_axis_tvalid = '1' and fi_s_tready = '1')
                    else s_axis_tlast when state = S_LOAD
                    else '0';
    fi_s_tvalid   <= s_axis_tvalid when state = S_LOAD else '0';
    s_axis_tready <= fi_s_tready   when state = S_LOAD else '0';

    -- inner FIFO m_axis -> m_axis (only in S_DRAIN)
    m_axis_tdata  <= fi_m_tdata;
    m_axis_tlast  <= fi_m_tlast  when state = S_DRAIN else '0';
    m_axis_tvalid <= fi_m_tvalid when state = S_DRAIN else '0';
    fi_m_tready   <= m_axis_tready when state = S_DRAIN else '0';

    -----------------------------------------------------------------
    -- Phase-complete detection
    -----------------------------------------------------------------
    -- When use_count='1': done when beat_count reaches n_words
    -- When use_count='0': done when we see tlast handshake

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
    -- Control FSM + beat counter
    -----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state      <= S_IDLE;
                beat_count <= (others => '0');
                cmd_latched <= '0';
            else
                case state is
                    when S_IDLE =>
                        beat_count <= (others => '0');

                        -- Edge-sensitive command detection:
                        -- Only act on the first cycle we see a non-zero cmd
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

                        -- Clear latch when ARM writes NOP back
                        if ctrl_cmd = CMD_NOP then
                            cmd_latched <= '0';
                        end if;

                    when S_LOAD =>
                        -- Count accepted beats on s_axis
                        if fi_s_tvalid = '1' and fi_s_tready = '1' then
                            beat_count <= beat_count + 1;
                        end if;

                        if load_done = '1' then
                            state      <= S_IDLE;
                            beat_count <= (others => '0');
                        end if;

                        -- Immediate stop override (check cmd register)
                        if ctrl_cmd = CMD_STOP and cmd_latched = '0' then
                            cmd_latched <= '1';
                            state       <= S_STOP;
                            beat_count  <= (others => '0');
                        end if;
                        if ctrl_cmd = CMD_NOP then
                            cmd_latched <= '0';
                        end if;

                    when S_DRAIN =>
                        -- Count emitted beats on m_axis
                        if fi_m_tvalid = '1' and fi_m_tready = '1' then
                            beat_count <= beat_count + 1;
                        end if;

                        if drain_done = '1' then
                            state      <= S_IDLE;
                            beat_count <= (others => '0');
                        end if;

                        -- Immediate stop override
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
                        -- Return to idle when ARM clears to NOP
                        if ctrl_cmd = CMD_NOP then
                            state       <= S_IDLE;
                            cmd_latched <= '0';
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;
