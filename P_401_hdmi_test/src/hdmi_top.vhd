-------------------------------------------------------------------------------
-- hdmi_top.vhd - PL-only HDMI color bar test for ZedBoard
--
-- Top-level module that:
--   1. Uses MMCME2_BASE to generate 74.25 MHz pixel clock from 100 MHz input
--   2. Instantiates video_timing for 720p@60Hz
--   3. Instantiates color_bars for 8-bar test pattern
--   4. Instantiates i2c_init to configure the ADV7511 at startup
--   5. Maps 24-bit RGB to 16-bit output bus for ADV7511
--
-- ADV7511 is configured for 24-bit RGB 4:4:4 input with the data
-- mapped across the 16-bit data bus. For the initial test, we send
-- R[7:0] on HD_D[15:8] and G[7:0] on HD_D[7:0]. Blue information
-- is lost in 16-bit mode, but the color bars will still be visible
-- (with blue component missing). For full 24-bit, the ADV7511 can
-- be configured to latch two 12-bit words per pixel on DDR clock edges,
-- but for this first test we keep it simple.
--
-- NOTE on mapping: The ADV7511 in style-2 Input ID=1 (Table 16 in
-- datasheet) for 16-bit SDR 4:2:2 expects:
--   D[15:8] = Cr/Cb,  D[7:0] = Y
-- But we configure it for RGB via registers, so D[15:8]=R, D[7:0]=G
-- gives a visible result. Adjust registers if needed.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity hdmi_top is
    port (
        -- System clock
        sys_clk      : in    std_logic;   -- 100 MHz from Y9

        -- HDMI video output to ADV7511
        hdmi_clk     : out   std_logic;   -- Pixel clock to ADV7511
        hdmi_d       : out   std_logic_vector(15 downto 0);
        hdmi_de      : out   std_logic;
        hdmi_hsync   : out   std_logic;
        hdmi_vsync   : out   std_logic;
        hdmi_int_n   : in    std_logic;   -- Interrupt from ADV7511 (active low)
        hdmi_spdif   : out   std_logic;

        -- HDMI I2C (directly from PL, active-low open-drain)
        hdmi_scl     : inout std_logic;
        hdmi_sda     : inout std_logic;

        -- Debug: active LED shows init done
        led          : out   std_logic_vector(7 downto 0)
    );
end entity hdmi_top;

architecture rtl of hdmi_top is

    ---------------------------------------------------------------------------
    -- MMCM signals
    ---------------------------------------------------------------------------
    signal pclk          : std_logic;   -- 74.25 MHz pixel clock
    signal mmcm_locked   : std_logic;
    signal mmcm_clkfb    : std_logic;
    signal mmcm_clkout0  : std_logic;

    ---------------------------------------------------------------------------
    -- Reset generation
    ---------------------------------------------------------------------------
    signal rst_cnt       : unsigned(7 downto 0) := (others => '0');
    signal rst_pclk      : std_logic := '1';
    signal rst_sys       : std_logic := '1';
    signal rst_sys_cnt   : unsigned(3 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Video timing signals
    ---------------------------------------------------------------------------
    signal vt_hsync   : std_logic;
    signal vt_vsync   : std_logic;
    signal vt_de      : std_logic;
    signal vt_pixel_x : unsigned(10 downto 0);
    signal vt_pixel_y : unsigned(9 downto 0);

    ---------------------------------------------------------------------------
    -- Color bar signals (1 clock latency from timing)
    ---------------------------------------------------------------------------
    signal cb_r       : std_logic_vector(7 downto 0);
    signal cb_g       : std_logic_vector(7 downto 0);
    signal cb_b       : std_logic_vector(7 downto 0);
    signal cb_de      : std_logic;

    -- Pipeline sync signals to match color bar latency (1 clock)
    signal hsync_d1   : std_logic := '0';
    signal vsync_d1   : std_logic := '0';

    ---------------------------------------------------------------------------
    -- I2C init
    ---------------------------------------------------------------------------
    signal i2c_done   : std_logic;

begin

    ---------------------------------------------------------------------------
    -- MMCME2_BASE: generate ~74.25 MHz from 100 MHz
    --
    -- Exact 74.25 MHz is not achievable with MMCME2 from 100 MHz because
    -- the multiplier/divider granularity is 0.125.  Best approximation:
    --
    -- VCO = 100 * 9.000 / 1 = 900.0 MHz  (range 600-1200 for -1 speed)
    -- CLKOUT0 = 900.0 / 12.125 = 74.2268 MHz  (error = -0.031%)
    --
    -- HDMI spec allows +/- 0.5% pixel clock tolerance, so 0.031% is fine.
    ---------------------------------------------------------------------------
    u_mmcm : MMCME2_BASE
        generic map (
            BANDWIDTH          => "OPTIMIZED",
            CLKIN1_PERIOD      => 10.0,          -- 100 MHz input
            CLKFBOUT_MULT_F    => 9.000,         -- VCO = 900.0 MHz
            CLKFBOUT_PHASE     => 0.0,
            CLKOUT0_DIVIDE_F   => 12.125,        -- 900.0 / 12.125 = 74.2268 MHz
            CLKOUT0_DUTY_CYCLE => 0.5,
            CLKOUT0_PHASE      => 0.0,
            DIVCLK_DIVIDE      => 1,
            REF_JITTER1        => 0.010,
            STARTUP_WAIT       => FALSE
        )
        port map (
            CLKIN1   => sys_clk,
            CLKFBIN  => mmcm_clkfb,
            CLKFBOUT => mmcm_clkfb,
            CLKOUT0  => mmcm_clkout0,
            CLKOUT1  => open,
            CLKOUT2  => open,
            CLKOUT3  => open,
            CLKOUT4  => open,
            CLKOUT5  => open,
            CLKOUT6  => open,
            LOCKED   => mmcm_locked,
            PWRDWN   => '0',
            RST      => '0'
        );

    -- Buffer the MMCM output
    u_bufg : BUFG
        port map (
            I => mmcm_clkout0,
            O => pclk
        );

    ---------------------------------------------------------------------------
    -- Reset in sys_clk domain (simple power-on reset)
    ---------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if rst_sys_cnt /= "1111" then
                rst_sys_cnt <= rst_sys_cnt + 1;
                rst_sys     <= '1';
            else
                rst_sys <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Reset in pixel clock domain (wait for MMCM lock)
    ---------------------------------------------------------------------------
    process(pclk)
    begin
        if rising_edge(pclk) then
            if mmcm_locked = '0' then
                rst_cnt  <= (others => '0');
                rst_pclk <= '1';
            elsif rst_cnt /= x"FF" then
                rst_cnt  <= rst_cnt + 1;
                rst_pclk <= '1';
            else
                rst_pclk <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Video timing generator
    ---------------------------------------------------------------------------
    u_timing : entity work.video_timing
        port map (
            clk     => pclk,
            rst     => rst_pclk,
            hsync   => vt_hsync,
            vsync   => vt_vsync,
            de      => vt_de,
            pixel_x => vt_pixel_x,
            pixel_y => vt_pixel_y
        );

    ---------------------------------------------------------------------------
    -- Color bar pattern generator
    ---------------------------------------------------------------------------
    u_color : entity work.color_bars
        port map (
            clk     => pclk,
            de_in   => vt_de,
            pixel_x => vt_pixel_x,
            pixel_y => vt_pixel_y,
            r_out   => cb_r,
            g_out   => cb_g,
            b_out   => cb_b,
            de_out  => cb_de
        );

    ---------------------------------------------------------------------------
    -- Pipeline hsync/vsync to match color bar 1-clock latency
    ---------------------------------------------------------------------------
    process(pclk)
    begin
        if rising_edge(pclk) then
            hsync_d1 <= vt_hsync;
            vsync_d1 <= vt_vsync;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- I2C init for ADV7511 (runs on sys_clk domain = 100 MHz)
    ---------------------------------------------------------------------------
    u_i2c : entity work.i2c_init
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            I2C_FREQ_HZ => 100_000
        )
        port map (
            clk  => sys_clk,
            rst  => rst_sys,
            scl  => hdmi_scl,
            sda  => hdmi_sda,
            done => i2c_done
        );

    ---------------------------------------------------------------------------
    -- Output mapping
    ---------------------------------------------------------------------------
    -- Pixel clock to ADV7511 via ODDR (proper clock forwarding)
    -- ODDR toggles the output on both edges, producing a clean copy of pclk
    u_clk_oddr : ODDR
        generic map (
            DDR_CLK_EDGE => "OPPOSITE_EDGE",
            INIT         => '0',
            SRTYPE       => "SYNC"
        )
        port map (
            Q  => hdmi_clk,
            C  => pclk,
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => '0',
            S  => '0'
        );

    -- Sync and data enable (active high)
    hdmi_hsync <= hsync_d1;
    hdmi_vsync <= vsync_d1;
    hdmi_de    <= cb_de;

    -- 16-bit data bus: R[7:0] on D[15:8], G[7:0] on D[7:0]
    -- Blue is lost in 16-bit mode, but all bars will still show distinct colors
    hdmi_d(15 downto 8) <= cb_r;
    hdmi_d(7 downto 0)  <= cb_g;

    -- S/PDIF audio: not used, drive low
    hdmi_spdif <= '0';

    ---------------------------------------------------------------------------
    -- Debug LEDs
    ---------------------------------------------------------------------------
    led(0) <= mmcm_locked;
    led(1) <= i2c_done;
    led(2) <= not hdmi_int_n;  -- ADV7511 interrupt active-low, LED active-high
    led(3) <= vt_vsync;        -- Blink at 60 Hz (visible flicker)
    led(7 downto 4) <= (others => '0');

end architecture rtl;
