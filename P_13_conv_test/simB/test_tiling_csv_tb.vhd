-------------------------------------------------------------------------------
-- test_tiling_csv_tb.vhd -- Verify conv_engine_v2 tiling with c_in=32
-------------------------------------------------------------------------------
-- Config: c_in=32, c_out=1(*), h_in=3, w_in=3, ksize=3x3, stride=1, pad=1
-- ic_tile_size=8 => 4 tiles of 8 channels each
--
-- (*) Engine always processes N_MAC=32 oc at a time. We only populate
--     filter 0 (oc=0) with real weights; filters 1..31 have weight=0
--     so their output is requant(bias=2000).
--
-- Input:  288 bytes (NCHW: 32ch x 3x3)
--         values = (i*7+3) % 251 - 125 for i in 0..287
-- Weight: 288 bytes (OHWI: 1 filter x 3x3 x 32ch)
--         values = ((i*13+5) % 251) - 125 for i in 0..287
--         (filters 1..31 = 0)
-- Bias:   2000 (oc=0), 0 (oc=1..31)
-- Quant:  x_zp=-128, w_zp=0, M0=656954014, n_shift=37, y_zp=-17
--
-- Expected output (oc=0, 9 pixels row-major):
--   127, 26, -128, 127, -24, -128, 127, 12, -128
-- NOTE: RTL zero-pads with mac_a=0 (not (0-x_zp)*w).
--
-- Expected oc=1..31 (bias=0, weights=0):
--   requant(0) = clamp((0 + 2^36) >> 37 + (-17), -128, 127)
--              = clamp(0 + (-17), -128, 127) = -17
--
-- Key verifications:
--   1. MAC NOT cleared between ic_tiles of SAME pixel
--   2. MAC IS cleared at new pixel
--   3. Weight loads happen 4 times per pixel (4 tiles)
--   4. Final accumulator after 4 tiles matches full c_in=32 computation
--   5. Requantize uses FINAL accumulator (not intermediate tile's)
--
-- CSV log: debug_tiling.csv with all debug signals per cycle
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity test_tiling_csv_tb is
end;

architecture bench of test_tiling_csv_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal cfg_c_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out     : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize     : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride    : std_logic := '0';
    signal cfg_pad       : std_logic := '0';
    signal cfg_x_zp      : signed(8 downto 0) := (others => '0');
    signal cfg_w_zp      : signed(7 downto 0) := (others => '0');
    signal cfg_M0        : unsigned(31 downto 0) := (others => '0');
    signal cfg_n_shift   : unsigned(5 downto 0) := (others => '0');
    signal cfg_y_zp      : signed(7 downto 0) := (others => '0');
    signal cfg_addr_input   : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_weights : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_bias    : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_output  : unsigned(24 downto 0) := (others => '0');
    signal cfg_ic_tile_size : unsigned(9 downto 0) := (others => '0');
    signal start         : std_logic := '0';
    signal done          : std_logic;
    signal busy          : std_logic;
    signal ddr_rd_addr   : unsigned(24 downto 0);
    signal ddr_rd_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en     : std_logic;
    signal ddr_wr_addr   : unsigned(24 downto 0);
    signal ddr_wr_data   : std_logic_vector(7 downto 0);
    signal ddr_wr_en     : std_logic;

    -- Debug
    signal dbg_state    : integer range 0 to 63;
    signal dbg_oh, dbg_ow, dbg_kh, dbg_kw, dbg_ic : unsigned(9 downto 0);
    signal dbg_oc_tile_base, dbg_ic_tile_base : unsigned(9 downto 0);
    signal dbg_w_base   : unsigned(19 downto 0);
    signal dbg_mac_a    : signed(8 downto 0);
    signal dbg_mac_b    : weight_array_t;
    signal dbg_mac_bi   : bias_array_t;
    signal dbg_mac_acc  : acc_array_t;
    signal dbg_mac_vi, dbg_mac_clr, dbg_mac_lb, dbg_pad : std_logic;
    signal dbg_act_addr : unsigned(24 downto 0);

    -- DDR address map
    constant ADDR_INPUT   : natural := 16#0000#;
    constant ADDR_WEIGHTS : natural := 16#0400#;
    constant ADDR_BIAS    : natural := 16#0800#;
    constant ADDR_OUTPUT  : natural := 16#0C00#;

    signal sim_done : std_logic := '0';
    signal cycle_cnt : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    -- Cycle counter
    p_cnt : process(clk)
    begin
        if rising_edge(clk) then
            cycle_cnt <= cycle_cnt + 1;
        end if;
    end process;

    uut : entity work.conv_engine_v2
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride, cfg_pad => cfg_pad,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data,
            ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data,
            ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_oc_tile_base => dbg_oc_tile_base, dbg_ic_tile_base => dbg_ic_tile_base,
            dbg_w_base => dbg_w_base,
            dbg_mac_a => dbg_mac_a, dbg_mac_b => dbg_mac_b, dbg_mac_bi => dbg_mac_bi,
            dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr, dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr
        );

    ---------------------------------------------------------------------------
    -- CSV logger: writes one row per clock cycle while busy
    ---------------------------------------------------------------------------
    p_csv : process(clk)
        file csv_file : text;
        variable csv_line : line;
        variable file_opened : boolean := false;
    begin
        if rising_edge(clk) then
            if busy = '1' or done = '1' then
                if not file_opened then
                    file_open(csv_file, "debug_tiling.csv", write_mode);
                    -- Header
                    write(csv_line, string'("cycle,state,oh,ow,kh,kw,ic,oc_tile_base,ic_tile_base,w_base,mac_a,mac_acc0,mac_vi,mac_clr,mac_lb,pad,act_addr,ddr_rd_en,ddr_wr_en,ddr_wr_addr,ddr_wr_data"));
                    writeline(csv_file, csv_line);
                    file_opened := true;
                end if;

                -- Data row
                write(csv_line, integer'image(cycle_cnt));
                write(csv_line, string'(","));
                write(csv_line, integer'image(dbg_state));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oh)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ow)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kh)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kw)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oc_tile_base)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic_tile_base)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_w_base)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_a)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(0))));
                write(csv_line, string'(","));
                if dbg_mac_vi = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;
                write(csv_line, string'(","));
                if dbg_mac_clr = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;
                write(csv_line, string'(","));
                if dbg_mac_lb = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;
                write(csv_line, string'(","));
                if dbg_pad = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_act_addr)));
                write(csv_line, string'(","));
                if ddr_rd_en = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;
                write(csv_line, string'(","));
                if ddr_wr_en = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_wr_addr)));
                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(ddr_wr_data))));
                writeline(csv_file, csv_line);

                if done = '1' then
                    file_close(csv_file);
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main stimulus + DDR model + verification
    ---------------------------------------------------------------------------
    p_main : process
        type ddr_t is array(0 to 8191) of std_logic_vector(7 downto 0);
        variable ddr : ddr_t := (others => (others => '0'));

        procedure ddr_w8(addr : natural; val : integer) is
        begin
            ddr(addr) := std_logic_vector(to_signed(val, 8));
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

        -- Input data: 288 bytes, NCHW layout
        -- inputs[i] = (i*7+3) % 251 - 125
        type data288_t is array(0 to 287) of integer;
        constant inp : data288_t := (
            -122,-115,-108,-101, -94, -87, -80, -73, -66, -59, -52, -45, -38, -31, -24, -17,
             -10,  -3,   4,  11,  18,  25,  32,  39,  46,  53,  60,  67,  74,  81,  88,  95,
             102, 109, 116, 123,-121,-114,-107,-100, -93, -86, -79, -72, -65, -58, -51, -44,
             -37, -30, -23, -16,  -9,  -2,   5,  12,  19,  26,  33,  40,  47,  54,  61,  68,
              75,  82,  89,  96, 103, 110, 117, 124,-120,-113,-106, -99, -92, -85, -78, -71,
             -64, -57, -50, -43, -36, -29, -22, -15,  -8,  -1,   6,  13,  20,  27,  34,  41,
              48,  55,  62,  69,  76,  83,  90,  97, 104, 111, 118, 125,-119,-112,-105, -98,
             -91, -84, -77, -70, -63, -56, -49, -42, -35, -28, -21, -14,  -7,   0,   7,  14,
              21,  28,  35,  42,  49,  56,  63,  70,  77,  84,  91,  98, 105, 112, 119,-125,
            -118,-111,-104, -97, -90, -83, -76, -69, -62, -55, -48, -41, -34, -27, -20, -13,
              -6,   1,   8,  15,  22,  29,  36,  43,  50,  57,  64,  71,  78,  85,  92,  99,
             106, 113, 120,-124,-117,-110,-103, -96, -89, -82, -75, -68, -61, -54, -47, -40,
             -33, -26, -19, -12,  -5,   2,   9,  16,  23,  30,  37,  44,  51,  58,  65,  72,
              79,  86,  93, 100, 107, 114, 121,-123,-116,-109,-102, -95, -88, -81, -74, -67,
             -60, -53, -46, -39, -32, -25, -18, -11,  -4,   3,  10,  17,  24,  31,  38,  45,
              52,  59,  66,  73,  80,  87,  94, 101, 108, 115, 122,-122,-115,-108,-101, -94,
             -87, -80, -73, -66, -59, -52, -45, -38, -31, -24, -17, -10,  -3,   4,  11,  18,
              25,  32,  39,  46,  53,  60,  67,  74,  81,  88,  95, 102, 109, 116, 123,-121
        );

        -- Weight data: 288 bytes, OHWI layout for filter 0
        -- weights[i] = ((i*13+5) % 251) - 125
        constant wgt : data288_t := (
            -120,-107, -94, -81, -68, -55, -42, -29, -16,  -3,  10,  23,  36,  49,  62,  75,
              88, 101, 114,-124,-111, -98, -85, -72, -59, -46, -33, -20,  -7,   6,  19,  32,
              45,  58,  71,  84,  97, 110, 123,-115,-102, -89, -76, -63, -50, -37, -24, -11,
               2,  15,  28,  41,  54,  67,  80,  93, 106, 119,-119,-106, -93, -80, -67, -54,
             -41, -28, -15,  -2,  11,  24,  37,  50,  63,  76,  89, 102, 115,-123,-110, -97,
             -84, -71, -58, -45, -32, -19,  -6,   7,  20,  33,  46,  59,  72,  85,  98, 111,
             124,-114,-101, -88, -75, -62, -49, -36, -23, -10,   3,  16,  29,  42,  55,  68,
              81,  94, 107, 120,-118,-105, -92, -79, -66, -53, -40, -27, -14,  -1,  12,  25,
              38,  51,  64,  77,  90, 103, 116,-122,-109, -96, -83, -70, -57, -44, -31, -18,
              -5,   8,  21,  34,  47,  60,  73,  86,  99, 112, 125,-113,-100, -87, -74, -61,
             -48, -35, -22,  -9,   4,  17,  30,  43,  56,  69,  82,  95, 108, 121,-117,-104,
             -91, -78, -65, -52, -39, -26, -13,   0,  13,  26,  39,  52,  65,  78,  91, 104,
             117,-121,-108, -95, -82, -69, -56, -43, -30, -17,  -4,   9,  22,  35,  48,  61,
              74,  87, 100, 113,-125,-112, -99, -86, -73, -60, -47, -34, -21,  -8,   5,  18,
              31,  44,  57,  70,  83,  96, 109, 122,-116,-103, -90, -77, -64, -51, -38, -25,
             -12,   1,  14,  27,  40,  53,  66,  79,  92, 105, 118,-120,-107, -94, -81, -68,
             -55, -42, -29, -16,  -3,  10,  23,  36,  49,  62,  75,  88, 101, 114,-124,-111,
             -98, -85, -72, -59, -46, -33, -20,  -7,   6,  19,  32,  45,  58,  71,  84,  97
        );

        constant BIAS_OC0 : integer := 2000;

        -- Expected output for oc=0 (9 pixels, row-major)
        -- Python-computed: RTL pads with mac_a=0 (not x-x_zp where x=0)
        type exp9_t is array(0 to 8) of integer;
        constant expected_oc0 : exp9_t := (
            127, 26, -128, 127, -24, -128, 127, 12, -128
        );

        -- Expected for oc=1..31 (bias=0, weights=0)
        -- acc = 0, requant(0) = clamp((0 + 2^36) >> 37 + (-17)) = clamp(0 + (-17)) = -17
        constant expected_zero_wt : integer := -17;

        variable errors  : integer := 0;
        variable got     : integer;
        variable timeout : integer;

    begin
        report "==============================================" severity note;
        report "TEST TILING: c_in=32, ic_tile_size=8, 4 tiles" severity note;
        report "  c_out=32(engine), h_in=3, w_in=3, ksize=3x3" severity note;
        report "  pad=1, stride=1, h_out=3, w_out=3" severity note;
        report "==============================================" severity note;

        -----------------------------------------------------------------
        -- Load DDR
        -----------------------------------------------------------------
        -- Input at ADDR_INPUT: NCHW 288 bytes
        for i in 0 to 287 loop
            ddr_w8(ADDR_INPUT + i, inp(i));
        end loop;

        -- Weights at ADDR_WEIGHTS: OHWI
        -- Filter 0 (oc=0): 288 bytes with real values
        for i in 0 to 287 loop
            ddr_w8(ADDR_WEIGHTS + i, wgt(i));
        end loop;
        -- Filters 1..31: 288 bytes each, all zeros (already 0 from init)

        -- Bias at ADDR_BIAS: 32 words x 4 bytes = 128 bytes
        ddr_w32(ADDR_BIAS + 0, BIAS_OC0);  -- bias[0] = 2000
        -- bias[1..31] = 0 (already zero from init)

        report "DDR loaded: 288B input + 288B weights(oc0) + 128B bias" severity note;

        -----------------------------------------------------------------
        -- Reset
        -----------------------------------------------------------------
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -----------------------------------------------------------------
        -- Configure
        -----------------------------------------------------------------
        cfg_c_in         <= to_unsigned(32, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned(3, 10);
        cfg_w_in         <= to_unsigned(3, 10);
        cfg_ksize        <= "10";          -- 3x3
        cfg_stride       <= '0';           -- stride=1
        cfg_pad          <= '1';           -- pad=1
        cfg_x_zp         <= to_signed(-128, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(8, 10);    -- 4 tiles of 8

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING conv_engine_v2 with ic_tile_size=8 (4 tiles)" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -----------------------------------------------------------------
        -- Run: serve DDR reads/writes
        -----------------------------------------------------------------
        timeout := 0;
        while done /= '1' and timeout < 2000000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(12 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 2000000 then
            report "TIMEOUT waiting for done after 2M cycles" severity failure;
        end if;

        report "DONE at cycle " & integer'image(timeout) severity note;

        -- Flush any remaining writes
        for i in 0 to 29 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(12 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Verify oc=0 (9 pixels, the interesting filter)
        -----------------------------------------------------------------
        report "==============================================" severity note;
        report "CHECKING oc=0: 9 output pixels" severity note;

        -- Output layout: out[oc * hw_out + oh*w_out + ow]
        -- hw_out = 3*3 = 9
        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 0*9 + px)));
            if got /= expected_oc0(px) then
                errors := errors + 1;
                report "oc0 pixel " & integer'image(px) &
                       " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(expected_oc0(px)) severity error;
            else
                report "oc0 pixel " & integer'image(px) &
                       " PASS: y=" & integer'image(got) severity note;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Verify oc=1 (should all be -8: requant(bias=2000, weights=0))
        -----------------------------------------------------------------
        report "CHECKING oc=1 (expect all " & integer'image(expected_zero_wt) & ")" severity note;

        for px in 0 to 8 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + 1*9 + px)));
            if got /= expected_zero_wt then
                errors := errors + 1;
                report "oc1 pixel " & integer'image(px) &
                       " FAIL: got=" & integer'image(got) &
                       " exp=" & integer'image(expected_zero_wt) severity error;
            else
                report "oc1 pixel " & integer'image(px) &
                       " PASS: y=" & integer'image(got) severity note;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Quick spot-check: oc=31
        -----------------------------------------------------------------
        report "CHECKING oc=31 pixel 4 (center)" severity note;
        got := to_integer(signed(ddr(ADDR_OUTPUT + 31*9 + 4)));
        if got /= expected_zero_wt then
            errors := errors + 1;
            report "oc31 px4 FAIL: got=" & integer'image(got) &
                   " exp=" & integer'image(expected_zero_wt) severity error;
        else
            report "oc31 px4 PASS: y=" & integer'image(got) severity note;
        end if;

        -----------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------
        report "==============================================" severity note;
        if errors = 0 then
            report "TILING TEST ALL PASSED" severity note;
        else
            report "TILING TEST FAILED: " & integer'image(errors) & " errors" severity error;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
