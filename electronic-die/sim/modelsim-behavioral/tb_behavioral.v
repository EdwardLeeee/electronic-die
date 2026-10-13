`timescale 1ns/1ps
module tb_rng64_behavior;
    reg         clk;
    reg         sel;
    reg  [63:0] seed;
    wire [63:0] rng_out;
    integer output_file;
    integer count;

    rng64_behavior dut (
        .clk     (clk),
        .sel     (sel),
        .seed    (seed),
        .rng_out (rng_out)
    );

    initial begin
        clk = 1'b0;
        forever #50 clk = ~clk;
    end

    initial begin
        seed = 64'd122059;
        sel = 1'b0;
        count = 0;
        output_file = $fopen("rng_output_verilog.txt", "w");
        #100 sel = 1'b1;
    end

    always @(posedge clk) begin
        if (sel && count < 32) begin
            $fdisplay(output_file, "%064b", rng_out);
            count = count + 1;
            if (count == 32) begin
                $fclose(output_file);
                #10 $finish;
            end
        end
    end
endmodule

module tb_electronic_die_behavior;
    reg        clk;
    reg        en;
    wire [2:0] tossing_result;

    electronic_die_behavior dut (
        .clk            (clk),
        .en             (en),
        .tossing_result (tossing_result)
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    initial begin
        en = 1'b0;
        #35  en = 1'b1;
        #80  en = 1'b0;
        #60  en = 1'b1;
        #80  en = 1'b0;
        #65  $finish;
    end
endmodule
