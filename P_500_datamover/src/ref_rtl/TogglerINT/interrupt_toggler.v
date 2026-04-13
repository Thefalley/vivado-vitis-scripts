

module interrupt_toggler #(
    parameter CNT_MAX = 4
)(
    input   wire    clk,
    input   wire    n_rst,
    input   wire    pulse,
    output  reg     INT_A,
    output  reg     INT_B
);

    // PULSE COUNTER
    reg [$clog2(CNT_MAX)-1:0] cnt;

    always @(posedge(clk)) begin
        if (!n_rst) begin
            cnt <= 0;
            INT_A <= 0;
            INT_B <= 1;
        end else begin
            if (pulse) begin
                if (cnt == CNT_MAX - 1) begin
                    cnt <= 0;
                    INT_A <= ~INT_A;
                    INT_B <= ~INT_B;
                end else begin
                    cnt <= cnt + 1;
                end
            end
        end
    end

endmodule