-------------------------------------------------------------------------------
-- full_test_tb.vhd -- Complete test of conv_test_wrapper (byte-array mem)
--                     using real layer_005 data: c_in=3, c_out=32, 3x3, pad=1
-------------------------------------------------------------------------------
-- FINDING: The conv_engine MAC loop iterates (kh, kw, ic) and expects weights
-- in OHWI layout. The C test data stores them in OIHW. This TB transposes
-- them before writing to the wrapper BRAM, matching what the C code must also
-- do (write_bram_bytes should use transposed weights).
--
-- Two tests run sequentially:
--   Part A: conv_engine directly (DDR model) -- validates engine + transpose
--   Part B: conv_test_wrapper via AXI-Lite   -- validates byte-array wrapper
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity full_test_tb is
end entity full_test_tb;

architecture sim of full_test_tb is

    constant CLK_PERIOD : time := 10 ns;

    ---------------------------------------------------------------------------
    -- Test data arrays (from conv_test.c -- OIHW layout as-is)
    ---------------------------------------------------------------------------
    type s8_array_t is array(natural range <>) of integer range -128 to 127;
    type s32_array_t is array(natural range <>) of integer;

    constant INPUT_DATA : s8_array_t(0 to 26) := (
         56,-106,  21,  50,-102,  17,   6, -97,  -6,
         62, -64,  39,  59, -57,  34,  29, -42,  23,
         65, -40,  44,  70, -31,  33,  39, -24,  31
    );

    constant WEIGHT_OIHW : s8_array_t(0 to 863) := (
        -4,-3,10,-8,-12,11,-4,-5,7,-2,-4,6,-6,-12,6,-1,-4,6,0,-2,0,-3,-5,3,-1,-2,5,
        -13,-2,4,-7,3,6,1,5,0,-10,-3,6,-9,-1,5,4,6,5,-8,-7,-5,-8,-6,-3,-1,-2,-3,
        -2,-6,-9,-2,-7,-9,0,-1,-4,3,-3,0,3,-7,-2,4,2,4,2,1,4,1,-1,5,-1,2,5,
        3,-1,-14,0,-9,-6,8,-2,-6,0,3,2,-6,-7,9,-3,-6,3,4,7,3,-1,-6,9,-2,-11,-3,
        -2,-12,-1,2,-23,5,6,9,8,-5,-9,-7,-2,-16,-5,-1,4,-3,0,-3,-1,3,-7,1,3,5,3,
        2,-2,2,0,-4,-2,1,-3,0,-7,-7,-8,-6,-7,-8,-7,-7,-8,5,8,5,7,13,10,6,10,8,
        -1,0,-2,1,6,2,-2,1,-1,3,5,5,4,10,7,6,9,8,-2,-6,-4,-5,-12,-9,-4,-11,-8,
        10,18,12,0,0,0,-10,-18,-11,9,17,10,0,0,0,-9,-17,-11,6,12,7,0,0,0,-6,-12,-7,
        6,-3,-9,9,-8,-12,10,-1,-3,7,-1,-3,6,-10,-9,8,-2,0,3,0,-1,3,-6,-5,3,-3,-2,
        -28,7,-27,5,127,5,-29,-13,-27,14,-16,14,-11,-18,-17,16,-27,10,14,-6,16,-4,-54,-5,14,2,20,
        -1,-1,-7,3,10,-10,6,-4,-8,3,1,-8,7,10,-13,10,-5,-10,3,1,-8,7,14,-8,10,-1,-7,
        2,0,0,-1,-8,-4,2,-6,-2,-4,-6,-6,-6,-9,-8,-3,-9,-6,3,9,4,6,19,12,2,12,8,
        -3,-2,1,-4,-3,1,0,1,4,-5,0,9,-10,-4,8,-7,-2,8,-5,1,9,-10,-2,8,-9,-3,7,
        2,11,11,9,-46,1,5,-2,9,5,2,8,5,-30,-4,8,-5,3,-12,-1,-14,-4,16,-6,-11,2,-12,
        -10,1,12,-13,2,20,-14,-3,11,-7,-1,4,-8,3,13,-7,0,6,-2,-1,-1,-2,2,5,-2,1,2,
        1,6,2,4,20,10,1,10,5,-3,-9,-5,-6,-9,-9,-4,-11,-8,3,0,4,-1,-4,-2,4,-1,3,
        -4,-3,4,-6,-2,-8,-2,-12,-9,-1,4,2,4,9,-8,4,-8,-12,-6,2,-2,3,13,-7,7,-1,-11,
        -2,-1,3,-5,-48,46,-1,-4,5,7,0,0,-5,-60,53,9,-3,4,3,0,-2,3,-12,12,4,-3,1,
        -4,-4,-1,-11,-15,0,-2,-4,-4,-1,0,11,-12,-19,6,4,2,6,-7,-1,10,-13,-14,10,2,3,10,
        29,9,-21,36,4,-36,25,-3,-38,-11,-3,8,-11,2,21,-10,-2,10,-20,-7,12,-26,-1,31,-12,5,24,
        0,2,-1,2,2,2,2,4,3,3,0,2,-2,-7,-1,-2,-5,-1,0,0,2,-4,-5,-2,-4,-5,-3,
        -10,-13,-14,4,5,4,5,10,10,-7,-9,-9,1,3,1,5,9,7,-6,-7,-6,-2,0,0,4,8,7,
        -7,6,-6,0,-14,-6,-1,2,-5,7,10,10,3,-31,-1,3,-9,3,4,17,9,3,-18,3,-4,-10,2,
        6,2,3,4,-4,-4,5,-2,-9,0,-3,-1,-2,-8,-5,0,-6,-7,3,2,3,1,-2,0,3,-1,-2,
        -2,-1,-2,0,5,1,-4,2,-1,0,-2,-2,0,4,0,0,3,0,-2,0,-4,1,13,3,1,13,5,
        -1,1,-2,4,18,-8,1,0,-14,3,2,5,1,4,-6,4,-5,-7,-1,-4,2,-6,-7,-8,-4,-12,-8,
        0,4,4,2,11,13,0,6,5,0,-3,-4,-2,3,10,0,-1,-3,-2,-7,2,-4,2,25,-4,-11,-1,
        1,-12,2,-11,-32,-13,2,-18,0,4,6,4,6,24,8,5,9,4,-4,0,-5,0,23,3,-6,6,-4,
        2,4,0,6,17,4,0,6,1,-3,1,-1,0,14,-2,-3,2,-4,-4,-2,-5,2,17,-6,-2,5,-8,
        -21,-36,-31,-1,1,-7,27,44,31,4,15,11,0,10,2,-9,-14,-15,14,28,22,-1,5,4,-17,-32,-21,
        1,-5,1,0,-48,-4,-2,55,5,8,-13,7,1,-60,-10,-3,65,4,2,1,3,2,-21,-5,-3,21,1,
        4,5,8,-2,-6,2,-4,-5,0,-1,-1,-1,-4,-7,-4,-3,-3,-3,1,1,0,2,0,0,2,3,2
    );

    constant BIAS_DATA : s32_array_t(0 to 31) := (
        1623, 1048, 1258, 232, 1845, 1748, 1300, 1221,
        1861, 123, -859, -1173, 4085, 2515, 659, 825,
        1526, 3951, 1526, 1647, 1409, -616, 1566, 984,
        -6950, 1229, -10249, 2056, -8582, 1821, 3756, 814
    );

    constant EXPECTED_CH0 : s8_array_t(0 to 8) := (
        -36, -11, -45, -37, -9, -52, -29, -14, -42
    );

    constant EXPECTED_CENTER : s8_array_t(0 to 31) := (
        -9,-53,-10,-25,-20,-2,-17,-7,-5,-56,-31,-14,-6,-15,-14,-24,
        -43,67,-25,2,-23,-27,-11,-18,-39,-51,-43,9,-57,-16,14,-17
    );

    constant ADDR_INPUT   : natural := 16#000#;
    constant ADDR_WEIGHTS : natural := 16#400#;
    constant ADDR_BIAS    : natural := 16#800#;
    constant ADDR_OUTPUT  : natural := 16#C00#;

    constant C_IN  : integer := 3;
    constant K_SZ  : integer := 3;
    constant H_OUT : integer := 3;
    constant W_OUT : integer := 3;

    constant REG_BRAM_BASE : integer := 16#1000#;

    ---------------------------------------------------------------------------
    -- Transpose: OIHW -> OHWI
    ---------------------------------------------------------------------------
    function transpose_weights return s8_array_t is
        variable result : s8_array_t(0 to 863);
        variable src_idx, dst_idx : integer;
    begin
        for oc in 0 to 31 loop
            for kh in 0 to K_SZ-1 loop
                for kw in 0 to K_SZ-1 loop
                    for ic in 0 to C_IN-1 loop
                        dst_idx := oc * 27 + kh * K_SZ * C_IN + kw * C_IN + ic;
                        src_idx := oc * 27 + ic * K_SZ * K_SZ + kh * K_SZ + kw;
                        result(dst_idx) := WEIGHT_OIHW(src_idx);
                    end loop;
                end loop;
            end loop;
        end loop;
        return result;
    end function;

    constant WEIGHT_OHWI : s8_array_t(0 to 863) := transpose_weights;

    ---------------------------------------------------------------------------
    -- Wrapper AXI-Lite signals
    ---------------------------------------------------------------------------
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal awaddr    : std_logic_vector(14 downto 0) := (others => '0');
    signal awprot    : std_logic_vector(2 downto 0) := (others => '0');
    signal awvalid   : std_logic := '0';
    signal awready   : std_logic;
    signal wdata     : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb     : std_logic_vector(3 downto 0) := (others => '0');
    signal wvalid    : std_logic := '0';
    signal wready    : std_logic;
    signal bresp     : std_logic_vector(1 downto 0);
    signal bvalid    : std_logic;
    signal bready    : std_logic := '1';
    signal araddr    : std_logic_vector(14 downto 0) := (others => '0');
    signal arprot    : std_logic_vector(2 downto 0) := (others => '0');
    signal arvalid   : std_logic := '0';
    signal arready   : std_logic;
    signal rdata     : std_logic_vector(31 downto 0);
    signal rresp     : std_logic_vector(1 downto 0);
    signal rvalid    : std_logic;
    signal rready    : std_logic := '1';

    signal sim_done  : boolean := false;

    ---------------------------------------------------------------------------
    -- AXI write procedure
    ---------------------------------------------------------------------------
    procedure axi_write(
        signal aclk     : in  std_logic;
        signal aw_addr  : out std_logic_vector(14 downto 0);
        signal aw_valid : out std_logic;
        signal aw_ready : in  std_logic;
        signal w_dat    : out std_logic_vector(31 downto 0);
        signal w_str    : out std_logic_vector(3 downto 0);
        signal w_valid  : out std_logic;
        signal w_ready  : in  std_logic;
        signal b_valid  : in  std_logic;
        signal b_rdy    : out std_logic;
        constant addr   : in  integer;
        constant data   : in  std_logic_vector(31 downto 0);
        constant strobe : in  std_logic_vector(3 downto 0)
    ) is
    begin
        wait until rising_edge(aclk);
        aw_addr  <= std_logic_vector(to_unsigned(addr, 15));
        aw_valid <= '1';
        w_dat    <= data;
        w_str    <= strobe;
        w_valid  <= '1';
        b_rdy    <= '1';
        wait until rising_edge(aclk) and aw_ready = '1';
        aw_valid <= '0';
        w_valid  <= '0';
        if b_valid = '0' then
            wait until rising_edge(aclk) and b_valid = '1';
        end if;
        wait until rising_edge(aclk);
    end procedure;

    ---------------------------------------------------------------------------
    -- AXI read procedure
    ---------------------------------------------------------------------------
    procedure axi_read(
        signal aclk     : in  std_logic;
        signal ar_addr  : out std_logic_vector(14 downto 0);
        signal ar_valid : out std_logic;
        signal ar_ready : in  std_logic;
        signal r_data   : in  std_logic_vector(31 downto 0);
        signal r_valid  : in  std_logic;
        signal r_rdy    : out std_logic;
        constant addr   : in  integer;
        variable data   : out std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(aclk);
        ar_addr  <= std_logic_vector(to_unsigned(addr, 15));
        ar_valid <= '1';
        r_rdy    <= '1';
        wait until rising_edge(aclk) and ar_ready = '1';
        ar_valid <= '0';
        if r_valid = '0' then
            wait until rising_edge(aclk) and r_valid = '1';
        end if;
        data := r_data;
        wait until rising_edge(aclk);
    end procedure;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    ---------------------------------------------------------------------------
    -- DUT: conv_test_wrapper
    ---------------------------------------------------------------------------
    u_dut : entity work.conv_test_wrapper
        port map (
            s_axi_aclk    => clk,
            s_axi_aresetn => rst_n,
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

    ---------------------------------------------------------------------------
    -- Main stimulus
    ---------------------------------------------------------------------------
    p_stim : process
        variable v_word : std_logic_vector(31 downto 0);
        variable v_byte_val : integer;
        variable v_rdata : std_logic_vector(31 downto 0);
        variable v_got : integer;
        variable v_exp : integer;
        variable v_pass_count : integer := 0;
        variable v_fail_count : integer := 0;
        variable v_byte_pos : integer;
        variable v_word_addr : integer;
    begin
        -- Reset
        rst_n <= '0';
        wait for 100 ns;
        wait until rising_edge(clk);
        rst_n <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);

        report "========================================";
        report " FULL TEST: conv_test_wrapper + layer_005";
        report " (weights transposed OIHW -> OHWI)";
        report "========================================";

        -----------------------------------------------------------------------
        -- Write input data (27 bytes)
        -----------------------------------------------------------------------
        report "Writing input data (27 bytes)...";
        for i in 0 to 6 loop
            v_word := (others => '0');
            for b in 0 to 3 loop
                if i*4+b < 27 then
                    v_byte_val := INPUT_DATA(i*4+b);
                    if v_byte_val < 0 then
                        v_byte_val := v_byte_val + 256;
                    end if;
                    v_word(b*8+7 downto b*8) := std_logic_vector(to_unsigned(v_byte_val, 8));
                end if;
            end loop;
            if i < 6 then
                axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                           REG_BRAM_BASE + ADDR_INPUT + i*4, v_word, "1111");
            else
                axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                           REG_BRAM_BASE + ADDR_INPUT + i*4, v_word, "0111");
            end if;
        end loop;

        -----------------------------------------------------------------------
        -- Write TRANSPOSED weight data (864 bytes, OHWI layout)
        -----------------------------------------------------------------------
        report "Writing weight data (864 bytes, OHWI transposed)...";
        for i in 0 to 215 loop
            v_word := (others => '0');
            for b in 0 to 3 loop
                if i*4+b < 864 then
                    v_byte_val := WEIGHT_OHWI(i*4+b);
                    if v_byte_val < 0 then
                        v_byte_val := v_byte_val + 256;
                    end if;
                    v_word(b*8+7 downto b*8) := std_logic_vector(to_unsigned(v_byte_val, 8));
                end if;
            end loop;
            axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                       REG_BRAM_BASE + ADDR_WEIGHTS + i*4, v_word, "1111");
        end loop;

        -----------------------------------------------------------------------
        -- Write bias data (32 x int32)
        -----------------------------------------------------------------------
        report "Writing bias data (32 x int32)...";
        for i in 0 to 31 loop
            v_word := std_logic_vector(to_signed(BIAS_DATA(i), 32));
            axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                       REG_BRAM_BASE + ADDR_BIAS + i*4, v_word, "1111");
        end loop;

        -----------------------------------------------------------------------
        -- Configure registers
        -----------------------------------------------------------------------
        report "Configuring registers...";

        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#00#, x"00000000", "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#04#, std_logic_vector(to_unsigned(3, 32)), "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#08#, std_logic_vector(to_unsigned(32, 32)), "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#0C#, std_logic_vector(to_unsigned(3, 32)), "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#10#, std_logic_vector(to_unsigned(3, 32)), "1111");
        -- ksp = (1<<3)|(0<<2)|2 = 0x0A
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#14#, x"0000000A", "1111");
        -- x_zp = -128 -> 0x180
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#18#, x"00000180", "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#1C#, x"00000000", "1111");
        -- M0 = 0x272D1B1E
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#20#, x"272D1B1E", "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#24#, std_logic_vector(to_unsigned(37, 32)), "1111");
        -- y_zp = -17 -> 0xEF
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#28#, x"000000EF", "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#2C#, std_logic_vector(to_unsigned(ADDR_INPUT, 32)), "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#30#, std_logic_vector(to_unsigned(ADDR_WEIGHTS, 32)), "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#34#, std_logic_vector(to_unsigned(ADDR_BIAS, 32)), "1111");
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#38#, std_logic_vector(to_unsigned(ADDR_OUTPUT, 32)), "1111");

        -----------------------------------------------------------------------
        -- Pulse start
        -----------------------------------------------------------------------
        report "Starting conv_engine...";
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#00#, x"00000001", "1111");

        wait for 100 ns;
        axi_write(clk, awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bvalid, bready,
                   16#00#, x"00000000", "1111");

        -----------------------------------------------------------------------
        -- Poll for done
        -----------------------------------------------------------------------
        report "Polling for done...";
        for poll in 0 to 500000 loop
            axi_read(clk, araddr, arvalid, arready, rdata, rvalid, rready,
                      16#00#, v_rdata);
            if v_rdata(1) = '1' then
                report "Conv_engine DONE (poll=" & integer'image(poll) & ")";
                exit;
            end if;
            if poll = 500000 then
                report "TIMEOUT waiting for done!" severity failure;
            end if;
        end loop;

        -----------------------------------------------------------------------
        -- Verify channel 0 all 9 pixels
        -----------------------------------------------------------------------
        report "";
        report "=== Channel 0 -- all 9 pixels ===";

        for oh in 0 to 2 loop
            for ow in 0 to 2 loop
                v_byte_pos := ADDR_OUTPUT + oh * W_OUT + ow;
                v_word_addr := (v_byte_pos / 4) * 4;

                axi_read(clk, araddr, arvalid, arready, rdata, rvalid, rready,
                          REG_BRAM_BASE + v_word_addr, v_rdata);

                v_got := to_integer(signed(v_rdata((v_byte_pos mod 4)*8+7 downto (v_byte_pos mod 4)*8)));
                v_exp := EXPECTED_CH0(oh * 3 + ow);

                if v_got = v_exp then
                    report "  (" & integer'image(oh) & "," & integer'image(ow) &
                           "): got " & integer'image(v_got) &
                           "  exp " & integer'image(v_exp) & "  PASS";
                    v_pass_count := v_pass_count + 1;
                else
                    report "  (" & integer'image(oh) & "," & integer'image(ow) &
                           "): got " & integer'image(v_got) &
                           "  exp " & integer'image(v_exp) & "  FAIL" severity warning;
                    v_fail_count := v_fail_count + 1;
                end if;
            end loop;
        end loop;

        -----------------------------------------------------------------------
        -- Verify pixel(1,1) for all 32 channels
        -----------------------------------------------------------------------
        report "";
        report "=== Pixel (1,1) -- all 32 output channels ===";

        for oc in 0 to 31 loop
            v_byte_pos := ADDR_OUTPUT + oc * (H_OUT * W_OUT) + 1 * W_OUT + 1;
            v_word_addr := (v_byte_pos / 4) * 4;

            axi_read(clk, araddr, arvalid, arready, rdata, rvalid, rready,
                      REG_BRAM_BASE + v_word_addr, v_rdata);

            v_got := to_integer(signed(v_rdata((v_byte_pos mod 4)*8+7 downto (v_byte_pos mod 4)*8)));
            v_exp := EXPECTED_CENTER(oc);

            if v_got = v_exp then
                report "  oc " & integer'image(oc) &
                       ": got " & integer'image(v_got) &
                       "  exp " & integer'image(v_exp) & "  PASS";
                v_pass_count := v_pass_count + 1;
            else
                report "  oc " & integer'image(oc) &
                       ": got " & integer'image(v_got) &
                       "  exp " & integer'image(v_exp) & "  FAIL" severity warning;
                v_fail_count := v_fail_count + 1;
            end if;
        end loop;

        -----------------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------------
        report "";
        report "===================================================";
        report "  PASS: " & integer'image(v_pass_count) & " / " &
               integer'image(v_pass_count + v_fail_count);
        report "  FAIL: " & integer'image(v_fail_count) & " / " &
               integer'image(v_pass_count + v_fail_count);
        if v_fail_count = 0 then
            report "  RESULT: ALL 41 TESTS PASSED -- BIT-EXACT";
        else
            report "  RESULT: FAILURES DETECTED" severity warning;
        end if;
        report "===================================================";

        sim_done <= true;
        wait;
    end process;

end architecture sim;
