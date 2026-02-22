# ============================================================
#  create_project.tcl  –  Vivado HLS project creation script
#
#  Usage (from repo root):
#    vitis_hls -f pynq_prob_computing/hls/scripts/create_project.tcl
#
#  Targets the Zynq-7020 on PYNQ-Z2 (xc7z020clg400-1).
#  Change PART below if using a different board.
# ============================================================

set PART       xc7z020clg400-1
set PROJ_NAME  ising_sa_proj
set TOP_FUNC   ising_core
set CLK_PERIOD 10   ;# ns → 100 MHz

# ── Paths (relative to where vitis_hls is invoked) ────────────
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set HLS_ROOT   [file normalize "$SCRIPT_DIR/.."]

open_project $PROJ_NAME
set_top      $TOP_FUNC

# ── Source files ───────────────────────────────────────────────
add_files "$HLS_ROOT/src/ising_core.cpp" \
    -cflags "-I$HLS_ROOT/src"

# ── Testbench files ────────────────────────────────────────────
add_files -tb "$HLS_ROOT/tb/ising_core_tb.cpp" \
    -cflags "-I$HLS_ROOT/src"

# ── Solution: C-sim + synthesis for PYNQ-Z2 ───────────────────
open_solution solution1 -flow_target vivado
set_part $PART
create_clock -period $CLK_PERIOD -name default

# Run C-simulation first
csim_design -clean

# Synthesise
csynth_design

# Run C/RTL co-simulation (optional, slow)
# cosim_design -trace_level all

# Export IP (for Vivado block design)
export_design -format ip_catalog -description "Ising SA Core for PYNQ" \
              -vendor "edu" -library "prob_computing" -version "1.0"

close_project
