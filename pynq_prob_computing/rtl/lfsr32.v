// ============================================================
//  lfsr32.v  –  32-bit Fibonacci LFSR
//
//  다항식: x^32 + x^22 + x^2 + x + 1
//  탭(0-indexed): 31, 21, 1, 0
//  주기: 2^32 − 1  (씨드 0 금지)
// ============================================================
`timescale 1ns/1ps

module lfsr32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,    // 1이면 seed로 초기화
    input  wire [31:0] seed,    // 씨드 (0 금지, 0 입력 시 DEFAULT로 대체)
    input  wire        en,      // 1이면 다음 상태로 전진
    output reg  [31:0] q        // 현재 LFSR 상태
);

    wire feedback = q[31] ^ q[21] ^ q[1] ^ q[0];

    always @(posedge clk) begin
        if (!rst_n)
            q <= 32'hDEAD_BEEF;
        else if (load)
            q <= (seed == 32'd0) ? 32'hDEAD_BEEF : seed;
        else if (en)
            q <= {q[30:0], feedback};
    end

endmodule
