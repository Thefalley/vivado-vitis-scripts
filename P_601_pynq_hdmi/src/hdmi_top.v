// HDMI TX top module for PYNQ-Z2
// Generates 720p@60Hz color bars over TMDS using Digilent rgb2dvi IP.
// Architecture: 125MHz -> MMCM -> ~74MHz pixel + ~370MHz serial
//               video_timing -> color_bars -> rgb2dvi (Digilent) -> TMDS out

module hdmi_top (
    input  wire       clk_125,        // 125 MHz board clock
    output wire       hdmi_tx_clk_p,  // TMDS clock pair
    output wire       hdmi_tx_clk_n,
    output wire [2:0] hdmi_tx_d_p,    // TMDS data pairs
    output wire [2:0] hdmi_tx_d_n,
    output wire [3:0] leds
);

    // ================================================================
    // Clock generation: 125 MHz -> ~74 MHz (pixel) + ~370 MHz (5x serial)
    // VCO = 125 * 8.875 = 1109.375 MHz
    // pixel  = 1109.375 / 15 = 73.958 MHz (0.39% from 74.25)
    // serial = 1109.375 / 3  = 369.792 MHz (exactly 5x pixel)
    // ================================================================
    wire clk_pixel, clk_serial;
    wire clk_pixel_unbuf, clk_serial_unbuf;
    wire clk_fb, clk_fb_buf;
    wire mmcm_locked;

    MMCME2_BASE #(
        .CLKFBOUT_MULT_F (8.875),
        .CLKIN1_PERIOD    (8.0),
        .CLKOUT0_DIVIDE_F (15.0),
        .CLKOUT1_DIVIDE   (3),
        .DIVCLK_DIVIDE    (1)
    ) mmcm_inst (
        .CLKOUT0  (clk_pixel_unbuf),
        .CLKOUT1  (clk_serial_unbuf),
        .CLKOUT0B (), .CLKOUT1B (),
        .CLKOUT2  (), .CLKOUT2B (),
        .CLKOUT3  (), .CLKOUT3B (),
        .CLKOUT4  (), .CLKOUT5  (), .CLKOUT6 (),
        .CLKFBOUT (clk_fb),
        .CLKFBOUTB(),
        .CLKIN1   (clk_125),
        .CLKFBIN  (clk_fb_buf),
        .PWRDWN   (1'b0),
        .RST      (1'b0),
        .LOCKED   (mmcm_locked)
    );

    BUFG bufg_pixel  (.I(clk_pixel_unbuf),  .O(clk_pixel));
    BUFG bufg_serial (.I(clk_serial_unbuf), .O(clk_serial));
    BUFG bufg_fb     (.I(clk_fb),           .O(clk_fb_buf));

    // Reset: active while MMCM not locked
    wire rst = ~mmcm_locked;

    // ================================================================
    // Video timing: 720p @ 60 Hz
    // ================================================================
    wire hsync, vsync, de;
    wire [10:0] hcount;
    wire [9:0]  vcount;

    video_timing timing_inst (
        .clk    (clk_pixel),
        .rst    (1'b0),
        .hsync  (hsync),
        .vsync  (vsync),
        .de     (de),
        .hcount (hcount),
        .vcount (vcount)
    );

    // ================================================================
    // Color bar pattern
    // ================================================================
    wire [7:0] r, g, b;

    color_bars bars_inst (
        .x (hcount),
        .y (vcount),
        .r (r),
        .g (g),
        .b (b)
    );

    // ================================================================
    // Digilent rgb2dvi: proven TMDS encoding + OSERDESE2 serialization
    // vid_pData packing: {Red[23:16], Blue[15:8], Green[7:0]}
    // ================================================================
    rgb2dvi #(
        .kGenerateSerialClk(1'b0),
        .kRstActiveHigh(1'b1),
        .kClkRange(1),
        .kD0Swap(1'b0),
        .kD1Swap(1'b0),
        .kD2Swap(1'b0),
        .kClkSwap(1'b0)
    ) dvi_out (
        .TMDS_Clk_p  (hdmi_tx_clk_p),
        .TMDS_Clk_n  (hdmi_tx_clk_n),
        .TMDS_Data_p (hdmi_tx_d_p),
        .TMDS_Data_n (hdmi_tx_d_n),
        .aRst        (rst),
        .aRst_n      (~rst),
        .vid_pData   ({r, b, g}),
        .vid_pVDE    (de),
        .vid_pHSync  (hsync),
        .vid_pVSync  (vsync),
        .PixelClk    (clk_pixel),
        .SerialClk   (clk_serial)
    );

    // ================================================================
    // Status LEDs
    // ================================================================
    assign leds[0] = mmcm_locked;
    assign leds[1] = 1'b1;
    assign leds[2] = 1'b0;
    assign leds[3] = 1'b0;

endmodule
