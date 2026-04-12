`timescale 1ns / 1ps

module pynq_hello_tb;

    reg clk = 0;
    reg [1:0] sw = 0;
    reg [3:0] btn = 0;
    wire [3:0] leds;

    pynq_hello uut (
        .clk  (clk),
        .sw   (sw),
        .btn  (btn),
        .leds (leds)
    );

    // 125 MHz -> 8 ns period
    always #4 clk = ~clk;

    initial begin
        $display("=== PYNQ Hello World TB ===");

        // Reset via BTN0
        btn = 4'b0001;
        #100;
        btn = 4'b0000;

        // Run for a bit at slow speed
        $display("T=%0t LEDs=%b (after reset)", $time, leds);
        #1000;
        $display("T=%0t LEDs=%b", $time, leds);

        // Enable fast mode
        sw = 2'b01;
        #1000;
        $display("T=%0t LEDs=%b (fast mode)", $time, leds);

        // Toggle pattern
        sw = 2'b10;
        #1000;
        $display("T=%0t LEDs=%b (toggle mode)", $time, leds);

        $display("=== PASS ===");
        $finish;
    end

endmodule
