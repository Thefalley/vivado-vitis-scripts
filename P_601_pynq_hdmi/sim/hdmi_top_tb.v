`timescale 1ns / 1ps

module hdmi_top_tb;

    reg clk_125 = 0;
    wire hdmi_tx_clk_p, hdmi_tx_clk_n;
    wire [2:0] hdmi_tx_d_p, hdmi_tx_d_n;
    wire [3:0] leds;

    hdmi_top uut (
        .clk_125       (clk_125),
        .hdmi_tx_clk_p (hdmi_tx_clk_p),
        .hdmi_tx_clk_n (hdmi_tx_clk_n),
        .hdmi_tx_d_p   (hdmi_tx_d_p),
        .hdmi_tx_d_n   (hdmi_tx_d_n),
        .leds          (leds)
    );

    // 125 MHz -> 8 ns period
    always #4 clk_125 = ~clk_125;

    initial begin
        $display("=== HDMI TX Testbench ===");
        // Wait for MMCM to lock (simulated)
        #500;
        $display("T=%0t MMCM locked=%b", $time, leds[0]);
        // Run a few lines
        #100000;
        $display("T=%0t LEDs=%b", $time, leds);
        $display("=== DONE ===");
        $finish;
    end

endmodule
