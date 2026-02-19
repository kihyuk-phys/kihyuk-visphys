`timescale 1ns / 1ps
//============================================================================
// Stochastic-to-Binary Converter
//
// Counts the number of 1s in a stochastic bit stream over a window
// of 2^COUNT_W clock cycles, then outputs the binary probability.
//
// Result = count / 2^COUNT_W  (represented as COUNT_W-bit unsigned integer)
//
// A 'done' signal pulses high when a full measurement window completes.
//============================================================================
module stoch_to_binary #(
    parameter COUNT_W = 8    // counter width → window = 2^COUNT_W cycles
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire               stoch_in,       // stochastic bit stream
    output reg  [COUNT_W-1:0] bin_out,        // binary result
    output reg                done            // pulses when measurement done
);

    reg [COUNT_W-1:0] counter;    // cycle counter
    reg [COUNT_W-1:0] ones_count; // number of 1s observed

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter    <= {COUNT_W{1'b0}};
            ones_count <= {COUNT_W{1'b0}};
            bin_out    <= {COUNT_W{1'b0}};
            done       <= 1'b0;
        end else if (en) begin
            done <= 1'b0;

            if (counter == {COUNT_W{1'b1}}) begin
                // Window complete: output result and reset
                bin_out    <= ones_count + stoch_in;
                done       <= 1'b1;
                counter    <= {COUNT_W{1'b0}};
                ones_count <= {COUNT_W{1'b0}};
            end else begin
                counter    <= counter + 1'b1;
                ones_count <= ones_count + stoch_in;
            end
        end
    end

endmodule
