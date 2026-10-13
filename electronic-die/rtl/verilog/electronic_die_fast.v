// Electronic die with a replaceable, optionally pipelined mod-6 stage.
// Contract: docs/verification.md, section 4.
//
//   CORE   = 0: the original % operator (modulo_by_6); STAGES registers are
//               simply appended after it ("naive registered" control).
//   CORE   = 1: mod6_popcount (two popcount trees, then mod 3).
//   CORE   = 2: mod6_residue  (one tree of mod-3 adders over base-4 digits).
//   STAGES = pipeline registers between the CA state and result_reg.
//
// The CA free-runs exactly as in electronic_die.  The mod-6 pipeline is fed
// every clock; a valid bit travels with it so the pre-seed CA contents never
// reach the output.  en only gates the commit of the pipeline output into
// result_reg, so tossing_result follows the die sequence STAGES clocks late.
module electronic_die_fast (
    input  wire       clk,
    input  wire       en,
    output wire [2:0] tossing_result
);
    parameter [63:0]  SEED   = 64'd122059;
    parameter integer CORE   = 2;
    parameter integer STAGES = 2;

    reg         init_done  = 1'b0;
    reg  [2:0]  result_reg = 3'd1;
    wire [63:0] rng_value;
    wire [2:0]  die_value;          // 1..6, STAGES clocks behind rng_value

    rng64 rng_inst (
        .seed    (SEED),
        .clk     (clk),
        .sel     (init_done),
        .rng_out (rng_value)
    );

    genvar i;
    generate
        if (CORE == 0) begin : percent
            wire [2:0] die0;
            wire [3*(STAGES+1)-1:0] d;
            modulo_by_6 modulo_inst (.rng_value(rng_value), .die_value(die0));
            assign d[2:0] = die0;
            for (i = 1; i <= STAGES; i = i + 1) begin : delay
                reg [2:0] q = 3'd1;
                always @(posedge clk) q <= d[3*(i-1) +: 3];
                assign d[3*i +: 3] = q;
            end
            assign die_value = d[3*STAGES +: 3];
        end else if (CORE == 1) begin : popcount
            wire [2:0] rem;
            mod6_popcount #(.WIDTH(64), .STAGES(STAGES)) mod_inst (.clk(clk), .x(rng_value), .rem(rem));
            assign die_value = rem + 3'd1;
        end else begin : residue
            wire [2:0] rem;
            mod6_residue #(.WIDTH(64), .STAGES(STAGES)) mod_inst (.clk(clk), .x(rng_value), .rem(rem));
            assign die_value = rem + 3'd1;
        end
    endgenerate

    // valid[s] = 1 when the value s registers deep came from a loaded CA state.
    wire [STAGES:0] valid;
    assign valid[0] = init_done;
    generate
        for (i = 1; i <= STAGES; i = i + 1) begin : valid_delay
            reg q = 1'b0;
            always @(posedge clk) q <= valid[i-1];
            assign valid[i] = q;
        end
    endgenerate

    always @(posedge clk) begin
        if (!init_done)
            init_done <= 1'b1;
        if (en && valid[STAGES])
            result_reg <= die_value;
    end

    assign tossing_result = result_reg;
endmodule
