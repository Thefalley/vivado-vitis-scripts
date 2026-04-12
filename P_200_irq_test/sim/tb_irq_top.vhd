library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_irq_top is
end tb_irq_top;

architecture sim of tb_irq_top is

    constant CLK_PERIOD : time    := 10 ns;
    constant ADDR_W     : integer := 6;
    constant DATA_W     : integer := 32;

    signal clk     : std_logic := '0';
    signal rst_n   : std_logic := '0';
    signal irq_out : std_logic;

    signal awaddr  : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
    signal awprot  : std_logic_vector(2 downto 0)        := "000";
    signal awvalid : std_logic := '0';
    signal awready : std_logic;
    signal wdata   : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
    signal wstrb   : std_logic_vector(3 downto 0)        := x"0";
    signal wvalid  : std_logic := '0';
    signal wready  : std_logic;
    signal bresp   : std_logic_vector(1 downto 0);
    signal bvalid  : std_logic;
    signal bready  : std_logic := '0';
    signal araddr  : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
    signal arprot  : std_logic_vector(2 downto 0)        := "000";
    signal arvalid : std_logic := '0';
    signal arready : std_logic;
    signal rdata   : std_logic_vector(DATA_W-1 downto 0);
    signal rresp   : std_logic_vector(1 downto 0);
    signal rvalid  : std_logic;
    signal rready  : std_logic := '0';

begin

    clk <= not clk after CLK_PERIOD / 2;

    DUT: entity work.irq_top
        generic map (C_S_AXI_DATA_WIDTH => DATA_W, C_S_AXI_ADDR_WIDTH => ADDR_W)
        port map (
            irq_out => irq_out, S_AXI_ACLK => clk, S_AXI_ARESETN => rst_n,
            S_AXI_AWADDR => awaddr, S_AXI_AWPROT => awprot,
            S_AXI_AWVALID => awvalid, S_AXI_AWREADY => awready,
            S_AXI_WDATA => wdata, S_AXI_WSTRB => wstrb,
            S_AXI_WVALID => wvalid, S_AXI_WREADY => wready,
            S_AXI_BRESP => bresp, S_AXI_BVALID => bvalid, S_AXI_BREADY => bready,
            S_AXI_ARADDR => araddr, S_AXI_ARPROT => arprot,
            S_AXI_ARVALID => arvalid, S_AXI_ARREADY => arready,
            S_AXI_RDATA => rdata, S_AXI_RRESP => rresp,
            S_AXI_RVALID => rvalid, S_AXI_RREADY => rready
        );

    stim: process

        procedure axi_write(
            addr : in std_logic_vector(ADDR_W-1 downto 0);
            data : in std_logic_vector(DATA_W-1 downto 0)) is
        begin
            awaddr <= addr; awvalid <= '1';
            wdata <= data; wstrb <= x"F"; wvalid <= '1'; bready <= '1';
            loop wait until rising_edge(clk); exit when bvalid = '1'; end loop;
            awvalid <= '0'; wvalid <= '0';
            wait until rising_edge(clk); bready <= '0';
        end procedure;

        procedure axi_read(
            addr : in  std_logic_vector(ADDR_W-1 downto 0);
            data : out std_logic_vector(DATA_W-1 downto 0)) is
        begin
            araddr <= addr; arvalid <= '1'; rready <= '1';
            loop wait until rising_edge(clk); exit when rvalid = '1'; end loop;
            data := rdata; arvalid <= '0'; rready <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Addresses (6-bit, byte offsets)
        constant A_CTRL      : std_logic_vector(ADDR_W-1 downto 0) := "000000"; -- 0x00
        constant A_THRESHOLD : std_logic_vector(ADDR_W-1 downto 0) := "000100"; -- 0x04
        constant A_CONDITION : std_logic_vector(ADDR_W-1 downto 0) := "001000"; -- 0x08
        constant A_STATUS    : std_logic_vector(ADDR_W-1 downto 0) := "001100"; -- 0x0C
        constant A_COUNT     : std_logic_vector(ADDR_W-1 downto 0) := "010000"; -- 0x10
        constant A_IRQ_CNT   : std_logic_vector(ADDR_W-1 downto 0) := "010100"; -- 0x14
        constant A_PRESCALER : std_logic_vector(ADDR_W-1 downto 0) := "011000"; -- 0x18
        constant A_SCRATCH0  : std_logic_vector(ADDR_W-1 downto 0) := "011100"; -- 0x1C
        constant A_SCRATCH1  : std_logic_vector(ADDR_W-1 downto 0) := "100000"; -- 0x20
        constant A_SCRATCH2  : std_logic_vector(ADDR_W-1 downto 0) := "100100"; -- 0x24
        constant A_SCRATCH3  : std_logic_vector(ADDR_W-1 downto 0) := "101000"; -- 0x28
        constant A_VERSION   : std_logic_vector(ADDR_W-1 downto 0) := "101100"; -- 0x2C

        variable rd : std_logic_vector(DATA_W-1 downto 0);

    begin
        rst_n <= '0'; wait for 100 ns;
        wait until rising_edge(clk); rst_n <= '1';
        wait until rising_edge(clk); wait until rising_edge(clk);

        -- ========== TEST 1: IRQ with irq_mask enabled ==========
        report "=== TEST 1: threshold=10, condition=10, mask=1 ===";
        axi_write(A_THRESHOLD, x"0000000A");
        axi_write(A_CONDITION, x"0000000A");
        axi_write(A_PRESCALER, x"00000000");  -- no prescaler
        axi_write(A_CTRL, x"00000005");        -- start=1 + irq_mask=1 (bit2)

        wait until irq_out = '1' for 500 ns;
        assert irq_out = '1' report "FAIL T1: IRQ not fired" severity error;
        report "OK T1: IRQ fired";

        axi_read(A_IRQ_CNT, rd);
        report "  IRQ_COUNT = " & integer'image(to_integer(unsigned(rd)));

        axi_write(A_CTRL, x"00000002");  -- clear
        wait for 30 ns;
        axi_write(A_CTRL, x"00000000");
        wait for 50 ns;

        -- ========== TEST 2: IRQ masked (bit2=0) ==========
        report "=== TEST 2: same config but irq_mask=0 ===";
        axi_write(A_CTRL, x"00000001");  -- start=1, mask=0

        wait for 300 ns;
        assert irq_out = '0' report "FAIL T2: IRQ should be masked" severity error;
        report "OK T2: IRQ masked (irq_out stays low)";

        -- FSM should still be in IRQ_FIRE internally (irq_reg=1 but masked)
        axi_read(A_STATUS, rd);
        report "  STATUS = " & integer'image(to_integer(unsigned(rd)));

        axi_write(A_CTRL, x"00000002");  -- clear
        wait for 30 ns;
        axi_write(A_CTRL, x"00000000");
        wait for 50 ns;

        -- ========== TEST 3: Prescaler ==========
        report "=== TEST 3: prescaler=4, threshold=5 (should take 5*5=25 clocks) ===";
        axi_write(A_PRESCALER, x"00000004");   -- divide by 5
        axi_write(A_THRESHOLD, x"00000005");   -- count to 5
        axi_write(A_CONDITION, x"00000005");
        axi_write(A_CTRL, x"00000005");        -- start + mask

        wait until irq_out = '1' for 1000 ns;
        assert irq_out = '1' report "FAIL T3: prescaler IRQ not fired" severity error;
        report "OK T3: prescaler IRQ fired";

        axi_read(A_COUNT, rd);
        report "  COUNT = " & integer'image(to_integer(unsigned(rd)));
        assert to_integer(unsigned(rd)) = 5
            report "FAIL T3: count should be 5" severity error;

        axi_write(A_CTRL, x"00000002");
        wait for 30 ns;
        axi_write(A_CTRL, x"00000000");
        wait for 50 ns;

        -- ========== TEST 4: Scratch registers ==========
        report "=== TEST 4: scratch R/W ===";
        axi_write(A_SCRATCH0, x"DEADBEEF");
        axi_write(A_SCRATCH1, x"CAFEBABE");
        axi_write(A_SCRATCH2, x"12345678");
        axi_write(A_SCRATCH3, x"FFFFFFFF");

        axi_read(A_SCRATCH0, rd);
        assert rd = x"DEADBEEF" report "FAIL: SCRATCH0" severity error;
        axi_read(A_SCRATCH1, rd);
        assert rd = x"CAFEBABE" report "FAIL: SCRATCH1" severity error;
        axi_read(A_SCRATCH2, rd);
        assert rd = x"12345678" report "FAIL: SCRATCH2" severity error;
        axi_read(A_SCRATCH3, rd);
        assert rd = x"FFFFFFFF" report "FAIL: SCRATCH3" severity error;
        report "OK T4: all scratch registers verified";

        -- ========== TEST 5: VERSION register (read-only) ==========
        report "=== TEST 5: VERSION ===";
        axi_read(A_VERSION, rd);
        report "  VERSION = " & integer'image(to_integer(unsigned(rd)));
        assert rd = x"20000001"
            report "FAIL: VERSION should be 0x20000001" severity error;
        report "OK T5: VERSION = 0x20000001";

        -- ========== TEST 6: Total IRQ count ==========
        report "=== TEST 6: check total IRQ_COUNT ===";
        axi_read(A_IRQ_CNT, rd);
        report "  Total IRQ_COUNT = " & integer'image(to_integer(unsigned(rd)));
        -- T1 fired, T2 fired (masked but FSM still counts), T3 fired = 3
        assert to_integer(unsigned(rd)) = 3
            report "FAIL: IRQ_COUNT should be 3" severity error;

        report "========== ALL TESTS PASSED ==========";
        wait for 100 ns;
        assert false report "Simulation complete" severity note;
        wait;
    end process;

end sim;
