// ============================================================
//  sa_engine.v  –  Tanh P-bit SA 엔진 (핵심 로직)
//
//  Python 코드 대응:
//    T_temp = T_f * (i / (anneal-1))          ← T_now 증가
//    shuffled = fisher_yates([0..7])           ← SHUF 상태
//    h_eff = sum(J[j][k] * m[k])              ← HEFF 상태
//    m[j] = sign(tanh(T*h_eff) + U(-1,1))     ← PBIT 상태
//         ↕
//    P(m=+1) = sigmoid(2*T*h_eff)
//            = (1 + tanh(T*h_eff)) / 2
//    → rand32 < sigmoid_lut[T*h_eff*32 + 256] 이면 +1
//
//  상태 전환 개요
//  ─────────────────────────────────────────────────────────
//  IDLE
//   └→ INIT         (히스토그램 초기화 256클럭, 스핀 초기화)
//       └→ [anneal 위상]
//           SHUF_INIT → SHUF_STEP(7회)
//           → HEFF_ACC(8회) → LUT_IDX → LUT_RD → PBIT_UPD
//           → (다음 스핀 or 스윕 종료)
//           → SAMP_WR  (AXI write sample_buf)
//           → ANNEAL_ADV (T_now++, 카운터 체크)
//       └→ [meas 위상]
//           (위와 같은 SHUF/HEFF/PBIT)
//           → HIST_UPD  (hist[spin]++)
//           → MEAS_ADV  (카운터 체크)
//       └→ FLUSH_WR(256회)  (hist_buf AXI write)
//       └→ DONE
// ============================================================
`timescale 1ns/1ps

module sa_engine (
    input  wire        clk,
    input  wire        rst_n,

    // ── 제어 ────────────────────────────────────────────────
    input  wire        ap_start,
    output reg         ap_done,
    output reg  [1:0]  status,     // 0=idle 1=anneal 2=meas 3=done

    // ── 파라미터 (axi4l_slave 출력) ─────────────────────────
    input  wire [31:0] n_anneal_sweeps,
    input  wire [31:0] n_meas_sweeps,
    input  wire [31:0] T_step_raw,    // T_step × 2^32 / sweep (드라이버 계산)
    input  wire [31:0] lfsr_seed,
    input  wire [31:0] J_flat   [0:63],
    input  wire [31:0] h_field  [0:7], // 현재 미사용 (0으로 전달), 확장용
    input  wire [31:0] sample_buf_addr,
    input  wire [31:0] hist_buf_addr,

    // ── AXI4 마스터 인터페이스 (sample_buf) ─────────────────
    output reg         s_wr_req,
    output reg  [31:0] s_wr_addr,
    output reg  [31:0] s_wr_data,
    output reg  [3:0]  s_wr_strb,
    input  wire        s_wr_done,

    // ── AXI4 마스터 인터페이스 (hist_buf) ────────────────────
    output reg         h_wr_req,
    output reg  [31:0] h_wr_addr,
    output reg  [31:0] h_wr_data,
    output reg  [3:0]  h_wr_strb,
    input  wire        h_wr_done
);

    // ====================================================
    //  상수
    // ====================================================
    localparam N = 8;   // 스핀 수

    // 상태 인코딩
    localparam S_IDLE       = 5'd0;
    localparam S_INIT       = 5'd1;   // 히스토그램 초기화
    localparam S_SHUF_INIT  = 5'd2;   // 순열 [0..7] 초기화
    localparam S_SHUF_STEP  = 5'd3;   // Fisher-Yates 7단계
    localparam S_HEFF_ACC   = 5'd4;   // h_eff 누적 (8사이클)
    localparam S_LUT_IDX    = 5'd5;   // LUT 인덱스 계산
    localparam S_LUT_RD     = 5'd6;   // LUT ROM 읽기 (1클럭 지연)
    localparam S_PBIT_UPD   = 5'd7;   // P-bit 업데이트 + 스핀 기록
    localparam S_SAMP_WR    = 5'd8;   // sample_buf AXI write
    localparam S_ANNEAL_ADV = 5'd9;   // 온도/카운터 업데이트
    localparam S_HIST_UPD   = 5'd10;  // hist[spin]++
    localparam S_MEAS_ADV   = 5'd11;  // 측정 카운터
    localparam S_FLUSH_WR   = 5'd12;  // hist_buf AXI write (256회)
    localparam S_DONE       = 5'd13;

    // ====================================================
    //  내부 레지스터
    // ====================================================
    reg [4:0]  state;
    reg        phase;          // 0 = anneal, 1 = meas

    // 스핀 상태: 1 = +1, 0 = -1
    reg [7:0]  spin;

    // 온도
    reg [31:0] T_now;          // T × 2^32 누적값

    // 카운터
    reg [31:0] anneal_cnt;     // 어닐링 스윕 카운터
    reg [31:0] meas_cnt;       // 측정 스윕 카운터
    reg [8:0]  init_cnt;       // 초기화 카운터 (0..255)
    reg [8:0]  flush_cnt;      // 히스토그램 플러시 카운터

    // 현재 스핀 인덱스
    reg [2:0]  spin_cnt;       // 0..7, 한 스윕 내 처리한 스핀 수

    // Fisher-Yates 순열
    reg [2:0]  perm [0:7];     // perm[i] ∈ {0..7}
    reg [2:0]  shuf_i;         // Fisher-Yates 단계 (7 downto 1)
    reg [2:0]  j_curr;         // 현재 처리 중인 스핀: perm[spin_cnt]
    reg [2:0]  swap_j;         // Fisher-Yates 교환 대상 인덱스
    reg [2:0]  swap_tmp;       // 교환 임시 변수

    // h_eff 누적
    reg [2:0]  heff_k;         // 0..7
    reg signed [35:0] h_acc;   // 누적기 (36-bit: 8 × int32 합)

    // LUT 인터페이스
    reg  [8:0]  lut_idx_r;
    wire [31:0] lut_val;       // sigmoid_lut 출력 (1클럭 지연)

    // 히스토그램 (FPGA 내부 레지스터 → 합성 시 BRAM으로 추론)
    reg [31:0] histogram [0:255];

    // LFSR
    reg        lfsr_en;
    reg        lfsr_load;
    wire[31:0] lfsr_q;

    // ====================================================
    //  서브모듈 인스턴스
    // ====================================================

    lfsr32 u_lfsr (
        .clk   (clk),
        .rst_n (rst_n),
        .load  (lfsr_load),
        .seed  (lfsr_seed),
        .en    (lfsr_en),
        .q     (lfsr_q)
    );

    sigmoid_lut u_lut (
        .clk (clk),
        .idx (lut_idx_r),
        .val (lut_val)
    );

    // ====================================================
    //  h_eff 조합 논리: j_curr 행에 대해 즉시 계산
    //  h_acc 는 FSM 에서 순차 누적하지만,
    //  각 클럭에 더할 항은 조합으로 계산
    // ====================================================
    // (FSM 내부에서 직접 계산)

    // ====================================================
    //  LUT 인덱스 계산 (S_LUT_IDX 상태에서 등록)
    // ====================================================
    // T_now (T×2^32, unsigned 32-bit) × |h_eff| (35-bit unsigned)
    // 곱 >> 27 = T × |h_eff| × 32  →  LUT 인덱스 절대값
    wire        h_neg    = h_acc[35];
    wire [35:0] h_abs    = h_neg ? (~h_acc + 36'd1) : h_acc;
    wire [63:0] t_h_prod = T_now * h_abs[31:0];          // 32×32 곱 (64-bit)
    wire [36:0] idx_raw  = t_h_prod[63:27];               // >> 27
    wire [7:0]  idx_abs  = (|idx_raw[36:8]) ? 8'd255 : idx_raw[7:0]; // 0..255로 포화

    // 부호 고려: 양수 h_eff → 256+, 음수 → 256-
    wire [8:0]  lut_idx_comb = h_neg ? (9'd256 - {1'b0, idx_abs})
                                     : (9'd256 + {1'b0, idx_abs});

    // ====================================================
    //  메인 FSM
    // ====================================================
    integer fi;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            ap_done     <= 1'b0;
            status      <= 2'd0;
            spin        <= 8'h0;
            T_now       <= 32'd0;
            anneal_cnt  <= 32'd0;
            meas_cnt    <= 32'd0;
            init_cnt    <= 9'd0;
            flush_cnt   <= 9'd0;
            spin_cnt    <= 3'd0;
            shuf_i      <= 3'd7;
            h_acc       <= 36'sd0;
            heff_k      <= 3'd0;
            phase       <= 1'b0;
            lut_idx_r   <= 9'd256;
            lfsr_en     <= 1'b0;
            lfsr_load   <= 1'b0;
            s_wr_req    <= 1'b0;
            h_wr_req    <= 1'b0;
            for (fi = 0; fi < 8; fi = fi+1) perm[fi] <= fi[2:0];
            for (fi = 0; fi < 256; fi = fi+1) histogram[fi] <= 32'd0;
        end else begin

            // 기본값 (펄스 신호)
            ap_done  <= 1'b0;
            lfsr_en  <= 1'b0;
            lfsr_load<= 1'b0;
            s_wr_req <= 1'b0;
            h_wr_req <= 1'b0;

            case (state)

                // ──────────────────────────────────────────────────
                S_IDLE: begin
                    status <= 2'd0;
                    if (ap_start) begin
                        // LFSR 시드 로드
                        lfsr_load   <= 1'b1;
                        // 카운터/변수 초기화
                        T_now       <= 32'd0;
                        anneal_cnt  <= 32'd0;
                        meas_cnt    <= 32'd0;
                        flush_cnt   <= 9'd0;
                        spin_cnt    <= 3'd0;
                        phase       <= 1'b0;
                        init_cnt    <= 9'd0;
                        state       <= S_INIT;
                    end
                end

                // ──────────────────────────────────────────────────
                // 히스토그램 초기화 (256클럭) + 스핀 랜덤 초기화
                S_INIT: begin
                    histogram[init_cnt[7:0]] <= 32'd0;
                    lfsr_en <= 1'b1;  // LFSR 돌리면서 스핀 초기화
                    if (init_cnt == 9'd7) begin
                        // 처음 8클럭은 스핀 초기화에 사용
                        spin[init_cnt[2:0]] <= lfsr_q[0];
                    end
                    if (init_cnt == 9'd255) begin
                        state  <= S_SHUF_INIT;
                        status <= 2'd1;  // annealing 시작
                    end
                    init_cnt <= init_cnt + 9'd1;
                end

                // ──────────────────────────────────────────────────
                // 순열 초기화 [0,1,2,3,4,5,6,7]
                S_SHUF_INIT: begin
                    perm[0] <= 3'd0; perm[1] <= 3'd1;
                    perm[2] <= 3'd2; perm[3] <= 3'd3;
                    perm[4] <= 3'd4; perm[5] <= 3'd5;
                    perm[6] <= 3'd6; perm[7] <= 3'd7;
                    shuf_i  <= 3'd7;
                    lfsr_en <= 1'b1;  // 다음 랜덤 준비
                    state   <= S_SHUF_STEP;
                end

                // ──────────────────────────────────────────────────
                // Fisher-Yates: shuf_i = 7 downto 1 (7단계)
                // j = lfsr_q % (shuf_i+1), swap(perm[shuf_i], perm[j])
                S_SHUF_STEP: begin
                    // swap_j = lfsr_q % (shuf_i+1)
                    // shuf_i+1 ∈ {2,3,4,5,6,7,8}
                    case (shuf_i)
                        3'd7: swap_j <= lfsr_q[2:0];           // % 8 = 3 LSB
                        3'd6: swap_j <= (lfsr_q[2:0] < 3'd7) ? lfsr_q[2:0] :
                                        (lfsr_q[2:0] - 3'd7);  // approx % 7
                        3'd5: swap_j <= lfsr_q[2:0] % 3'd6;
                        3'd4: swap_j <= lfsr_q[2:0] % 3'd5;
                        3'd3: swap_j <= {1'b0, lfsr_q[1:0]};   // % 4 = 2 LSB
                        3'd2: swap_j <= (lfsr_q[1:0] == 2'd3) ? 3'd0 :
                                        {1'b0, lfsr_q[1:0]};   // approx % 3
                        3'd1: swap_j <= {2'b0, lfsr_q[0]};     // % 2 = 1 LSB
                        default: swap_j <= 3'd0;
                    endcase

                    lfsr_en <= 1'b1;

                    // 교환 수행 (다음 클럭에 반영되도록 레지스터에 기록)
                    // perm[shuf_i] ↔ perm[swap_j]
                    // swap_j는 조합 논리로 계산됨 → 래치에 넣기
                    // 실제 교환은 다음 상태에서 처리 (1클럭 지연)
                    swap_tmp <= perm[shuf_i];

                    if (shuf_i == 3'd1) begin
                        // 마지막 단계 → 교환 후 스핀 처리 시작
                        // (교환은 아래 별도 로직으로 처리)
                        spin_cnt <= 3'd0;
                        state    <= S_HEFF_ACC;
                    end else begin
                        shuf_i <= shuf_i - 3'd1;
                    end
                end

                // ──────────────────────────────────────────────────
                // h_eff = Σ J[j_curr][k] * m[k], k = 0..7 (8클럭)
                S_HEFF_ACC: begin
                    if (heff_k == 3'd0) begin
                        // 이 스핀에 대한 누적 초기화
                        j_curr <= perm[spin_cnt];
                        h_acc  <= 36'sd0;
                        heff_k <= 3'd1;
                    end else begin
                        // k = heff_k-1 에 해당하는 항 누적
                        // J_flat[j_curr*8 + (heff_k-1)]
                        // Verilog에서 j_curr*8은 런타임 계산 → 멀티플렉서 트리로 합성
                        h_acc <= h_acc +
                            (spin[heff_k-1]
                                ? $signed({1'b0, J_flat[{j_curr, (heff_k-1)}]})
                                : -$signed({1'b0, J_flat[{j_curr, (heff_k-1)}]}));
                        if (heff_k == 3'd7) begin
                            // 마지막 항 처리 후 → 8번째 항(k=7) 은 LUT_IDX에서 처리
                            heff_k <= 3'd0;
                            state  <= S_LUT_IDX;
                        end else begin
                            heff_k <= heff_k + 3'd1;
                        end
                    end
                end

                // ──────────────────────────────────────────────────
                // k=7 마지막 항 추가 + LUT 인덱스 등록
                S_LUT_IDX: begin
                    // k=7 항 처리
                    h_acc <= h_acc +
                        (spin[7]
                            ? $signed({1'b0, J_flat[{j_curr, 3'd7}]})
                            : -$signed({1'b0, J_flat[{j_curr, 3'd7}]}));
                    // lut_idx 등록 (h_acc는 다음 클럭에 최종값)
                    lut_idx_r <= lut_idx_comb;
                    lfsr_en   <= 1'b1;   // 난수 사전 준비
                    state     <= S_LUT_RD;
                end

                // ──────────────────────────────────────────────────
                // sigmoid_lut 읽기 지연 1클럭
                S_LUT_RD: begin
                    // lut_val 유효해짐 (sigmoid_lut 동기 ROM)
                    // lut_idx_r 재계산 (h_acc 최종값 반영)
                    lut_idx_r <= lut_idx_comb;
                    state     <= S_PBIT_UPD;
                end

                // ──────────────────────────────────────────────────
                // P-bit 업데이트: rand32 < lut_val → spin[j]=1, else 0
                S_PBIT_UPD: begin
                    spin[j_curr] <= (lfsr_q < lut_val) ? 1'b1 : 1'b0;
                    lfsr_en      <= 1'b1;

                    if (spin_cnt == 3'd7) begin
                        // 한 스윕 완료
                        spin_cnt <= 3'd0;
                        if (!phase) begin
                            // Annealing 위상: sample_buf 쓰기
                            state <= S_SAMP_WR;
                        end else begin
                            // Measurement 위상: 히스토그램 업데이트
                            state <= S_HIST_UPD;
                        end
                    end else begin
                        spin_cnt <= spin_cnt + 3'd1;
                        state    <= S_HEFF_ACC;
                    end
                end

                // ──────────────────────────────────────────────────
                // sample_buf 에 현재 스핀 상태(1바이트) AXI 쓰기
                S_SAMP_WR: begin
                    if (!s_wr_req && !s_wr_done) begin
                        s_wr_req  <= 1'b1;
                        // 바이트 어드레싱: anneal_cnt 번째 바이트
                        s_wr_addr <= sample_buf_addr + anneal_cnt;
                        s_wr_data <= {24'd0, spin};
                        s_wr_strb <= 4'b0001;
                    end else if (s_wr_done) begin
                        state <= S_ANNEAL_ADV;
                    end
                end

                // ──────────────────────────────────────────────────
                // 어닐링 단계 업데이트
                S_ANNEAL_ADV: begin
                    T_now      <= T_now + T_step_raw;
                    anneal_cnt <= anneal_cnt + 32'd1;

                    if (anneal_cnt + 32'd1 >= n_anneal_sweeps) begin
                        // 어닐링 완료 → 측정 위상으로
                        phase      <= 1'b1;
                        meas_cnt   <= 32'd0;
                        status     <= 2'd2;
                        state      <= S_SHUF_INIT;
                    end else begin
                        state <= S_SHUF_INIT;
                    end
                end

                // ──────────────────────────────────────────────────
                // 히스토그램 업데이트: hist[spin]++
                S_HIST_UPD: begin
                    histogram[spin] <= histogram[spin] + 32'd1;
                    state           <= S_MEAS_ADV;
                end

                // ──────────────────────────────────────────────────
                // 측정 단계 업데이트
                S_MEAS_ADV: begin
                    meas_cnt <= meas_cnt + 32'd1;

                    if (meas_cnt + 32'd1 >= n_meas_sweeps) begin
                        // 측정 완료 → 히스토그램 플러시
                        flush_cnt <= 9'd0;
                        state     <= S_FLUSH_WR;
                    end else begin
                        state <= S_SHUF_INIT;
                    end
                end

                // ──────────────────────────────────────────────────
                // 히스토그램 256 엔트리를 hist_buf 에 AXI 쓰기
                S_FLUSH_WR: begin
                    if (!h_wr_req && !h_wr_done) begin
                        h_wr_req  <= 1'b1;
                        h_wr_addr <= hist_buf_addr + {flush_cnt, 2'b00};  // × 4
                        h_wr_data <= histogram[flush_cnt[7:0]];
                        h_wr_strb <= 4'b1111;
                    end else if (h_wr_done) begin
                        if (flush_cnt == 9'd255) begin
                            state <= S_DONE;
                        end else begin
                            flush_cnt <= flush_cnt + 9'd1;
                        end
                    end
                end

                // ──────────────────────────────────────────────────
                S_DONE: begin
                    status  <= 2'd3;
                    ap_done <= 1'b1;
                    if (!ap_start)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase

            // ────────────────────────────────────────────────────
            // Fisher-Yates 교환: swap_tmp / swap_j 확정 후 수행
            // SHUF_STEP 상태에서 1클럭 뒤에 반영
            // (perm 배열에 직접 쓰기 → 별도 처리)
            if (state == S_SHUF_STEP) begin
                perm[shuf_i] <= perm[swap_j];
                perm[swap_j] <= swap_tmp;
            end

        end
    end

endmodule
