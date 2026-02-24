// ============================================================
//  axi4_wr_master.v  –  AXI4 단일 비트(single-beat) 쓰기 마스터
//
//  사용처:
//    sample_buf 쓰기  (스윕 결과 1바이트)
//    hist_buf   쓰기  (히스토그램 256 × uint32)
//
//  동작:
//    wr_req ↑  → AW 채널 전송 → W 채널 전송 → B 채널 수신
//            → wr_done ↑ (1클럭 펄스)
//
//  AR/R 채널은 사용하지 않으므로 타이오프(tie-off) 처리.
// ============================================================
`timescale 1ns/1ps

module axi4_wr_master (
    input  wire        clk,
    input  wire        rst_n,

    // ── 사용자 인터페이스 ──────────────────────────────────
    input  wire        wr_req,      // 1클럭 펄스: 쓰기 요청
    input  wire [31:0] wr_addr,     // 대상 물리 주소
    input  wire [31:0] wr_data,     // 쓸 데이터
    input  wire [3:0]  wr_strb,     // 바이트 인에이블 (4'b1111 = 전체 4바이트)
    output reg         wr_done,     // 1클럭 펄스: 쓰기 완료

    // ── AXI4 쓰기 주소 채널 ───────────────────────────────
    output reg  [31:0] m_awaddr,
    output reg  [7:0]  m_awlen,     // 0 = 단일 비트
    output reg  [2:0]  m_awsize,    // 2 = 4바이트
    output reg  [1:0]  m_awburst,   // 01 = INCR
    output reg         m_awvalid,
    input  wire        m_awready,

    // ── AXI4 쓰기 데이터 채널 ────────────────────────────
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wstrb,
    output reg         m_wlast,
    output reg         m_wvalid,
    input  wire        m_wready,

    // ── AXI4 쓰기 응답 채널 ──────────────────────────────
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output reg         m_bready,

    // ── AXI4 읽기 채널 (사용 안 함 – 타이오프) ───────────
    output wire [31:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready
);

    // 읽기 채널 타이오프
    assign m_araddr  = 32'd0;
    assign m_arlen   = 8'd0;
    assign m_arsize  = 3'd2;
    assign m_arburst = 2'b01;
    assign m_arvalid = 1'b0;
    assign m_rready  = 1'b0;

    // ── 상태 머신 ─────────────────────────────────────────
    localparam S_IDLE = 3'd0;
    localparam S_AW   = 3'd1;   // AW 채널 전송 대기
    localparam S_W    = 3'd2;   // W  채널 전송 대기
    localparam S_B    = 3'd3;   // B  채널(응답) 대기
    localparam S_DONE = 3'd4;   // 완료 펄스 1클럭

    reg [2:0] state;
    reg [31:0] addr_r, data_r;
    reg [3:0]  strb_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            wr_done   <= 1'b0;
            m_awvalid <= 1'b0;
            m_wvalid  <= 1'b0;
            m_bready  <= 1'b0;
            m_wlast   <= 1'b0;
        end else begin
            wr_done <= 1'b0;  // 기본 0

            case (state)

                S_IDLE: begin
                    if (wr_req) begin
                        addr_r    <= wr_addr;
                        data_r    <= wr_data;
                        strb_r    <= wr_strb;
                        // AW + W 동시 전송 시도
                        m_awaddr  <= wr_addr;
                        m_awlen   <= 8'd0;
                        m_awsize  <= 3'd2;
                        m_awburst <= 2'b01;
                        m_awvalid <= 1'b1;
                        m_wdata   <= wr_data;
                        m_wstrb   <= wr_strb;
                        m_wlast   <= 1'b1;
                        m_wvalid  <= 1'b1;
                        state     <= S_AW;
                    end
                end

                S_AW: begin
                    // AW 핸드셰이크 완료 대기
                    if (m_awready && m_awvalid) begin
                        m_awvalid <= 1'b0;
                        if (m_wready && m_wvalid) begin
                            // W도 이미 완료
                            m_wvalid <= 1'b0;
                            m_wlast  <= 1'b0;
                            m_bready <= 1'b1;
                            state    <= S_B;
                        end else begin
                            state <= S_W;
                        end
                    end else if (m_wready && m_wvalid) begin
                        // W 먼저 완료
                        m_wvalid <= 1'b0;
                        m_wlast  <= 1'b0;
                        // AW 대기 계속
                    end
                end

                S_W: begin
                    if (m_wready && m_wvalid) begin
                        m_wvalid <= 1'b0;
                        m_wlast  <= 1'b0;
                        m_bready <= 1'b1;
                        state    <= S_B;
                    end
                end

                S_B: begin
                    if (m_bvalid && m_bready) begin
                        m_bready <= 1'b0;
                        wr_done  <= 1'b1;
                        state    <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
