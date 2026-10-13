module rng64 (
    input  wire [63:0] seed,
    input  wire        clk,
    input  wire        sel,
    output wire [63:0] rng_out
);
    genvar i;
    generate
        for (i = 0; i < 64; i = i + 1) begin : ca_generate
            localparam integer IM1 = (i == 0)  ? 63 : i - 1;
            localparam integer IP1 = (i == 63) ? 0  : i + 1;
            localparam integer IP2 = (i >= 62) ? i - 62 : i + 2;
            wire [3:0] adr;

            assign adr = {rng_out[i], rng_out[IM1], rng_out[IP2], rng_out[IP1]};

            ca_cell ca_array (
                .adr  (adr),
                .clk  (clk),
                .sel  (sel),
                .init (seed[i]),
                .y    (rng_out[i])
            );
        end
    endgenerate
endmodule
