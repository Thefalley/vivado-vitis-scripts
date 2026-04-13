
----------------------------------------------------------------------------------
-- Company:        IKERLAN
-- Engineer:       Pablo Mendoza EGUIGUREN
--
-- Module Name:    top_axis4_to_axi_bridge_DM - RTL
-- File:           top_axis4_to_axi_bridge_DM.vhd
-- Created:        04/02/2025
--
-- Description:
-- This module implements a **data bridge between multiple AXI-Stream interfaces 
-- and an AXI Memory-Mapped (AXI-MM) interface**. It integrates an AXI Data Mover 
-- to efficiently transfer data from the AXI-Stream interfaces into memory.
--
-- Features:
-- 1. **AXI-Stream to AXI-MM Data Transfer:**
--    - Supports **4 AXI-Stream input interfaces** (`s_axis_tdata_0` to `s_axis_tdata_3`).
--    - Implements **AXI handshaking (`tvalid`, `tready`, `tlast`)** for flow control.
--    - Uses `top_axis4_to_axi_bridge` to aggregate and process incoming data.
--    - Interfaces with an **AXI Data Mover (`axi_datamover_0`)** to perform 
--      AXI-MM transactions.
--
-- 2. **AXI Data Mover Command Generation:**
--    - Commands are generated based on:
--      * **Base address selection** (`base_address_A`, `base_address_B`).
--      * **Calculated burst length** (`LENGTHE2F`).
--    - Command and data transactions are controlled via:
--      * `m_axis_cmd_data`: Command data for the AXI Data Mover.
--      * `m_axis_cmd_valid`: Indicates when a command is ready.
--      * `m_axi_s2mm_awaddr`: Target memory address for data storage.
--      * `m_axi_s2mm_wdata`: Data being written to memory.
--
-- 3. **Interrupt Handling for Data Transfers:**
--    - Implements **interrupt toggling** via `interrupt_toggler` to signal 
--      completion of transactions.
--    - Generates **two interrupt signals (`INT_A`, `INT_B`)** to notify 
--      the processing system (PS) about transfer completion.
--
-- 4. **AXI Transaction Monitoring:**
--    - Monitors AXI-MM responses (`m_axi_s2mm_bresp`, `m_axi_s2mm_bvalid`) 
--      to detect errors.
--    - Provides a **status output (`s2mm_err`)** to indicate transfer errors.
--    - Implements **ILA (Integrated Logic Analyzer) support** for debugging.
--
-- Usage:
-- - Incoming **AXI-Stream data is processed and stored in memory**.
-- - The module dynamically **computes burst length and base addresses**.
-- - The **AXI Data Mover executes the memory write transactions**.
-- - Interrupt signals toggle after **each completed data transfer**.
--
-- Parameters:
-- * **HS_TDATA_WIDTH**: Width of AXI Stream data (default: 32 bits).
-- * **INTERFACE_NUM**: Number of AXI-Stream input interfaces (default: 4).
-- * **CMD_WIDTH**: Width of the AXI Data Mover command (default: 72 bits).
-- * **LENGTHE2F_WIDTH**: Number of bits used for length computations.
-- * **CNT_MAX**: Number of transactions before toggling an interrupt.
--
-- Dependencies:
-- - `top_axis4_to_axi_bridge`: Aggregates and processes AXI-Stream data.
-- - `axi_datamover_0`: Performs AXI Memory-Mapped (AXI-MM) transactions.
-- - `interrupt_toggler`: Generates interrupt signals for the processing system.
--
-- Revision History:
-- Rev 1.0 - Initial release by Pablo Mendoza
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top_axis4_to_axi_bridge_DM is
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

        -- Base address
        base_address_A  : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        base_address_B  : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);

        -- AXI Stream input signals
        s_axis_tdata_0   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0); -- Data from source 0
        s_axis_tlast_0   : in  std_logic;                                     -- Last signal for source 0
        s_axis_tvalid_0  : in  std_logic;                                     -- Valid signal for source 0
        s_axis_tready_0  : out std_logic;                                     -- Ready signal for source 0

        s_axis_tdata_1   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0); -- Data from source 1
        s_axis_tlast_1   : in  std_logic;                                     -- Last signal for source 1
        s_axis_tvalid_1  : in  std_logic;                                     -- Valid signal for source 1
        s_axis_tready_1  : out std_logic;                                     -- Ready signal for source 1

        s_axis_tdata_2   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0); -- Data from source 2
        s_axis_tlast_2   : in  std_logic;                                     -- Last signal for source 2
        s_axis_tvalid_2  : in  std_logic;                                     -- Valid signal for source 2
        s_axis_tready_2  : out std_logic;                                     -- Ready signal for source 2

        s_axis_tdata_3   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0); -- Data from source 3
        s_axis_tlast_3   : in  std_logic;                                     -- Last signal for source 3
        s_axis_tvalid_3  : in  std_logic;                                     -- Valid signal for source 3
        s_axis_tready_3  : out std_logic;                                     -- Ready signal for source 3

        -- AXI interface output
        m_axi_s2mm_awid             : out std_logic_vector(3 DOWNTO 0);
        m_axi_s2mm_awaddr           : out std_logic_vector(31 DOWNTO 0);
        m_axi_s2mm_awlen            : out std_logic_vector(7 DOWNTO 0);
        m_axi_s2mm_awsize           : out std_logic_vector(2 DOWNTO 0);
        m_axi_s2mm_awburst          : out std_logic_vector(1 DOWNTO 0);
        m_axi_s2mm_awprot           : out std_logic_vector(2 DOWNTO 0);
        m_axi_s2mm_awcache          : out std_logic_vector(3 DOWNTO 0);
        m_axi_s2mm_awuser           : out std_logic_vector(3 DOWNTO 0);
        m_axi_s2mm_awvalid          : out std_logic;
        m_axi_s2mm_awready          : in  std_logic;
        m_axi_s2mm_wdata            : out std_logic_vector(31 DOWNTO 0);
        m_axi_s2mm_wstrb            : out std_logic_vector(3 DOWNTO 0);
        m_axi_s2mm_wlast            : out std_logic;
        m_axi_s2mm_wvalid           : out std_logic;
        m_axi_s2mm_wready           : in  std_logic;
        m_axi_s2mm_bresp            : in  std_logic_vector(1 DOWNTO 0);
        m_axi_s2mm_bvalid           : in  std_logic;
        m_axi_s2mm_bready           : out std_logic;

        s2mm_err                    : out std_logic;                        -- s2mm_err

        -- Interrupt signals
        INT_A                   : out std_logic;                            -- Interrupt A
        INT_B                   : out std_logic                             -- Interrupt B

    );
end top_axis4_to_axi_bridge_DM;

architecture arch_top_axis4_to_axi_bridge_DM of top_axis4_to_axi_bridge_DM is

    -- -- axis4_to_axi_bridge Output AXI-Stream signals
    signal m_axis_tdata             : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal m_axis_tdest             : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal m_axis_tlast             : std_logic;
    signal m_axis_tvalid            : std_logic;
    signal m_axis_tready            : std_logic := '0';

    -- axis4_to_axi_bridge OUTPUT Command signals
    signal m_axis_cmd_data          : std_logic_vector(CMD_WIDTH - 1 downto 0);
    signal m_axis_cmd_valid         : std_logic;
    -- signal m_axis_cmd_last  : std_logic;
    signal m_axis_cmd_ready         : std_logic := '0';

    -- AXI-Stream Data Mover status signals
    signal m_axis_s2mm_STS_tdata    : std_logic_vector(STS_DATA_WIDTH - 1 downto 0);
    signal m_axis_s2mm_STS_tkeep    : std_logic_vector(0 downto 0);
    signal m_axis_s2mm_STS_tlast    : std_logic;
    signal m_axis_s2mm_STS_tready   : std_logic;
    signal m_axis_s2mm_STS_tvalid   : std_logic;

begin

    -- DUT top_axis4_to_axi_bridge
    DUT_top_axis4_to_axi_bridge : entity work.top_axis4_to_axi_bridge
        generic map (
            HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
            BYTE_WIDTH      => BYTE_WIDTH,
            INTERFACE_NUM   => INTERFACE_NUM,
            DEST_WIDTH      => DEST_WIDTH,
            CMD_WIDTH       => CMD_WIDTH,
            CNT_MAX         => CNT_MAX
        )
        port map (
            -- Global control signals
            clk             => clk,
            n_rst           => n_rst,
            -- enable          => enable,

            base_address_A  => base_address_A,
            base_address_B  => base_address_B,

            -- Input AXI-Stream
            s_hs_tdata_0    => s_axis_tdata_0,
            s_hs_tlast_0    => s_axis_tlast_0,
            s_hs_tvalid_0   => s_axis_tvalid_0,
            s_hs_tready_0   => s_axis_tready_0,

            s_hs_tdata_1    => s_axis_tdata_1,
            s_hs_tlast_1    => s_axis_tlast_1,
            s_hs_tvalid_1   => s_axis_tvalid_1,
            s_hs_tready_1   => s_axis_tready_1,

            s_hs_tdata_2    => s_axis_tdata_2,
            s_hs_tlast_2    => s_axis_tlast_2,
            s_hs_tvalid_2   => s_axis_tvalid_2,
            s_hs_tready_2   => s_axis_tready_2,

            s_hs_tdata_3    => s_axis_tdata_3,
            s_hs_tlast_3    => s_axis_tlast_3,
            s_hs_tvalid_3   => s_axis_tvalid_3,
            s_hs_tready_3   => s_axis_tready_3,

            -- Output AXI-Stream
            m_axis_tdata    => m_axis_tdata,
            m_axis_tdest    => m_axis_tdest,
            m_axis_tlast    => m_axis_tlast,
            m_axis_tvalid   => m_axis_tvalid,
            m_axis_tready   => m_axis_tready,

            -- Command interface
            m_axis_cmd_data         => m_axis_cmd_data,
            m_axis_cmd_valid        => m_axis_cmd_valid,
            -- m_axis_cmd_last      => m_axis_cmd_last,
            m_axis_cmd_ready        => m_axis_cmd_ready,

            -- Status interface
            M_AXIS_S2MM_STS_tdata   => M_AXIS_S2MM_STS_tdata,
            M_AXIS_S2MM_STS_tkeep   => M_AXIS_S2MM_STS_tkeep,
            M_AXIS_S2MM_STS_tlast   => M_AXIS_S2MM_STS_tlast,
            M_AXIS_S2MM_STS_tready  => M_AXIS_S2MM_STS_tready,
            M_AXIS_S2MM_STS_tvalid  => M_AXIS_S2MM_STS_tvalid,

            -- Interrupt
            INT_A     => INT_A,    
            INT_B     => INT_B     
        );

        DUT_axi_datamover_0 : entity work.axi_datamover_0
            port map (
                m_axi_s2mm_aclk               => clk,
                m_axi_s2mm_aresetn            => n_rst,
                m_axis_s2mm_cmdsts_awclk      => clk,
                m_axis_s2mm_cmdsts_aresetn    => n_rst,

                s_axis_s2mm_tdata             => m_axis_tdata,
                s_axis_s2mm_tkeep             => (others => '1'),
                s_axis_s2mm_tlast             => m_axis_tlast,
                s_axis_s2mm_tvalid            => m_axis_tvalid,
                s_axis_s2mm_tready            => m_axis_tready,

                s_axis_s2mm_cmd_tvalid        => m_axis_cmd_valid,
                s_axis_s2mm_cmd_tready        => m_axis_cmd_ready,
                s_axis_s2mm_cmd_tdata         => m_axis_cmd_data,

                m_axi_s2mm_awid               => m_axi_s2mm_awid,
                m_axi_s2mm_awaddr             => m_axi_s2mm_awaddr,
                m_axi_s2mm_awlen              => m_axi_s2mm_awlen,
                m_axi_s2mm_awsize             => m_axi_s2mm_awsize,
                m_axi_s2mm_awburst            => m_axi_s2mm_awburst,
                m_axi_s2mm_awprot             => m_axi_s2mm_awprot,
                m_axi_s2mm_awcache            => m_axi_s2mm_awcache,
                m_axi_s2mm_awuser             => m_axi_s2mm_awuser,
                m_axi_s2mm_awvalid            => m_axi_s2mm_awvalid,
                m_axi_s2mm_awready            => m_axi_s2mm_awready,
                m_axi_s2mm_wdata              => m_axi_s2mm_wdata,
                m_axi_s2mm_wstrb              => m_axi_s2mm_wstrb,
                m_axi_s2mm_wlast              => m_axi_s2mm_wlast,
                m_axi_s2mm_wvalid             => m_axi_s2mm_wvalid,
                m_axi_s2mm_wready             => m_axi_s2mm_wready,
                m_axi_s2mm_bresp              => m_axi_s2mm_bresp,
                m_axi_s2mm_bvalid             => m_axi_s2mm_bvalid,
                m_axi_s2mm_bready             => m_axi_s2mm_bready,

                m_axis_s2mm_sts_tvalid        => M_AXIS_S2MM_STS_tvalid,
                m_axis_s2mm_sts_tready        => M_AXIS_S2MM_STS_tready,
                m_axis_s2mm_sts_tdata         => M_AXIS_S2MM_STS_tdata,
                m_axis_s2mm_sts_tkeep         => M_AXIS_S2MM_STS_tkeep,
                m_axis_s2mm_sts_tlast         => M_AXIS_S2MM_STS_tlast,

                s2mm_err                      => s2mm_err
            );

end arch_top_axis4_to_axi_bridge_DM;