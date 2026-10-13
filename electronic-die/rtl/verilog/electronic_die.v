module electronic_die (
    input  wire       clk,
    input  wire       en,
    output wire [2:0] tossing_result
);
    parameter [63:0] SEED = 64'd122059;

    reg        init_done = 1'b0;
    reg [2:0]  result_reg = 3'd1;
    wire [63:0] rng_value;
    wire [2:0]  mod_value;

    rng64 rng_inst (
        .seed    (SEED),
        .clk     (clk),
        .sel     (init_done),
        .rng_out (rng_value)
    );

    modulo_by_6 modulo_inst (
        .rng_value (rng_value),
        .die_value (mod_value)
    );

    // The first rising edge loads the seed into the RNG.
    // Later, the RNG keeps running; en controls only the output register.
    always @(posedge clk) begin
        if (!init_done)
            init_done <= 1'b1;
        else if (en)
            result_reg <= mod_value;
    end

    assign tossing_result = result_reg;
endmodule
