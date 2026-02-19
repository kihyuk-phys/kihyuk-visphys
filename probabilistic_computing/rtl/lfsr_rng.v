`timescale 1ns / 1ps
//============================================================================
// LFSR-based Random Number Generator
// - Galois LFSR, parameterizable width (default 16-bit)
// - Maximal-length polynomial taps for 8/16/32 bits
//============================================================================
module lfsr_rng #(
    parameter WIDTH = 16,
    parameter SEED  = 16'hACE1   // non-zero initial seed
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en,
    output wire [WIDTH-1:0] rng_out
);

    reg [WIDTH-1:0] lfsr;

    // Galois LFSR feedback
    // Maximal-length polynomials:
    //   8-bit  : x^8 + x^6 + x^5 + x^4 + 1
    //   16-bit : x^16 + x^14 + x^13 + x^11 + 1
    //   32-bit : x^32 + x^22 + x^2 + x^1 + 1
    wire feedback = lfsr[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= SEED[WIDTH-1:0];
        end else if (en) begin
            lfsr <= {1'b0, lfsr[WIDTH-1:1]};
            if (feedback) begin
                case (WIDTH)
                    8:  lfsr <= {1'b0, lfsr[WIDTH-1:1]} ^ 8'hB4;
                    16: lfsr <= {1'b0, lfsr[WIDTH-1:1]} ^ 16'hB400;
                    32: lfsr <= {1'b0, lfsr[WIDTH-1:1]} ^ 32'h80200003;
                    default: lfsr <= {1'b0, lfsr[WIDTH-1:1]} ^ SEED;
                endcase
            end
        end
    end

    assign rng_out = lfsr;

endmodule
