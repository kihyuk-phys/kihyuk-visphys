// ============================================================
//  axi4l_slave.v  –  AXI4-Lite 슬레이브 레지스터 파일
//
//  레지스터 맵 (4바이트 정렬, 4바이트 간격)
//  ─────────────────────────────────────────────────────────
//  0x000  ap_ctrl          [0]=start(W), [1]=done(R), [2]=idle(R)
//  0x004  status           [1:0] RO  0=idle 1=anneal 2=meas 3=done
//  0x008  n_anneal_sweeps  RW  uint32
//  0x00C  n_meas_sweeps    RW  uint32
//  0x010  T_final_raw      RW  [15:0]  T × 2^12  (ap_ufixed<16,4>)
//  0x014  n_anneal_steps   RW  uint32  (베타 증가 단계 수)
//  0x018  lfsr_seed        RW  uint32  (0 금지)
//  0x01C  T_step_raw       RW  uint32  T_step × 2^32 (드라이버가 계산)
//  0x020–0x11C  J_flat[64] RW  int32 × 64
//  0x120–0x13C  h_field[8] RW  int32 × 8
//  0x140  sample_buf_addr  RW  uint32 (물리 주소 하위 32-bit)
//  0x144  hist_buf_addr    RW  uint32 (물리 주소 하위 32-bit)
//
//  주소 폭: 9-bit (0x000 ~ 0x1FF, 512바이트)
// ============================================================
`timescale 1ns/1ps

module axi4l_slave #(
    parameter ADDR_W = 9,
    parameter DATA_W = 32
)(
    input  wire              clk,
    input  wire              rst_n,

    // ── AXI4-Lite 슬레이브 포트 ────────────────────────────
    input  wire [ADDR_W-1:0] s_awaddr,
    input  wire              s_awvalid,
    output reg               s_awready,

    input  wire [DATA_W-1:0] s_wdata,
    input  wire [3:0]        s_wstrb,
    input  wire              s_wvalid,
    output reg               s_wready,

    output reg  [1:0]        s_bresp,
    output reg               s_bvalid,
    input  wire              s_bready,

    input  wire [ADDR_W-1:0] s_araddr,
    input  wire              s_arvalid,
    output reg               s_arready,

    output reg  [DATA_W-1:0] s_rdata,
    output reg  [1:0]        s_rresp,
    output reg               s_rvalid,
    input  wire              s_rready,

    // ── 레지스터 출력 (SA 엔진으로) ────────────────────────
    output reg               ap_start,      // 1클럭 펄스
    input  wire              ap_done,        // SA 엔진 완료 신호
    input  wire [1:0]        status,         // SA 엔진 상태

    output reg  [31:0]       n_anneal_sweeps,
    output reg  [31:0]       n_meas_sweeps,
    output reg  [15:0]       T_final_raw,
    output reg  [31:0]       n_anneal_steps,
    output reg  [31:0]       lfsr_seed,
    output reg  [31:0]       T_step_raw,

    output reg  [31:0]       J_flat   [0:63],
    output reg  [31:0]       h_field  [0:7],
    output reg  [31:0]       sample_buf_addr,
    output reg  [31:0]       hist_buf_addr
);

    // ── 내부 상태 ─────────────────────────────────────────
    reg [ADDR_W-1:0] aw_addr_r;
    reg              aw_valid_r;   // AW 채널 수신 완료
    reg [ADDR_W-1:0] ar_addr_r;

    // ── ap_done 래치 (읽기 후 클리어) ────────────────────
    reg ap_done_latch;
    reg ap_idle;

    always @(posedge clk) begin
        if (!rst_n) begin
            ap_done_latch <= 1'b0;
            ap_idle       <= 1'b1;
        end else begin
            if (ap_done)        ap_done_latch <= 1'b1;
            if (ap_start)       ap_done_latch <= 1'b0;
            ap_idle <= (status == 2'd0);
        end
    end

    // ── 쓰기 채널 ─────────────────────────────────────────
    integer wi;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_awready    <= 1'b0;
            s_wready     <= 1'b0;
            s_bvalid     <= 1'b0;
            s_bresp      <= 2'b00;
            aw_valid_r   <= 1'b0;
            ap_start     <= 1'b0;
            // 기본값
            n_anneal_sweeps <= 32'd1000;
            n_meas_sweeps   <= 32'd500;
            T_final_raw     <= 16'd41;    // 0.01 × 2^12
            n_anneal_steps  <= 32'd20;
            lfsr_seed       <= 32'h12345678;
            T_step_raw      <= 32'd42950; // 0.01/1000 × 2^32 ≈ 42950
            sample_buf_addr <= 32'd0;
            hist_buf_addr   <= 32'd0;
            for (wi = 0; wi < 64; wi = wi+1) J_flat[wi]  <= 32'd0;
            for (wi = 0; wi <  8; wi = wi+1) h_field[wi] <= 32'd0;
        end else begin
            ap_start <= 1'b0;  // 기본 0 (펄스)

            // AW 수신
            s_awready <= 1'b0;
            if (s_awvalid && !aw_valid_r) begin
                aw_addr_r  <= s_awaddr;
                aw_valid_r <= 1'b1;
                s_awready  <= 1'b1;
            end

            // W 수신 + 레지스터 쓰기
            s_wready <= 1'b0;
            if (s_wvalid && aw_valid_r && !s_bvalid) begin
                s_wready   <= 1'b1;
                aw_valid_r <= 1'b0;

                // 주소 디코딩 (word address = aw_addr_r[ADDR_W-1:2])
                case (aw_addr_r[8:2])
                    7'd0: begin   // 0x000 ap_ctrl
                        if (s_wdata[0]) ap_start <= 1'b1;
                    end
                    // 0x004 status: RO, 쓰기 무시
                    7'd2: n_anneal_sweeps <= s_wdata;         // 0x008
                    7'd3: n_meas_sweeps   <= s_wdata;         // 0x00C
                    7'd4: T_final_raw     <= s_wdata[15:0];   // 0x010
                    7'd5: n_anneal_steps  <= s_wdata;         // 0x014
                    7'd6: lfsr_seed       <= (s_wdata==32'd0) ? 32'h1 : s_wdata; // 0x018
                    7'd7: T_step_raw      <= s_wdata;         // 0x01C
                    // 0x020–0x11C: J_flat[0..63] (word index 8..71)
                    default: begin
                        if (aw_addr_r[8:2] >= 7'd8 && aw_addr_r[8:2] <= 7'd71)
                            J_flat[aw_addr_r[8:2] - 7'd8] <= s_wdata;
                        // 0x120–0x13C: h_field[0..7] (word index 72..79)
                        else if (aw_addr_r[8:2] >= 7'd72 && aw_addr_r[8:2] <= 7'd79)
                            h_field[aw_addr_r[8:2] - 7'd72] <= s_wdata;
                        // 0x140: sample_buf_addr (word index 80)
                        else if (aw_addr_r[8:2] == 7'd80)
                            sample_buf_addr <= s_wdata;
                        // 0x144: hist_buf_addr (word index 81)
                        else if (aw_addr_r[8:2] == 7'd81)
                            hist_buf_addr   <= s_wdata;
                    end
                endcase

                // B 채널 응답 준비
                s_bvalid <= 1'b1;
                s_bresp  <= 2'b00;
            end

            // B 응답 핸드셰이크
            if (s_bvalid && s_bready)
                s_bvalid <= 1'b0;
        end
    end

    // ── 읽기 채널 ─────────────────────────────────────────
    always @(posedge clk) begin
        if (!rst_n) begin
            s_arready <= 1'b0;
            s_rvalid  <= 1'b0;
            s_rresp   <= 2'b00;
            s_rdata   <= 32'd0;
        end else begin
            s_arready <= 1'b0;

            if (s_arvalid && !s_rvalid) begin
                ar_addr_r <= s_araddr;
                s_arready <= 1'b1;
                s_rvalid  <= 1'b1;
                s_rresp   <= 2'b00;

                case (s_araddr[8:2])
                    7'd0: s_rdata <= {29'd0, ap_idle, ap_done_latch, 1'b0};  // ap_ctrl
                    7'd1: s_rdata <= {30'd0, status};                         // status
                    7'd2: s_rdata <= n_anneal_sweeps;
                    7'd3: s_rdata <= n_meas_sweeps;
                    7'd4: s_rdata <= {16'd0, T_final_raw};
                    7'd5: s_rdata <= n_anneal_steps;
                    7'd6: s_rdata <= lfsr_seed;
                    7'd7: s_rdata <= T_step_raw;
                    default: begin
                        if (s_araddr[8:2] >= 7'd8 && s_araddr[8:2] <= 7'd71)
                            s_rdata <= J_flat[s_araddr[8:2] - 7'd8];
                        else if (s_araddr[8:2] >= 7'd72 && s_araddr[8:2] <= 7'd79)
                            s_rdata <= h_field[s_araddr[8:2] - 7'd72];
                        else if (s_araddr[8:2] == 7'd80)
                            s_rdata <= sample_buf_addr;
                        else if (s_araddr[8:2] == 7'd81)
                            s_rdata <= hist_buf_addr;
                        else
                            s_rdata <= 32'd0;
                    end
                endcase
            end

            if (s_rvalid && s_rready)
                s_rvalid <= 1'b0;
        end
    end

endmodule
