// TMDS 8b/10b encoder (DVI 1.0 spec)
// Encodes 8-bit pixel data into 10-bit TMDS symbols with DC balance.
// During blanking (de=0), outputs one of 4 control characters.

module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire       de,       // data enable (active during visible area)
    input  wire [1:0] ctrl,     // control bits (used during blanking)
    input  wire [7:0] din,      // 8-bit pixel data
    output reg  [9:0] dout      // 10-bit TMDS symbol
);

    // Count 1s in input data
    wire [3:0] N1d = din[0] + din[1] + din[2] + din[3] +
                     din[4] + din[5] + din[6] + din[7];

    // Step 1: Minimize transitions - choose XOR or XNOR path
    wire use_xnor = (N1d > 4'd4) || (N1d == 4'd4 && din[0] == 1'b0);

    wire [8:0] q_m;
    assign q_m[0] = din[0];
    assign q_m[1] = use_xnor ? (q_m[0] ~^ din[1]) : (q_m[0] ^ din[1]);
    assign q_m[2] = use_xnor ? (q_m[1] ~^ din[2]) : (q_m[1] ^ din[2]);
    assign q_m[3] = use_xnor ? (q_m[2] ~^ din[3]) : (q_m[2] ^ din[3]);
    assign q_m[4] = use_xnor ? (q_m[3] ~^ din[4]) : (q_m[3] ^ din[4]);
    assign q_m[5] = use_xnor ? (q_m[4] ~^ din[5]) : (q_m[4] ^ din[5]);
    assign q_m[6] = use_xnor ? (q_m[5] ~^ din[6]) : (q_m[5] ^ din[6]);
    assign q_m[7] = use_xnor ? (q_m[6] ~^ din[7]) : (q_m[6] ^ din[7]);
    assign q_m[8] = ~use_xnor;  // 1=XOR, 0=XNOR

    // Count 1s/0s in q_m[7:0]
    wire [3:0] N1q = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                     q_m[4] + q_m[5] + q_m[6] + q_m[7];
    wire [3:0] N0q = 4'd8 - N1q;

    // Step 2: DC balance with running disparity counter (two's complement)
    reg [4:0] cnt = 5'd0;

    wire cnt_eq_0 = (cnt == 5'd0);
    wire cnt_gt_0 = ~cnt[4] & ~cnt_eq_0;
    wire cnt_lt_0 = cnt[4];

    always @(posedge clk) begin
        if (rst) begin
            dout <= 10'b1101010100;
            cnt  <= 5'd0;
        end else if (!de) begin
            // Blanking: output control character, reset disparity
            cnt <= 5'd0;
            case (ctrl)
                2'b00:   dout <= 10'b1101010100;
                2'b01:   dout <= 10'b0010101011;
                2'b10:   dout <= 10'b0101010100;
                default: dout <= 10'b1010101011;
            endcase
        end else begin
            // Active video: encode with DC balance
            if (cnt_eq_0 || N1q == 4'd4) begin
                dout[9]   <= ~q_m[8];
                dout[8]   <= q_m[8];
                dout[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
                cnt       <= q_m[8] ? (cnt + N1q - N0q) : (cnt + N0q - N1q);
            end else if ((cnt_gt_0 && N1q > 4'd4) || (cnt_lt_0 && N1q < 4'd4)) begin
                dout[9]   <= 1'b1;
                dout[8]   <= q_m[8];
                dout[7:0] <= ~q_m[7:0];
                cnt       <= cnt + {3'b0, q_m[8], 1'b0} + N0q - N1q;
            end else begin
                dout[9]   <= 1'b0;
                dout[8]   <= q_m[8];
                dout[7:0] <= q_m[7:0];
                cnt       <= cnt - {3'b0, ~q_m[8], 1'b0} + N1q - N0q;
            end
        end
    end

endmodule
