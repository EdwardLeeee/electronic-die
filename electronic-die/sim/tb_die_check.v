`timescale 1ns/1ps
// Self-checking testbench for the electronic die (original timing).
//   default     : electronic_die (structural)
//   -DBEHAVIORAL: electronic_die_behavior
// Contract: docs/verification.md, section 2:
//   R[0] = R[1] = 1;  R[k] = en_k ? die(state[k-2]) : R[k-1]  for k >= 2
// where k counts rising edges and en_k is the value of en sampled at edge k.
//   -Ptb_die_check.SEED=64'd<seed>   must match the seed used for the vectors
//   +states=<file> +die=<file>       from model/ca_rng.py vectors
//   +steps=<n>                       edges to check (default 256)
module tb_die_check;
    parameter [63:0]  SEED      = 64'd122059;
    parameter integer MAX_STEPS = 8192;

    reg        clk = 1'b0;
    reg        en  = 1'b1;          // high from time 0: edge 1 must not update
    wire [2:0] tossing_result;

`ifdef BEHAVIORAL
    electronic_die_behavior #(.SEED(SEED)) dut (.clk(clk), .en(en), .tossing_result(tossing_result));
`else
    electronic_die          #(.SEED(SEED)) dut (.clk(clk), .en(en), .tossing_result(tossing_result));
`endif
    wire [63:0] rng_state = dut.rng_value;   // CA state, for diagnostics

    reg [63:0]   states [0:MAX_STEPS];
    reg [2:0]    die    [0:MAX_STEPS];
    reg [1023:0] states_file, die_file;
    integer      steps = 256;
    integer      k;
    integer      errors = 0;
    reg [2:0]    R;                // reference output after edge k
    reg          en_next;          // en to be sampled at edge k+1
    reg [15:0]   lfsr;

    always #5 clk = ~clk;

    // en schedule by edge number: 1..64 high, 65..96 low, 97..128 alternating,
    // then a 16-bit LFSR (x^16+x^14+x^13+x^11+1) so every seed sees a different pattern.
    function automatic [0:0] en_for_edge(input integer e);
        begin
            if (e <= 64)       en_for_edge = 1'b1;
            else if (e <= 96)  en_for_edge = 1'b0;
            else if (e <= 128) en_for_edge = e[0];
            else begin
                lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
                en_for_edge = lfsr[0];
            end
        end
    endfunction

    initial begin
        if (!$value$plusargs("states=%s", states_file) || !$value$plusargs("die=%s", die_file))
            $fatal(1, "usage: +states=<file> +die=<file> [+steps=<n>]");
        if ($value$plusargs("steps=%d", steps) && steps > MAX_STEPS)
            $fatal(1, "steps=%0d exceeds MAX_STEPS=%0d", steps, MAX_STEPS);
        for (k = 0; k <= MAX_STEPS; k = k + 1) begin states[k] = {64{1'bx}}; die[k] = 3'bxxx; end
        $readmemb(states_file, states, 0, steps);
        $readmemb(die_file, die, 0, steps);
        if (states[0] !== SEED)
            $fatal(1, "vector seed %0d does not match parameter SEED=%0d", states[0], SEED);
        if (^states[steps] === 1'bx || ^die[steps] === 1'bx)
            $fatal(1, "vector files have fewer than %0d+1 lines", steps);

        lfsr = SEED[15:0] ^ 16'hACE1;
        if (lfsr == 16'h0000) lfsr = 16'hACE1;
        R  = 3'd1;
        en = en_for_edge(1);

        for (k = 1; k <= steps; k = k + 1) begin
            @(negedge clk);                         // edge k has happened
            if (k >= 2 && en) R = die[k-2];         // en was sampled at edge k
            if (tossing_result !== R) begin
                errors = errors + 1;
                $display("FAIL edge %0d (en=%b): tossing_result=%0d expected=%0d", k, en, tossing_result, R);
            end
            if (tossing_result < 3'd1 || tossing_result > 3'd6) begin
                errors = errors + 1;
                $display("FAIL edge %0d: tossing_result=%b outside 1..6", k, tossing_result);
            end
            if (rng_state !== states[k-1]) begin
                errors = errors + 1;
                $display("FAIL edge %0d: CA state %064b expected %064b", k, rng_state, states[k-1]);
            end
            if (errors >= 5) $fatal(1, "too many mismatches");
            en = en_for_edge(k + 1);
        end
        if (errors) $fatal(1, "FAIL: %0d mismatches", errors);
        $display("PASS: electronic_die %0s, seed=%0d, %0d edges match the contract",
                 `ifdef BEHAVIORAL "behavioral" `else "structural" `endif, SEED, steps);
        $finish;
    end
endmodule
