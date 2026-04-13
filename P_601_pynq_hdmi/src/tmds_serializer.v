// TMDS 10:1 serializer using OSERDESE2 master/slave cascade (DDR mode)
// Converts 10-bit parallel TMDS symbol to serial output at 5x pixel clock.

module tmds_serializer (
    input  wire       clk_pixel,   // pixel clock (CLKDIV)
    input  wire       clk_serial,  // 5x pixel clock (CLK) for DDR 10:1
    input  wire       rst,
    input  wire [9:0] din,         // 10-bit TMDS symbol (parallel)
    output wire       serial_out   // serialized output
);

    wire cascade1, cascade2;

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"),
        .DATA_RATE_TQ ("SDR"),
        .DATA_WIDTH   (10),
        .SERDES_MODE  ("MASTER"),
        .TRISTATE_WIDTH(1)
    ) master (
        .OQ       (serial_out),
        .OFB      (),
        .TQ       (),
        .TFB      (),
        .SHIFTOUT1(),
        .SHIFTOUT2(),
        .CLK      (clk_serial),
        .CLKDIV   (clk_pixel),
        .D1       (din[0]),
        .D2       (din[1]),
        .D3       (din[2]),
        .D4       (din[3]),
        .D5       (din[4]),
        .D6       (din[5]),
        .D7       (din[6]),
        .D8       (din[7]),
        .TCE      (1'b0),
        .OCE      (1'b1),
        .TBYTEIN  (1'b0),
        .TBYTEOUT (),
        .RST      (rst),
        .SHIFTIN1 (cascade1),
        .SHIFTIN2 (cascade2),
        .T1       (1'b0),
        .T2       (1'b0),
        .T3       (1'b0),
        .T4       (1'b0)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"),
        .DATA_RATE_TQ ("SDR"),
        .DATA_WIDTH   (10),
        .SERDES_MODE  ("SLAVE"),
        .TRISTATE_WIDTH(1)
    ) slave (
        .OQ       (),
        .OFB      (),
        .TQ       (),
        .TFB      (),
        .SHIFTOUT1(cascade1),
        .SHIFTOUT2(cascade2),
        .CLK      (clk_serial),
        .CLKDIV   (clk_pixel),
        .D1       (1'b0),
        .D2       (1'b0),
        .D3       (din[8]),
        .D4       (din[9]),
        .D5       (1'b0),
        .D6       (1'b0),
        .D7       (1'b0),
        .D8       (1'b0),
        .TCE      (1'b0),
        .OCE      (1'b1),
        .TBYTEIN  (1'b0),
        .TBYTEOUT (),
        .RST      (rst),
        .SHIFTIN1 (1'b0),
        .SHIFTIN2 (1'b0),
        .T1       (1'b0),
        .T2       (1'b0),
        .T3       (1'b0),
        .T4       (1'b0)
    );

endmodule
