
----------------------------------------------------------------------------------
-- Company:        IKERLAN
-- Engineer:       Pablo Mendoza EGUIGUREN
--
-- Module Name:    top_axis4_to_axi_bridge - RTL
-- File:           top_axis4_to_axi_bridge.vhd
-- Created:        04/02/2025
--
-- Description:
-- This module implements an **AXI Stream to AXI Memory bridge** capable of 
-- receiving data from four AXI-Stream interfaces, processing the data, 
-- and transferring it to an AXI memory-mapped interface. The module also 
-- generates control commands and manages interrupts.
--
-- Features:
-- 1. **AXI-Stream Data Aggregation and Processing:**
--    - Receives data from **four AXI-Stream sources** (`s_hs_tdata_0` to `s_hs_tdata_3`).
--    - Implements **handshake logic** (`s_hs_tvalid`, `s_hs_tready`, `s_hs_tlast`) 
--      for proper synchronization.
--    - Processes the received data using `HsSkidBuf_Scheduler_dest` and `HsSkidBuf_dest`.
--    - Stores processed data in an **AXI memory-mapped interface**.
--
-- 2. **Command and Address Management:**
--    - Utilizes `dataColector_ROI_interpreter` to **extract metadata** and compute:
--      * **Base address** selection (`base_address_A`, `base_address_B`).
--      * **Data length computation** (`LENGTHE2F`).
--    - Generates AXI Data Mover commands using `axis_cmd_gen_s2mm` for efficient 
--      data transfer.
--
-- 3. **Interrupt Handling:**
--    - Implements an **interrupt toggler (`interrupt_toggler`)** to generate 
--      alternating interrupts (`INT_A` and `INT_B`) after a certain number 
--      of transactions (`CNT_MAX`).
--    - **Uses an Integrated Logic Analyzer (ILA)** to monitor transaction events.
--
-- 4. **State Machine for Transaction Control:**
--    - Implements a **finite state machine (FSM)** with three states:
--      * `IDLE_st`: Waits for a new transaction.
--      * `START_st`: Initiates metadata collection.
--      * `IDLE_DONE_DATA_st`: Waits for data processing completion before resetting.
--    - Utilizes **flags (`flag_DONE_DATA_COLECTOR`, `flag_DONE_CMD_SEND`)** 
--      to track data collection and command issuance progress.
--
-- Usage:
-- - The module operates **automatically** upon receiving valid AXI-Stream data.
-- - Metadata extraction and **base address computation** occur dynamically.
-- - The **AXI Data Mover interface** executes the memory write transaction.
-- - Interrupt signals toggle every `CNT_MAX` transactions.
--
-- Parameters:
-- * **HS_TDATA_WIDTH**: Width of the AXI Stream data (default: 32 bits).
-- * **INTERFACE_NUM**: Number of AXI-Stream input interfaces (default: 4).
-- * **CMD_WIDTH**: Width of generated AXI Data Mover commands (default: 72 bits).
-- * **LENGTHE2F_WIDTH**: Number of bits used for word length calculations.
-- * **CNT_MAX**: Number of transactions before toggling an interrupt.
--
-- Dependencies:
-- - `HsSkidBuf_Scheduler_dest`: Handles multiple AXI-Stream sources.
-- - `dataColector_ROI_interpreter`: Extracts metadata and computes addresses.
-- - `axis_cmd_gen_s2mm`: Generates control commands for the AXI Data Mover.
-- - `interrupt_toggler`: Generates interrupt signals for the PS.
--
-- Revision History:
-- Rev 1.0 - Initial release by Pablo Mendoza
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
-- use work.MathUtils.all;

-- Entity: axis4_to_axi_bridge
-- Converts 4 AXI Stream interfaces into an AXI memory interface
-- and generates control commands for data transfer.
entity top_axis4_to_axi_bridge is
    generic (
        HS_TDATA_WIDTH  : integer := 32;    -- Width of the AXI Stream data
        BYTE_WIDTH      : integer := 8;     -- Byte width (used for calculations)
        INTERFACE_NUM   : integer := 4;     -- Number of AXI Stream input interfaces
        DEST_WIDTH      : integer := 2;     -- Destination width in AXI Stream
        STS_DATA_WIDTH  : integer := 8;     -- Status data width
        CMD_WIDTH       : integer := 72;    -- Width of the generated command
        CNT_MAX         : integer := 4;     -- Counter max value for interrupts
        LENGTHE2F_WIDTH : integer := 23     -- Width of number of words to transfer
    );
    port (
        -- Global control signals
        clk             : in  std_logic;  -- System clock
        n_rst           : in  std_logic;  -- Active-low reset signal
        -- enable          : in  std_logic;  -- enable sistem

        -- Base address
        base_address_A  : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        base_address_B  : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);

        -- AXI Stream input signals
        s_hs_tdata_0   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);         -- Data from source 0
        s_hs_tlast_0   : in  std_logic;                                             -- Last signal for source 0
        s_hs_tvalid_0  : in  std_logic;                                             -- Valid signal for source 0
        s_hs_tready_0  : out std_logic;                                             -- Ready signal for source 0

        s_hs_tdata_1   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);         -- Data from source 1
        s_hs_tlast_1   : in  std_logic;                                             -- Last signal for source 1
        s_hs_tvalid_1  : in  std_logic;                                             -- Valid signal for source 1
        s_hs_tready_1  : out std_logic;                                             -- Ready signal for source 1

        s_hs_tdata_2   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);         -- Data from source 2
        s_hs_tlast_2   : in  std_logic;                                             -- Last signal for source 2
        s_hs_tvalid_2  : in  std_logic;                                             -- Valid signal for source 2
        s_hs_tready_2  : out std_logic;                                             -- Ready signal for source 2

        s_hs_tdata_3   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);         -- Data from source 3
        s_hs_tlast_3   : in  std_logic;                                             -- Last signal for source 3
        s_hs_tvalid_3  : in  std_logic;                                             -- Valid signal for source 3
        s_hs_tready_3  : out std_logic;                                             -- Ready signal for source 3

        -- AXI Stream output signals
        m_axis_tdata    : out std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);        -- Output data
        m_axis_tdest    : out std_logic_vector(DEST_WIDTH - 1 downto 0);            -- Output destination
        m_axis_tlast    : out std_logic;                                            -- Output last signal
        m_axis_tvalid   : out std_logic;                                            -- Output valid signal
        m_axis_tready   : in  std_logic;                                            -- Output ready signal

        -- AXI Stream command interface signals
        m_axis_cmd_data  : out std_logic_vector(CMD_WIDTH - 1 downto 0);            -- Command data
        m_axis_cmd_valid : out std_logic;                                           -- Command valid signal
        m_axis_cmd_last  : out std_logic;                                           -- Command last signal
        m_axis_cmd_ready : in  std_logic;                                           -- Command ready signal

        -- AXI Data Mover status signals
        M_AXIS_S2MM_STS_tdata  : in std_logic_vector(STS_DATA_WIDTH - 1 downto 0);  -- Status data
        M_AXIS_S2MM_STS_tkeep  : in std_logic_vector(0 downto 0);                   -- Keep signal
        M_AXIS_S2MM_STS_tlast  : in std_logic;                                      -- Last status signal
        M_AXIS_S2MM_STS_tready : out std_logic;                                     -- Ready signal for status
        M_AXIS_S2MM_STS_tvalid : in std_logic;                                      -- Valid status signal

        -- Interrupt signals
        INT_A                   : out std_logic;                                    -- Interrupt A
        INT_B                   : out std_logic                                     -- Interrupt B
    );
end top_axis4_to_axi_bridge;

architecture arch_top_axis4_to_axi_bridge of top_axis4_to_axi_bridge is

    -- FSM States
    type state_type is (
        IDLE_st,             -- System idle, waiting for a new transaction
        START_st,            -- Initialize metadata collection
        IDLE_DONE_DATA_st    -- Wait for data completion before resetting
    );
    -- Current and next state registers
    signal state, next_state : state_type := IDLE_st;

    -- AXI-Stream input signals (Buffered copies of input streams)
    signal aux_s_axis_tdata_0   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Data from source 0
    signal aux_s_axis_tlast_0   : std_logic;                                        -- End of packet for source 0
    signal aux_s_axis_tvalid_0  : std_logic;                                        -- Valid signal for source 0
    signal aux_s_axis_tready_0  : std_logic;                                        -- Ready signal for source 0

    signal aux_s_axis_tdata_1   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Data from source 1
    signal aux_s_axis_tlast_1   : std_logic;                                        -- End of packet for source 1
    signal aux_s_axis_tvalid_1  : std_logic;                                        -- Valid signal for source 1
    signal aux_s_axis_tready_1  : std_logic;                                        -- Ready signal for source 1

    signal aux_s_axis_tdata_2   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Data from source 2
    signal aux_s_axis_tlast_2   : std_logic;                                        -- End of packet for source 2
    signal aux_s_axis_tvalid_2  : std_logic;                                        -- Valid signal for source 2
    signal aux_s_axis_tready_2  : std_logic;                                        -- Ready signal for source 2

    signal aux_s_axis_tdata_3   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Data from source 3
    signal aux_s_axis_tlast_3   : std_logic;                                        -- End of packet for source 3
    signal aux_s_axis_tvalid_3  : std_logic;                                        -- Valid signal for source 3
    signal aux_s_axis_tready_3  : std_logic;                                        -- Ready signal for source 3

    -- AXI Stream Intermediate Processing Signals
    signal aux_1_main_hs_tdata  : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Processed data after first stage
    signal aux_1_main_hs_tdest  : std_logic_vector(DEST_WIDTH - 1 downto 0);        -- Destination ID
    signal aux_1_main_hs_tlast  : std_logic;                                        -- End-of-packet after first stage processing
    signal aux_1_main_hs_tvalid : std_logic;                                        -- Valid signal after first stage processing
    signal aux_1_main_hs_tready : std_logic;                                        -- Ready signal after first stage processing

    -- AXI Stream Final Processing Signals
    signal aux_2_main_hs_tdata  : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Processed data after second stage
    signal aux_2_main_hs_tdest  : std_logic_vector(DEST_WIDTH - 1 downto 0);        -- Destination ID after second stage
    signal aux_2_main_hs_tlast  : std_logic;                                        -- End-of-packet after second stage processing
    signal aux_2_main_hs_tvalid : std_logic;                                        -- Valid signal after second stage processing
    signal aux_2_main_hs_tready : std_logic;                                        -- Ready signal after second stage processing

    -- AXI Stream Colector signals
    signal aux_2_colector_hs_tdata  : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal aux_2_colector_hs_tdest  : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal aux_2_colector_hs_tlast  : std_logic;
    signal aux_2_colector_hs_tvalid : std_logic;
    signal aux_2_colector_hs_tready : std_logic;

    -- Logical AND operations for handshaking
    signal aux_2_main_hs_tvalid_and : std_logic;                                    -- AND operation for valid handshake
    signal aux_2_main_hs_tready_and : std_logic;                                    -- AND operation for ready handshake

    -- Metadata Collection Signals
    signal START_METADATA_COLECTOR  : std_logic;                                        -- Start collecting metadata
    signal DONE_CMD_SEND            : std_logic;                                        -- DONE_CMD_SEND signal
    signal DATA_HEADER_0            : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- First metadata header
    signal DATA_HEADER_1            : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);    -- Second metadata header
    signal TDEST_DATA_COLECTOR      : std_logic_vector(DEST_WIDTH - 1 downto 0);        -- Destination metadata
    signal DONE_HEADER_COLECTOR     : std_logic;                                        -- Header collection completed
    signal DONE_DATA_COLECTOR       : std_logic;                                        -- Data collection completed
    signal DONE_CALCULATE           : std_logic;                                        -- Data collection completed

    -- Address & Length Signals
    signal LENGTHE2F        : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);            -- Computed data length
    signal BASE_ADDRESS     : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);            -- Selected base address
    signal TDEST_LENGTH     : std_logic_vector(DEST_WIDTH - 1 downto 0);                -- Destination ID for length processing

    -- CMD signals
    signal aux_m_axis_cmd_valid : std_logic;                                            -- Command valid signal
    signal CMD_ISSUE            : std_logic;                                            -- Command issued signal

    -- AXI Stream Output Signals
    signal aux_m_axis_tdata  : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);           -- Final output data
    signal aux_m_axis_tdest  : std_logic_vector(DEST_WIDTH - 1 downto 0);               -- Final output destination
    signal aux_m_axis_tlast  : std_logic;                                               -- Final output end-of-packet signal
    signal aux_m_axis_tvalid : std_logic;                                               -- Final output valid signal
    signal aux_m_axis_tready : std_logic;                                               -- Final output ready signal

    signal flag_DONE_DATA_COLECTOR  : std_logic := '0';     -- FLAG DONE DATA COLECTOR
    signal flag_DONE_CMD_SEND       : std_logic := '0';     -- FLAG DONE CMD SEND

    -- Interrupt toggle signal
    -- signal aux_M_AXIS_S2MM_STS_tready : std_logic; -- Ready signal for AXI status monitoring

begin

    -- Map AXI Stream input signals to internal auxiliary registers
    aux_s_axis_tdata_0      <= s_hs_tdata_0;            -- Store input data from AXI Stream 0
    aux_s_axis_tlast_0      <= s_hs_tlast_0;            -- Store last signal from AXI Stream 0
    aux_s_axis_tvalid_0     <= s_hs_tvalid_0;           -- Store valid signal from AXI Stream 0
    s_hs_tready_0           <= aux_s_axis_tready_0;     -- Output ready signal for AXI Stream 0

    aux_s_axis_tdata_1      <= s_hs_tdata_1;            -- Store input data from AXI Stream 1
    aux_s_axis_tlast_1      <= s_hs_tlast_1;            -- Store last signal from AXI Stream 1
    aux_s_axis_tvalid_1     <= s_hs_tvalid_1;           -- Store valid signal from AXI Stream 1
    s_hs_tready_1           <= aux_s_axis_tready_1;     -- Output ready signal for AXI Stream 1

    aux_s_axis_tdata_2      <= s_hs_tdata_2;            -- Store input data from AXI Stream 2
    aux_s_axis_tlast_2      <= s_hs_tlast_2;            -- Store last signal from AXI Stream 2
    aux_s_axis_tvalid_2     <= s_hs_tvalid_2;           -- Store valid signal from AXI Stream 2
    s_hs_tready_2           <= aux_s_axis_tready_2;     -- Output ready signal for AXI Stream 2

    aux_s_axis_tdata_3      <= s_hs_tdata_3;            -- Store input data from AXI Stream 3
    aux_s_axis_tlast_3      <= s_hs_tlast_3;            -- Store last signal from AXI Stream 3
    aux_s_axis_tvalid_3     <= s_hs_tvalid_3;           -- Store valid signal from AXI Stream 3
    s_hs_tready_3           <= aux_s_axis_tready_3;     -- Output ready signal for AXI Stream 3

    -- Map processed data to the final AXI Stream output
    m_axis_tdata            <= aux_m_axis_tdata;        -- Output processed data
    m_axis_tdest            <= aux_m_axis_tdest;        -- Output destination ID
    m_axis_tlast            <= aux_m_axis_tlast;        -- Output end-of-packet signal
    m_axis_tvalid           <= aux_m_axis_tvalid;       -- Output valid signal
    aux_m_axis_tready       <= m_axis_tready;           -- Handshake ready signal

    -- Map processed command signals to output
    m_axis_cmd_valid        <= aux_m_axis_cmd_valid;    -- Output command valid signal


    -- Máquina de estados
    process(clk, n_rst)
    begin
        if n_rst = '0' then
            state <= IDLE_st;
        elsif rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    -- State transition logic
    process(clk, n_rst, state, flag_DONE_DATA_COLECTOR, flag_DONE_CMD_SEND)
    begin
        -- Default assignment: Hold the current state
        next_state <= state;

        case state is
            -- IDLE state: Waits for a new transaction to start
            when IDLE_st =>
                next_state <= START_st; -- Move to start state

            -- START state: Initiates metadata collection
            when START_st =>
                next_state <= IDLE_DONE_DATA_st; -- Move to header collection

            -- IDLE_DONE_DATA state: Waits until all data is processed
            when IDLE_DONE_DATA_st =>
                -- START_METADATA_COLECTOR <= '0';
                if ((flag_DONE_DATA_COLECTOR = '1') and (flag_DONE_CMD_SEND = '1'))  then -- TODO: FLAG USED FOR IDLE_DONE_DATA COLECT
                    next_state <= IDLE_st; -- Return to IDLE
                else
                    next_state <= IDLE_DONE_DATA_st; -- Wait for data collection to finish
                end if;

            -- Default case: Return to IDLE state if an undefined state is reached
            when others =>
                -- START_METADATA_COLECTOR <= '0';
                next_state <= IDLE_st;
        end case;
    end process;

    -- Flag CONTROL SIGNAL
    process(clk, n_rst)
    begin
        if n_rst = '0' then
            flag_DONE_DATA_COLECTOR <= '0';
            flag_DONE_CMD_SEND      <= '0';
        elsif rising_edge(clk) then
            -- PACK DATA SEND FLAG CONTROL
            if (state = IDLE_st) then
                flag_DONE_DATA_COLECTOR <= '0';
            elsif ((state = IDLE_DONE_DATA_st) and (DONE_DATA_COLECTOR = '1')) then
                flag_DONE_DATA_COLECTOR <= '1';
            end if;
            -- COMAND SEND FLAG CONTROL
            if (state = IDLE_st) then
                flag_DONE_CMD_SEND <= '0';
            elsif ((state = IDLE_DONE_DATA_st) and (DONE_CMD_SEND = '1')) then
                flag_DONE_CMD_SEND <= '1';
            end if;
        end if;
    end process;
    
    START_METADATA_COLECTOR <= '1' when state = START_st else '0';

    -- Instance of HsSkidBuf_Scheduler_dest
    -- This module manages the scheduling of incoming AXI Stream data from four sources
    -- and forwards the selected data to the next processing stage.
    u_HsSkidBuf_Scheduler_dest : entity work.HsSkidBuf_Scheduler_dest
    generic map (
        HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
        BYTE_WIDTH      => BYTE_WIDTH,
        INTERFACE_NUM   => INTERFACE_NUM,
        DEST_WIDTH      => DEST_WIDTH
    )
    port map(
        -- Clock input
        clk                 => clk,            

        -- AXI Stream inputs from four sources
        s_hs_tdata_0        => aux_s_axis_tdata_0, -- Data from AXI Stream source 0
        s_hs_tlast_0        => aux_s_axis_tlast_0, -- Last signal for source 0
        s_hs_tvalid_0       => aux_s_axis_tvalid_0, -- Valid signal for source 0
        s_hs_tready_0       => aux_s_axis_tready_0, -- Ready signal for source 0

        s_hs_tdata_1        => aux_s_axis_tdata_1, -- Data from AXI Stream source 1
        s_hs_tlast_1        => aux_s_axis_tlast_1, -- Last signal for source 1
        s_hs_tvalid_1       => aux_s_axis_tvalid_1, -- Valid signal for source 1
        s_hs_tready_1       => aux_s_axis_tready_1, -- Ready signal for source 1

        s_hs_tdata_2        => aux_s_axis_tdata_2, -- Data from AXI Stream source 2
        s_hs_tlast_2        => aux_s_axis_tlast_2, -- Last signal for source 2
        s_hs_tvalid_2       => aux_s_axis_tvalid_2, -- Valid signal for source 2
        s_hs_tready_2       => aux_s_axis_tready_2, -- Ready signal for source 2

        s_hs_tdata_3        => aux_s_axis_tdata_3, -- Data from AXI Stream source 3
        s_hs_tlast_3        => aux_s_axis_tlast_3, -- Last signal for source 3
        s_hs_tvalid_3       => aux_s_axis_tvalid_3, -- Valid signal for source 3
        s_hs_tready_3       => aux_s_axis_tready_3, -- Ready signal for source 3

        -- Outputs: Processed AXI Stream data
        m_hs_tdata          => aux_1_main_hs_tdata, -- Processed data output
        m_hs_tdest          => aux_1_main_hs_tdest, -- Destination ID output
        m_hs_tlast          => aux_1_main_hs_tlast, -- Last signal output
        m_hs_tvalid         => aux_1_main_hs_tvalid, -- Valid signal output
        m_hs_tready         => aux_1_main_hs_tready  -- Ready signal output
    );

    -- Instance of HsSkidBuf_dest
    -- Buffer module that holds and forwards AXI Stream data while handling flow control.
    u_HsSkidBuf_dest_main_1 : entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
            BYTE_WIDTH      => BYTE_WIDTH,
            INTERFACE_NUM   => INTERFACE_NUM,
            DEST_WIDTH      => DEST_WIDTH
        )
        port map(
            -- Clock input
            clk             => clk,
            
            -- AXI Stream input from previous processing stage
            s_hs_tdata      => aux_1_main_hs_tdata,     -- Input data
            s_hs_tdest      => aux_1_main_hs_tdest,     -- Input destination ID
            s_hs_tlast      => aux_1_main_hs_tlast,     -- End-of-packet signal
            s_hs_tvalid     => aux_1_main_hs_tvalid,    -- Valid input signal
            s_hs_tready     => aux_1_main_hs_tready,    -- Ready input signal
            
            -- AXI Stream output to next processing stage
            m_hs_tdata      => aux_2_main_hs_tdata,     -- Output data
            m_hs_tdest      => aux_2_main_hs_tdest,     -- Output destination ID
            m_hs_tlast      => aux_2_main_hs_tlast,     -- End-of-packet signal
            m_hs_tvalid     => aux_2_main_hs_tvalid,    -- Valid output signal
            m_hs_tready     => aux_2_main_hs_tready_and -- Ready output signal with lock control
        );

    -- HandShake: Apply flow control
    -- If any of tready signals are low keep lock
    aux_2_main_hs_tready_and    <= aux_2_colector_hs_tready and aux_2_main_hs_tready;
    aux_2_main_hs_tvalid_and    <= aux_2_main_hs_tready_and and aux_2_main_hs_tvalid;
    aux_2_colector_hs_tvalid    <= aux_2_main_hs_tvalid_and;

    -- Copy data signals to Colector data
    aux_2_colector_hs_tdata     <= aux_2_main_hs_tdata;
    aux_2_colector_hs_tdest     <= aux_2_main_hs_tdest;
    aux_2_colector_hs_tlast     <= aux_2_main_hs_tlast;

    -- Instance of DataColector_ROI_interpreter 
    -- Colect header and calculate base address and lenght package.
    u_dataColector_ROI_interpreter : entity work.dataColector_ROI_interpreter
        generic map (
            HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
            INTERFACE_NUM   => INTERFACE_NUM,
            DEST_WIDTH      => DEST_WIDTH,
            BYTE_WIDTH      => BYTE_WIDTH
        )
        port map(
            n_rst                   => n_rst,
            clk                     => clk,
            -- Enable signal
            Start_Metadata_Colector => Start_Metadata_Colector,
            DONE_CMD_SEND           => DONE_CMD_SEND,
            -- OFFSET ADDRESS
            base_address_A          => base_address_A,
            base_address_B          => base_address_B,
            -- AXIS-INTERFACE
            s_hs_tdata              => aux_2_colector_hs_tdata, 
            s_hs_tdest              => aux_2_colector_hs_tdest, 
            s_hs_tlast              => aux_2_colector_hs_tlast, 
            s_hs_tvalid             => aux_2_colector_hs_tvalid,
            s_hs_tready             => aux_2_colector_hs_tready,
    
            -- OUT LENGTH AND BASE ADDRESS
            lengthE2F               => lengthE2F,
            base_address            => base_address,
            
            -- Done signals
            DONE_HEADER_COLECTOR    => DONE_HEADER_COLECTOR,
            DONE_DATA_COLECTOR      => DONE_DATA_COLECTOR,
            DONE_CALCULATE          => DONE_CALCULATE
    
        );

    -- CMD send done signal
    DONE_CMD_SEND <= '1' when ((aux_m_axis_cmd_valid = '1') and (m_axis_cmd_ready = '1')) else '0';

    -- Instance of DATA_MOVER_CMD_GENERATOR
    -- Generates AXI Data Mover commands based on the computed length and base address.
    u_data_mover_cmd_gen : entity work.axis_cmd_gen_s2mm
    generic map (
        CMD_WIDTH => CMD_WIDTH  -- Command width
    )
    port map (
        s_axi_clk        => clk,                    -- AXI clock
        s_axi_resetn     => n_rst,                  -- Active-low reset
        base_address     => BASE_ADDRESS,           -- Base address for memory transaction
        burst_length     => LENGTHE2F(LENGTHE2F_WIDTH - 1 downto 0),    -- Number of words to transfer
        send_comand      => DONE_CALCULATE,            -- Issued when length computation is done
        s_axis_tdata     => m_axis_cmd_data,        -- Command data output
        s_axis_tkeep     => open,                   -- Unused keep signal
        s_axis_tvalid    => aux_m_axis_cmd_valid,   -- Valid command output
        s_axis_tlast     => m_axis_cmd_last,        -- End-of-command signal
        s_axis_tready    => m_axis_cmd_ready,       -- Ready signal for command reception
        cmd_issue        => CMD_ISSUE               -- Command issued flag
    );

    -- Instance of HsSkidBuf_dest
    -- Buffer module that holds and forwards AXI Stream data while handling flow control.
    u_HsSkidBuf_dest_main_2 : entity work.HsSkidBuf_dest
    generic map (
        HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
        BYTE_WIDTH      => BYTE_WIDTH,
        INTERFACE_NUM   => INTERFACE_NUM,
        DEST_WIDTH      => DEST_WIDTH
    )
    port map(
        -- Clock input
        clk             => clk,
        
        -- AXI Stream input from previous processing stage
        s_hs_tdata      => aux_2_main_hs_tdata, -- Input data
        s_hs_tdest      => aux_2_main_hs_tdest, -- Input destination ID
        s_hs_tlast      => aux_2_main_hs_tlast, -- End-of-packet signal
        s_hs_tvalid     => aux_2_main_hs_tvalid_and, -- Valid input signal with flow control
        s_hs_tready     => aux_2_main_hs_tready, -- Ready input signal
        
        -- AXI Stream output to next processing stage
        m_hs_tdata      => aux_m_axis_tdata, -- Output data
        m_hs_tdest      => aux_m_axis_tdest, -- Output destination ID
        m_hs_tlast      => aux_m_axis_tlast, -- End-of-packet signal
        m_hs_tvalid     => aux_m_axis_tvalid, -- Valid output signal
        m_hs_tready     => aux_m_axis_tready  -- Ready output signal
    );

    -- Instantiate `interrupt_toggler`
    -- This module generates interrupt signals based on data transfer events.
    inst_interrupt : entity work.interrupt_toggler
    generic map (
        CNT_MAX => CNT_MAX  -- Maximum count before toggling the interrupt
    )
    port map (
        clk     => clk,    -- System clock
        n_rst   => n_rst,  -- Active-low reset
        pulse   => M_AXIS_S2MM_STS_tvalid,  -- Pulse signal to trigger the interrupt
        INT_A   => INT_A,  -- Interrupt output A
        INT_B   => INT_B   -- Interrupt output B
    );

    M_AXIS_S2MM_STS_tready <= '1';                

end arch_top_axis4_to_axi_bridge;
