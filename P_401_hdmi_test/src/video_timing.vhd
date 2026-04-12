-------------------------------------------------------------------------------
-- video_timing.vhd - 720p @ 60 Hz timing generator
--
-- Generates HSYNC, VSYNC, Data Enable, and pixel coordinates for
-- 1280x720 progressive @ 60 Hz (74.25 MHz pixel clock).
--
-- Timing parameters (CEA-861):
--   H active: 1280   H front porch: 110   H sync: 40   H back porch: 220
--   V active: 720    V front porch: 5     V sync: 5    V back porch: 20
--   H total: 1650    V total: 750
--   Sync polarity: positive (active high)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity video_timing is
    port (
        clk       : in  std_logic;   -- 74.25 MHz pixel clock
        rst       : in  std_logic;   -- active-high synchronous reset
        -- Video timing outputs
        hsync     : out std_logic;
        vsync     : out std_logic;
        de        : out std_logic;   -- data enable (active region)
        pixel_x   : out unsigned(10 downto 0);  -- 0..1279 during active
        pixel_y   : out unsigned(9 downto 0)     -- 0..719  during active
    );
end entity video_timing;

architecture rtl of video_timing is

    -- Horizontal timing constants
    constant H_ACTIVE : natural := 1280;
    constant H_FP     : natural := 110;
    constant H_SYNC   : natural := 40;
    constant H_BP     : natural := 220;
    constant H_TOTAL  : natural := H_ACTIVE + H_FP + H_SYNC + H_BP;  -- 1650

    -- Vertical timing constants
    constant V_ACTIVE : natural := 720;
    constant V_FP     : natural := 5;
    constant V_SYNC   : natural := 5;
    constant V_BP     : natural := 20;
    constant V_TOTAL  : natural := V_ACTIVE + V_FP + V_SYNC + V_BP;  -- 750

    -- Counters
    signal h_cnt : unsigned(10 downto 0) := (others => '0');  -- 0..1649
    signal v_cnt : unsigned(9 downto 0)  := (others => '0');  -- 0..749

    -- Internal signals
    signal h_active : std_logic;
    signal v_active : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Horizontal and vertical counters
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                h_cnt <= (others => '0');
                v_cnt <= (others => '0');
            else
                if h_cnt = H_TOTAL - 1 then
                    h_cnt <= (others => '0');
                    if v_cnt = V_TOTAL - 1 then
                        v_cnt <= (others => '0');
                    else
                        v_cnt <= v_cnt + 1;
                    end if;
                else
                    h_cnt <= h_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Sync generation (active-high, positive polarity for 720p)
    -- HSYNC pulse: from H_ACTIVE+H_FP to H_ACTIVE+H_FP+H_SYNC-1
    -- VSYNC pulse: from V_ACTIVE+V_FP to V_ACTIVE+V_FP+V_SYNC-1
    ---------------------------------------------------------------------------
    hsync <= '1' when (h_cnt >= H_ACTIVE + H_FP) and
                      (h_cnt <  H_ACTIVE + H_FP + H_SYNC) else '0';

    vsync <= '1' when (v_cnt >= V_ACTIVE + V_FP) and
                      (v_cnt <  V_ACTIVE + V_FP + V_SYNC) else '0';

    ---------------------------------------------------------------------------
    -- Active region flags
    ---------------------------------------------------------------------------
    h_active <= '1' when h_cnt < H_ACTIVE else '0';
    v_active <= '1' when v_cnt < V_ACTIVE else '0';

    de <= h_active and v_active;

    ---------------------------------------------------------------------------
    -- Pixel coordinates (valid only during active region)
    ---------------------------------------------------------------------------
    pixel_x <= h_cnt when h_active = '1' else (others => '0');
    pixel_y <= v_cnt when v_active = '1' else (others => '0');

end architecture rtl;
