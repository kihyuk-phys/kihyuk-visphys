`timescale 1ns / 1ps
//============================================================================
// Probabilistic Computing Top Module
//
// Demonstrates two key concepts:
// 1) Stochastic multiplication: A * B using stochastic bit streams
// 2) p-bit network: 4 interconnected probabilistic bits
//
// Inputs:  8-bit binary values A and B for stochastic multiplier
//          Bias and weights for p-bit network
// Outputs: 8-bit binary result of stochastic multiplication
//          4-bit p-bit network state
//============================================================================
module prob_computing_top #(
    parameter DATA_W  = 8,
    parameter COUNT_W = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     en,

    // Stochastic multiplier interface
    input  wire [DATA_W-1:0]        mul_a,          // operand A (binary)
    input  wire [DATA_W-1:0]        mul_b,          // operand B (binary)
    input  wire                     bipolar_mode,   // 0=unipolar, 1=bipolar
    output wire [COUNT_W-1:0]       mul_result,     // multiplication result (binary)
    output wire                     mul_done,       // result valid

    // p-bit network interface
    input  wire signed [DATA_W-1:0] pbit_bias  [0:3],  // bias for each p-bit
    input  wire signed [DATA_W-1:0] pbit_w01,           // weight between p-bit 0 and 1
    input  wire signed [DATA_W-1:0] pbit_w02,           // weight between p-bit 0 and 2
    input  wire signed [DATA_W-1:0] pbit_w12,           // weight between p-bit 1 and 2
    input  wire signed [DATA_W-1:0] pbit_w23,           // weight between p-bit 2 and 3
    input  wire signed [DATA_W-1:0] pbit_w13,           // weight between p-bit 1 and 3
    input  wire signed [DATA_W-1:0] pbit_w03,           // weight between p-bit 0 and 3
    output wire [3:0]               pbit_state          // 4 p-bit output states
);

    // ===================================================================
    // PART 1: Stochastic Multiplier Pipeline
    // Binary → Stochastic → Multiply → Stochastic-to-Binary
    // ===================================================================

    // SNG for operand A
    wire stoch_a;
    stochastic_num_gen #(
        .N         (DATA_W),
        .LFSR_SEED (16'hACE1)
    ) u_sng_a (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .bin_in    (mul_a),
        .stoch_out (stoch_a)
    );

    // SNG for operand B (different seed for independence)
    wire stoch_b;
    stochastic_num_gen #(
        .N         (DATA_W),
        .LFSR_SEED (16'hBEEF)
    ) u_sng_b (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .bin_in    (mul_b),
        .stoch_out (stoch_b)
    );

    // Stochastic multiplier
    wire stoch_product;
    stoch_multiplier u_mul (
        .a       (stoch_a),
        .b       (stoch_b),
        .bipolar (bipolar_mode),
        .out     (stoch_product)
    );

    // Convert stochastic product back to binary
    stoch_to_binary #(
        .COUNT_W (COUNT_W)
    ) u_s2b (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (en),
        .stoch_in (stoch_product),
        .bin_out  (mul_result),
        .done     (mul_done)
    );

    // ===================================================================
    // PART 2: 4-node p-bit Network (fully connected)
    // Each p-bit receives inputs from all other p-bits
    // ===================================================================

    wire [3:0] pbit_out;
    assign pbit_state = pbit_out;

    // p-bit 0: connected to p-bits 1, 2, 3
    wire signed [DATA_W-1:0] w0 [0:2];
    assign w0[0] = pbit_w01;
    assign w0[1] = pbit_w02;
    assign w0[2] = pbit_w03;

    p_bit #(
        .DATA_W    (DATA_W),
        .NUM_IN    (3),
        .LFSR_SEED (16'h1234)
    ) u_pbit0 (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .bias    (pbit_bias[0]),
        .weights (w0),
        .p_in    ({pbit_out[3], pbit_out[2], pbit_out[1]}),
        .p_out   (pbit_out[0])
    );

    // p-bit 1: connected to p-bits 0, 2, 3
    wire signed [DATA_W-1:0] w1 [0:2];
    assign w1[0] = pbit_w01;
    assign w1[1] = pbit_w12;
    assign w1[2] = pbit_w13;

    p_bit #(
        .DATA_W    (DATA_W),
        .NUM_IN    (3),
        .LFSR_SEED (16'h5678)
    ) u_pbit1 (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .bias    (pbit_bias[1]),
        .weights (w1),
        .p_in    ({pbit_out[3], pbit_out[2], pbit_out[0]}),
        .p_out   (pbit_out[1])
    );

    // p-bit 2: connected to p-bits 0, 1, 3
    wire signed [DATA_W-1:0] w2 [0:2];
    assign w2[0] = pbit_w02;
    assign w2[1] = pbit_w12;
    assign w2[2] = pbit_w23;

    p_bit #(
        .DATA_W    (DATA_W),
        .NUM_IN    (3),
        .LFSR_SEED (16'h9ABC)
    ) u_pbit2 (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .bias    (pbit_bias[2]),
        .weights (w2),
        .p_in    ({pbit_out[3], pbit_out[1], pbit_out[0]}),
        .p_out   (pbit_out[2])
    );

    // p-bit 3: connected to p-bits 0, 1, 2
    wire signed [DATA_W-1:0] w3 [0:2];
    assign w3[0] = pbit_w03;
    assign w3[1] = pbit_w13;
    assign w3[2] = pbit_w23;

    p_bit #(
        .DATA_W    (DATA_W),
        .NUM_IN    (3),
        .LFSR_SEED (16'hDEF0)
    ) u_pbit3 (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .bias    (pbit_bias[3]),
        .weights (w3),
        .p_in    ({pbit_out[2], pbit_out[1], pbit_out[0]}),
        .p_out   (pbit_out[3])
    );

endmodule
