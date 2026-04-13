----------------------------------------------------------------------------------
-- Module Name: HsSkidBuf_Scheduler
-- Description:
-- This module implements a state machine-based scheduler designed to manage 
-- data flow between multiple HsSkidBuf modules and a downstream AXI-Stream 
-- interface. It performs the following tasks:
--
-- - Reads and processes headers and data from up to 4 input HsSkidBuf modules.
-- - Controls the flow of data using handshake signals (`valid`, `ready`, and `last`).
-- - Outputs combined data streams based on a state-driven multiplexing mechanism.
-- - Provides control signals (`header_collection_done` and `data_collection_done`) 
--   to indicate the completion of header and data processing.
--
-- Features:
-- - Simple state machine for sequential processing.
-- - Input flow control based on `ready_for_header` and `ready_for_data` signals.
-- - Multiplexed output to a single AXI-Stream-compatible interface.
--
-- Notes:
-- - This module blocks or routes data based on the received inputs and the 
--   current state of the scheduler.
-- - It is designed to be configurable via generic parameters for data width.
----------------------------------------------------------------------------------

-- VHDL-2008

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
-- use work.MathUtils.all;

entity HsSkidBuf_Scheduler_dest is
    generic (
        HS_TDATA_WIDTH  : integer := 32;
        BYTE_WIDTH      : integer := 8;
        INTERFACE_NUM   : integer := 4;
        DEST_WIDTH      : integer := 2  
    );
    port (
        --reset_n        : in  std_logic;
        clk            : in  std_logic;

        -- Entradas de los 4 módulos HsSkidBuf
        s_hs_tdata_0   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        --s_hs_tdest_0   : in  std_logic_vector(log2(INTERFACE_NUM) - 1 downto 0);
        s_hs_tlast_0   : in  std_logic;
        s_hs_tvalid_0  : in  std_logic;
        s_hs_tready_0  : out std_logic;

        s_hs_tdata_1   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        --s_hs_tdest_1   : in  std_logic_vector(log2(INTERFACE_NUM) - 1 downto 0);
        s_hs_tlast_1   : in  std_logic;
        s_hs_tvalid_1  : in  std_logic;
        s_hs_tready_1  : out std_logic;

        s_hs_tdata_2   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        --s_hs_tdest_2   : in  std_logic_vector(log2(INTERFACE_NUM) - 1 downto 0);
        s_hs_tlast_2   : in  std_logic;
        s_hs_tvalid_2  : in  std_logic;
        s_hs_tready_2  : out std_logic;

        s_hs_tdata_3   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        --s_hs_tdest_3   : in  std_logic_vector(log2(INTERFACE_NUM) - 1 downto 0);
        s_hs_tlast_3   : in  std_logic;
        s_hs_tvalid_3  : in  std_logic;
        s_hs_tready_3  : out std_logic;

        -- Salidas combinadas (después del multiplexor)
        m_hs_tdata     : out std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        m_hs_tdest     : out std_logic_vector(DEST_WIDTH - 1 downto 0);
        m_hs_tlast     : out std_logic;
        m_hs_tvalid    : out std_logic;
        m_hs_tready    : in  std_logic
    );
end HsSkidBuf_Scheduler_dest;

architecture arch_HsSkidBuf_Scheduler_dest of HsSkidBuf_Scheduler_dest is

    signal aux0_hs_tready_0 : std_logic := '0';
    signal aux0_hs_tready_1 : std_logic := '0';
    signal aux0_hs_tready_2 : std_logic := '0';
    signal aux0_hs_tready_3 : std_logic := '0';

    -- Signal AUX1 (INPUT - MUX)
    signal aux1_hs_tdata_0, aux1_hs_tdata_1, aux1_hs_tdata_2, aux1_hs_tdata_3       : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal aux1_hs_tdest_0, aux1_hs_tdest_1, aux1_hs_tdest_2, aux1_hs_tdest_3       : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal aux1_hs_tlast_0, aux1_hs_tlast_1, aux1_hs_tlast_2, aux1_hs_tlast_3       : std_logic;
    signal aux1_hs_tvalid_0, aux1_hs_tvalid_1, aux1_hs_tvalid_2, aux1_hs_tvalid_3   : std_logic;
    signal aux1_hs_tready_0, aux1_hs_tready_1, aux1_hs_tready_2, aux1_hs_tready_3   : std_logic;

    -- Signal AUX2 (Mux - MAIN(data mover))
    signal aux2_hs_tdata  : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal aux2_hs_tdest  : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal aux2_hs_tlast  : std_logic;
    signal aux2_hs_tvalid : std_logic;
    signal aux2_hs_tready : std_logic;

    -- Signal AUX3 (MAIN(data mover) - OUTPUT)
    signal aux3_hs_tdata  : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal aux3_hs_tdest  : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal aux3_hs_tlast  : std_logic;
    signal aux3_hs_tvalid : std_logic;
    signal aux3_hs_tready : std_logic;

    -- Selector signal declaration
    signal scheduler_sel : std_logic_vector(3-1 downto 0); -- TODO: Variable para controlar scheduler witdh (interface constant)


    type state_type is (
        MUX0_DATA_st,   -- Processing data for interface 0
        MUX1_DATA_st,   -- Processing data for interface 1
        MUX2_DATA_st,   -- Processing data for interface 2
        MUX3_DATA_st    -- Processing data for interface 3
    );
    signal state : state_type := MUX0_DATA_st; -- Initialize the state to the first interface's idle state
    signal next_state : state_type;         -- Define the next state for the state machine

    begin

    -- Tready signal conection
    s_hs_tready_0   <= aux1_hs_tready_0; -- aux0_hs_tready_0;
    s_hs_tready_1   <= aux1_hs_tready_1; -- aux0_hs_tready_1;
    s_hs_tready_2   <= aux1_hs_tready_2; -- aux0_hs_tready_2;
    s_hs_tready_3   <= aux1_hs_tready_3; -- aux0_hs_tready_3;

    -- output conections
    m_hs_tdata      <= aux3_hs_tdata;
    m_hs_tdest      <= aux3_hs_tdest;
    m_hs_tlast      <= aux3_hs_tlast;
    m_hs_tvalid     <= aux3_hs_tvalid;
    m_hs_tdest      <= aux3_hs_tdest;
    aux3_hs_tready  <=  m_hs_tready;

    ------ HsSkidBuf input stantiation
    ----HsSkidBuf_input_0: entity work.HsSkidBuf_dest
    ----    generic map (
    ----        HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
    ----        BYTE_WIDTH      => BYTE_WIDTH,
    ----        INTERFACE_NUM   => INTERFACE_NUM
    ----    )
    ----    port map (
    ----        clk          => clk,
    ----        s_hs_tdata   => s_hs_tdata_0,
    ----        s_hs_tdest   => "00",
    ----        s_hs_tlast   => s_hs_tlast_0,
    ----        s_hs_tvalid  => s_hs_tvalid_0,
    ----        s_hs_tready  => aux0_hs_tready_0,
    ----        m_hs_tdata   => aux1_hs_tdata_0,
    ----        m_hs_tdest   => aux1_hs_tdest_0,
    ----        m_hs_tlast   => aux1_hs_tlast_0,
    ----        m_hs_tvalid  => aux1_hs_tvalid_0,
    ----        m_hs_tready  => aux1_hs_tready_0
    ----    );
----
    ----HsSkidBuf_input_1: entity work.HsSkidBuf_dest
    ----    generic map (
    ----        HS_TDATA_WIDTH => HS_TDATA_WIDTH,
    ----        BYTE_WIDTH     => BYTE_WIDTH,
    ----        INTERFACE_NUM   => INTERFACE_NUM
    ----    )
    ----    port map (
    ----        clk          => clk,
    ----        s_hs_tdata   => s_hs_tdata_1,
    ----        s_hs_tdest   => "01",
    ----        s_hs_tlast   => s_hs_tlast_1,
    ----        s_hs_tvalid  => s_hs_tvalid_1,
    ----        s_hs_tready  => aux0_hs_tready_1,
    ----        m_hs_tdata   => aux1_hs_tdata_1,
    ----        m_hs_tdest   => aux1_hs_tdest_1,
    ----        m_hs_tlast   => aux1_hs_tlast_1,
    ----        m_hs_tvalid  => aux1_hs_tvalid_1,
    ----        m_hs_tready  => aux1_hs_tready_1
    ----    );
----
    ----HsSkidBuf_input_2: entity work.HsSkidBuf_dest
    ----    generic map (
    ----        HS_TDATA_WIDTH => HS_TDATA_WIDTH,
    ----        BYTE_WIDTH     => BYTE_WIDTH,
    ----        INTERFACE_NUM   => INTERFACE_NUM
    ----    )
    ----    port map (
    ----        clk          => clk,
    ----        s_hs_tdata   => s_hs_tdata_2,
    ----        s_hs_tdest   => "10",
    ----        s_hs_tlast   => s_hs_tlast_2,
    ----        s_hs_tvalid  => s_hs_tvalid_2,
    ----        s_hs_tready  => aux0_hs_tready_2,
    ----        m_hs_tdata   => aux1_hs_tdata_2,
    ----        m_hs_tdest   => aux1_hs_tdest_2,
    ----        m_hs_tlast   => aux1_hs_tlast_2,
    ----        m_hs_tvalid  => aux1_hs_tvalid_2,
    ----        m_hs_tready  => aux1_hs_tready_2
    ----    );
----
    ----HsSkidBuf_input_3: entity work.HsSkidBuf_dest
    ----    generic map (
    ----        HS_TDATA_WIDTH => HS_TDATA_WIDTH,
    ----        BYTE_WIDTH     => BYTE_WIDTH,
    ----        INTERFACE_NUM   => INTERFACE_NUM
    ----    )
    ----    port map (
    ----        clk          => clk,
    ----        s_hs_tdata   => s_hs_tdata_3,
    ----        s_hs_tdest   => "11",
    ----        s_hs_tlast   => s_hs_tlast_3,
    ----        s_hs_tvalid  => s_hs_tvalid_3,
    ----        s_hs_tready  => aux0_hs_tready_3,
    ----        m_hs_tdata   => aux1_hs_tdata_3,
    ----        m_hs_tdest   => aux1_hs_tdest_3,
    ----        m_hs_tlast   => aux1_hs_tlast_3,
    ----        m_hs_tvalid  => aux1_hs_tvalid_3,
    ----        m_hs_tready  => aux1_hs_tready_3
    ----    );

    -- Multiplexer Process
    -- This process selects one of the four input streams and routes it to the output
    -- based on the value of the scheduler_sel signal. It also manages the tready
    -- signals for flow control, ensuring that only the selected input stream is active.
    process(scheduler_sel, 
        s_hs_tdata_0, s_hs_tlast_0, s_hs_tvalid_0, 
        s_hs_tdata_1, s_hs_tlast_1, s_hs_tvalid_1, 
        s_hs_tdata_2, s_hs_tlast_2, s_hs_tvalid_2, 
        s_hs_tdata_3, s_hs_tlast_3, s_hs_tvalid_3, 
        aux2_hs_tready
    )
    begin
        case scheduler_sel is
            when "000" =>
                aux2_hs_tdata       <= s_hs_tdata_0;
                aux2_hs_tlast       <= s_hs_tlast_0;
                aux2_hs_tvalid      <= s_hs_tvalid_0;
                aux2_hs_tdest       <= "00";-- aux1_hs_tdest_0;
                aux1_hs_tready_0    <= aux2_hs_tready;
                aux1_hs_tready_1    <= '0';
                aux1_hs_tready_2    <= '0';
                aux1_hs_tready_3    <= '0';
            when "001" =>
                --aux2_hs_tdata       <= aux1_hs_tdata_1;
                --aux2_hs_tlast       <= aux1_hs_tlast_1;
                --aux2_hs_tvalid      <= aux1_hs_tvalid_1;
                --aux2_hs_tdest       <= aux1_hs_tdest_1;
                aux2_hs_tdata       <= s_hs_tdata_1;
                aux2_hs_tlast       <= s_hs_tlast_1;
                aux2_hs_tvalid      <= s_hs_tvalid_1;
                aux2_hs_tdest       <= "01";
                aux1_hs_tready_0    <= '0';
                aux1_hs_tready_1    <= aux2_hs_tready;
                aux1_hs_tready_2    <= '0';
                aux1_hs_tready_3    <= '0';
            when "010" =>
                --aux2_hs_tdata       <= aux1_hs_tdata_2;
                --aux2_hs_tlast       <= aux1_hs_tlast_2;
                --aux2_hs_tvalid      <= aux1_hs_tvalid_2;
                --aux2_hs_tdest       <= aux1_hs_tdest_2;
                aux2_hs_tdata       <= s_hs_tdata_2;
                aux2_hs_tlast       <= s_hs_tlast_2;
                aux2_hs_tvalid      <= s_hs_tvalid_2;
                aux2_hs_tdest       <= "10";
                aux1_hs_tready_0    <= '0';
                aux1_hs_tready_1    <= '0';
                aux1_hs_tready_2    <= aux2_hs_tready;
                aux1_hs_tready_3    <= '0';
            when "011" =>
                -- aux2_hs_tdata       <= aux1_hs_tdata_3;
                -- aux2_hs_tlast       <= aux1_hs_tlast_3;
                -- aux2_hs_tvalid      <= aux1_hs_tvalid_3;
                -- aux2_hs_tdest       <= aux1_hs_tdest_3;
                aux2_hs_tdata       <= s_hs_tdata_3;
                aux2_hs_tlast       <= s_hs_tlast_3;
                aux2_hs_tvalid      <= s_hs_tvalid_3;
                aux2_hs_tdest       <= "11";
                aux1_hs_tready_0    <= '0';
                aux1_hs_tready_1    <= '0';
                aux1_hs_tready_2    <= '0';
                aux1_hs_tready_3    <= aux2_hs_tready;
            when others =>
                aux2_hs_tdata       <= (others => '0');
                aux2_hs_tlast       <= '0';
                aux2_hs_tvalid      <= '0';
                aux2_hs_tdest       <= "00";
                aux1_hs_tready_0    <= '0';
                aux1_hs_tready_1    <= '0';
                aux1_hs_tready_2    <= '0';
                aux1_hs_tready_3    <= '0';
        
        end case;
    end process;

    -- HsSkidBuf output entity
    HsSkidBuf_main_0: entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH  => HS_TDATA_WIDTH,
            BYTE_WIDTH      => BYTE_WIDTH,
            INTERFACE_NUM   => INTERFACE_NUM
        )
        port map (
            clk          => clk,
            s_hs_tdata   => aux2_hs_tdata, 
            s_hs_tdest   => aux2_hs_tdest, 
            s_hs_tlast   => aux2_hs_tlast, 
            s_hs_tvalid  => aux2_hs_tvalid,
            s_hs_tready  => aux2_hs_tready,
            m_hs_tdata   => aux3_hs_tdata, 
            m_hs_tdest   => aux3_hs_tdest, 
            m_hs_tlast   => aux3_hs_tlast, 
            m_hs_tvalid  => aux3_hs_tvalid,
            m_hs_tready  => aux3_hs_tready
        );


    --------------------------------------------------------------------------------
    -- State register
    --------------------------------------------------------------------------------
    process(clk)
    begin
    if rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    -- Next state combinational logic
    process(state, aux2_hs_tlast, aux2_hs_tready, aux2_hs_tvalid)
    begin
        case state is
            -- Interface 0
            when MUX0_DATA_st => 
                -- Process the data for Interface 0
                if (aux2_hs_tlast = '1') and (aux2_hs_tready = '1') and (aux2_hs_tvalid = '1') then
                    next_state <= MUX1_DATA_st; -- Return to idle after data processing
                else 
                    next_state <= MUX0_DATA_st; -- Continue processing data
                end if;
             
            -- Interface 1
            when MUX1_DATA_st => 
                -- Process the data for Interface 1
                if (aux2_hs_tlast = '1') and (aux2_hs_tready = '1') and (aux2_hs_tvalid = '1')  then
                    next_state <= MUX2_DATA_st; -- Return to idle after data processing
                else 
                    next_state <= MUX1_DATA_st; -- Continue processing data
                end if;
                
            -- Interface 2
            when MUX2_DATA_st => 
                -- Process the data for Interface 2
                if (aux2_hs_tlast = '1') and (aux2_hs_tready = '1') and (aux2_hs_tvalid = '1') then
                    next_state <= MUX3_DATA_st; -- Return to idle after data processing
                else 
                    next_state <= MUX2_DATA_st; -- Continue processing data
                end if;
                
            -- Interface 3
            when MUX3_DATA_st => 
                -- Process the data for Interface 3
                if (aux2_hs_tlast = '1') and (aux2_hs_tready = '1') and (aux2_hs_tvalid = '1') then
                    next_state <= MUX0_DATA_st; -- Return to idle after data processing
                else 
                    next_state <= MUX3_DATA_st; -- Continue processing data
                end if;
        end case;
    end process;


    scheduler_sel <= 
            -- Case 000: Enable slave_tready0 (Others: '0')
            "000" when (state = MUX0_DATA_st) else -- Processing data for channel 0

            -- Case 001: Enable slave_tready1 (Others: '0')
            "001" when (state = MUX1_DATA_st) else -- Processing data for channel 1

            -- Case 010: Enable slave_tready2 (Others: '0')
            "010" when (state = MUX2_DATA_st) else -- Processing data for channel 2

            -- Case 011: Enable slave_tready3 (Others: '0')
            "011" when (state = MUX3_DATA_st) else -- Processing data for channel 3

            -- Default case: Prevent any unexpected behavior
            "100"; -- Reset state, all channels disabled    

end arch_HsSkidBuf_Scheduler_dest;