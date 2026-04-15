-- ============================================================================
-- dm_s2mm_ctrl.vhd
-- DataMover S2MM Command Generator + Status Handler
-- P_500_datamover - Learning project
--
-- Controlled via GPIO pins (dest_addr, ctrl_reg, status_reg).
-- Generates 72-bit DataMover S2MM commands and consumes status responses.
--
-- ============================================================================
-- DATAMOVER S2MM COMMAND FORMAT (72 bits):
--
--   Bit(s)    Field       Description
--   -------   ---------   --------------------------------------------------
--   [71:68]   RSVD        Reserved, must be 0000
--   [67:64]   TAG         Transaction tag (echoed in status), 4-bit
--   [63:32]   SADDR       Start address for memory write, 32-bit
--   [31]      RSVD        Reserved, must be 0
--   [30]      TYPE        1 = INCR burst (addr increments), 0 = FIXED
--   [29:24]   DSA         DRE Stream Alignment (set to 000000 normally)
--   [23]      EOF         End Of Frame (1 = last cmd of this frame)
--   [22:0]    BTT         Bytes To Transfer (max 8MB with 23-bit BTT)
--
-- ============================================================================
-- DATAMOVER S2MM STATUS FORMAT (8 bits):
--
--   Bit(s)    Field       Description
--   -------   ---------   --------------------------------------------------
--   [7]       DECERR      AXI Decode Error (invalid address)
--   [6]       SLVERR      AXI Slave Error
--   [5]       INTERR      DataMover Internal Error
--   [4]       OK          Transfer completed successfully
--   [3:0]     TAG         Echoed TAG from the command
--
-- ============================================================================
-- SOFTWARE USAGE (from bare-metal C):
--
--   1. Write destination address to GPIO_ADDR (channel 1)
--   2. Write byte_count to GPIO_CTRL (channel 1) bits [22:0]
--   3. Set bit [31] of GPIO_CTRL to 1 (start pulse), then back to 0
--   4. Start DMA MM2S transfer (data source)
--   5. Poll GPIO_CTRL channel 2 for status, or wait for interrupt
--   6. Check status_reg[2] for errors, status_reg[1] for done
--
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity dm_s2mm_ctrl is
    port(
        clk           : in  std_logic;
        resetn        : in  std_logic;

        -- Configuration inputs (directly from AXI GPIO outputs)
        dest_addr     : in  std_logic_vector(31 downto 0);  -- DDR destination
        ctrl_reg      : in  std_logic_vector(31 downto 0);  -- [22:0]=BTT, [31]=start

        -- Status output (directly to AXI GPIO input)
        status_reg    : out std_logic_vector(31 downto 0);   -- [0]=busy [1]=done [2]=err

        -- Interrupt output
        done_irq      : out std_logic;

        -- DataMover S2MM Command interface (AXI-Stream master, 72-bit)
        cmd_tdata     : out std_logic_vector(71 downto 0);
        cmd_tvalid    : out std_logic;
        cmd_tready    : in  std_logic;

        -- DataMover S2MM Status interface (AXI-Stream slave, 8-bit)
        sts_tdata     : in  std_logic_vector(7 downto 0);
        sts_tvalid    : in  std_logic;
        sts_tready    : out std_logic;
        sts_tkeep     : in  std_logic_vector(0 downto 0);
        sts_tlast     : in  std_logic
    );
end entity dm_s2mm_ctrl;

architecture rtl of dm_s2mm_ctrl is

    type state_t is (ST_IDLE, ST_SEND_CMD, ST_WAIT_DONE);
    signal state : state_t;

    -- Edge detection for start pulse
    signal start_prev  : std_logic;
    signal start_pulse : std_logic;

    -- Internal status
    signal cmd_valid_i : std_logic;
    signal busy_i      : std_logic;
    signal done_i      : std_logic;
    signal error_i     : std_logic;
    signal sts_data_i  : std_logic_vector(7 downto 0);

begin

    -- =========================================================
    -- Build the 72-bit DataMover S2MM command (active combinatorially)
    -- =========================================================
    cmd_tdata(71 downto 68) <= "0000";                  -- RSVD
    cmd_tdata(67 downto 64) <= "0000";                  -- TAG = 0
    cmd_tdata(63 downto 32) <= dest_addr;               -- SADDR
    cmd_tdata(31)           <= '0';                     -- RSVD
    cmd_tdata(30)           <= '1';                     -- TYPE = INCR
    cmd_tdata(29 downto 24) <= "000000";                -- DSA = 0
    cmd_tdata(23)           <= '1';                     -- EOF = 1
    cmd_tdata(22 downto  0) <= ctrl_reg(22 downto 0);   -- BTT

    cmd_tvalid <= cmd_valid_i;

    -- Always ready to consume status (never backpressure)
    sts_tready <= '1';

    -- =========================================================
    -- Rising-edge detector on ctrl_reg[31] (start bit)
    -- =========================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                start_prev <= '0';
            else
                start_prev <= ctrl_reg(31);
            end if;
        end if;
    end process;

    start_pulse <= ctrl_reg(31) and not start_prev;

    -- =========================================================
    -- Main FSM
    -- =========================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state       <= ST_IDLE;
                cmd_valid_i <= '0';
                busy_i      <= '0';
                done_i      <= '0';
                error_i     <= '0';
                done_irq    <= '0';
                sts_data_i  <= (others => '0');
            else
                -- Default: interrupt is one-cycle pulse
                done_irq <= '0';

                case state is

                    -- Wait for start pulse
                    when ST_IDLE =>
                        if start_pulse = '1' then
                            state       <= ST_SEND_CMD;
                            cmd_valid_i <= '1';
                            busy_i      <= '1';
                            done_i      <= '0';
                            error_i     <= '0';
                        end if;

                    -- Send the 72-bit command to DataMover
                    when ST_SEND_CMD =>
                        if cmd_tready = '1' and cmd_valid_i = '1' then
                            cmd_valid_i <= '0';
                            state       <= ST_WAIT_DONE;
                        end if;

                    -- Wait for DataMover status response
                    when ST_WAIT_DONE =>
                        if sts_tvalid = '1' then
                            sts_data_i <= sts_tdata;
                            busy_i     <= '0';
                            done_i     <= '1';
                            -- Error if any of DECERR/SLVERR/INTERR are set
                            error_i    <= sts_tdata(7) or sts_tdata(6) or sts_tdata(5);
                            done_irq   <= '1';
                            state      <= ST_IDLE;
                        end if;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process;

    -- =========================================================
    -- Status register output (directly to GPIO input)
    -- =========================================================
    status_reg(0)            <= busy_i;       -- Transfer in progress
    status_reg(1)            <= done_i;       -- Transfer completed
    status_reg(2)            <= error_i;      -- Error flag
    status_reg(3)            <= '0';          -- Reserved
    status_reg(11 downto 4)  <= sts_data_i;   -- Raw DataMover status byte
    status_reg(31 downto 12) <= (others => '0');

end architecture rtl;
