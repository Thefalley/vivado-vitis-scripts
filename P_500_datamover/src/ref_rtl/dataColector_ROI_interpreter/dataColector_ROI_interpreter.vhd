library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity dataColector_ROI_interpreter is
    generic (
        HS_TDATA_WIDTH : integer := 32; -- Ancho de los datos
        INTERFACE_NUM  : integer := 4;   -- Number of AXI Stream input interfaces
        DEST_WIDTH     : integer := 2;
        BYTE_WIDTH     : integer := 8 -- TODO: sobra
    );
    port (
        n_rst                   : in  std_logic;
        clk                     : in  std_logic;
        -- Enable signal
        Start_Metadata_Colector : in std_logic;
        DONE_CMD_SEND           : in std_logic;
        -- OFFSET ADDRESS
        base_address_A          : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        base_address_B          : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        -- AXIS-INTERFACE
        s_hs_tdata              : in std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        s_hs_tdest              : in std_logic_vector(DEST_WIDTH - 1 downto 0);
        s_hs_tlast              : in std_logic;
        s_hs_tvalid             : in std_logic;
        s_hs_tready             : out std_logic;

        -- OUT LENGTH AND BASE ADDRESS
        lengthE2F               : out std_logic_vector(31 downto 0); -- Output data
        base_address            : out std_logic_vector(31 downto 0);
        
        -- Done signals
        DONE_HEADER_COLECTOR    : out std_logic;
        DONE_DATA_COLECTOR      : out std_logic;
        DONE_CALCULATE          : out std_logic

    );
end dataColector_ROI_interpreter;

architecture arch_dataColector_ROI_interpreter of dataColector_ROI_interpreter is
    -- HEADER REGISTER SAVE MACHINE
    type state_type_HEADER is (
        idle_st,
        header_0_st,
        header_1_st 
        );
    signal state         : state_type_HEADER := idle_st;
    signal next_state    : state_type_HEADER;

    -- PACK LAST MACHINE
    type state_type_PACK_LAST is (
        idle_pack_last_st,
        colecting_pack_st
        );
    signal state_PACK_LAST         : state_type_PACK_LAST := idle_pack_last_st;
    signal next_state_PACK_LAST    : state_type_PACK_LAST;

    -- TREADY LOCK CONTROL
    type state_type_TREADY_LOCK is (
        idle_st,
        header_colect_st,
        cmd_sending_st,
        cmd_sending_last_st,
        data_sending_st
        );
    signal state_TREADY_LOCK        : state_type_TREADY_LOCK := idle_st;
    signal next_state_TREADY_LOCK   : state_type_TREADY_LOCK;

    -- CALCULATOR PIPELINE
    type state_type_CALC is (
        idle_st,
        bytesCalculator_st,
        base_address_calculator_st,
        calc_done_st
    );
    signal state_CALC        : state_type_CALC := idle_st;
    signal next_state_CALC   : state_type_CALC;

    signal aux_dest             : std_logic_vector(DEST_WIDTH - 1 downto 0) := (others => '0');

    signal aux_base_address_A   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal aux_base_address_B   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);

    signal DATA_HEADER_0_REG    : std_logic_vector(HS_TDATA_WIDTH-1 downto 0) := (others => '0');
    signal DATA_HEADER_1_REG    : std_logic_vector(HS_TDATA_WIDTH-1 downto 0) := (others => '0');

    -- calculation signal 
    signal calc    : std_logic := '0';

    -- ROI values as unsigned
    signal xA : unsigned(15 downto 0);
    signal xB : unsigned(15 downto 0);
    signal yA : unsigned(15 downto 0);
    signal yC : unsigned(15 downto 0);

    -----Q-----
    -- 0 | 1 --
    -- 2 | 3 --
    -----------
    -- BYTE DATA AUXILIAR
    signal bytes_0              : unsigned(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal bytes_1              : unsigned(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal bytes_2              : unsigned(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal bytes_3              : unsigned(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    -- LENGTH AUXILIAR
    signal lengthE2F_0_reg      : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal lengthE2F_1_reg      : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal lengthE2F_2_reg      : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal lengthE2F_3_reg      : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    -- BASE ADDRESS AUXILIAR ADDRESS
    signal aux_base_address_0   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_1   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_2   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_3   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_4   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_5   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_6   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address_7   : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    -- TDEST LENGTH
    signal aux_lengthE2F        : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');
    signal aux_base_address     : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0) := (others => '0');

    signal header_register_sel  : std_logic_vector(1 downto 0) := "00";
    
    signal aux_s_hs_tready      : std_logic := '0';

    signal aux_DONE_CALCULATE   : std_logic := '0';

    signal cmd_count            : integer   := 0;
    signal flag_OffSet_B        : std_logic := '0';

begin

    DONE_CALCULATE   <= aux_DONE_CALCULATE;

    -- tready routing
    s_hs_tready <= aux_s_hs_tready;

    -- tready enable logic
    aux_s_hs_tready <= '1' when ((state_TREADY_LOCK = header_colect_st) or (state_TREADY_LOCK = data_sending_st)) else '0';

    -- TDEST and OFFSET VALUE STAMP REG
    process(clk)
    begin
        if rising_edge(clk) then
            if ((state = header_0_st) and (s_hs_tvalid = '1') and (aux_s_hs_tready = '1')) then
                aux_dest            <= s_hs_tdest;
                aux_base_address_A  <= base_address_A;
                aux_base_address_B  <= base_address_B;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------------
    -- STATE REGISTER
    --------------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if n_rst = '0' then
                state               <= idle_st;
                state_PACK_LAST     <= idle_pack_last_st;
                state_TREADY_LOCK   <= idle_st;
                state_CALC          <= idle_st;
            else
                state               <= next_state;
                state_PACK_LAST     <= next_state_PACK_LAST;
                state_TREADY_LOCK   <= next_state_TREADY_LOCK;
                state_CALC          <= next_state_CALC;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------------
    -- HEADER REGISTER STATE MACHINE COMBINATIONAL
    --------------------------------------------------------------------------------
    process(state, Start_Metadata_Colector, s_hs_tvalid, aux_s_hs_tready, s_hs_tlast)
    begin
        case state is
            when idle_st =>
                if Start_Metadata_Colector = '1' then
                    next_state <= header_0_st; -- Inicia la colecta de headers
                else
                    next_state <= idle_st; -- Permanece en espera
                end if;

            when header_0_st => 
                if (s_hs_tvalid = '1') and (aux_s_hs_tready = '1') then
                    next_state <= header_1_st; -- Procesa el siguiente header
                else
                    next_state <= header_0_st; -- Espera a que el header sea válido
                end if;

            when header_1_st => 
                if (s_hs_tvalid = '1') and (aux_s_hs_tready = '1') then
                    next_state <= idle_st; -- Avanza a la colecta de datos
                else
                    next_state <= header_1_st; -- Espera a que el segundo header sea válido
                end if;
        end case;
    end process;

    -- Calculate signal control
    calc <= '1' when ((state = header_1_st) and (s_hs_tvalid = '1') and (aux_s_hs_tready = '1')) else '0';

    --------------------------------------------------------------------------------
    -- PACK LAST WORD STATE MACHINE COMBINATIONAL
    --------------------------------------------------------------------------------
    process(state_PACK_LAST, Start_Metadata_Colector, s_hs_tvalid, aux_s_hs_tready, s_hs_tlast)
        begin
        case state_PACK_LAST is
            when idle_pack_last_st =>
                if Start_Metadata_Colector = '1' then
                    next_state_PACK_LAST <= colecting_pack_st; -- Inicia la colecta de headers
                else
                    next_state_PACK_LAST <= idle_pack_last_st; -- Permanece en espera
                end if;
            when colecting_pack_st =>
                if ((s_hs_tvalid = '1') and (aux_s_hs_tready = '1') and (s_hs_tlast = '1')) then
                    next_state_PACK_LAST <= idle_pack_last_st; -- Inicia la colecta de headers
                else
                    next_state_PACK_LAST <= colecting_pack_st; -- Inicia la colecta de headers
                end if;
        end case;
    end process;

    --------------------------------------------------------------------------------
    -- TREADY LOCK STATE MACHINE COMBINATIONAL
    --------------------------------------------------------------------------------
    process(state_TREADY_LOCK, Start_Metadata_Colector, state, s_hs_tvalid, aux_s_hs_tready, s_hs_tlast, DONE_CMD_SEND)
    begin
        case state_TREADY_LOCK is
            when idle_st =>
                if Start_Metadata_Colector = '1' then
                    next_state_TREADY_LOCK <= header_colect_st; -- Inicia la colecta de headers
                else
                    next_state_TREADY_LOCK <= idle_st; -- Permanece en espera
                end if;

            when header_colect_st => 
                if (state = header_1_st ) and (s_hs_tvalid = '1') and (aux_s_hs_tready = '1') then
                    if (s_hs_tlast = '1') then
                        next_state_TREADY_LOCK <= cmd_sending_last_st;
                    else
                        next_state_TREADY_LOCK <= cmd_sending_st; -- Avanza a la colecta de datos
                    end if;
                else
                    next_state_TREADY_LOCK <= header_colect_st; -- Espera a que el segundo header sea válido
                end if;
                    
            when cmd_sending_st => 
                if  DONE_CMD_SEND = '1' then
                    next_state_TREADY_LOCK <= data_sending_st; -- Avanza a la colecta de datos
                else
                    next_state_TREADY_LOCK <= cmd_sending_st; -- Espera a que el segundo header sea válido
                end if;

            when cmd_sending_last_st => 
                if  DONE_CMD_SEND = '1' then
                    next_state_TREADY_LOCK <= idle_st; -- Avanza a la colecta de datos
                else
                    next_state_TREADY_LOCK <= cmd_sending_last_st; -- Espera a que el segundo header sea válido
                end if;
                
            when data_sending_st => 
                if ((s_hs_tvalid = '1') and (aux_s_hs_tready = '1') and (s_hs_tlast = '1')) then
                    next_state_TREADY_LOCK <= idle_st; -- Avanza a la colecta de datos
                else
                    next_state_TREADY_LOCK <= data_sending_st; -- Espera a que el segundo header sea válido
                end if;
                
        end case;
    end process;

    --------------------------------------------------------------------------------
    -- CALCULATOR STATE MACHINE COMBINATIONAL
    --------------------------------------------------------------------------------
    process(state_CALC, calc)
    begin
        case state_CALC is
            when idle_st =>
                if calc = '1' then
                    next_state_CALC <= bytesCalculator_st;
                else
                    next_state_CALC <= idle_st;
                end if;

            when bytesCalculator_st =>
                next_state_CALC <= base_address_calculator_st; 

            when base_address_calculator_st =>
                next_state_CALC <= calc_done_st;

            when calc_done_st =>
                next_state_CALC <= idle_st; 

            when others =>
                next_state_CALC <= idle_st; -- Default fallback state_CALC
        end case;
    end process;

    --------------------------------------------------------------------------------
    -- CALCULATOR PIPELINE REG
    --------------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            case state_CALC is
                when bytesCalculator_st =>
                    -- Clear outputs at the start of calculation
                    lengthE2F_0_reg <= (others => '0');
                    lengthE2F_1_reg <= (others => '0');
                    lengthE2F_2_reg <= (others => '0');
                    lengthE2F_3_reg <= (others => '0');

                    -- Calculate the number of pixels for each quadrant
                    bytes_0 <= resize(to_unsigned(8, 32) + (xB * yA)/to_unsigned(4, 32), 32);
                    bytes_1 <= resize(to_unsigned(8, 32) + (xA * yA)/to_unsigned(4, 32), 32);
                    bytes_2 <= resize(to_unsigned(8, 32) + (xA * yC)/to_unsigned(4, 32), 32);
                    bytes_3 <= resize(to_unsigned(8, 32) + (xB * yC)/to_unsigned(4, 32), 32);

                when base_address_calculator_st =>
                    -- Calculate optimal base address

                    aux_base_address_0  <= std_logic_vector(unsigned(aux_base_address_A) + bytes_0);                               
                    aux_base_address_1  <= std_logic_vector(unsigned(aux_base_address_A));                      
                    aux_base_address_2  <= std_logic_vector(unsigned(aux_base_address_A) + bytes_0 + bytes_1);            
                    aux_base_address_3  <= std_logic_vector(unsigned(aux_base_address_A) + bytes_0 + bytes_1 + bytes_2);  
                    aux_base_address_4  <= std_logic_vector(unsigned(aux_base_address_B) + bytes_0);                               
                    aux_base_address_5  <= std_logic_vector(unsigned(aux_base_address_B));
                    aux_base_address_6  <= std_logic_vector(unsigned(aux_base_address_B) + bytes_0 + bytes_1);            
                    aux_base_address_7  <= std_logic_vector(unsigned(aux_base_address_B) + bytes_0 + bytes_1 + bytes_2);  

                    lengthE2F_0_reg     <= std_logic_vector(bytes_0);
                    lengthE2F_1_reg     <= std_logic_vector(bytes_1);
                    lengthE2F_2_reg     <= std_logic_vector(bytes_2);
                    lengthE2F_3_reg     <= std_logic_vector(bytes_3);

                when calc_done_st =>
                    -- Indicate calculation is done
                    aux_DONE_CALCULATE <= '1';

                when idle_st =>
                    -- Clear the done signal
                    aux_DONE_CALCULATE <= '0';

                when others =>
                    null; -- Do nothing
            end case;
        end if;
    end process;

    -- Header register selector
    header_register_sel <=  "00" when (state = header_0_st) else
                            "01" when (state = header_1_st) else
                            "10";

     -- Header reg value
     process(clk, header_register_sel)
     begin
        if rising_edge(clk) then
            case header_register_sel is
                when "00" =>
                    DATA_HEADER_0_REG <= s_hs_tdata;
                when "01" =>
                    DATA_HEADER_1_REG <= s_hs_tdata;
                when others =>
            end case;
        end if;
    end process;

    -- Header and Data colect done signal
    DONE_HEADER_COLECTOR <= '1' when ((state = header_1_st) and (s_hs_tvalid = '1') and (aux_s_hs_tready = '1')) else '0';
    DONE_DATA_COLECTOR   <= '1' when ((state_PACK_LAST = colecting_pack_st) and (s_hs_tvalid = '1') and (aux_s_hs_tready = '1') and (s_hs_tlast = '1')) else '0';

    -- lengthE2F and base_address register
    process (clk)
    begin
        if rising_edge(clk) then
            lengthE2F       <= aux_lengthE2F;
            base_address    <= aux_base_address;
        end if;
    end process;

    -- CALCULATOR
    -- Extract the regions of interest (ROI) from input data
    xA <= unsigned(DATA_HEADER_0_REG(15 downto 0));  -- Lower 16 bits of input_data_0
    xB <= unsigned(DATA_HEADER_0_REG(31 downto 16)); -- Upper 16 bits of input_data_0
    yA <= unsigned(DATA_HEADER_1_REG(15 downto 0));  -- Lower 16 bits of input_data_1
    yC <= unsigned(DATA_HEADER_1_REG(31 downto 16)); -- Upper 16 bits of input_data_1

    -- MUX length
    aux_lengthE2F <=    lengthE2F_0_reg when ((aux_dest = std_logic_vector(to_unsigned(0, DEST_WIDTH))) ) else -- or (aux_dest = std_logic_vector(to_unsigned(4, DEST_WIDTH)))) else
                        lengthE2F_1_reg when ((aux_dest = std_logic_vector(to_unsigned(1, DEST_WIDTH))) ) else -- or (aux_dest = std_logic_vector(to_unsigned(5, DEST_WIDTH)))) else
                        lengthE2F_2_reg when ((aux_dest = std_logic_vector(to_unsigned(2, DEST_WIDTH))) ) else -- or (aux_dest = std_logic_vector(to_unsigned(6, DEST_WIDTH)))) else
                        lengthE2F_3_reg when ((aux_dest = std_logic_vector(to_unsigned(3, DEST_WIDTH))) ) else -- or (aux_dest = std_logic_vector(to_unsigned(7, DEST_WIDTH)))) else
                        (others => 'U');

    -- MUX base address
    aux_base_address    <=  aux_base_address_0  when ((flag_OffSet_B = '0') and (aux_dest = std_logic_vector(to_unsigned(0, DEST_WIDTH)))) else
                            aux_base_address_1  when ((flag_OffSet_B = '0') and (aux_dest = std_logic_vector(to_unsigned(1, DEST_WIDTH)))) else
                            aux_base_address_2  when ((flag_OffSet_B = '0') and (aux_dest = std_logic_vector(to_unsigned(2, DEST_WIDTH)))) else
                            aux_base_address_3  when ((flag_OffSet_B = '0') and (aux_dest = std_logic_vector(to_unsigned(3, DEST_WIDTH)))) else
                            aux_base_address_4  when ((flag_OffSet_B = '1') and (aux_dest = std_logic_vector(to_unsigned(0, DEST_WIDTH)))) else
                            aux_base_address_5  when ((flag_OffSet_B = '1') and (aux_dest = std_logic_vector(to_unsigned(1, DEST_WIDTH)))) else
                            aux_base_address_6  when ((flag_OffSet_B = '1') and (aux_dest = std_logic_vector(to_unsigned(2, DEST_WIDTH)))) else
                            aux_base_address_7  when ((flag_OffSet_B = '1') and (aux_dest = std_logic_vector(to_unsigned(3, DEST_WIDTH)))) else
                            (others => 'U'); 

    -- flag OffSet
    process(clk, n_rst)
    begin
        if n_rst = '0' then
            cmd_count       <= 0;
            flag_OffSet_B   <= '0';
        elsif rising_edge(clk) then
            if DONE_CMD_SEND = '1' then
                cmd_count       <= cmd_count + 1;
            elsif (cmd_count = INTERFACE_NUM) then
                cmd_count       <= 0;
                flag_OffSet_B   <= not flag_OffSet_B;
            end if;
        end if;
    end process;

end arch_dataColector_ROI_interpreter;