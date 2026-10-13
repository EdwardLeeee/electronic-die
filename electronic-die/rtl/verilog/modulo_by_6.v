module modulo_by_6 (
    input  wire [63:0] rng_value,
    output wire [2:0]  die_value
);
    // +1 converts the range 0..5 into the die range 1..6.
    assign die_value = (rng_value % 6) + 1;
endmodule
