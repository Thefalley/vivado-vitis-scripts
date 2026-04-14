-------------------------------------------------------------------------------
-- conv_stream_tb.vhd -- Testbench for P_16 conv_stream_wrapper
-------------------------------------------------------------------------------
-- Target DUT: C:/project/vivado/P_16_conv_datamover/src/conv_stream_wrapper.vhd
--
-- Reuses the AXI-Lite write/read procedures from the P_14 TB. Adapts for:
--   * 7-bit AXI-Lite address (regs up to 0x50)
--   * m_axis_tkeep(3:0) output -- verified to be "1111" during tvalid='1'
--   * conv_engine_v3 asymmetric padding register map (0x44..0x50)
--
-- Scenario (= Stress Test 7 from P_13/simB/STRESS_TEST_RESULTS.txt):
--   c_in=1, c_out=32, h=3, w=3, 3x3 kernel, stride=1,
--   pad_top=1, pad_bottom=0, pad_left=1, pad_right=0  =>  h_out=2, w_out=2
--   Input all=10, Weights oc0=1 (rest 0), Bias=0, identity requantize.
--   Expected oc=0 (LE byte packing at output word 192 = 0x300):
--     (0,0)=40 (0x28), (0,1)=60 (0x3C), (1,0)=60 (0x3C), (1,1)=90 (0x5A)
--     word = 0x5A3C3C28
--   oc=1..31 all zeros (words 193..223 = 0x00000000).
--
-- BRAM layout (byte-addressed, 1 word = 4 bytes LE):
--   0x000 : input  (9 bytes, 3 words)
--   0x100 : weights (32 oc * 9 = 288 bytes; oc=0 -> 1, rest 0)
--   0x200 : bias (32 * int32 = 128 bytes = 32 words, all 0)
--   0x300 : output (32 oc * 4 = 128 bytes = 32 words, written by conv)
-- Total span: 0x380 bytes = 224 words.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity conv_stream_tb is
end entity conv_stream_tb;

architecture sim of conv_stream_tb is

    constant CLK_PERIOD : time := 10 ns;

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';

    -- AXI-Lite
    signal awaddr  : std_logic_vector(6 downto 0)  := (others => '0');
    signal awprot  : std_logic_vector(2 downto 0)  := (others => '0');
    signal awvalid : std_logic := '0';
    signal awready : std_logic;
    signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb   : std_logic_vector(3 downto 0)  := "1111";
    signal wvalid  : std_logic := '0';
    signal wready  : std_logic;
    signal bresp   : std_logic_vector(1 downto 0);
    signal bvalid  : std_logic;
    signal bready  : std_logic := '1';
    signal araddr  : std_logic_vector(6 downto 0)  := (others => '0');
    signal arprot  : std_logic_vector(2 downto 0)  := (others => '0');
    signal arvalid : std_logic := '0';
    signal arready : std_logic;
    signal rdata   : std_logic_vector(31 downto 0);
    signal rresp   : std_logic_vector(1 downto 0);
    signal rvalid  : std_logic;
    signal rready  : std_logic := '1';

    -- AXI-Stream Slave (input / LOAD)
    signal s_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_tlast  : std_logic := '0';
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;

    -- AXI-Stream Master (output / DRAIN)
    signal m_tdata  : std_logic_vector(31 downto 0);
    signal m_tlast  : std_logic;
    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '0';
    signal m_tkeep  : std_logic_vector(3 downto 0);

    -- Procedures -- reused from P_14 TB
    procedure axi_write(
        signal clk_s     : in  std_logic;
        signal awaddr_s  : out std_logic_vector(6 downto 0);
        signal awvalid_s : out std_logic;
        signal wdata_s   : out std_logic_vector(31 downto 0);
        signal wvalid_s  : out std_logic;
        signal bvalid_s  : in  std_logic;
        signal bready_s  : out std_logic;
        addr : in integer;
        data : in std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk_s);
        awaddr_s  <= std_logic_vector(to_unsigned(addr, 7));
        awvalid_s <= '1';
        wdata_s   <= data;
        wvalid_s  <= '1';
        bready_s  <= '1';
        loop
            wait until rising_edge(clk_s);
            if bvalid_s = '1' then
                exit;
            end if;
        end loop;
        awvalid_s <= '0';
        wvalid_s  <= '0';
        wait until rising_edge(clk_s);
    end procedure;

    procedure axi_read(
        signal clk_s     : in  std_logic;
        signal araddr_s  : out std_logic_vector(6 downto 0);
        signal arvalid_s : out std_logic;
        signal rvalid_s  : in  std_logic;
        signal rdata_s   : in  std_logic_vector(31 downto 0);
        signal rready_s  : out std_logic;
        addr : in  integer;
        data : out std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk_s);
        araddr_s  <= std_logic_vector(to_unsigned(addr, 7));
        arvalid_s <= '1';
        rready_s  <= '1';
        loop
            wait until rising_edge(clk_s);
            if rvalid_s = '1' then
                data := rdata_s;
                exit;
            end if;
        end loop;
        arvalid_s <= '0';
        wait until rising_edge(clk_s);
    end procedure;

    -- Byte addresses for BRAM layout
    constant ADDR_IN  : integer := 16#000#;
    constant ADDR_W   : integer := 16#100#;
    constant ADDR_B   : integer := 16#200#;
    constant ADDR_OUT : integer := 16#300#;

    constant N_LOAD_WORDS  : integer := 224;  -- 896 bytes, covers 0x000..0x37F
    constant OUT_WORD_BASE : integer := ADDR_OUT / 4;  -- = 192

    type word_array_t is array (natural range <>) of std_logic_vector(31 downto 0);

    -- Build the BRAM image for the asymmetric-pad scenario.
    -- Input: 9 bytes = 10 at addresses 0x000..0x008.
    --   word 0 (bytes 0..3)   = 0x0A0A0A0A
    --   word 1 (bytes 4..7)   = 0x0A0A0A0A
    --   word 2 (bytes 8..11)  = 0x000000_0A (byte 8 = 10, rest 0)
    -- Weights: 32 OC * 9 bytes = 288 bytes starting at 0x100 (word 64).
    --   oc=0 weights (bytes 0x100..0x108) all = 1.
    --   oc=1..31 weights all = 0.
    -- Bias: 32 int32 = 0 at 0x200..0x27F (words 128..159). Already zeros.
    -- Output at 0x300..0x37F (words 192..223): zero before conv; written by engine.
    function build_bram_image return word_array_t is
        variable img : word_array_t(0 to N_LOAD_WORDS-1) := (others => (others => '0'));
    begin
        -- Input bytes: 0..8 all = 10
        img(0) := x"0A0A0A0A";  -- bytes 0,1,2,3
        img(1) := x"0A0A0A0A";  -- bytes 4,5,6,7
        img(2) := x"0000000A";  -- byte 8 = 10; bytes 9,10,11 = 0

        -- Weights: oc=0 bytes 0x100..0x108 all = 1. That's words 64,65 full
        -- (0x100..0x107) plus byte 0x108 = first byte of word 66.
        img(64) := x"01010101";  -- 0x100..0x103
        img(65) := x"01010101";  -- 0x104..0x107
        img(66) := x"00000001";  -- byte 0x108 = 1; 0x109..0x10B = 0
        -- oc=1..31 weights -> 0 (already zero)

        -- Bias: all zeros (already zero)
        -- Output area: zero (will be overwritten by engine)

        return img;
    end function;

    constant BRAM_IMAGE : word_array_t(0 to N_LOAD_WORDS-1) := build_bram_image;

    signal test_pass    : boolean := true;
    signal tkeep_ok     : boolean := true;

begin

    clk <= not clk after CLK_PERIOD / 2;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    dut : entity work.conv_stream_wrapper
        port map (
            clk            => clk,
            rst_n          => rst_n,
            s_axi_awaddr   => awaddr,
            s_axi_awprot   => awprot,
            s_axi_awvalid  => awvalid,
            s_axi_awready  => awready,
            s_axi_wdata    => wdata,
            s_axi_wstrb    => wstrb,
            s_axi_wvalid   => wvalid,
            s_axi_wready   => wready,
            s_axi_bresp    => bresp,
            s_axi_bvalid   => bvalid,
            s_axi_bready   => bready,
            s_axi_araddr   => araddr,
            s_axi_arprot   => arprot,
            s_axi_arvalid  => arvalid,
            s_axi_arready  => arready,
            s_axi_rdata    => rdata,
            s_axi_rresp    => rresp,
            s_axi_rvalid   => rvalid,
            s_axi_rready   => rready,
            s_axis_tdata   => s_tdata,
            s_axis_tlast   => s_tlast,
            s_axis_tvalid  => s_tvalid,
            s_axis_tready  => s_tready,
            m_axis_tdata   => m_tdata,
            m_axis_tlast   => m_tlast,
            m_axis_tvalid  => m_tvalid,
            m_axis_tready  => m_tready,
            m_axis_tkeep   => m_tkeep
        );

    ---------------------------------------------------------------------------
    -- tkeep checker: whenever tvalid='1', tkeep must be "1111"
    ---------------------------------------------------------------------------
    p_tkeep_chk : process(clk)
    begin
        if rising_edge(clk) then
            if m_tvalid = '1' and m_tkeep /= "1111" then
                report "TB: tkeep mismatch! tvalid=1 but tkeep=" &
                       std_logic'image(m_tkeep(3)) & std_logic'image(m_tkeep(2)) &
                       std_logic'image(m_tkeep(1)) & std_logic'image(m_tkeep(0))
                       severity error;
                tkeep_ok  <= false;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    p_stim : process
        variable v_rd : std_logic_vector(31 downto 0);
        variable drain_words : integer := 0;
        variable exp : std_logic_vector(31 downto 0);
        variable any_fail : boolean := false;
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        report "TB: === Phase 1: Configure registers (asym pad [1,0,1,0]) ===" severity note;

        -- n_words for LOAD
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#04#, std_logic_vector(to_unsigned(N_LOAD_WORDS, 32)));
        -- c_in = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#08#, x"00000001");
        -- c_out = 32
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#0C#, x"00000020");
        -- h_in = 3
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#10#, x"00000003");
        -- w_in = 3
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#14#, x"00000003");
        -- ksp: ksize="01" (3x3), stride='0' => reg = 0x01
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#18#, x"00000001");
        -- x_zp = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#1C#, x"00000000");
        -- w_zp = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#20#, x"00000000");
        -- M0 = 1073741824 = 2^30
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#24#, x"40000000");
        -- n_shift = 30
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#28#, x"0000001E");
        -- y_zp = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#2C#, x"00000000");
        -- addr_input = 0x000
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#30#, std_logic_vector(to_unsigned(ADDR_IN, 32)));
        -- addr_weights = 0x100
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#34#, std_logic_vector(to_unsigned(ADDR_W, 32)));
        -- addr_bias = 0x200
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#38#, std_logic_vector(to_unsigned(ADDR_B, 32)));
        -- addr_output = 0x300
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#3C#, std_logic_vector(to_unsigned(ADDR_OUT, 32)));
        -- ic_tile_size = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#40#, x"00000001");
        -- pad_top = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#44#, x"00000001");
        -- pad_bottom = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#48#, x"00000000");
        -- pad_left = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#4C#, x"00000001");
        -- pad_right = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#50#, x"00000000");

        report "TB: === Phase 2: LOAD data via AXI-Stream ===" severity note;

        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#00#, x"00000001");  -- cmd_load

        for i in 0 to N_LOAD_WORDS - 1 loop
            s_tdata  <= BRAM_IMAGE(i);
            s_tvalid <= '1';
            if i = N_LOAD_WORDS - 1 then
                s_tlast <= '1';
            else
                s_tlast <= '0';
            end if;
            loop
                wait until rising_edge(clk);
                exit when s_tready = '1';
            end loop;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';

        wait for CLK_PERIOD * 5;

        report "TB: === Phase 3: START conv ===" severity note;
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#00#, x"00000002");  -- cmd_start

        -- Poll status register until done (bit 8)
        for i in 0 to 20000 loop
            wait for CLK_PERIOD * 10;
            axi_read(clk, araddr, arvalid, rvalid, rdata, rready,
                     16#00#, v_rd);
            if v_rd(8) = '1' then
                report "TB: Conv DONE after " & integer'image(i) & " poll iterations" severity note;
                exit;
            end if;
            if i = 20000 then
                report "TB: TIMEOUT waiting for conv done!" severity failure;
                test_pass <= false;
            end if;
        end loop;

        report "TB: === Phase 4: DRAIN output via AXI-Stream ===" severity note;

        -- Drain the full BRAM (N_LOAD_WORDS words)
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#04#, std_logic_vector(to_unsigned(N_LOAD_WORDS, 32)));
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#00#, x"00000004");  -- cmd_drain

        m_tready <= '1';
        drain_words := 0;
        for i in 0 to N_LOAD_WORDS + 200 loop
            wait until rising_edge(clk);
            if m_tvalid = '1' and m_tready = '1' then
                -- Check output region: words OUT_WORD_BASE .. OUT_WORD_BASE+31
                if drain_words = OUT_WORD_BASE then
                    -- oc=0: bytes (px0,px1,px2,px3) = (40,60,60,90)
                    -- Little-endian packing: byte0 -> bits 7:0
                    -- word = 0x5A3C3C28
                    exp := x"5A3C3C28";
                    if m_tdata /= exp then
                        report "TB: OC0 MISMATCH at word " & integer'image(drain_words) &
                               " got=0x" & to_hstring(m_tdata) &
                               " exp=0x5A3C3C28"
                               severity error;
                        test_pass <= false;
                        any_fail := true;
                    else
                        report "TB: oc=0 word OK (0x5A3C3C28) = (40,60,60,90)" severity note;
                    end if;
                elsif drain_words > OUT_WORD_BASE and drain_words < OUT_WORD_BASE + 32 then
                    -- oc=1..31: expect 0
                    if m_tdata /= x"00000000" then
                        report "TB: oc=" & integer'image(drain_words - OUT_WORD_BASE) &
                               " NON-ZERO at word " & integer'image(drain_words) &
                               " got=0x" & to_hstring(m_tdata)
                               severity error;
                        test_pass <= false;
                        any_fail := true;
                    end if;
                end if;

                drain_words := drain_words + 1;

                if m_tlast = '1' then
                    report "TB: Drain complete, total words = " &
                           integer'image(drain_words) severity note;
                    exit;
                end if;
            end if;
        end loop;
        m_tready <= '0';

        wait for CLK_PERIOD * 10;

        if tkeep_ok then
            report "TB: tkeep check OK -- always '1111' while tvalid='1'" severity note;
        else
            report "TB: tkeep check FAILED" severity error;
            test_pass <= false;
            any_fail := true;
        end if;

        -- Give the delta cycle for test_pass update above to take effect
        wait for CLK_PERIOD;

        if test_pass and not any_fail then
            report "TB: ========== ALL TESTS PASSED ==========" severity note;
        else
            report "TB: ========== SOME TESTS FAILED ==========" severity error;
        end if;

        -- End simulation cleanly
        assert false report "TB: Simulation complete" severity failure;
        wait;
    end process;

end architecture sim;
