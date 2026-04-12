library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- axi_lite_cfg: AXI4-Lite slave con 8 registros (adaptado de P_3)
--
-- Mapa de registros:
--   reg0 (0x00) CTRL       R/W   bit0=start, bit1=irq_clear
--   reg1 (0x04) THRESHOLD  R/W   ciclos a contar
--   reg2 (0x08) CONDITION  R/W   valor de comparacion
--   reg3 (0x0C) STATUS     R/O   desde FSM (running, irq_pending, state)
--   reg4 (0x10) COUNT      R/O   valor actual del contador
--   reg5 (0x14) IRQ_COUNT  R/O   total de interrupciones generadas
--   reg6 (0x18) reservado  R/W
--   reg7 (0x1C) reservado  R/W

entity axi_lite_cfg is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 5
    );
    port (
        -- Config outputs (from writable registers)
        ctrl_out      : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        threshold_out : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        condition_out : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        -- Status inputs (read-only registers, directly from FSM)
        status_in     : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        count_in      : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        irq_count_in  : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);

        S_AXI_ACLK    : in  std_logic;
        S_AXI_ARESETN  : in  std_logic;
        S_AXI_AWADDR   : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWPROT   : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID  : in  std_logic;
        S_AXI_AWREADY  : out std_logic;
        S_AXI_WDATA    : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB    : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        S_AXI_WVALID   : in  std_logic;
        S_AXI_WREADY   : out std_logic;
        S_AXI_BRESP    : out std_logic_vector(1 downto 0);
        S_AXI_BVALID   : out std_logic;
        S_AXI_BREADY   : in  std_logic;
        S_AXI_ARADDR   : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARPROT   : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID  : in  std_logic;
        S_AXI_ARREADY  : out std_logic;
        S_AXI_RDATA    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_RRESP    : out std_logic_vector(1 downto 0);
        S_AXI_RVALID   : out std_logic;
        S_AXI_RREADY   : in  std_logic
    );
end axi_lite_cfg;

architecture arch_imp of axi_lite_cfg is

    signal axi_awaddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    signal axi_awready : std_logic;
    signal axi_wready  : std_logic;
    signal axi_bresp   : std_logic_vector(1 downto 0);
    signal axi_bvalid  : std_logic;
    signal axi_araddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    signal axi_arready : std_logic;
    signal axi_rdata   : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    signal axi_rresp   : std_logic_vector(1 downto 0);
    signal axi_rvalid  : std_logic;

    constant ADDR_LSB          : integer := (C_S_AXI_DATA_WIDTH/32) + 1;
    constant OPT_MEM_ADDR_BITS : integer := 2;  -- 8 registros (3 bits)

    -- Writable registers only
    signal slv_reg0 : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- CTRL
    signal slv_reg1 : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- THRESHOLD
    signal slv_reg2 : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- CONDITION
    -- reg3, reg4, reg5 -> read-only from external inputs
    signal slv_reg6 : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- reserved
    signal slv_reg7 : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- reserved

    signal slv_reg_rden : std_logic;
    signal slv_reg_wren : std_logic;
    signal reg_data_out : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    signal byte_index   : integer;
    signal aw_en        : std_logic;

begin

    -- Output routing
    ctrl_out      <= slv_reg0;
    threshold_out <= slv_reg1;
    condition_out <= slv_reg2;

    S_AXI_AWREADY <= axi_awready;
    S_AXI_WREADY  <= axi_wready;
    S_AXI_BRESP   <= axi_bresp;
    S_AXI_BVALID  <= axi_bvalid;
    S_AXI_ARREADY <= axi_arready;
    S_AXI_RDATA   <= axi_rdata;
    S_AXI_RRESP   <= axi_rresp;
    S_AXI_RVALID  <= axi_rvalid;

    ---------------------------------------------------------------
    -- AXI write address ready
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_awready <= '0';
                aw_en <= '1';
            else
                if (axi_awready = '0' and S_AXI_AWVALID = '1' and
                    S_AXI_WVALID = '1' and aw_en = '1') then
                    axi_awready <= '1';
                    aw_en <= '0';
                elsif (S_AXI_BREADY = '1' and axi_bvalid = '1') then
                    aw_en <= '1';
                    axi_awready <= '0';
                else
                    axi_awready <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- AXI write address latch
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_awaddr <= (others => '0');
            else
                if (axi_awready = '0' and S_AXI_AWVALID = '1' and
                    S_AXI_WVALID = '1' and aw_en = '1') then
                    axi_awaddr <= S_AXI_AWADDR;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- AXI write data ready
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_wready <= '0';
            else
                if (axi_wready = '0' and S_AXI_WVALID = '1' and
                    S_AXI_AWVALID = '1' and aw_en = '1') then
                    axi_wready <= '1';
                else
                    axi_wready <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Register write logic
    ---------------------------------------------------------------
    slv_reg_wren <= axi_wready and S_AXI_WVALID and axi_awready and S_AXI_AWVALID;

    process (S_AXI_ACLK)
        variable loc_addr : std_logic_vector(OPT_MEM_ADDR_BITS downto 0);
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                slv_reg0 <= (others => '0');
                slv_reg1 <= (others => '0');
                slv_reg2 <= (others => '0');
                slv_reg6 <= (others => '0');
                slv_reg7 <= (others => '0');
            else
                loc_addr := axi_awaddr(ADDR_LSB + OPT_MEM_ADDR_BITS downto ADDR_LSB);
                if (slv_reg_wren = '1') then
                    case loc_addr is
                        when "000" =>  -- reg0: CTRL
                            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
                                if (S_AXI_WSTRB(byte_index) = '1') then
                                    slv_reg0(byte_index*8+7 downto byte_index*8)
                                        <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
                                end if;
                            end loop;
                        when "001" =>  -- reg1: THRESHOLD
                            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
                                if (S_AXI_WSTRB(byte_index) = '1') then
                                    slv_reg1(byte_index*8+7 downto byte_index*8)
                                        <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
                                end if;
                            end loop;
                        when "010" =>  -- reg2: CONDITION
                            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
                                if (S_AXI_WSTRB(byte_index) = '1') then
                                    slv_reg2(byte_index*8+7 downto byte_index*8)
                                        <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
                                end if;
                            end loop;
                        -- "011", "100", "101" -> READ-ONLY (STATUS, COUNT, IRQ_COUNT)
                        when "110" =>  -- reg6: reserved
                            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
                                if (S_AXI_WSTRB(byte_index) = '1') then
                                    slv_reg6(byte_index*8+7 downto byte_index*8)
                                        <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
                                end if;
                            end loop;
                        when "111" =>  -- reg7: reserved
                            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
                                if (S_AXI_WSTRB(byte_index) = '1') then
                                    slv_reg7(byte_index*8+7 downto byte_index*8)
                                        <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
                                end if;
                            end loop;
                        when others =>
                            slv_reg0 <= slv_reg0;
                            slv_reg1 <= slv_reg1;
                            slv_reg2 <= slv_reg2;
                            slv_reg6 <= slv_reg6;
                            slv_reg7 <= slv_reg7;
                    end case;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Write response
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_bvalid <= '0';
                axi_bresp  <= "00";
            else
                if (axi_awready = '1' and S_AXI_AWVALID = '1' and
                    axi_wready = '1' and S_AXI_WVALID = '1' and
                    axi_bvalid = '0') then
                    axi_bvalid <= '1';
                    axi_bresp  <= "00";
                elsif (S_AXI_BREADY = '1' and axi_bvalid = '1') then
                    axi_bvalid <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Read address ready + latch
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_arready <= '0';
                axi_araddr  <= (others => '1');
            else
                if (axi_arready = '0' and S_AXI_ARVALID = '1') then
                    axi_arready <= '1';
                    axi_araddr  <= S_AXI_ARADDR;
                else
                    axi_arready <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Read valid
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_rvalid <= '0';
                axi_rresp  <= "00";
            else
                if (axi_arready = '1' and S_AXI_ARVALID = '1' and
                    axi_rvalid = '0') then
                    axi_rvalid <= '1';
                    axi_rresp  <= "00";
                elsif (axi_rvalid = '1' and S_AXI_RREADY = '1') then
                    axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Read data mux
    ---------------------------------------------------------------
    slv_reg_rden <= axi_arready and S_AXI_ARVALID and (not axi_rvalid);

    process (slv_reg0, slv_reg1, slv_reg2, status_in, count_in,
             irq_count_in, slv_reg6, slv_reg7, axi_araddr,
             S_AXI_ARESETN, slv_reg_rden)
        variable loc_addr : std_logic_vector(OPT_MEM_ADDR_BITS downto 0);
    begin
        loc_addr := axi_araddr(ADDR_LSB + OPT_MEM_ADDR_BITS downto ADDR_LSB);
        case loc_addr is
            when "000"  => reg_data_out <= slv_reg0;       -- CTRL
            when "001"  => reg_data_out <= slv_reg1;       -- THRESHOLD
            when "010"  => reg_data_out <= slv_reg2;       -- CONDITION
            when "011"  => reg_data_out <= status_in;      -- STATUS (R/O)
            when "100"  => reg_data_out <= count_in;       -- COUNT  (R/O)
            when "101"  => reg_data_out <= irq_count_in;   -- IRQ_COUNT (R/O)
            when "110"  => reg_data_out <= slv_reg6;       -- reserved
            when "111"  => reg_data_out <= slv_reg7;       -- reserved
            when others => reg_data_out <= (others => '0');
        end case;
    end process;

    ---------------------------------------------------------------
    -- Output read data register
    ---------------------------------------------------------------
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_rdata <= (others => '0');
            else
                if (slv_reg_rden = '1') then
                    axi_rdata <= reg_data_out;
                end if;
            end if;
        end if;
    end process;

end arch_imp;
