`timescale 1ns / 1ps

module blink_led_tb;

    reg clk;
    reg reset;
    wire [7:0] leds;

    blink_led uut (
        .clk(clk),
        .reset(reset),
        .leds(leds)
    );

    initial clk = 0;
    always #5 clk = ~clk; // 100 MHz

    initial begin
        reset = 1;
        #100;
        reset = 0;
        #700_000_000; // ~0.7s para ver rotacion
        $finish;
    end

endmodule
