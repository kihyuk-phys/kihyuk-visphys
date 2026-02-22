# ============================================================
#  run_csim.tcl  –  C-simulation only (fast verification)
#
#  Usage:
#    vitis_hls -f pynq_prob_computing/hls/scripts/run_csim.tcl
# ============================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set HLS_ROOT   [file normalize "$SCRIPT_DIR/.."]

open_project ising_csim_proj
set_top ising_core

add_files "$HLS_ROOT/src/ising_core.cpp" \
    -cflags "-I$HLS_ROOT/src"

add_files -tb "$HLS_ROOT/tb/ising_core_tb.cpp" \
    -cflags "-I$HLS_ROOT/src"

open_solution solution1
set_part xc7z020clg400-1
create_clock -period 10 -name default

csim_design -clean -argv {}

close_project
