`timescale 1ns/1ps
module tb_rng64;
    reg         clk;
    reg         sel;
    reg  [63:0] seed;
    wire [63:0] rng_out;
    integer input_file;
    integer output_file;
    integer scan_result;

    rng64 dut (
        .seed    (seed),
        .clk     (clk),
        .sel     (sel),
        .rng_out (rng_out)
    );

    initial begin
        clk = 1'b0;
        forever #50 clk = ~clk;
    end

    initial begin
        input_file = $fopen("source_data.txt", "r");
        scan_result = $fscanf(input_file, "%b", seed);
        $fclose(input_file);
        sel = 1'b0;
        #100 sel = 1'b1;
    end

    initial begin
        output_file = $fopen("output_data.txt", "w");
        #3250;
        $fclose(output_file);
        $finish;
    end

    always @(rng_out) begin
        if (^rng_out !== 1'bx)
            $fdisplay(output_file, "%064b", rng_out);
    end
endmodule
