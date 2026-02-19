`timescale 1ns / 1ps
//============================================================================
// Stochastic Number Generator (SNG)
//
// Converts an N-bit binary number P to a stochastic bit stream.
// At each clock cycle, outputs 1 with probability P/(2^N).
//
// Method: Compare P against a uniform random number R from LFSR.
//   stoch_out = (P > R) ? 1 : 0
//
// For unipolar encoding: P in [0, 2^N-1] represents [0, 1)
//============================================================================
module stochastic_num_gen #(
    parameter N         = 8,             // binary input width
    parameter LFSR_SEED = 16'hBEEF
)(
    input  wire           clk,
    input  wire           rst_n,
    input  wire           en,
    input  wire [N-1:0]   bin_in,        // binary probability input
    output wire           stoch_out      // stochastic bit stream output
);

    wire [15:0] rng_val;

    lfsr_rng #(
        .WIDTH (16),
        .SEED  (LFSR_SEED)
    ) u_lfsr (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .rng_out (rng_val)
    );

    // Compare: stochastic bit = 1 if bin_in > random[N-1:0]
    assign stoch_out = (bin_in > rng_val[N-1:0]) ? 1'b1 : 1'b0;

endmodule
