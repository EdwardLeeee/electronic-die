`timescale 1ns/1ps
module tb_electronic_die;
    reg        clk;
    reg        en;
    wire [2:0] tossing_result;

    electronic_die dut (
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
