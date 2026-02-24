// ============================================================
//  ising_core.v  –  탑레벨 (AXI 래퍼 + 서브모듈 연결)
//
//  포트 요약
//  ─────────────────────────────────────────────────────────
//  ap_clk / ap_rst_n        : 100 MHz 클럭, 액티브-로우 리셋
//  s_axi_ctrl_*             : AXI4-Lite 슬레이브 (레지스터 접근)
//  m_axi_gmem0_*            : AXI4 마스터 (sample_buf 쓰기)
//  m_axi_gmem1_*            : AXI4 마스터 (hist_buf 쓰기)
//
//  Vivado Block Design 연결:
//    PS7 M_AXI_GP0 → AXI IC → s_axi_ctrl
//    PS7 S_AXI_HP0 ← SC ← m_axi_gmem0
//    PS7 S_AXI_HP1 ← SC ← m_axi_gmem1
// ============================================================
`timescale 1ns/1ps

module ising_core (
    input  wire        ap_clk,
    input  wire        ap_rst_n,

    // ── AXI4-Lite 슬레이브 (ctrl) ─────────────────────────
    input  wire [8:0]  s_axi_ctrl_awaddr,
    input  wire        s_axi_ctrl_awvalid,
    output wire        s_axi_ctrl_awready,
    input  wire [31:0] s_axi_ctrl_wdata,
    input  wire [3:0]  s_axi_ctrl_wstrb,
    input  wire        s_axi_ctrl_wvalid,
    output wire        s_axi_ctrl_wready,
    output wire [1:0]  s_axi_ctrl_bresp,
    output wire        s_axi_ctrl_bvalid,
    input  wire        s_axi_ctrl_bready,
    input  wire [8:0]  s_axi_ctrl_araddr,
    input  wire        s_axi_ctrl_arvalid,
    output wire        s_axi_ctrl_arready,
    output wire [31:0] s_axi_ctrl_rdata,
    output wire [1:0]  s_axi_ctrl_rresp,
    output wire        s_axi_ctrl_rvalid,
    input  wire        s_axi_ctrl_rready,

    // ── AXI4 마스터 0 (gmem0 = sample_buf) ───────────────
    output wire [31:0] m_axi_gmem0_awaddr,
    output wire [7:0]  m_axi_gmem0_awlen,
    output wire [2:0]  m_axi_gmem0_awsize,
    output wire [1:0]  m_axi_gmem0_awburst,
    output wire        m_axi_gmem0_awvalid,
    input  wire        m_axi_gmem0_awready,
    output wire [31:0] m_axi_gmem0_wdata,
    output wire [3:0]  m_axi_gmem0_wstrb,
    output wire        m_axi_gmem0_wlast,
    output wire        m_axi_gmem0_wvalid,
    input  wire        m_axi_gmem0_wready,
    input  wire [1:0]  m_axi_gmem0_bresp,
    input  wire        m_axi_gmem0_bvalid,
    output wire        m_axi_gmem0_bready,
    output wire [31:0] m_axi_gmem0_araddr,
    output wire [7:0]  m_axi_gmem0_arlen,
    output wire [2:0]  m_axi_gmem0_arsize,
    output wire [1:0]  m_axi_gmem0_arburst,
    output wire        m_axi_gmem0_arvalid,
    input  wire        m_axi_gmem0_arready,
    input  wire [31:0] m_axi_gmem0_rdata,
    input  wire [1:0]  m_axi_gmem0_rresp,
    input  wire        m_axi_gmem0_rlast,
    input  wire        m_axi_gmem0_rvalid,
    output wire        m_axi_gmem0_rready,

    // ── AXI4 마스터 1 (gmem1 = hist_buf) ─────────────────
    output wire [31:0] m_axi_gmem1_awaddr,
    output wire [7:0]  m_axi_gmem1_awlen,
    output wire [2:0]  m_axi_gmem1_awsize,
    output wire [1:0]  m_axi_gmem1_awburst,
    output wire        m_axi_gmem1_awvalid,
    input  wire        m_axi_gmem1_awready,
    output wire [31:0] m_axi_gmem1_wdata,
    output wire [3:0]  m_axi_gmem1_wstrb,
    output wire        m_axi_gmem1_wlast,
    output wire        m_axi_gmem1_wvalid,
    input  wire        m_axi_gmem1_wready,
    input  wire [1:0]  m_axi_gmem1_bresp,
    input  wire        m_axi_gmem1_bvalid,
    output wire        m_axi_gmem1_bready,
    output wire [31:0] m_axi_gmem1_araddr,
    output wire [7:0]  m_axi_gmem1_arlen,
    output wire [2:0]  m_axi_gmem1_arsize,
    output wire [1:0]  m_axi_gmem1_arburst,
    output wire        m_axi_gmem1_arvalid,
    input  wire        m_axi_gmem1_arready,
    input  wire [31:0] m_axi_gmem1_rdata,
    input  wire [1:0]  m_axi_gmem1_rresp,
    input  wire        m_axi_gmem1_rlast,
    input  wire        m_axi_gmem1_rvalid,
    output wire        m_axi_gmem1_rready
);

    // ====================================================
    //  내부 신호 (레지스터 파일 → SA 엔진)
    // ====================================================
    wire        ap_start;
    wire        ap_done;
    wire [1:0]  status;

    wire [31:0] n_anneal_sweeps;
    wire [31:0] n_meas_sweeps;
    wire [15:0] T_final_raw;
    wire [31:0] n_anneal_steps;
    wire [31:0] lfsr_seed;
    wire [31:0] T_step_raw;
    wire [31:0] J_flat  [0:63];
    wire [31:0] h_field [0:7];
    wire [31:0] sample_buf_addr;
    wire [31:0] hist_buf_addr;

    // SA 엔진 → AXI 마스터 (sample_buf)
    wire        s_wr_req;
    wire [31:0] s_wr_addr;
    wire [31:0] s_wr_data;
    wire [3:0]  s_wr_strb;
    wire        s_wr_done;

    // SA 엔진 → AXI 마스터 (hist_buf)
    wire        h_wr_req;
    wire [31:0] h_wr_addr;
    wire [31:0] h_wr_data;
    wire [3:0]  h_wr_strb;
    wire        h_wr_done;

    // ====================================================
    //  AXI4-Lite 슬레이브 (레지스터 파일)
    // ====================================================
    axi4l_slave #(.ADDR_W(9), .DATA_W(32)) u_regs (
        .clk            (ap_clk),
        .rst_n          (ap_rst_n),
        .s_awaddr       (s_axi_ctrl_awaddr),
        .s_awvalid      (s_axi_ctrl_awvalid),
        .s_awready      (s_axi_ctrl_awready),
        .s_wdata        (s_axi_ctrl_wdata),
        .s_wstrb        (s_axi_ctrl_wstrb),
        .s_wvalid       (s_axi_ctrl_wvalid),
        .s_wready       (s_axi_ctrl_wready),
        .s_bresp        (s_axi_ctrl_bresp),
        .s_bvalid       (s_axi_ctrl_bvalid),
        .s_bready       (s_axi_ctrl_bready),
        .s_araddr       (s_axi_ctrl_araddr),
        .s_arvalid      (s_axi_ctrl_arvalid),
        .s_arready      (s_axi_ctrl_arready),
        .s_rdata        (s_axi_ctrl_rdata),
        .s_rresp        (s_axi_ctrl_rresp),
        .s_rvalid       (s_axi_ctrl_rvalid),
        .s_rready       (s_axi_ctrl_rready),
        .ap_start       (ap_start),
        .ap_done        (ap_done),
        .status         (status),
        .n_anneal_sweeps(n_anneal_sweeps),
        .n_meas_sweeps  (n_meas_sweeps),
        .T_final_raw    (T_final_raw),
        .n_anneal_steps (n_anneal_steps),
        .lfsr_seed      (lfsr_seed),
        .T_step_raw     (T_step_raw),
        .J_flat         (J_flat),
        .h_field        (h_field),
        .sample_buf_addr(sample_buf_addr),
        .hist_buf_addr  (hist_buf_addr)
    );

    // ====================================================
    //  SA 엔진
    // ====================================================
    sa_engine u_engine (
        .clk            (ap_clk),
        .rst_n          (ap_rst_n),
        .ap_start       (ap_start),
        .ap_done        (ap_done),
        .status         (status),
        .n_anneal_sweeps(n_anneal_sweeps),
        .n_meas_sweeps  (n_meas_sweeps),
        .T_step_raw     (T_step_raw),
        .lfsr_seed      (lfsr_seed),
        .J_flat         (J_flat),
        .h_field        (h_field),
        .sample_buf_addr(sample_buf_addr),
        .hist_buf_addr  (hist_buf_addr),
        .s_wr_req       (s_wr_req),
        .s_wr_addr      (s_wr_addr),
        .s_wr_data      (s_wr_data),
        .s_wr_strb      (s_wr_strb),
        .s_wr_done      (s_wr_done),
        .h_wr_req       (h_wr_req),
        .h_wr_addr      (h_wr_addr),
        .h_wr_data      (h_wr_data),
        .h_wr_strb      (h_wr_strb),
        .h_wr_done      (h_wr_done)
    );

    // ====================================================
    //  AXI4 마스터 0 – sample_buf 쓰기
    // ====================================================
    axi4_wr_master u_mst0 (
        .clk        (ap_clk),
        .rst_n      (ap_rst_n),
        .wr_req     (s_wr_req),
        .wr_addr    (s_wr_addr),
        .wr_data    (s_wr_data),
        .wr_strb    (s_wr_strb),
        .wr_done    (s_wr_done),
        .m_awaddr   (m_axi_gmem0_awaddr),
        .m_awlen    (m_axi_gmem0_awlen),
        .m_awsize   (m_axi_gmem0_awsize),
        .m_awburst  (m_axi_gmem0_awburst),
        .m_awvalid  (m_axi_gmem0_awvalid),
        .m_awready  (m_axi_gmem0_awready),
        .m_wdata    (m_axi_gmem0_wdata),
        .m_wstrb    (m_axi_gmem0_wstrb),
        .m_wlast    (m_axi_gmem0_wlast),
        .m_wvalid   (m_axi_gmem0_wvalid),
        .m_wready   (m_axi_gmem0_wready),
        .m_bresp    (m_axi_gmem0_bresp),
        .m_bvalid   (m_axi_gmem0_bvalid),
        .m_bready   (m_axi_gmem0_bready),
        .m_araddr   (m_axi_gmem0_araddr),
        .m_arlen    (m_axi_gmem0_arlen),
        .m_arsize   (m_axi_gmem0_arsize),
        .m_arburst  (m_axi_gmem0_arburst),
        .m_arvalid  (m_axi_gmem0_arvalid),
        .m_arready  (m_axi_gmem0_arready),
        .m_rdata    (m_axi_gmem0_rdata),
        .m_rresp    (m_axi_gmem0_rresp),
        .m_rlast    (m_axi_gmem0_rlast),
        .m_rvalid   (m_axi_gmem0_rvalid),
        .m_rready   (m_axi_gmem0_rready)
    );

    // ====================================================
    //  AXI4 마스터 1 – hist_buf 쓰기
    // ====================================================
    axi4_wr_master u_mst1 (
        .clk        (ap_clk),
        .rst_n      (ap_rst_n),
        .wr_req     (h_wr_req),
        .wr_addr    (h_wr_addr),
        .wr_data    (h_wr_data),
        .wr_strb    (h_wr_strb),
        .wr_done    (h_wr_done),
        .m_awaddr   (m_axi_gmem1_awaddr),
        .m_awlen    (m_axi_gmem1_awlen),
        .m_awsize   (m_axi_gmem1_awsize),
        .m_awburst  (m_axi_gmem1_awburst),
        .m_awvalid  (m_axi_gmem1_awvalid),
        .m_awready  (m_axi_gmem1_awready),
        .m_wdata    (m_axi_gmem1_wdata),
        .m_wstrb    (m_axi_gmem1_wstrb),
        .m_wlast    (m_axi_gmem1_wlast),
        .m_wvalid   (m_axi_gmem1_wvalid),
        .m_wready   (m_axi_gmem1_wready),
        .m_bresp    (m_axi_gmem1_bresp),
        .m_bvalid   (m_axi_gmem1_bvalid),
        .m_bready   (m_axi_gmem1_bready),
        .m_araddr   (m_axi_gmem1_araddr),
        .m_arlen    (m_axi_gmem1_arlen),
        .m_arsize   (m_axi_gmem1_arsize),
        .m_arburst  (m_axi_gmem1_arburst),
        .m_arvalid  (m_axi_gmem1_arvalid),
        .m_arready  (m_axi_gmem1_arready),
        .m_rdata    (m_axi_gmem1_rdata),
        .m_rresp    (m_axi_gmem1_rresp),
        .m_rlast    (m_axi_gmem1_rlast),
        .m_rvalid   (m_axi_gmem1_rvalid),
        .m_rready   (m_axi_gmem1_rready)
    );

endmodule
