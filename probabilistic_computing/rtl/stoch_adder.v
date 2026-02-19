`timescale 1ns / 1ps
//============================================================================
// Stochastic Scaled Adder
//
// Uses a 2:1 MUX to compute scaled addition:
//   P(out=1) = sel * P(A=1) + (1-sel) * P(B=1)
//
// When sel has P(sel=1) = 0.5 (random coin flip), this computes:
//   P(out) = (P(A) + P(B)) / 2
//
// This is the fundamental addition operation in stochastic computing.
// The output is scaled by 1/2 to stay within [0,1].
//============================================================================
module stoch_adder #(
    parameter LFSR_SEED = 16'hCAFE
)(
    input  wire  clk,
    input  wire  rst_n,
    input  wire  en,
    input  wire  a,           // stochastic input A
    input  wire  b,           // stochastic input B
    output wire  out          // stochastic output = (A + B) / 2
);

    // Generate a random select signal with P=0.5
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

    wire sel = rng_val[0];   // P(sel=1) ≈ 0.5 for maximal-length LFSR

    // MUX-based scaled addition
    assign out = sel ? a : b;

endmodule
