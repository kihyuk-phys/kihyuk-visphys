# ============================================================
#  create_bd.tcl  –  Vivado Block Design + Bitstream 전 과정
#                    (Verilog RTL 직접 합성 버전)
#
#  HLS 합성 불필요 – rtl/*.v 파일을 직접 사용
#
#  Usage (Vivado Tcl Console 또는 커맨드라인)
#  ─────────────────────────────────────────────────────────────
#  Vivado Tcl Console:
#    source {C:/path/to/pynq_prob_computing/vivado/create_bd.tcl}
#
#  커맨드라인 (프로젝트 루트에서):
#    vivado -mode batch -source pynq_prob_computing/vivado/create_bd.tcl
#
#  출력 파일 (pynq_output/ 디렉터리)
#  ─────────────────────────────────────────────────────────────
#  ising_sa.bit   – PYNQ 보드에 올릴 비트스트림
#  ising_sa.hwh   – PYNQ Python 드라이버용 하드웨어 핸드오프
#
#  블록 다이어그램 구조
#  ─────────────────────────────────────────────────────────────
#
#  ┌─────────────────────────────────────────────────────────────┐
#  │  Zynq PS7                                                    │
#  │  ┌──────────────┐                                            │
#  │  │ M_AXI_GP0   │──→ [AXI IC ctrl] ──→ ising_core s_axi_ctrl│
#  │  │              │                                            │
#  │  │ S_AXI_HP0   │←── [SmartConnect] ←── ising_core m_axi_gmem0 (sample_buf)
#  │  │ S_AXI_HP1   │←── [SmartConnect] ←── ising_core m_axi_gmem1 (hist_buf)
#  │  └──────────────┘                                            │
#  └─────────────────────────────────────────────────────────────┘
#
#  주소 맵 (GP0 기준)
#  ─────────────────────────────────────────────────────────────
#  ising_core s_axi_ctrl : 0x43C0_0000  (64KB)
# ============================================================

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ① 사용자 설정  ← 보드에 따라 여기만 수정
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# PYNQ-Z2
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"

# PYNQ-Z1 (Digilent) 사용 시 아래 두 줄로 교체
# set PART       "xc7z020clg484-1"
# set BOARD_PART "digilentinc.com:pynq-z1:part0:1.0"

set PROJ_NAME  "ising_sa_vivado"
set BD_NAME    "ising_sa_bd"

# 이 스크립트가 pynq_prob_computing/vivado/ 에 있다고 가정
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set RTL_DIR    [file normalize "$SCRIPT_DIR/../rtl"]
set OUT_DIR    [file normalize "$SCRIPT_DIR/../pynq_output"]

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ② RTL 파일 존재 확인
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if {![file isdirectory $RTL_DIR]} {
    error "RTL 디렉터리가 없습니다: $RTL_DIR"
}
puts "RTL 경로: $RTL_DIR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ③ Vivado 프로젝트 생성
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

create_project $PROJ_NAME [file normalize "$SCRIPT_DIR/$PROJ_NAME"] -part $PART

if {[catch {set_property board_part $BOARD_PART [current_project]} err]} {
    puts "WARN: 보드 파일 없음 ($BOARD_PART). Part 설정만 사용합니다."
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ④ RTL 소스 파일 추가
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set rtl_files [list \
    "$RTL_DIR/ising_core.v"     \
    "$RTL_DIR/sa_engine.v"      \
    "$RTL_DIR/axi4l_slave.v"    \
    "$RTL_DIR/axi4_wr_master.v" \
    "$RTL_DIR/sigmoid_lut.v"    \
    "$RTL_DIR/lfsr32.v"         \
]
add_files -norecurse $rtl_files
set_property top ising_core [current_fileset]
update_compile_order -fileset sources_1
puts "RTL 파일 추가 완료: [llength $rtl_files]개"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑤ Block Design 생성
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

create_bd_design $BD_NAME
puts "Block Design '$BD_NAME' 생성."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑥ Zynq PS7 인스턴스
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

if {[catch {
    apply_bd_automation \
        -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} \
        [get_bd_cells processing_system7_0]
} err]} {
    puts "보드 프리셋 없음, 수동 PS7 설정 적용..."
    make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/DDR]
    make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/FIXED_IO]
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0              {1} \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ   {100} \
        CONFIG.PCW_UIPARAM_DDR_PARTNO         {MT41K256M16 RE-125} \
        CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    ] [get_bd_cells processing_system7_0]
}

set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0        {1} \
    CONFIG.PCW_USE_S_AXI_HP1        {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {64} \
] [get_bd_cells processing_system7_0]
puts "Zynq PS7 설정 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑦ proc_sys_reset
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑧ ising_core RTL 모듈 인스턴스 (Module Reference)
#
#  RTL 파일을 직접 BD 셀로 참조 (IP 패키징 불필요)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

create_bd_cell -type module -reference ising_core ising_core_0
puts "RTL 모듈 ising_core 인스턴스 생성."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑨ AXI 인프라
#     ctrl  : AXI Interconnect  (GP0 → s_axi_ctrl)
#     gmem0 : AXI SmartConnect  (m_axi_gmem0 → HP0)
#     gmem1 : AXI SmartConnect  (m_axi_gmem1 → HP1)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ctrl 인터커넥트 (AXI Interconnect, 1SI/1MI)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ctrl
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] [get_bd_cells axi_ic_ctrl]

# gmem0 SmartConnect (sample_buf → HP0)
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_gmem0
set_property CONFIG.NUM_SI {1} [get_bd_cells sc_gmem0]

# gmem1 SmartConnect (hist_buf → HP1)
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_gmem1
set_property CONFIG.NUM_SI {1} [get_bd_cells sc_gmem1]

puts "AXI 인프라 IP 생성 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑩ 클럭 연결 (단일 도메인: FCLK_CLK0 = 100 MHz)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set fclk0 [get_bd_pins processing_system7_0/FCLK_CLK0]

# PS 포트 클럭
connect_bd_net $fclk0 [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]
connect_bd_net $fclk0 [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
connect_bd_net $fclk0 [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK]

# reset
connect_bd_net $fclk0 [get_bd_pins rst_ps7_0_100M/slowest_sync_clk]

# AXI Interconnect (ctrl)
connect_bd_net $fclk0 [get_bd_pins axi_ic_ctrl/ACLK]
connect_bd_net $fclk0 [get_bd_pins axi_ic_ctrl/S00_ACLK]
connect_bd_net $fclk0 [get_bd_pins axi_ic_ctrl/M00_ACLK]

# SmartConnect (gmem0, gmem1)
connect_bd_net $fclk0 [get_bd_pins sc_gmem0/aclk]
connect_bd_net $fclk0 [get_bd_pins sc_gmem1/aclk]

# HLS IP
connect_bd_net $fclk0 [get_bd_pins ising_core_0/ap_clk]

puts "클럭 연결 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑪ 리셋 연결
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set fclk_rst [get_bd_pins processing_system7_0/FCLK_RESET0_N]
connect_bd_net $fclk_rst [get_bd_pins rst_ps7_0_100M/ext_reset_in]

# AXI Interconnect 리셋
connect_bd_net [get_bd_pins rst_ps7_0_100M/interconnect_aresetn] \
               [get_bd_pins axi_ic_ctrl/ARESETN]

set periph_rst [get_bd_pins rst_ps7_0_100M/peripheral_aresetn]
connect_bd_net $periph_rst [get_bd_pins axi_ic_ctrl/S00_ARESETN]
connect_bd_net $periph_rst [get_bd_pins axi_ic_ctrl/M00_ARESETN]

# SmartConnect 리셋
connect_bd_net $periph_rst [get_bd_pins sc_gmem0/aresetn]
connect_bd_net $periph_rst [get_bd_pins sc_gmem1/aresetn]

# HLS IP 리셋
connect_bd_net $periph_rst [get_bd_pins ising_core_0/ap_rst_n]

puts "리셋 연결 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑫ AXI 인터페이스 연결
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── 컨트롤 경로 ────────────────────────────────────────────────
# PS GP0 → AXI Interconnect → ising_core s_axi_ctrl
connect_bd_intf_net \
    [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
    [get_bd_intf_pins axi_ic_ctrl/S00_AXI]

connect_bd_intf_net \
    [get_bd_intf_pins axi_ic_ctrl/M00_AXI] \
    [get_bd_intf_pins ising_core_0/s_axi_ctrl]

# ── 데이터 경로 (sample_buf) ───────────────────────────────────
# ising_core m_axi_gmem0 → SmartConnect → PS HP0
connect_bd_intf_net \
    [get_bd_intf_pins ising_core_0/m_axi_gmem0] \
    [get_bd_intf_pins sc_gmem0/S00_AXI]

connect_bd_intf_net \
    [get_bd_intf_pins sc_gmem0/M00_AXI] \
    [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

# ── 데이터 경로 (hist_buf) ─────────────────────────────────────
# ising_core m_axi_gmem1 → SmartConnect → PS HP1
connect_bd_intf_net \
    [get_bd_intf_pins ising_core_0/m_axi_gmem1] \
    [get_bd_intf_pins sc_gmem1/S00_AXI]

connect_bd_intf_net \
    [get_bd_intf_pins sc_gmem1/M00_AXI] \
    [get_bd_intf_pins processing_system7_0/S_AXI_HP1]

puts "AXI 인터페이스 연결 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑬ 주소 할당
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

assign_bd_address

# ising_core s_axi_ctrl 를 0x43C00000 에 고정 (PYNQ 관례)
# (auto-assign 후 주소가 다를 경우 아래로 덮어씀)
set seg [get_bd_addr_segs -of_objects \
    [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
    -filter {NAME =~ *ising_core_0*}]
if {$seg ne ""} {
    set_property offset 0x43C00000 $seg
    set_property range  64K        $seg
    puts "ising_core_0 ctrl 주소 고정: 0x43C00000 (64KB)"
} else {
    puts "WARN: ising_core_0 주소 세그먼트 자동 할당 사용."
    puts "      hwh 파일에서 실제 주소를 확인하세요."
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑭ 검증 & 저장
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

validate_bd_design
save_bd_design
puts "Block Design 검증 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑮ HDL Wrapper 생성
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

make_wrapper -files [get_files ${BD_NAME}.bd] -top
set wrapper_v [glob -nocomplain \
    "[file normalize "$SCRIPT_DIR/$PROJ_NAME"]/$PROJ_NAME.srcs/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"]
if {$wrapper_v eq ""} {
    # 경로 형식이 다를 경우 (Vivado 버전에 따라 다름)
    set wrapper_v [glob -nocomplain \
        "[file normalize "$SCRIPT_DIR/$PROJ_NAME"]/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"]
}
add_files -norecurse $wrapper_v
set_property top ${BD_NAME}_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "HDL Wrapper 추가: $wrapper_v"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑯ 합성 → P&R → 비트스트림
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

puts "합성 시작..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "합성 실패. Vivado 로그를 확인하세요."
}
puts "합성 완료."

puts "구현 + 비트스트림 생성 시작..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "구현 실패. Vivado 로그를 확인하세요."
}
puts "비트스트림 생성 완료."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ⑰ PYNQ 출력 파일 복사
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

file mkdir $OUT_DIR

# ── 비트스트림 ─────────────────────────────────────────────────
set bitfile [glob -nocomplain \
    "[file normalize "$SCRIPT_DIR/$PROJ_NAME"]/$PROJ_NAME.runs/impl_1/${BD_NAME}_wrapper.bit"]
if {$bitfile ne ""} {
    file copy -force $bitfile "$OUT_DIR/ising_sa.bit"
    puts "비트스트림 → $OUT_DIR/ising_sa.bit"
} else {
    puts "WARN: 비트스트림 파일을 찾지 못했습니다."
}

# ── hwh (Hardware Handoff) ─────────────────────────────────────
# Vivado 2019.1+ 은 BD 디렉터리에 자동 생성
set hwhfile [glob -nocomplain \
    "[file normalize "$SCRIPT_DIR/$PROJ_NAME"]/$PROJ_NAME.srcs/sources_1/bd/$BD_NAME/${BD_NAME}.hwh"]
if {$hwhfile eq ""} {
    # gen 경로 (2020+)
    set hwhfile [glob -nocomplain \
        "[file normalize "$SCRIPT_DIR/$PROJ_NAME"]/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/${BD_NAME}.hwh"]
}
if {$hwhfile ne ""} {
    file copy -force $hwhfile "$OUT_DIR/ising_sa.hwh"
    puts "HWH → $OUT_DIR/ising_sa.hwh"
} else {
    puts "WARN: hwh 파일이 없습니다. Vivado 2019.1+ 필요."
    puts "      또는 File → Export → Export Hardware 로 수동 생성."
}

puts ""
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  완료!"
puts "  PYNQ 보드에 업로드:"
puts "    scp $OUT_DIR/ising_sa.bit xilinx@<pynq-ip>:/home/xilinx/"
puts "    scp $OUT_DIR/ising_sa.hwh xilinx@<pynq-ip>:/home/xilinx/"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
