-------------------------------------------------------------------------------
-- conv_stream_tb.vhd -- Basic testbench for conv_stream_wrapper
-------------------------------------------------------------------------------
--
-- Test scenario: 1x1 convolution, 1 input channel, 32 output channels,
-- 1x1 spatial, no padding, stride=1.
--
-- BRAM layout (byte-addressed, loaded via AXI-Stream as 32-bit words):
--   addr_input   = 0x000 : 1 byte  = activation (x=10, uint8)
--   addr_weights = 0x004 : 32 bytes = weights (w[0..31], all = 2, int8)
--   addr_bias    = 0x080 : 128 bytes = bias (int32, all = 100)
--   addr_output  = 0x100 : 32 bytes = output (written by conv engine)
--
-- Expected output (per channel):
--   acc = bias + (x - x_zp) * (w - w_zp) = 100 + (10 - 0) * (2 - 0) = 120
--   requantize: y = clamp(round(acc * M0 >> n_shift) + y_zp)
--   With M0=1073741824 (0x40000000), n_shift=30, y_zp=0:
--     y = clamp(round(120 * 1073741824 / 2^30) + 0) = clamp(120) = 120
--
-- Flow: LOAD data -> START conv -> wait DONE -> DRAIN output -> verify
--
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

    -- AXI-Stream Slave (input)
    signal s_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_tlast  : std_logic := '0';
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;

    -- AXI-Stream Master (output)
    signal m_tdata  : std_logic_vector(31 downto 0);
    signal m_tlast  : std_logic;
    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '0';

    -- Procedures
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
        -- Wait for bvalid
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
        -- Wait for rvalid
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

    -- Test data: build the BRAM image as an array of 32-bit words
    -- Total BRAM region used: 0x000 to 0x11F = 288 bytes = 72 words
    -- We'll load 72 words (round up to include output area for drain)
    constant N_LOAD_WORDS  : integer := 96;   -- 384 bytes, covers 0x000..0x17F
    constant N_DRAIN_WORDS : integer := 8;    -- 32 bytes output = 8 words at 0x100

    type word_array_t is array (natural range <>) of std_logic_vector(31 downto 0);

    -- Build the BRAM image
    -- Word address = byte_address / 4
    --
    -- Byte 0x000: activation x = 10 (uint8)
    -- Bytes 0x001..0x003: 0
    -- Word 0 = 0x0000_000A
    --
    -- Bytes 0x004..0x023: 32 weights, all = 2 (int8)
    -- Word 1 = 0x0202_0202  (bytes 4,5,6,7)
    -- ...
    -- Word 8 = 0x0202_0202  (bytes 32,33,34,35)
    --
    -- Bytes 0x080..0x0FF: 32 biases, each int32 LE = 100 = 0x00000064
    -- Word 32 = 0x00000064  (bias[0])
    -- ...
    -- Word 63 = 0x00000064  (bias[31])
    --
    -- Bytes 0x100..0x11F: 32 output bytes (to be written by conv)
    -- Word 64..71: output area (initially zero)

    function build_bram_image return word_array_t is
        variable img : word_array_t(0 to N_LOAD_WORDS-1) := (others => (others => '0'));
    begin
        -- Word 0: activation byte at offset 0 = 10
        img(0) := x"0000000A";

        -- Words 1..8: 32 weight bytes (all = 2), packed 4 per word
        for i in 1 to 8 loop
            img(i) := x"02020202";
        end loop;

        -- Words 9..31: unused (gap between weights end at 0x024 and bias at 0x080)
        -- 0x024/4 = 9, 0x080/4 = 32

        -- Words 32..63: 32 biases, each = 100 = 0x00000064 (little-endian int32)
        for i in 32 to 63 loop
            img(i) := x"00000064";
        end loop;

        -- Words 64..71: output area (zero, will be written by conv)
        -- Already zero from initialization

        return img;
    end function;

    constant BRAM_IMAGE : word_array_t(0 to N_LOAD_WORDS-1) := build_bram_image;

    signal test_pass : boolean := true;
    signal rd_tmp    : std_logic_vector(31 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Clock & reset
    ---------------------------------------------------------------------------
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
            m_axis_tready  => m_tready
        );

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    p_stim : process
        variable v_rd : std_logic_vector(31 downto 0);
        variable drain_words : integer := 0;
        variable expected_byte : integer;
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        report "TB: === Phase 1: Configure registers ===" severity note;

        -- n_words = N_LOAD_WORDS (for LOAD phase)
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#04#, std_logic_vector(to_unsigned(N_LOAD_WORDS, 32)));

        -- c_in = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#08#, x"00000001");
        -- c_out = 32
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#0C#, x"00000020");
        -- h_in = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#10#, x"00000001");
        -- w_in = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#14#, x"00000001");
        -- ksp: ksize=0 (1x1), stride=0, pad=0 => 0x00
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#18#, x"00000000");
        -- x_zp = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#1C#, x"00000000");
        -- w_zp = 0
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#20#, x"00000000");
        -- M0 = 0x40000000 (1073741824 = 1.0 in Q30)
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
                  16#30#, x"00000000");
        -- addr_weights = 0x004
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#34#, x"00000004");
        -- addr_bias = 0x080
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#38#, x"00000080");
        -- addr_output = 0x100
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#3C#, x"00000100");
        -- ic_tile_size = 1
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#40#, x"00000001");

        report "TB: === Phase 2: LOAD data via AXI-Stream ===" severity note;

        -- cmd_load (bit 0 of ctrl)
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#00#, x"00000001");

        -- Send N_LOAD_WORDS beats via s_axis
        -- Present data BEFORE the rising edge, then check handshake.
        -- De-assert tvalid between beats to avoid double-counting.
        for i in 0 to N_LOAD_WORDS - 1 loop
            s_tdata  <= BRAM_IMAGE(i);
            s_tvalid <= '1';
            if i = N_LOAD_WORDS - 1 then
                s_tlast <= '1';
            else
                s_tlast <= '0';
            end if;
            -- Wait for handshake (tvalid AND tready both high at rising edge)
            loop
                wait until rising_edge(clk);
                exit when s_tready = '1';
            end loop;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';

        -- Wait a few cycles for FSM to go back to IDLE
        wait for CLK_PERIOD * 5;

        report "TB: === Phase 3: START conv ===" severity note;

        -- cmd_start (bit 1 of ctrl)
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#00#, x"00000002");

        -- Poll status register until done (bit 8)
        for i in 0 to 50000 loop
            wait for CLK_PERIOD * 10;
            axi_read(clk, araddr, arvalid, rvalid, rdata, rready,
                     16#00#, v_rd);
            if v_rd(8) = '1' then
                report "TB: Conv DONE after polling" severity note;
                exit;
            end if;
            if i = 50000 then
                report "TB: TIMEOUT waiting for conv done!" severity failure;
                test_pass <= false;
            end if;
        end loop;

        report "TB: === Phase 4: DRAIN output via AXI-Stream ===" severity note;

        -- Set n_words for drain = N_DRAIN_WORDS (8 words = 32 bytes)
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#04#, std_logic_vector(to_unsigned(N_DRAIN_WORDS, 32)));

        -- But we need to drain from output address 0x100 = word 64.
        -- The drain always starts from BRAM word 0. So for this test,
        -- we re-load just the output region or accept that drain reads
        -- from word 0.
        --
        -- Actually, the drain reads from BRAM word 0 sequentially.
        -- For a proper test, we'd want to drain from the output region.
        -- But the conv engine wrote output at byte 0x100 = word 64.
        -- The simplest approach: drain ALL 96 words and check words 64..71.
        --
        -- Let's drain 96 words and verify the output portion.
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#04#, std_logic_vector(to_unsigned(N_LOAD_WORDS, 32)));

        -- cmd_drain (bit 2 of ctrl)
        axi_write(clk, awaddr, awvalid, wdata, wvalid, bvalid, bready,
                  16#00#, x"00000004");

        -- Accept m_axis beats
        m_tready <= '1';
        drain_words := 0;
        for i in 0 to N_LOAD_WORDS + 100 loop
            wait until rising_edge(clk);
            if m_tvalid = '1' and m_tready = '1' then
                -- Check output words (BRAM words 64..71 = byte 0x100..0x11F)
                if drain_words >= 64 and drain_words <= 71 then
                    -- Each output word contains 4 output bytes.
                    -- Expected per byte: 120 = 0x78
                    -- So each word should be 0x78787878
                    expected_byte := 120;  -- = 100 + 10*2
                    if m_tdata /= x"78787878" then
                        report "TB: MISMATCH at drain word " &
                               integer'image(drain_words) &
                               " got=" & integer'image(to_integer(unsigned(m_tdata))) &
                               " exp=0x78787878"
                               severity error;
                        test_pass <= false;
                    else
                        report "TB: drain word " & integer'image(drain_words) &
                               " OK (0x78787878)" severity note;
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

        if test_pass then
            report "TB: ========== ALL TESTS PASSED ==========" severity note;
        else
            report "TB: ========== SOME TESTS FAILED ==========" severity error;
        end if;

        -- End simulation
        assert false report "TB: Simulation complete" severity failure;
        wait;
    end process;

end architecture sim;
