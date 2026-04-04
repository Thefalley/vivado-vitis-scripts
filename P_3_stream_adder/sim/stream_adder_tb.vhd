library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity stream_adder_tb is
end stream_adder_tb;

architecture tb of stream_adder_tb is

    constant CLK_PERIOD : time := 10 ns;
    constant DATA_WIDTH : integer := 32;

    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';

    -- AXI-Lite
    signal axil_awaddr  : std_logic_vector(6 downto 0) := (others => '0');
    signal axil_awvalid : std_logic := '0';
    signal axil_awready : std_logic;
    signal axil_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal axil_wstrb   : std_logic_vector(3 downto 0) := "1111";
    signal axil_wvalid  : std_logic := '0';
    signal axil_wready  : std_logic;
    signal axil_bresp   : std_logic_vector(1 downto 0);
    signal axil_bvalid  : std_logic;
    signal axil_bready  : std_logic := '1';
    signal axil_araddr  : std_logic_vector(6 downto 0) := (others => '0');
    signal axil_arvalid : std_logic := '0';
    signal axil_arready : std_logic;
    signal axil_rdata   : std_logic_vector(31 downto 0);
    signal axil_rresp   : std_logic_vector(1 downto 0);
    signal axil_rvalid  : std_logic;
    signal axil_rready  : std_logic := '1';

    -- AXI-Stream input
    signal s_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal s_tlast  : std_logic := '0';
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;

    -- AXI-Stream output
    signal m_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal m_tlast  : std_logic;
    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';

    -- Test control
    signal test_done : boolean := false;

begin

    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    uut : entity work.stream_adder
        generic map (DATA_WIDTH => DATA_WIDTH)
        port map (
            clk            => clk,
            resetn         => resetn,
            S_AXI_AWADDR   => axil_awaddr,
            S_AXI_AWPROT   => "000",
            S_AXI_AWVALID  => axil_awvalid,
            S_AXI_AWREADY  => axil_awready,
            S_AXI_WDATA    => axil_wdata,
            S_AXI_WSTRB    => axil_wstrb,
            S_AXI_WVALID   => axil_wvalid,
            S_AXI_WREADY   => axil_wready,
            S_AXI_BRESP    => axil_bresp,
            S_AXI_BVALID   => axil_bvalid,
            S_AXI_BREADY   => axil_bready,
            S_AXI_ARADDR   => axil_araddr,
            S_AXI_ARPROT   => "000",
            S_AXI_ARVALID  => axil_arvalid,
            S_AXI_ARREADY  => axil_arready,
            S_AXI_RDATA    => axil_rdata,
            S_AXI_RRESP    => axil_rresp,
            S_AXI_RVALID   => axil_rvalid,
            S_AXI_RREADY   => axil_rready,
            s_axis_tdata   => s_tdata,
            s_axis_tlast   => s_tlast,
            s_axis_tvalid  => s_tvalid,
            s_axis_tready  => s_tready,
            m_axis_tdata   => m_tdata,
            m_axis_tlast   => m_tlast,
            m_axis_tvalid  => m_tvalid,
            m_axis_tready  => m_tready
        );

    -- AXI-Lite write procedure
    stim : process
        procedure axil_write(addr : in std_logic_vector(6 downto 0);
                             data : in std_logic_vector(31 downto 0)) is
        begin
            axil_awaddr  <= addr;
            axil_awvalid <= '1';
            axil_wdata   <= data;
            axil_wvalid  <= '1';
            wait until rising_edge(clk) and axil_awready = '1';
            axil_awvalid <= '0';
            axil_wvalid  <= '0';
            wait until rising_edge(clk) and axil_bvalid = '1';
            wait until rising_edge(clk);
        end procedure;

        procedure send_stream(data : in integer; last : in std_logic) is
        begin
            s_tdata  <= std_logic_vector(to_unsigned(data, DATA_WIDTH));
            s_tlast  <= last;
            s_tvalid <= '1';
            wait until rising_edge(clk) and s_tready = '1';
            s_tvalid <= '0';
            s_tlast  <= '0';
        end procedure;

        variable expected : unsigned(DATA_WIDTH - 1 downto 0);
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

    begin
        -- Reset
        resetn <= '0';
        wait for CLK_PERIOD * 10;
        resetn <= '1';
        wait for CLK_PERIOD * 5;

        -------------------------------------------------------
        -- TEST 1: add_value = 0 (passthrough)
        -------------------------------------------------------
        report "TEST 1: add_value = 0 (passthrough)";
        axil_write("0000000", x"00000000");
        wait for CLK_PERIOD * 2;

        send_stream(100, '0');
        send_stream(200, '0');
        send_stream(300, '1');

        wait for CLK_PERIOD * 20;

        -------------------------------------------------------
        -- TEST 2: add_value = 10
        -------------------------------------------------------
        report "TEST 2: add_value = 10";
        axil_write("0000000", x"0000000A");
        wait for CLK_PERIOD * 2;

        -- Send 4 values: 1, 2, 3, 4
        send_stream(1, '0');
        send_stream(2, '0');
        send_stream(3, '0');
        send_stream(4, '1');

        wait for CLK_PERIOD * 20;

        -------------------------------------------------------
        -- TEST 3: add_value = 0xFFFFFFFF (wrap around)
        -------------------------------------------------------
        report "TEST 3: add_value = 0xFFFFFFFF (overflow wrap)";
        axil_write("0000000", x"FFFFFFFF");
        wait for CLK_PERIOD * 2;

        send_stream(1, '0');
        send_stream(0, '1');

        wait for CLK_PERIOD * 20;

        -------------------------------------------------------
        -- TEST 4: backpressure (m_tready toggling)
        -------------------------------------------------------
        report "TEST 4: backpressure test";
        axil_write("0000000", x"00000005");
        wait for CLK_PERIOD * 2;

        m_tready <= '0'; -- Block output
        send_stream(10, '0');
        send_stream(20, '1');
        wait for CLK_PERIOD * 5;
        m_tready <= '1'; -- Release
        wait for CLK_PERIOD * 20;

        report "ALL TESTS COMPLETE";
        test_done <= true;
        wait;
    end process;

    -- Output monitor
    monitor : process(clk)
    begin
        if rising_edge(clk) then
            if m_tvalid = '1' and m_tready = '1' then
                report "OUT: data=" & integer'image(to_integer(unsigned(m_tdata))) &
                       " last=" & std_logic'image(m_tlast);
            end if;
        end if;
    end process;

end tb;
