`timescale 1ns/1ps
// Equivalence of the mod-6 cores with Verilog's % operator.
//   -Ptb_mod6_equiv.CORE=1   mod6_popcount      -Ptb_mod6_equiv.CORE=2   mod6_residue
//   -Ptb_mod6_equiv.WIDTH=<w> -Ptb_mod6_equiv.STAGES=<s>
// WIDTH <= 20: every input value, visited in a scrambled order (a bijection,
// so that bit 0 is not simply periodic and a pipeline-latency error cannot
// hide).  Otherwise directed corner cases (0, all
// ones, every single bit set or cleared, alternating patterns, largest
// multiples of 6) followed by +n=<N> random values (default 200000).
// One new input per clock; rem is checked STAGES clocks later.
module tb_mod6_equiv;
    parameter integer CORE   = 2;
    parameter integer WIDTH  = 64;
    parameter integer STAGES = 0;
    localparam integer EXHAUSTIVE = (WIDTH <= 20);

    reg              clk = 1'b0;
    reg  [WIDTH-1:0] x   = {WIDTH{1'b0}};
    wire [2:0]       rem;

    generate
        if (CORE == 1) begin : c
            mod6_popcount #(.WIDTH(WIDTH), .STAGES(STAGES)) dut (.clk(clk), .x(x), .rem(rem));
        end else begin : c
            mod6_residue  #(.WIDTH(WIDTH), .STAGES(STAGES)) dut (.clk(clk), .x(x), .rem(rem));
        end
    endgenerate

    always #5 clk = ~clk;

    reg [WIDTH-1:0] hist [0:STAGES];       // inputs of the last STAGES+1 cycles
    reg [WIDTH-1:0] v, applied;
    reg [2:0]       want;
    integer n, total, k, errors, nrand, directed;
    integer s;

    // Bijection on WIDTH-bit values: odd multiply, xorshift, odd multiply.
    function [WIDTH-1:0] scramble(input [WIDTH-1:0] i);
        reg [WIDTH-1:0] y;
        begin
            y = i * 64'h9E3779B97F4A7C15;
            y = y ^ (y >> (WIDTH / 2));
            scramble = y * 64'hBF58476D1CE4E5B9;
        end
    endfunction

    // Directed value number k (k < 4*WIDTH + 8).
    function [WIDTH-1:0] corner(input integer k);
        reg [WIDTH-1:0] ones;
        begin
            ones = {WIDTH{1'b1}};
            if (k < WIDTH)              corner = {{(WIDTH-1){1'b0}}, 1'b1} << k;
            else if (k < 2*WIDTH)       corner = ~({{(WIDTH-1){1'b0}}, 1'b1} << (k - WIDTH));
            else if (k < 3*WIDTH)       corner = ones >> (k - 2*WIDTH);          // low-order runs of ones
            else if (k < 4*WIDTH)       corner = ones << (k - 3*WIDTH);          // high-order runs of ones
            else case (k - 4*WIDTH)
                0: corner = {WIDTH{1'b0}};
                1: corner = ones;
                2: corner = {(WIDTH+1)/2{2'b01}};
                3: corner = {(WIDTH+1)/2{2'b10}};
                4: corner = ones - (ones % 6);                                   // largest multiple of 6
                5: corner = ones - (ones % 6) - 1;
                6: corner = ones - (ones % 6) + 5;                               // may wrap: still a valid input
                default: corner = {(WIDTH+2)/3{3'b110}};
            endcase
        end
    endfunction

    initial begin
        errors = 0;
        directed = 4*WIDTH + 8;
        if (!$value$plusargs("n=%d", nrand)) nrand = 200000;
        s = 32'h5EED0000 + CORE*256 + WIDTH*8 + STAGES;
        total = EXHAUSTIVE ? (1 << WIDTH) : directed + nrand;

        for (n = 0; n < total + STAGES; n = n + 1) begin
            @(negedge clk);
            if (n < total) begin
                if (EXHAUSTIVE)        v = scramble(n);
                else if (n < directed) v = corner(n);
                else                   for (k = 0; k < WIDTH; k = k + 32) v = {v, $random(s)};
            end else
                v = {WIDTH{1'b0}};                                               // flush
            x = v;
            for (k = STAGES; k > 0; k = k - 1) hist[k] = hist[k-1];
            hist[0] = v;
            #1;
            if (n >= STAGES) begin
                applied = hist[STAGES];
                want = applied % 6;
                if (rem !== want) begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("FAIL: x=%0d (0x%h): rem=%0d expected %0d", applied, applied, rem, want);
                end
            end
        end
        if (errors) $fatal(1, "FAIL: %0d of %0d values wrong (CORE=%0d WIDTH=%0d STAGES=%0d)", errors, total, CORE, WIDTH, STAGES);
        if (CORE == 1) $write("PASS: mod6_popcount"); else $write("PASS: mod6_residue");
        $write(" WIDTH=%0d STAGES=%0d: %0d ", WIDTH, STAGES, total);
        if (EXHAUSTIVE) $display("values (every input) equal x %% 6");
        else            $display("values (directed + random) equal x %% 6");
        $finish;
    end
endmodule
