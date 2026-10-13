module ca_cell (
    input  wire [3:0] adr,
    input  wire       clk,
    input  wire       sel,
    input  wire       init,
    output reg        y
);
    reg next_state;

    always @(*) begin
        case (adr)
            4'b0000: next_state = 1'b0;
            4'b0001: next_state = 1'b1;
            4'b0010: next_state = 1'b1;
            4'b0011: next_state = 1'b0;
            4'b0100: next_state = 1'b0;
            4'b0101: next_state = 1'b0;
            4'b0110: next_state = 1'b0;
            4'b0111: next_state = 1'b1;
            4'b1000: next_state = 1'b1;
            4'b1001: next_state = 1'b1;
            4'b1010: next_state = 1'b1;
            4'b1011: next_state = 1'b0;
            4'b1100: next_state = 1'b0;
            4'b1101: next_state = 1'b1;
            4'b1110: next_state = 1'b0;
            4'b1111: next_state = 1'b1;
            default: next_state = 1'b1;
        endcase
    end

    always @(posedge clk) begin
        if (!sel)
            y <= init;
        else
            y <= next_state;
    end
endmodule
