----------------------------------------------------------------------------------
-- Company:        IKERLAN
-- Engineer:       PABLO MENDOZA EGUIGUREN
--
-- Module Name:    tester_axis4_to_axi_bridge - RTL
-- File:           tester_axis4_to_axi_bridge.vhd
-- Created:        04/02/2025
--
-- Description:
-- This module serves as a bridge between an AXI-Lite Slave interface and 
-- four AXI-Stream Master interfaces. It allows external controllers 
-- (e.g., processors) to configure and initiate multiple data streams 
-- via AXI-Stream using AXI-Lite control signals.
--
-- Features:
-- 1. AXI-Lite Slave Interface:
--    - Allows configuration of data stream parameters such as:
--      * Number of words to transmit.
--      * Initial data values.
--      * Base addresses for different outputs.
--    - Start and reset signals are managed through AXI-Lite registers.
--
-- 2. AXI-Stream Master Interfaces:
--    - Four independent AXI-Stream outputs (`master_0` to `master_3`) 
--      can be controlled simultaneously.
--    - Each stream can generate custom data based on parameters set 
--      via AXI-Lite.
--    - Option to use deterministic (`AXI_Stream_Master_meta`) or 
--      random (`AXI_Stream_Random_Master_meta`) data generators.
--
-- 3. Finite State Machine (FSM):
--    - **IDLE:** Waits for start signal (`0xFFFFFFFF`).
--    - **PULSE:** Issues a start pulse to all stream masters.
--    - **UNLOCKED:** Continuous streaming until a reset command (`0xFF00FF00`) is received.
--    - **RESETTING:** Resets internal states and returns to IDLE.
--
-- Usage:
-- - Configure data stream parameters via the AXI-Lite interface.
-- - Write `0xFFFFFFFF` to the start register (`aux_start_0`) to initiate streaming.
-- - Write `0xFF00FF00` to reset the module and stop data transmission.
-- - Choose between random or deterministic data generation by selecting
--   the appropriate AXI-Stream Master entity.
--
-- Parameters:
-- * `C_S_AXI_DATA_WIDTH`: Defines the data width of the AXI-Lite and AXI-Stream interfaces (default: 32 bits).
-- * `C_S_AXI_ADDR_WIDTH`: Defines the address width of the AXI-Lite interface (default: 7 bits).
--
-- Dependencies:
-- - S00_AXI_32_REG: AXI-Lite slave module for configuration.
-- - AXI_Stream_Random_Master_meta or AXI_Stream_Master_meta: 
--   Modules for generating AXI-Stream data.
--
-- Revision:
-- Rev 1.0 - Initial release
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tester_axis4_to_axi_bridge is
    generic(
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 7
    );
    port (
        -- Global Clock and Reset
        clk           : in  std_logic;
        n_rst         : in  std_logic;

        -- AXI Slave Interface
        S_AXI_AWADDR  : in  std_logic_vector(6 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector(3 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(6 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic;

        -- Base address output
        o_base_address_A    : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        o_base_address_B    : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);

        -- Interface AXI-STREAM
        o_s_hs_tdata_0      : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        o_s_hs_tvalid_0     : out std_logic;
        o_s_hs_tlast_0      : out std_logic;
        o_s_hs_tready_0     : in  std_logic;
        o_s_hs_tdata_1      : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        o_s_hs_tvalid_1     : out std_logic;
        o_s_hs_tlast_1      : out std_logic;
        o_s_hs_tready_1     : in  std_logic;
        o_s_hs_tdata_2      : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        o_s_hs_tvalid_2     : out std_logic;
        o_s_hs_tlast_2      : out std_logic;
        o_s_hs_tready_2     : in  std_logic;
        o_s_hs_tdata_3      : out std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
        o_s_hs_tvalid_3     : out std_logic;
        o_s_hs_tlast_3      : out std_logic;
        o_s_hs_tready_3     : in std_logic

    );
end tester_axis4_to_axi_bridge;

architecture rtl of tester_axis4_to_axi_bridge is

    -- Internal signals for connecting the AXI Slave module
    signal aux_start_0          : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_num_words_0      : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_0_0   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_1_0   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_start_1          : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_num_words_1      : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_0_1   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_1_1   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_start_2          : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_num_words_2      : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_0_2   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_1_2   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_start_3          : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_num_words_3      : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_0_3   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_init_value_1_3   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_base_address_A   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);
    signal aux_base_address_B   : std_logic_vector(C_S_AXI_DATA_WIDTH - 1 downto 0);

    -- START SIGNAL
    signal master_start_0       : std_logic;
    signal master_start_1       : std_logic;
    signal master_start_2       : std_logic;
    signal master_start_3       : std_logic;

    -- FSM States
    type state_type is (IDLE, PULSE, UNLOCKED, RESETTING);
    signal state, next_state : state_type := IDLE;

    -- Control Signals
    signal start_pulse   : std_logic := '0';

begin

    process(clk, state)
    begin
        if rising_edge(clk) then
            if state = IDLE then
                o_base_address_A  <= aux_base_address_A;
                o_base_address_B  <= aux_base_address_B;
            end if;
        end if;
    end process;

    -- FSM State Transition Process
    process(clk, n_rst)
    begin
        if n_rst = '0' then
            state <= IDLE;
        elsif rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    -- FSM Next State Logic
    process(state, aux_start_0)
    begin
        case state is
            when IDLE =>
                if aux_start_0 = x"FFFFFFFF" then
                    next_state <= PULSE;
                else
                    next_state <= IDLE;
                end if;

            when PULSE =>
                next_state <= UNLOCKED;

            when UNLOCKED =>
                if aux_start_0 = x"FF00FF00" then
                    next_state <= RESETTING;
                else
                    next_state <= UNLOCKED;
                end if;

            when RESETTING =>
                next_state <= IDLE;

            when others =>
                next_state <= IDLE;
        end case;
    end process;

    start_pulse <= '1' when state = PULSE else '0';

    -- Assign `start_X` signals
    master_start_0 <= start_pulse;
    master_start_1 <= start_pulse;
    master_start_2 <= start_pulse;
    master_start_3 <= start_pulse;

    -- Instantiation of myip_v1_0_S00_AXI
    axi_slave_inst : entity work.S00_AXI_32_REG
        generic map (
            C_S_AXI_DATA_WIDTH => C_S_AXI_DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH
        )
        port map (
            -- Output signals
            o_start_0        => aux_start_0,
            o_num_words_0    => aux_num_words_0,
            o_init_value_0_0 => aux_init_value_0_0,
            o_init_value_1_0 => aux_init_value_1_0,
            o_start_1        => aux_start_1,
            o_num_words_1    => aux_num_words_1,
            o_init_value_0_1 => aux_init_value_0_1,
            o_init_value_1_1 => aux_init_value_1_1,
            o_start_2        => aux_start_2,
            o_num_words_2    => aux_num_words_2,
            o_init_value_0_2 => aux_init_value_0_2,
            o_init_value_1_2 => aux_init_value_1_2,
            o_start_3        => aux_start_3,
            o_num_words_3    => aux_num_words_3,
            o_init_value_0_3 => aux_init_value_0_3,
            o_init_value_1_3 => aux_init_value_1_3,
            o_base_address_A => aux_base_address_A,
            o_base_address_B => aux_base_address_B,

            -- AXI Interface
            S_AXI_ACLK    => clk,
            S_AXI_ARESETN => n_rst,
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

    -- AXI Stream Master instantiation (4 instances for each input group)
    master_0: entity work.AXI_Stream_Random_Master_meta
    -- master_0: entity work.AXI_Stream_Master_meta
        generic map (
            DATA_WIDTH => C_S_AXI_DATA_WIDTH
        )
        port map (
            clk             => clk,
            reset_n         => n_rst,
            start           => master_start_0,
            num_words       => aux_num_words_0,
            init_value_0    => aux_init_value_0_0,
            init_value_1    => aux_init_value_1_0,
            m_axis_tdata    => o_s_hs_tdata_0,
            m_axis_tvalid   => o_s_hs_tvalid_0,
            m_axis_tlast    => o_s_hs_tlast_0,
            m_axis_tready   => o_s_hs_tready_0
        );
    
    -- AXI Stream Master instantiation (4 instances for each input group)
    master_1: entity work.AXI_Stream_Random_Master_meta
    -- master_1: entity work.AXI_Stream_Master_meta
        generic map (
            DATA_WIDTH => C_S_AXI_DATA_WIDTH
        )
        port map (
            clk             => clk,
            reset_n         => n_rst,
            start           => master_start_1,
            num_words       => aux_num_words_1,
            init_value_0    => aux_init_value_0_1,
            init_value_1    => aux_init_value_1_1,
            m_axis_tdata    => o_s_hs_tdata_1,
            m_axis_tvalid   => o_s_hs_tvalid_1,
            m_axis_tlast    => o_s_hs_tlast_1,
            m_axis_tready   => o_s_hs_tready_1
        );
 
    -- AXI Stream Master instantiation (4 instances for each input group)
    master_2: entity work.AXI_Stream_Random_Master_meta
    -- master_2: entity work.AXI_Stream_Master_meta
        generic map (
            DATA_WIDTH => C_S_AXI_DATA_WIDTH
        )
        port map (
            clk             => clk,
            reset_n         => n_rst,
            start           => master_start_2,
            num_words       => aux_num_words_2,
            init_value_0    => aux_init_value_0_2,
            init_value_1    => aux_init_value_1_2,
            m_axis_tdata    => o_s_hs_tdata_2,
            m_axis_tvalid   => o_s_hs_tvalid_2,
            m_axis_tlast    => o_s_hs_tlast_2,
            m_axis_tready   => o_s_hs_tready_2
        );
 
    -- AXI Stream Master instantiation (4 instances for each input group)
    master_3: entity work.AXI_Stream_Random_Master_meta
    -- master_3: entity work.AXI_Stream_Master_meta
        generic map (
            DATA_WIDTH => C_S_AXI_DATA_WIDTH
        )
        port map (
            clk             => clk,
            reset_n         => n_rst,
            start           => master_start_3,
            num_words       => aux_num_words_3,
            init_value_0    => aux_init_value_0_3,
            init_value_1    => aux_init_value_1_3,
            m_axis_tdata    => o_s_hs_tdata_3,
            m_axis_tvalid   => o_s_hs_tvalid_3,
            m_axis_tlast    => o_s_hs_tlast_3,
            m_axis_tready   => o_s_hs_tready_3
        );

end rtl;

