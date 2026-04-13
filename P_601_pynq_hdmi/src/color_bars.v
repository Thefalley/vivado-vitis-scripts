// Pattern generator: red circle centered on 720p screen
// Purely combinational.

module color_bars (
    input  wire [10:0] x,
    input  wire [9:0]  y,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

    // Circle: center (640, 360), radius 150
    // (x-640)^2 + (y-360)^2 <= 150^2 = 22500
    wire signed [11:0] dx = $signed({1'b0, x}) - 12'sd640;
    wire signed [11:0] dy = $signed({2'b0, y}) - 12'sd360;
    wire [23:0] dist_sq = dx * dx + dy * dy;
    wire in_circle = (dist_sq <= 24'd22500);

    always @(*) begin
        if (in_circle) begin
            r = 8'hFF; g = 8'h00; b = 8'h00;  // Red
        end else begin
            r = 8'h00; g = 8'h00; b = 8'h00;  // Black
        end
    end

endmodule
