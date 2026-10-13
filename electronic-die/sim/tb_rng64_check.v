`timescale 1ns/1ps
// Self-checking testbench for the 64-cell CA RNG.
//   default    : rng64 (structural, electronic-die/rtl/verilog)
//   -DBEHAVIORAL: rng64_behavior (electronic-die/rtl/verilog-behavioral)
// Contract: docs/verification.md, section 1.
//   +states=<file>  expected states from model/ca_rng.py vectors (line 0 = seed)
//   +steps=<n>      number of CA steps to check (default 256)
module tb_rng64_check;
    parameter integer MAX_STEPS = 8192;

    reg         clk = 1'b0;
    reg         sel = 1'b0;
    reg  [63:0] seed;
    wire [63:0] rng_out;

    reg  [63:0]   expected [0:MAX_STEPS];
    reg  [1023:0] states_file;
    integer       steps = 256;
    integer       k;
    integer       errors = 0;

`ifdef BEHAVIORAL
    rng64_behavior dut (.clk(clk), .sel(sel), .seed(seed), .rng_out(rng_out));
`else
    rng64 dut (.seed(seed), .clk(clk), .sel(sel), .rng_out(rng_out));
`endif

    always #5 clk = ~clk;   // rising edges at 5, 15, 25, ... ns

    initial begin
        if (!$value$plusargs("states=%s", states_file))
            $fatal(1, "usage: +states=<file> [+steps=<n>]");
        if ($value$plusargs("steps=%d", steps) && steps > MAX_STEPS)
            $fatal(1, "steps=%0d exceeds MAX_STEPS=%0d", steps, MAX_STEPS);
        for (k = 0; k <= MAX_STEPS; k = k + 1) expected[k] = {64{1'bx}};
        $readmemb(states_file, expected, 0, steps);
        if (^expected[steps] === 1'bx)
            $fatal(1, "%0s has fewer than %0d+1 lines", states_file, steps);

        seed = expected[0];

        // Edge 1 samples sel=0 and loads the seed; every later edge advances.
        for (k = 1; k <= steps + 1; k = k + 1) begin
            @(negedge clk);
            if (rng_out !== expected[k-1]) begin
                errors = errors + 1;
                $display("FAIL edge %0d: rng_out=%064b expected=%064b", k, rng_out, expected[k-1]);
                if (errors >= 5) $fatal(1, "too many mismatches");
            end
            sel = 1'b1;
        end
        if (errors) $fatal(1, "FAIL: %0d mismatches", errors);
        $display("PASS: rng64 %0s, seed=%0d, %0d steps match the model",
                 `ifdef BEHAVIORAL "behavioral" `else "structural" `endif, seed, steps);
        $finish;
    end
endmodule
