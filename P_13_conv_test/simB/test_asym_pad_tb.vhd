-------------------------------------------------------------------------------
-- test_asym_pad_tb.vhd — TB para conv_engine_v3: padding asimetrico + simetrico
-------------------------------------------------------------------------------
-- TEST 1: 3x3 stride=2, pad=[1,0,1,0] (top,bot,left,right), c_in=3, c_out=1
--   h_in=6, w_in=6 -> h_out=3, w_out=3
--   Input: {1,2,...,108}  Weight: all ones  Bias: 1000
--   M0=1, n_shift=5, y_zp=0, x_zp=0
--   Expected RQ outputs: {46,55,56, 59,74,76, 66,84,86}
--
-- TEST 2: 3x3 stride=1, pad=[1,1,1,1], c_in=3, c_out=1
--   h_in=3, w_in=3 -> h_out=3, w_out=3
--   Input: {1,2,...,27}  Weight: all ones  Bias: 500
--   M0=1, n_shift=5, y_zp=0, x_zp=0
--   Expected RQ outputs: {20,23,21, 23,27,24, 21,24,22}
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity test_asym_pad_tb is
end;

architecture bench of test_asym_pad_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk             : std_logic := '0';
    signal rst_n           : std_logic := '0';
    signal cfg_c_in        : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out       : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in        : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in        : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize       : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride      : std_logic := '0';
    signal cfg_pad_top     : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_bottom  : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_left    : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_right   : unsigned(1 downto 0) := (others => '0');
    signal cfg_x_zp        : signed(8 downto 0) := (others => '0');
    signal cfg_w_zp        : signed(7 downto 0) := (others => '0');
    signal cfg_M0          : unsigned(31 downto 0) := (others => '0');
    signal cfg_n_shift     : unsigned(5 downto 0) := (others => '0');
    signal cfg_y_zp        : signed(7 downto 0) := (others => '0');
    signal cfg_addr_input  : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_weights: unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_bias   : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_output : unsigned(24 downto 0) := (others => '0');
    signal cfg_ic_tile_size: unsigned(9 downto 0) := (others => '0');
    signal start           : std_logic := '0';
    signal done            : std_logic;
    signal busy            : std_logic;
    signal ddr_rd_addr     : unsigned(24 downto 0);
    signal ddr_rd_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en       : std_logic;
    signal ddr_wr_addr     : unsigned(24 downto 0);
    signal ddr_wr_data     : std_logic_vector(7 downto 0);
    signal ddr_wr_en       : std_logic;

    constant DDR_SIZE : natural := 8192;

    -- DDR addresses
    constant ADDR_INPUT   : natural := 16#000#;
    constant ADDR_WEIGHTS : natural := 16#200#;
    constant ADDR_BIAS    : natural := 16#400#;
    constant ADDR_OUTPUT  : natural := 16#600#;

begin
    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.conv_engine_v3
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride,
            cfg_pad_top => cfg_pad_top, cfg_pad_bottom => cfg_pad_bottom,
            cfg_pad_left => cfg_pad_left, cfg_pad_right => cfg_pad_right,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data,
            ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data,
            ddr_wr_en => ddr_wr_en
        );

    p_main : process
        type ddr_t is array(0 to DDR_SIZE-1) of std_logic_vector(7 downto 0);
        variable ddr : ddr_t := (others => (others => '0'));

        procedure ddr_w8(addr : natural; val : integer) is
        begin
            ddr(addr) := std_logic_vector(to_signed(val, 8));
        end procedure;

        procedure ddr_w8u(addr : natural; val : natural) is
        begin
            ddr(addr) := std_logic_vector(to_unsigned(val, 8));
        end procedure;

        procedure ddr_w32(addr : natural; val : integer) is
            variable v : std_logic_vector(31 downto 0);
        begin
            v := std_logic_vector(to_signed(val, 32));
            ddr(addr + 0) := v( 7 downto  0);
            ddr(addr + 1) := v(15 downto  8);
            ddr(addr + 2) := v(23 downto 16);
            ddr(addr + 3) := v(31 downto 24);
        end procedure;

        variable timeout   : integer;
        variable got_val   : integer;
        variable pass      : boolean;
        variable all_pass  : boolean;

        -- Expected outputs for test 1 (asymmetric pad [1,0,1,0], stride=2)
        -- 3x3 output stored flat: out[oh*w_out + ow]
        type expected_t is array(0 to 8) of integer;
        constant EXP1 : expected_t := (46, 55, 56, 59, 74, 76, 66, 84, 86);

        -- Expected outputs for test 2 (symmetric pad [1,1,1,1], stride=1)
        constant EXP2 : expected_t := (20, 23, 21, 23, 27, 24, 21, 24, 22);

        procedure run_and_check(
            test_name : string;
            expected  : expected_t;
            n_out     : natural
        ) is
        begin
            -- Start
            report "STARTING " & test_name severity note;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            timeout := 0;
            while done /= '1' and timeout < 200000 loop
                wait until rising_edge(clk);
                timeout := timeout + 1;
                if ddr_rd_en = '1' then
                    ddr_rd_data <= ddr(to_integer(ddr_rd_addr(12 downto 0)));
                end if;
                if ddr_wr_en = '1' then
                    ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
                end if;
            end loop;

            if timeout >= 200000 then
                report test_name & ": TIMEOUT" severity failure;
                return;
            end if;

            report test_name & ": DONE at cycle " & integer'image(timeout) severity note;

            -- Capture any trailing writes
            for i in 0 to 30 loop
                wait until rising_edge(clk);
                if ddr_wr_en = '1' then
                    ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
                end if;
            end loop;

            -- Check outputs
            pass := true;
            for idx in 0 to n_out - 1 loop
                got_val := to_integer(signed(ddr(ADDR_OUTPUT + idx)));
                if got_val /= expected(idx) then
                    report test_name & " MISMATCH at idx=" & integer'image(idx)
                         & " expected=" & integer'image(expected(idx))
                         & " got=" & integer'image(got_val)
                         severity error;
                    pass := false;
                else
                    report test_name & " out[" & integer'image(idx)
                         & "]=" & integer'image(got_val) & " OK"
                         severity note;
                end if;
            end loop;

            if pass then
                report test_name & ": PASS" severity note;
            else
                report test_name & ": FAIL" severity error;
                all_pass := false;
            end if;
        end procedure;

    begin
        all_pass := true;

        -----------------------------------------------------------------------
        -- TEST 1: Asymmetric pad [1,0,1,0], stride=2
        -- c_in=3, c_out=1, h_in=6, w_in=6, 3x3 kernel
        -- h_out = (6+1+0-3)/2+1 = 3, w_out = (6+1+0-3)/2+1 = 3
        -----------------------------------------------------------------------
        report "======= TEST 1: Asymmetric pad [1,0,1,0] stride=2 =======" severity note;

        -- Load input: {1,2,...,108} in layout [c][h][w]
        -- c_in=3, h_in=6, w_in=6  => 108 bytes
        for idx in 0 to 107 loop
            ddr_w8u(ADDR_INPUT + idx, idx + 1);
        end loop;

        -- Load weights: all ones, layout OHWI = [oc=1][kh=3][kw=3][ic=3] = 27 bytes
        for idx in 0 to 26 loop
            ddr_w8(ADDR_WEIGHTS + idx, 1);
        end loop;

        -- Load bias: 1000 (1 filter, 4 bytes LE)
        ddr_w32(ADDR_BIAS + 0, 1000);
        -- Fill remaining bias words for the 32-wide MAC array with 0
        for idx in 1 to 31 loop
            ddr_w32(ADDR_BIAS + idx * 4, 0);
        end loop;

        -- Clear output region
        for idx in 0 to 255 loop
            ddr(ADDR_OUTPUT + idx) := (others => '0');
        end loop;

        -- Reset
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        -- Configure
        cfg_c_in         <= to_unsigned(3, 10);
        cfg_c_out        <= to_unsigned(32, 10);   -- rounded up to N_MAC
        cfg_h_in         <= to_unsigned(6, 10);
        cfg_w_in         <= to_unsigned(6, 10);
        cfg_ksize        <= "10";                  -- 3x3
        cfg_stride       <= '1';                   -- stride=2
        cfg_pad_top      <= to_unsigned(1, 2);
        cfg_pad_bottom   <= to_unsigned(0, 2);
        cfg_pad_left     <= to_unsigned(1, 2);
        cfg_pad_right    <= to_unsigned(0, 2);
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1, 32);
        cfg_n_shift      <= to_unsigned(5, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(3, 10);
        wait until rising_edge(clk);

        run_and_check("TEST1_ASYM_PAD", EXP1, 9);

        -----------------------------------------------------------------------
        -- TEST 2: Symmetric pad [1,1,1,1], stride=1
        -- c_in=3, c_out=1, h_in=3, w_in=3, 3x3 kernel
        -- h_out = (3+1+1-3)/1+1 = 3, w_out = 3
        -----------------------------------------------------------------------
        report "======= TEST 2: Symmetric pad [1,1,1,1] stride=1 =======" severity note;

        -- Load input: {1,2,...,27} in layout [c][h][w]
        for idx in 0 to 26 loop
            ddr_w8u(ADDR_INPUT + idx, idx + 1);
        end loop;

        -- Weights: all ones, layout OHWI = [1][3][3][3] = 27 bytes (same as test 1)
        -- Already loaded, no need to reload

        -- Load bias: 500
        ddr_w32(ADDR_BIAS + 0, 500);

        -- Clear output region
        for idx in 0 to 255 loop
            ddr(ADDR_OUTPUT + idx) := (others => '0');
        end loop;

        -- Reset to re-init the engine
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        -- Configure
        cfg_c_in         <= to_unsigned(3, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "10";                  -- 3x3
        cfg_stride       <= '0';                   -- stride=1
        cfg_pad_top      <= to_unsigned(1, 2);
        cfg_pad_bottom   <= to_unsigned(1, 2);
        cfg_pad_left     <= to_unsigned(1, 2);
        cfg_pad_right    <= to_unsigned(1, 2);
        cfg_x_zp         <= to_signed(0, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1, 32);
        cfg_n_shift      <= to_unsigned(5, 6);
        cfg_y_zp         <= to_signed(0, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(3, 10);
        wait until rising_edge(clk);

        run_and_check("TEST2_SYM_PAD", EXP2, 9);

        -----------------------------------------------------------------------
        -- FINAL VERDICT
        -----------------------------------------------------------------------
        if all_pass then
            report "============ ALL TESTS PASSED ============" severity note;
        else
            report "============ SOME TESTS FAILED ============" severity failure;
        end if;

        wait;
    end process;

end bench;
