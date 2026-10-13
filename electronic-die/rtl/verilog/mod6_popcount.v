// x mod 6 for an unsigned WIDTH-bit x, from two popcounts.
//
//   2^0 mod 6 = 1, and for k >= 1: 2^k mod 6 = 2 (k odd), 4 (k even)
//   =>  x mod 6 = (b0 + 2*P_odd + 4*P_even) mod 6
//               = b0 + 2*((P_odd + 2*P_even) mod 3)
//   P_odd  = number of ones in x[1], x[3], x[5], ...
//   P_even = number of ones in x[2], x[4], x[6], ...
//
// Each popcount is a perfect binary adder tree (LOG levels).  The small
// final reduction (P_odd + 2*P_even) mod 3 counts as one more depth.
// STAGES pipeline registers (0 .. LOG+1) are placed at evenly spaced depths;
// rem is x mod 6 for the x presented STAGES clocks earlier.
module mod6_popcount #(
    parameter integer WIDTH  = 64,
    parameter integer STAGES = 0
) (
    input  wire             clk,
    input  wire [WIDTH-1:0] x,
    output wire [2:0]       rem
);
    function integer clog2;               // ceil(log2(n)), n >= 1
        input integer n;
        integer v;
        begin
            clog2 = 0;
            for (v = n - 1; v > 0; v = v >> 1)
                clog2 = clog2 + 1;
        end
    endfunction

    localparam integer NODD   = WIDTH / 2;           // x[1], x[3], ...
    localparam integer NEVEN  = (WIDTH - 1) / 2;     // x[2], x[4], ...
    localparam integer LOG    = clog2(NODD);
    localparam integer LEAVES = 1 << LOG;
    localparam integer CW     = LOG + 1;             // a count of up to LEAVES ones
    localparam integer DEPTH  = LOG + 1;             // adder levels + final mod 3

    // Bit d of CUTS is 1 when a register follows depth d
    // (1 = first adder level, LOG = popcount roots, LOG+1 = final mod 3).
    function [31:0] cuts;
        input integer stages;
        input integer levels;
        integer k;
        begin
            cuts = 32'd0;
            for (k = 1; k <= stages; k = k + 1)
                cuts = cuts | (32'd1 << ((k * levels + stages) / (stages + 1)));
        end
    endfunction
    localparam [31:0] CUTS = cuts(STAGES, DEPTH);

    // Leaf bit vectors, zero padded to LEAVES.
    wire [LEAVES-1:0] odd_bits;
    wire [LEAVES-1:0] even_bits;
    genvar l, i;
    generate
        for (i = 0; i < LEAVES; i = i + 1) begin : leaves
            if (i < NODD)  begin : o assign odd_bits[i]  = x[2*i + 1]; end
            else           begin : o assign odd_bits[i]  = 1'b0;       end
            if (i < NEVEN) begin : e assign even_bits[i] = x[2*i + 2]; end
            else           begin : e assign even_bits[i] = 1'b0;       end
        end
    endgenerate

    // Two heap-ordered adder trees, CW bits per node; node 1 is the root.
    wire [CW*2*LEAVES-1:0] onode;
    wire [CW*2*LEAVES-1:0] enode;
    generate
        if (WIDTH < 4 || STAGES < 0 || STAGES > DEPTH) begin : bad_parameters
            initial $display("mod6_popcount: need WIDTH >= 4 and 0 <= STAGES <= %0d", DEPTH);
        end
        for (i = 0; i < LEAVES; i = i + 1) begin : leaf
            assign onode[CW*(LEAVES + i) +: CW] = {{(CW-1){1'b0}}, odd_bits[i]};
            assign enode[CW*(LEAVES + i) +: CW] = {{(CW-1){1'b0}}, even_bits[i]};
        end
        for (l = 0; l < LOG; l = l + 1) begin : level
            for (i = 0; i < (1 << l); i = i + 1) begin : n
                wire [CW-1:0] osum = onode[CW*(2*((1 << l) + i)) +: CW] + onode[CW*(2*((1 << l) + i) + 1) +: CW];
                wire [CW-1:0] esum = enode[CW*(2*((1 << l) + i)) +: CW] + enode[CW*(2*((1 << l) + i) + 1) +: CW];
                if (CUTS[LOG - l]) begin : registered
                    reg [CW-1:0] oq = {CW{1'b0}};
                    reg [CW-1:0] eq = {CW{1'b0}};
                    always @(posedge clk) begin
                        oq <= osum;
                        eq <= esum;
                    end
                    assign onode[CW*((1 << l) + i) +: CW] = oq;
                    assign enode[CW*((1 << l) + i) +: CW] = eq;
                end else begin : combinational
                    assign onode[CW*((1 << l) + i) +: CW] = osum;
                    assign enode[CW*((1 << l) + i) +: CW] = esum;
                end
            end
        end
    endgenerate

    wire [CW-1:0] p_odd  = onode[CW +: CW];
    wire [CW-1:0] p_even = enode[CW +: CW];
    wire [CW+1:0] t      = {2'b00, p_odd} + {1'b0, p_even, 1'b0};   // P_odd + 2*P_even
    wire [1:0]    r_comb = t % 3;
    wire [1:0]    r;
    generate
        if (CUTS[DEPTH]) begin : final_registered
            reg [1:0] q = 2'd0;
            always @(posedge clk) q <= r_comb;
            assign r = q;
        end else begin : final_combinational
            assign r = r_comb;
        end
    endgenerate

    wire [STAGES:0] b0;
    assign b0[0] = x[0];
    generate
        for (i = 1; i <= STAGES; i = i + 1) begin : b0_delay
            reg q = 1'b0;
            always @(posedge clk) q <= b0[i-1];
            assign b0[i] = q;
        end
    endgenerate

    assign rem = {r, b0[STAGES]};
endmodule
