# ============================================================
#  create_project.tcl  –  HLS synthesis + IP export
#
#  Usage:
#    vivado_hls -f pynq_prob_computing/hls/scripts/create_project.tcl
#
#  Vivado HLS  (2018.x – 2019.x) 과 Vitis HLS (2020.x+) 모두 호환.
#
#  출력: ising_sa_proj/solution1/impl/ip/
#       → vivado/create_bd.tcl 에서 이 경로를 IP repo 로 참조함
#
#  대상 보드: PYNQ-Z2  (xc7z020clg400-1)
# ============================================================

set PART       xc7z020clg400-1
set PROJ_NAME  ising_sa_proj
set TOP_FUNC   ising_core
set CLK_PERIOD 10   ;# ns → 100 MHz

# ── Paths ──────────────────────────────────────────────────────
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set HLS_ROOT   [file normalize "$SCRIPT_DIR/.."]

open_project $PROJ_NAME
set_top      $TOP_FUNC

# ── Source files ───────────────────────────────────────────────
add_files "$HLS_ROOT/src/ising_core.cpp" \
    -cflags "-I$HLS_ROOT/src"

# ── Testbench ──────────────────────────────────────────────────
add_files -tb "$HLS_ROOT/tb/ising_core_tb.cpp" \
    -cflags "-I$HLS_ROOT/src"

# ── Solution ───────────────────────────────────────────────────
# -flow_target vivado : Vivado HLS 2019.x 이하에서는 기본값이므로 생략 가능
#                       Vitis HLS 2020.x+ 에서는 명시 필요
open_solution solution1
set_part $PART
create_clock -period $CLK_PERIOD -name default

# ── C-simulation ───────────────────────────────────────────────
csim_design -clean

# ── RTL synthesis ──────────────────────────────────────────────
csynth_design

# ── C/RTL co-simulation (선택, 오래 걸림) ─────────────────────
# cosim_design -trace_level all

# ── IP catalog export → Vivado Block Design에서 사용 ───────────
export_design -format ip_catalog \
              -vendor  "knu" \
              -library "prob_computing" \
              -version "1.0" \
              -description "8-spin Ising SA core (Annealing + Measurement)"

close_project
