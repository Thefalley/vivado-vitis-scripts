library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- axi_lite_cfg_rw: AXI-Lite register bank with bidirectional registers.
--
-- Registers 0-2: writable by ARM (output ports, same as original)
-- Registers 3-12: readable by ARM from hardware inputs (hw_reg_xx ports)
-- Registers 13-31: writable by ARM (unused, same as original)
--
-- Based on axi_lite_cfg from P_101, modified for P_102 counter readback.

entity axi_lite_cfg_rw is
	generic (
		C_S_AXI_DATA_WIDTH	: integer	:= 32;
		C_S_AXI_ADDR_WIDTH	: integer	:= 7
	);
	port (
		-- Writable registers (ARM writes, hardware reads)
		add_value           : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- reg0: ctrl_cmd
		port_not_used_01    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- reg1: n_words
		port_not_used_02    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- reg2: counter_reset

		-- Read-from-hardware ports (ARM reads, hardware writes)
		hw_reg_03 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- ctrl_state
		hw_reg_04 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- occupancy
		hw_reg_05 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_in_lo
		hw_reg_06 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_in_hi
		hw_reg_07 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_in_hh
		hw_reg_08 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_in_hhh
		hw_reg_09 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_out_lo
		hw_reg_10 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_out_hi
		hw_reg_11 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_out_hh
		hw_reg_12 : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);  -- total_out_hhh

		-- Remaining writable registers (unused)
		port_not_used_13    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_14    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_15    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_16    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_17    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_18    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_19    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_20    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_21    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_22    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_23    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_24    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_25    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_26    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_27    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_28    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_29    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		port_not_used_30    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);

		-- AXI-Lite interface
		S_AXI_ACLK	: in std_logic;
		S_AXI_ARESETN	: in std_logic;
		S_AXI_AWADDR	: in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
		S_AXI_AWPROT	: in std_logic_vector(2 downto 0);
		S_AXI_AWVALID	: in std_logic;
		S_AXI_AWREADY	: out std_logic;
		S_AXI_WDATA	: in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		S_AXI_WSTRB	: in std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
		S_AXI_WVALID	: in std_logic;
		S_AXI_WREADY	: out std_logic;
		S_AXI_BRESP	: out std_logic_vector(1 downto 0);
		S_AXI_BVALID	: out std_logic;
		S_AXI_BREADY	: in std_logic;
		S_AXI_ARADDR	: in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
		S_AXI_ARPROT	: in std_logic_vector(2 downto 0);
		S_AXI_ARVALID	: in std_logic;
		S_AXI_ARREADY	: out std_logic;
		S_AXI_RDATA	: out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		S_AXI_RRESP	: out std_logic_vector(1 downto 0);
		S_AXI_RVALID	: out std_logic;
		S_AXI_RREADY	: in std_logic
	);
end axi_lite_cfg_rw;

architecture arch_imp of axi_lite_cfg_rw is

	signal axi_awaddr	: std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
	signal axi_awready	: std_logic;
	signal axi_wready	: std_logic;
	signal axi_bresp	: std_logic_vector(1 downto 0);
	signal axi_bvalid	: std_logic;
	signal axi_araddr	: std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
	signal axi_arready	: std_logic;
	signal axi_rdata	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal axi_rresp	: std_logic_vector(1 downto 0);
	signal axi_rvalid	: std_logic;

	constant ADDR_LSB  : integer := (C_S_AXI_DATA_WIDTH/32)+ 1;
	constant OPT_MEM_ADDR_BITS : integer := 4;

	-- Slave registers (all 32 still exist for write logic)
	signal slv_reg0	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg1	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg2	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg3	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg4	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg5	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg6	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg7	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg8	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg9	    : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg10	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg11	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg12	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg13	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg14	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg15	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg16	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg17	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg18	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg19	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg20	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg21	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg22	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg23	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg24	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg25	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg26	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg27	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg28	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg29	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg30	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg31	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal slv_reg_rden	: std_logic;
	signal slv_reg_wren	: std_logic;
	signal reg_data_out	: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
	signal byte_index	: integer;
	signal aw_en	    : std_logic;

begin

    -- Output routing: writable registers
    add_value           <= slv_reg0;   -- reg0: ctrl_cmd
    port_not_used_01    <= slv_reg1;   -- reg1: n_words
    port_not_used_02    <= slv_reg2;   -- reg2: counter_reset
    -- Registers 3-12 are INPUT from hardware (hw_reg_xx), no output needed
    port_not_used_13    <= slv_reg13;
    port_not_used_14    <= slv_reg14;
    port_not_used_15    <= slv_reg15;
    port_not_used_16    <= slv_reg16;
    port_not_used_17    <= slv_reg17;
    port_not_used_18    <= slv_reg18;
    port_not_used_19    <= slv_reg19;
    port_not_used_20    <= slv_reg20;
    port_not_used_21    <= slv_reg21;
    port_not_used_22    <= slv_reg22;
    port_not_used_23    <= slv_reg23;
    port_not_used_24    <= slv_reg24;
    port_not_used_25    <= slv_reg25;
    port_not_used_26    <= slv_reg26;
    port_not_used_27    <= slv_reg27;
    port_not_used_28    <= slv_reg28;
    port_not_used_29    <= slv_reg29;
    port_not_used_30    <= slv_reg30;

	-- I/O Connections
	S_AXI_AWREADY	<= axi_awready;
	S_AXI_WREADY	<= axi_wready;
	S_AXI_BRESP	<= axi_bresp;
	S_AXI_BVALID	<= axi_bvalid;
	S_AXI_ARREADY	<= axi_arready;
	S_AXI_RDATA	<= axi_rdata;
	S_AXI_RRESP	<= axi_rresp;
	S_AXI_RVALID	<= axi_rvalid;

	-- axi_awready generation
	process (S_AXI_ACLK)
	begin
	  if rising_edge(S_AXI_ACLK) then
	    if S_AXI_ARESETN = '0' then
	      axi_awready <= '0';
	      aw_en <= '1';
	    else
	      if (axi_awready = '0' and S_AXI_AWVALID = '1' and S_AXI_WVALID = '1' and aw_en = '1') then
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

	-- axi_awaddr latching
	process (S_AXI_ACLK)
	begin
	  if rising_edge(S_AXI_ACLK) then
	    if S_AXI_ARESETN = '0' then
	      axi_awaddr <= (others => '0');
	    else
	      if (axi_awready = '0' and S_AXI_AWVALID = '1' and S_AXI_WVALID = '1' and aw_en = '1') then
	        axi_awaddr <= S_AXI_AWADDR;
	      end if;
	    end if;
	  end if;
	end process;

	-- axi_wready generation
	process (S_AXI_ACLK)
	begin
	  if rising_edge(S_AXI_ACLK) then
	    if S_AXI_ARESETN = '0' then
	      axi_wready <= '0';
	    else
	      if (axi_wready = '0' and S_AXI_WVALID = '1' and S_AXI_AWVALID = '1' and aw_en = '1') then
	          axi_wready <= '1';
	      else
	        axi_wready <= '0';
	      end if;
	    end if;
	  end if;
	end process;

	-- Write enable
	slv_reg_wren <= axi_wready and S_AXI_WVALID and axi_awready and S_AXI_AWVALID ;

	-- Register write logic
	process (S_AXI_ACLK)
	variable loc_addr :std_logic_vector(OPT_MEM_ADDR_BITS downto 0);
	begin
	  if rising_edge(S_AXI_ACLK) then
	    if S_AXI_ARESETN = '0' then
	      slv_reg0 <= (others => '0');
	      slv_reg1 <= (others => '0');
	      slv_reg2 <= (others => '0');
	      slv_reg3 <= (others => '0');
	      slv_reg4 <= (others => '0');
	      slv_reg5 <= (others => '0');
	      slv_reg6 <= (others => '0');
	      slv_reg7 <= (others => '0');
	      slv_reg8 <= (others => '0');
	      slv_reg9 <= (others => '0');
	      slv_reg10 <= (others => '0');
	      slv_reg11 <= (others => '0');
	      slv_reg12 <= (others => '0');
	      slv_reg13 <= (others => '0');
	      slv_reg14 <= (others => '0');
	      slv_reg15 <= (others => '0');
	      slv_reg16 <= (others => '0');
	      slv_reg17 <= (others => '0');
	      slv_reg18 <= (others => '0');
	      slv_reg19 <= (others => '0');
	      slv_reg20 <= (others => '0');
	      slv_reg21 <= (others => '0');
	      slv_reg22 <= (others => '0');
	      slv_reg23 <= (others => '0');
	      slv_reg24 <= (others => '0');
	      slv_reg25 <= (others => '0');
	      slv_reg26 <= (others => '0');
	      slv_reg27 <= (others => '0');
	      slv_reg28 <= (others => '0');
	      slv_reg29 <= (others => '0');
	      slv_reg30 <= (others => '0');
	      slv_reg31 <= (others => '0');
	    else
	      loc_addr := axi_awaddr(ADDR_LSB + OPT_MEM_ADDR_BITS downto ADDR_LSB);
	      if (slv_reg_wren = '1') then
	        case loc_addr is
	          when b"00000" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg0(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"00001" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg1(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"00010" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg2(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          -- Registers 3-12: writes accepted but values not used for read
	          -- (read returns hw_reg_xx instead). Keep write logic so AXI
	          -- bus does not return errors on writes to these addresses.
	          when b"00011" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg3(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"00100" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg4(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"00101" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg5(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"00110" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg6(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"00111" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg7(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01000" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg8(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01001" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg9(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01010" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg10(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01011" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg11(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01100" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg12(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01101" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg13(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01110" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg14(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"01111" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg15(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10000" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg16(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10001" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg17(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10010" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg18(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10011" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg19(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10100" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg20(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10101" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg21(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10110" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg22(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"10111" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg23(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11000" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg24(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11001" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg25(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11010" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg26(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11011" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg27(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11100" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg28(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11101" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg29(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11110" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg30(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when b"11111" =>
	            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8-1) loop
	              if ( S_AXI_WSTRB(byte_index) = '1' ) then
	                slv_reg31(byte_index*8+7 downto byte_index*8) <= S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
	              end if;
	            end loop;
	          when others =>
	            slv_reg0 <= slv_reg0;
	            slv_reg1 <= slv_reg1;
	            slv_reg2 <= slv_reg2;
	            slv_reg3 <= slv_reg3;
	            slv_reg4 <= slv_reg4;
	            slv_reg5 <= slv_reg5;
	            slv_reg6 <= slv_reg6;
	            slv_reg7 <= slv_reg7;
	            slv_reg8 <= slv_reg8;
	            slv_reg9 <= slv_reg9;
	            slv_reg10 <= slv_reg10;
	            slv_reg11 <= slv_reg11;
	            slv_reg12 <= slv_reg12;
	            slv_reg13 <= slv_reg13;
	            slv_reg14 <= slv_reg14;
	            slv_reg15 <= slv_reg15;
	            slv_reg16 <= slv_reg16;
	            slv_reg17 <= slv_reg17;
	            slv_reg18 <= slv_reg18;
	            slv_reg19 <= slv_reg19;
	            slv_reg20 <= slv_reg20;
	            slv_reg21 <= slv_reg21;
	            slv_reg22 <= slv_reg22;
	            slv_reg23 <= slv_reg23;
	            slv_reg24 <= slv_reg24;
	            slv_reg25 <= slv_reg25;
	            slv_reg26 <= slv_reg26;
	            slv_reg27 <= slv_reg27;
	            slv_reg28 <= slv_reg28;
	            slv_reg29 <= slv_reg29;
	            slv_reg30 <= slv_reg30;
	            slv_reg31 <= slv_reg31;
	        end case;
	      end if;
	    end if;
	  end if;
	end process;

	-- Write response logic
	process (S_AXI_ACLK)
	begin
	  if rising_edge(S_AXI_ACLK) then
	    if S_AXI_ARESETN = '0' then
	      axi_bvalid  <= '0';
	      axi_bresp   <= "00";
	    else
	      if (axi_awready = '1' and S_AXI_AWVALID = '1' and axi_wready = '1' and S_AXI_WVALID = '1' and axi_bvalid = '0'  ) then
	        axi_bvalid <= '1';
	        axi_bresp  <= "00";
	      elsif (S_AXI_BREADY = '1' and axi_bvalid = '1') then
	        axi_bvalid <= '0';
	      end if;
	    end if;
	  end if;
	end process;

	-- axi_arready generation
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

	-- axi_rvalid generation
	process (S_AXI_ACLK)
	begin
	  if rising_edge(S_AXI_ACLK) then
	    if S_AXI_ARESETN = '0' then
	      axi_rvalid <= '0';
	      axi_rresp  <= "00";
	    else
	      if (axi_arready = '1' and S_AXI_ARVALID = '1' and axi_rvalid = '0') then
	        axi_rvalid <= '1';
	        axi_rresp  <= "00";
	      elsif (axi_rvalid = '1' and S_AXI_RREADY = '1') then
	        axi_rvalid <= '0';
	      end if;
	    end if;
	  end if;
	end process;

	-- Read enable
	slv_reg_rden <= axi_arready and S_AXI_ARVALID and (not axi_rvalid) ;

	-- Read data mux: registers 0-2 from slv_reg, registers 3-12 from hw_reg
	process (slv_reg0, slv_reg1, slv_reg2,
	         hw_reg_03, hw_reg_04, hw_reg_05, hw_reg_06, hw_reg_07,
	         hw_reg_08, hw_reg_09, hw_reg_10, hw_reg_11, hw_reg_12,
	         slv_reg13, slv_reg14, slv_reg15, slv_reg16,
	         slv_reg17, slv_reg18, slv_reg19, slv_reg20,
	         slv_reg21, slv_reg22, slv_reg23, slv_reg24,
	         slv_reg25, slv_reg26, slv_reg27, slv_reg28,
	         slv_reg29, slv_reg30, slv_reg31,
	         axi_araddr, S_AXI_ARESETN, slv_reg_rden)
	variable loc_addr :std_logic_vector(OPT_MEM_ADDR_BITS downto 0);
	begin
	    loc_addr := axi_araddr(ADDR_LSB + OPT_MEM_ADDR_BITS downto ADDR_LSB);
	    case loc_addr is
	      when b"00000" =>
	        reg_data_out <= slv_reg0;       -- ctrl_cmd (W)
	      when b"00001" =>
	        reg_data_out <= slv_reg1;       -- n_words (W)
	      when b"00010" =>
	        reg_data_out <= slv_reg2;       -- counter_reset (W)
	      -- Hardware readback registers (3-12)
	      when b"00011" =>
	        reg_data_out <= hw_reg_03;      -- ctrl_state (R)
	      when b"00100" =>
	        reg_data_out <= hw_reg_04;      -- occupancy (R)
	      when b"00101" =>
	        reg_data_out <= hw_reg_05;      -- total_in_lo (R)
	      when b"00110" =>
	        reg_data_out <= hw_reg_06;      -- total_in_hi (R)
	      when b"00111" =>
	        reg_data_out <= hw_reg_07;      -- total_in_hh (R)
	      when b"01000" =>
	        reg_data_out <= hw_reg_08;      -- total_in_hhh (R)
	      when b"01001" =>
	        reg_data_out <= hw_reg_09;      -- total_out_lo (R)
	      when b"01010" =>
	        reg_data_out <= hw_reg_10;      -- total_out_hi (R)
	      when b"01011" =>
	        reg_data_out <= hw_reg_11;      -- total_out_hh (R)
	      when b"01100" =>
	        reg_data_out <= hw_reg_12;      -- total_out_hhh (R)
	      -- Remaining registers (13-31) read from slv_reg
	      when b"01101" =>
	        reg_data_out <= slv_reg13;
	      when b"01110" =>
	        reg_data_out <= slv_reg14;
	      when b"01111" =>
	        reg_data_out <= slv_reg15;
	      when b"10000" =>
	        reg_data_out <= slv_reg16;
	      when b"10001" =>
	        reg_data_out <= slv_reg17;
	      when b"10010" =>
	        reg_data_out <= slv_reg18;
	      when b"10011" =>
	        reg_data_out <= slv_reg19;
	      when b"10100" =>
	        reg_data_out <= slv_reg20;
	      when b"10101" =>
	        reg_data_out <= slv_reg21;
	      when b"10110" =>
	        reg_data_out <= slv_reg22;
	      when b"10111" =>
	        reg_data_out <= slv_reg23;
	      when b"11000" =>
	        reg_data_out <= slv_reg24;
	      when b"11001" =>
	        reg_data_out <= slv_reg25;
	      when b"11010" =>
	        reg_data_out <= slv_reg26;
	      when b"11011" =>
	        reg_data_out <= slv_reg27;
	      when b"11100" =>
	        reg_data_out <= slv_reg28;
	      when b"11101" =>
	        reg_data_out <= slv_reg29;
	      when b"11110" =>
	        reg_data_out <= slv_reg30;
	      when b"11111" =>
	        reg_data_out <= slv_reg31;
	      when others =>
	        reg_data_out  <= (others => '0');
	    end case;
	end process;

	-- Output register read data
	process( S_AXI_ACLK ) is
	begin
	  if (rising_edge (S_AXI_ACLK)) then
	    if ( S_AXI_ARESETN = '0' ) then
	      axi_rdata  <= (others => '0');
	    else
	      if (slv_reg_rden = '1') then
	          axi_rdata <= reg_data_out;
	      end if;
	    end if;
	  end if;
	end process;

end arch_imp;
