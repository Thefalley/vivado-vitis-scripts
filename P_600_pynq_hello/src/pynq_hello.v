module pynq_hello (
    input  wire       clk,
    input  wire [1:0] sw,
    input  wire [3:0] btn,
    output reg  [3:0] leds
);

    // PYNQ-Z2: 125 MHz clock
    // Counter de 26 bits: 2^26 = ~67M -> ~0.54s a 125MHz
    // SW[0] = acelerar (2x), SW[1] = patron alternativo
    reg [26:0] counter = 0;

    wire tick = (sw[0]) ? counter[24] & ~prev24 :  // rapido (~0.13s)
                          counter[26] & ~prev26;    // lento  (~0.54s)

    reg prev24 = 0, prev26 = 0;

    always @(posedge clk) begin
        counter <= counter + 1'b1;
        prev24  <= counter[24];
        prev26  <= counter[26];
    end

    // Patron de LEDs - iniciar con LED0 encendido
    initial leds = 4'b0001;

    always @(posedge clk) begin
        if (btn[0]) begin
            // Reset: encender LED 0
            leds <= 4'b0001;
        end else if (tick) begin
            if (sw[1])
                leds <= ~leds;                        // toggle all
            else
                leds <= {leds[2:0], leds[3]};         // rotate left
        end
    end

endmodule
