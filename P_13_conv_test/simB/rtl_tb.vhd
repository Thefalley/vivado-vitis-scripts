library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Unisim for post-synth primitives

entity rtl_tb is
end entity;

architecture sim of rtl_tb is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';

    -- AXI-Lite signals
    signal awaddr  : std_logic_vector(14 downto 0) := (others => '0');
    signal awprot  : std_logic_vector(2 downto 0) := "000";
    signal awvalid : std_logic := '0';
    signal awready : std_logic;
    signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb   : std_logic_vector(3 downto 0) := "1111";
    signal wvalid  : std_logic := '0';
    signal wready  : std_logic;
    signal bresp   : std_logic_vector(1 downto 0);
    signal bvalid  : std_logic;
    signal bready  : std_logic := '1';
    signal araddr  : std_logic_vector(14 downto 0) := (others => '0');
    signal arprot  : std_logic_vector(2 downto 0) := "000";
    signal arvalid : std_logic := '0';
    signal arready : std_logic;
    signal rdata   : std_logic_vector(31 downto 0);
    signal rresp   : std_logic_vector(1 downto 0);
    signal rvalid  : std_logic;
    signal rready  : std_logic := '1';

    constant CLK_PERIOD : time := 11.111 ns; -- 90 MHz

    -- Test data (same as conv_test.c layer_005 subset)
    type s8_array is array(natural range <>) of integer;

    constant INPUT_DATA : s8_array(0 to 26) := (
        56,-106,21, 50,-102,17, 6,-97,-6,
        62,-64,39, 59,-57,34, 29,-42,23,
        65,-40,44, 70,-31,33, 39,-24,31
    );

    -- First 27 weights (filter 0 only, for quick check)
    constant WEIGHT_F0 : s8_array(0 to 26) := (
        -4,-3,10, -8,-12,11, -4,-5,7,
        -2,-4,6, -6,-12,6, -1,-4,6,
        0,-2,0, -3,-5,3, -1,-2,5
    );

    -- Procedures
    procedure axi_write(
        signal clk_s : in std_logic;
        signal awaddr_s : out std_logic_vector(14 downto 0);
        signal awvalid_s : out std_logic;
        signal awready_s : in std_logic;
        signal wdata_s : out std_logic_vector(31 downto 0);
        signal wvalid_s : out std_logic;
        signal wready_s : in std_logic;
        signal bvalid_s : in std_logic;
        addr : in unsigned(14 downto 0);
        data : in std_logic_vector(31 downto 0)
    ) is
    begin
        awaddr_s <= std_logic_vector(addr);
        wdata_s <= data;
        awvalid_s <= '1';
        wvalid_s <= '1';
        wait until rising_edge(clk_s) and awready_s = '1';
        awvalid_s <= '0';
        wvalid_s <= '0';
        if bvalid_s = '0' then
            wait until rising_edge(clk_s) and bvalid_s = '1';
        end if;
        wait until rising_edge(clk_s);
    end procedure;

    procedure axi_read(
        signal clk_s : in std_logic;
        signal araddr_s : out std_logic_vector(14 downto 0);
        signal arvalid_s : out std_logic;
        signal arready_s : in std_logic;
        signal rdata_s : in std_logic_vector(31 downto 0);
        signal rvalid_s : in std_logic;
        addr : in unsigned(14 downto 0);
        result : out std_logic_vector(31 downto 0)
    ) is
    begin
        araddr_s <= std_logic_vector(addr);
        arvalid_s <= '1';
        wait until rising_edge(clk_s) and arready_s = '1';
        arvalid_s <= '0';
        wait until rising_edge(clk_s) and rvalid_s = '1';
        result := rdata_s;
        wait until rising_edge(clk_s);
    end procedure;

begin
    clk <= not clk after CLK_PERIOD / 2;

    -- DUT: post-synth netlist of conv_test_wrapper
    u_dut : entity work.conv_test_wrapper
        port map (
            s_axi_aclk    => clk,
            s_axi_aresetn => resetn,
            s_axi_awaddr  => awaddr,
            s_axi_awprot  => awprot,
            s_axi_awvalid => awvalid,
            s_axi_awready => awready,
            s_axi_wdata   => wdata,
            s_axi_wstrb   => wstrb,
            s_axi_wvalid  => wvalid,
            s_axi_wready  => wready,
            s_axi_bresp   => bresp,
            s_axi_bvalid  => bvalid,
            s_axi_bready  => bready,
            s_axi_araddr  => araddr,
            s_axi_arprot  => arprot,
            s_axi_arvalid => arvalid,
            s_axi_arready => arready,
            s_axi_rdata   => rdata,
            s_axi_rresp   => rresp,
            s_axi_rvalid  => rvalid,
            s_axi_rready  => rready
        );

    p_main : process
        variable rd_val : std_logic_vector(31 downto 0);
        variable word   : std_logic_vector(31 downto 0);
        variable byte_val : signed(7 downto 0);
        variable timeout : integer;
    begin
        resetn <= '0';
        wait for 200 ns;
        resetn <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);

        report "Writing input (27 bytes)...";
        for i in 0 to 6 loop
            word := (others => '0');
            for b in 0 to 3 loop
                if i*4+b < 27 then
                    word(b*8+7 downto b*8) := std_logic_vector(to_signed(INPUT_DATA(i*4+b), 8));
                end if;
            end loop;
            axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                       to_unsigned(16#1000# + i*4, 15), word);
        end loop;

        report "Writing weights filter 0 (27 bytes)...";
        for i in 0 to 6 loop
            word := (others => '0');
            for b in 0 to 3 loop
                if i*4+b < 27 then
                    word(b*8+7 downto b*8) := std_logic_vector(to_signed(WEIGHT_F0(i*4+b), 8));
                end if;
            end loop;
            axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                       to_unsigned(16#1400# + i*4, 15), word);
        end loop;

        report "Writing bias (1 x int32 = 1623)...";
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#1800#, 15), std_logic_vector(to_signed(1623, 32)));

        -- DEBUG: readback bias and first input/weight words
        report "DEBUG: Reading back bias at 0x1800...";
        axi_read(clk, araddr, arvalid, arready, rdata, rvalid,
                  to_unsigned(16#1800#, 15), rd_val);
        report "DEBUG: bias readback = " & integer'image(to_integer(signed(rd_val)))
             & " (expect 1623)";

        report "DEBUG: Reading back input word 0 at 0x1000...";
        axi_read(clk, araddr, arvalid, arready, rdata, rvalid,
                  to_unsigned(16#1000#, 15), rd_val);
        report "DEBUG: input[0] readback = " & integer'image(to_integer(signed(rd_val)));

        report "DEBUG: Reading back weight word 0 at 0x1400...";
        axi_read(clk, araddr, arvalid, arready, rdata, rvalid,
                  to_unsigned(16#1400#, 15), rd_val);
        report "DEBUG: weight[0] readback = " & integer'image(to_integer(signed(rd_val)));

        report "Configuring registers...";
        -- c_in=1 (single OC for quick test), c_out=1
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#04#, 15), x"00000003"); -- c_in=3
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#08#, 15), x"00000001"); -- c_out=1
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#0C#, 15), x"00000003"); -- h_in=3
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#10#, 15), x"00000003"); -- w_in=3
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#14#, 15), x"0000000A"); -- ksize=2,stride=0,pad=1
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#18#, 15), x"00000180"); -- x_zp=-128 as 9-bit
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#1C#, 15), x"00000000"); -- w_zp=0
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#20#, 15), x"272D1B1E"); -- M0=656954014
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#24#, 15), x"00000025"); -- n_shift=37
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#28#, 15), x"000000EF"); -- y_zp=-17 as 8-bit
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#2C#, 15), x"00000000"); -- addr_input=0
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#30#, 15), x"00000400"); -- addr_weights=0x400
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#34#, 15), x"00000800"); -- addr_bias=0x800
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#38#, 15), x"00000C00"); -- addr_output=0xC00

        report "Starting conv...";
        axi_write(clk, awaddr, awvalid, awready, wdata, wvalid, wready, bvalid,
                   to_unsigned(16#00#, 15), x"00000001"); -- start

        report "Polling done...";
        timeout := 0;
        loop
            axi_read(clk, araddr, arvalid, arready, rdata, rvalid,
                      to_unsigned(16#00#, 15), rd_val);
            exit when rd_val(1) = '1'; -- done bit
            timeout := timeout + 1;
            assert timeout < 100000 report "TIMEOUT" severity failure;
        end loop;

        report "Done! Reading output...";
        -- Read 9 output bytes from 0xC00
        for i in 0 to 2 loop
            axi_read(clk, araddr, arvalid, arready, rdata, rvalid,
                      to_unsigned(16#1C00# + i*4, 15), rd_val);
            for b in 0 to 2 loop
                if i*3+b < 9 then
                    byte_val := signed(rd_val(b*8+7 downto b*8));
                    report "out[" & integer'image(i) & "][" & integer'image(b) & "] = " & integer'image(to_integer(byte_val));
                end if;
            end loop;
        end loop;

        report "Post-synth simulation complete";
        wait;
    end process;
end architecture;
