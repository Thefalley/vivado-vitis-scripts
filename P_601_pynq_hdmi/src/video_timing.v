// Video timing generator - 1280x720 @ 60 Hz (720p)
// Pixel clock: 74.25 MHz nominal (73.958 MHz used, 0.39% error)
// All outputs are combinational from registered counters.

module video_timing (
    input  wire        clk,
    input  wire        rst,
    output wire        hsync,
    output wire        vsync,
    output wire        de,
    output wire [10:0] hcount,
    output wire [9:0]  vcount
);

    // CEA-861 1280x720 @ 60 Hz timing
    localparam H_ACTIVE = 1280;
    localparam H_FP     = 110;
    localparam H_SYNC   = 40;
    localparam H_BP     = 220;
    localparam H_TOTAL  = 1650;

    localparam V_ACTIVE = 720;
    localparam V_FP     = 5;
    localparam V_SYNC   = 5;
    localparam V_BP     = 20;
    localparam V_TOTAL  = 750;

    reg [10:0] h_cnt = 0;
    reg [9:0]  v_cnt = 0;

    always @(posedge clk) begin
        if (rst) begin
            h_cnt <= 0;
            v_cnt <= 0;
        end else if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 0;
            v_cnt <= (v_cnt == V_TOTAL - 1) ? 10'd0 : v_cnt + 1'b1;
        end else begin
            h_cnt <= h_cnt + 1'b1;
        end
    end

    assign hcount = h_cnt;
    assign vcount = v_cnt;

    // Active video area
    assign de = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);

    // Sync pulses (active HIGH for 720p)
    assign hsync = (h_cnt >= H_ACTIVE + H_FP) && (h_cnt < H_ACTIVE + H_FP + H_SYNC);
    assign vsync = (v_cnt >= V_ACTIVE + V_FP) && (v_cnt < V_ACTIVE + V_FP + V_SYNC);

endmodule
