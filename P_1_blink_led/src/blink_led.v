module blink_led (
    input  wire clk,
    input  wire reset,
    output reg [7:0] leds
);

    // ZedBoard: 100 MHz clock -> toggle cada 0.67s
    // Counter de 26 bits: 2^26 = 67M ~ 0.67s a 100MHz
    reg [25:0] counter;

    always @(posedge clk) begin
        if (reset) begin
            counter <= 26'd0;
            leds    <= 8'b0000_0001;
        end else begin
            counter <= counter + 1'b1;
            if (counter == 26'd0)
                leds <= {leds[6:0], leds[7]}; // rotate left
        end
    end

endmodule
