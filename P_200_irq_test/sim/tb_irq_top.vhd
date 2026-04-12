library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- tb_irq_top: Testbench completo para irq_top
--
-- TEST 1: threshold=10, condition=10  -> IRQ debe disparar
-- TEST 2: threshold=10, condition=5   -> IRQ NO debe disparar
-- TEST 3: re-arrancar con condition=10 -> segundo IRQ

entity tb_irq_top is
end tb_irq_top;

architecture sim of tb_irq_top is

    constant CLK_PERIOD : time    := 10 ns;  -- 100 MHz
    constant ADDR_W     : integer := 5;
    constant DATA_W     : integer := 32;

    signal clk     : std_logic := '0';
    signal rst_n   : std_logic := '0';
    signal irq_out : std_logic;

    -- AXI-Lite master signals
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

    -- Clock
    clk <= not clk after CLK_PERIOD / 2;

    -- DUT
    DUT: entity work.irq_top
        generic map (
            C_S_AXI_DATA_WIDTH => DATA_W,
            C_S_AXI_ADDR_WIDTH => ADDR_W
        )
        port map (
            irq_out       => irq_out,
            S_AXI_ACLK    => clk,
            S_AXI_ARESETN => rst_n,
            S_AXI_AWADDR  => awaddr,
            S_AXI_AWPROT  => awprot,
            S_AXI_AWVALID => awvalid,
            S_AXI_AWREADY => awready,
            S_AXI_WDATA   => wdata,
            S_AXI_WSTRB   => wstrb,
            S_AXI_WVALID  => wvalid,
            S_AXI_WREADY  => wready,
            S_AXI_BRESP   => bresp,
            S_AXI_BVALID  => bvalid,
            S_AXI_BREADY  => bready,
            S_AXI_ARADDR  => araddr,
            S_AXI_ARPROT  => arprot,
            S_AXI_ARVALID => arvalid,
            S_AXI_ARREADY => arready,
            S_AXI_RDATA   => rdata,
            S_AXI_RRESP   => rresp,
            S_AXI_RVALID  => rvalid,
            S_AXI_RREADY  => rready
        );

    -- Stimulus
    stim: process

        ---------------------------------------------------------------
        -- AXI-Lite write: drives AW+W channels, waits for B response
        ---------------------------------------------------------------
        procedure axi_write(
            addr : in std_logic_vector(ADDR_W-1 downto 0);
            data : in std_logic_vector(DATA_W-1 downto 0)
        ) is
        begin
            awaddr  <= addr;
            awvalid <= '1';
            wdata   <= data;
            wstrb   <= x"F";
            wvalid  <= '1';
            bready  <= '1';
            loop
                wait until rising_edge(clk);
                exit when bvalid = '1';
            end loop;
            awvalid <= '0';
            wvalid  <= '0';
            wait until rising_edge(clk);
            bready  <= '0';
        end procedure;

        ---------------------------------------------------------------
        -- AXI-Lite read: drives AR channel, captures R data
        ---------------------------------------------------------------
        procedure axi_read(
            addr : in  std_logic_vector(ADDR_W-1 downto 0);
            data : out std_logic_vector(DATA_W-1 downto 0)
        ) is
        begin
            araddr  <= addr;
            arvalid <= '1';
            rready  <= '1';
            loop
                wait until rising_edge(clk);
                exit when rvalid = '1';
            end loop;
            data := rdata;
            arvalid <= '0';
            rready  <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Register byte addresses
        constant A_CTRL      : std_logic_vector(ADDR_W-1 downto 0) := "00000";  -- 0x00
        constant A_THRESHOLD : std_logic_vector(ADDR_W-1 downto 0) := "00100";  -- 0x04
        constant A_CONDITION : std_logic_vector(ADDR_W-1 downto 0) := "01000";  -- 0x08
        constant A_STATUS    : std_logic_vector(ADDR_W-1 downto 0) := "01100";  -- 0x0C
        constant A_COUNT     : std_logic_vector(ADDR_W-1 downto 0) := "10000";  -- 0x10
        constant A_IRQ_CNT   : std_logic_vector(ADDR_W-1 downto 0) := "10100";  -- 0x14

        variable rd : std_logic_vector(DATA_W-1 downto 0);

    begin
        -- ============================================================
        -- Reset
        -- ============================================================
        rst_n <= '0';
        wait for 100 ns;
        wait until rising_edge(clk);
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -- ============================================================
        -- TEST 1: threshold=10, condition=10 -> IRQ fires
        -- ============================================================
        report "=== TEST 1: threshold=10, condition=10 (IRQ expected) ===";

        axi_write(A_THRESHOLD, x"0000000A");  -- 10
        axi_write(A_CONDITION, x"0000000A");  -- 10
        axi_write(A_CTRL,      x"00000001");  -- start=1

        -- Wait for interrupt
        wait until irq_out = '1' for 500 ns;
        assert irq_out = '1'
            report "FAIL: IRQ did not fire" severity error;
        report "OK: IRQ fired";

        -- Read STATUS -> expect irq_pending (bit1) = 1
        axi_read(A_STATUS, rd);
        report "  STATUS    = " & integer'image(to_integer(unsigned(rd)));
        assert rd(1) = '1'
            report "FAIL: irq_pending not set" severity error;

        -- Read counter value
        axi_read(A_COUNT, rd);
        report "  COUNT     = " & integer'image(to_integer(unsigned(rd)));

        -- Read IRQ counter -> should be 1
        axi_read(A_IRQ_CNT, rd);
        report "  IRQ_COUNT = " & integer'image(to_integer(unsigned(rd)));
        assert to_integer(unsigned(rd)) = 1
            report "FAIL: IRQ_COUNT should be 1" severity error;

        -- Clear interrupt
        axi_write(A_CTRL, x"00000002");  -- irq_clear=1
        wait for 30 ns;
        assert irq_out = '0'
            report "FAIL: IRQ did not clear" severity error;
        report "OK: IRQ cleared";

        -- Reset CTRL
        axi_write(A_CTRL, x"00000000");
        wait for 50 ns;

        -- ============================================================
        -- TEST 2: threshold=10, condition=5 -> NO IRQ
        -- ============================================================
        report "=== TEST 2: threshold=10, condition=5 (no IRQ expected) ===";

        axi_write(A_THRESHOLD, x"0000000A");  -- 10
        axi_write(A_CONDITION, x"00000005");  -- 5 (counter will be 10, not 5)
        axi_write(A_CTRL,      x"00000001");  -- start=1

        -- Wait ~200ns -> FSM cycles twice without IRQ
        wait for 200 ns;
        assert irq_out = '0'
            report "FAIL: IRQ fired when it should NOT" severity error;
        report "OK: no IRQ (correct)";

        -- Read STATUS -> expect running (bit0=1), no irq (bit1=0)
        axi_read(A_STATUS, rd);
        report "  STATUS    = " & integer'image(to_integer(unsigned(rd)));
        assert rd(0) = '1'
            report "FAIL: FSM should be running" severity error;

        -- Stop FSM
        axi_write(A_CTRL, x"00000000");
        wait for 50 ns;

        -- ============================================================
        -- TEST 3: restart, condition matches -> second IRQ
        -- ============================================================
        report "=== TEST 3: restart with condition=10 (second IRQ) ===";

        axi_write(A_CONDITION, x"0000000A");  -- fix condition to 10
        axi_write(A_CTRL,      x"00000001");  -- start=1

        wait until irq_out = '1' for 500 ns;
        assert irq_out = '1'
            report "FAIL: second IRQ did not fire" severity error;
        report "OK: second IRQ fired";

        -- IRQ_COUNT should be 2
        axi_read(A_IRQ_CNT, rd);
        report "  IRQ_COUNT = " & integer'image(to_integer(unsigned(rd)));
        assert to_integer(unsigned(rd)) = 2
            report "FAIL: IRQ_COUNT should be 2" severity error;

        -- Clear
        axi_write(A_CTRL, x"00000002");
        wait for 30 ns;
        axi_write(A_CTRL, x"00000000");
        wait for 50 ns;

        -- ============================================================
        report "========== ALL TESTS PASSED ==========";
        wait for 100 ns;
        assert false report "Simulation complete" severity note;
        wait;
    end process;

end sim;
