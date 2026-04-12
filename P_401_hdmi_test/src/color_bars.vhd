-------------------------------------------------------------------------------
-- color_bars.vhd - 8-bar SMPTE-style color bar pattern generator
--
-- Generates 8 vertical bars across 1280 pixels:
--   Bar 0: White    (255, 255, 255)
--   Bar 1: Yellow   (255, 255,   0)
--   Bar 2: Cyan     (  0, 255, 255)
--   Bar 3: Green    (  0, 255,   0)
--   Bar 4: Magenta  (255,   0, 255)
--   Bar 5: Red      (255,   0,   0)
--   Bar 6: Blue     (  0,   0, 255)
--   Bar 7: Black    (  0,   0,   0)
--
-- Each bar is 160 pixels wide (1280 / 8 = 160).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity color_bars is
    port (
        clk     : in  std_logic;
        de_in   : in  std_logic;
        pixel_x : in  unsigned(10 downto 0);
        pixel_y : in  unsigned(9 downto 0);
        -- 24-bit RGB output
        r_out   : out std_logic_vector(7 downto 0);
        g_out   : out std_logic_vector(7 downto 0);
        b_out   : out std_logic_vector(7 downto 0);
        de_out  : out std_logic
    );
end entity color_bars;

architecture rtl of color_bars is

    -- Bar index: pixel_x / 160 = pixel_x(10 downto 7) when aligned
    -- Since 160 is not a power of 2, we use the top 3 bits of pixel_x
    -- after dividing by 160.  Actually, 1280/8 = 160.
    -- A simpler approach: pixel_x(10 downto 7) gives 0..9 for 0..1279
    -- but that divides by 128, not 160.
    -- We'll compare ranges explicitly for correctness.
    signal bar_idx : unsigned(2 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Determine which bar we're in (registered for timing)
    ---------------------------------------------------------------------------
    process(clk)
        variable px : natural;
    begin
        if rising_edge(clk) then
            de_out <= de_in;

            px := to_integer(pixel_x);

            if    px < 160 then bar_idx <= "000";  -- Bar 0: White
            elsif px < 320 then bar_idx <= "001";  -- Bar 1: Yellow
            elsif px < 480 then bar_idx <= "010";  -- Bar 2: Cyan
            elsif px < 640 then bar_idx <= "011";  -- Bar 3: Green
            elsif px < 800 then bar_idx <= "100";  -- Bar 4: Magenta
            elsif px < 960 then bar_idx <= "101";  -- Bar 5: Red
            elsif px < 1120 then bar_idx <= "110"; -- Bar 6: Blue
            else                bar_idx <= "111";  -- Bar 7: Black
            end if;

            -- Color lookup (active only during DE)
            if de_in = '1' then
                case to_integer(bar_idx) is
                    when 0 =>  -- White
                        r_out <= x"FF"; g_out <= x"FF"; b_out <= x"FF";
                    when 1 =>  -- Yellow
                        r_out <= x"FF"; g_out <= x"FF"; b_out <= x"00";
                    when 2 =>  -- Cyan
                        r_out <= x"00"; g_out <= x"FF"; b_out <= x"FF";
                    when 3 =>  -- Green
                        r_out <= x"00"; g_out <= x"FF"; b_out <= x"00";
                    when 4 =>  -- Magenta
                        r_out <= x"FF"; g_out <= x"00"; b_out <= x"FF";
                    when 5 =>  -- Red
                        r_out <= x"FF"; g_out <= x"00"; b_out <= x"00";
                    when 6 =>  -- Blue
                        r_out <= x"00"; g_out <= x"00"; b_out <= x"FF";
                    when others =>  -- Black
                        r_out <= x"00"; g_out <= x"00"; b_out <= x"00";
                end case;
            else
                r_out <= x"00";
                g_out <= x"00";
                b_out <= x"00";
            end if;
        end if;
    end process;

end architecture rtl;
