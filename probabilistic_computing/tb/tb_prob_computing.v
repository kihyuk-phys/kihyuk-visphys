`timescale 1ns / 1ps
//============================================================================
// Testbench for Probabilistic Computing Modules
//
// Tests:
// 1) Stochastic multiplication accuracy
// 2) p-bit network sampling behavior
// 3) Stochastic adder verification
//============================================================================
module tb_prob_computing;

    // ---------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------
    parameter DATA_W  = 8;
    parameter COUNT_W = 8;
    parameter CLK_PERIOD = 10;  // 100 MHz

    // ---------------------------------------------------------------
    // Signals
    // ---------------------------------------------------------------
    reg                      clk;
    reg                      rst_n;
    reg                      en;

    // Stochastic multiplier
    reg  [DATA_W-1:0]        mul_a, mul_b;
    reg                      bipolar_mode;
    wire [COUNT_W-1:0]       mul_result;
    wire                     mul_done;

    // p-bit network
    reg signed [DATA_W-1:0]  pbit_bias [0:3];
    reg signed [DATA_W-1:0]  pbit_w01, pbit_w02, pbit_w12;
    reg signed [DATA_W-1:0]  pbit_w23, pbit_w13, pbit_w03;
    wire [3:0]               pbit_state;

    // Stochastic adder standalone test
    reg                      sa_a, sa_b;
    wire                     sa_out;

    // ---------------------------------------------------------------
    // Clock generation
    // ---------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------------------------------------------------------
    // DUT: Top module
    // ---------------------------------------------------------------
    prob_computing_top #(
        .DATA_W  (DATA_W),
        .COUNT_W (COUNT_W)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .en           (en),
        .mul_a        (mul_a),
        .mul_b        (mul_b),
        .bipolar_mode (bipolar_mode),
        .mul_result   (mul_result),
        .mul_done     (mul_done),
        .pbit_bias    (pbit_bias),
        .pbit_w01     (pbit_w01),
        .pbit_w02     (pbit_w02),
        .pbit_w12     (pbit_w12),
        .pbit_w23     (pbit_w23),
        .pbit_w13     (pbit_w13),
        .pbit_w03     (pbit_w03),
        .pbit_state   (pbit_state)
    );

    // ---------------------------------------------------------------
    // DUT: Standalone stochastic adder
    // ---------------------------------------------------------------
    stoch_adder #(
        .LFSR_SEED (16'hFACE)
    ) u_adder (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .a     (sa_a),
        .b     (sa_b),
        .out   (sa_out)
    );

    // ---------------------------------------------------------------
    // Test stimulus
    // ---------------------------------------------------------------
    integer i;
    integer done_count;
    real expected_product, actual_product;
    real error_pct;

    // p-bit state histogram
    integer pbit_histogram [0:15];  // 2^4 possible states

    initial begin
        // Initialize
        rst_n = 0;
        en    = 0;
        mul_a = 0;
        mul_b = 0;
        bipolar_mode = 0;
        sa_a = 0;
        sa_b = 0;

        for (i = 0; i < 4; i = i + 1) pbit_bias[i] = 0;
        pbit_w01 = 0; pbit_w02 = 0; pbit_w12 = 0;
        pbit_w23 = 0; pbit_w13 = 0; pbit_w03 = 0;

        for (i = 0; i < 16; i = i + 1) pbit_histogram[i] = 0;

        // Reset
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);
        en = 1;

        // ===========================================================
        // TEST 1: Stochastic Multiplication (Unipolar)
        //   A = 192/256 = 0.75
        //   B = 128/256 = 0.50
        //   Expected: 0.75 * 0.50 = 0.375 → ~96/256
        // ===========================================================
        $display("==================================================");
        $display("TEST 1: Stochastic Multiplication (Unipolar)");
        $display("  A = 192 (0.75), B = 128 (0.50)");
        $display("  Expected result ≈ 96 (0.375)");
        $display("==================================================");

        mul_a = 8'd192;   // 0.75
        mul_b = 8'd128;   // 0.50
        bipolar_mode = 0;

        // Wait for multiple measurement windows
        done_count = 0;
        while (done_count < 5) begin
            @(posedge clk);
            if (mul_done) begin
                done_count = done_count + 1;
                actual_product = mul_result;
                expected_product = 96.0;
                error_pct = (actual_product - expected_product) / expected_product * 100.0;
                $display("  Window %0d: result = %0d (%.3f), error = %.1f%%",
                         done_count, mul_result, mul_result / 256.0, error_pct);
            end
        end

        // ===========================================================
        // TEST 2: Stochastic Multiplication (different values)
        //   A = 64/256 = 0.25
        //   B = 64/256 = 0.25
        //   Expected: 0.25 * 0.25 = 0.0625 → ~16/256
        // ===========================================================
        $display("");
        $display("==================================================");
        $display("TEST 2: Stochastic Multiplication (0.25 x 0.25)");
        $display("  Expected result ≈ 16 (0.0625)");
        $display("==================================================");

        mul_a = 8'd64;
        mul_b = 8'd64;

        done_count = 0;
        while (done_count < 5) begin
            @(posedge clk);
            if (mul_done) begin
                done_count = done_count + 1;
                $display("  Window %0d: result = %0d (%.4f)",
                         done_count, mul_result, mul_result / 256.0);
            end
        end

        // ===========================================================
        // TEST 3: p-bit Network
        //   Configure a simple 4-node network with coupling weights
        //   and observe the state distribution
        // ===========================================================
        $display("");
        $display("==================================================");
        $display("TEST 3: p-bit Network (4 nodes, ferromagnetic coupling)");
        $display("==================================================");

        // Ferromagnetic coupling: positive weights encourage alignment
        pbit_bias[0] = 8'sd10;
        pbit_bias[1] = 8'sd0;
        pbit_bias[2] = 8'sd0;
        pbit_bias[3] = 8'sd0;
        pbit_w01 = 8'sd30;   // strong positive coupling
        pbit_w02 = 8'sd30;
        pbit_w12 = 8'sd30;
        pbit_w23 = 8'sd30;
        pbit_w13 = 8'sd30;
        pbit_w03 = 8'sd30;

        // Collect samples
        for (i = 0; i < 4096; i = i + 1) begin
            @(posedge clk);
            pbit_histogram[pbit_state] = pbit_histogram[pbit_state] + 1;
        end

        $display("  State histogram (4096 samples):");
        $display("  State  |  Count  |  Probability");
        $display("  -------|---------|-------------");
        for (i = 0; i < 16; i = i + 1) begin
            if (pbit_histogram[i] > 0)
                $display("  %4b  |  %5d  |  %.4f",
                         i[3:0], pbit_histogram[i], pbit_histogram[i] / 4096.0);
        end

        $display("  (With ferromagnetic coupling, states 0000 and 1111 should dominate)");

        // ===========================================================
        // TEST 4: p-bit Network (antiferromagnetic coupling)
        // ===========================================================
        $display("");
        $display("==================================================");
        $display("TEST 4: p-bit Network (antiferromagnetic coupling)");
        $display("==================================================");

        // Reset histogram
        for (i = 0; i < 16; i = i + 1) pbit_histogram[i] = 0;

        // Antiferromagnetic: negative weights encourage opposite states
        pbit_bias[0] = 8'sd0;
        pbit_bias[1] = 8'sd0;
        pbit_bias[2] = 8'sd0;
        pbit_bias[3] = 8'sd0;
        pbit_w01 = -8'sd30;
        pbit_w02 = -8'sd30;
        pbit_w12 = -8'sd30;
        pbit_w23 = -8'sd30;
        pbit_w13 = -8'sd30;
        pbit_w03 = -8'sd30;

        for (i = 0; i < 4096; i = i + 1) begin
            @(posedge clk);
            pbit_histogram[pbit_state] = pbit_histogram[pbit_state] + 1;
        end

        $display("  State histogram (4096 samples):");
        $display("  State  |  Count  |  Probability");
        $display("  -------|---------|-------------");
        for (i = 0; i < 16; i = i + 1) begin
            if (pbit_histogram[i] > 0)
                $display("  %4b  |  %5d  |  %.4f",
                         i[3:0], pbit_histogram[i], pbit_histogram[i] / 4096.0);
        end

        $display("  (With antiferromagnetic coupling on fully-connected graph,");
        $display("   frustrated states will show more uniform distribution)");

        // ===========================================================
        // Finish
        // ===========================================================
        $display("");
        $display("==================================================");
        $display("All tests completed.");
        $display("==================================================");
        #(CLK_PERIOD * 10);
        $finish;
    end

    // ---------------------------------------------------------------
    // Optional: VCD dump for waveform viewing
    // ---------------------------------------------------------------
    initial begin
        $dumpfile("prob_computing.vcd");
        $dumpvars(0, tb_prob_computing);
    end

endmodule
