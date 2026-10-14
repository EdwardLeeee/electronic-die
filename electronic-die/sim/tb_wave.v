`timescale 1ns/1ps
// Waveform source for docs/img/die_waveform.png (make figures); not a check.
// The course die and the two-stage residue die run side by side from the
// same seed and the same en.  By contract 4 (docs/verification.md) the fast
// die shows the course die's sequence two clocks later while en is high.
//   +vcd=<file>   where to write the dump (default build/wave/die_wave.vcd)
module tb_wave;
    parameter [63:0]  SEED  = 64'd122059;
    parameter integer EDGES = 28;

    reg        clk = 1'b0;
    reg        en  = 1'b1;
    wire [2:0] course_result, fast_result;
    integer    k = 0;
    reg [1023:0] vcd_file;

    electronic_die      #(.SEED(SEED))                        course (.clk(clk), .en(en), .tossing_result(course_result));
    electronic_die_fast #(.SEED(SEED), .CORE(2), .STAGES(2)) fast   (.clk(clk), .en(en), .tossing_result(fast_result));

    always #5 clk = ~clk;

    // en by edge number: high for edges 1..14, low for 15..18, high again.
    // It changes on the falling edge, so every rising edge samples a settled value.
    always @(negedge clk)
        en <= !(k >= 14 && k < 18);

    // The picture is only worth drawing if it shows the contract, so check the
    // one relation it illustrates: with en high at edges k and k-2 (k >= 4),
    // fast after edge k equals course after edge k-2.
    reg [2:0] course_at [0:EDGES];
    reg       en_at     [0:EDGES];
    always @(posedge clk) begin
        k = k + 1;
        en_at[k] = en;
        #1 course_at[k] = course_result;
        $display("edge %0d en=%0d course=%0d fast=%0d", k, en, course_result, fast_result);
        if (k >= 4 && en_at[k] && en_at[k-2] && fast_result !== course_at[k-2])
            $fatal(1, "edge %0d: fast=%0d, course two edges earlier=%0d", k, fast_result, course_at[k-2]);
        if (k == EDGES) $finish;
    end

    initial begin
        if (!$value$plusargs("vcd=%s", vcd_file)) vcd_file = "build/wave/die_wave.vcd";
        $dumpfile(vcd_file);
        $dumpvars(0, clk, en, course_result, fast_result);
    end
endmodule
