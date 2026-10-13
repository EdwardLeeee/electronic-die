module rng64_behavior (
    input  wire        clk,
    input  wire        sel,
    input  wire [63:0] seed,
    output reg  [63:0] rng_out
);
    integer i;
    integer im1;
    integer ip1;
    integer ip2;
    reg [3:0] adr;
    reg [63:0] next_state;

    always @(*) begin
        next_state = rng_out;
        for (i = 0; i < 64; i = i + 1) begin
            im1 = (i == 0)  ? 63 : i - 1;
            ip1 = (i == 63) ? 0  : i + 1;
            ip2 = (i >= 62) ? i - 62 : i + 2;
            adr = {rng_out[i], rng_out[im1], rng_out[ip2], rng_out[ip1]};

            case (adr)
                4'b0000: next_state[i] = 1'b0;
                4'b0001: next_state[i] = 1'b1;
                4'b0010: next_state[i] = 1'b1;
                4'b0011: next_state[i] = 1'b0;
                4'b0100: next_state[i] = 1'b0;
                4'b0101: next_state[i] = 1'b0;
                4'b0110: next_state[i] = 1'b0;
                4'b0111: next_state[i] = 1'b1;
                4'b1000: next_state[i] = 1'b1;
                4'b1001: next_state[i] = 1'b1;
                4'b1010: next_state[i] = 1'b1;
                4'b1011: next_state[i] = 1'b0;
                4'b1100: next_state[i] = 1'b0;
                4'b1101: next_state[i] = 1'b1;
                4'b1110: next_state[i] = 1'b0;
                default: next_state[i] = 1'b1;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!sel)
            rng_out <= seed;
        else
            rng_out <= next_state;
    end
endmodule

module electronic_die_behavior (
    input  wire       clk,
    input  wire       en,
    output wire [2:0] tossing_result
);
    parameter [63:0] SEED = 64'd122059;

    reg        init_done = 1'b0;
    reg [2:0]  result_reg = 3'd1;
    wire [63:0] rng_value;

    function [2:0] die_from_mod6;
        input [63:0] value;
        integer k;
        reg [3:0] next_rem;
        reg [2:0] remainder;
        begin
            remainder = 3'd0;
            for (k = 63; k >= 0; k = k - 1) begin
                next_rem = {remainder, 1'b0} + value[k];
                if (next_rem >= 4'd6)
                    next_rem = next_rem - 4'd6;
                remainder = next_rem[2:0];
            end
            die_from_mod6 = remainder + 3'd1;
        end
    endfunction

    rng64_behavior rng_inst (
        .clk     (clk),
        .sel     (init_done),
        .seed    (SEED),
        .rng_out (rng_value)
    );

    always @(posedge clk) begin
        if (!init_done)
            init_done <= 1'b1;
        else if (en)
            result_reg <= die_from_mod6(rng_value);
    end

    assign tossing_result = result_reg;
endmodule
