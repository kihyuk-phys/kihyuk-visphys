`timescale 1ns / 1ps
//============================================================================
// p-bit (Probabilistic Bit) Module
//
// Implements a tunable probabilistic bit based on the model:
//   m_i = sgn( tanh(I_i) - r )
//
// Where:
//   I_i   = bias + sum(weights * inputs)  (input activation, signed)
//   r     = uniform random number in [-1, 1)
//   m_i   = output probabilistic bit (+1 or -1, encoded as 1 or 0)
//
// The tanh function is approximated using a piecewise-linear LUT.
// The random number r comes from an internal LFSR.
//============================================================================
module p_bit #(
    parameter DATA_W   = 8,          // data width for activation
    parameter NUM_IN   = 4,          // number of input p-bits
    parameter LFSR_W   = 16,
    parameter LFSR_SEED = 16'hACE1
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        en,
    input  wire signed [DATA_W-1:0]    bias,           // bias term
    input  wire signed [DATA_W-1:0]    weights [0:NUM_IN-1],  // weights
    input  wire        [NUM_IN-1:0]    p_in,           // input p-bit states
    output reg                         p_out           // output p-bit state
);

    // ---------------------------------------------------------------
    // 1) Compute activation I = bias + sum(w_j * m_j)
    //    m_j is +1 if p_in[j]=1, -1 if p_in[j]=0
    // ---------------------------------------------------------------
    integer j;
    reg signed [DATA_W+3:0] activation;  // extra bits for accumulation

    always @(*) begin
        activation = {{4{bias[DATA_W-1]}}, bias};  // sign-extend bias
        for (j = 0; j < NUM_IN; j = j + 1) begin
            if (p_in[j])
                activation = activation + {{4{weights[j][DATA_W-1]}}, weights[j]};
            else
                activation = activation - {{4{weights[j][DATA_W-1]}}, weights[j]};
        end
    end

    // ---------------------------------------------------------------
    // 2) Approximate tanh(I) using piecewise-linear approximation
    //    Output is in signed fixed-point Q1.(DATA_W-1) format
    //    Range: [-1, +1) mapped to [-(2^(DATA_W-1)), +(2^(DATA_W-1)-1)]
    // ---------------------------------------------------------------
    reg signed [DATA_W-1:0] tanh_out;
    localparam signed [DATA_W+3:0] SAT_POS = (1 <<< (DATA_W-1)) - 1;
    localparam signed [DATA_W+3:0] SAT_NEG = -(1 <<< (DATA_W-1));

    always @(*) begin
        if (activation > SAT_POS)
            tanh_out = SAT_POS[DATA_W-1:0];
        else if (activation < SAT_NEG)
            tanh_out = SAT_NEG[DATA_W-1:0];
        else
            tanh_out = activation[DATA_W-1:0];
    end

    // ---------------------------------------------------------------
    // 3) LFSR random number generator
    // ---------------------------------------------------------------
    wire [LFSR_W-1:0] rng_val;

    lfsr_rng #(
        .WIDTH (LFSR_W),
        .SEED  (LFSR_SEED)
    ) u_lfsr (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .rng_out (rng_val)
    );

    // Map LFSR output to signed random in same range as tanh_out
    wire signed [DATA_W-1:0] rand_signed = rng_val[DATA_W-1:0];

    // ---------------------------------------------------------------
    // 4) Compare: p_out = (tanh_out > rand_signed) ? 1 : 0
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            p_out <= 1'b0;
        else if (en)
            p_out <= (tanh_out > rand_signed) ? 1'b1 : 1'b0;
    end

endmodule
