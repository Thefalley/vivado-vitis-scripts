-------------------------------------------------------------------------------
-- test_ic_tiling_tb.vhd -- IC tiling test with REAL ONNX weights
-------------------------------------------------------------------------------
-- Layer 002 from yolov4_int8_qop.onnx: conv2d_3/Conv2D_quant
-- 1x1 conv, c_in=64, c_out=64 (testing first 32x32 subset)
--
-- Config: c_in=32, c_out=32, h_in=3, w_in=3, ksize=1x1, stride=1, pad=0
-- ic_tile_size=8 => 4 tiles of 8 channels each
--
-- ALL 32 output channels have REAL weights from the ONNX model.
-- Input: deterministic synthetic (same formula as gen_layer_tests.py)
-- Expected output: Python-computed, HW-exact integer arithmetic
--
-- Quant params (from ONNX):
--   x_zp=-97, w_zp=0, y_zp=7
--   x_scale=0.11783, w_scale=0.006049, y_scale=0.15697
--   M0=1248165501, n_shift=38
--
-- Memory layout:
--   Input:   0x000-0x11F (288 B)
--   Weights: 0x120-0x51F (1024 B) OHWI
--   Bias:    0x520-0x59F (128 B)
--   Output:  0x5A0-0x6BF (288 B)
--   Total:   1728 B
--
-- Key verification:
--   1. IC tiling with REAL weights (not synthetic, not zero)
--   2. All 32 OC channels have nonzero weights -> meaningful accumulation
--   3. 4 tile passes per pixel, accumulator preserved across tiles
--   4. 288 output bytes checked bit-exact
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity test_ic_tiling_tb is
end;

architecture bench of test_ic_tiling_tb is
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
    constant ADDR_WEIGHTS : natural := 16#0120#;
    constant ADDR_BIAS    : natural := 16#0520#;
    constant ADDR_OUTPUT  : natural := 16#05A0#;

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

        -- Input data: 288 bytes, NCHW layout (32ch x 3x3)
        -- Generated with: val = ((c*37 + r*17 + col*7 + c*r*3) % 256) - 128
        type data288_t is array(0 to 287) of integer;
        constant inp : data288_t := (
            -128,-121,-114,-111,-104, -97, -94, -87, -80, -91, -84, -77, -71, -64, -57, -51,
             -44, -37, -54, -47, -40, -31, -24, -17,  -8,  -1,   6, -17, -10,  -3,   9,  16,
              23,  35,  42,  49,  20,  27,  34,  49,  56,  63,  78,  85,  92,  57,  64,  71,
              89,  96, 103, 121,-128,-121,  94, 101, 108,-127,-120,-113, -92, -85, -78,-125,
            -118,-111, -87, -80, -73, -49, -42, -35, -88, -81, -74, -47, -40, -33,  -6,   1,
               8, -51, -44, -37,  -7,   0,   7,  37,  44,  51, -14,  -7,   0,  33,  40,  47,
              80,  87,  94,  23,  30,  37,  73,  80,  87, 123,-126,-119,  60,  67,  74, 113,
             120, 127, -90, -83, -76,  97, 104, 111,-103, -96, -89, -47, -40, -33,-122,-115,
            -108, -63, -56, -49,  -4,   3,  10, -85, -78, -71, -23, -16,  -9,  39,  46,  53,
             -48, -41, -34,  17,  24,  31,  82,  89,  96, -11,  -4,   3,  57,  64,  71, 125,
            -124,-117,  26,  33,  40,  97, 104, 111, -88, -81, -74,  63,  70,  77,-119,-112,
            -105, -45, -38, -31, 100, 107, 114, -79, -72, -65,  -2,   5,  12,-119,-112,-105,
             -39, -32, -25,  41,  48,  55, -82, -75, -68,   1,   8,  15,  84,  91,  98, -45,
             -38, -31,  41,  48,  55, 127,-122,-115,  -8,  -1,   6,  81,  88,  95, -86, -79,
             -72,  29,  36,  43, 121,-128,-121, -43, -36, -29,  66,  73,  80, -95, -88, -81,
               0,   7,  14, 103, 110, 117, -55, -48, -41,  43,  50,  57,-116,-109,-102, -15,
              -8,  -1,  86,  93, 100, -79, -72, -65,  25,  32,  39,-127,-120,-113, -42, -35,
             -28,  65,  72,  79, -84, -77, -70,  -5,   2,   9, 105, 112, 119, -41, -34, -27
        );

        -- Weight data: 1024 bytes, OHWI layout (32 filters x 1x1 x 32 channels)
        -- Real weights from ONNX layer_002 (conv2d_3/Conv2D_quant)
        type data1024_t is array(0 to 1023) of integer;
        constant wgt : data1024_t := (
              -7,   8,  16,  -5,  -6,   1,   1,   3,  -6,   6,  10,   0,  -6,  35,   8,   3,
              -4,  35,  -5,  -4, -69,  15,  -4,   3,   7,  -7,  -5,   5,   6,   4,  -6,  -2,
              15, -47,  10,   4, -24,  -9, -47,   1,   4, -12,  -9, -23, -14, -23,  -4, -21,
             -12,   1,   0, -15, -16,  -4,  -8,  -9, -16,   8, -34,  14,   2, -23, -23,  -4,
              -4, -20,  -4,  -1,   2, -19,  35,   2,   0,   4,  -8, -12,  -1,   3,  10,  -9,
              -3, -17,  -8,   0,  -5,  -1,  29, -17,  -2,  -1, -36,   3, -15, -12, -10, -13,
              60,   9,  -5, -20,   4,   0,   2, -26,  -8,  -5,   6,  -1,  -1, -11,   4,  -5,
             -11,   2,  -2,  -1,  10, -50,  -3,   5, -10,  -3,   0,  11,   4,  -4,  -9,   3,
              19, -10,   3,  -6,  -5,  -3,   3,  -1,  -6,  14,  -2,  11,  -3, -85,  11,   1,
               7,  16,   1,   3,  45, -19,  -4,  14,  -6,  -1,   0,   2,   7,   2,   5, -12,
              -7, -10, -31, -30,   2,  -2,  -2,   6,  31,   7,  -7,   8,  10,   6,  -2,   1,
              11,  11,   0,   8,   7,   4,   0,  13,   7,   2,   2,   0,   5, -18,   4, -26,
              -7,  -1,   8, -24,   2,   5,   0, -11,  -2,   7,   1,   0, -11,  15,  -6,  -2,
              13,  -5,   4,   5, -19,  -2,   0,  -1, -72,  15,   3,   4,   9,   3,   5,  11,
               9,   9,  17,  87,  -2,   7,   0,  16, -10, -12,  -2,   8,   5,   1,   3,   3,
               8,   6,  -7,  14, -33,   6,   2,  -4, -75,  16,   1,  -1,   4,  -3,  -5,  12,
             -16, -18,  -7,  -4,  -3, -26,  -5,  -1,  -5, -11, -20, -29,  -7,  -1,  13, -17,
              -5,  -1,  57, -10,   5,  -4,   8,  -2,  -4,   0,  -1,   5, -33, -14,  -3,   3,
               3,   4,   9,   0,  -3,   8,  18,   0,  20,   7,   3,  26,  10,   1, -13, -16,
               7,  -1,   0,  -3,  -1,   0, -45,  23,   0,  -6,  13,   2,  -8,  42,  -1,  34,
              -4,   3,  -7,  -4,   0,  -4,   0,  -1, -17,   4, -11,  -3,   2,   0,  -5,  -7,
               1, -11,  -2,   3,   2,   3,  -7,  -4,   2,   1,  -7,   5,  -4,  -5,   2,  -2,
              -6,  -2, -10,   6,  -2,  -5,   3,  13,  19,  12,  -6, -10,   3,  20,   5,  -4,
               1,  -6,   8,  10, -26,   8,  -6,  15,  25,   1,   1,  -1,  -1,  -6,   2, -13,
               6,  23,  -7,   2,   7, -27,  -4, -18,   3,  -5,   3,  -3,  -3,   7, -16,   0,
              -2,  -1, -25, -16,  -4, -18,   3,  -5,  -2, -11,  -3,  -4, -13,  -6,  59,   0,
              -9,   1,  -6,  -1, -11, -15,  -6, -17,   5,  13,   1,  -1,   4, -10,  -9,  12,
              82,  -8, -11,  18,  -2, -14,  -7, -14,   1,  55,  -7,  39, -16,  10, -10,   3,
             -13,   5,   6,  21,  -2,  -7,   3,  15,  -7,   0,   0,  -4,   3,  41,  -5,  -2,
              -6,   3,   2,  -1, -23,  -1,  -3,  -8, -27,  14,  -1,  -2,   2,   4,  -5,  -4,
              -6,  -8,  -3,-108,  -8,   2,  -2,   0,  11,  -6,   1,  -4, -18, -16,   2,   6,
               4,  -1,   8,   6,  16, -13,  -7,   8,  92, -17,  -5,  18,  12,   0,   4,  -2,
              -7,   9, -11,  11,  12,   1,  -2,   1, -34,  -7,  -4,   6,  10,  -6,   9,   3,
              -9,  30,   3,   7,  -5,  11,  10,  25,   4,  14,   6,  -3,   3,  -8,  -4,  -5,
             -28,  -2, -18,  11, -14, -17,  -1,   1,   4,  -3,  -9, -11,  -6, -10,   8,  -2,
              20,   2,  -6,   0,   8,  25,   0,  -3,   4, -17,  -4, -16, -19,  -5,  10,   6,
             -18,  -4,   5,  33, -13,  -4,   4,  -3, -15,   6,   9,   9,   2,  -8,  -5,  -9,
               5,  12,  -9,  -2,  17,   1,  14,   7,   2,   4,   9,  -1,  -3,  -3,   0,   7,
             -54, -10,  -1, -11, -11,   4,   4,  11,   5,   2,  -1,  -6,   9,  19,   5,   3,
              18,   4,   6,   8, -46,  44,  -1,  -5, -21,   1,   2, -14,   5,   3,  15, -13,
             -18, -29,  19, -12, -22, -65,   6, -17,  31,  24, -41, -15,  -8,  13,  18,  52,
               3,  -7, -11,  -6,  -9,   2,  -9,   1,  -9,  -1,   8, -22, -69, -38,  -1, -42,
              -7,   9,  22,  -2, -15,  -3,   7,  14, -65,   1,   1,   7, -11,   1,  -2,   7,
              -6,   0,   0,   0,  10,  11,  -8,  -6,   9,   6,  10,  -2,  11,   2,   1,  12,
               1,  -3, -10,  11,  22,  -7,   3,  -4,   3,   4,   6,  -4,  -3, -31,   1,   4,
             -10,   5,  -3,  -4,  21, -21,   8,  11,   7,  -7,   2,  -2,  -5,   3,  -4,  -7,
               5,   4,  14, -45, -25,  -8,   8,  13, -11,   5,  -2,  -8,  -3,  -9,  -6,  20,
             -10,  10,   5,  -9,  -8,  -1,  -3,  12, -19,  25,   6,   5,   6,   7,   6,  23,
              12, -18,   2,  28,   3,   5,  -3,  -1,   3,   5,   0,   0,   3,  -4,   5,   1,
              -2,   5,  -4,  -6,  -4, -24,   9, -16,  96,   1,  -3, -12,   5,   4,  -2,   5,
             -17,  -2,  -9,  37,   5, -13,   5,   8,   8,   4,   8,   5,  -6, -32, -11,  -5,
              -9,  -3,   4,  -4,  16,  10,  -4,  -5,  16,  -5,  -1,  -3,  -2,  -3,  -2, -11,
             -32, -21, -24,   6,  13, -16, -12,  -3,  -9,  30,  13,   2,   0,   7,  22,  -3,
              29,   5,  -3,  -8,   2, -15, -20,  11,  -3, -44, -15,   0, -11,   3,  -1,   0,
               9,  28,  -1,   3,   9,   9,   1,   4,  -3,   2, -10,  13,  -1,   0, -12,   5,
               9,   0,  -9,   5,  10,  -1,  -8,   3,   0,  -7,  -1, -21,  -7,  -1,   1,   0,
              30,  -8,   6, -21,  -3,   2,   2,   4,  -5,  -2,  -3,  -9,  -1,  50,   1,   5,
              13, -10,  13,   6,  -7, -13,  -1,   1,  10,   8,   4,  -5,   0,  -2,   0,   8,
             -11,   3,  -9,   5, -11, -19, -21, -18,  -4, -10, -19, -22,  -9,  13,  -8, -43,
              -2,  -2,  -5, -19, -28, -19, -10, -23,  -2,  12, -36,  -3,  -2, -41, -16, -14,
              36,   0, -24,  -1,  10,   1, -15,  -6,  17,  -5,  16, -23,  -4,  -8,   5,  -2,
              -2, -32,  -3,  -9,   3,   5, -19, -48,   5,  25,   8,   5, -28,  -4,   7,  -7,
             -10,  -7,  25,  -6,   8,  -2,   1,  -6, -19, -11,   5,  15, -20, -26,   1,   0,
              22,  16,  -4,  14,  36,  13, -11, -10, -10,   8,   1,  10,  13,  -2,   2,  20
        );

        -- Bias: 32 values, int32 (from ONNX)
        type bias32_t is array(0 to 31) of integer;
        constant bias_vals : bias32_t := (
            3834, 5385, 623, -458, 773, 3576, 1395, 1504,
            571, -833, -1907, -386, -50, -825, 1551, 1404,
            6400, 2318, -50, 4258, 1251, 950, 870, -2168,
            1505, -617, 2808, 176, 308, 4195, -1656, 1584
        );

        -- Expected output: 288 bytes (32ch x 3x3), NCHW
        -- Python-computed with HW-exact integer arithmetic
        constant expected : data288_t := (
              -3,  -2,  -1,  42,  51,  52,  62,  18,  19,-128,-128,-128, -85,-106,-116, -97,
             -61, -72, -33, -37, -41, -81, -84, -88, -74,  -3,  -7,  -1,  -3,  -5, -41, -39,
             -41, -37, -46, -48, -16, -16, -16,  25,  26,  26,  45,   1,   1,  36,  37,  37,
              21,  19,  20,  55,  20,  21,   1,   0,  -2, -20, -39, -41,  20,  20,  18,  16,
              18,  21,  31,  15,  17,  91,  74,  77, -17, -22, -27, -41, -46, -51,-111, -48,
             -53,  77,  81,  85,  83,  94,  98,  31, -29, -25, -13, -16, -18, -36, -39, -42,
             -53, -29, -32,  11,  13,  14,  16,  16,  17,   5,  13,  15, -33, -35, -38, -25,
             -15, -17, -59, -20, -22,  63,  65,  68,  62,   0,   2,  38,  84,  86,  25,  25,
              25,  -4, -21, -21,   1,  19,  19,   6,   5,   4,  14,  33,  31, -36, -43, -44,
              69,  71,  74,  99,  85,  87, 109,  39,  42, -36, -39, -42, -25,  -9, -11, -25,
               6,   3,  49,  50,  52,  46,  43,  45,  63,  37,  38,  -5,  -6,  -7,  30,  28,
              28,  34,  37,  36,-101,-110,-119,-128,-128,-128,-128, -55, -64,  27,  28,  28,
              12,   5,   6,   5,   7,   8,   9,   8,   8,  15,  22,  22,  24,  18,  17, -23,
             -23, -23,   6, -23, -23, -25, -31, -31,  42,  45,  48, 109, 111, 113,  18,  28,
              31,  -6,  -7,  -8,   6,  11,  10,   4,  22,  21,  -9, -12, -15,  -5,  43,  40,
              24,  19,  16,  11,  12,  13,  10,  19,  20,  22,  -6,  -5,  51,  54,  56,  14,
               7,   9,  -8,  13,  16,-109,-121,-128,-122,-128,-128,-128, -94,-106, -38, -41,
             -44, -57, -90, -93,-117,  -2,  -5,  57,  59,  61,  47,  40,  42,  87,  67,  69
        );

        variable errors  : integer := 0;
        variable got     : integer;
        variable exp     : integer;
        variable timeout : integer;

    begin
        report "===========================================================" severity note;
        report "IC TILING TEST: REAL ONNX weights (layer_002)" severity note;
        report "  c_in=32, c_out=32, h_in=3, w_in=3, ksize=1x1" severity note;
        report "  ic_tile_size=8 (4 tiles of 8 channels)" severity note;
        report "  x_zp=-97, w_zp=0, y_zp=7, M0=1248165501, n_shift=38" severity note;
        report "  ALL 32 OC channels have REAL nonzero weights" severity note;
        report "  Total checks: 288 output bytes" severity note;
        report "===========================================================" severity note;

        -----------------------------------------------------------------
        -- Load DDR
        -----------------------------------------------------------------
        -- Input at ADDR_INPUT (288 bytes, NCHW)
        for i in 0 to 287 loop
            ddr_w8(ADDR_INPUT + i, inp(i));
        end loop;

        -- Weights at ADDR_WEIGHTS (1024 bytes, OHWI)
        for i in 0 to 1023 loop
            ddr_w8(ADDR_WEIGHTS + i, wgt(i));
        end loop;

        -- Bias at ADDR_BIAS (32 x 4 bytes = 128 bytes)
        for i in 0 to 31 loop
            ddr_w32(ADDR_BIAS + i * 4, bias_vals(i));
        end loop;

        report "DDR loaded: 288B input + 1024B weights + 128B bias" severity note;

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
        cfg_ksize        <= "00";              -- 1x1
        cfg_stride       <= '0';              -- stride=1
        cfg_pad          <= '0';              -- no pad
        cfg_x_zp         <= to_signed(-97, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(1248165501, 32);
        cfg_n_shift      <= to_unsigned(38, 6);
        cfg_y_zp         <= to_signed(7, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(8, 10);    -- 4 tiles of 8

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING conv_engine_v2: 1x1 conv, ic_tile_size=8 (4 tiles)" severity note;
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
        -- Verify ALL 288 output bytes
        -----------------------------------------------------------------
        report "===========================================================" severity note;
        report "VERIFYING 288 output bytes (32 channels x 9 pixels)" severity note;

        for oc in 0 to 31 loop
            for px in 0 to 8 loop
                got := to_integer(signed(ddr(ADDR_OUTPUT + oc * 9 + px)));
                exp := expected(oc * 9 + px);
                if got /= exp then
                    errors := errors + 1;
                    report "oc=" & integer'image(oc) &
                           " px=" & integer'image(px) &
                           " FAIL: got=" & integer'image(got) &
                           " exp=" & integer'image(exp) severity error;
                end if;
            end loop;
        end loop;

        -- Print first pixel of each channel for debug
        report "First pixel of each output channel:" severity note;
        for oc in 0 to 31 loop
            got := to_integer(signed(ddr(ADDR_OUTPUT + oc * 9)));
            exp := expected(oc * 9);
            if got = exp then
                report "  oc " & integer'image(oc) &
                       ": y=" & integer'image(got) & " OK" severity note;
            else
                report "  oc " & integer'image(oc) &
                       ": got=" & integer'image(got) &
                       " exp=" & integer'image(exp) & " FAIL" severity error;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------
        report "===========================================================" severity note;
        if errors = 0 then
            report "IC TILING TEST: ALL 288/288 PASSED -- BIT-EXACT" severity note;
            report "  ic_tile_size=8, 4 tiles, real ONNX weights, 32 OC channels" severity note;
        else
            report "IC TILING TEST FAILED: " & integer'image(errors) &
                   "/288 mismatches" severity error;
        end if;
        report "===========================================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
