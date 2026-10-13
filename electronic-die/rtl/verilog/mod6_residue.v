// x mod 6 for an unsigned WIDTH-bit x, built as a balanced tree of mod-3 adders.
//
//   x = 2*h + b0 with h = x >> 1      =>   x mod 6 = b0 + 2*(h mod 3)
//   h = sum_i d_i * 4^i (base-4 digits d_i = h[2i+1:2i]) and 4 = 1 (mod 3)
//                                     =>   h mod 3 = (sum_i d_i) mod 3
//
// The digits are added modulo 3 in a perfect binary tree.  Every node is the
// same 4-input, 2-output function (a + b) mod 3, so the tree has log2(digits)
// levels instead of the 64-stage subtract chain the % operator produces.
//
// STAGES pipeline registers (0 .. LOG) are placed at evenly spaced tree depths.
// Every path from x to rem crosses exactly STAGES registers, so rem is
// x mod 6 for the x presented STAGES clocks earlier (combinational if 0).
module mod6_residue #(
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

    localparam integer DIGITS = WIDTH / 2;           // digits of h = x >> 1
    localparam integer LOG    = clog2(DIGITS);       // tree levels
    localparam integer LEAVES = 1 << LOG;

    // Bit d of CUTS is 1 when a register follows the nodes at depth d
    // (depth 1 = nodes fed by digits, depth LOG = root).
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
    localparam [31:0] CUTS = cuts(STAGES, LOG);

    function [1:0] mod3add;               // (a + b) mod 3 for a, b in 0..3
        input [1:0] a;
        input [1:0] b;
        reg   [2:0] s;
        begin
            s = a + b;
            if (s >= 3'd6)      mod3add = 2'd0;
            else if (s >= 3'd3) mod3add = s - 3'd3;
            else                mod3add = s[1:0];
        end
    endfunction

    // Heap-ordered tree: node j has children 2j and 2j+1; leaves are
    // LEAVES .. 2*LEAVES-1; node 1 is the root.  Two bits per node.
    wire [2*LEAVES-1:0] h = {{(2*LEAVES - (WIDTH - 1)){1'b0}}, x[WIDTH-1:1]};
    wire [4*LEAVES-1:0] node;

    genvar l, i;
    generate
        if (WIDTH < 4 || STAGES < 0 || STAGES > LOG) begin : bad_parameters
            initial $display("mod6_residue: need WIDTH >= 4 and 0 <= STAGES <= %0d", LOG);
            assign node = {4*LEAVES{1'bx}};
        end else begin : tree
            for (i = 0; i < LEAVES; i = i + 1) begin : digit
                assign node[2*(LEAVES + i) +: 2] = h[2*i +: 2];
            end
            for (l = 0; l < LOG; l = l + 1) begin : level        // level l has 2^l nodes
                for (i = 0; i < (1 << l); i = i + 1) begin : n
                    wire [1:0] sum = mod3add(node[2*(2*((1 << l) + i))     +: 2],
                                             node[2*(2*((1 << l) + i) + 1) +: 2]);
                    if (CUTS[LOG - l]) begin : registered
                        reg [1:0] q = 2'd0;
                        always @(posedge clk) q <= sum;
                        assign node[2*((1 << l) + i) +: 2] = q;
                    end else begin : combinational
                        assign node[2*((1 << l) + i) +: 2] = sum;
                    end
                end
            end
        end
    endgenerate

    // b0 travels alongside the tree with the same latency.
    wire [STAGES:0] b0;
    assign b0[0] = x[0];
    generate
        for (i = 1; i <= STAGES; i = i + 1) begin : b0_delay
            reg q = 1'b0;
            always @(posedge clk) q <= b0[i-1];
            assign b0[i] = q;
        end
    endgenerate

    assign rem = {node[3:2], b0[STAGES]};    // 2*(h mod 3) + b0, at most 5
endmodule
