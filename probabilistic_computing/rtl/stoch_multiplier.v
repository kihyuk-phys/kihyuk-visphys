`timescale 1ns / 1ps
//============================================================================
// Stochastic Multiplier
//
// In unipolar stochastic computing, multiplication is a single AND gate:
//   P(out=1) = P(A=1) * P(B=1)
//
// For bipolar encoding, an XNOR gate is used:
//   P(out=1) corresponds to x*y in [-1,1]
//============================================================================
module stoch_multiplier (
    input  wire  a,           // stochastic input A
    input  wire  b,           // stochastic input B
    input  wire  bipolar,     // 0=unipolar (AND), 1=bipolar (XNOR)
    output wire  out
);

    wire unipolar_out = a & b;
    wire bipolar_out  = ~(a ^ b);   // XNOR

    assign out = bipolar ? bipolar_out : unipolar_out;

endmodule
